# Design decisions (and the questions they answer)

This file records the load-bearing choices behind the benchmark, including the two
questions Filippo explicitly asked to be researched and decided: **where the benchmark
should live** and **how it should be hosted**. Decisions here are durable; if one is
reversed, amend this file in the same change and say why.

---

## D1 — Separate, tool-neutral repo (NOT folded into PromptQuery)

**Decision:** the benchmark is its own standalone repository. PromptQuery is *one adapter*
that runs against it, alongside a raw-LLM baseline and (later) Vanna / WrenAI / LangChain.

**Why:**

1. **Credibility = neutrality.** Every serious NL→SQL benchmark — Spider, BIRD, Spider 2.0 —
   is independent of any product. A benchmark shipped *inside* the repo of the tool that tops
   it is dismissed on sight ("of course `prq` wins its own benchmark"). PromptQuery's own
   marketing rule of record is literally *"neutral honest benchmark"* (positioning pillar #4,
   `00-MASTER-STRATEGY.md`). Folding the benchmark into `prq` would violate the very
   positioning it is meant to support.
2. **Different lifecycle.** A multi-GB seeded database + harness + leaderboard has a different
   release cadence, contributor base, and data-licensing surface than a pip-installed CLI. It
   should not bloat `prq`'s package or git history.
3. **It still showcases `prq`.** Neutrality *amplifies* the marketing value: an independent
   benchmark that `prq` happens to win is a far stronger asset than a self-graded one. `prq`'s
   `eval/` harness becomes a thin consumer/adapter of this repo.

**Consequence:** nothing here imports from or depends on `promptquery`. The `prq` adapter
lives in `harness/adapters/` and shells out to the installed CLI like any other tool.

---

## D2 — Local build + portable artifact. No cloud hosting, no signup. (researched)

**Decision:** build and ship the benchmark as **schema DDL + a deterministic seed generator +
a compressed `pg_dump`**, reproduced locally via Docker / native Postgres. **No cloud account
is created.**

**Why:**

1. **A benchmark is not a server.** Its value is *reproducibility*, not a hosted endpoint.
   The deliverable is the recipe (DDL + seeded generator) plus a frozen dump for exact
   reproduction — anyone runs `make up && make restore` (or `make seed`) to obtain a
   byte-identical database. A single hosted instance would be *less* credible (unverifiable,
   mutable, a single point of trust).
2. **It fits locally.** The `bench` scale factor produces an on-disk Postgres data directory of
   roughly **3–8 GB**; `pg_dump -Fc` compresses that to a **~0.5–1.5 GB** release asset. The
   *generator itself* is a few KB of Python. 35 GB free on this machine is ample. Smaller scale
   factors (`tiny`, `small`) run in seconds for CI.
3. **Cloud free tiers are too small AND unnecessary.** Neon / Supabase free tiers cap at
   ~0.5 GB — below the `bench` fact tables — and a paid small instance ($5–25/mo) buys nothing
   the local dump doesn't already give us. We deliberately spend $0.

**Hosting that we deliberately defer (not block on):** an *optional* hosted read-only demo
instance (Neon free tier on a `small` scale factor, or Supabase) for a zero-setup "try a query"
link — mirroring how `prq` already publishes public read-only RNAcentral creds. This is a
launch nicety, authored after v1 ships, and does not gate the benchmark.

**What this means for Filippo:** there is **nothing to sign up for** right now. If/when we add
the optional public demo, that is the only point a signup page would appear — and it will be a
free tier.

---

## D3 — Scale factors, sized for reproducibility and local disk

| Scale     | Use                        | Total rows (measured)    | On disk | `pg_dump -Fc -Z6` (measured) |
|-----------|----------------------------|--------------------------|---------|------------------------------|
| `tiny`    | CI smoke / unit tests      | ~0.2M                     | ~90 MB  | < 10 MB                      |
| `small`   | **the eval scale**         | **4.4M** (50k orders)     | 1.2 GB  | **233 MB**                   |
| `bench`   | "millions of rows" artifact| **87.8M** (1M orders, 10M events) | 22 GB | **4.6 GB**            |
| `large`   | stress / retrieval-at-load | ~430M+                    | ~110 GB | several GB                   |

All volumes are produced by a **single seeded RNG** (`seed/generate.py`), so a given
`(scale, seed)` is fully deterministic and reproducible on any machine.

> **Distribution note (measured):** the `small` dump (233 MB) is the clean **GitHub Release asset**
> (under the 2 GiB/file limit) and is the methodology's eval scale (N=3 seeded states). The `bench`
> dump (4.6 GB) **exceeds GitHub's 2 GiB asset cap** — ship it via Cloudflare R2 (free tier, no
> egress) or split it, or simply have users regenerate it deterministically with
> `make seed SCALE=bench`. Never git-LFS (10 GiB/mo bandwidth ≈ 2 downloads). See
> `docs/HOSTING-AND-LICENSING.md`.

---

## D4 — Domain: multi-tenant B2B SaaS commerce platform

**Why this domain:** it is (a) the domain PromptQuery markets into, (b) naturally sprawling —
auth, tenancy, catalog, pricing, inventory, orders, billing/subscriptions, CRM, support,
marketing, analytics, audit, comms, ops easily reach **220–260 FK-linked tables** without
padding — and (c) instantly legible to reviewers (everyone understands orders and refunds),
which matters for trusting the gold SQL. See `schema/CONVENTIONS.md` for the module map.

---

## D5 — Scoring: execution-equality first, retrieval-at-scale as the signature axis

Primary metric is **execution accuracy** (gold vs. predicted result sets, order-insensitive) —
the Spider/BIRD/Spider 2.0 standard. The differentiator nobody else measures cleanly is
**schema-retrieval-at-scale**: can a system find the handful of relevant tables among 220+?
Reported as recall@K of the must-reference tables. See `docs/METHODOLOGY.md`.

---

## D6 — Name: **heron**

Chosen name: **heron**. It fits the NL→SQL benchmark lineage of short zoological names (Spider →
BIRD → BEAVER), is distinctive and SEO-clean (no existing text-to-SQL benchmark uses it; a June-2026
search returned none), and reads as a serious member of that family. The thematic nod: a heron
patiently picks one fish out of a wide body of water — the retrieval-at-scale thesis. Filippo can
still rebrand (the artifact is name-agnostic) — but everything here now uses `heron`. Before a public
launch, secure the GitHub repo name, the `.dev`/`.ai` domain, and re-confirm no active ML/data
project has taken it (IBM's "Heron" quantum chip is a different domain, low confusion risk).
