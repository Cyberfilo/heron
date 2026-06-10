# Contributing to heron

Thanks for helping build an honest, reproducible NL→SQL benchmark. The bar is simple:
**every number must be reproducible from committed artifacts, and gold must be trustworthy.**

## Setup

```bash
make up                       # Postgres 16 in Docker (or point DSN at any Postgres)
make schema                   # load the 14-module schema (211 tables)
python -m venv seed/.venv && seed/.venv/bin/pip install -r seed/requirements.txt
make seed SCALE=small         # deterministic data (seed 42); SCALE=tiny for a fast smoke
make verify                   # referential-integrity + invariants must pass
```

## Adding a question

Edit `questions/core.py` (or add a new `questions/<set>.py` exporting `QUESTIONS`). Each
`Question` needs:

- `text` — the natural-language question, as a user would type it.
- `gold_sql` — a verified-correct PostgreSQL SELECT.
- `gold_tables` — **exactly** the schema-qualified tables the gold SQL references (the retrieval
  ground truth). The audit enforces this equals the parsed table set.
- `sql_shape` — `single | join | multi-join | analytical`.
- `retrieval` — `named | 1-hop | 2-hop+ | lexical-gap` (how hard it is to *find* the tables).
- `tags` — free-form (e.g. `tenant-isolation`, `value-grounding`, `anti-join`).

**Only put `ORDER BY` in the gold when the question actually requests an order** (top/first/ranked/
sorted). Gratuitous `ORDER BY` makes the comparator order-sensitive and unfairly fails correct
unordered answers. Then:

```bash
make audit       # every gold must execute, return non-empty, and have gold_tables == referenced
```

A question is not mergeable until `make audit` passes for it.

## Adding a tool (a system to benchmark) — first-class contribution

heron is **tool-neutral**; adding your NL→SQL tool is exactly the kind of PR we want. You write a
small adapter, run it once, and open a PR with your results — **a bot then re-runs your SQL to verify
the numbers and regenerates the leaderboard. You never edit the leaderboard yourself.**

### 1. Write the adapter
Drop a module in `harness/adapters/` subclassing `Adapter` and implementing
`predict(question, ctx) -> Prediction(sql, tables=None)`. `ctx` carries `{'dsn', 'model'}` (and
`schema_text` for the dump baseline). Return `tables` (the schema-qualified set your system
retrieved/selected) if it has a retrieval or schema-pruning stage — that populates **Set-Recall@k**.
Register the name in `harness/adapters/__init__.py`. Copy a pattern: `raw_llm.py` (dump baseline),
`promptquery.py` (retrieval), `vanna_tool.py` (RAG), `macsql.py` / `dinsql.py` (multi-step prompting).

Two hard rules:
- **Same model.** Generate SQL with the `gpt-4o` passed via `ctx['model']`. A fine-tuned/local model
  breaks the control and belongs in the survey's "deferred" bucket, not the leaderboard.
- **Real tokens, not estimates.** If your tool calls the `openai` SDK directly, the harness usage
  meter captures the exact billed `response.usage` automatically. If it wraps the client (like
  LangChain), capture usage in the adapter (e.g. `get_openai_callback`) and return it on the
  `Prediction`.

### 2. Run it on the 100-question suite
```bash
make up && make schema && make seed SCALE=small SEED=42      # the gold database
make bench ADAPTER=<name> MODEL=openai/gpt-4o                # writes results_<name>.json + prints $ cost
```

### 3. Turn the run into a submission
```bash
python harness/make_submission.py results_<name>.json --tool "<Display Name>" --repo <your-repo-url>
# → submissions/<name>.json
```

### 4. Open the PR
Commit **your adapter** (`harness/adapters/<name>.py` + the one-line registration) and
**`submissions/<name>.json`**. Do **not** touch `docs/LEADERBOARD.md` — it's auto-generated. Open the
PR with the [add-a-tool template](.github/PULL_REQUEST_TEMPLATE/add-a-tool.md) (append
`?template=add-a-tool.md` to the PR URL).

### What the bot does (so you don't)
- **On your PR** (`verify-submission`): re-executes every `pred_sql` in your file against a fresh gold
  DB and recomputes EX@1 / VES / Soft-F1 / Set-Recall / errors / timing. Verified numbers show in the
  PR's checks. The check **fails** if the submission is incomplete (not all 100), uses a non-`gpt-4o`
  model, contains non-`SELECT` SQL, or claims an accuracy its own SQL can't reproduce.
- **On merge** (`update-leaderboard`): regenerates `docs/LEADERBOARD.md` from all submissions and
  commits it.

Your tool is scored on **EX@1**, **VES** (efficiency of the SQL it writes), **Soft-F1**,
**Set-Recall@k**, reliability, token/$ economy, and the composite **0–100 Grade** — all defined in
[`docs/METHODOLOGY.md`](docs/METHODOLOGY.md). Submission format: [`submissions/README.md`](submissions/README.md).
Favorable or not, the number stays.

## Ground rules

1. **Reproducible or it doesn't count.** No number without a committed question + gold + a
   deterministic database (`(scale, seed)` is byte-stable).
2. **Publish failures.** Unfavorable results stay in the repo. A leaderboard of only wins is
   marketing, not a benchmark.
3. **State conditions on every number** (scale, model, EX@1 vs EX@k, single- vs multi-state, n).
4. **Don't overclaim.** See `docs/RELATED-WORK.md` §5.3 for what prior work already does.
