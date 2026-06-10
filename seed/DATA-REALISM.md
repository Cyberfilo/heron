# DATA-REALISM — Generating realistic, deterministic, referentially-consistent synthetic data at scale for Postgres

> Research doc for the NL-to-SQL benchmark generator (`seed/generate.py`). Target DB: single multi-tenant
> B2B SaaS commerce schema, ~220 FK-linked tables, 14 domains, millions of rows, Postgres 16, reproduced
> locally from `(scale, seed)`. Scored by execution-equality, so the generated data must be **byte-identical**
> across machines for a given `(scale, seed)`.
>
> Conventions below: **[VERIFIED]** = backed by a cited source fetched June 2026; **[PRIOR]** = my own
> engineering knowledge, not independently sourced here. Numbers are quoted with their source URL.

---

## 0. Executive summary (the bets)

1. **Use `numpy.random.default_rng(seed)` (PCG64) as the single source of randomness for everything
   quantitative** (IDs, counts, amounts, timestamps, distribution sampling) and treat Faker/Mimesis as a
   *thin, separately-seeded labeller* for human-readable strings only. numpy is vectorized (generate a
   million order amounts in one call) and has an explicit, documented seeding + parallel-stream model
   (`SeedSequence`/`spawn`). [VERIFIED]
2. **Pick Mimesis over Faker for the string layer** — it is ~12× faster (1M names: 13.7s vs 185.9s) and
   produces far more unique values (1M names: 84.8% unique vs 33.0%), which matters at our row counts.
   [VERIFIED]
3. **Load with psycopg3 binary `COPY ... FROM STDIN`, streaming row tuples, never `INSERT`.** COPY is
   ~10–100× faster than per-row INSERT; on commodity hardware expect ~80k rows/s plain, ~370k rows/s with
   indexes deferred, ~660k rows/s into `UNLOGGED` tables. [VERIFIED]
4. **Generate in FK dependency (topological) order, hold integer ID pools in memory, and sample children's
   parents from the parent pool — never random ints.** Tenant isolation and temporal coherence are enforced
   by carrying `tenant_id` and parent timestamps down the dependency graph. [PRIOR]
5. **Determinism is a first-class property, not an afterthought**: pin numpy + Mimesis versions, set
   `PYTHONHASHSEED=0`, derive a child seed per table via `SeedSequence`, forbid Python-`set`/`dict`-iteration
   in the hot path, and run single-threaded (or use `spawn()` per worker). [VERIFIED + PRIOR]

---

## 1. Python string-tooling: Faker vs Mimesis

### 1.1 Speed and uniqueness — the numbers

From the official Mimesis "About" page (Mimesis master / 19.x docs), benchmarking name generation: [VERIFIED]

| Volume | Mimesis time | Mimesis uniqueness | Faker time | Faker uniqueness |
|--------|-------------:|-------------------:|-----------:|-----------------:|
| 10k    | 0.137 s      | 99.88%             | 1.758 s    | 93.63%           |
| 100k   | 1.344 s      | 98.27%             | 17.375 s   | 71.07%           |
| 1M     | 13.685 s     | 84.76%             | 185.945 s  | 33.02%           |

Source: <https://mimesis.name/master/about.html>. The page summarises this as Mimesis being "≈12 times
faster than Faker, and generates more unique data," with no hard third-party dependencies and 47 locales.
Independent write-ups echo the ~12× figure. [VERIFIED]
<https://www.statology.org/building-rich-test-data-mimesis-schemas/>

**Implication for us:** at millions of rows, Faker's name uniqueness collapsing to 33% would create huge
accidental duplicate clusters in customer/contact names — fine for "dirty realism" but bad if you want
*controlled* duplicate rates. Mimesis gives both speed and a higher unique baseline you can then *deliberately*
degrade. Faker remains fine for prototyping or where you need a provider Mimesis lacks. [PRIOR]

### 1.2 Determinism / seeding

- **Faker**: `Faker.seed_instance(n)` (per-instance) or `Faker.seed(n)` (global, legacy shared
  `random.Random`). Faker's own docs warn the global/shared-`random.Random` legacy behaviour "can only become
  more confusing"; prefer `seed_instance`. The `.unique` proxy is backed by a `set`, so only hashable
  values work and it can exhaust/raise. Faker is **not** guaranteed thread-safe (multiple language ports
  document concurrency issues). [VERIFIED] <https://faker.readthedocs.io/en/master/fakerclass.html>,
  <https://github.com/joke2k/faker/blob/master/docs/fakerclass.rst>
