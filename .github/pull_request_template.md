<!--
  Default PR template. For the two common contributions there are tailored templates —
  append one of these to the URL when opening the PR (or copy its checklist in):
    • Adding a tool:     ?template=add-a-tool.md
    • Adding question(s): ?template=add-a-question.md
-->

## What & why

<!-- One or two sentences. Link any related issue. -->

## Checklist

- [ ] Change is **reproducible from committed artifacts** (heron's first rule)
- [ ] If it touches questions/gold: `make audit` passes (every gold executes, non-empty, `gold_tables == referenced`)
- [ ] If it adds/changes a tool: it uses the **same `gpt-4o`** control and real billed tokens (see `?template=add-a-tool.md`)
- [ ] Numbers in docs state their conditions (scale, model, n, single-state EX@1) per `docs/METHODOLOGY.md`
- [ ] **Unfavorable results kept** — no cherry-picking

## Notes

<!-- Anything reviewers should know: setup gotchas, deviations, open questions. -->
