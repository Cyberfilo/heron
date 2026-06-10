# Reuse plan — recognized eval code, reference schema, and external-benchmark adapters to PORT

**Purpose.** Decide exactly which RECOGNIZED, openly-licensed **code** and **data** our benchmark
should *port or reuse* (rather than reinvent), with verified licenses and attribution text, so the
harness is trusted and our execution-equality scoring is comparable to Spider/BIRD. Covers: (1) the
SQL result comparator to port into `harness/run.py`; (2) a small reference schema to bundle as a
sanity-check DB; (3) feasibility of a "unified harness" that ingests Spider / BIRD / LiveSQLBench;
(4) data generators to borrow skew/ideas from. Ends with a concrete REUSE PLAN.

**Research date:** June 2026. Licenses verified against repo LICENSE files / official docs this
session; URLs in §Sources. Re-verify before relying on any figure.

---

## 1 — Scoring / eval code: which comparator to PORT

Three recognized execution-equality comparators exist. Their **code licenses** differ from the
**dataset licenses** they ship with — this distinction is the whole ballgame for reuse.

### 1a. Spider `test-suite-sql-eval` (taoyds) — Apache-2.0 CODE ✅

- **Repo:** https://github.com/taoyds/test-suite-sql-eval — **License: Apache-2.0** (verified
  against the repo LICENSE / GitHub license badge this session).
- **This is now the *official* execution metric of Spider, SParC, CoSQL** (EMNLP 2020, "Semantic
  Evaluation for Text-to-SQL with Distilled Test Suites"). Recognized = high.
- **Comparator semantics** (`exec_eval.py`):
  - `eval_exec_match()` — top-level; runs predicted vs gold SQL across the DB(s) and compares.
  - `result_eq(result1, result2, order_matters)` — the core comparison. **Bag (multiset)
    semantics**: uses `multiset_eq()` so duplicate rows must match in count, not just presence.
  - **Order sensitivity is keyed off `ORDER BY`**: if the gold query has `ORDER BY`,
    `order_matters=True` and row sequence must match; otherwise rows are compared unordered.
  - **Column-permutation tolerance**: `get_constraint_permutation()` enumerates column reorderings
    (sampled to ~20 rows to bound the combinatorics) so a prediction with columns in a different
    order still matches. `unorder_row()` normalizes within-row element order for the unordered case.
- **Note on the Spider *dataset*:** the Spider data/questions are **CC BY-SA 4.0** (share-alike) —
  see https://yale-lily.github.io/spider — but the **eval code in this repo is Apache-2.0**, so we
  can port the code under Apache terms without inheriting CC BY-SA on our harness.
- **Original Spider `evaluation.py`:** https://github.com/taoyds/spider/blob/master/evaluation.py —
  same Apache-2.0 repo; older `--etype exec`/`match` script. Superseded by `test-suite-sql-eval`
  for execution accuracy. Port the test-suite version, not this one.

### 1b. BIRD official eval (`bird-bench`) — code in CC BY-SA 4.0 repos ⚠️

- **Repo:** https://github.com/bird-bench/mini_dev (and the main BIRD repo). The repo/datasets are
  marked **CC BY-SA 4.0** (verified). Scripts: `evaluation_ex.py` (execution accuracy / EX),
  `evaluation_ves.py` (R-VES, valid-efficiency), `evaluation_f1.py` (soft-F1).
- **Comparator:** EX compares the gold vs predicted **result sets** (set-of-rows equality on
  execution against the SQLite/Postgres DB). R-VES additionally weights by runtime efficiency.
- **License caveat:** because BIRD ships its eval **inside CC BY-SA 4.0 repos**, copying that script
  text into our harness risks pulling **share-alike** obligations onto whatever file we paste it in.
  **Do not copy BIRD's eval source.** If we want BIRD-style EX we **re-implement** it (set-equality
  is a standard idea, not copyrightable) or — better — reuse the Apache-2.0 Spider comparator which
  already covers set/bag equality. Use BIRD only as a *behavioral spec*, not a code donor.

### 1c. Defog `sql-eval` (defog-ai) — Apache-2.0 CODE ✅