- **Mimesis**: accepts `seed=` as `int | str | bytes | bytearray` on any provider, plus `reseed(seed)` to
  reset, `Generic(locale, seed=...)` to seed many providers at once, and a module-level `random.global_seed`.
  It auto-respects `pytest_randomly`'s seed. **Caveat the docs state explicitly:** "some methods of some
  providers cannot be used with seeded providers since their nondeterministic nature" — so you must *test*
  each Mimesis method you depend on for reproducibility rather than assume it. [VERIFIED]
  <https://mimesis.name/master/random_and_seed.html>

**Recommendation:** keep the string RNG (Mimesis) on its **own** seed derived from the master `SeedSequence`,
distinct from the numpy quantitative RNG. Never let Faker/Mimesis touch the global `random` module that your
numeric code also reads. [PRIOR]

### 1.3 numpy for the heavy lifting

`numpy.random.default_rng(seed)` returns a `Generator` backed by **PCG64**, the modern recommended bit
generator. It is fully vectorized — `rng.choice(a, size, p=...)`, `integers`, `normal`, `poisson`,
`lognormal`, `pareto(a)`, `zipf(a)`, `exponential`, `gamma`, `binomial`, etc. all take a `size` and return
arrays in one call. [VERIFIED] <https://numpy.org/doc/stable/reference/random/generator.html>

Critical reproducibility caveat from the same page: **"Generator does not provide a version compatibility
guarantee. In particular, as better algorithms evolve the bit stream may change."** So byte-identical output
across machines requires **pinning the numpy version** (see §8). [VERIFIED]

Generate per-table independent, reproducible streams with `SeedSequence` / `Generator.spawn(n)`: "SeedSequence
expands an initial seed into many independent child seeds — great for creating multiple reproducible streams
(e.g., parallel workers)." [VERIFIED]
<https://www.plus2net.com/python/numpy-random-generator.php>

---

## 2. Fast bulk load into Postgres

### 2.1 COPY vs INSERT — throughput

Measured numbers (Jan 2026 write-up, loading 10M rows): [VERIFIED]
<https://oneuptime.com/blog/post/2026-01-25-load-millions-rows-copy-postgresql/view>

| Method                         | Time   | Throughput        |
|--------------------------------|-------:|------------------:|
| Individual INSERTs             | 45 min | ~3,700 rows/s     |
| Batched INSERTs (1k rows)      | 8 min  | ~20,800 rows/s    |
| COPY (default, with indexes)   | 2 min  | ~83,300 rows/s    |
| COPY, indexes dropped          | 45 s   | ~370,000 rows/s   |
| COPY into `UNLOGGED` table     | 25 s   | ~666,600 rows/s   |

Corroborating orders of magnitude: another 2026 benchmark reports COPY doing 35M records in 260s vs ~1,100s
for batch inserts, and a 10M-row case where single inserts took ~9,000s vs COPY ~14s; the broad claim is
**COPY is 10–100× faster than INSERT** (and "roughly 4× faster than bulk INSERTs" in the conservative case).
[VERIFIED] <https://oneuptime.com/blog/post/2026-01-25-use-copy-command-bulk-import-postgresql/view>,
<https://www.cybertec-postgresql.com/en/bulk-load-performance-in-postgresql/>,
<https://www.citusdata.com/blog/2017/11/08/faster-bulk-loading-in-postgresql-with-copy/>

**Takeaway:** never use INSERT for seeding. COPY is the only correct primitive at our scale.

### 2.2 psycopg3 COPY API (the one we should use)

psycopg3 exposes COPY directly. The streaming pattern (no temp CSV on disk needed): [VERIFIED]
<https://www.psycopg.org/psycopg3/docs/basic/copy.html>, <https://www.psycopg.org/psycopg3/docs/api/copy.html>

```python
records = [(10, 20, "hello"), (40, None, "world")]
with cur.copy("COPY sample (col1, col2, col3) FROM STDIN") as copy:
    for record in records:
        copy.write_row(record)        # tuples -> rows; None -> NULL
# rows are committed when the `with` block exits
```

