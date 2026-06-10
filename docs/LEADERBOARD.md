# heron leaderboard — v1 (100 questions, gpt-4o)

The headline table. Every number is reproducible from committed artifacts, and **unfavorable
results are kept on purpose** — a leaderboard that only shows wins is marketing, not a benchmark.
For the per-bucket breakdown, Grade sub-scores, $/100q cost, and the tool-by-tool write-up, see
[`CROSS-TOOL-LEADERBOARD.md`](CROSS-TOOL-LEADERBOARD.md). Scoring spec: [`METHODOLOGY.md`](METHODOLOGY.md).

> **Conditions for every row:** `small` scale (50k orders, ~4.4M rows), **100-question suite**,
> single-state **EX@1 at temperature 0**, comparator per [`METHODOLOGY.md`](METHODOLOGY.md) §1.1.
> Every tool generates SQL with the **same `gpt-4o`** — the only differences are how each ingests a
> 211-table multi-schema DB and how it selects tables. Token counts are OpenAI's billed
> `response.usage` (exact). Multi-state EX (N=3 seeds) and the larger `bench` scale are wired but
> not yet run for these rows.

Ranked by **Grade** (0–100, see [`METHODOLOGY.md`](METHODOLOGY.md) §7). EX@1 is headline accuracy;
VES is correctness-gated efficiency (100 = as fast as the gold query); Soft-F1 is partial-credit
correctness; Set-Recall is `n/a` for end-to-end tools that don't expose a retrieved-table set.

| Rank | Tool | Grade | EX@1 | VES | Soft-F1 | Set-Recall | ms/q | tok/q | errors |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | Vanna | **61.9** | 46.0 | 44.6 | 48.2 | 79.0 | 1,535 | 2,000 | 18 |
| 2 | PromptQuery | **59.0** | 58.0 | 52.0 | 60.2 | 98.0 | 2,265 | 4,257 | 7 |
| 3 | raw-gpt-4o | **55.5** | 55.0 | 49.2 | 56.8 | n/a | 1,399 | 15,314 | 10 |
| 4 | MAC-SQL | **46.8** | 49.0 | 42.2 | 51.7 | 90.0 | 2,967 | 15,656 | 3 |
| 5 | DIN-SQL | **46.5** | 52.0 | 45.5 | 54.9 | 90.0 | 5,124 | 16,343 | 6 |
| 6 | LangChain | **18.0** | 16.0 | 14.8 | 17.9 | n/a | 6,494 | 101,151 | 46 |

_6 systems · Grade = .45·EX + .20·EFF + .10·REL + .15·TOK + .10·LAT (METHODOLOGY §7). Token counts
are OpenAI's billed `response.usage` (exact), captured uniformly for every tool via the harness
usage meter._

## The one-paragraph read

**PromptQuery wins accuracy (58.0 EX@1) and retrieval (98% Set-Recall — finds every required table
among 211 on all but two questions); Vanna takes the Grade on raw token-economy and speed.** The
schema-dumpers (raw-gpt-4o, LangChain) match the field on accuracy at best and pay for it in tokens:
LangChain reflects full DDL for all 211 tables = **101k tokens/question** for **16% EX** — the
"no-retrieval tax" as a dollar figure. The NL2SQL-Handbook multi-agent methods (MAC-SQL, DIN-SQL)
land mid-pack: more agent steps bought reliability (MAC-SQL: 3 errors) and recall (90%), not
top-line accuracy. Everyone is weak on `analytical` (≤40) — that ceiling is SQL **generation**, not
retrieval. Full analysis: [`CROSS-TOOL-LEADERBOARD.md`](CROSS-TOOL-LEADERBOARD.md).

## Reproduce

```bash
make seed SCALE=small SEED=42
make bench ADAPTER=gold                                   # 100/100 sanity
make bench ADAPTER=raw-llm     MODEL=openai/gpt-4o
make bench ADAPTER=promptquery MODEL=openai/gpt-4o        # needs `pip install promptquery`
make bench ADAPTER=vanna       MODEL=openai/gpt-4o        # pin vanna==0.7.9
make bench ADAPTER=mac-sql     MODEL=openai/gpt-4o
make bench ADAPTER=din-sql     MODEL=openai/gpt-4o
# then regenerate this table:
python harness/leaderboard.py --label "raw-gpt-4o=results_raw_v1.json" \
  "PromptQuery=results_prq_v1.json" "Vanna=results_vanna_v1.json" \
  "LangChain=results_langchain_v1.json" "MAC-SQL=results_macsql_v1.json" \
  "DIN-SQL=results_dinsql_v1.json" > docs/LEADERBOARD.md
```

Per-question raw outcomes (the SQL each system generated, errors, elapsed, tokens) are in
`results_<adapter>_v1.json` — diff them to see exactly what each tool did.