- **Repo:** https://github.com/defog-ai/sql-eval — **License: Apache-2.0** (verified against
  https://github.com/defog-ai/sql-eval/blob/main/LICENSE this session; copyright field left as the
  Apache template default).
- **Comparator (`eval/eval.py`, pandas-based):**
  - `compare_query_results()` — runs gold + generated SQL, returns a tuple
    `(exact_match: bool, subset_match: bool)`.
  - `compare_df()` — exact equality after normalization; uses pandas `assert_frame_equal` with
    `check_dtype=False`.
  - `subset_df()` — checks whether the **gold** result is a **subset** of the generated result
    (matches columns by sorted values, ignores column *names*/aliases, ignores row order, ignores
    dtypes) — tolerant of harmless extra columns.
  - `normalize_table()` — **sorts columns alphabetically by name; dedups + sorts rows from first
    column to last UNLESS the query has `ORDER BY` (then it sorts by the ORDER BY columns); fills
    NaN with a sentinel (`-99999`); resets index.** This is the most *alias/column-order tolerant*
    comparator of the three.
- **Caveat on the *model*, not the eval:** Defog's **SQLCoder model weights** are CC BY-SA 4.0 /
  OpenRAIL — irrelevant to us; we only port the **eval code**, which is **Apache-2.0**.

### 1d. RECOMMENDATION — what to port into `harness/run.py`

**Port the Spider `test-suite-sql-eval` `result_eq`/`eval_exec_match` core (Apache-2.0) as the
PRIMARY comparator, and additionally implement Defog-style normalization (Apache-2.0) as a
configurable "lenient" mode.** Rationale:

1. **Recognition.** Spider's test-suite metric is *the* recognized execution-accuracy metric in the
   field; using it makes our numbers directly legible to anyone who knows Spider/BIRD.
2. **Correct default semantics for our schema.** Bag/multiset equality + `ORDER BY`-aware ordering
   is exactly right for a relational benchmark (duplicates and ordering are meaningful).