Binary COPY (`FORMAT BINARY`) is supported and is "more efficient than the implicit default FORMAT TEXT," but
requires that every Python type has a binary dumper registered and that the table schema matches exactly. For
maximum control you can also use `copy.write(bytes)` to skip Python-object conversion entirely. [VERIFIED]
(same psycopg3 docs)

**CSV-on-disk vs stream-from-Python:** generating to a CSV then `COPY ... FROM '/path'` (server-side) or
`\copy` (client-side) is the classic approach and is fast, but it doubles I/O (write CSV, read CSV) and adds a
text-escaping round trip. Streaming generated tuples straight into `cur.copy(...).write_row()` avoids the temp
file and is the recommended path for a Python generator. Use binary format if you've profiled the text
conversion as a bottleneck. [PRIOR, API VERIFIED]

### 2.3 Load-time Postgres tuning (apply during seeding, revert after)

From the bulk-load sources above and CYBERTEC: [VERIFIED]
<https://www.cybertec-postgresql.com/en/postgresql-bulk-loading-huge-amounts-of-data/>

- Create tables, **load**, then **build indexes and add FK constraints afterward** (constraint validation and
  index maintenance per-row is the dominant cost).
- `SET maintenance_work_mem = '2GB'` (faster index builds), `SET synchronous_commit = off`,
  `max_wal_size = '10GB'` during the load.
- Consider `UNLOGGED` tables during generation (≈2× the index-dropped rate above), then `ALTER TABLE ... SET
  LOGGED` — but note that flips to logged generate WAL anyway; for a *dump-only* artifact you may keep them
  unlogged until the pg_dump.
- COPY is single-threaded; **parallelize by sharding rows across connections** if you saturate one core but
  not I/O. For deterministic output, shard on a stable key (e.g., `id % N`) and merge in id order. [PRIOR]
- "If you want to load billions of rows, I/O is king." [VERIFIED]
  <https://oneuptime.com/blog/post/2026-01-25-load-millions-rows-copy-postgresql/view>

---

## 3. Statistical realism

A benchmark whose data is uniformly random is a *weaker* benchmark: the well-known critique of TPC-H is that
its **uniform** distributions make the workload artificially easy and unrepresentative (see §6). Real commerce
data is heavy-tailed. We should bake in the following, all reproducibly via numpy.

### 3.1 Customer & product popularity — power law / Zipf

Customer purchase frequency and product sales both follow heavy-tailed (Zipf/Pareto/power-law) distributions:
"the distributions of the sizes of cities, earthquakes, ... and people's personal fortunes all appear to
follow power laws" (Newman 2005, the canonical reference). [VERIFIED]
<https://arxiv.org/abs/cond-mat/0412004>

Two practical ways to generate this in numpy:
- **Bounded catalog (preferred for us):** build a probability vector over the *finite* set of product/customer
  IDs and sample with `rng.choice(ids, size=n, p=weights)`, where `weights ∝ rank^(-s)` (Zipf exponent
  `s≈1.0–1.2`). This guarantees IDs stay inside the existing pool (no FK violations) and is vectorized.
  [PRIOR; choice/p API VERIFIED] <https://numpy.org/doc/stable/reference/random/generator.html>
- **Unbounded counts:** `rng.zipf(a)` draws ranks from an infinite Zipf; useful for "number of items per
  order" style counts but must be clipped. `numpy.random.Generator.zipf` is "inherently vectorized when you
  specify `size`." [VERIFIED] <https://numpy.org/doc/stable/reference/random/generated/numpy.random.Generator.zipf.html>

TPC-H has an official **Zipfian-skew** datagen variant (Microsoft download + `tpch_dbgen_zipf_skew` on
GitHub) precisely because uniform was deemed unrealistic — we can borrow its `z` (skew) parameterization idea.
[VERIFIED] <https://www.microsoft.com/en-us/download/details.aspx?id=52430>,
<https://github.com/SrikanthKandula/tpch_dbgen_zipf_skew>

### 3.2 Order value — lognormal / Pareto

Monetary amounts (order totals, line prices) are strongly right-skewed; **lognormal** is the standard model
for order/basket value and `rng.lognormal(mean, sigma)` is vectorized, while the **Pareto tail** captures the
few very large B2B orders. Use lognormal for the body and a Pareto/`rng.pareto(a)` mixture for the top
percentile of "whale" accounts. [PRIOR; numpy methods VERIFIED]

