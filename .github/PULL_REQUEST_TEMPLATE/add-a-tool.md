<!--
  Adding an NL→SQL tool to heron. Thanks — this is a first-class contribution.
  See CONTRIBUTING.md → "Adding a tool". The bar: same gpt-4o, headless predict(),
  real billed tokens, every number reproducible from committed artifacts.
-->

## Tool

- **Name:**
- **Repo / paper:**
- **License:**
- **Version pinned:** <!-- e.g. vanna==0.7.9 — note any gotcha -->
- **Approach:** <!-- retrieval / RAG / full-schema dump / multi-agent / decomposition / ... -->
- **Exposes a retrieved-table set?** <!-- yes → scored on Set-Recall@k | no → end-to-end -->

## How it handles heron's 211-table, 14-schema DB

<!-- One short paragraph: how does it ingest the schema and pick tables before generating? -->

## Results (paste the `make bench` summary — 100 questions, gpt-4o, temp 0)

| Grade | EX@1 | VES | Soft-F1 | Set-Recall | ms/q | tok/q | $/100q | errors |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|  |  |  |  |  |  |  |  |  |

<!-- Unfavorable numbers stay. A leaderboard of only wins is marketing, not a benchmark. -->

## Checklist

- [ ] Adapter in `harness/adapters/<name>.py`, subclasses `Adapter`, registered in `harness/adapters/__init__.py`
- [ ] **Generates SQL with the same `gpt-4o`** passed via `ctx['model']` — no fine-tuned / local model (that breaks the control; it belongs in the survey's "deferred" bucket)
- [ ] Returns `tables` (schema-qualified) if the tool has a retrieval / schema-selection stage
- [ ] **Real billed tokens captured** — via the usage meter automatically, or (if the SDK wraps the client) returned on the `Prediction`. No tiktoken estimates.
- [ ] Ran on the full **100-question** suite: `make bench ADAPTER=<name> MODEL=openai/gpt-4o`
- [ ] Committed `results_<name>_v1.json` (the per-question evidence)
- [ ] Added a tool card to `docs/CROSS-TOOL-LEADERBOARD.md` and regenerated `docs/LEADERBOARD.md`
- [ ] Stated the **setup reality** (install command, version pins, any integration gotcha)
- [ ] `make audit` still passes (no question/gold changes) — or, if you touched questions, it passes for them too

## Reproduce

```bash
make seed SCALE=small SEED=42
make bench ADAPTER=<name> MODEL=openai/gpt-4o
```
