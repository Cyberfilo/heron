# Related Work: The NL-to-SQL Benchmark Landscape (and the Gap We Fill)

> **Scope.** This document surveys the text-to-SQL benchmark landscape as of June 2026 and states precisely
> the unoccupied niche our new benchmark occupies: **one large, fully-seeded, local-Postgres,
> production-shaped multi-tenant SaaS schema (~220 FK-linked tables across 14 domains, millions of rows),
> scored by execution-equality, with a first-class "schema-retrieval at scale" axis** (find the right ~5
> tables among ~220).
>
> **Honesty note up front.** Several existing benchmarks are *already strong* on dimensions we care about.
> BEAVER already has private warehouses with ~100 tables/db and *already* reports table-retrieval F1 as an
> isolated subtask. BIRD-Ent already pushes past 4,000 columns. Spider 2.0 already has 1,000–3,000-column
> enterprise schemas. We are **not** claiming "first hard schema." Our claim is narrower and defensible:
> **first fully-open, locally-reproducible, single-coherent-schema Postgres benchmark that combines (a)
> production multi-tenant shape, (b) deterministic million-row seeding you can rebuild from a dump, and (c)
> retrieval-at-scale as an explicitly measured, isolatable axis on one schema rather than across a pool of
> small dbs.** See the Gap Analysis section for the precise wording.
>
> **VERIFIED vs PRIOR.** Numbers tagged with a citation are verified against the linked source (fetched
> June 2026). Numbers tagged *(prior)* are from model knowledge and should be re-verified before publication.

---

## 1. The Spider family

### 1.1 Spider 1.0 (Yale, EMNLP 2018) — the saturated baseline

