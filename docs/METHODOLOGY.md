# Methodology — how heron scores

This is the canonical scoring spec that `harness/run.py` implements. It is grounded in the
text-to-SQL evaluation literature (Spider test-suite accuracy, BIRD EX/VES, BEAVER subtask F1, and
the 2025–26 schema-linking work); see `docs/METHODOLOGY-research.md` for the cited survey behind
each choice. Design rule: **adopt the field's proven metrics, don't reinvent them; innovate only on
the retrieval axis and on gold quality.**

---

## 0. The thing we got to control that others didn't: gold quality

The single most damaging failure mode in published benchmarks is **wrong gold answers**, not the
choice of metric. A CIDR-2026 audit found annotation errors in **52.8%** of BIRD Mini-Dev and
**66.1%** of Spider 2.0-Snow items, and correcting the gold *reordered the leaderboard* (one system
went 4th→1st). Because heron **owns a deterministic generator and writes its own gold SQL
against a schema it defines**, we can make gold-quality the headline advantage:

- Every gold query is **executed at authoring time** against a freshly seeded DB and its result is
  inspected (non-empty unless the question is intentionally an empty-set probe; sane row counts).
- Gold is **multi-state validated** (see §2) — a gold query that returns different shapes across
  seeds is a buggy gold and is rejected.
- The pre-release **audit checklist** (§6) is run before any number is published.

---

## 1. Primary metric — Execution Accuracy (EX)

A prediction is correct iff its **result set equals the gold result set** under the comparator in
§1.1. This is the Spider/BIRD standard ("did the query actually return the right data"), and it is
strictly better than exact-SQL-string or AST match, which punish correct paraphrases and reward
wrong-but-similar SQL.

### 1.1 The result-set comparator (`result_eq`)

