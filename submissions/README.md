# submissions/ — the leaderboard's source of truth

One folder per benchmarked tool. **The leaderboard (`/leaderboard.svg`, `.json`, `.csv`) is generated
from these folders by CI — nobody edits it by hand.** To add or update a tool, add/modify a folder
here via a pull request (see [`../CONTRIBUTING.md`](../CONTRIBUTING.md)).

```
submissions/<tool>/
  results.json   the tool's run of the 100-question suite (CI re-runs its SQL to score it)
  meta.json      display info: { tool, adapter, repo, version, approach, submitted_by }
  adapter.py     a snapshot of the adapter that produced the run (auditable + reproducible)
```

## How a folder becomes a number (genuineness)

On every PR, `harness/score_submission.py` takes each question's `pred_sql` from `results.json` and
**re-executes it against a freshly-seeded gold database CI controls**, recomputing EX@1, VES, Soft-F1,
Set-Recall, errors, and timing from scratch. The number that lands on the leaderboard is the one CI
derived — **you cannot fake accuracy by editing the JSON.** Only token counts are taken from your
file (they require the actual model run); `adapter.py` makes them re-runnable, and they're labeled
self-reported.

A submission is **rejected** (PR check fails) if it: is missing questions (not all 100), uses a model
other than `openai/gpt-4o` (the same-model control), contains non-`SELECT` SQL, or claims an EX@1 its
own SQL can't reproduce (anti-tamper).

## results.json format

Produce it with `make bench` + `harness/make_submission.py` (see CONTRIBUTING). The shape:

```json
{
  "summary": { ... },                      // informational only — CI ignores it and recomputes
  "results": [
    {
      "id": "q001",
      "pred_sql": "SELECT count(*) FROM identity.users",   // REQUIRED — CI re-runs this
      "pred_tables": ["identity.users"],                   // tables your tool retrieved (Set-Recall)
      "prompt_tokens": 1234,                               // from response.usage (self-reported)
      "completion_tokens": 12,
      "error": null
    }
    // ... all 100 questions q001–q100
  ]
}
```

Only `results[].id` + `pred_sql` are strictly required; include `pred_tables` so Set-Recall is
verified (not trusted), and the token fields so your token economy counts in the Grade. `make bench`
records all of these for you.
