"""DIN-SQL adapter — decomposed in-context Text-to-SQL (gpt-4o).

A faithful in-process reproduction of DIN-SQL (Pourreza & Rafiei, NeurIPS 2023) —
four prompting modules over the SAME gpt-4o, so heron isolates the *approach*:

  1. Schema Linking — identify the tables/columns the question refers to. On heron's
     211-table DB this also serves as the table-retrieval step → its table set is
     scored on Set-Recall@k, and the downstream modules see only the linked schema
     (which is why DIN-SQL stays affordable despite being multi-step).
  2. Classification — label the query EASY / NON-NESTED / NESTED.
  3. Generation     — class-aware: nested questions are decomposed into intermediate
     sub-queries before the final SQL.
  4. Self-Correction — a generic pass that repairs likely mistakes in the SQL.

Needs only `openai` + `psycopg` (+ the schema). Cite: DIN-SQL, arXiv:2304.11015.
"""
from __future__ import annotations

import sys
import os

from .base import Adapter, Prediction
from ._openai import chat, extract_sql, extract_table_list

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from harness.schema_text import render_schema  # noqa: E402

LINK_SYS = (
    "You are the Schema-Linking module of DIN-SQL, working over a large PostgreSQL "
    "database (211 tables, 14 schemas). Identify the fully-qualified tables "
    "(schema.table) the question needs, including bridge/join tables. Reply with ONLY "
    "a JSON array of table names.")

CLASS_SYS = (
    "You are the Classification module of DIN-SQL. Given the relevant schema and the "
    "question, classify the SQL it requires as exactly one of: EASY (single table, no "
    "join), NON-NESTED (joins/aggregation but no sub-query), or NESTED (needs "
    "sub-queries/set-ops/CTEs). Reply with ONLY that one label.")

GEN_SYS = (
    "You are the Generation module of DIN-SQL. Using ONLY the given schema, write one "
    "read-only PostgreSQL SELECT that answers the question. For NESTED questions, first "
    "reason about the intermediate sub-queries, then compose the final query. Use "
    "schema-qualified names. Return ONLY the final SQL in a ```sql code block.")

CORRECT_SYS = (
    "You are the Self-Correction module of DIN-SQL. Review the SQL for bugs (wrong "
    "joins, missing GROUP BY, bad column/table names, dialect issues) against the "
    "schema and fix them. If it is already correct, return it unchanged. Return ONLY "
    "the SQL in a ```sql code block.")


class DinSqlAdapter(Adapter):
    name = "din-sql"

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

    def predict(self, question, ctx) -> Prediction:
        if not getattr(self, "_ready", False):
            self._setup(ctx)
        pt = ct = 0
        # 1) Schema linking (sees the full schema; reduces it for everything downstream)
        try:
            link, p, c = chat(LINK_SYS, f"Schema:\n{self._full_schema}\n\nQuestion: {question.text}",
                              self._model, max_tokens=400)
            pt += p; ct += c
        except Exception as e:  # noqa: BLE001
            return Prediction(sql=None, error=f"din-sql linking: {e}")
        tables = extract_table_list(link, self._valid)
        subset = set(tables) if tables else None
        reduced = render_schema(self._conn, only=subset) if subset else self._full_schema

        # 2) Classification
        try:
            cls, p, c = chat(CLASS_SYS, f"Schema:\n{reduced}\n\nQuestion: {question.text}",
                             self._model, max_tokens=8)
            pt += p; ct += c
        except Exception:  # noqa: BLE001
            cls = "NON-NESTED"
        cls = (cls or "").strip().upper()

        # 3) Generation (class-aware)
        try:
            gen, p, c = chat(GEN_SYS, f"Schema:\n{reduced}\n\nQuestion ({cls}): {question.text}\n\nSQL:",
                             self._model)
            pt += p; ct += c
        except Exception as e:  # noqa: BLE001
            return Prediction(sql=None, tables=tuple(tables) or None, error=f"din-sql gen: {e}")
        sql = extract_sql(gen)

        # 4) Self-correction (generic, no execution — faithful to DIN-SQL)
        if sql:
            try:
                fix, p, c = chat(CORRECT_SYS, f"Schema:\n{reduced}\n\nQuestion: {question.text}\n\nSQL:\n{sql}",
                                 self._model)
                pt += p; ct += c
                fixed = extract_sql(fix)
                if fixed:
                    sql = fixed
            except Exception:  # noqa: BLE001
                pass

        return Prediction(sql=sql, tables=tuple(tables) or None,
                          prompt_tokens=pt, completion_tokens=ct)
