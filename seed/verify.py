#!/usr/bin/env python3
"""Post-load integrity & realism checks. Exits non-zero on any hard failure.

Hard invariants (must be 0): FK orphans are impossible (enforced by the DB), so we
check the things the GENERATOR could get wrong — tenant isolation, temporal coherence,
non-negative money — plus a realism sanity report (counts, skew, status mixes).
"""
from __future__ import annotations

import argparse
import sys

import psycopg

# (label, sql_returning_a_count_that_must_be_zero)
HARD = [
    ("order_items tenant matches order",
     "SELECT count(*) FROM sales.order_items oi JOIN sales.orders o ON o.id=oi.order_id "
     "WHERE oi.tenant_id <> o.tenant_id"),
    ("payments tenant matches order",
     "SELECT count(*) FROM billing.payments p JOIN sales.orders o ON o.id=p.order_id "
     "WHERE p.order_id IS NOT NULL AND p.tenant_id <> o.tenant_id"),
    ("orders updated_at >= created_at",
     "SELECT count(*) FROM sales.orders WHERE updated_at < created_at"),
    ("orders grand_total non-negative",
     "SELECT count(*) FROM sales.orders WHERE grand_total < 0"),
    ("order_items quantity positive",
     "SELECT count(*) FROM sales.order_items WHERE quantity <= 0"),
    ("subscriptions period order",
     "SELECT count(*) FROM billing.subscriptions "
     "WHERE current_period_end IS NOT NULL AND current_period_start IS NOT NULL "
     "AND current_period_end < current_period_start"),
]

REPORT = [
    ("tenants", "SELECT count(*) FROM identity.tenants"),
    ("users", "SELECT count(*) FROM identity.users"),
    ("orders", "SELECT count(*) FROM sales.orders"),
    ("order_items", "SELECT count(*) FROM sales.order_items"),
    ("events", "SELECT count(*) FROM analytics.events"),
    ("payments", "SELECT count(*) FROM billing.payments"),
    ("total rows (est)",
     "SELECT sum(n_live_tup)::bigint FROM pg_stat_user_tables"),
    ("DB size", "SELECT pg_size_pretty(pg_database_size(current_database()))"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    args = ap.parse_args()
    failures = 0
    with psycopg.connect(args.dsn) as conn, conn.cursor() as cur:
        print("== hard invariants (must be 0) ==")
        for label, sql in HARD:
            try:
                cur.execute(sql)
                v = cur.fetchone()[0]
            except Exception as e:  # noqa: BLE001 — a missing column means a schema/recipe drift
                print(f"  ERROR {label}: {e}")
                conn.rollback()
                failures += 1
                continue
            ok = (v == 0)
            print(f"  {'OK ' if ok else 'FAIL'} {label}: {v}")
            failures += 0 if ok else 1

        print("\n== realism report ==")
        for label, sql in REPORT:
            cur.execute(sql)
            print(f"  {label:<20} {cur.fetchone()[0]}")

        print("\n== status mixes (sanity) ==")
        for tbl, col in [("sales.orders", "status"), ("billing.payments", "status"),
                         ("billing.subscriptions", "status")]:
            try:
                cur.execute(f"SELECT {col}, count(*) FROM {tbl} GROUP BY 1 ORDER BY 2 DESC")
                rows = cur.fetchall()
                print(f"  {tbl}.{col}: " + ", ".join(f"{r[0]}={r[1]}" for r in rows))
            except Exception:
                conn.rollback()

    if failures:
        print(f"\n{failures} hard invariant(s) FAILED", file=sys.stderr)
        sys.exit(1)
    print("\nall hard invariants passed")


if __name__ == "__main__":
    main()
