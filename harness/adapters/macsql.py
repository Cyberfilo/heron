"""MAC-SQL adapter — multi-agent collaborative Text-to-SQL (gpt-4o).

A faithful in-process reproduction of MAC-SQL (Wang et al., 2024) — three LLM
agents over the SAME gpt-4o the other tools use, so heron isolates the *approach*:

  1. Selector  — given the full 211-table schema, prune to the tables needed for
     the question. This is MAC-SQL's answer to large schemas (and what makes it a
     fair retrieval-aware competitor); its output is the retrieved set scored on
     Set-Recall@k.
  2. Decomposer — over ONLY the selected tables, reason step-by-step and emit one
     PostgreSQL SELECT.
  3. Refiner   — execute the candidate read-only; if it errors, feed the error back
     once and regenerate (MAC-SQL's execution-guided self-repair).

Needs only `openai` + `psycopg` (+ the schema). Cite: MAC-SQL, arXiv:2312.11242.
"""
from __future__ import annotations

import sys
import os

from .base import Adapter, Prediction
from ._openai import chat, extract_sql, extract_table_list

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from harness.schema_text import render_schema  # noqa: E402

SELECTOR_SYS = (
    "You are the Selector agent in a Text-to-SQL system working over a large "
    "PostgreSQL database (211 tables across 14 schemas). Given the full schema and "
    "a question, return the MINIMAL set of fully-qualified tables (schema.table) "
    "required to answer it, including any join/bridge tables. Reply with ONLY a JSON "
    "array of table names, e.g. [\"sales.orders\", \"identity.users\"].")

DECOMPOSER_SYS = (
    "You are the Decomposer agent. Given a focused schema subset and a question, "
    "think step by step (decompose into sub-questions if needed) and produce exactly "
    "ONE read-only PostgreSQL SELECT that answers it. Use schema-qualified table names. "
    "Return ONLY the final SQL inside a ```sql code block.")

REFINER_SYS = (
    "You are the Refiner agent. The SQL below failed to execute. Given the schema "
    "subset, the question, the SQL, and the database error, return a corrected "
    "read-only PostgreSQL SELECT. Return ONLY the SQL inside a ```sql code block.")

DML = ("insert", "update", "delete", "drop", "alter", "create", "truncate", "grant", "merge")


class MacSqlAdapter(Adapter):
    name = "mac-sql"

    def _setup(self, ctx):
        import psycopg
        self._conn = psycopg.connect(ctx["dsn"])
        self._model = ctx.get("model")
        self._full_schema = render_schema(self._conn)
        with self._conn.cursor() as cur:
            cur.execute("SELECT table_schema||'.'||table_name FROM information_schema.tables "
                        "WHERE table_schema NOT IN ('pg_catalog','information_schema','pg_toast')")
            self._valid = {r[0] for r in cur.fetchall()}
        self._ready = True

    def _exec_error(self, sql: str) -> str | None:
        """Run sql read-only; return the DB error string, or None if it executes."""
        if not sql or any(sql.lstrip().lower().startswith(k) for k in DML):
            return "not a read-only SELECT"
        try:
            with self._conn.cursor() as cur:
                cur.execute("SET LOCAL statement_timeout = 30000")
                cur.execute(sql)
                cur.fetchmany(1)
            self._conn.rollback()
            return None
        except Exception as e:  # noqa: BLE001
            self._conn.rollback()
            return str(e).splitlines()[0][:200]

    def predict(self, question, ctx) -> Prediction:
        if not getattr(self, "_ready", False):
            self._setup(ctx)
        pt = ct = 0
        # 1) Selector
        try:
            sel, p, c = chat(SELECTOR_SYS, f"Schema:\n{self._full_schema}\n\nQuestion: {question.text}",
                             self._model, max_tokens=400)
            pt += p; ct += c
        except Exception as e:  # noqa: BLE001
            return Prediction(sql=None, error=f"mac-sql selector: {e}")
        tables = extract_table_list(sel, self._valid)
        subset = set(tables) if tables else None          # None => fall back to full schema
        reduced = render_schema(self._conn, only=subset) if subset else self._full_schema

        # 2) Decomposer
        try:
            gen, p, c = chat(DECOMPOSER_SYS, f"Schema:\n{reduced}\n\nQuestion: {question.text}\n\nSQL:",
                             self._model)
            pt += p; ct += c
        except Exception as e:  # noqa: BLE001
            return Prediction(sql=None, tables=tuple(tables) or None, error=f"mac-sql decomposer: {e}")
        sql = extract_sql(gen)

        # 3) Refiner (one execution-guided repair)
        err = self._exec_error(sql) if sql else "empty generation"
        if err:
            try:
                fix, p, c = chat(REFINER_SYS,
                                 f"Schema:\n{reduced}\n\nQuestion: {question.text}\n\n"
                                 f"SQL:\n{sql}\n\nError: {err}", self._model)
                pt += p; ct += c
                fixed = extract_sql(fix)
                if fixed:
                    sql = fixed
            except Exception:  # noqa: BLE001 — keep the pre-refine SQL
                pass

        return Prediction(sql=sql, tables=tuple(tables) or None,
                          prompt_tokens=pt, completion_tokens=ct)
