#!/usr/bin/env python3
"""Regenerate the leaderboard from the submission folders — no manual editing.

  python harness/build_leaderboard.py --dsn <conninfo>

Scores every `submissions/<tool>/results.json` by re-running its SQL
(harness/score_submission.score), ranks by the 0-100 Grade, and writes three outputs that are
all pure functions of the committed submissions:

  leaderboard.json   the master per-tool record (the accumulator)
  leaderboard.csv    flat table for spreadsheets / scripts
  leaderboard.svg    the visual table embedded at the top of README.md (GitHub renders SVG)

The CI `update-leaderboard` job runs this on every push to main and commits the three files,
so the published leaderboard always reflects the committed submissions and is never hand-edited.
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import psycopg

from harness.grade import compute as compute_grades
from harness.score_submission import score, load_submission

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ------------------------------------------------------------------ SVG renderer
COLS = [   # (header, key, width, align, fmt)
    ("#", "rank", 44, "mid", lambda v: str(v)),
    ("Tool", "tool", 168, "left", lambda v: v),
    ("Grade", "grade", 86, "mid", lambda v: f"{v:.1f}" if v is not None else "—"),
    ("EX@1", "ex_at_1", 74, "mid", lambda v: f"{v:.1f}" if v is not None else "—"),
    ("VES", "ves", 70, "mid", lambda v: f"{v:.1f}" if v is not None else "—"),
    ("Set-Recall", "set_recall", 96, "mid", lambda v: f"{v:.0f}" if v is not None else "n/a"),
    ("tok/q", "avg_tokens", 84, "mid", lambda v: f"{v:,.0f}" if v else "—"),
    ("$/run", "est_cost_usd", 72, "mid", lambda v: f"${v:.2f}" if v is not None else "—"),
    ("err", "errors", 50, "mid", lambda v: str(v)),
]
ROW_H, HEAD_H, TITLE_H, FOOTER_H, PAD = 34, 36, 52, 30, 1


def _esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _grade_fill(g):
    if g is None:
        return "#9ca3af"
    hue = max(0, min(120, g * 1.25))          # 0 → red, 100 → green
    return f"hsl({hue:.0f},62%,42%)"


def render_svg(rows) -> str:
    W = sum(c[2] for c in COLS) + 2 * PAD
    H = TITLE_H + HEAD_H + ROW_H * len(rows) + FOOTER_H
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}" font-family="-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif">',
           f'<rect width="{W}" height="{H}" fill="#ffffff"/>']
    # title
    out.append(f'<text x="{PAD+14}" y="32" font-size="19" font-weight="700" fill="#111827">'
               f'heron leaderboard <tspan font-weight="400" fill="#6b7280" font-size="13">'
               f'· NL→SQL on 211 tables · 100 questions · same gpt-4o</tspan></text>')
    # header
    y0 = TITLE_H
    out.append(f'<rect x="{PAD}" y="{y0}" width="{W-2*PAD}" height="{HEAD_H}" fill="#111827"/>')
    x = PAD
    for hdr, key, w, align, _ in COLS:
        tx = x + (w // 2 if align == "mid" else 12)
        anchor = "middle" if align == "mid" else "start"
        out.append(f'<text x="{tx}" y="{y0+23}" font-size="12.5" font-weight="600" '
                   f'fill="#e5e7eb" text-anchor="{anchor}">{_esc(hdr)}</text>')
        x += w
    # rows
    for i, r in enumerate(rows):
        y = y0 + HEAD_H + i * ROW_H
        bg = "#ffffff" if i % 2 else "#f6f7f9"
        out.append(f'<rect x="{PAD}" y="{y}" width="{W-2*PAD}" height="{ROW_H}" fill="{bg}"/>')
        x = PAD
        for hdr, key, w, align, fmt in COLS:
            val = r["grade"] if key == "grade" else (r.get("errs") if key == "errors"
                                                     else r["summary"].get(key))
            txt = fmt(val)
            tx = x + (w // 2 if align == "mid" else 12)
            anchor = "middle" if align == "mid" else "start"
            if key == "grade":   # colored grade pill
                pw, ph = 58, 22
                out.append(f'<rect x="{x+(w-pw)//2}" y="{y+(ROW_H-ph)//2}" width="{pw}" height="{ph}" '
                           f'rx="5" fill="{_grade_fill(val)}"/>')
                out.append(f'<text x="{tx}" y="{y+22}" font-size="13" font-weight="700" '
                           f'fill="#ffffff" text-anchor="middle">{_esc(txt)}</text>')
            else:
                weight = "700" if (key == "tool" and i == 0) else ("600" if key == "tool" else "400")
                fill = "#111827" if key == "tool" else "#374151"
                mono = "" if key == "tool" else ' font-family="ui-monospace,SFMono-Regular,Menlo,monospace"'
                out.append(f'<text x="{tx}" y="{y+22}" font-size="12.5" font-weight="{weight}" '
                           f'fill="{fill}" text-anchor="{anchor}"{mono}>{_esc(txt)}</text>')
            x += w
    out.append(f'<text x="{PAD+14}" y="{H-5}" font-size="10.5" fill="#9ca3af">'
               f'Grade = .45·EX + .20·VES + .10·reliability + .15·tokens + .10·latency · '
               f'EX/VES/Set-Recall recomputed by CI from each tool’s SQL · auto-generated</text>')
    out.append('</svg>')
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    args = ap.parse_args()

    dirs = sorted(d for d in glob.glob(os.path.join(ROOT, "submissions", "*"))
                  if os.path.isdir(d) and os.path.exists(os.path.join(d, "results.json")))
    rows, rejected = [], []
    with psycopg.connect(args.dsn) as conn:
        for d in dirs:
            sub = load_submission(d)
            verified, issues = score(sub, conn)
            meta = json.load(open(os.path.join(d, "meta.json"))) if os.path.exists(
                os.path.join(d, "meta.json")) else {}
            verified.update({k: meta[k] for k in ("repo", "version", "approach") if k in meta})
            name = verified.get("tool") or verified.get("adapter") or os.path.basename(d)
            if issues:
                rejected.append((name, issues[0]))
                sys.stderr.write(f"skip {name}: {issues[0]}\n")
                continue
            rows.append(dict(name=name, summary=verified,
                             errs=verified.get("errors", 0), n=verified.get("n")))
    compute_grades(rows)   # attaches grade + dims, sorts by grade

    # master JSON (the accumulator)
    master = {"benchmark": "heron", "model": "openai/gpt-4o", "n_questions": 100,
              "scale": "small", "tools": [], "rejected": [dict(tool=n, reason=r) for n, r in rejected]}
    for i, r in enumerate(rows, 1):
        r["summary"]["rank"] = i
        master["tools"].append(dict(grade=r["grade"], **r["summary"]))
    json.dump(master, open(os.path.join(ROOT, "leaderboard.json"), "w"), indent=2, default=str)

    # CSV
    fields = ["rank", "tool", "grade", "ex_at_1", "ves", "soft_f1", "set_recall",
              "avg_total_ms", "avg_tokens", "est_cost_usd", "errors", "model", "version"]
    with open(os.path.join(ROOT, "leaderboard.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for t in master["tools"]:
            w.writerow(t)

    # SVG (for README)
    svg_rows = [dict(grade=r["grade"], errs=r["errs"],
                     summary={**r["summary"], "rank": r["summary"]["rank"]}) for r in rows]
    open(os.path.join(ROOT, "leaderboard.svg"), "w").write(render_svg(svg_rows))

    sys.stderr.write(f"wrote leaderboard.json / .csv / .svg ({len(rows)} tools, "
                     f"{len(rejected)} rejected)\n")


if __name__ == "__main__":
    main()
