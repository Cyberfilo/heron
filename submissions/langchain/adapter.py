"""LangChain adapter — create_sql_query_chain (no table retrieval → dumps schema).

LangChain 1.x moved the SQL chain to the `langchain-classic` package; `SQLDatabase` is still
in `langchain_community.utilities`. It has no built-in table retrieval, so it puts the WHOLE
schema's table_info in the prompt — the naive approach, tested here at 211 tables (multi-schema
handled by pre-reflecting all schemas into the SQLDatabase's metadata). End-to-end → no Set-Recall.

Runs in the langchain venv:  ~/.heron-tools/venv-langchain/bin/python harness/run.py --adapter langchain --model openai/gpt-4o
"""
from __future__ import annotations

import re

from .base import Adapter, Prediction

SCHEMAS = ["identity", "geo", "catalog", "pricing", "inventory", "sales", "billing",
           "crm", "support", "marketing", "analytics", "comms", "audit", "ops"]


def _sa_url(conninfo: str) -> str:
    kv = dict(p.split("=", 1) for p in conninfo.split())
    user = kv.get("user", "postgres"); db = kv.get("dbname", "postgres")
    host = kv.get("host", "/tmp"); port = kv.get("port", "5432"); pw = kv.get("password", "")
    auth = f"{user}:{pw}@" if pw else f"{user}@"
    return f"postgresql+psycopg://{auth}/{db}?host={host}&port={port}"


def _clean(sql: str) -> str | None:
    if not sql:
        return None
    sql = re.sub(r"^\s*SQLQuery:\s*", "", sql.strip())
    m = re.search(r"```sql\s*(.*?)```", sql, re.S | re.I)
    if m:
        sql = m.group(1)
    return sql.strip().rstrip(";").strip() or None


class LangChainAdapter(Adapter):
    name = "langchain"

    def _setup(self, ctx):
        from sqlalchemy import create_engine, MetaData, Table
        from langchain_community.utilities import SQLDatabase
        from langchain_openai import ChatOpenAI
        from langchain_classic.chains import create_sql_query_chain

        eng = create_engine(_sa_url(ctx["dsn"]))
        md = MetaData()
        with eng.connect() as conn:
            names = [r[0] for r in conn.exec_driver_sql(
                "SELECT table_schema||'.'||table_name FROM information_schema.tables "
                "WHERE table_schema = ANY(%(s)s) AND table_type='BASE TABLE'",
                {"s": SCHEMAS}).fetchall()]
        for qn in names:
            sch, tbl = qn.split(".", 1)
            try:
                Table(tbl, md, schema=sch, autoload_with=eng)
            except Exception:  # noqa: BLE001
                pass
        self._db = SQLDatabase(eng, metadata=md, sample_rows_in_table_info=0)
        model = (ctx.get("model") or "gpt-4o").replace("openai/", "")
        self._chain = create_sql_query_chain(ChatOpenAI(model=model, temperature=0), self._db)
        self._ready = True

    def predict(self, question, ctx) -> Prediction:
        if not getattr(self, "_ready", False):
            self._setup(ctx)
        # LangChain routes the OpenAI call through its own client wrapper, which the
        # harness usage meter doesn't see — so capture exact billed tokens with
        # LangChain's native callback (reads OpenAI's reported token_usage).
        from langchain_community.callbacks import get_openai_callback
        ptok = ctok = None
        try:
            with get_openai_callback() as cb:
                out = self._chain.invoke({"question": question.text})
            ptok, ctok = cb.prompt_tokens, cb.completion_tokens
        except Exception as e:  # noqa: BLE001
            return Prediction(sql=None, error=f"langchain: {str(e)[:160]}")
        return Prediction(sql=_clean(out), tables=None,
                          prompt_tokens=ptok or None, completion_tokens=ctok or None)
