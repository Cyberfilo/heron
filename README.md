# heron — a production-scale NL→SQL benchmark

**The text-to-SQL benchmark that runs on a database shaped like production:** one
multi-tenant SaaS commerce schema, **211 FK-linked tables across 14 domains**, seeded
deterministically with **millions of rows** of skewed, dirty-but-valid data, and a graded suite
of natural-language questions with **gold SQL scored by execution-equality** — and a first-class
**schema-retrieval-at-scale** axis: *can the system find the right handful of tables among hundreds?*

> **Status: v1.** 211 tables · 575 FKs · deterministic generator (4.4M rows / 233 MB dump at
> `small`; **87.8M rows / 4.6 GB at `bench`**) · **100 audited gold questions** · execution-equality
> harness (ported Spider comparator) plus **VES efficiency, Soft-F1, a 0–100 Grade, and exact
> OpenAI-billed token/cost accounting** · **6 tools benchmarked** — PromptQuery, Vanna, raw-gpt-4o,
> LangChain, and the [NL2SQL-Handbook](https://github.com/HKUSTDial/NL2SQL_Handbook) methods MAC-SQL
> & DIN-SQL. Leaderboard below.

---

## Why another NL→SQL benchmark?

The field is strong, and we stand on its shoulders. We are **not** claiming to be the first hard
schema, the first to isolate table-retrieval, or the first Postgres benchmark — prior work already
does each of those, and we say so plainly. (Full landscape with sizes, leaderboard numbers, and
citations: [`docs/RELATED-WORK.md`](docs/RELATED-WORK.md).)

| Benchmark | Tables / schema | Dialect | Locally reproducible? | One coherent schema? | Multi-tenant SaaS? | Retrieval isolated? |
|---|---|---|---|---|---|---|
| Spider 1.0 | ~5 | SQLite | yes | no (200 dbs) | no | no |
| BIRD | ~7 | SQLite/MySQL/PG | yes | no (95 dbs) | no | no |
| Spider 2.0 | ~53 (≤1–3K cols) | **BigQuery/Snowflake** | **no — cloud account** | no (many dbs) | no | bundled |
| LiveSQLBench-Large | ~54 | PostgreSQL | yes | no (18 dbs) | no | no |
| **BEAVER** | **~101** | **Oracle/MySQL** | **no — private warehouses** | no (3 warehouses) | no | **yes (table-F1)** |
| **heron** | **~220 in ONE schema** | **PostgreSQL 16 (local)** | **yes — `pg_dump` + seed** | **yes (14 domains)** | **yes (`tenant_id`)** | **yes (set-recall@k)** |

The niche that is genuinely empty (one sentence): **no existing benchmark is simultaneously a
single coherent FK-linked multi-tenant SaaS Postgres schema of ~220 tables, fully open and
*rebuildable from a deterministic seeded generator + a compressed dump on a laptop* — no cloud
warehouse, no private data, no account — seeded to millions of rows, with schema-retrieval-at-scale
("find the right ~5 tables among ~220") measured as a first-class, isolatable axis on that one
schema.** Spider 2.0 is cloud-bound; BEAVER's warehouses are private and can't be `pg_restore`d;
LiveSQLBench spreads its scale across 18 separate databases. The intersection is open — that's the
lane. The differentiator is **verifiable reproducibility**, not a difficulty boast (difficulty
saturates fast — Spider 2.0-Snow is already at 96.7%).

## What's in here

```
schema/        DDL for the 14 domain modules (+ CONVENTIONS.md — the design contract)
seed/          deterministic, seeded data generator (scale factors: tiny|small|bench|large)
questions/     100 NL questions + gold SQL + difficulty + must-reference tables
harness/       execution-equality runner, scoring (EX / VES / Soft-F1 / Grade), the OpenAI
               usage+cost meter, and adapters (gold, raw-llm, promptquery, vanna,
               langchain, mac-sql, din-sql)
docs/          RELATED-WORK, METHODOLOGY, LEADERBOARD, CROSS-TOOL-LEADERBOARD
CONTRIBUTING.md   how to add a question or a tool (PR templates in .github/)
docker-compose.yml + Makefile   one-command Postgres + load
```

## Quickstart

```bash
make up                                          # Postgres 16 in Docker
make schema                                      # load the 14-module schema (211 tables)
make seed SCALE=small                            # deterministic data (seed 42)
make verify                                      # referential-integrity + invariants
make bench ADAPTER=gold                          # sanity: 100% EX / 100% Set-Recall
make bench ADAPTER=raw-llm     MODEL=openai/gpt-4o
make bench ADAPTER=promptquery MODEL=openai/gpt-4o   # needs `pip install promptquery`
make bench ADAPTER=mac-sql     MODEL=openai/gpt-4o   # NL2SQL-Handbook multi-agent method
```

To reproduce the exact published database, `make restore` from the frozen dump (a release asset)
instead of regenerating.

## Results (v1)

`small` scale, **100-question suite**, single-state EX@1 @ temp 0, every tool on the **same `gpt-4o`**
(only difference = how each ingests the 211-table DB and selects tables). Ranked by a 0–100 **Grade**;
token counts are OpenAI's **billed `response.usage`** (exact). Full table, per-bucket breakdown,
$/100q cost, and tool cards: [`docs/CROSS-TOOL-LEADERBOARD.md`](docs/CROSS-TOOL-LEADERBOARD.md) ·
headline table: [`docs/LEADERBOARD.md`](docs/LEADERBOARD.md).

| Rank | Tool | Grade | EX@1 | Set-Recall | tok/q | $/100q | errors |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | Vanna (RAG) | **61.9** | 46.0 | 79.0 | 2,000 | $0.53 | 18 |
| 2 | PromptQuery (retrieval) | **59.0** | **58.0** | **98.0** | 4,257 | $1.11 | 7 |
| 3 | raw-gpt-4o (full-schema dump) | 55.5 | 55.0 | n/a | 15,314 | $3.87 | 10 |
| 4 | MAC-SQL (multi-agent) | 46.8 | 49.0 | 90.0 | 15,656 | $4.00 | 3 |
| 5 | DIN-SQL (decomposed) | 46.5 | 52.0 | 90.0 | 16,343 | $4.21 | 6 |
| 6 | LangChain (schema-dump) | 18.0 | 16.0 | n/a | **101,151** | $25.36 | 46 |

**The honest read:** **PromptQuery wins accuracy (58 EX@1) and retrieval (98% Set-Recall — finds
every required table among 211 on all but two questions); Vanna takes the Grade on raw token-economy
and speed** — heron's own namesake tool not topping the Grade is exactly the neutrality the benchmark
claims. The schema-dumpers pay the "no-retrieval tax" in tokens, not accuracy: **LangChain reflects
full DDL for all 211 tables = 101k tokens/question for 16% EX** ($25/100q — 65% of the whole run's
bill). The NL2SQL-Handbook multi-agent methods land mid-pack — more agent steps bought reliability
(MAC-SQL: 3 errors) and recall, not top-line accuracy. Everyone is weak on `analytical` (≤40): that
ceiling is SQL **generation**, not retrieval.

## Principles (non-negotiable, inherited from the project's "honesty is the moat" ethos)

1. **Reproducible or it doesn't count.** Every number traces to a committed question + gold SQL +
   a deterministic database. The harness is open; run it yourself.
2. **Tool-neutral.** This repo depends on no NL→SQL product. PromptQuery is one adapter among
   several, including a raw-LLM baseline and (later) competing tools. See
   [`DECISIONS.md`](DECISIONS.md) §D1.
3. **Failures are published.** Like the parent project, unfavorable results are committed on
   purpose. A leaderboard that only shows wins is marketing, not a benchmark.
4. **Real shape, honest labels.** The data is messy and skewed because production is; the schema
   is inconsistently documented because production is. Difficulty is calibrated and disclosed
   in [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md).

## License

Code: **Apache-2.0** ([`LICENSE`](LICENSE)). Generated data + questions: **CC-BY-4.0**. No
third-party data is redistributed — all data is synthetic and generated locally by `seed/generate.py`.
Attributions and lineage (Spider comparator, BIRD/VES metrics, schema-shape provenance) are in
[`NOTICE`](NOTICE).

## Contributing

heron is tool-neutral by design — **adding your NL→SQL tool is a first-class contribution.** See
[`CONTRIBUTING.md`](CONTRIBUTING.md) and the PR template at
[`.github/PULL_REQUEST_TEMPLATE/add-a-tool.md`](.github/PULL_REQUEST_TEMPLATE/add-a-tool.md). The bar:
same `gpt-4o`, headless `predict()`, and every number reproducible from committed artifacts.
