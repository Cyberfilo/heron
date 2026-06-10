#!/usr/bin/env python3
"""heron runner: score a system (adapter) by execution-equality + retrieval recall.

  python harness/run.py --dsn <conninfo> --adapter gold
  python harness/run.py --dsn <conninfo> --adapter raw-llm --model gpt-4o

Reports multi-axis EX (overall + per difficulty bucket) and, for adapters that expose a
retrieved-table set, Set-Recall@k. See docs/METHODOLOGY.md.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import psycopg

from harness.adapters import get_adapter
from harness.comparator import has_order_by, result_eq, soft_f1, ves_reward
from harness.schema_text import render_schema
from harness import usage_meter
from questions.schema import load_all

usage_meter.install()   # capture OpenAI's real billed token usage for every adapter

DML = ("insert", "update", "delete", "drop", "alter", "create", "truncate", "grant", "merge")


TIMING_REPS = 5          # repeat timing runs and take the MIN (least scheduling noise)
TIMING_CAP_MS = 5000     # don't repeat-time queries already slower than this (cost control)


def _run_once(conn, sql, timeout_ms):
    t = time.time()
    with conn.cursor() as cur:
        cur.execute(f"SET LOCAL statement_timeout = {timeout_ms}")
        cur.execute(sql)
        rows = cur.fetchall()
    conn.rollback()
    return rows, (time.time() - t) * 1000


def execute(conn, sql, timeout_ms=30000, reps=TIMING_REPS):
    """Run SQL; return (rows, err, min_elapsed_ms).

    For a stable efficiency signal the query is run once to warm caches (its time is
    discarded), then `reps` more times with the MINIMUM kept — the minimum is the run
    least perturbed by OS scheduling, which is what BIRD's repeat-and-take-best targets.
    Queries already slower than TIMING_CAP_MS are measured once (no point re-running).
    """
    low = sql.lstrip().lower()
    if any(low.startswith(k) for k in DML):
        return None, "rejected: not a SELECT", 0.0
    try:
        rows, warm_ms = _run_once(conn, sql, timeout_ms)        # warm-up (discarded)
        if reps <= 1 or warm_ms > TIMING_CAP_MS:
            return rows, None, warm_ms
        best = warm_ms
        for _ in range(reps):
            _, ms = _run_once(conn, sql, timeout_ms)
            best = min(best, ms)
        return rows, None, best
    except Exception as e:  # noqa: BLE001
        conn.rollback()
        return None, str(e).splitlines()[0][:200], 0.0


def pct(xs):
    xs = [x for x in xs if x is not None]
    return round(100 * sum(xs) / len(xs), 1) if xs else None


def avg(xs):
    xs = [x for x in xs if x is not None]
    return round(sum(xs) / len(xs), 1) if xs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--model", default=None)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--from-id", default=None, help="only run questions with id >= this (e.g. q041)")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    qs = load_all()
    if args.from_id:
        qs = [q for q in qs if q.id >= args.from_id]
    if args.limit:
        qs = qs[: args.limit]
    adapter = get_adapter(args.adapter)

    with psycopg.connect(args.dsn) as conn:
        ctx = {"dsn": args.dsn, "model": args.model}
        if adapter.name == "raw-llm":
            sys.stderr.write("rendering full schema for the naive baseline...\n")
            ctx["schema_text"] = render_schema(conn)

        results = []
        for q in qs:
            gold_rows, gerr, gold_ms = execute(conn, q.gold_sql)
            order = has_order_by(q.gold_sql)
            usage_meter.reset()
            t0 = time.time()
            pred = adapter.predict(q, ctx)
            gen_ms = round((time.time() - t0) * 1000, 1)   # NL->SQL generation time
            m_pt, m_ct, m_calls = usage_meter.totals()      # real OpenAI billed usage
            pred_rows, perr, exec_ms = (None, pred.error, 0.0)
            if pred.sql and perr is None:
                pred_rows, perr, exec_ms = execute(conn, pred.sql)
            ex = None if gerr else result_eq(gold_rows, pred_rows, order)
            sf1 = None if gerr else round(soft_f1(gold_rows, pred_rows, order), 3)
            ves = None if gerr else round(ves_reward(bool(ex), gold_ms, exec_ms), 3)
            setrec = None if pred.tables is None else (set(q.gold_tables) <= set(pred.tables))
            # authoritative tokens = OpenAI's billed usage (meter); fall back to whatever
            # the adapter self-reported only if no OpenAI call was observed this question.
            if m_calls:
                ptok, ctok = m_pt, m_ct
            else:
                ptok, ctok = pred.prompt_tokens, pred.completion_tokens
            toks = (ptok or 0) + (ctok or 0) if (ptok is not None or ctok is not None) else None
            results.append(dict(id=q.id, ex=ex, soft_f1=sf1, ves=ves, set_recall=setrec,
                                sql_shape=q.sql_shape,
                                retrieval=q.retrieval, tags=list(q.tags),
                                gen_ms=gen_ms, exec_ms=round(exec_ms, 1),
                                gold_exec_ms=round(gold_ms, 1),
                                prompt_tokens=ptok, completion_tokens=ctok, tokens=toks,
                                pred_sql=pred.sql, error=perr or gerr))
            mark = "ok " if ex else ("·  " if ex is None else "X  ")
            sys.stderr.write(f"  {mark}{q.id} EX={ex} setR={setrec} {gen_ms}ms {q.sql_shape}\n")

    # ---- aggregate ----
    ex_all = pct([r["ex"] for r in results])
    setr_all = pct([r["set_recall"] for r in results])
    # VES: 100 * mean reward over questions with a valid (executable) gold
    ves_vals = [r["ves"] for r in results if r["ves"] is not None]
    ves_all = round(100 * sum(ves_vals) / len(ves_vals), 1) if ves_vals else None
    sf1_vals = [r["soft_f1"] for r in results if r["soft_f1"] is not None]
    soft_f1_all = round(100 * sum(sf1_vals) / len(sf1_vals), 1) if sf1_vals else None
    by_shape = {s: pct([r["ex"] for r in results if r["sql_shape"] == s])
                for s in ("single", "join", "multi-join", "analytical")}
    by_retr = {s: pct([r["ex"] for r in results if r["retrieval"] == s])
               for s in ("named", "1-hop", "2-hop+", "lexical-gap")}

    avg_gen = avg([r["gen_ms"] for r in results])
    avg_exec = avg([r["exec_ms"] for r in results])
    avg_total = avg([(r["gen_ms"] or 0) + (r["exec_ms"] or 0) for r in results])
    avg_gold_exec = avg([r["gold_exec_ms"] for r in results])
    tok_rows = [r["tokens"] for r in results if r["tokens"] is not None]
    total_tokens = sum(tok_rows) if tok_rows else None
    avg_tokens = round(sum(tok_rows) / len(tok_rows), 1) if tok_rows else None
    token_cov = f"{len(tok_rows)}/{len(results)}"
    total_prompt = sum(r["prompt_tokens"] or 0 for r in results if r["prompt_tokens"] is not None)
    total_completion = sum(r["completion_tokens"] or 0 for r in results if r["completion_tokens"] is not None)
    est_cost = round(usage_meter.cost_usd(total_prompt, total_completion, args.model), 4)

    summary = dict(adapter=adapter.name, model=args.model, n=len(results),
                   ex_at_1=ex_all, ves=ves_all, soft_f1=soft_f1_all, set_recall=setr_all,
                   ex_by_shape=by_shape, ex_by_retrieval=by_retr,
                   avg_gen_ms=avg_gen, avg_exec_ms=avg_exec, avg_total_ms=avg_total,
                   avg_gold_exec_ms=avg_gold_exec,
                   prompt_tokens=total_prompt, completion_tokens=total_completion,
                   est_cost_usd=est_cost,
                   avg_tokens=avg_tokens, total_tokens=total_tokens, token_coverage=token_cov)
    print("\n" + "=" * 60)
    print(f"heron  adapter={adapter.name} model={args.model or '-'}  n={len(results)}")
    print(f"  Execution Accuracy (EX@1):  {ex_all}%")
    print(f"  Valid Efficiency (VES):     {ves_all}   (100 = parity with gold; >100 faster)")
    print(f"  Soft-F1 (row-set):          {soft_f1_all}%")
    print("  Retrieval Set-Recall:       " +
          (f"{setr_all}%" if setr_all is not None else "n/a (end-to-end)"))
    print(f"  Avg gen time/q:   {avg_gen} ms   | avg pred-SQL exec: {avg_exec} ms | "
          f"avg total/q: {avg_total} ms (gold exec {avg_gold_exec} ms)")
    print(f"  Avg tokens/q:     {avg_tokens}   | total tokens: {total_tokens} "
          f"(coverage {token_cov})")
    print(f"  Est. API cost:    ${est_cost}   ({total_prompt:,} in + {total_completion:,} out "
          f"@ {args.model or 'gpt-4o'} prices)")
    print(f"  EX by SQL shape:   {by_shape}")
    print(f"  EX by retrieval:   {by_retr}")
    print("=" * 60)

    out = args.out or f"results_{adapter.name}.json"
    with open(out, "w") as f:
        json.dump(dict(summary=summary, results=results), f, indent=2, default=str)
    sys.stderr.write(f"wrote {out}\n")

    # append to a cumulative cost ledger so session spend is auditable across runs
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ledger = os.path.join(root, "api_costs.tsv")
    new = not os.path.exists(ledger)
    with open(ledger, "a") as cf:
        if new:
            cf.write("timestamp\tadapter\tmodel\tn\tprompt_tokens\tcompletion_tokens\tusd\n")
        cf.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\t{adapter.name}\t{args.model or 'gpt-4o'}"
                 f"\t{len(results)}\t{total_prompt}\t{total_completion}\t{est_cost}\n")
    sys.stderr.write(f"cost ${est_cost} appended to {ledger}\n")


if __name__ == "__main__":
    main()
