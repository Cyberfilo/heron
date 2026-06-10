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

heron is **tool-neutral**; adding your NL→SQL tool is exactly the kind of PR we want. Use the
[add-a-tool PR template](.github/PULL_REQUEST_TEMPLATE/add-a-tool.md).

1. **Write the adapter.** Drop a module in `harness/adapters/` subclassing `Adapter` and implementing
   `predict(question, ctx) -> Prediction(sql, tables=None)`. `ctx` carries `{'dsn', 'model'}` (and
   `schema_text` for the dump baseline). Return `tables` (the schema-qualified set your system
   retrieved/selected) if it has a retrieval or schema-pruning stage — that populates the
   **Set-Recall@k** axis. Register the name in `harness/adapters/__init__.py`.
2. **Hold the model fixed.** The whole point is to isolate *the approach*, so your tool must generate
   SQL with the **same `gpt-4o`** every other tool uses (passed via `ctx['model']`). Tools that
   require a fine-tuned/local model belong in the survey's "deferred" bucket, not the leaderboard —
   they'd break the control.
3. **Don't hand-count tokens.** The harness meters real OpenAI usage automatically: if your tool calls
   the `openai` SDK directly, `harness/usage_meter.py` captures the exact billed `response.usage`. If
   it wraps the client (like LangChain), capture usage in the adapter (e.g. `get_openai_callback`) and
   return it on the `Prediction` — the runner prefers the meter and falls back to your value. **No
   tiktoken estimates** land in published numbers.
4. **Patterns to copy:** `gold.py` (sanity), `raw_llm.py` (naive full-schema baseline),
   `promptquery.py` (retrieval, exposes Set-Recall), `vanna_tool.py` (RAG), `macsql.py` /
   `dinsql.py` (multi-step prompting frameworks).

Run it and regenerate the leaderboard:

```bash
make bench ADAPTER=<name> MODEL=openai/gpt-4o   # writes results_<name>.json + prints $ cost
python harness/leaderboard.py --label "MyTool=results_<name>.json" ...   # Grade + EX + VES + cost
```

Your tool is automatically scored on **EX@1** (execution accuracy), **VES** (correctness-gated
efficiency of the SQL it writes), **Soft-F1** (partial credit), **Set-Recall@k** (if it exposes a
table set), **reliability** (error rate), **token/$ economy**, and the composite **0–100 Grade** —
all defined in [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md). Commit your `results_<name>_v1.json` so
the number is reproducible. Favorable or not, it stays.

## Ground rules

1. **Reproducible or it doesn't count.** No number without a committed question + gold + a
   deterministic database (`(scale, seed)` is byte-stable).
2. **Publish failures.** Unfavorable results stay in the repo. A leaderboard of only wins is
   marketing, not a benchmark.
3. **State conditions on every number** (scale, model, EX@1 vs EX@k, single- vs multi-state, n).
4. **Don't overclaim.** See `docs/RELATED-WORK.md` §5.3 for what prior work already does.
