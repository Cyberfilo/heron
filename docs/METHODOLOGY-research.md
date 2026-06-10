# Scoring & Metrics for a State-of-the-Art Text-to-SQL Benchmark

> Research brief for the PromptQuery NL-to-SQL benchmark (multi-tenant B2B SaaS commerce schema,
> ~220 FK-linked tables, 14 domains, Postgres 16, execution-equality scoring, a "schema-retrieval
> at scale" axis). Topic owner: **Scoring & Metrics + retrieval-axis scoring**.
> Date: June 2026. Sources are cited inline; numbers are tagged **[VERIFIED]** (from a cited source)
> vs **[PRIOR]** (model prior knowledge, treat as needing confirmation).

---

## 0. TL;DR recommendations (the detail is below)

1. **Primary metric = Execution Accuracy (EX)** with a *carefully specified result-set comparator*
   (order-sensitive only when gold has `ORDER BY`, bag/multiset semantics, column-permutation tolerant,
   typed NULL/float handling). Borrow the comparator design from Spider's distilled-test-suite
   `exec_eval.result_eq`, not a naive `==`.
2. **Mitigate single-db-state false positives** the way the Spider Test-Suite paper does — but since we
   own a *deterministic generator*, do it more cheaply: evaluate each item against **2–3 independently
   seeded database states** ("fuzz states") and require the prediction to match the gold on *all* of them.
   This is the cheap local equivalent of "distilled test suites."
3. **Report two scores per axis, never one number.** End-to-end: `EX` (primary) + `EX@k` for
   nondeterminism. Retrieval: **macro Table-Recall@k** AND **Set-Recall (all-tables-hit rate)** —
   the second is the one that actually predicts downstream SQL success.
4. **Skip BIRD's VES as a headline metric.** Efficiency scoring (VES/R-VES) is hardware- and
   data-distribution-dependent and has been criticized; if you want an efficiency signal, report
   R-VES *as a secondary diagnostic only*, computed by repeat-and-take-best.
5. **Gold must be deterministic and audited.** The biggest documented failure mode of every prior
   benchmark is *bad gold* (52.8% of BIRD Mini-Dev, 66.1% of Spider 2.0-Snow items had annotation
   issues). Our generator-produced gold + an audit checklist is our single biggest competitive edge.

---

## 1. Execution Accuracy (EX) vs Exact-Set-Match (EM/ESM)

### Definitions
- **Exact Match / Exact Set Match (EM/ESM):** compares the *predicted SQL string/AST* to the gold SQL,
  not its result. Spider implements this as **"Exact Matching without Values"**: it parses each SQL
  clause (SELECT, WHERE, GROUP BY, ORDER BY, …) into *order-invariant bags of sub-components* and checks
  every clause matches. E.g. `SELECT avg(col1), max(col2), min(col1)` becomes the set
  `{(avg,col1),(max,col2),(min,col1)}`; `SELECT col1, col2` and `SELECT col2, col1` are treated as equal.
  Crucially it **ignores literal values** in the WHERE clause (hence "without values"). Source:
  [Spider eval README](https://github.com/taoyds/spider/blob/master/evaluation_examples/README.md),
  [DeepWiki: Spider evaluation metrics](https://deepwiki.com/taoyds/spider/3.1-evaluation-metrics),
  [Spider paper, arXiv 1809.08887](https://ar5iv.labs.arxiv.org/html/1809.08887).
- **Execution Accuracy (EX):** run both predicted and gold SQL on the database and compare the
  *returned result sets*; score 1 if equal, 0 otherwise. This is the metric Spider 2.0 and BIRD use as
  the headline number. Spider 2.0: "an output SQL is considered correct if it returns a multiset of rows
  identical to the reference when executed on the correct database." Source:
  [Spider 2.0 site](https://spider2-sql.github.io/),
  [BIRD paper, arXiv 2305.03111](https://arxiv.org/abs/2305.03111).

### Why EM is both too strict and too loose
- **Too strict (false negatives):** semantically identical queries with different surface form
  (different join order, `IN` vs `EXISTS`, equivalent sub-selects, alias differences) are scored wrong.
  The literature is explicit: "Exact Set Match suffers from significant false negatives, with
  semantically equivalent queries with different syntactic representations incorrectly failing"
  ([Querio: 5 metrics](https://querio.ai/articles/metrics-test-text-to-sql-accuracy)).
- **Too loose (false positives):** because Spider's EM **ignores WHERE values**, two queries that differ
  only in a filter constant (`WHERE country='US'` vs `WHERE country='UK'`) match under EM even though
  they're semantically different. Value prediction was simply out-of-scope for Spider's task definition
  ([Spider eval README](https://github.com/taoyds/spider/blob/master/evaluation_examples/README.md)).
- EM is still useful for **regression testing** (a fixed reference suite to detect that a code change
  broke a previously-passing query) — but it must never be the headline metric
  ([Querio](https://querio.ai/articles/metrics-test-text-to-sql-accuracy)).

### Why EX is not free either
- **EX has false positives** from a *single database state*: a wrong query can coincidentally return the
  same rows as the gold on the one db instance you happen to test against (e.g. a filter that's a no-op
  on this data, or two columns that happen to be equal in this snapshot). The Spider Test-Suite paper
  measured this directly (see §2). The combined published figure: "EX and ESM have high false positive
  and negative rates of 11.3% and 13.9% respectively"
  ([Querio](https://querio.ai/articles/metrics-test-text-to-sql-accuracy)).
- EX is **comparison-logic-sensitive**: order, duplicates, NULLs, floats, and column order all change the
  verdict. A naive `==` between result lists is wrong (see §4).

**Recommendation for us:** EX is the primary metric. Report EM-without-values *only* as a secondary
diagnostic / regression signal, never as the headline.

---

## 2. Spider Test-Suite Accuracy / Distilled Test Suites (Zhong, Yu, Klein — EMNLP 2020)

**Paper:** "Semantic Evaluation for Text-to-SQL with Distilled Test Suites,"
[arXiv 2010.02840](https://arxiv.org/abs/2010.02840) /
[ACL Anthology 2020.emnlp-main.29](https://aclanthology.org/2020.emnlp-main.29/) /
[GitHub taoyds/test-suite-sql-eval](https://github.com/taoyds/test-suite-sql-eval).

### Problem it solves
Single-database-state EX produces **false positives**: a semantically wrong query can return the gold
result on one db. Test-suite accuracy approximates true *semantic* (denotational) equivalence by
checking that the prediction matches the gold across *many* database states, not one.

### How it's computed
1. Generate a **large number of randomly generated databases**.
2. **Distill** a small subset that maximizes *code coverage of the gold query* (i.e. picks db states
   that exercise the gold query's branches/predicates so that a behaviourally-different prediction will
   diverge on at least one state).
3. At eval time, compute **denotation (result) accuracy of the prediction over the entire distilled
   suite**. Passing all of them is a **tight upper bound on semantic accuracy**.
   Source: [arXiv 2010.02840](https://arxiv.org/abs/2010.02840).

### Magnitude of the problem it fixes
- The original single-state Spider EX metric had a **2.5% false-negative rate on average and 8.1% in the
  worst case** across the 21 leaderboard models they checked. Distilled-suite accuracy was manually
  verified correct on 100 examples. [VERIFIED — arXiv 2010.02840 abstract.]
- They released distilled suites for **11 text-to-SQL datasets**. [VERIFIED — same.]

### Implementation detail worth copying: the comparator (`exec_eval.result_eq`)
The repo's `exec_eval.py` is the de-facto standard result comparator. Confirmed behaviour:
- **Order sensitivity is keyed on the gold:** `order_matters = 'order by' in gold.lower()`. If the gold
  has `ORDER BY`, comparison is order-sensitive; otherwise results are compared as **unordered multisets**.
- **Duplicates:** uses `multiset_eq` ("whether two bags of relations are equivalent") — i.e. **bag/multiset
  semantics**, duplicates count.
- **Column permutation tolerance:** `get_constraint_permutation` + `permute_tuple` enumerate plausible
  column re-orderings so `SELECT a,b` and `SELECT b,a` can still match.
- **Fast-reject:** `unorder_row` + `quick_rej` cheaply rule out obvious mismatches before the expensive
  permutation search.
  Source: [test-suite-sql-eval/exec_eval.py](https://github.com/taoyds/test-suite-sql-eval).

### Is it worth adopting here? — YES, in an adapted form
- The *concept* (multi-state evaluation to kill single-state false positives) is exactly right and is now
  considered best practice. Spider 2.0 and most serious harnesses inherit this comparator.
- But the *full distillation pipeline* (random-db generation + coverage maximization) is heavy and was
  built because Spider authors did **not** control the data generator. **We do.** Our generator is
  deterministic and seeded.
- **Adapted recommendation:** instead of distilling coverage-maximal random dbs, generate **N
  independent seeded states** of the SAME schema (e.g. seeds `S0` (the canonical scored state), plus
  `S1`, `S2` as "fuzz states" with different value distributions, FK fan-outs, NULL densities, and edge
  rows). Require the prediction to match gold on **all N states** (multi-state EX). This is the cheap,
  deterministic, reproducible local equivalent of distilled test suites and directly attacks the false
  positive problem. Reuse the `result_eq` comparator from the Spider repo for the per-state check.

---

## 3. BIRD's Valid Efficiency Score (VES) and reward-based R-VES

**Paper:** "Can LLM Already Serve as A Database Interface? A BIg Bench for Large-Scale Database Grounded
Text-to-SQLs (BIRD)," [arXiv 2305.03111](https://arxiv.org/abs/2305.03111).
BIRD stats: **95 databases, 33.4 GB total, 12,751 text-to-SQL pairs, 37 professional domains**
[VERIFIED — [emergentmind summary](https://www.emergentmind.com/papers/2305.03111)].
Human EX baseline **92.96%** (recorded Dec 16, 2025); current top leaderboard EX ~**81.95%** (AskData +
GPT-4o), latest entry **May 27, 2026** (Xiaomi Text2SQL, 80.83%)
[VERIFIED — [BIRD leaderboard](https://bird-bench.github.io/)].

### VES definition (intuition + form)
VES integrates **correctness AND execution efficiency**. Conceptually:
```
VES = (1/N) * Σ_n  1(results_n match gold_n) * R(gold_n, pred_n)
R = sqrt( time(gold_n) / time(pred_n) )     # relative speed; >1 if prediction is faster
```
A correct-but-equal-speed query contributes ~1; a correct-and-faster query >1; a correct-but-slower
query <1; an incorrect query contributes 0. (The exact paper notation uses an indicator on result
equality times a runtime-ratio reward. The runtime-ratio form is the one BIRD's own evaluation code
implements.) Source: [BIRD paper](https://arxiv.org/abs/2305.03111),
[VES topic page](https://www.emergentmind.com/topics/valid-efficiency-score-ves).

### R-VES (reward-based VES) — the metric BIRD now uses for test submissions
BIRD replaced the raw time-ratio with **binned reward points** to reduce variance. From the BIRD
Mini-Dev evaluation code, the reward as a function of `time_ratio = time(gold)/time(pred)`:

| time_ratio | reward |
|------------|--------|
| `== 0` (wrong) | 0 |
| `>= 2`   | 1.25 |
| `1 ≤ r < 2` | 1.00 |
| `0.5 ≤ r < 1` | 0.75 |
| `0.25 ≤ r < 0.5` | 0.50 |
| `r < 0.25` | 0.25 |

[VERIFIED — [bird-bench/mini_dev evaluation_ves.py](https://github.com/bird-bench/mini_dev)].
To stabilize the (noisy) timing, BIRD **enlarges the timeout (to 3 s/example) and repeats execution 5
times, reporting only the highest result** [VERIFIED — [mini_dev README](https://github.com/bird-bench/mini_dev)].

### Criticisms of VES / efficiency metrics
- **Hardware & data-distribution dependence:** "to train and evaluate on efficiency, you need ground
  truth about what 'efficient' means for a specific database engine and data distribution"
  ([beancount.io BIRD analysis](https://beancount.io/bean-labs/research-logs/2026/06/06/bird-benchmark-text-to-sql-real-database-gap)).
  Timing is non-reproducible across machines, Postgres versions, cache state, and concurrent load.
- **Penalizes correct-but-slow** queries even when the user would be perfectly happy with the answer
  (same source). A model that writes a clear, correct, slightly-slower query scores worse than an
  obscure fast one — not obviously desirable.
- **High variance** is acknowledged inside BIRD itself (hence repeat-5-take-max + timeout enlargement).
- Optimizing for EX can *reduce* VES because longer/more complex SQL is slower
  ([VES topic page](https://www.emergentmind.com/topics/valid-efficiency-score-ves)).

### Also from BIRD's stack: Soft-F1 (worth knowing)
BIRD Mini-Dev added **Soft-F1**, a partial-credit table-similarity metric that counts matched cells vs
false-positive/false-negative cells across rows, then `P = tp/(tp+fp)`, `R = tp/(tp+fn)`,
`F1 = 2PR/(P+R)`. It is designed to "reduce the impact of column order and missing values." This is a
gentler alternative to binary EX for *diagnostic* reporting.
[VERIFIED — [mini_dev README](https://github.com/bird-bench/mini_dev)].

**Recommendation for us:** Do **not** make VES/R-VES a headline metric — it is not reproducible across
hosts and our benchmark is reproduced *locally on arbitrary user hardware*. If we want an efficiency
signal, report **R-VES as a clearly-labeled secondary diagnostic**, computed repeat-5-take-best with a
fixed timeout, and pin Postgres version + `work_mem`/`shared_buffers` in the harness config so numbers
are at least internally comparable. Consider **Soft-F1 as a secondary partial-credit diagnostic** to see
*how close* a near-miss was.

---

## 4. Result-set comparison: the rules our harness must pin down

A naive comparison of two result lists is wrong in at least six ways. Concrete rules recommended for our
harness, with the rationale and the precedent:

| Dimension | Recommended rule | Rationale / precedent |
|-----------|------------------|-----------------------|
| **Row order** | Order-**sensitive iff the GOLD query contains `ORDER BY`**; otherwise compare as an unordered multiset. | This is exactly Spider's `result_eq` (`order_matters = 'order by' in gold`). Matches user intent: only enforce order when the question asked for it. [test-suite-sql-eval](https://github.com/taoyds/test-suite-sql-eval) |
| **Duplicates** | **Bag/multiset semantics** — duplicate rows must match in count. | Spider 2.0 compares a "multiset of rows"; `multiset_eq` in test-suite eval. SQL is multiset-semantics by default. [Spider 2.0](https://spider2-sql.github.io/), [VLDB formal SQL semantics](http://www.vldb.org/pvldb/vol11/p27-guagliardo.pdf) |
| **Column order / names** | Compare by **position with column-permutation tolerance**, NOT by column name. Allow the gold's column set to match any column permutation of the prediction (Spider's `permute_tuple`). Do **not** require matching aliases/headers. | Models legitimately reorder/alias output columns. Spider's comparator tolerates permutations. Comparing by name punishes correct queries with different aliases. [test-suite-sql-eval](https://github.com/taoyds/test-suite-sql-eval) |
| **NULL handling** | Treat NULL as a first-class value that is **equal to NULL** for result comparison (grouping/`DISTINCT` semantics), even though `NULL = NULL` is *unknown* inside SQL. Sort NULLs to a fixed position when canonicalizing. | SQL groups NULLs together for DISTINCT/GROUP BY even though `=` returns unknown. The comparator must mirror grouping semantics, not predicate semantics. [Databricks NULL semantics](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/sql-ref-null-semantics), [Spark NULL semantics](https://spark.apache.org/docs/latest/sql-ref-null-semantics.html) |
| **Float / numeric tolerance** | Compare floats/`numeric` with an **absolute+relative tolerance** (e.g. `abs(a-b) <= 1e-6 + 1e-6*max(|a|,|b|)`). **Round monetary/`numeric` to the column's declared scale** before comparing. Exact-compare integers, text, dates, booleans. | Aggregates (`AVG`, `SUM` over floats), `ROUND` differences, and float accumulation order cause spurious mismatches. Spider/BIRD comparators normalize numbers; a fixed tolerance is the standard fix. (Prior best-practice — pin the exact epsilon in our config.) |
| **Type coercion** | Canonicalize obvious cross-type equivalences carefully: `1` (int) vs `1.0` (float) vs `'1'` (text) — decide per-column. Default: compare *values after casting to the gold column's type*. Avoid blanket stringification (it hides float/int/format bugs). | Avoids both false positives (stringifying everything) and false negatives (int vs numeric for the same value). (Prior best-practice.) |
| **Empty result** | An empty result set matches gold **only if gold is also empty**. Distinguish "0 rows" from "1 row containing 0" (a `COUNT` returning 0). | Common silent bug: `SELECT COUNT(*) ... WHERE <false>` returns `[(0,)]`, not `[]`. They are different and must not match. (Prior best-practice.) |
| **Value strings in WHERE** | Because we score by **execution**, WHERE values ARE tested implicitly (unlike Spider's value-blind EM). Keep it that way — do not strip values. | Our generator controls the data so value-dependent gold is unambiguous and *should* be enforced. This is strictly better than Spider EM. |

**Canonicalization pipeline (recommended order):** execute → cast each cell to gold column type →
round numerics to declared scale + apply float epsilon → represent NULL as a sentinel → (if gold has no
`ORDER BY`) sort rows by a total order over canonicalized tuples → (within the multiset) allow column
permutation → multiset-compare. This is essentially `result_eq` hardened with explicit type/float rules.

---

## 5. LLM nondeterminism, pass@k, and keeping GOLD deterministic

### The model side is nondeterministic; report it honestly
- **EX@1 (greedy / temperature 0)** is the headline reliability number (lower temp maximizes pass@1).
- **EX@k / pass@k** captures "can the model get it in k tries." Definition: pass@k is the probability
  that ≥1 of k independent samples is correct, estimated *unbiasedly* from `n ≥ k` samples per item via
  `pass@k = E[ 1 − C(n−c, k) / C(n, k) ]` (n samples, c correct), then **macro-averaged over items**.
  Source: [Chen et al. Codex / HumanEval](https://mbrenndoerfer.com/writing/humaneval-code-generation-benchmark-pass-at-k),
  [pass@k unbiased estimator](https://leehanchung.github.io/blogs/2025/09/08/pass-at-k/).
- **Temperature trade-off:** lower temperature → better pass@1; higher temperature → better pass@k for
  k>1 (more diversity). Report the temperature used.
  ([adaptive temperature sampling, arXiv 2309.02772](https://arxiv.org/html/2309.02772)).
- **Caveat:** the unbiased estimator assumes i.i.d. sampling at fixed temperature/prompt; changing any of
  those breaks the statistics ([pass@k discussion](https://leehanchung.github.io/blogs/2025/09/08/pass-at-k/)).

**Recommendation:** Headline = **EX@1 at temperature 0** (deterministic decoding where the provider
supports it). Also report **EX@5 (pass@5)** with `n=10, temperature≈0.6–0.8` as a "capability ceiling"
number. Always log: model id, temperature, top_p, seed (if supported), n. Note that even at temp 0 most
hosted LLMs are not bit-reproducible — so the *model* score is a distribution; run ≥3 seeds and report
mean ± std for EX@1.

### The GOLD side must be 100% deterministic
- Gold SQL is **fixed, version-controlled, and human-audited** — never LLM-generated at eval time.
- Gold *results* are deterministic because the database is built from a **seeded generator** + a
  **pinned `pg_dump`** (pin Postgres major version, locale/collation, and `timezone`). Re-running the
  generator with the same seed must reproduce byte-identical data.
- For multi-state EX (§2), each fuzz state has its own fixed seed; gold is re-executed per state to
  produce that state's expected result. Cache expected results in the repo so scoring needs no LLM and is
  fully offline/reproducible.
- **Determinism traps to pin:** `ORDER BY` without a total tiebreaker (canonicalize gold to have a
  deterministic order or none), `now()`/`random()`/sequences in gold (forbid), collation-dependent text
  sort (pin `LC_COLLATE`), float aggregation order (covered by the epsilon rule).

---

## 6. Scoring the SCHEMA-RETRIEVAL axis ("find the right ~5 tables among 220")

This is our signature axis. The literature converged on **Recall@k** with two complementary forms.

### Metrics used in the literature
- **Macro-average Table-Recall@N** (a.k.a. Recall@k over tables): per item, fraction of *gold tables*
  present in the top-N retrieved tables, averaged over items. This is the primary schema-retrieval
  metric in recent massive-DB papers, e.g. RASL reports `R@5`/`R@15`. RASL explicitly: "we primarily
  evaluate our method using **macro-average Recall@N** with respect to ground truth tables used in each
  SQL query." [VERIFIED — [RASL, Amazon Science](https://assets.amazon.science/1b/95/8f62e89647348f4c4836f6c3040d/rasl-retrieval-augmented-schema-linking-for-massive-database-text-to-sql.pdf)].
  Scale context from RASL: a typical enterprise catalog "with 10,000 tables averaging 50 columns each
  would require over 500,000 schema entities," and BIRD's full-catalog setting they construct has
  **80 dbs / 597 tables / 4,337 columns** (their Table 1) — comparable in spirit to our 220-table schema.
- **Set-Recall / "strict recall" (all-tables-hit rate):** a **binary per-item** metric — 1 iff *every*
  gold table is retrieved, else 0; averaged over items. This is the one that actually predicts downstream
  EX, because *missing a single required table makes the SQL impossible*. Recent work reports "strict
  schema linking recall" (e.g. 97.4% on BIRD-Dev, 91.2% on Spider 2.0-Lite for AutoLink's SRR)
  ([AutoLink, arXiv 2511.17190](https://arxiv.org/pdf/2511.17190);
   [LinkAlign, arXiv 2503.18596](https://arxiv.org/pdf/2503.18596)).
- **Precision / FPR / F1 (table- and column-level):** precision and false-positive-rate matter because
  over-retrieval blows the context budget. NL2SQLBench proposes P/R/F1 at both table and column level
  ([NL2SQLBench, arXiv 2604.16493](https://arxiv.org/pdf/2604.16493)).
- **Known limitation of recall/precision** (call this out in our docs): standard P/R can look high while a
  single missing critical element tanks SQL accuracy — which is *exactly why Set-Recall is the
  decision-relevant metric*
  ([schema-linking survey](https://arxiv.org/html/2408.05109v1)).

### Recommended retrieval metric + reporting format for us
Report a small fixed table, **per difficulty bucket and overall**, at k ∈ {5, 10, 20}:

```
Retrieval axis (k = 5 / 10 / 20):
  Table-Recall@k        (macro avg fraction of gold tables retrieved)      — continuous, diagnostic
  Set-Recall@k          (% items where ALL gold tables retrieved)          — PRIMARY, predicts EX
  Table-Precision@k     (avg fraction of retrieved tables that are gold)   — context-budget cost
  Column-Recall@k       (optional; macro avg over gold columns)            — secondary
  Mean gold-table count, mean retrieval-distance (FK hops from seed)       — calibration context
```

- **Headline retrieval number = Set-Recall@k** at the k our pipeline actually feeds the LLM (e.g. k=20
  for a 220-table schema). Table-Recall@k is the smoother companion curve.
- Also report **"oracle-schema EX gap"**: EX when the model is *given* exactly the gold tables minus EX
  with the model's own retrieval. This isolates how much of end-to-end error is *retrieval* vs
  *generation* — RASL and others use the perfect-schema upper bound this way
  ([RASL](https://assets.amazon.science/1b/95/8f62e89647348f4c4836f6c3040d/rasl-retrieval-augmented-schema-linking-for-massive-database-text-to-sql.pdf),
   [schema-linking survey](https://arxiv.org/html/2408.05109v1)).
- **Retrieval distance** (number of FK hops from the question's "seed" tables to each required table) is a
  natural difficulty knob unique to our FK-dense schema — report Set-Recall sliced by max retrieval
  distance.

---

## 7. Difficulty calibration

### How Spider and BIRD do it
- **Spider** buckets every item into **easy / medium / hard / extra hard** by counting SQL "hardness
  components": presence of `WHERE, GROUP BY, ORDER BY, LIMIT, JOIN, OR, LIKE, HAVING` plus nesting,
  set operations (`INTERSECT/UNION/EXCEPT`), number of aggregations, and number of selected columns.
  More components / nesting → harder. Source:
  [Spider eval README](https://github.com/taoyds/spider/blob/master/evaluation_examples/README.md),
  [DeepWiki](https://deepwiki.com/taoyds/spider/3.3-using-the-evaluator).
- **BIRD** labels **simple / moderate / challenging** but, importantly, grades difficulty by
  *human-required reasoning + external-knowledge use + db value understanding*, not just SQL keyword
  counts — reflecting its "real database" emphasis ([BIRD paper](https://arxiv.org/abs/2305.03111)).

### Recommended calibration scheme for us (multi-axis, not a single label)
Don't collapse to one label; tag each item with **structural** and **retrieval** difficulty axes, then
also publish a single rolled-up bucket for leaderboard convenience.

**Structural difficulty (SQL shape) — derive automatically from gold AST:**
| Signal | Easy | Medium | Hard | Extra |
|--------|------|--------|------|-------|
| # joins | 0–1 | 2–3 | 4–5 | 6+ |
| Aggregation / GROUP BY / HAVING | none | single agg | grouped agg | grouped + HAVING + multi-agg |
| Window functions / CTE / nesting | none | 1 CTE or subquery | window OR recursive CTE | window + multi-CTE / correlated subq |
| Set ops (UNION/INTERSECT/EXCEPT) | none | — | present | present + nested |

**Retrieval difficulty (unique to our 220-table schema):**
| Signal | Easy | Medium | Hard | Extra |
|--------|------|--------|------|-------|
| # gold tables | 1–2 | 3–4 | 5–6 | 7+ |
| Max FK retrieval distance from question seed | 0–1 hop | 2 hops | 3 hops | 4+ hops |
| Lexical ambiguity (decoy tables with similar names/columns) | none | 1–2 decoys | several | heavy (multi-tenant near-duplicates) |
| Cross-domain span (of the 14 domains) | 1 domain | 2 | 3 | 4+ |

**Ambiguity flag (orthogonal):** mark items where the NL question admits >1 defensible gold (e.g.
"top customers" — by revenue? by order count?). Either (a) **disambiguate the question** so gold is
unique (preferred — see §8), or (b) keep an explicit `ambiguous=true` tag and **exclude from the
headline score**, reporting them separately. BIRD's documented pain was exactly under-specified
questions ([Understanding Noise in BIRD, arXiv 2402.12243](https://arxiv.org/abs/2402.12243)).

Roll-up rule: overall bucket = max(structural bucket, retrieval bucket). Always report EX and Set-Recall
**per bucket** as well as overall — a single aggregate number hides where models fail.

---

## 8. Pitfalls that have invalidated past benchmarks — and our checklist

The dominant, repeatedly-documented failure mode is **bad gold and data contamination**, not metric
choice. The evidence is stark and recent:

- **Pervasive annotation errors.** "Text-to-SQL Benchmarks are Broken" (CIDR 2026) audited two benchmarks
  and found an annotation **error rate of 52.8% in BIRD Mini-Dev and 66.1% in Spider 2.0-Snow**
  (items with ≥1 of four error patterns). Re-evaluating five leading agents on the *corrected* set shifted
  scores by **−3% to +31%** (BIRD) and changed **leaderboard rank by up to 3 positions** — e.g. CHESS went
  from 62% to 81% EX and from 4th to 1st. Their four error patterns: **E1** SQL semantics ≠ question intent;
  **E2** SQL ≠ question due to misunderstanding the data/schema; **E3** wrong/misannotated domain knowledge;
  **E4** ambiguity in the question. [VERIFIED — [CIDR 2026, Jin et al.](https://www.vldb.org/cidrdb/papers/2026/p5-jin.pdf)].
- **BIRD-specific noise.** "Understanding the Effects of Noise in Text-to-SQL" found **annotation errors in
  ~32% of BIRD's training set** and **~49% of the financial domain** (52/106 sampled), including **22 wrong
  gold queries** in the analyzed financial slice (20.7%). After correcting gold, **zero-shot GPT-3.5
  outperformed DIN-SQL and MAC-SQL** — i.e. the noise had *inverted* the published ranking.
  [VERIFIED — [arXiv 2402.12243](https://arxiv.org/abs/2402.12243)].
  Concrete error example they cite: annotators misusing `BETWEEN ... AND ...` for a strict inequality.
- **BIRD's binary PASS/FAIL agrees with human experts only ~62% of the time** (a 2025 study), partly
  because of single-state EX false positives + bad gold
  ([Querio/Promethium evaluation guides summarizing the finding](https://promethium.ai/guides/text-to-sql-evaluation-benchmarks-metrics/);
   cross-ref [SQL2NL, arXiv 2509.04657](https://arxiv.org/pdf/2509.04657)).
- **Single-db-state false positives** — the 2.5%–8.1% Spider false-negative rate and the 11.3% EX
  false-positive figure (§1–2).
- **Value typos / type errors in gold** — e.g. lexicographic vs numeric sort on a text column storing
  numbers, swapped `ST_POINT(lng,lat)` argument order, `TO_TIMESTAMP` start-vs-end-of-day — all real
  errors catalogued in the CIDR 2026 audit.
- **Data contamination / training-set leakage.** Spider/BIRD are old and on the public web; models may
  have memorized them. "Contamination may inflate scores by 10–30% for models like GPT-4 and Claude 3,"
  and accuracy drops sharply under syntactic paraphrase (a memorization signature).
  ([Benchmark Data Contamination survey, arXiv 2406.04244](https://arxiv.org/html/2406.04244v1);
   [SPENCE contamination probe, arXiv 2604.17771](https://arxiv.org/html/2604.17771v1)).

### Pre-release checklist for OUR benchmark
- [ ] **Every gold query human-reviewed** by someone who didn't write the question; reviewer runs it and
      eyeballs the result. (Targets E1–E4 above.)
- [ ] **No ambiguous gold:** if a question admits >1 defensible answer, rewrite the question to be unique,
      or tag `ambiguous` and exclude from headline. (Targets E4.)
- [ ] **Multi-state validation:** every gold passes the `result_eq` comparator on the canonical state AND
      all fuzz states; investigate any item whose result is identical across states with a *different*
      plausible query (single-state false-positive risk).
- [ ] **Gold is deterministic:** no `now()/random()/uuid_generate`, no collation-dependent or
      tiebreaker-free `ORDER BY`; pin Postgres major version, `LC_COLLATE`, `timezone`.
- [ ] **Value/type audit:** check numeric-vs-text sort, date boundary semantics (inclusive/exclusive),
      `BETWEEN` misuse, geo arg order, unit consistency. (Directly from the CIDR audit's recurring bugs.)
- [ ] **Contamination defense:** the schema + data are *newly generated*, never published as gold-SQL on
      the web; keep gold SQL out of any crawlable location; optionally hold out a private test split and
      run a SPENCE-style paraphrase-robustness spot-check.
- [ ] **Comparator unit tests:** explicit test cases for order sensitivity, duplicates, NULL equality,
      float epsilon, empty-vs-zero, column permutation (mirror Spider's `test_suite` cases).
- [ ] **Difficulty labels validated:** spot-check that auto-derived structural/retrieval buckets match
      human judgement on a sample.
- [ ] **Publish the comparator + seeds + Postgres config** so any third party reproduces identical scores.

---

## 9. Concrete recommendations for `run.py` / the harness

1. **Metrics emitted (per item + aggregated, per difficulty bucket + overall):**
   - `ex@1` (temp 0, greedy) — **headline**, multi-state (must pass on all N seeded states).
   - `ex@5` (pass@5, unbiased estimator, n=10, temp ≈0.7) — capability ceiling.
   - Retrieval: `table_recall@{5,10,20}`, **`set_recall@{5,10,20}` (headline retrieval)**,
     `table_precision@k`, optional `column_recall@k`.
   - `oracle_schema_ex` (EX given gold tables) and the **retrieval gap** = `oracle_schema_ex − ex@1`.
   - Secondary diagnostics: `em_without_values` (regression signal), `soft_f1` (partial credit),
     `r_ves` (clearly labeled, repeat-5-take-best, pinned PG config) — none of these are headline.

2. **Result comparator = a hardened `result_eq`:** vendor the Spider test-suite comparator logic
   (order-from-gold, multiset, column-permutation) and add explicit **typed cell normalization**:
   float epsilon (`1e-6` abs + rel), numeric rounded to declared scale, NULL sentinel, empty≠zero,
   cast-to-gold-type. Ship it with unit tests.

3. **Multi-state EX:** build N=3 seeded states (`S0` canonical + `S1`,`S2` fuzz). Cache each state's gold
   result in-repo. Score = AND over states. This is our cheap, deterministic stand-in for distilled test
   suites and our defense against single-state false positives.

4. **Determinism contract in the harness header:** assert Postgres major version, `LC_COLLATE`,
   `timezone`, and `statement_timeout`; refuse to score if they differ from the pinned config. Set the
   session read-only (you already do this in PromptQuery's `db.py`) and reuse that safety layer.

5. **Provenance logging:** for every run, log model id, provider, temperature, top_p, seed, n, prompt
   hash, retrieval-k, comparator version, dataset version, PG version → so scores are auditable and
   reproducible.

6. **Reporting format:** a compact table — rows = difficulty buckets (easy/medium/hard/extra ×
   structural and retrieval), columns = `ex@1`, `ex@5`, `set_recall@k`, `retrieval_gap` — plus the
   retrieval-distance slice. One headline number is forbidden; always show the breakdown.

7. **Do NOT adopt as headline:** raw VES/R-VES (hardware-dependent), EM-with/without-values (too
   strict+loose), single-state EX (false positives). Keep them only as labeled diagnostics.

---

## Source index (primary)
- Spider eval & test-suite: [taoyds/spider](https://github.com/taoyds/spider/blob/master/evaluation_examples/README.md),
  [taoyds/test-suite-sql-eval](https://github.com/taoyds/test-suite-sql-eval),
  [DeepWiki metrics](https://deepwiki.com/taoyds/spider/3.1-evaluation-metrics).
- Distilled test suites: [arXiv 2010.02840](https://arxiv.org/abs/2010.02840) /
  [ACL 2020.emnlp-main.29](https://aclanthology.org/2020.emnlp-main.29/).
- BIRD: [arXiv 2305.03111](https://arxiv.org/abs/2305.03111),
  [leaderboard](https://bird-bench.github.io/), [mini_dev (R-VES, Soft-F1)](https://github.com/bird-bench/mini_dev).
- Spider 2.0: [site](https://spider2-sql.github.io/), [GitHub](https://github.com/xlang-ai/Spider2),
  [ICLR'25 paper](https://proceedings.iclr.cc/paper_files/paper/2025/file/46c10f6c8ea5aa6f267bcdabcb123f97-Paper-Conference.pdf).
- Schema retrieval at scale: [RASL (Amazon Science)](https://assets.amazon.science/1b/95/8f62e89647348f4c4836f6c3040d/rasl-retrieval-augmented-schema-linking-for-massive-database-text-to-sql.pdf),
  [AutoLink arXiv 2511.17190](https://arxiv.org/pdf/2511.17190),
  [LinkAlign arXiv 2503.18596](https://arxiv.org/pdf/2503.18596),
  [NL2SQL survey arXiv 2408.05109](https://arxiv.org/html/2408.05109v1).
- Annotation-error / noise pitfalls: [CIDR'26 "Benchmarks are Broken"](https://www.vldb.org/cidrdb/papers/2026/p5-jin.pdf),
  [Understanding Noise in BIRD arXiv 2402.12243](https://arxiv.org/abs/2402.12243).
- Contamination: [survey arXiv 2406.04244](https://arxiv.org/html/2406.04244v1),
  [SPENCE arXiv 2604.17771](https://arxiv.org/html/2604.17771v1).
- pass@k: [HumanEval/Codex](https://mbrenndoerfer.com/writing/humaneval-code-generation-benchmark-pass-at-k),
  [unbiased estimator](https://leehanchung.github.io/blogs/2025/09/08/pass-at-k/).
- SQL/NULL semantics: [VLDB formal SQL semantics](http://www.vldb.org/pvldb/vol11/p27-guagliardo.pdf),
  [Databricks NULL semantics](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/sql-ref-null-semantics).
