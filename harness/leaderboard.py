#!/usr/bin/env python3
"""Aggregate result JSONs into one cross-tool leaderboard (markdown).

  python harness/leaderboard.py results_*.json > docs/LEADERBOARD.md
  python harness/leaderboard.py --label "Vanna=results_vanna.json" "raw-llm=results_raw_gpt4o.json" ...

Each results file is what harness/run.py writes: {"summary": {...}, "results": [...]}. We rank by
EX@1, show Set-Recall (n/a for end-to-end tools), per-bucket EX, and an error tally so failures are
visible (a leaderboard of only wins is marketing, not a benchmark).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness.grade import compute as compute_grades  # noqa: E402


def load(path):
    with open(path) as f:
        d = json.load(f)
    s = d.get("summary", {})
    res = d.get("results", [])
    errs = sum(1 for r in res if r.get("error"))
    empties = sum(1 for r in res if not r.get("pred_sql") and not r.get("error"))
    return s, res, errs, empties


def cell(v):
    return "n/a" if v is None else (f"{v}" if isinstance(v, str) else f"{v}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*", help="results_*.json (or use --label name=path)")
    ap.add_argument("--label", nargs="*", default=[], help="name=path overrides for display")
    ap.add_argument("--title", default="heron cross-tool leaderboard")
    args = ap.parse_args()

    items = []  # (display_name, path)
    for spec in args.label:
        name, _, path = spec.partition("=")
        items.append((name, path))
    for path in args.files:
        for p in sorted(glob.glob(path)):
            items.append((None, p))

    rows = []
    for name, path in items:
        try:
            s, res, errs, empties = load(path)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"skip {path}: {e}\n")
            continue
        if s.get("adapter") == "gold":          # gold is the reference, not a ranked tool
            continue
        rows.append(dict(name=name or s.get("adapter", path), summary=s,
                         errs=errs, n=s.get("n") or len(res)))
    compute_grades(rows)                         # attaches grade + dims, sorts by grade

    print(f"# {args.title}\n")
    print("Ranked by **Grade** (0–100, see docs/METHODOLOGY.md §7). EX@1 is headline accuracy; VES is "
          "correctness-gated efficiency (100 = as fast as the gold query); Soft-F1 is partial-credit "
          "correctness; Set-Recall is `n/a` for end-to-end tools.\n")
    print("| Rank | Tool | Grade | EX@1 | VES | Soft-F1 | Set-Recall | ms/q | tok/q | errors |")
    print("|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for i, r in enumerate(rows, 1):
        s = r["summary"]
        print(f"| {i} | {r['name']} | **{cell(r['grade'])}** | {cell(s.get('ex_at_1'))} | "
              f"{cell(s.get('ves'))} | {cell(s.get('soft_f1'))} | {cell(s.get('set_recall'))} | "
              f"{cell(s.get('avg_total_ms'))} | {cell(s.get('avg_tokens'))} | {r['errs']} |")
    print(f"\n_{len(rows)} systems · Grade = .45 EX + .20 EFF + .10 REL + .15 TOK + .10 LAT "
          f"(METHODOLOGY §7). Per-bucket EX, retrieval distance, per-question timing/tokens in the "
          f"`results_*.json`. Token counts are OpenAI's billed `response.usage` (exact), captured "
          f"uniformly for every tool via the harness usage meter._")


if __name__ == "__main__":
    main()
