#!/usr/bin/env python3
"""Score a community submission by RE-RUNNING its SQL — the genuineness engine.

  python harness/score_submission.py --dsn <conninfo> submissions/<tool>.json

A submission is a tool's per-question output (see submissions/README.md). We do **not**
trust the metrics in it. For every question we take the submitter's `pred_sql`, execute it
against the freshly-seeded gold database *we* control, and recompute EX / VES / Soft-F1 /
Set-Recall / errors / timing from scratch. The number that reaches the leaderboard is the one
we derived — so accuracy cannot be faked. Only token counts are self-reported (they require the
actual model run); the committed adapter makes them auditable, and they're labeled as such.

Exit status is non-zero if the submission is invalid (incomplete coverage, wrong model,
non-SELECT SQL) or looks tampered (claimed EX materially exceeds what its own SQL reproduces).
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import psycopg

from harness.run import execute, pct, avg          # reuse the exact min-of-5 executor + helpers
from harness.comparator import has_order_by, result_eq, soft_f1, ves_reward
from harness.usage_meter import cost_usd
from questions.schema import load_all

REQUIRED_MODEL = "openai/gpt-4o"     # the same-model control; other models aren't comparable here
INFLATION_TOLERANCE = 2.0            # claimed EX may exceed verified by at most this many points


def score(submission: dict, conn) -> tuple[dict, list[str]]:
    """Re-execute the submission's SQL and recompute every metric. Returns
    (verified_summary, issues). `issues` non-empty => the submission should be rejected."""
    issues: list[str] = []
    claimed = submission.get("summary", {}) or {}
    rows_in = submission.get("results", []) or []
    by_id = {r.get("id"): r for r in rows_in if isinstance(r, dict)}

    qs = load_all()
    qids = {q.id for q in qs}
    missing = sorted(qid for qid in qids if qid not in by_id)
    extra = sorted(i for i in by_id if i not in qids)
    if missing:
        issues.append(f"incomplete: missing {len(missing)} questions (e.g. {missing[:5]})")
    if extra:
        issues.append(f"unknown question ids: {extra[:5]}")

    model = claimed.get("model") or submission.get("model")
    if model and model.replace("openai/", "") != REQUIRED_MODEL.replace("openai/", ""):
        issues.append(f"model is {model!r}; the leaderboard requires {REQUIRED_MODEL} "
                      f"(same-model control). Other models belong in an open track.")

    out = []
    for q in qs:
        sub = by_id.get(q.id) or {}
        pred_sql = sub.get("pred_sql")
        gold_rows, gerr, gold_ms = execute(conn, q.gold_sql)
        order = has_order_by(q.gold_sql)
        if pred_sql:
            pred_rows, perr, exec_ms = execute(conn, pred_sql)   # rejects DML => counts as error
        else:
            pred_rows, perr, exec_ms = None, (sub.get("error") or "no pred_sql"), 0.0
        ex = None if gerr else result_eq(gold_rows, pred_rows, order)
        sf1 = None if gerr else round(soft_f1(gold_rows, pred_rows, order), 3)
        ves = None if gerr else round(ves_reward(bool(ex), gold_ms, exec_ms), 3)
        # Set-Recall: re-derived from the submitted retrieved-table set when present;
        # falls back to the self-reported boolean only for pre-pred_tables baselines.
        ptables = sub.get("pred_tables")
        if ptables is not None:
            setrec = set(q.gold_tables) <= set(ptables)
        else:
            setrec = sub.get("set_recall")
        ptok, ctok = sub.get("prompt_tokens"), sub.get("completion_tokens")
        toks = (ptok or 0) + (ctok or 0) if (ptok is not None or ctok is not None) else None
        out.append(dict(id=q.id, ex=ex, soft_f1=sf1, ves=ves, set_recall=setrec,
                        sql_shape=q.sql_shape, retrieval=q.retrieval,
                        exec_ms=round(exec_ms, 1), gold_exec_ms=round(gold_ms, 1),
                        prompt_tokens=ptok, completion_tokens=ctok, tokens=toks,
                        pred_sql=pred_sql, error=perr or gerr))

    # ---- aggregate the VERIFIED numbers ----
    ex_all = pct([r["ex"] for r in out])
    setr_all = pct([r["set_recall"] for r in out])
    ves_vals = [r["ves"] for r in out if r["ves"] is not None]
    ves_all = round(100 * sum(ves_vals) / len(ves_vals), 1) if ves_vals else None
    sf1_vals = [r["soft_f1"] for r in out if r["soft_f1"] is not None]
    sf1_all = round(100 * sum(sf1_vals) / len(sf1_vals), 1) if sf1_vals else None
    by_shape = {s: pct([r["ex"] for r in out if r["sql_shape"] == s])
                for s in ("single", "join", "multi-join", "analytical")}
    by_retr = {s: pct([r["ex"] for r in out if r["retrieval"] == s])
               for s in ("named", "1-hop", "2-hop+", "lexical-gap")}
    # gen latency is self-reported (the model call on the submitter's machine); exec is re-timed here
    avg_gen = avg([(by_id.get(r["id"]) or {}).get("gen_ms") for r in out])
    avg_exec = avg([r["exec_ms"] for r in out])
    avg_total = round((avg_gen or 0) + (avg_exec or 0), 1)
    errs = sum(1 for r in out if r.get("error"))
    tok_rows = [r["tokens"] for r in out if r["tokens"] is not None]
    total_prompt = sum(r["prompt_tokens"] or 0 for r in out if r["prompt_tokens"] is not None)
    total_completion = sum(r["completion_tokens"] or 0 for r in out if r["completion_tokens"] is not None)

    verified = dict(
        adapter=claimed.get("adapter") or submission.get("adapter"),
        tool=submission.get("tool") or claimed.get("adapter"),
        model=model, n=len(out), errors=errs,
        ex_at_1=ex_all, ves=ves_all, soft_f1=sf1_all, set_recall=setr_all,
        ex_by_shape=by_shape, ex_by_retrieval=by_retr,
        avg_gen_ms=avg_gen, avg_exec_ms=avg_exec, avg_total_ms=avg_total,
        avg_tokens=round(sum(tok_rows) / len(tok_rows), 1) if tok_rows else None,
        total_tokens=sum(tok_rows) if tok_rows else None,
        token_coverage=f"{len(tok_rows)}/{len(out)}",
        prompt_tokens=total_prompt, completion_tokens=total_completion,
        est_cost_usd=round(cost_usd(total_prompt, total_completion, model), 4),
        token_source="self-reported (re-runnable via the committed adapter)",
        verified=True, verifier="harness/score_submission.py",
    )

    # ---- anti-tamper: claimed EX must not materially exceed what its own SQL reproduces ----
    claimed_ex = claimed.get("ex_at_1")
    if claimed_ex is not None and ex_all is not None and claimed_ex - ex_all > INFLATION_TOLERANCE:
        issues.append(f"claimed EX@1 {claimed_ex} but the submitted SQL only reproduces {ex_all} "
                      f"(> {INFLATION_TOLERANCE}pt gap) — results look inflated or stale.")
    if tok_rows and total_prompt == 0:
        issues.append("token counts are all zero for an LLM tool — include real `response.usage`.")
    return verified, issues


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("submission", help="path to submissions/<tool>.json")
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--out", help="write the verified result JSON here")
    args = ap.parse_args()

    with open(args.submission) as f:
        submission = json.load(f)
    with psycopg.connect(args.dsn) as conn:
        verified, issues = score(submission, conn)

    s = verified
    print("\n" + "=" * 60)
    print(f"VERIFIED  {s['tool']} ({s['adapter']})  model={s['model']}  n={s['n']}")
    print(f"  EX@1 {s['ex_at_1']}  VES {s['ves']}  Soft-F1 {s['soft_f1']}  "
          f"Set-Recall {s['set_recall']}  errors {s['errors']}")
    print(f"  tokens/q {s['avg_tokens']} (self-reported)  est ${s['est_cost_usd']}/run")
    print("=" * 60)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(dict(summary=verified, results=submission.get("results", [])), f,
                      indent=2, default=str)
        sys.stderr.write(f"wrote {args.out}\n")
    if issues:
        sys.stderr.write("\nSUBMISSION REJECTED:\n  - " + "\n  - ".join(issues) + "\n")
        sys.exit(1)
    sys.stderr.write("\nSubmission OK — verified numbers above will be used on the leaderboard.\n")


if __name__ == "__main__":
    main()