### 3.3 Time patterns — diurnal + weekly + seasonal

Public e-commerce timing figures to reproduce: [VERIFIED]

- **Diurnal:** >36% of daily US e-commerce orders fall between **11:00–15:00**; noon and 1pm are the two
  busiest hours at ~7.5% each; evenings (18:00–23:00) are <20% of orders. (Study of 1M+ orders.)
  <https://www.twice.com/the-wire/the-8-pm-shopping-rush-doesnt-exist-study-of-1m-orders-shows-u-s-e-commerce-peaks-at-lunch>
- **Weekly:** weekdays (esp. Mon–Thu) dominate; weekends are the quietest. Thursday/Friday/Monday cluster as
  busiest depending on region.
  <https://ecdb.com/blog/online-shopping-habits-the-golden-hours-of-ecommerce/4462>
- **Seasonal / holiday spikes:** the holiday season is ~24% of annual online sales; **Cyber Monday ≈ 5.5×** an
  average day and **Black Friday ≈ 4.5×** average volume; Cyber Monday 2025 hit **$14.25B** (+7.1% YoY) and
  Black Friday online **$11.8B** (+9.1% YoY).
  <https://almcorp.com/blog/black-friday-cyber-monday-2025-winners-losers-analysis/>,
  <https://www.statista.com/topics/1103/holiday-season-e-commerce/>

**How to generate:** for each order, draw a base date over the benchmark window, then bias the timestamp with a
multiplicative intensity = `hour_weight[h] × dow_weight[d] × season_weight[date]`. Implement as a precomputed
per-day Poisson rate (`rng.poisson(lambda_day)`) where `lambda_day` encodes weekday + seasonal multipliers,
then distribute intra-day times by sampling hours from the diurnal weight vector with `rng.choice`. This makes
`COUNT(*) GROUP BY date_trunc('hour'/'day'/'month')` queries return *recognizable* shapes — good for the
benchmark's analytics questions. [PRIOR]

### 3.4 Churn / refund / failure rates to seed (so derived tables are realistic)

| Phenomenon | Figure to target | Source |
|---|---|---|
| **Cart abandonment** | ~70% (2025 avg; mobile ~79%, desktop ~67%) | <https://www.upcounting.com/blog/average-ecommerce-cart-abandonment-rate>, <https://baymard.com/lists/cart-abandonment-rate> [VERIFIED] |
| **E-commerce return/refund rate** | ~19–20% overall; apparel 20–40% (clothing ~26%), electronics 8–15% (often 8–10%), footwear 17–30%, beauty 4–12% | <https://www.upcounting.com/blog/average-ecommerce-return-rate>, <https://www.richpanel.com/learn/ecommerce-return-rates> [VERIFIED] |
| **Payment decline / failure** | ~7.9% global avg attempted purchases; subscription/recurring ~15%; CNP ~3× in-store failure | <https://coinlaw.io/card-decline-statistics/>, <https://gr4vy.com/posts/why-do-online-payments-fail-an-updated-guide-for-2025/> [VERIFIED] |
| **B2B SaaS monthly churn** | ~3.5% blended (≈2.6% voluntary + 0.8% involuntary); SMB 3–5%, Mid-Market 1.5–3%, Enterprise 1–2%; best-in-class <1% | <https://www.vitally.io/post/saas-churn-benchmarks>, <https://www.venasolutions.com/blog/saas-churn-rate> [VERIFIED] |

Wire these as **Bernoulli draws keyed off the relevant row** (e.g., for each order, `is_returned =
rng.random() < return_rate[product_category]`; for each subscription-month, `churned = rng.random() <
monthly_churn[tenant_segment]`). This produces refunds, failed payments, abandoned carts and churn events that
*aggregate to known industry rates* — exactly the kind of answer a benchmark question can check.

---

## 4. Referential-integrity-preserving generation

### 4.1 Dependency-ordered generation with retained ID pools

- **Topologically sort the 220 tables by FK dependency.** Generate parents before children. [PRIOR]
- **Retain ID pools in memory** as numpy `int64` arrays per table (and, where needed, per tenant). A child's
  FK column is **sampled from the parent pool** (`rng.choice(parent_ids, size=n_children, p=...)`), *never*
  generated as a free random int. This makes FK violations structurally impossible and lets you apply the §3
  popularity skew (`p=`) at the same time. [PRIOR]
