<!--
  Adding question(s) to heron. See CONTRIBUTING.md → "Adding a question".
  Gold must be trustworthy: it must execute, return non-empty, and declare exactly
  the tables it references. `make audit` is the gate.
-->

## Questions added

- **IDs / count:** <!-- e.g. q101–q108 (8) -->
- **What they exercise:** <!-- tables/domains, SQL shapes, retrieval distance, edge cases -->

## Checklist

- [ ] Each `Question` has `text`, `gold_sql`, `gold_tables`, `sql_shape`, `retrieval`, `tags`
- [ ] `gold_tables` is **exactly** the schema-qualified set the gold SQL references (audit enforces equality)
- [ ] `ORDER BY` appears in the gold **only** when the question asks for an order (top/first/ranked/sorted)
- [ ] Enum/value literals match the real schema (no guessed enum labels)
- [ ] **`make audit` passes** — every gold executes, returns non-empty, and `gold_tables == referenced`
- [ ] No duplicate question id

## Audit output

```
<!-- paste: `make audit` → "N questions: 0 hard failure(s), 0 empty result(s)" -->
```
