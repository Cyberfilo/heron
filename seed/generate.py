#!/usr/bin/env python3
"""Deterministic data generator entrypoint.

  PYTHONHASHSEED=0 python generate.py --dsn <conninfo> --scale small --seed 42

Truncates all benchmark tables (RESTART IDENTITY -> ids start at 1, which the engine
relies on), then generates + COPYs every table in FK-topological order.
"""
from __future__ import annotations

import argparse
import os
import sys
import time

import psycopg

import engine
import recipes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True, help="libpq conninfo or URL")
    ap.add_argument("--scale", default="small", choices=["tiny", "small", "bench", "large"])
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if os.environ.get("PYTHONHASHSEED") != "0":
        # determinism guard (string hashing affects nothing we rely on now, but keep the
        # contract explicit per DATA-REALISM.md).
        os.environ["PYTHONHASHSEED"] = "0"

    t0 = time.time()
    with psycopg.connect(args.dsn, autocommit=False) as conn:
        eng = engine.Engine(conn, args.scale, args.seed, recipes_mod=recipes)
        tbls = ", ".join(eng.S["tables"])
        with conn.cursor() as cur:
            cur.execute(f"TRUNCATE {tbls} RESTART IDENTITY CASCADE")
        conn.commit()
        log = (lambda *_: None) if args.quiet else print
        log(f"seeding scale={args.scale} seed={args.seed} over {len(eng.S['tables'])} tables")
        eng.run(log=log)

    total = time.time() - t0
    print(f"\nseeded scale={args.scale} seed={args.seed} in {total:.1f}s", file=sys.stderr)


if __name__ == "__main__":
    main()