- Use **deterministic surrogate IDs**: contiguous `bigint` sequences per table (`np.arange(start, start+n)`),
  so the same `(scale, seed)` yields the same IDs. Avoid UUIDs unless seeded from numpy bytes — random UUIDs
  destroy determinism. [PRIOR]

### 4.2 Tenant isolation (the multi-tenant invariant)

The hard rule: **a child row's `tenant_id` must equal its parent's `tenant_id`.** Implement by carrying tenant
down the graph rather than re-drawing it:
- Maintain, per parent table, a parallel array `parent_tenant[parent_id] = tenant_id`.
- When you pick a child's parent via `choice`, **read the parent's tenant from that array** and copy it to the
  child — do not sample tenant independently.
- For tables with multiple FKs to different parents, all parents must already share a tenant; restrict the
  `choice` pool to one tenant at a time (loop per tenant) so cross-tenant pairings can't occur. [PRIOR]

This per-tenant loop also lets you give tenants *different sizes* (a few "whale" tenants holding most rows — a
Pareto over tenants), which is realistic for B2B SaaS and makes the "schema-retrieval at scale" axis harder
(skewed tenants ⇒ skewed query selectivity). [PRIOR]

### 4.3 Temporal coherence

Enforce event ordering with monotone offsets, not independent draws: [PRIOR]
- `placed_at` = base order timestamp (from §3.3).
- `paid_at = placed_at + rng.exponential(scale≈minutes)` (only if payment succeeded).
- `shipped_at = paid_at + rng.gamma(...)`, `delivered_at = shipped_at + transit`, `refunded_at = delivered_at
  + return_window_draw`. Always add non-negative deltas so `paid_at >= placed_at >= created_at` holds by
  construction. Child rows (line items) inherit/clip to the parent order's window. Subscription periods are
  contiguous (`period_end[i] == period_start[i+1]`).
- A row that "didn't happen" (unpaid, unshipped) gets `NULL`, not a fabricated time — see §5.

---

## 5. "Dirty but valid" realism (without breaking FKs)

Real production schemas are messy in the *value* layer, never in the *key* layer. Inject mess only into
non-key, nullable, or free-text columns: [PRIOR]

- **Mixed casing / whitespace:** randomly upper/lower/title-case a fraction of names, emails, city strings;
  occasionally leave leading/trailing spaces. (Great for testing whether the model emits `LOWER()`/`TRIM()`.)
- **Nullable optionals:** leave `phone`, `middle_name`, `address_line_2`, `notes`, `coupon_code` NULL at
  realistic rates. NULL handling is a classic NL-to-SQL failure mode — deliberately worth seeding.
- **Free text:** Mimesis `text()`/`words()` for `notes`, review bodies, support-ticket text. Vary lengths.
- **Controlled duplicates:** because Mimesis still yields ~85% unique at 1M (§1.1), *re-inject* duplicates on
  purpose at a known rate (e.g., 2% duplicate customer emails across tenants but **never within a tenant** if a
  unique constraint exists there) so dedup-style questions have a known answer.
- **Format variety:** phone numbers in 2–3 formats, dates-as-text in a free-text column, currency with/without
  symbols. Keep all of this **out of** columns that participate in FKs or unique constraints you rely on.

Rule: dirtiness lives in **attributes**; **keys, FKs, tenant_id, and the temporal invariants stay pristine.**

---

## 6. Reference workloads — what to borrow, what not

