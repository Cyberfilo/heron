# Hosting & Licensing — NL-to-SQL Benchmark (v1)

**Scope:** distribution of the benchmark database (a single multi-tenant B2B SaaS commerce
Postgres 16 schema, ~220 FK-linked tables, 14 domains, deterministically seeded to millions of
rows → a compressed `pg_dump` in the ~0.5–1.5 GB range), the code license for the harness/generator,
the data license for the synthetic database + questions, and an **optional, deferred** zero-setup
public read-only demo.

**Research date:** June 2026. Pricing and limits below were fetched from official pages on that date;
managed-DB pricing changes frequently — re-verify the cited pages before committing.

**Confidence legend:** ✅ = verified from the cited official page this session · ⚠️ = from a secondary
source (re-verify) · 💭 = my reasoning/recommendation, not a sourced fact.

---

## 1. Managed Postgres hosting — free + cheapest paid tiers

The question for each provider: (a) free-tier storage cap, (b) cheapest paid tier cost + what it
gives, (c) can it hold a ~0.5–1.5 GB **read-only** demo DB?

A 0.5–1.5 GB live database (not the compressed dump — the *restored* DB will be larger than the
compressed artifact, plus indexes; budget ~2–4 GB of live disk for a 1 GB dump 💭) is the bar.

