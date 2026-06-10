#!/usr/bin/env python3
"""heron Grade — one 0–100 number per tool, from the data the harness records.

  python harness/grade.py --label "PromptQuery=results_prq_v1.json" "raw-llm=results_raw_v1.json" ...

The grade is a transparent weighted blend of five sub-scores, each on 0–100:

  EX   correctness   — Execution Accuracy (ex_at_1). The thing that matters most.
  EFF  efficiency    — VES capped at 100 (matching the hand-written gold query's
                       speed is full marks; a correct-but-slow query is penalized).
  REL  reliability   — 100·(1 − errors/n): how often it runs at all.
  TOK  token economy — 100·(min_tok_in_field / tok), capped 100: the most
                       token-frugal tool anchors 100; a tool that sends 7× more scores ~14.
  LAT  latency       — 100·(min_total_ms_in_field / total_ms), capped 100: fastest anchors 100.

        grade = Σ wᵢ·dimᵢ / Σ wᵢ   (over the dims a tool actually exposes)

Weights (EX dominates by design; economy/efficiency together are a third):
  EX .45 · EFF .20 · REL .10 · TOK .15 · LAT .10

TOK/LAT are field-relative (anchored to the best tool present), so the grade
compares tools *to each other* on this run; it is not an absolute score. Set-Recall
is shown alongside but is NOT in the grade — end-to-end tools don't expose it, and
penalizing them for an n/a dimension would be unfair. EFF/TOK/LAT are dropped (and
their weight redistributed) for any tool that doesn't expose them.
"""
from __future__ import annotations

import argparse
import json
import sys

WEIGHTS = {"ex": 0.45, "eff": 0.20, "rel": 0.10, "tok": 0.15, "lat": 0.10}


def load(path):
    with open(path) as f:
        d = json.load(f)
    s = d.get("summary", {})
    res = d.get("results", [])
    errs = sum(1 for r in res if r.get("error"))
    return s, errs, len(res)


def field_mins(rows):
    """Min avg_tokens and avg_total_ms across the tools that expose them (anchors)."""
    toks = [r["summary"].get("avg_tokens") for r in rows if r["summary"].get("avg_tokens")]
    lats = [r["summary"].get("avg_total_ms") for r in rows if r["summary"].get("avg_total_ms")]
    return (min(toks) if toks else None), (min(lats) if lats else None)


def dims(summary, errs, n, min_tok, min_lat):
    ex = summary.get("ex_at_1")
    ves = summary.get("ves")
    tok = summary.get("avg_tokens")
    lat = summary.get("avg_total_ms")
    return {
        "ex": ex,
        "eff": None if ves is None else min(100.0, ves),
        "rel": None if not n else round(100.0 * (1 - errs / n), 1),
        "tok": None if (not tok or not min_tok) else min(100.0, 100.0 * min_tok / tok),
        "lat": None if (not lat or not min_lat) else min(100.0, 100.0 * min_lat / lat),
    }


def grade(dim: dict) -> float | None:
    num = den = 0.0
    for k, w in WEIGHTS.items():
        v = dim.get(k)
        if v is None:
            continue
        num += w * v
        den += w
    return round(num / den, 1) if den else None


def compute(rows):
    """rows: list of {name, summary, errs, n}. Returns same rows with grade + dims, sorted."""
    min_tok, min_lat = field_mins(rows)
    for r in rows:
        r["dims"] = dims(r["summary"], r["errs"], r["n"], min_tok, min_lat)
        r["grade"] = grade(r["dims"])
    rows.sort(key=lambda r: (-(r["grade"] or -1)))
    return rows


def _c(v):
    return "n/a" if v is None else (f"{v:.1f}" if isinstance(v, float) else f"{v}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--label", nargs="*", default=[])
    args = ap.parse_args()
    items = []
    for spec in args.label:
        name, _, path = spec.partition("=")
        items.append((name, path))
    for p in args.files:
        items.append((None, p))

    rows = []
    for name, path in items:
        try:
            s, errs, n = load(path)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"skip {path}: {e}\n")
            continue
        if s.get("adapter") == "gold":          # gold is the reference, not a competitor
            continue
        rows.append(dict(name=name or s.get("adapter", path), summary=s, errs=errs, n=n))
    compute(rows)

    print("| Rank | Tool | Grade | EX | EFF(VES) | REL | TOK | LAT | Set-Recall |")
    print("|---:|---|---:|---:|---:|---:|---:|---:|---:|")
    for i, r in enumerate(rows, 1):
        d = r["dims"]
        sr = r["summary"].get("set_recall")
        print(f"| {i} | {r['name']} | **{_c(r['grade'])}** | {_c(d['ex'])} | {_c(d['eff'])} | "
              f"{_c(d['rel'])} | {_c(d['tok'])} | {_c(d['lat'])} | "
              f"{('n/a' if sr is None else str(sr))} |")
    print(f"\n_Grade = .45·EX + .20·EFF + .10·REL + .15·TOK + .10·LAT (renormalized over exposed "
          f"dims). EFF=min(100,VES); TOK/LAT anchored to the most efficient tool in this field. "
          f"Set-Recall shown but not graded._")


if __name__ == "__main__":
    main()