| Property | Value | Source |
|---|---|---|
| Databases | **200** (138 domains); 10,181 questions; 5,693 unique SQL | [yale-lily.github.io/spider](https://yale-lily.github.io/spider) |
| Schema size | **Small** — few tables/columns per db (Spider 2.0 paper measures it as a contrast point) | [arxiv 2411.07763](https://arxiv.org/pdf/2411.07763) |
| Dialect | SQLite | [github.com/taoyds/spider](https://github.com/taoyds/spider) |
| Scoring | Test-Suite Accuracy / Execution Accuracy (also Exact-Set-Match) | [yale-lily.github.io/spider](https://yale-lily.github.io/spider) |
| License | **CC BY-SA 4.0** | [huggingface.co/datasets/xlangai/spider](https://huggingface.co/datasets/xlangai/spider) |
| Schema-retrieval-at-scale? | **No.** One db per question is given; cross-domain generalization is tested, not table retrieval within a huge schema. | — |
| Status | **Saturated** — top systems report ~90%+ EX (vendor claims up to 99.8%) | [apporchid.com blog](https://www.apporchid.com/blog/%20how-app-orchids-ontology-driven-text-to-sql-solution-redefines-accuracy-and-trust-in-an-era-of-llm-hallucinations) |

**Takeaway:** Spider 1.0 is the reference point everyone compares *down* from. Its schemas are toy-sized; it
does not stress schema linking at scale. Our benchmark is the explicit anti-Spider-1.0 on schema size.

### 1.2 Spider 2.0 / 2.0-lite / 2.0-snow / 2.0-DBT (ICLR 2025 Oral) — enterprise warehouse workflows

| Property | Value | Source |
|---|---|---|
| Total real-world workflows | **632** enterprise tasks | [spider2-sql.github.io](https://spider2-sql.github.io/), [arxiv 2411.07763](https://arxiv.org/pdf/2411.07763) |
| Spider 2.0-Snow | **547** tasks, all Snowflake | [github.com/xlang-ai/Spider2](https://github.com/xlang-ai/Spider2) |
| Spider 2.0-Lite | **547** tasks: 214 BigQuery / 198 Snowflake / 135 SQLite | [github.com/xlang-ai/Spider2](https://github.com/xlang-ai/Spider2) |
| Spider 2.0-DBT | **68** tasks, DuckDB + dbt | [github.com/xlang-ai/Spider2](https://github.com/xlang-ai/Spider2) |
| Schema size | Databases often **>1,000 columns**, some **>3,000 columns**; BEAVER measures Spider 2.0 at **avg 52.6 tables / 803.6 columns** per db | [arxiv 2411.07763](https://arxiv.org/pdf/2411.07763), [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |
| Dialect | BigQuery, Snowflake, SQLite, DuckDB — **cloud warehouses**, multi-dialect | [spider2-sql.github.io](https://spider2-sql.github.io/) |
| Scoring | Execution-based success rate (agent must produce the right result; SQL often >100 lines) | [arxiv 2411.07763](https://arxiv.org/pdf/2411.07763) |
| License | **MIT** | [github.com/xlang-ai/Spider2](https://github.com/xlang-ai/Spider2) |
| Schema-retrieval-at-scale? | **Yes, implicitly** — agents must navigate huge schemas + docs, but it is bundled into end-to-end success, not isolated as a retrieval F1. | [arxiv 2411.07763](https://arxiv.org/pdf/2411.07763) |

**Why it's hard:** long contexts, multi-dialect SQL, multi-step agentic workflows, queries exceeding 100
lines. GPT-4o baseline success was ~10.1% on the full set at release. [spider2-sql.github.io](https://spider2-sql.github.io/)

**Current leaderboard SOTA (as of fetch, June 2026):**
- Spider 2.0-Lite: **DivSkill-SQL 73.13%** (Snowflake AI Research × UCSD); SOMA-SQL 72.02% (Oracle OCI); DecisionX Agent 71.84% — [spider2-sql.github.io](https://spider2-sql.github.io/)
- Spider 2.0-Snow: Genloop Sentinel Agent v2 Pro **96.70%** — [spider2-sql.github.io](https://spider2-sql.github.io/)
- Spider 2.0-DBT: SignalPilot Agent **65.6%** — [spider2-sql.github.io](https://spider2-sql.github.io/)

> The Lite numbers climbing into the low-70s within ~18 months shows the leaderboard is **maturing fast**.
> The Snow 96.7% figure suggests parts of Spider 2.0 are *approaching saturation* on the easier subset —
> reinforcing the need for fresh, contamination-resistant, locally-rebuildable schemas.

**Relevance to us:** Spider 2.0 is the closest "big schema, real enterprise" benchmark — but it is
**cloud-warehouse-bound** (you need a BigQuery/Snowflake account to reproduce), spread across **many separate
databases**, and does **not** report an isolated retrieval metric. Our benchmark is the **local-Postgres,
single-coherent-schema, fully-seeded** complement.

### 1.3 Dr.Spider (Amazon, ICLR 2023, notable-top-5%) — robustness, not scale

| Property | Value | Source |
|---|---|---|
| Design | **17 perturbations** across DB, NL question, and SQL axes, built on Spider | [arxiv 2301.08881](https://arxiv.org/abs/2301.08881) |
| Finding | Even the most robust model dropped **14.0% overall**, **50.7%** on the hardest perturbation | [arxiv 2301.08881](https://arxiv.org/abs/2301.08881) |
| Dialect / scoring | SQLite / Execution Accuracy | [github.com/awslabs/diagnostic-robustness-text-to-sql](https://github.com/awslabs/diagnostic-robustness-text-to-sql) |
| Schema-retrieval-at-scale? | **No** — it measures *robustness to perturbation*, an orthogonal axis. | — |

**Relevance to us:** Dr.Spider's *diagnostic, axis-isolating* philosophy is the methodological precedent for
our "retrieval-at-scale as an isolated signal" design. We borrow the spirit (decompose and measure one axis
cleanly), not the data.

---

## 2. The BIRD family

### 2.1 BIRD (NeurIPS 2023) — value grounding + efficiency on bigger, dirtier dbs

| Property | Value | Source |
|---|---|---|
| Question-SQL pairs | **12,751** | [bird-bench.github.io](https://bird-bench.github.io/) |
| Databases | **95**, total **33.4 GB**, **37+ professional domains** | [bird-bench.github.io](https://bird-bench.github.io/), [neurips proceedings](https://proceedings.neurips.cc/paper_files/paper/2023/file/83fc8fab1710363050bbd1d4b8cc0021-Paper-Datasets_and_Benchmarks.pdf) |
| Schema size | BEAVER measures BIRD at **avg 6.8 tables / 72.5 columns** per db — i.e. still modest | [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |
| Dialect | SQLite (primary); MySQL & PostgreSQL versions exist | [bird-bench.github.io](https://bird-bench.github.io/) |
| Scoring | **EX** (Execution Accuracy) + **VES** / **R-VES** (Reward-based Valid Efficiency Score — penalizes correct-but-slow SQL) | [bird-bench.github.io](https://bird-bench.github.io/) |
| License | **CC BY-SA 4.0** | [bird-bench.github.io](https://bird-bench.github.io/) |
| Schema-retrieval-at-scale? | **No** — value grounding & dirty data are the novelty; one db per question. | — |

**Key innovations we should respect:** (1) **value grounding** — questions reference *data values* not just
column names; (2) **dirty data** — real-world messy contents; (3) **efficiency scoring (VES)** — a
production-relevant axis most benchmarks ignore.

**Leaderboard SOTA (fetched June 2026):**
- Human baseline: **92.96% EX** — [bird-bench.github.io](https://bird-bench.github.io/)
- Dev (overall track): AskData + GPT-4o **77.64% EX** — [bird-bench.github.io](https://bird-bench.github.io/)
- Test (overall track): AskData + GPT-4o **81.95% EX** (Sep 2025) — [bird-bench.github.io](https://bird-bench.github.io/)
- Single-model track: Gemini-SQL (Gemini-2.5-Pro) **77.14% EX** (Mar 2026) — [bird-bench.github.io](https://bird-bench.github.io/)

> BIRD is **maturing but not saturated** — overall systems crossed 80% EX on test in 2025, ~12 points below
> the human ceiling. Still, its per-db schemas are small (≈7 tables), so it does not stress retrieval.

### 2.2 BIRD-Critic / SWE-SQL (NeurIPS 2025) — SQL *issue fixing*, not generation

| Property | Value | Source |
|---|---|---|
| Tasks | **600 dev + 200 held-out OOD**; PostgreSQL-only set has **530 complex tasks** | [bird-critic.github.io](https://bird-critic.github.io/), [github.com/bird-bench/BIRD-CRITIC-1](https://github.com/bird-bench/BIRD-CRITIC-1) |
| Dialects | MySQL, **PostgreSQL**, SQL Server, Oracle | [github.com/bird-bench/BIRD-CRITIC-1](https://github.com/bird-bench/BIRD-CRITIC-1) |
| Task type | **Fix user SQL issues** in real apps (a debugging benchmark, not pure NL→SQL) | [bird-critic.github.io](https://bird-critic.github.io/) |
| Schema-retrieval-at-scale? | **No** — different task entirely (SQL repair). | — |

### 2.3 LiveSQLBench (BIRD-SQL Pro v0.5, 2025–2026) — contamination-free, live, Postgres

| Property | Value | Source |
|---|---|---|
| Base-Lite | **18 dbs, 270 tasks** (180 SELECT + 90 management/CRUD) | [livesqlbench.ai](https://livesqlbench.ai/) |
| Base-Full v1 | **22 dbs, 600 tasks** | [livesqlbench.ai](https://livesqlbench.ai/) |
| Large-v1 | **18 dbs, 480 tasks**, **~1K columns**, **~54 tables/db**, ~84K-token prompts | [livesqlbench.ai](https://livesqlbench.ai/) |
| Dialect | **PostgreSQL** (primary); SQLite version too | [livesqlbench.ai](https://livesqlbench.ai/) |
| Scoring | **Success Rate** (passing test cases / total) | [livesqlbench.ai](https://livesqlbench.ai/) |
| Contamination defense | "Truly Live & Hidden Test" — hidden test set of each release becomes next release's open dev set | [livesqlbench.ai](https://livesqlbench.ai/) |
| Schema-retrieval-at-scale? | **Partially** — Large-v1 has ~54 tables/~1K columns per db, the closest in the BIRD family to our scale, but still **multiple separate dbs** and no isolated retrieval metric. | [livesqlbench.ai](https://livesqlbench.ai/) |

**Leaderboard SOTA (as of 2026-04-26):** Gemini 3.1 Pro **43.10%**, Claude Opus 4.6 **39.43%**, GPT-5.5
(xhigh) **37.36%** — [livesqlbench.ai](https://livesqlbench.ai/). **Low scores → far from saturation.**

**Relevance to us:** LiveSQLBench is the **most philosophically aligned** prior — Postgres, full SQL spectrum
(incl. CRUD/management), live/contamination-resistant, ~54 tables/db. The differences: it spreads scale
across *many* dbs (≤54 tables each) rather than **one ~220-table coherent schema**, it is **not multi-tenant
SaaS-shaped**, and it does **not isolate retrieval** as its own axis. We are adjacent, not redundant.

---

## 3. Domain / scientific / reasoning / ambiguity benchmarks

### 3.1 ScienceBenchmark (VLDB 2024) — real scientific schemas

| Property | Value | Source |
|---|---|---|
| Databases | **3**: CORDIS (research policy), SDSS (astrophysics), OncoMX (cancer research) | [arxiv 2306.04743](https://arxiv.org/html/2306.04743v2) |
| Data | Dev = 100 NL/SQL pairs per domain; train = 100 (CORDIS/SDSS), 50 (OncoMX); extended with GPT-3 synthetic data | [arxiv 2306.04743v2](https://arxiv.org/html/2306.04743v2) |
| Schema size | e.g. OncoMX = **25 tables, 106 columns**; real, complex domain schemas | [arxiv 2306.04743v2](https://arxiv.org/html/2306.04743v2) |
| Dialect | PostgreSQL-style relational (hosted demo) | [sciencebenchmark.cloudlab.zhaw.ch](https://sciencebenchmark.cloudlab.zhaw.ch/) |
| Scoring | Execution Accuracy | [dl.acm.org/doi/10.14778/3636218.3636225](https://dl.acm.org/doi/10.14778/3636218.3636225) |
| License | **CC BY 4.0** | [arxiv 2306.04743](https://arxiv.org/abs/2306.04743) |
| Schema-retrieval-at-scale? | **No** — domain-specific difficulty, moderate schemas (≤25 tables). | — |

### 3.2 Archer (EACL 2024) — arithmetic / commonsense / hypothetical reasoning

| Property | Value | Source |
|---|---|---|
| Data | 1,042 EN + 1,042 ZH questions, 521 unique SQL, **20 dbs / 20 domains** | [sig4kg.github.io/archer-bench](https://sig4kg.github.io/archer-bench/) |
| Difficulty | GPT-4 + DIN-SQL scored **6.73% EX** (vs 85.3% on Spider) at release | [arxiv 2402.12554](https://arxiv.org/abs/2402.12554) |
| 2025 update | Oracle AI won the 2025 Archer NL2SQL Challenge (planner+SQL agents on GPT-5), leading by 9+ EX points, >99% SQL validity | [blogs.oracle.com](https://blogs.oracle.com/cloud-infrastructure/oracle-wins-archer-nl2sql-challenge) |
| Scoring / dialect | Execution Accuracy / SQLite | [sig4kg.github.io/archer-bench](https://sig4kg.github.io/archer-bench/) |
| Schema-retrieval-at-scale? | **No** — reasoning difficulty, small schemas. | — |

### 3.3 AmbiQT (EMNLP 2023) — ambiguity

| Property | Value | Source |
|---|---|---|
| Data | **>3,000 examples**, each text → two plausible SQLs; 4 ambiguity types (lexical column/table, structural join/aggregate) | [arxiv 2310.13659](https://arxiv.org/abs/2310.13659) |
| Finding | All tested models fail to surface all plausible SQLs in top-k | [github.com/testzer0/ambiqt](https://github.com/testzer0/ambiqt) |
| Schema-retrieval-at-scale? | **No** — ambiguity resolution, not scale. | — |

### 3.4 BookSQL (NAACL 2024) — accounting / finance, large *data* volume

| Property | Value | Source |
|---|---|---|
| Data | **100k NL-SQL pairs**, accounting db of **1 million records**, **27 businesses** (~35k–40k txns each) | [aclanthology.org/2024.naacl-long.28](https://aclanthology.org/2024.naacl-long.28/), [arxiv 2406.07860](https://arxiv.org/abs/2406.07860) |
| Difficulty | Large gaps even for GPT-4; domain-specialized models needed | [arxiv 2406.07860](https://arxiv.org/abs/2406.07860) |
| Schema-retrieval-at-scale? | **No** — single accounting schema (narrow), big *data* volume but not *schema* breadth. | — |

> BookSQL is the closest prior on **data volume** (1M records, financial). It validates that "millions of
> rows in one coherent domain" is a respected design — but its **schema is narrow** (accounting only),
> whereas we span **14 domains / ~220 tables** in one schema. Complementary, not overlapping.

### 3.5 FINCH (2025) — financial NL2SQL with contextual handling

Newer financial entrant building on the BookSQL lineage. [arxiv 2510.01887](https://arxiv.org/html/2510.01887v1)
*(prior; not deeply verified — listed for completeness.)*

---

## 4. Production / enterprise-flavored efforts and 2025–2026 newcomers

### 4.1 BEAVER (2024–2025) — the most directly comparable prior

| Property | Value | Source |
|---|---|---|
| Data | **9,128 question-SQL pairs** from real enterprise query logs + synth | [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |
| Schema | **812 tables across 19 domains**; 3 private warehouses: DW (97 tables, Oracle), NW (366, MySQL), SP (349, MySQL) | [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |
| Per-db scale | **avg 101.5 tables / 869.4 columns** per db; queries avg 4.0 tables, 5.7 joins, 316.7 tokens | [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |
| Dialects | Oracle, MySQL (private data-warehouse SQL) | [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |
| Scoring | Execution Accuracy (binary) **+ fine-grained subtask F1 for table retrieval, join detection, column mapping, domain knowledge** + LLM-judge query decomposition | [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |
| Difficulty | Best system **ReFoRCE + Claude-4.5-Sonnet = 10.8% EX**; with oracle subtask annotations → 30.1% | [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |
| License | **CC BY 4.0**; artifacts at beaverbench.github.io | [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |
| Schema-retrieval-at-scale? | **YES, explicitly** — table-retrieval F1 is one of five isolated subtask metrics. **This is the prior that most overlaps our retrieval axis.** | [arxiv 2409.02038v3](https://arxiv.org/html/2409.02038v3) |

> **BE HONEST ABOUT BEAVER.** It already does the two things we most want to claim: (1) ~100-table
> enterprise schemas, and (2) **table-retrieval as an isolated F1 subtask**. We must not claim to be "first
> to measure schema linking at scale." BEAVER got there first. Our differentiators vs BEAVER are concrete
> and narrow (see Gap Analysis): **fully open & locally reproducible** (BEAVER warehouses are private/
> anonymized, Oracle+MySQL, not rebuildable end-to-end by anyone), **Postgres** (BEAVER is Oracle/MySQL),
> **one single coherent multi-tenant SaaS schema** (BEAVER is 3 unrelated warehouses), and **deterministic
> million-row seeding from a pg_dump** (BEAVER ships logged queries against fixed private data).

### 4.2 BIRD-Ent / Spider-Ent + DRAG (ICLR 2026 submission, withdrawn)

| Property | Value | Source |
|---|---|---|
| Scale | **>4,000 columns**, abbreviated/cryptic names, scattered knowledge across **1.5M tokens** of docs | [openreview gXkIkSN2Ha](https://openreview.net/forum?id=gXkIkSN2Ha) |
| Method | **Dual-Retrieval-Augmented-Generation (DRAG)** — formalizes retrieving table schemas *and* knowledge docs before SQL gen | [openreview gXkIkSN2Ha](https://openreview.net/forum?id=gXkIkSN2Ha) |
| Results | BIRD-Ent **39.1 EX**, Spider-Ent **60.5 EX** | [openreview gXkIkSN2Ha](https://openreview.net/forum?id=gXkIkSN2Ha) |
| Status | **Withdrawn** ICLR 2026 submission (Jan 2026) — may not become a stable public benchmark | [openreview gXkIkSN2Ha](https://openreview.net/forum?id=gXkIkSN2Ha) |
| Schema-retrieval-at-scale? | **YES, central** — DRAG is literally a retrieval-first paradigm; >4,000 columns. | [openreview gXkIkSN2Ha](https://openreview.net/forum?id=gXkIkSN2Ha) |

> BIRD-Ent formalizes "retrieve before you generate" at >4K columns. It overlaps our retrieval thesis, but
> it is a **refinement layer over existing academic dbs** (not a new coherent schema) and is **withdrawn**
> (uncertain availability). It validates the *direction* without occupying our *niche*.

### 4.3 Schema-linking-at-scale method papers (not benchmarks, but they prove the axis matters)

- **LinkAlign** (EMNLP 2025): scalable schema linking for large multi-db text-to-SQL; SOTA **33.09% on
  Spider 2.0-Lite** with open-source LLMs at submission time; built **AmbiDB** synthetic set for realistic
  schema-linking ambiguity. [arxiv 2503.18596](https://arxiv.org/abs/2503.18596),
  [github.com/Satissss/LinkAlign](https://github.com/Satissss/LinkAlign)
- **SchemaGraphSQL** (2025): FK-graph + pathfinding to pick optimal table/column sequences on large
  schemas. [arxiv 2505.18363](https://arxiv.org/pdf/2505.18363)

> These are **method** papers that treat "find the right tables among thousands of fields" as *the* hard
> sub-problem. They prove demand for exactly the axis our benchmark isolates — but they had to *invent*
> evaluation setups (AmbiDB is synthetic) because **no clean, single-schema, retrieval-at-scale benchmark
> exists**. That absence is our opening.

---

## 5. Gap Analysis

### 5.1 Comparison table

| Benchmark | #Tables/db (scale) | Data volume | Dialect | Local-reproducible? | Single coherent schema? | Multi-tenant SaaS shape? | Retrieval-at-scale ISOLATED metric? | Scoring | License |
|---|---|---|---|---|---|---|---|---|---|
| **Spider 1.0** | tiny (~5) | tiny | SQLite | Yes | No (200 dbs) | No | No | Exec/Test-suite | CC BY-SA 4.0 |
| **Spider 2.0** | 52.6 avg (≤1K–3K cols) | large | BigQuery/Snowflake/SQLite/DuckDB | **No (cloud)** | No (many dbs) | No | No (bundled in agent success) | Exec success | MIT |
| **Dr.Spider** | tiny | tiny | SQLite | Yes | No | No | No (robustness axis) | Exec | — |
| **BIRD** | 6.8 avg / 72.5 cols | 33.4 GB | SQLite(+MySQL/PG) | Yes | No (95 dbs) | No | No | EX + VES/R-VES | CC BY-SA 4.0 |
| **LiveSQLBench Large** | ~54 / ~1K cols | large | **PostgreSQL** | Yes | No (18 dbs) | No | No | Success rate | open (gh/hf) |
| **ScienceBenchmark** | ≤25 | moderate | PG-style | Yes (hosted) | No (3 dbs) | No | No | EX | CC BY 4.0 |
| **Archer** | small | small | SQLite | Yes | No (20 dbs) | No | No (reasoning axis) | EX | — |
| **AmbiQT** | small | small | SQLite | Yes | No | No | No (ambiguity axis) | top-k SQL recall | — |
| **BookSQL** | narrow (accounting) | **1M records** | SQL | Yes | ~Yes (1 domain) | No | No | EX | open (gh) |
| **BEAVER** | **101.5 avg / 869 cols** | large (logged) | Oracle/MySQL | **No (private warehouses)** | No (3 warehouses) | No | **YES (table-retrieval F1)** | EX + subtask F1 | CC BY 4.0 |
| **BIRD-Ent/Spider-Ent** | >4,000 cols | large | (unstated) | partial (over academic dbs) | No (refines existing) | No | **YES (DRAG retrieval)** | EX | — (withdrawn) |
| **→ THIS BENCHMARK** | **~220 in ONE schema** | **millions of rows, seeded** | **PostgreSQL 16 (local)** | **YES (pg_dump + seed gen)** | **YES (1 schema, 14 domains)** | **YES (B2B SaaS, tenant_id)** | **YES (find ~5 of ~220, isolated)** | **Execution-equality** | **(choose: CC BY 4.0 / MIT)** |

### 5.2 The precise unoccupied niche (one sentence)

> **No existing benchmark is simultaneously: (a) a single, coherent, FK-linked production-shaped multi-tenant
> B2B SaaS schema of ~220 tables across 14 domains, (b) fully open and *locally reproducible from a
> deterministic seeded generator + compressed pg_dump* on commodity Postgres 16 — no cloud warehouse, no
> private/anonymized data, no account required, (c) seeded to *millions of rows* so value-grounding and
> efficiency are real, and (d) scored on execution-equality with schema-retrieval-at-scale ("find the right
> ~5 tables among ~220") as a *first-class, isolatable axis on one schema*.**

Each existing benchmark misses at least one of these on a hard constraint, not a soft one:

- **Spider 2.0** and **BIRD-Ent** are big-schema but **cloud-bound / not a single coherent schema / not
  locally rebuildable end-to-end**.
- **BEAVER** has big schemas and isolated retrieval F1 but is **private/anonymized, Oracle+MySQL, 3 unrelated
  warehouses** — you cannot `pg_restore` it and rerun deterministically; it is **not multi-tenant SaaS**.
- **LiveSQLBench** is Postgres + ~54 tables/db but spreads scale across **18 separate dbs**, is **not
  multi-tenant**, and has **no isolated retrieval metric**.
- **BookSQL** has the data volume and is single-domain but **narrow schema, no retrieval-at-scale axis**.

The intersection — **single coherent multi-tenant Postgres SaaS schema + local deterministic million-row
reproducibility + isolated retrieval-at-scale axis** — is empty. That is the niche.

### 5.3 What we must NOT overclaim (where prior work is already strong)

1. **NOT "first to measure schema linking / table retrieval as an isolated signal."** BEAVER ships
   table-retrieval F1; BIRD-Ent's DRAG is retrieval-first. *Correct claim:* "first to isolate retrieval at
   scale **on one single coherent, openly-reproducible Postgres schema.**"
2. **NOT "first large/hard enterprise schema."** Spider 2.0 (1K–3K cols), BEAVER (101 tables), BIRD-Ent
   (>4K cols) are all larger or comparable on raw column count. *Correct claim:* "first that is **production-
   shaped (multi-tenant SaaS) AND fully open AND locally rebuildable** at this scale."
3. **NOT "first Postgres NL2SQL benchmark."** LiveSQLBench and BIRD-Critic-PostgreSQL exist. *Correct
   claim:* "first **single-schema, multi-tenant, millions-of-rows** Postgres benchmark with a retrieval
   axis."
4. **NOT "first with value grounding / efficiency."** BIRD owns value grounding + VES; we should **adopt
   and cite** these, not reinvent them.
5. **NOT "hardest benchmark."** Difficulty claims age badly (Snow leaderboard already at 96.7%). Claim a
   *distinct axis*, not a *higher number*.

---

## 6. How to position without overclaiming ("honesty is the moat")

1. **Lead with the axis, not the leaderboard.** Position as *"the retrieval-at-scale Postgres benchmark you
   can rebuild on your laptop"*, not *"the new SOTA-hardest benchmark."* Difficulty saturates; a clean,
   reproducible, isolatable axis endures.
2. **Name the neighbors explicitly in the README.** A one-paragraph "How this differs from BEAVER, Spider
   2.0, LiveSQLBench" with their real numbers (table counts, dialects, reproducibility) signals you did the
   homework and disarms the "didn't they already do this?" reviewer. Cite this document.
3. **Adopt, don't reinvent, the good metrics.** Use **execution-equality** as the spine (Spider/BIRD
   lineage). Add **retrieval-recall@k / table-F1** as the headline isolated axis (BEAVER precedent). Consider
   an **efficiency/VES-style** secondary score (BIRD precedent) since millions of rows make it meaningful.
   Citing the lineage *strengthens* credibility.
4. **Make reproducibility the loud, verifiable claim.** "One `make` target → Postgres 16 + deterministic
   seed + compressed dump, byte-stable, no cloud account" is something **none** of the big-schema rivals can
   say (Spider 2.0 needs BigQuery/Snowflake; BEAVER is private). This is the *honest* moat — it's checkable,
   not a difficulty boast.
5. **State the contamination posture plainly.** A freshly-generated synthetic schema is contamination-
   resistant *today* but not forever (cf. LiveSQLBench's rolling hidden-test design). Say so; optionally
   reserve a held-out generation seed for a hidden split rather than claiming permanent immunity.
6. **Quantify, don't adjective.** Every claim in the README should carry a number and, where comparative, a
   competitor number + citation (this file supplies them). "~220 tables in one schema vs BEAVER's avg 101.5
   across 3 warehouses [cite]" beats "much larger and more realistic."

---

## Appendix: Source index

- Spider 1.0 — https://yale-lily.github.io/spider · https://github.com/taoyds/spider · https://huggingface.co/datasets/xlangai/spider
- Spider 2.0 — https://spider2-sql.github.io/ · https://github.com/xlang-ai/Spider2 · https://arxiv.org/pdf/2411.07763
- Dr.Spider — https://arxiv.org/abs/2301.08881 · https://github.com/awslabs/diagnostic-robustness-text-to-sql
- BIRD — https://bird-bench.github.io/ · https://proceedings.neurips.cc/paper_files/paper/2023/file/83fc8fab1710363050bbd1d4b8cc0021-Paper-Datasets_and_Benchmarks.pdf
- BIRD-Critic / SWE-SQL — https://bird-critic.github.io/ · https://github.com/bird-bench/BIRD-CRITIC-1
- LiveSQLBench — https://livesqlbench.ai/ · https://github.com/bird-bench/livesqlbench
- ScienceBenchmark — https://arxiv.org/abs/2306.04743 · https://arxiv.org/html/2306.04743v2 · https://dl.acm.org/doi/10.14778/3636218.3636225
- Archer — https://arxiv.org/abs/2402.12554 · https://sig4kg.github.io/archer-bench/ · https://blogs.oracle.com/cloud-infrastructure/oracle-wins-archer-nl2sql-challenge
- AmbiQT — https://arxiv.org/abs/2310.13659 · https://github.com/testzer0/ambiqt
- BookSQL — https://aclanthology.org/2024.naacl-long.28/ · https://arxiv.org/abs/2406.07860
- BEAVER — https://arxiv.org/html/2409.02038v3 · https://arxiv.org/abs/2409.02038 · https://beaverbench.github.io/
- BIRD-Ent/Spider-Ent (DRAG) — https://openreview.net/forum?id=gXkIkSN2Ha
- LinkAlign — https://arxiv.org/abs/2503.18596 · https://github.com/Satissss/LinkAlign
- SchemaGraphSQL — https://arxiv.org/pdf/2505.18363

*Compiled June 2026. Citation-tagged numbers verified against linked sources at compile time; re-verify
leaderboard figures before publication as they move monthly.*