| Workload | Borrow | Avoid |
|---|---|---|
| **TPC-H** | The "skew variant" parameterization (`z` Zipf knob) and the scale-factor (`SF`) discipline | Its **uniform** base distributions — "every partition key possesses roughly equal cardinality … vastly simplifies the resource management challenge by creating an artificially balanced cluster load." Not representative. [VERIFIED] <https://prestodb.io/blog/2026/01/30/tpc-h-vs-tpc-ds-benchmarking-modern-distributed-sql-engines-presto/> |
| **TPC-DS** | Its **non-uniform, domain-specific distributions and realistic retail skew** ("certain items, dates, or customer IDs appear orders of magnitude more frequently … mimicking best-sellers or seasonal variations") and its rich 24-table snowflake schema as a *modeling* reference | Its enormous query complexity isn't our goal; we want NL-to-SQL retrieval, not 99-query decision-support coverage. [VERIFIED] (same Presto post) |
| **pgbench** | Scale-factor (`-s`) mental model: one knob multiplies row counts deterministically; built into Postgres | Its trivial TPC-B-like schema (4 tables) — far too small for a 220-table retrieval benchmark. [PRIOR] |
| **Synthea** | Its **architecture**: seeded, module-driven state machines that produce *internally consistent longitudinal histories per entity* from public statistics; CLI `-s <seed>` for reproducibility; OMOP/relational outputs. This is the gold standard for *referentially + temporally coherent* synthetic records. [VERIFIED] <https://github.com/synthetichealth/synthea>, <https://synthetichealth.github.io/synthea/> | Its healthcare domain specifics and Java/Generic-Module-Framework machinery — overkill; borrow the *pattern* (per-entity coherent timelines), not the code. [PRIOR] |
| **dbgen/dsdgen** | The idea of a single compiled generator parameterized by `(SF, seed)` producing reproducible flat files for COPY | C-level reproducibility tricks we don't need; we get determinism from numpy + pinned versions. [PRIOR] |

The recurring lesson across all of them: **real benchmarks moved away from uniform distributions toward
documented skew.** "It has been universally recognized that data skew is prevalent in data warehousing. A
modern benchmark should therefore provide a test bed to evaluate the ability of database engines to handle
skew." [VERIFIED] <https://www.microsoft.com/en-us/download/details.aspx?id=52430>

---

## 7. Determinism strategy — byte-identical across machines

Goal: `generate(scale=S, seed=K)` produces the **same rows in the same order** on any machine, so the pg_dump
checksum matches and execution-equality scoring is stable.

### 7.1 The pitfalls (each is a real source of nondeterminism)

1. **Hash randomization** — Python salts string hashes per process (PEP 456). Any logic that iterates a
   `set`/`dict` of strings, or relies on `hash()` of a string, varies run-to-run. *"String values compute to
   different integer hashes on every fresh boot due to PYTHONHASHSEED."* [VERIFIED]
   <https://chenna.me/blog/2023/12/25/python-hash-is-not-deterministic/>, <https://bugs.python.org/issue27706>
   → **Fix:** export `PYTHONHASHSEED=0` for the generator process, and never iterate an unordered collection in
   the data path — iterate sorted lists / numpy arrays.
2. **`random.seed(str)`** is itself affected by hash randomization (Python bug 27706/29025). → **Fix:** seed
   numpy/Mimesis with **ints or bytes**, never with bare strings under default hashseed. [VERIFIED]
3. **numpy version drift** — `Generator` has "no compatibility guarantee … the bit stream may change" across
   versions. → **Fix:** pin numpy (and document the pin in the dump manifest). [VERIFIED]
   <https://numpy.org/doc/stable/reference/random/generator.html>
4. **Mimesis non-deterministic methods** — docs warn some provider methods ignore the seed. → **Fix:** unit-test
   reproducibility of every Mimesis call you use; replace any non-reproducible one with a numpy-driven choice
   over a fixed list. [VERIFIED] <https://mimesis.name/master/random_and_seed.html>
5. **Threadpool / parallel nondeterminism** — interleaving of concurrent workers changes row order and RNG
   consumption. → **Fix:** if parallelizing, give each worker a **`SeedSequence.spawn()` child stream** and a
   **deterministic shard** (e.g., id-range), then write shards back in id order. [VERIFIED + PRIOR]
6. **Faker/Mimesis global state** — a shared `random.Random` mutated by another component desyncs output.
   → **Fix:** instance-level seeding only; isolate the string RNG from the numeric RNG. [VERIFIED]
7. **dict ordering for output column order / JSON** — insertion-ordered since 3.7, but don't rely on
   *set*-derived ordering; sort keys explicitly when serializing. [PRIOR]
8. **Locale / float formatting / timezone** — pin a fixed locale (`Locale.EN`), format timestamps as UTC, and
   render decimals with a fixed precision so the COPY text is byte-stable. [PRIOR]

### 7.2 The seeding tree

```
master_seed (int, e.g. 0xBE0F)               # the only user-facing knob besides scale
  └─ SeedSequence(master_seed)
       ├─ child[0]  → numpy Generator for IDs & structure
       ├─ child[1]  → numpy Generator for amounts/distributions
       ├─ child[2]  → numpy Generator for timestamps
       ├─ child[3]  → Mimesis seed (int) for strings
       └─ child[k]  → per-table / per-worker streams via .spawn()
```

