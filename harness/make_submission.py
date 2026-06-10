#!/usr/bin/env python3
"""Wrap a `make bench` results file into a leaderboard submission.

  python harness/make_submission.py results_<name>.json --tool "My Tool" --repo https://github.com/me/mytool

Writes submissions/<adapter>.json (the format harness/score_submission.py expects). The bot
re-runs your SQL from this file to compute the published numbers — so all it really needs from
you is each question's `pred_sql` (+ `pred_tables` for Set-Recall, and `prompt_tokens` /
`completion_tokens` for the self-reported token economy), which `make bench` already records.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results", help="a results_<name>.json written by `make bench`")
    ap.add_argument("--tool", required=True, help="display name for the leaderboard, e.g. 'My Tool'")
    ap.add_argument("--repo", default=None, help="link to your tool's repo")
    ap.add_argument("--submitted-by", default=None, help="your name/handle (optional)")
    ap.add_argument("--out", default=None, help="defaults to submissions/<adapter>.json")
    args = ap.parse_args()

    with open(args.results) as f:
        d = json.load(f)
    summary = d.get("summary", {})
    adapter = summary.get("adapter")
    if not adapter or "results" not in d:
        sys.exit("not a heron results file (need summary.adapter + results[])")
    if summary.get("n") != 100:
        sys.stderr.write(f"warning: this run has n={summary.get('n')}, not the full 100-question "
                         f"suite — incomplete submissions are rejected by CI.\n")

    submission = {
        "tool": args.tool,
        "adapter": adapter,
        "repo": args.repo,
        "submitted_by": args.submitted_by,
        "summary": summary,           # informational only — CI recomputes everything from results[]
        "results": d["results"],
    }
    out = args.out or os.path.join(ROOT, "submissions", f"{adapter}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(submission, f, indent=2, default=str)
    print(f"wrote {out}")
    print(f"  tool={args.tool!r} adapter={adapter!r} model={summary.get('model')} "
          f"questions={len(d['results'])}")
    print("Next: commit your adapter + this file, open a PR (template: add-a-tool). "
          "Do NOT edit docs/LEADERBOARD.md — the bot regenerates it.")


if __name__ == "__main__":
    main()
