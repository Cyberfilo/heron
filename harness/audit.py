#!/usr/bin/env python3
"""Gold-quality audit (docs/METHODOLOGY.md §6). Run before publishing any number.

For every question:
  - the gold SQL must execute with no error,
  - it must return a non-empty result (unless tagged 'empty-set-probe'),
  - the declared gold_tables must EQUAL the tables the SQL actually references
    (parsed with sqlglot) — no missing, no spurious.

Exits non-zero if any check fails. This is what makes heron's gold trustworthy:
the dominant failure mode of prior benchmarks is wrong gold, and we own ours.
"""
from __future__ import annotations

import argparse
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import psycopg
import sqlglot
from sqlglot import exp

from questions.schema import load_all


def referenced_tables(sql: str) -> set[str]:
    tree = sqlglot.parse_one(sql, read="postgres")
    cte_names = {c.alias_or_name for c in tree.find_all(exp.CTE)}
    out = set()
    for t in tree.find_all(exp.Table):
        if t.name in cte_names and not t.db:
            continue
        out.add(f"{t.db}.{t.name}" if t.db else t.name)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    qs = load_all()
    fails = 0
    empty = 0
    with psycopg.connect(args.dsn) as conn:
        for q in qs:
            # 1) declared tables == referenced tables
            try:
                ref = referenced_tables(q.gold_sql)
            except Exception as e:  # noqa: BLE001
                print(f"FAIL {q.id}: gold SQL does not parse: {e}")
                fails += 1
                continue
            declared = set(q.gold_tables)
            if ref != declared:
                missing = ref - declared
                spurious = declared - ref
                msg = []
                if missing:
                    msg.append(f"referenced-but-undeclared={sorted(missing)}")
                if spurious:
                    msg.append(f"declared-but-unused={sorted(spurious)}")
                print(f"FAIL {q.id}: gold_tables mismatch: {'; '.join(msg)}")
                fails += 1

            # 2) executes + non-empty
            with conn.cursor() as cur:
                try:
                    cur.execute(q.gold_sql)
                    rows = cur.fetchall()
                except Exception as e:  # noqa: BLE001
                    conn.rollback()
                    print(f"FAIL {q.id}: gold SQL errored: {str(e).splitlines()[0]}")
                    fails += 1
                    continue
                conn.rollback()
            n = len(rows)
            is_empty = (n == 0) or (n == 1 and all(v is None for v in rows[0]))
            if is_empty and "empty-set-probe" not in q.tags:
                print(f"WARN {q.id}: gold returned empty ({q.text!r})")
                empty += 1
            elif args.verbose:
                print(f"ok   {q.id}: {n} row(s)  [{q.sql_shape}/{q.retrieval}]")

    print(f"\n{len(qs)} questions: {fails} hard failure(s), {empty} empty result(s)")
    if fails:
        sys.exit(1)


if __name__ == "__main__":
    main()