| Provider | Free-tier storage cap | Cheapest paid tier | Holds 0.5–1.5 GB read-only demo? | Source |
|---|---|---|---|---|
| **Neon** | 0.5 GB / project (free plan; 100 CU-hours/mo) ✅ | **Launch** — usage-based, **no monthly minimum**; compute $0.106/CU-h, storage **$0.35/GB-mo** ✅ | Free: ❌ (0.5 GB cap). Launch: ✅ — ~$0.35–0.50/mo storage for a 1 GB DB + scale-to-zero compute. Best cheap fit. | [neon.com/pricing](https://neon.com/pricing) |
| **Supabase** | 500 MB DB size; project **paused after 1 week** inactivity; 2 active projects max ✅ | **Pro** — $25/mo, **8 GB** DB included, then $0.125/GB ✅ | Free: ❌ (500 MB + auto-pause kills a demo). Pro: ✅ but $25/mo floor is overkill. | [supabase.com/pricing](https://supabase.com/pricing) |
| **Railway** | $5 one-time trial credit, expires 30 days (no permanent free DB) ⚠️ | **Hobby** — $5/mo subscription incl. $5 usage; volume storage **$0.15/GB-mo**; a small always-on PG ≈ $5–15/mo ⚠️ | ✅ technically, but you pay the $5 subscription even at low usage; always-on compute adds cost. | [railway.com/pricing](https://railway.com/pricing), [docs.railway.com/pricing/plans](https://docs.railway.com/pricing/plans) |
| **Render** | Free Postgres: **1 GB** storage but **expires 30 days** after creation (then 14-day grace, then deleted); no backups ⚠️ | **Starter ~$7/mo**; Basic-1GB (10 GB storage) ~$20/mo; storage beyond included $0.30/GB-mo ⚠️ | Free: ❌ (30-day expiry = not a stable demo). Starter: ✅. | [render.com/pricing](https://render.com/pricing), [render.com/docs/postgresql-refresh](https://render.com/docs/postgresql-refresh) |
| **Aiven** | Free PG tier exists but **shuts down on inactivity** + tight caps; storage not officially quantified on the page ⚠️ | **Developer Tier** — **from $5/mo**, 1 CPU / 1 GB RAM / **8 GB** storage ✅ | Free: ⚠️ (inactivity shutdown). Developer: ✅ — 8 GB at $5/mo is a clean fit. | [aiven.io/developer-tier](https://aiven.io/developer-tier), [aiven.io/pricing](https://aiven.io/pricing) |
| **Fly.io (Managed Postgres)** | **No free tier** for Managed Postgres in 2026 ⚠️ | **Basic ~$38/mo**; storage $0.28/provisioned-GB-mo ⚠️ | ✅ on capacity, but $38/mo entry is expensive for a tiny read-only demo. Not recommended. | [fly.io/docs/mpg](https://fly.io/docs/mpg/), [fly.io/docs/about/pricing](https://fly.io/docs/about/pricing/) |
| **Crunchy Bridge** | No always-free tier, but **hobby-0 under the $5/mo minimum charge ≈ free**; storage $0.10/GB-mo ⚠️ | **Hobby — $10/mo** nominal; hobby-0 can stay under the $5 floor ⚠️ | ✅ on capacity (cheapest storage $/GB of the set). Hobby is explicitly *not for production* / no SLA. Fine for a demo. | [crunchydata.com/pricing](https://www.crunchydata.com/pricing), [docs.crunchybridge.com/concepts/plans-pricing](https://docs.crunchybridge.com/concepts/plans-pricing) |

**Takeaways:**
- **No major provider's *free* tier comfortably holds a stable 1 GB read-only demo.** Neon and
  Supabase free tiers cap at 0.5 GB; Render's 1 GB free DB **expires after 30 days**; Supabase
  free projects auto-pause after a week. The free tiers are sized for prototypes, not a persistent
  benchmark demo. 💭
- **Cheapest *paid* options that fit:** Neon **Launch** (no monthly minimum, ~cents/mo for storage,
  scale-to-zero compute) and Aiven **Developer** ($5/mo flat, 8 GB) are the two best-value entries.
  Crunchy hobby-0 (under $5/mo) is the cheapest storage $/GB. 💭
- Numbers move fast: Neon cut storage from ~$1.75 to $0.35/GB-mo and doubled free compute to 100
  CU-h in late 2025 after the Databricks acquisition ⚠️ ([neon.com/blog/new-usage-based-pricing](https://neon.com/blog/new-usage-based-pricing)).
  Re-check before relying on any figure.

---

## 2. LOCAL-for-v1 + ship a `pg_dump` — confirm or challenge

**Verdict: the local-first decision is correct for v1. ✅💭** Reasons:

1. **Execution-equality scoring needs a byte-identical DB.** A deterministic local Postgres 16 +
   seeded generator + a pinned `pg_dump` gives every evaluator the *same* rows, so gold-vs-predicted
   result comparison is reproducible. A shared hosted DB introduces drift, contention, and a single
   point of failure — worse for a benchmark, not better. 💭
2. **No cloud cost, no account, no rate limits, no provider lock-in.** Tool-neutral repo stays
   tool-neutral. 💭
3. **The "retrieval at scale" axis (find ~5 of 220 tables) is a schema property, not a hosting
   property** — it travels fully inside the dump. 💭

The only real question is **where the ~1 GB dump physically lives.** Here the limits bite:

### Where the limits bite

- **GitHub Release assets:** each asset must be **< 2 GiB** ✅, but **there is no limit on the total
  size of a release, nor on bandwidth/download usage**, and up to **1000 assets per release** ✅
  ([docs.github.com — about-releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)).
  → A single ~1 GB compressed dump fits comfortably as **one release asset**, with **free, unmetered
  downloads**. This is the sweet spot.
- **Regular git / repo files:** hard **100 MB per-file** push limit — a 1 GB dump **cannot** be a
  normal committed file ⚠️.
- **Git LFS (free / Pro):** **10 GiB storage + 10 GiB/month bandwidth**; per-file cap 2 GB (free) ⚠️.
  A 1 GB dump uses 10% of storage but **blows the 10 GiB/month bandwidth budget after ~10 downloads**.
  Extra capacity is **$5/mo per 50 GB storage + 50 GB bandwidth** data pack ⚠️
  ([docs.github.com — LFS billing](https://docs.github.com/billing/managing-billing-for-git-large-file-storage/about-billing-for-git-large-file-storage)).
  → **LFS is the wrong tool here** — its metered bandwidth is exactly what Release assets avoid.

### External object storage (overflow / >2 GiB / mirror)

If the dump ever exceeds 2 GiB, or you want a CDN mirror:

| Store | Free tier | Storage $/GB-mo | Egress | Source |
|---|---|---|---|---|
| **Cloudflare R2** | 10 GB storage; 1M Class-A + 10M Class-B ops/mo (permanent) ⚠️ | $0.015 | **$0 egress (always free)** ✅ | [developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/) |
| **Backblaze B2** | First 10 GB storage free ⚠️ | $0.005 | Free up to 3× stored/mo, then $0.01/GB; **free egress via Cloudflare/Fastly/bunny CDN** ⚠️ | [backblaze.com/cloud-storage/pricing](https://www.backblaze.com/cloud-storage/pricing) |

A ~1 GB dump sits inside **both** free tiers indefinitely. **R2's zero-egress** makes it the better
mirror if downloads ever get heavy (B2's free egress is capped at 3× stored, i.e. ~3 GB/mo for a
1 GB object before charges). 💭

### Recommendation for the dump (§5 expands)

**Primary: GitHub Release asset** (free, unmetered, < 2 GiB, version-pinned to a git tag). **Mirror:
Cloudflare R2 free tier** if/when downloads scale or the artifact crosses 2 GiB. **Never git-LFS** for
this — metered bandwidth defeats the purpose. Ship a SHA-256 checksum + a one-line `pg_restore` script
next to the asset. 💭

---

## 3. Deferred optional public read-only demo (spec only — no account created now)

If a zero-setup "try a query in the browser / against a live DB" demo is added later:

- **Best provider+tier: Neon Launch.** Usage-based, **no monthly minimum**, storage ~$0.35/GB-mo,
  **scale-to-zero compute** (idle ≈ free), branching to reset the demo to a clean read-only state.
  For a 1 GB read-only DB this is plausibly **a few dollars/month**. ✅💭
- **Runner-up: Aiven Developer Tier** — flat $5/mo, 8 GB, always-on (no cold-start), simpler to
  reason about than usage-based billing. 💭
- **Avoid for a demo:** Supabase free (auto-pause + 500 MB), Render free (30-day expiry), Fly MPG
  (no free tier, $38/mo floor). 💭

**Signup it would involve (deferred):** create a Neon account (GitHub/Google OAuth, no card for free
plan; card required to enter Launch), create one project + database, `pg_restore` the dump, create a
**read-only role** and set `default_transaction_read_only = on` (mirrors the PromptQuery CLI's own
two-layer safety model 💭), put the DSN behind the demo. Keep it on its own throwaway project so it
can be torn down without touching anything else.

---

## 4. Licensing — how the prior art licenses DATA and CODE

| Benchmark | Data license | Code license | Source |
|---|---|---|---|
| **Spider 1.0** (Yale) | **CC BY-SA 4.0** ✅ | repo scripts under their own terms | [yale-lily.github.io/spider](https://yale-lily.github.io/spider) |
| **BIRD** (HKU/Alibaba) | **CC BY-SA 4.0** (changed to this on 2024-04-27; site adds a "not responsible for bad-purpose use" disclaimer) ✅ | code in the BIRD repos | [bird-bench.github.io](https://bird-bench.github.io/) |
| **Spider 2.0** (xlang-ai) | repo (incl. harness) under **MIT** ✅; underlying DBs are **real enterprise sources** (BigQuery/Snowflake/SQLite/DuckDB/Postgres/ClickHouse), 632 tasks, schemas of 700–3000+ columns ⚠️ — so data licensing is per-source, *not* a single clean license | **MIT** ✅ | [github.com/xlang-ai/Spider2](https://github.com/xlang-ai/Spider2), [arxiv.org/abs/2411.07763](https://arxiv.org/abs/2411.07763) |

**Key insight for us:** Spider/BIRD chose **CC BY-SA 4.0** — a *copyleft / ShareAlike* data license
that forces derivatives to re-share under the same terms. That made sense for them because their data
derives from scraped/curated real-world content where they wanted attribution + share-alike. **Our
situation is fundamentally different: 100% synthetic, no third-party data redistributed.** We are free
to pick a *more permissive* license precisely because there's no upstream copyleft obligation to
inherit. 💭 Spider 2.0's messy per-source data licensing is exactly the trap we avoid by generating
everything ourselves.

### License options for a **fully synthetic** dataset

| License | Type | Attribution required? | ShareAlike? | Best for | Note |
|---|---|---|---|---|---|
| **CC0 1.0** | Public-domain dedication | No | No | Max adoption; "do anything" | Lowest friction; no credit guaranteed |
| **CC BY 4.0** | Permissive + attribution | Yes | No | Datasets wanting citation/credit | Standard for open datasets; you get cited |
| **CDLA-Permissive-2.0** | Permissive, **AI/ML-purpose-built** | Yes (notices) | No | Open data for AI/ML training & eval | Linux Foundation; short, removes the "is a model output a derivative?" doubt; CC0/CC-BY content can be folded in ✅ ([cdla.dev](https://cdla.dev/faq-resources/compatibility/), [linuxfoundation.org press](https://www.linuxfoundation.org/press/press-release/enabling-easier-collaboration-on-open-data-for-ai-and-ml-with-cdla-permissive-2-0)) |
| **Apache-2.0** | Permissive **software** license | Yes (NOTICE) | No | **Code**, not data | Has an explicit patent grant; not designed for datasets |

Sources for the comparison: [cdla.dev compatibility FAQ](https://cdla.dev/faq-resources/compatibility/),
[Linux Foundation CDLA-Permissive-2.0 announcement](https://www.linuxfoundation.org/press/press-release/enabling-easier-collaboration-on-open-data-for-ai-and-ml-with-cdla-permissive-2-0).

**Why NOT copy Spider/BIRD's CC BY-SA:** ShareAlike is viral — anyone fine-tuning a model or building
a derived benchmark on our data could be forced to re-license their work, which **suppresses adoption
of a benchmark whose whole point is to be adopted.** For synthetic data we have no reason to impose it. 💭

---

## 5. IP / ToS gotchas with Faker / Mimesis

- **Faker** is **MIT-licensed** ✅ ([github.com/joke2k/faker](https://github.com/joke2k/faker),
  [pypi.org/project/Faker](https://pypi.org/project/Faker/)).
- **Mimesis** is **MIT-licensed** ✅ ([github.com/lk-geimfari/mimesis](https://github.com/lk-geimfari/mimesis),
  [mimesis.name](https://mimesis.name/)).

Both are permissive: you can use them in a commercial/open project, and **MIT places no restriction on
the *data they emit*** — the generated rows are yours to license however you choose. 💭 Two practical
gotchas to keep clean:

1. **Bundled lexicons/providers.** Faker/Mimesis ship locale word-lists, name lists, etc. These are
   covered by the libraries' MIT terms; since our generator only *emits* fabricated values (not the
   source word-lists verbatim as a dataset), there's no redistribution-of-a-corpus issue. Keep the
   MIT notices for both libs in a `THIRD_PARTY_NOTICES` / `NOTICE` file as a courtesy. 💭
2. **Realism ≠ real.** Faker can emit plausible-looking emails, addresses, credit-card-format
   strings, etc. Because the seed and algorithm are fixed and synthetic, none of it maps to a real
   person — but **state explicitly in the README/DATASHEET that all data is synthetic and any
   resemblance to real entities is coincidental**, so no one mistakes it for PII. 💭 (BIRD's site
   carries a similar "not responsible for misuse" disclaimer — worth echoing.)

No GPL/copyleft dependency in this stack, so no license contamination of our code. 💭

---

## 6. RECOMMENDATIONS (concrete)

1. **Distribution mechanism for the dump → GitHub Release asset (primary), Cloudflare R2 (mirror).**
   - Compressed `pg_dump` (custom/`-Fc` format) as **one Release asset per tagged benchmark version**:
     free, unmetered downloads, fits under the 2 GiB asset cap. ✅
   - **Do not use git-LFS** (metered 10 GiB/mo bandwidth = wrong tool). ✅
   - Add a **Cloudflare R2 free-tier mirror** (10 GB free, **zero egress**) for resilience / if the
     artifact ever exceeds 2 GiB. ✅
   - Ship alongside: SHA-256 checksum, the exact Postgres version (16.x) it was dumped from, and a
     one-command `pg_restore` script. 💭

2. **Code license (harness + generator) → Apache-2.0.**
   - Permissive, **explicit patent grant** (safer than MIT for a tool others build on), and the
     emerging default for ML/eval tooling. Spider 2.0 used MIT; Apache-2.0 is the slightly safer
     superset. 💭 (If you want maximum brevity/familiarity, MIT is an acceptable fallback.)

3. **Data license (generated DB + questions/gold SQL) → CC BY 4.0, with CC0 as the bolder alt.**
   - **Primary recommendation: CC BY 4.0.** Permissive, no ShareAlike (unlike Spider/BIRD), and
     **attribution = you get cited** in every paper/leaderboard that uses the benchmark — valuable for
     a benchmark whose currency is recognition. 💭
   - **Consider CDLA-Permissive-2.0** if you want a license *purpose-built for AI/ML data* that
     removes the "is a model trained on this a derivative?" ambiguity — it's the cleanest fit for an
     eval dataset and folds in CC0/CC-BY content if you ever mix sources. ✅💭
   - **CC0** only if maximizing frictionless adoption matters more than guaranteed citation. 💭
   - Because the data is 100% synthetic, **all three are legally safe** — there is no upstream
     copyleft to inherit, which is exactly why we should *not* copy Spider/BIRD's CC BY-SA. ✅

4. **Deferred public demo provider → Neon (Launch tier), runner-up Aiven (Developer tier).**
   - Neon: no monthly minimum, scale-to-zero, branch-to-reset, ~a few $/mo for a 1 GB read-only DB.
     Spec only — **no account created now.** ✅
   - Confirm: **host LOCALLY for v1, demo is optional and later.** ✅

---

### Appendix — all sources cited
- Neon pricing: https://neon.com/pricing · https://neon.com/blog/new-usage-based-pricing
- Supabase pricing: https://supabase.com/pricing
- Railway: https://railway.com/pricing · https://docs.railway.com/pricing/plans
- Render: https://render.com/pricing · https://render.com/docs/postgresql-refresh
- Aiven: https://aiven.io/developer-tier · https://aiven.io/pricing
- Fly.io MPG: https://fly.io/docs/mpg/ · https://fly.io/docs/about/pricing/
- Crunchy Bridge: https://www.crunchydata.com/pricing · https://docs.crunchybridge.com/concepts/plans-pricing
- GitHub Releases limits: https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases
- GitHub LFS billing: https://docs.github.com/billing/managing-billing-for-git-large-file-storage/about-billing-for-git-large-file-storage
- Cloudflare R2 pricing: https://developers.cloudflare.com/r2/pricing/
- Backblaze B2 pricing: https://www.backblaze.com/cloud-storage/pricing
- Spider 1.0: https://yale-lily.github.io/spider
- BIRD: https://bird-bench.github.io/
- Spider 2.0: https://github.com/xlang-ai/Spider2 · https://arxiv.org/abs/2411.07763
- CDLA: https://cdla.dev/faq-resources/compatibility/ · https://www.linuxfoundation.org/press/press-release/enabling-easier-collaboration-on-open-data-for-ai-and-ml-with-cdla-permissive-2-0
- Faker: https://github.com/joke2k/faker · https://pypi.org/project/Faker/
- Mimesis: https://github.com/lk-geimfari/mimesis · https://mimesis.name/