Two result sets compare **equal** under these rules (a hardened version of Spider's `result_eq`):

1. **Bag semantics by default.** Rows are compared as a **multiset** — duplicate rows must match in
   multiplicity. (Aggregations and `DISTINCT` are part of correctness; silently de-duping would
   hide errors.)
2. **Order-insensitive UNLESS gold has `ORDER BY`.** If the gold SQL's outermost query has an
   `ORDER BY`, row order is enforced; otherwise both sides are sorted before comparison. (NL rarely
   pins an order unless it asks for "top/first/sorted".)
3. **Column-permutation tolerant.** NL does not fix column order or names. Following Spider, we
   accept the prediction if there exists a one-to-one mapping of predicted columns to gold columns
   under which the (multiset of) rows match. Implemented as: for the gold column count *c*, search
   permutations of predicted columns (capped; if predicted column count ≠ *c*, fail fast).
4. **Typed value equality:**
   - `NULL == NULL` (within a tuple position).
   - **Floats**: equal within `abs_tol = 1e-6` or `rel_tol = 1e-6` (whichever passes). Money
     `numeric` is compared exactly after normalizing scale.
   - **Decimals/ints**: exact after numeric normalization (`Decimal('10.0') == 10`).
   - **Strings**: exact, case-sensitive (the data layer already encodes intended casing); whitespace
     is **not** trimmed.
   - **bool / date / timestamptz / uuid**: native equality after parsing.
5. **Empty results** match **only** an empty gold. (A blank answer is not a free pass.)

The comparator is intentionally strict on *what the data is* and lenient on *how it's shaped*
(column order/name), matching how a human judges "is this the right answer."

### 1.2 Multi-state EX — killing single-state false positives

Evaluating against **one** database state produces false positives: a query like
`SELECT ... WHERE status='paid'` may coincidentally match gold on one seed while being semantically
wrong. Spider's distilled-test-suite paper measured single-state false-negative rates of
**2.5–8.1%**, and the field reports material false-positive rates too.

We can fix this cheaply *because we own the generator*: heron ships **N=3 independently-seeded
database states** of the same schema at the evaluation scale (`small` by default). A prediction
counts as **EX-correct only if `result_eq(pred, gold)` holds on ALL N states.** This is heron's
headline number: **multi-state EX@1** (single sample, temperature 0).

### 1.3 Nondeterminism — `EX@1` headline, `EX@k` ceiling

LLMs sample. We separate two questions:
- **`EX@1` (headline):** one prediction per question at **temperature 0** (deterministic-as-possible
  decoding). This is what a user actually gets and is comparable across systems.
- **`EX@k` (capability ceiling):** *k* samples (default `k=5`, temperature 0.7), scored with the
  **unbiased pass@k estimator** (Chen et al. 2021). Reported alongside, never as the headline —
  it answers "could the system do it" not "does it reliably".

The **gold side is always deterministic** (fixed SQL, fixed seeded DB).

---

## 2. The signature axis — schema retrieval at scale

The differentiator: before a system can write SQL over ~220 tables, it must **find the right ones**.
We measure this in isolation, following BEAVER's table-retrieval-F1 precedent and the 2025 schema-
linking literature (RASL/LinkAlign), which converged on these metrics.

Each question carries a hand-labeled **`gold_tables`** set (the tables any correct SQL must
reference). For a system that exposes its retrieved/selected table set `pred_tables`:

- **Set-Recall@k (headline):** binary — did `pred_tables` (top-k) contain **every** gold table?
  This is the metric that *predicts downstream EX*, because **one missing table makes the SQL
  impossible**. Reported as the fraction of questions with full coverage.
- **Table-Recall@k:** mean per-question fraction of gold tables retrieved (partial credit).
- **Precision@k:** how much noise the system pulled in (efficiency of retrieval).
- **Oracle-schema EX gap:** EX when the system is *handed* the gold tables, minus EX when it must
  retrieve them itself. This **separates retrieval error from generation error** — a unique
  diagnostic heron can offer because it controls both the schema and the harness.

Retrieval results are **sliced by FK retrieval distance** (how many FK hops from a table named in
the question to a required-but-unnamed join table), because distance-2+ joins are where naive
keyword retrieval collapses.

> Systems that do **not** expose an intermediate table set (pure end-to-end "schema → SQL") are
> still scored on EX; their retrieval axis is reported as "n/a (end-to-end)". The retrieval axis is
> an *additional* lens for systems with a retrieval stage (the whole point of PromptQuery-class
> tools), not a precondition for the leaderboard.

---

## 3. Efficiency & robustness metrics (alongside EX, never replacing it)

EX answers "is the answer right". The SQL the tool *wrote* also has a cost — a correct-but-O(n²)
query is observably slower here because the DB has millions of rows. We measure that directly.

- **VES — Valid Efficiency Score (BIRD).** For each question, reward = `sqrt(gold_ms / pred_ms)`
  **if the prediction is execution-correct**, else `0`. The aggregate is `100 · mean(reward)` over the
  questions whose gold executes. Reading: **100 = the tool's correct queries are, on average, as fast
  as the hand-written gold**; >100 = faster; <100 = slower. `sqrt` damps timing noise; a single reward
  is capped at 3.0 so a near-zero `pred_ms` can't dominate the mean. This is the canonical BIRD VES
  (we use it rather than the image-encoded R-VES buckets, which aren't specified in text). Efficiency
  is **hardware-dependent in absolute terms**, so it never gates EX — but because every tool is timed
  on the *same machine in the same run*, it is a fair *relative* efficiency comparison, and it feeds
  the efficiency sub-score of the Grade (§7).
- **Timing protocol (stable-ish on one box).** Each query (gold and predicted) is run once to warm
  caches (that time discarded), then `TIMING_REPS=5` more times with the **minimum** kept — the min is
  the run least perturbed by OS scheduling, the same intent as BIRD's "repeat and take the best".
  Queries already slower than 5 s are measured once (cost control). `harness/run.py` records
  per-question `exec_ms` (predicted) and `gold_exec_ms`.
- **Soft-F1 (robust correctness).** Row-multiset F1 between the predicted and gold result sets,
  `2·|gold ∩ pred| / (|gold| + |pred|)` over the best column alignment (BIRD-2.0-style, table-level).
  Reported alongside EX as partial credit: it distinguishes "completely wrong" from "almost right"
  (one missing row, an extra column), which a binary EX hides. Diagnostic — EX stays the headline.
- **Exact-set-match (EM):** reported for continuity with old Spider numbers, flagged as
  simultaneously too strict (punishes valid paraphrases) and too loose (rewards wrong constants).
  Diagnostic only.

---

## 4. Difficulty calibration — two orthogonal axes

A single "hard/medium/easy" label hides what makes a question hard. heron labels **two axes**
and reports **per-bucket**, never one aggregate:

- **SQL structural complexity** (`sql_shape`): from the gold SQL — number of joins, aggregation,
  `GROUP BY/HAVING`, subqueries/CTEs, window functions, set ops. Buckets: `single` / `join` /
  `multi-join` / `analytical`.
- **Retrieval difficulty** (`retrieval`): how hard it is to *find* the tables — max FK distance from
  a question-named entity to a required table, plus lexical-mismatch flag (question says "invoice",
  table is `billing.invoices`; or worse, a synonym the schema never uses). Buckets: `named` /
  `1-hop` / `2-hop+` / `lexical-gap`.

A question's tags also record traps it probes (e.g. `tenant-isolation`, `soft-delete`, `nullable-fk`,
`currency-mix`, `time-bucket`). Aggregate scores are always accompanied by the bucket breakdown.

---

## 5. What a published number must always state

Every headline number is reported with its full conditions, e.g.:

> **multi-state EX@1 = 0.xx** — model `<id>`, temperature 0, single sample, scored on N=3 seeded
> `small`-scale states with the `result_eq` comparator; retrieval Set-Recall@25 = 0.xx. Per-bucket
> table below.

No bare "xx% accurate" is ever published. (Same discipline as the parent project's facts sheet.)

---

## 6. Pre-release audit checklist (run before publishing any leaderboard)

Because bad gold invalidates benchmarks, every release passes:

- [ ] **Every gold query executes** on a freshly seeded DB with no error.
- [ ] **Every gold result is non-empty** unless the question is tagged `empty-set-probe`.
- [ ] **Multi-state stable:** each gold returns the *same shape* and *consistent* result across the
      N seeded states (counts may scale, structure must not change).
- [ ] **`gold_tables` ⊇ tables actually referenced** by the gold SQL (parsed via `sqlglot`); no
      missing or spurious entries.
- [ ] **No duplicate questions** (normalized text) and no two questions with identical gold SQL but
      different labels.
- [ ] **Ambiguity check:** a second author can reproduce the gold from the NL alone; ambiguous
      items are either reworded or moved to an explicit `ambiguous` split.
- [ ] **Difficulty buckets populated** across both axes (no empty cells that would skew aggregates).
- [ ] **Contamination posture stated:** generation seed for the public split is disclosed; a
      **held-out seed** is reserved for a future hidden split (we claim contamination-*resistance*,
      not permanent immunity).

---

## 7. The Grade — one 0–100 number per tool

A leaderboard with eight columns is honest but hard to read at a glance. The **Grade** collapses the
measured axes into one transparent 0–100 score (`harness/grade.py`). It is a weighted blend of five
sub-scores, each normalized to 0–100:

| Sub-score | What | Source | Weight |
|---|---|---|---:|
| **EX** | correctness | `ex_at_1` | 0.45 |
| **EFF** | efficiency of the SQL written | `min(100, VES)` | 0.20 |
| **REL** | reliability | `100·(1 − errors/n)` | 0.10 |
| **TOK** | token economy ($) | `100·(min_tok_in_field / tok)`, capped 100 | 0.15 |
| **LAT** | end-to-end latency | `100·(min_total_ms_in_field / total_ms)`, capped 100 | 0.10 |

`grade = Σ wᵢ·dimᵢ / Σ wᵢ`, renormalized over the dimensions a tool actually exposes (a tool whose
SDK hides token usage simply drops TOK and its weight is redistributed). Design choices, stated:

- **EX dominates (0.45).** Being right is the point; efficiency/economy together are a third of the
  score, so a fast, cheap, *wrong* tool still grades low.
- **EFF caps at 100.** Matching the hand-written gold query's speed is full marks — we don't reward a
  tool for writing a query that happens to beat gold, only penalize one that writes a slow one.
- **TOK and LAT are field-relative.** The most token-frugal (and the fastest) tool *in the run*
  anchors 100; others scale against it. So the Grade compares tools **to each other on this run** — it
  is not an absolute, cross-run constant.
- **Set-Recall is shown but not graded.** End-to-end tools don't expose a retrieved-table set;
  grading an n/a dimension would unfairly punish them. It stays a diagnostic column.

The Grade is a convenience lens over the per-axis table, never a replacement for it — every published
Grade ships next to its EX / VES / tokens / latency breakdown.
