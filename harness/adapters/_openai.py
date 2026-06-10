"""Shared OpenAI chat helper for the in-house prompting-framework adapters
(MAC-SQL, DIN-SQL). One place for the call, the token accounting, and the
SQL/JSON extraction so each adapter stays a faithful description of its method.
"""
from __future__ import annotations

import json
import re


def chat(system: str, user: str, model: str | None = None, max_tokens: int = 1500):
    """One gpt-4o (temp 0) chat turn. Returns (text, prompt_tokens, completion_tokens)."""
    import openai
    cl = openai.OpenAI()
    m = (model or "gpt-4o").replace("openai/", "")
    r = cl.chat.completions.create(
        model=m, temperature=0, max_tokens=max_tokens,
        messages=[{"role": "system", "content": system},
                  {"role": "user", "content": user}])
    u = r.usage
    return r.choices[0].message.content, u.prompt_tokens, u.completion_tokens


def extract_sql(text: str | None) -> str | None:
    if not text:
        return None
    m = re.search(r"```sql\s*(.*?)```", text, re.S | re.I)
    sql = (m.group(1) if m else text).strip()
    start = re.search(r"\b(select|with)\b", sql, re.I)   # drop any leading prose
    if start:
        sql = sql[start.start():]
    return sql.strip().rstrip(";").strip() or None


def extract_table_list(text: str | None, valid: set[str]) -> list[str]:
    """Pull schema-qualified table names a model emitted, keeping only real ones.
    Accepts a JSON array or any prose that mentions `schema.table` tokens.
    """
    if not text:
        return []
    found: list[str] = []
    m = re.search(r"\[.*?\]", text, re.S)
    if m:
        try:
            arr = json.loads(m.group(0))
            found = [str(x) for x in arr if isinstance(x, str)]
        except Exception:  # noqa: BLE001
            found = []
    if not found:
        found = re.findall(r"[a-z_]+\.[a-z_]+", text)
    # dedupe, preserve order, keep only tables that exist
    out, seen = [], set()
    for t in found:
        t = t.strip().strip('"')
        if t in valid and t not in seen:
            seen.add(t)
            out.append(t)
    return out
