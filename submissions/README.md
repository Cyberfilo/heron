# submissions/ — the leaderboard's source of truth

Each `*.json` here is one tool's run of the 100-question suite. **The leaderboard
([`../docs/LEADERBOARD.md`](../docs/LEADERBOARD.md)) is generated from these files by CI — nobody
edits the leaderboard by hand.** To add or update a tool, add/modify a file here via a pull request
(see [`../CONTRIBUTING.md`](../CONTRIBUTING.md)).

## How a submission becomes a number (genuineness)

On every PR, `harness/score_submission.py` takes each question's `pred_sql` from your file,
**re-executes it against a freshly-seeded gold database CI controls**, and recomputes EX@1, VES,
Soft-F1, Set-Recall, errors, and timing from scratch. The number that lands on the leaderboard is
the one CI derived — **you cannot fake accuracy by editing the JSON.** Only token counts are taken
from your file (they require the actual model run); your committed adapter makes them re-runnable,
and they're labeled self-reported.

A submission is **rejected** (PR check fails) if it: is missing questions (not all 100), uses a
model other than `openai/gpt-4o` (the same-model control), contains non-`SELECT` SQL, or claims an
EX@1 its own SQL can't reproduce (anti-tamper).

## File format

The easiest way to produce one is `make bench` + `harness/make_submission.py` (see CONTRIBUTING).
The shape:

```json
{
  "tool": "My Tool",                       // display name on the leaderboard
  "adapter": "my-tool",                    // adapter module name in harness/adapters/
  "repo": "https://github.com/me/my-tool", // optional
  "submitted_by": "you",                   // optional
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

Only `results[].id` + `pred_sql` are strictly required for scoring; include `pred_tables` so
Set-Recall is verified (not trusted), and the token fields so your token economy counts in the
Grade. `make bench` records all of these for you.
