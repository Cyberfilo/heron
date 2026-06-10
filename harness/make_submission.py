#!/usr/bin/env python3
"""Package a `make bench` run into a submission folder.

  python harness/make_submission.py results_<name>.json \
      --tool "My Tool" --repo https://github.com/me/mytool [--version 1.2] [--adapter-file path]

Creates submissions/<adapter>/ containing:
  results.json   your benchmark output (CI re-runs its SQL to compute the published numbers)
  meta.json      display info (tool name, repo, version, approach)
  adapter.py     a snapshot of the adapter that produced the run (auditable + reproducible)
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results", help="a results_<name>.json written by `make bench`")
    ap.add_argument("--tool", required=True, help="display name on the leaderboard")
    ap.add_argument("--repo", default=None)
    ap.add_argument("--version", default=None)
    ap.add_argument("--approach", default=None, help="retrieval / RAG / dump / multi-agent / ...")
    ap.add_argument("--submitted-by", default=None)
    ap.add_argument("--adapter-file", default=None,
                    help="path to your adapter (defaults to harness/adapters/<adapter>.py)")
    args = ap.parse_args()

    d = json.load(open(args.results))
    summary = d.get("summary", {})
    adapter = summary.get("adapter")
    if not adapter or "results" not in d:
        sys.exit("not a heron results file (need summary.adapter + results[])")
    if summary.get("n") != 100:
        sys.stderr.write(f"warning: n={summary.get('n')}, not the full 100-question suite "
                         f"— incomplete submissions are rejected by CI.\n")

    folder = os.path.join(ROOT, "submissions", adapter)
    os.makedirs(folder, exist_ok=True)
    json.dump({"summary": summary, "results": d["results"]},
              open(os.path.join(folder, "results.json"), "w"), indent=2, default=str)
    meta = {"tool": args.tool, "adapter": adapter, "repo": args.repo,
            "version": args.version, "approach": args.approach,
            "submitted_by": args.submitted_by}
    json.dump({k: v for k, v in meta.items() if v is not None},
              open(os.path.join(folder, "meta.json"), "w"), indent=2)

    src = args.adapter_file or os.path.join(ROOT, "harness", "adapters", f"{adapter.replace('-', '_')}.py")
    if os.path.exists(src):
        shutil.copy(src, os.path.join(folder, "adapter.py"))
        adapter_note = f"adapter.py (from {os.path.relpath(src, ROOT)})"
    else:
        adapter_note = "adapter.py MISSING — pass --adapter-file <path> or copy it in manually"

    print(f"wrote submissions/{adapter}/  (results.json + meta.json + {adapter_note})")
    print(f"  tool={args.tool!r} model={summary.get('model')} questions={len(d['results'])}")
    print("Commit the whole submissions/<adapter>/ folder and open a PR (template: add-a-tool). "
          "Do NOT edit leaderboard.svg/json/csv — the bot regenerates them.")


if __name__ == "__main__":
    main()
