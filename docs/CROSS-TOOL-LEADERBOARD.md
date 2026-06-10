# Cross-tool leaderboard — open-source NL→SQL tools on heron (v1)

**Six open-source NL→SQL tools through the same benchmark, on the same model (OpenAI `gpt-4o`,
temperature 0)**, against heron's production-shaped schema (211 tables / 14 Postgres schemas, `small`
scale = 50k orders / 4.4M rows, **100-question suite**, single-state EX@1). v1 adds: the **two
prompting frameworks from the [NL2SQL Handbook](https://github.com/HKUSTDial/NL2SQL_Handbook)**
(MAC-SQL, DIN-SQL), a **0–100 Grade**, a correctness-gated **efficiency score (VES)**, **Soft-F1**,
and **exact OpenAI-billed token counts** (no estimates). Full tool survey + integration notes:
[`TOOLS-SURVEY.md`](TOOLS-SURVEY.md); scoring spec: [`METHODOLOGY.md`](METHODOLOGY.md).

> Why this is fair: every tool generates SQL with the *same* gpt-4o; the only differences are
> **how each ingests a 211-table multi-schema DB** and **how it selects tables before generating**.
> That's exactly what we want to isolate. Unfavorable results are kept on purpose — including that
> heron's own namesake tool does **not** top the Grade.

## Results — v1 (100 questions, gpt-4o, exact tokens + Grade)

All six tools run the **same 100 questions** on gpt-4o (temp 0). Ranked by **Grade** (0–100,
[METHODOLOGY §7](METHODOLOGY.md)); EX@1 is the headline accuracy, VES is correctness-gated efficiency
(100 = as fast as the hand-written gold query), `$/100q` is the real OpenAI bill for one full run.

| Rank | Tool | Grade | EX@1 | VES | Soft-F1 | Set-Recall | ms/q | tok/q | $/100q | errors |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | **Vanna 0.7.9** (RAG) | **61.9** | 46.0 | 44.6 | 48.2 | 79.0 | 1,535 | **2,000** | **$0.53** | 18 |
| 2 | **PromptQuery** (retrieval) | **59.0** | **58.0** | **52.0** | **60.2** | **98.0** | 2,265 | 4,257 | $1.11 | 7 |
| 3 | raw-gpt-4o (full-schema dump) | 55.5 | 55.0 | 49.2 | 56.8 | n/a | **1,399** | 15,314 | $3.87 | 10 |
| 4 | MAC-SQL (multi-agent) | 46.8 | 49.0 | 42.2 | 51.7 | 90.0 | 2,967 | 15,656 | $4.00 | **3** |
| 5 | DIN-SQL (decomposed) | 46.5 | 52.0 | 45.5 | 54.9 | 90.0 | 5,124 | 16,343 | $4.21 | 6 |
| 6 | LangChain (schema-dump) | 18.0 | 16.0 | 14.8 | 17.9 | n/a | 6,494 | **101,151** | **$25.36** | 46 |

_Grade = .45·EX + .20·EFF + .10·REL(1−err) + .15·TOK + .10·LAT, renormalized over exposed dims;
EFF = min(100, VES); TOK/LAT anchored to the most efficient tool in the field. Tokens are OpenAI's
billed `response.usage` (exact, captured uniformly via the harness usage meter). Full v1 matrix costs
**$39.07** to run once. Regenerate: `python harness/leaderboard.py --label "PromptQuery=results_prq_v1.json" …`_

**Grade sub-scores (so you can re-rank to your own priorities):**

| Tool | EX | EFF(VES) | REL | TOK | LAT |
|---|---:|---:|---:|---:|---:|
| Vanna | 46.0 | 44.6 | 82.0 | **100.0** | 91.1 |
| PromptQuery | **58.0** | **52.0** | 93.0 | 47.0 | 61.8 |
| raw-gpt-4o | 55.0 | 49.2 | 90.0 | 13.1 | **100.0** |
| MAC-SQL | 49.0 | 42.2 | **97.0** | 12.8 | 47.2 |
| DIN-SQL | 52.0 | 45.5 | 94.0 | 12.2 | 27.3 |
| LangChain | 16.0 | 14.8 | 54.0 | 2.0 | 21.5 |

**Per-bucket EX@1** (where retrieval vs generation is the bottleneck):

| Tool | single | join | multi-join | analytical | named | 1-hop | 2-hop+ | lexical-gap |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| PromptQuery | 58.6 | **64.0** | **58.3** | 20.0 | 60.8 | **57.1** | 70.0 | 36.4 |
| raw-gpt-4o | **62.1** | 48.0 | 50.0 | 20.0 | 60.8 | 39.3 | **70.0** | **54.5** |
| DIN-SQL | 58.6 | 52.0 | 25.0 | **40.0** | 60.8 | 50.0 | 20.0 | 45.5 |
| MAC-SQL | 53.4 | 52.0 | 33.3 | 20.0 | 56.9 | 46.4 | 40.0 | 27.3 |
| Vanna | 53.4 | 48.0 | 16.7 | 20.0 | 56.9 | 42.9 | 20.0 | 27.3 |
| LangChain | 19.0 | 16.0 | 8.3 | 0.0 | 19.6 | 14.3 | 10.0 | 9.1 |

**What v1 shows (the point of the new axes):**
- **PromptQuery wins accuracy & retrieval; Vanna wins the Grade on efficiency.** PromptQuery leads
  **EX@1 (58.0)**, **Set-Recall (98%** — finds every required table among 211 on all but two
  questions), **VES**, and **Soft-F1**, and it's best on the join (64.0) and multi-join (58.3) buckets
  where finding the right tables matters most. Vanna takes the **#1 Grade** because it is the most
  token-frugal (**2.0k tok/q, $0.53/100q**) and fastest (1.5s/q), and the Grade weights token-economy
  and latency. Read both columns: **PromptQuery for the most correct answers and reliable retrieval;
  Vanna if raw cost/speed dominate** — at the price of 12 more errors and 19-point-lower recall.
- **The "no-retrieval tax" is now a dollar figure.** raw-gpt-4o matches the field on accuracy (55.0
  EX) but sends **15.3k tok/q ($3.87/100q)** — 3.6× PromptQuery and 7.7× Vanna — for *no* accuracy
  gain. At 211 tables the full dump still fits gpt-4o's context, so it isn't yet scale-starved on EX;
  what it buys is a bill, not correctness.
- **LangChain is the cautionary tale, quantified.** Its `SQLDatabase` reflects full DDL for all 211
  tables = **101,151 tokens every question** (6.6× raw's compact render), yet it scores **16% EX with
  46 errors** and is the slowest (6.5s/q). It is simultaneously the most expensive (**$25.36/100q —
  65% of the entire benchmark's cost**) and least accurate: maximum spend, minimum result.
- **The handbook's multi-agent methods land mid-pack — decomposition didn't beat plain retrieval
  here.** MAC-SQL (Selector→Decomposer→Refiner) and DIN-SQL (schema-linking→classify→decompose→
  self-correct) reach respectable EX (49 / 52) and **90% Set-Recall** (their LLM schema-selection
  works), and MAC-SQL is the most *reliable* tool (only **3 errors**). But each pays a full-schema
  selector/linking call (~15–16k tok/q, ~$4/100q) and multi-step latency (DIN-SQL is the slowest
  non-LangChain at 5.1s/q), so their Grades (46.8 / 46.5) trail the leaner retrieval tools. More
  agent steps bought reliability and recall, not top-line accuracy.
- **Per-bucket: retrieval helps joins, generation caps analytical, lexical-gap favors the dump.**
  Retrieval-aware tools win joins/multi-joins (prq 64/58 vs raw 48/50). *Everyone* is weak on
  analytical (20–40) — that ceiling is SQL **generation**, not retrieval. And raw-gpt-4o is strongest
  on **lexical-gap (54.5)** and ties best on **2-hop+ (70)**: seeing the whole schema sidesteps the
  retrieval miss that hurts prq/Vanna when the question's words don't match table names.
- **The Grade is weight-sensitive — and we show the parts.** The top three (Vanna 61.9, prq 59.0,
  raw 55.5) sit within ~6 points; tilting the weights toward accuracy puts PromptQuery first. The
  sub-score table above lets you re-rank for your own cost/accuracy trade-off.

## Results — v0.2 (35 questions q041–q075, gpt-4o) — *superseded by v1*

> Kept for history. **v1 (100 questions, above) supersedes this.** Note: v0.2's PromptQuery tokens
> were a tiktoken *estimate* (~2.3k/q) — v1's exact OpenAI-billed count is **4.3k/q**, ~1.9× higher;
> the estimate undercounted, which is why v1 records real `response.usage` for every tool.

Full-schema tools run only the 35 new questions (cost control); all four run the same set.

| Rank | Tool | EX@1 | Set-Recall | avg ms/q | avg tok/q | total tok | errors |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **PromptQuery** (retrieval) | **62.9%** | **100.0%** | 3,193 | **2,287** | 80,048 | 4/35 |
| 2 | raw-llm (full-schema dump) | 60.0% | n/a | 1,237 | **15,316** | 536,057 | 5/35 |
| 3 | Vanna 0.7.9 (RAG) | 42.9% | 80.0% | 1,922 | n/a | n/a | 6/35 |
| 4 | LangChain (schema-dump) | 11.4% | n/a | **6,119** | n/a | n/a | 18/35 |

_All four tools ran the same 35 new questions (q041–q075) on gpt-4o, temp 0. Tokens: exact for
raw-llm (OpenAI usage), tiktoken-estimate for PromptQuery; `n/a` where the tool's SDK doesn't expose
usage (Vanna, LangChain)._

**What the new metrics reveal (the point of adding them):**
- **Retrieval wins on accuracy *and* cost — now measured, not asserted.** PromptQuery is the most
  accurate tool on the 35 new questions (**62.9% EX@1**, edging raw-llm's 60.0%) while sending
  **2,287 tokens/q vs raw-llm's 15,316 — a 6.7× reduction** (80k total vs 536k for the same 35
  questions). With **100% Set-Recall** it never misses a required table among 211. The "no-retrieval
  tax" isn't only a token bill: the full-schema dump doesn't even buy accuracy here.
- **LangChain is both slowest and least accurate:** **6.1 s/question** (5× raw-llm) and **18/35
  errors** — reasoning over a 211-table multi-schema `table_info` is expensive *and* fragile.
- **Latency is the one axis where retrieval pays.** PromptQuery's pipeline (TF-IDF rank → LLM
  table-selector → FK expansion) costs **3.2 s/q** — slower than full-dump (raw-llm 1.2s) and RAG
  (Vanna 1.9s), faster than the framework dump (LangChain 6.1s). The selector LLM call is the added
  cost; you trade ~2s/q for 6.7× fewer tokens *and* the top accuracy. Execution of the generated SQL
  is tiny (<25ms) — the LLM call dominates, not the query.
- **EX ordering: retrieval (prq) > dump (raw-llm) > RAG (Vanna) > framework-dump (LangChain)** —
  consistent with v0.1, where PromptQuery also edged the naive baseline by a small margin. The
  accuracy gap stays small because at 211 tables the schema still fits gpt-4o's context (the baseline
  isn't yet scale-starved); at this scale the decisive difference retrieval buys is **token cost**,
  not EX. Everyone is still capped by generation on the hard (analytical) questions.

## Results — v0.1 (first 40 questions, gpt-4o) — *superseded by v1*

| Rank | Tool | EX@1 | Set-Recall | single | join | multi-join | analytical | errors |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | **PromptQuery** | **47.5%** | **100.0%** | 54.2 | 45.5 | 25.0 | 0.0 | 1/40 |
| 2 | raw-llm (baseline) | 45.0% | n/a | 54.2 | 36.4 | 25.0 | 0.0 | 4/40 |
| 3 | Vanna 0.7.9 | 37.5% | 70.0% | 41.7 | 45.5 | 0.0 | 0.0 | 10/40 |
| 4 | LangChain | 17.5% | n/a | 20.8 | 18.2 | 0.0 | 0.0 | 21/40 |

_(all gpt-4o, temp 0, single-state EX@1, 40 questions, heron `small`. Regenerate:
`python harness/leaderboard.py --label "PromptQuery=results_prq_gpt4o.json" ...`)_

**The read:**
- **Retrieval-aware tools lead.** PromptQuery (47.5%, **100% Set-Recall** — found every required
  table among 211) edges the naive baseline; the gap is small because at 211 tables the schema still
  fits gpt-4o's context (so the baseline isn't yet scale-starved — same finding as the single-tool
  leaderboard).
- **Retrieval quality is decisive among RAG tools.** Vanna's RAG hit only **70% Set-Recall** →
  missing tables → 10 execution errors → 37.5%. PromptQuery's 100% recall is why it's ahead of Vanna.
- **The schema-dumper-in-a-framework collapses.** LangChain errored on **21/40** — dumping a
  211-table, 14-schema `table_info` into the prompt produces wrong/invalid SQL far more often.
  No retrieval + multi-schema = worst result.
- **Everyone fails analytical (0%) and is weak on multi-join** — generation, not retrieval, is the
  ceiling here (a frontier-vs-frontier or harder-question follow-up would move this).

## The tools (positioning)

Each card: what it is · license · **how it handles heron's 211-table, 14-schema DB** · setup
reality · result.

### raw-llm (baseline) — the floor
Dumps the entire schema into the prompt and asks for SQL. **No retrieval.** Apache-2.0 (ours).
Multi-schema: we feed the full 211-table DDL text. Setup: trivial. The control that says "does any
tool beat just asking the model with everything?"

### PromptQuery (`prq`) — retrieval-first, the tool heron was built to measure neutrally
TF-IDF rank → optional LLM table-selector → FK-graph expansion → prompt over ~25 tables. Apache-2.0.
Multi-schema: native (`pg_catalog` introspection, schema-qualified). Setup: `pip install promptquery`.
Exposes its retrieved tables → scored on **Set-Recall@k** too.

### Vanna (legacy 0.7.9) — RAG over trained DDL
Train a vector store on per-table DDL, then RAG the relevant DDL per question. MIT. Multi-schema:
works **iff trained on schema-qualified DDL** (we train on heron's real `CREATE TABLE` statements).
Setup gotcha: **`pip install vanna` now gives the 2.0 agent rewrite — you must pin `0.7.9`** (the
classic generate_sql API; repo archived Feb 2026). Embeddings local (free); only generation is gpt-4o.
Exposes retrieved DDL → Set-Recall@k.

### LangChain (`create_sql_query_chain`) — no retrieval, schema-dump like the baseline
SQLDatabase reflection → table_info in the prompt → LLM. Multi-schema gotcha: **in LangChain 1.x the
chain moved to the separate `langchain-classic` package** (old `langchain.chains` import is gone), and
`SQLDatabase` reflects a single schema — we pre-reflect all 14 into its metadata. No table retrieval,
so effectively the naive approach wearing a framework; end-to-end → no Set-Recall. **The
killer in v1: its reflected `table_info` is full DDL for all 211 tables = 101k tokens/question** (vs
raw's 15k compact render) — 65% of the whole benchmark's API bill, for 16% EX. Tokens captured via
LangChain's `get_openai_callback` (the harness usage meter doesn't see its wrapped client).

### MAC-SQL (multi-agent) — handbook entry, faithful gpt-4o reproduction *(new in v1)*
Three agents over the same gpt-4o ([arXiv:2312.11242](https://arxiv.org/abs/2312.11242)):
**Selector** prunes the 211-table schema to the relevant tables (its retrieved set → Set-Recall),
**Decomposer** writes the SQL over only those, **Refiner** re-generates once on an execution error.
heron ships a faithful in-process reproduction (`harness/adapters/macsql.py`), not the authors' Spider
harness. Multi-schema: native (the Selector sees full schema-qualified DDL). Result: most *reliable*
(3 errors), 90% recall, but the full-schema selector call costs ~15.7k tok/q.

### DIN-SQL (decomposed in-context) — handbook entry, faithful gpt-4o reproduction *(new in v1)*
Four prompting modules ([arXiv:2304.11015](https://arxiv.org/abs/2304.11015)): **schema-linking**
(its table set → Set-Recall; also reduces the schema for the cheaper downstream calls),
**classification** (easy / non-nested / nested), class-aware **generation**, and **self-correction**.
Faithful reproduction in `harness/adapters/dinsql.py`. Best on the analytical bucket (40), but four
calls → slowest non-LangChain tool (5.1s/q) and ~16.3k tok/q.

### LlamaIndex (`SQLTableRetrieverQueryEngine`) — *deferred (confirmed structural)*
The only off-the-shelf engine that truly retrieves tables (embeds one node per table). **Still
deferred in v1, root cause now confirmed:** its `SQLDatabase` treats a schema-qualified name like
`analytics.cohort_members` as a *bare* table name (single-schema assumption), so SQLAlchemy's
`get_columns`/`get_table_comment` raise `NoSuchTableError` on heron's 14-schema DB. Neutralizing the
comment call isn't enough — the column reflection fails the same way. A real fix needs a custom
SQLDatabase that splits schema from table; out of scope for v1. Apache-2.0.

## Deferred — surveyed but not benchmarkable in-process (from TOOLS-SURVEY.md)
- **Server/UI (bucket B):** WrenAI (AGPL docker stack), DB-GPT (agent platform/web app), Dataherald
  (FastAPI+Mongo engine), Vanna 2.0 (deployed agent), SQLChat (Next.js). No headless `generate_sql()`.
- **Model-only / GPU (bucket C):** Defog/SQLCoder, XiYan-SQL, prem-1B-SQL, NSQL — fine-tuned models,
  not pipelines; would break the same-gpt-4o control.
- **NL2SQL Handbook, fine-tuned (excluded for the same reason):** OmniSQL, Alpha-SQL, DIVER, RUBIKSQL
  are trained/GPU models — they'd confound the "isolate retrieval, hold the model fixed" design.
  Only the handbook's **API-prompting frameworks** (MAC-SQL, DIN-SQL) are runnable under the control,
  and both are in v1 above.

## What this list is and isn't (honest)
- It is an **apples-to-apples run** of six OSS NL→SQL approaches on one production-shaped schema, same
  model (gpt-4o). It shows the real split — **retrieval-aware (PromptQuery, Vanna) vs. schema-dumpers
  (raw-gpt-4o, LangChain) vs. multi-agent (MAC-SQL, DIN-SQL)** at 211 tables — across accuracy,
  retrieval, efficiency, and **cost**.
- The **Grade is one opinionated blend** (weights in [METHODOLOGY §7](METHODOLOGY.md)); it is
  weight-sensitive and the top three are within ~6 points. Treat it as a convenience lens, not a
  verdict — the per-axis and sub-score tables are the real data.
- It is **not** a definitive ranking: single model (gpt-4o), single DB state, 100 questions, `small`
  scale. Numbers move with model, sampling, and scale. Read it as directional.
- **Tokens/cost are exact** (OpenAI billed `response.usage`), but **`$/100q` is hardware/price-time
  specific** (gpt-4o list prices, this run). Efficiency (VES/latency) is fair *relative* to the field
  on one machine, not an absolute constant.
- Set-Recall is only defined for tools that expose a retrieved-table set (PromptQuery, Vanna, MAC-SQL,
  DIN-SQL); schema-dumpers show `n/a`.