Deriving every stream from one `SeedSequence` keeps streams independent **and** reproducible, and means
changing `master_seed` reshuffles *everything* coherently. [VERIFIED]
<https://www.plus2net.com/python/numpy-random-generator.php>

### 7.3 Verifying determinism

Run `generate(S, K)` twice, pipe each table's COPY stream through `sha256`, and assert equality. Then run on a
second machine / Python patch version in CI. Store the expected per-table checksums alongside the compressed
`pg_dump` so any drift is caught.

---

## 8. RECOMMENDED generation architecture for `seed/generate.py`

### 8.1 Libraries & pins (June 2026)

- **numpy** — pinned (e.g. `numpy==2.3.*`); the quantitative RNG (`default_rng`/PCG64), all distributions,
  all ID sampling. *Source of all randomness that affects values.*
- **mimesis** — pinned (e.g. `mimesis==19.*`, Python ≥3.10); the **only** string/label generator, on its own
  int seed. Chosen for speed + uniqueness (§1.1).
- **psycopg[binary]** 3.x — the loader; `cur.copy("... FROM STDIN")` + `write_row` streaming (binary if
  profiled worthwhile).
- **Standard lib only** otherwise; **no** dependency on the global `random` module in the data path.
- Faker: optional dev-only fallback for providers Mimesis lacks; not on the critical path.

### 8.2 Pipeline shape

```
generate.py --scale S --seed K --dsn postgresql://localhost/bench
  1. Bootstrap determinism: os.environ["PYTHONHASHSEED"]="0" (re-exec if unset), fix Locale.EN, UTC.
  2. ss = np.random.SeedSequence(K); rng_id, rng_amt, rng_time, *rest = ss.spawn(N)
     mimesis seed = int.from_bytes(ss.generate_state(1).tobytes())   # int, not str
  3. Load FK dependency DAG of the 220 tables; topologically sort.
  4. For each tenant (sized by a Pareto over tenants scaled by S):
        for each table in topo order:
            n = scale_rule(table, S, tenant_size)          # scale-factor knob, §8.3
            ids = np.arange(next_id, next_id+n)            # deterministic surrogate keys
            fks = rng_id.choice(parent_pool_within_tenant, size=n, p=zipf_weights)  # skew + tenant-safe
            tenant_col = parent_tenant[fks]                 # carry tenant down (§4.2)
            amounts = rng_amt.lognormal(...)                # heavy-tailed values (§3.2)
            ts = derive_timestamps(parent_ts[fks], rng_time)# monotone, diurnal/seasonal (§3.3/§4.3)
            strings = mimesis_fields(...)                   # names/emails/text (§1)
            apply_dirtiness(strings, rng_id)                # casing/nulls/dups in attrs only (§5)
            stream_copy(cur, table, zip(ids, fks, tenant_col, amounts, ts, strings))
        retain id pools + tenant map + parent timestamps for children.
  5. After all COPY: CREATE INDEX, ADD FOREIGN KEY ... NOT VALID then VALIDATE (or build with constraints),
     ANALYZE.  Tune maintenance_work_mem/synchronous_commit during load (§2.3).
  6. Emit per-table sha256 manifest; pg_dump -Fc | zstd  → compressed reproducible artifact.
```

### 8.3 Scale-factor knobs

- **`--scale S`**: one float multiplier. Each table's row count = `base_rows[table] * S * tenant_weight`.
  Document `base_rows` per table so `S=1` is the canonical benchmark size and `S=0.01` is a fast smoke test.
- **`--seed K`**: int; the entire seeding tree derives from it.
- **`--tenants N`** (optional): override tenant count; tenant sizes follow a Pareto so a few tenants dominate
  (realistic + harder retrieval).
- Distribution exponents (`zipf_s`, `lognormal_sigma`, churn/return/decline rates) live in a **versioned
  config**, not hard-coded, so the statistical profile is part of the reproducible artifact.

### 8.4 Load method (final)

