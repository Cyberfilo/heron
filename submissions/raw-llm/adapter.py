"""Naive baseline: dump the ENTIRE schema into the prompt and ask for SQL.

This is the strawman heron exists to stress — at 211 tables the schema alone is
tens of thousands of tokens. End-to-end (no retrieved-table set), so it is scored on
EX only; its retrieval axis is reported as n/a. Needs an API key + the provider SDK:
  pip install openai   (or  anthropic) ;  set OPENAI_API_KEY / ANTHROPIC_API_KEY
"""
from __future__ import annotations

import os
import re

from .base import Adapter, Prediction

SYSTEM = ("You are a PostgreSQL expert. Given the database schema and a question, write "
          "exactly ONE read-only SQL SELECT (PostgreSQL dialect) that answers it. Use "
          "schema-qualified table names. Return ONLY the SQL inside a ```sql code block.")


def _extract(text: str) -> str | None:
    m = re.search(r"```sql\s*(.*?)```", text, re.S | re.I)
    sql = (m.group(1) if m else text).strip().rstrip(";").strip()
    return sql or None


def _call(model: str | None, system: str, user: str) -> str:
    if model and model.startswith(("claude", "anthropic")):
        import anthropic
        cl = anthropic.Anthropic()
        r = cl.messages.create(model=model.replace("anthropic/", ""), max_tokens=1500,
                               temperature=0, system=system,
                               messages=[{"role": "user", "content": user}])
        return ("".join(b.text for b in r.content if getattr(b, "type", "") == "text"),
                r.usage.input_tokens, r.usage.output_tokens)
    import openai
    cl = openai.OpenAI()
    m = (model or "gpt-4o").replace("openai/", "")
    r = cl.chat.completions.create(model=m, temperature=0,
                                   messages=[{"role": "system", "content": system},
                                             {"role": "user", "content": user}])
    return r.choices[0].message.content, r.usage.prompt_tokens, r.usage.completion_tokens


class RawLLMAdapter(Adapter):
    name = "raw-llm"

    def predict(self, question, ctx) -> Prediction:
        model = ctx.get("model") or os.environ.get("PRODBENCH_MODEL")
        user = f"Schema:\n{ctx['schema_text']}\n\nQuestion: {question.text}\n\nSQL:"
        try:
            text, ptok, ctok = _call(model, SYSTEM, user)
        except Exception as e:  # noqa: BLE001
            return Prediction(sql=None, error=f"llm: {e}")
        return Prediction(sql=_extract(text), tables=None,
                          prompt_tokens=ptok, completion_tokens=ctok)