3. **Both are Apache-2.0** — no share-alike contamination of our harness (which we keep
   Apache-2.0 or MIT to match `prq`'s ecosystem).
4. **Two modes for honesty:** a **strict** mode (Spider bag-equality, column-permutation tolerant)
   as the headline score, plus an optional **lenient/subset** mode (Defog) for diagnostics on
   "right answer, extra columns/aliases." Report strict as the official number.

**Attribution text to ship** (e.g., in `harness/THIRD_PARTY_NOTICES.md` and a header comment in
`harness/eval.py`):

```
Portions of the SQL execution-equality comparator are adapted from
test-suite-sql-eval (https://github.com/taoyds/test-suite-sql-eval),
Copyright the Spider/Yale-LILY authors, licensed under Apache License 2.0,
and from defog-ai/sql-eval (https://github.com/defog-ai/sql-eval),
licensed under Apache License 2.0. A copy of the Apache 2.0 license is
included in LICENSES/Apache-2.0.txt. Changes: re-targeted at PostgreSQL 16,
adapted result fetching to psycopg3, added multiset + subset modes.
```

(Apache-2.0 §4 requires: retain copyright/notice, state changes, include the license — the block
above plus a bundled `LICENSES/Apache-2.0.txt` satisfies this.)

---

## 2 — Small Postgres schema to BUNDLE as the "sanity-check" reference

We want one tiny, universally-recognized Postgres schema shipped *inside* the harness as a smoke
test (prove the runner + comparator work end-to-end on a familiar DB before touching our 221-table
beast).

| Candidate | License (verified) | Tables | Native Postgres? | Verdict |
|---|---|---|---|---|
| **Pagila** | **PostgreSQL License** ✅ (permissive, BSD/MIT-like; redistributable) | ~21 (+ partitioned `payment`) | **Yes — built for Postgres** | **RECOMMENDED** |
| Chinook | MIT / public-ish (varies by port) | ~11 | Port needed | Fine but less "Postgres-native"; Pagila better |
| Northwind-postgres | Varies by port (often MIT) | ~13 | Community port | Recognizable but port-quality varies; Pagila better |

**RECOMMENDATION: bundle Pagila.**
- **License: PostgreSQL License** — permissive, explicitly allows redistribution/modification, no
  share-alike. Safe to ship a copy in-repo (with its license file). Verified at
  https://github.com/devrimgunduz/pagila.
- **Download / clone:** `https://github.com/devrimgunduz/pagila.git`. Files: `pagila-schema.sql`
  (DDL), `pagila-data.sql` (COPY-format data) or `pagila-insert-data.sql` (INSERT-format),
  `pagila-schema-jsonb.sql` (JSONB variant). ~21 tables: `actor`, `film`, `customer`, `rental`,
  `inventory`, `payment` (partitioned), `category`, `language`, `staff`, `store`, `address`, etc.
- **Why Pagila over Chinook/Northwind:** it is the *Postgres-native* descendant of Sakila, uses
  real Postgres features (partitioning, `tsvector`, custom types), and is the schema most Postgres
  reviewers already recognize. Bundle it under `harness/fixtures/pagila/` with its license file and
  a `THIRD_PARTY_NOTICES` entry.

---

## 3 — "Unified harness" feasibility: ingesting Spider / BIRD / LiveSQLBench

Our runner is benchmark-agnostic: `(NL question, gold SQL, target DB)` → execute both → compare.
An adapter per external benchmark is writable. Key facts and **redistribution constraints**:

### 3a. Spider 1.0
- **Question format:** JSON list; each item has `db_id`, `question`, `query` (gold SQL),
  `query_toks`, `question_toks`, and a parsed `sql` struct (`select`/`from`/`where`/`groupBy`/
  `having`/`orderBy`/`limit`/`intersect`/`except`/`union`). Schemas in a separate `tables.json`
  (per-DB `table_names`, `column_names`, `foreign_keys`, `primary_keys`).
- **DB format:** **SQLite** files, one per `db_id` (~200 DBs). For our Postgres harness, the adapter
  either runs the SQLite DBs via a SQLite executor, or transpiles+loads to PG.
- **License / redistribution:** **dataset CC BY-SA 4.0** (https://yale-lily.github.io/spider). We
  may build an adapter that **points to / downloads** Spider; if we **bundle** any Spider
  questions/DBs, **share-alike applies to that bundled portion** (must keep CC BY-SA 4.0 +
  attribution on it). **Recommend pointer-download, not bundling.**

### 3b. BIRD (dev/mini-dev)
- **Question format:** JSON; each item has `db_id`, `question`, `evidence` (external knowledge /
  hint string — BIRD's signature addition over Spider), `SQL` (gold), and a `difficulty` label
  (simple/moderate/challenging). Schemas via per-DB description files + the DB itself.
- **DB format:** **SQLite** (dev); MySQL/Postgres variants exist for some tracks; ~95 DBs, ~33 GB.
- **Eval:** `evaluation_ex.py` (EX), `evaluation_ves.py` (R-VES), `evaluation_f1.py`.
- **License / redistribution:** **CC BY-SA 4.0** (https://github.com/bird-bench/mini_dev). Same
  share-alike rule: **pointer-download** the DBs/questions; do **not** bundle them into our
  (Apache/MIT) repo, and do **not** copy BIRD's eval scripts (§1b). Adapter reads BIRD's JSON,
  feeds `(question[, evidence], SQL, db)` to our runner.

### 3c. LiveSQLBench (bird-bench)
- **Question format:** JSONL (`livesqlbench_data.jsonl`); each task pairs an unambiguous NL query
  with gold SQL (`sol_sql`), grounded in an external **HKB** (hierarchical knowledge base) provided
  as structured JSON *and* unstructured document form; includes `test_cases`. **Note:** to prevent
  crawl-contamination, fields `sol_sql`, `test_cases`, `external_knowledge` are **withheld from the
  public file** and fetched via their eval flow.
- **DB format:** **PostgreSQL** (template + Docker) — **the most directly compatible** with our PG16
  harness. ~18 DBs, ~54 tables each.
- **License / redistribution:** **CC BY-SA 4.0** (since 2024-04-27;
  https://huggingface.co/datasets/birdsql/livesqlbench-base-full-v1). Pointer-download; withheld
  gold fields mean we must run through their provided flow rather than re-hosting answers.

### 3d. Adapter feasibility summary

| Benchmark | Q format | DB format | Native PG? | Redistribute? | Adapter effort |
|---|---|---|---|---|---|
| Spider 1.0 | JSON (`db_id/question/query`) + `tables.json` | SQLite ×~200 | No | CC BY-SA — **pointer only** | Low |
| BIRD | JSON (`db_id/question/evidence/SQL/difficulty`) | SQLite ×~95 (33 GB) | Partial | CC BY-SA — **pointer only** | Low–Med |
| LiveSQLBench | JSONL (`question/sol_sql/HKB/test_cases`, some withheld) | **PostgreSQL + Docker** | **Yes** | CC BY-SA — **pointer only** | Med (HKB + withheld fields) |

**All three are CC BY-SA 4.0.** Build adapters that **download from the official source at run
time** (a `make fetch-spider` / `fetch-bird` / `fetch-livesqlbench` target) and never check their
data into our repo. This keeps our repo's own license clean while still making the harness
"unified." Cite each source and pass their attribution through.

---

## 4 — Data generators: what to borrow (skew/ideas) vs avoid

| Generator | License (verified) | Borrow what | Verdict |
|---|---|---|---|
| **Faker** (joke2k) | **MIT** ✅ (https://pypi.org/project/Faker/) | Realistic names/emails/addresses/companies providers; seedable RNG (`Faker.seed_instance`) for determinism | **USE** — primary realistic-value source; MIT, seedable → fits our deterministic-seed requirement |
| **Mimesis** | **MIT** ✅ (https://github.com/lk-geimfari/mimesis/blob/master/LICENSE) | Faster bulk generation, locale providers; good for millions-of-rows throughput | **USE** (optional, perf) — MIT |
| **pydbgen** | **MIT** ✅ (https://github.com/tirthajyoti/pydbgen) | Ideas for table-level generation; thin wrapper over Faker | **Ideas only** — small/old; we have our own `seed/generate.py` |
| **pgbench** | **PostgreSQL License** ✅ (ships with Postgres) | The recognized PG load-gen *pattern* and TPC-B-like scaling/`--scale` idea | **Borrow the scaling pattern** — permissive; don't need its tables |
| **TPC-H / TPC-DS `dsdgen`/`dbgen`** | **TPC EULA** ⚠️ (restrictive; redistribution-limited) | **Skew ideas only** — TPC-DS's documented column-value *distributions* and the Zipfian/`s_factor` skew concepts; the *concept* of `Z`-skew on foreign keys | **DO NOT bundle the tools or generated data.** Read the public methodology; re-implement skew ourselves in `seed/generate.py`. The EULA forbids treating their materials as freely redistributable. |

**Net:** generate values with **Faker (MIT, seeded)** for determinism; optionally **Mimesis (MIT)**
for throughput; **re-implement TPC-style skew** (Zipfian/Pareto on tenant sizes, order counts,
event volumes) from the *published distribution ideas* — **never** ship TPC's `dsdgen`/`dbgen`
binaries or their output. pgbench's `--scale` is the recognized, permissive precedent for our
`tiny|small|bench|large` scale factors.

---

## 5 — CONCRETE REUSE PLAN

**(a) Eval code to PORT** → into `harness/eval.py`, consumed by `harness/run.py`:
- **Primary:** Spider `test-suite-sql-eval` `result_eq`/`eval_exec_match` core — **Apache-2.0** —
  retargeted to Postgres 16 / psycopg3. Bag(multiset) equality, `ORDER BY`-aware ordering,
  column-permutation tolerant. This produces our **headline execution-equality score**.
- **Secondary (diagnostic mode):** Defog `sql-eval` `normalize_table`/`compare_df`/`subset_df`
  logic — **Apache-2.0** — re-implemented as a "lenient/subset" mode (alias- & column-order-
  tolerant) for error analysis only.
- **Do NOT port BIRD's eval source** (CC BY-SA share-alike). Re-implement BIRD-style EX behavior if
  needed; the Spider comparator already covers it.
- **Attribution:** ship `harness/THIRD_PARTY_NOTICES.md` + `LICENSES/Apache-2.0.txt` with the
  attribution block in §1d. Keep our harness **Apache-2.0** (or MIT) to match `prq`'s ecosystem and
  avoid any copyleft entanglement.

**(b) Reference schema to BUNDLE** → `harness/fixtures/pagila/`:
- **Pagila** — **PostgreSQL License** — clone from `https://github.com/devrimgunduz/pagila.git`,
  vendor `pagila-schema.sql` + `pagila-data.sql` + Pagila's license file, add a
  `THIRD_PARTY_NOTICES` entry. Used as the harness smoke test (`make sanity`) and as the recognized
  "small familiar DB" the comparator is first proven against.

**(c) External benchmarks to provide ADAPTERS for** (pointer-download, never bundle):
- **Spider 1.0** (CC BY-SA 4.0), **BIRD** (CC BY-SA 4.0), **LiveSQLBench** (CC BY-SA 4.0 — and the
  most PG-native, so first to wire up). Each adapter: `make fetch-<bench>` downloads from the
  official source at run time; an `adapters/<bench>.py` maps their question JSON/JSONL +
  DB to our `(question, gold_sql, db)` runner contract. Pass through their attribution.

**(d) License pitfalls to AVOID:**
1. **CC BY-SA "share-alike" contamination (top pitfall).** Spider, BIRD, LiveSQLBench **datasets**
   and **BIRD's eval scripts** are CC BY-SA 4.0. If we **bundle** their data or **paste** their eval
   code, the share-alike clause attaches to that material — polluting our otherwise-permissive repo
   and forcing CC BY-SA on derivatives. **Mitigation:** pointer-download external data; port only
   the **Apache-2.0** comparators (Spider test-suite + Defog), never BIRD's source.
2. **TPC EULA on data generators (second pitfall).** TPC-H/TPC-DS `dbgen`/`dsdgen` and their output
   are under a **restrictive TPC EULA**, NOT open source — redistribution is limited and they retain
   ownership. **Mitigation:** never ship TPC tools or TPC-generated rows; re-implement skew from the
   public methodology using **Faker/Mimesis (MIT)**. (Also keep clear of Vendure/Spree≥4.10/
   Twenty/EspoCRM/SuiteCRM/Lago/Mautic/Listmonk/FreeScout/Zammad **schema files** — GPL/AGPL — per
   `SCHEMA-PROVENANCE.md`: shapes/names only, never their DDL.)

---

## Sources

Verified against repo LICENSE files / official docs, June 2026.

- Spider test-suite eval (Apache-2.0 code): https://github.com/taoyds/test-suite-sql-eval ; `exec_eval.py` comparator: https://github.com/taoyds/test-suite-sql-eval/blob/master/exec_eval.py
- Original Spider eval (Apache-2.0): https://github.com/taoyds/spider/blob/master/evaluation.py
- Spider dataset license (CC BY-SA 4.0): https://yale-lily.github.io/spider
- BIRD eval + dataset (CC BY-SA 4.0): https://github.com/bird-bench/mini_dev ; https://bird-bench.github.io/
- Defog sql-eval (Apache-2.0 code): https://github.com/defog-ai/sql-eval ; comparator: https://github.com/defog-ai/sql-eval/blob/main/eval/eval.py ; LICENSE: https://github.com/defog-ai/sql-eval/blob/main/LICENSE
- LiveSQLBench (CC BY-SA 4.0, PostgreSQL): https://github.com/bird-bench/livesqlbench ; https://huggingface.co/datasets/birdsql/livesqlbench-base-full-v1 ; https://livesqlbench.ai/
- Pagila (PostgreSQL License): https://github.com/devrimgunduz/pagila
- Faker (MIT): https://pypi.org/project/Faker/ ; https://github.com/joke2k/faker
- Mimesis (MIT): https://github.com/lk-geimfari/mimesis/blob/master/LICENSE
- pydbgen (MIT): https://github.com/tirthajyoti/pydbgen
- pgbench (PostgreSQL License): https://www.postgresql.org/docs/current/pgbench.html ; PostgreSQL License: https://www.postgresql.org/about/licence/
- TPC-H/TPC-DS tools (TPC EULA, restrictive): https://www.tpc.org/tpcds/ ; https://github.com/gregrahn/tpcds-kit ; sample EULA: https://github.com/tsafin/tpch-tools/blob/master/EULA.txt