**psycopg3 streaming `COPY ... FROM STDIN`**, indexes/FKs built *after* load, `UNLOGGED` during generation if
the artifact is dump-only, with the §2.3 session tuning. This is the only approach that hits 7-figure row
counts in seconds-to-minutes while staying byte-deterministic (COPY text output is a pure function of the
generated tuples). [VERIFIED throughput, §2.1]

---

## 9. Open questions / things to validate before coding

- Confirm Mimesis 19.x reproducibility for *every* provider method we plan to use (the docs' "some methods …
  nondeterministic" caveat is unspecific). Build a tiny `test_mimesis_determinism.py` first. [VERIFIED caveat]
- Decide binary vs text COPY by profiling on the actual schema (binary needs per-type dumpers; text is simpler
  and already very fast). [VERIFIED tradeoff]
- Pin exact numpy/mimesis/psycopg versions and record them in the dump manifest — cross-version bit-stream
  drift is the single biggest determinism risk. [VERIFIED]
- Validate that the per-tenant `choice`-restricted parent pools don't become a performance bottleneck at high
  tenant counts; if so, batch per-tenant generation but keep deterministic ordering. [PRIOR]

---

### Source index (primary)

- Mimesis About (benchmarks): <https://mimesis.name/master/about.html>
- Mimesis Random & Seed: <https://mimesis.name/master/random_and_seed.html>
- Faker class docs: <https://faker.readthedocs.io/en/master/fakerclass.html>
- numpy Generator: <https://numpy.org/doc/stable/reference/random/generator.html>
- numpy Zipf: <https://numpy.org/doc/stable/reference/random/generated/numpy.random.Generator.zipf.html>
- numpy SeedSequence/streams: <https://www.plus2net.com/python/numpy-random-generator.php>
- COPY throughput (load millions): <https://oneuptime.com/blog/post/2026-01-25-load-millions-rows-copy-postgresql/view>
- COPY bulk import: <https://oneuptime.com/blog/post/2026-01-25-use-copy-command-bulk-import-postgresql/view>
- CYBERTEC bulk load: <https://www.cybertec-postgresql.com/en/bulk-load-performance-in-postgresql/>, <https://www.cybertec-postgresql.com/en/postgresql-bulk-loading-huge-amounts-of-data/>
- Citus COPY: <https://www.citusdata.com/blog/2017/11/08/faster-bulk-loading-in-postgresql-with-copy/>
- psycopg3 COPY: <https://www.psycopg.org/psycopg3/docs/basic/copy.html>, <https://www.psycopg.org/psycopg3/docs/api/copy.html>
- Power laws (Newman): <https://arxiv.org/abs/cond-mat/0412004>
- TPC-H vs TPC-DS skew: <https://prestodb.io/blog/2026/01/30/tpc-h-vs-tpc-ds-benchmarking-modern-distributed-sql-engines-presto/>
- TPC-H skew datagen: <https://www.microsoft.com/en-us/download/details.aspx?id=52430>, <https://github.com/SrikanthKandula/tpch_dbgen_zipf_skew>
- Synthea: <https://github.com/synthetichealth/synthea>, <https://synthetichealth.github.io/synthea/>
- Diurnal/weekly timing: <https://www.twice.com/the-wire/the-8-pm-shopping-rush-doesnt-exist-study-of-1m-orders-shows-u-s-e-commerce-peaks-at-lunch>, <https://ecdb.com/blog/online-shopping-habits-the-golden-hours-of-ecommerce/4462>
- Holiday/BF/CM 2025: <https://almcorp.com/blog/black-friday-cyber-monday-2025-winners-losers-analysis/>, <https://www.statista.com/topics/1103/holiday-season-e-commerce/>
- Cart abandonment: <https://www.upcounting.com/blog/average-ecommerce-cart-abandonment-rate>, <https://baymard.com/lists/cart-abandonment-rate>
- Return rates: <https://www.upcounting.com/blog/average-ecommerce-return-rate>, <https://www.richpanel.com/learn/ecommerce-return-rates>
- Payment declines: <https://coinlaw.io/card-decline-statistics/>, <https://gr4vy.com/posts/why-do-online-payments-fail-an-updated-guide-for-2025/>
- SaaS churn: <https://www.vitally.io/post/saas-churn-benchmarks>, <https://www.venasolutions.com/blog/saas-churn-rate>
- Python hash determinism: <https://chenna.me/blog/2023/12/25/python-hash-is-not-deterministic/>, <https://bugs.python.org/issue27706>
