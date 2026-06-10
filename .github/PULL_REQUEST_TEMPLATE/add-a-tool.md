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

## Results (your local `make bench` numbers — CI re-runs your SQL and recomputes these)

| EX@1 | VES | Soft-F1 | Set-Recall | tok/q | $/run | errors |
|---:|---:|---:|---:|---:|---:|---:|
|  |  |  |  |  |  |  |

<!-- These are informational. The bot re-executes your pred_sql to produce the published numbers,
     so don't worry about getting them perfect — but inflated claims (claimed EX >> reproduced EX)
     fail the check. Unfavorable numbers stay; a leaderboard of only wins is marketing. -->

## Checklist

- [ ] Adapter in `harness/adapters/<name>.py`, subclasses `Adapter`, registered in `harness/adapters/__init__.py`
- [ ] **Generates SQL with the same `gpt-4o`** passed via `ctx['model']` — no fine-tuned / local model (that breaks the control)
- [ ] Returns `tables` (schema-qualified) if the tool has a retrieval / schema-selection stage
- [ ] **Real billed tokens captured** — via the usage meter automatically, or (if the SDK wraps the client) returned on the `Prediction`. No tiktoken estimates.
- [ ] Ran the full **100-question** suite: `make bench ADAPTER=<name> MODEL=openai/gpt-4o`
- [ ] Created the submission: `python harness/make_submission.py results_<name>.json --tool "<Name>" --repo <url>`
- [ ] Committed the **`submissions/<name>/`** folder (results.json + meta.json + adapter.py) — and did **not** edit `leaderboard.svg/json/csv` (the bot regenerates them)
- [ ] Stated the **setup reality** below (install command, version pins, any integration gotcha)
- [ ] The `verify-submission` check is green (CI re-ran my SQL and accepted it)

## Reproduce

```bash
make up && make schema && make seed SCALE=small SEED=42
make bench ADAPTER=<name> MODEL=openai/gpt-4o
python harness/make_submission.py results_<name>.json --tool "<Name>" --repo <url>
```
