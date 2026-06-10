"""LlamaIndex adapter — SQLTableRetrieverQueryEngine (RAG over tables).

LlamaIndex's recommended pattern for "too many tables to fit in context": embed one schema
node per table, retrieve the top-k relevant tables per question, then generate SQL over only
those. That makes it a fair retrieval-aware comparison at 211 tables — and it exposes the
retrieved table set, so we score Set-Recall@k too.

Multi-schema (14 schemas) is handled by pre-reflecting every schema into one SQLAlchemy
MetaData and handing that to LlamaIndex's SQLDatabase, so table names are schema-qualified
and the generated SQL resolves against the DB's search_path.

Runs in the llamaindex venv:  ~/.heron-tools/venv-llamaindex/bin/python harness/run.py --adapter llamaindex --model openai/gpt-4o
"""
from __future__ import annotations

from .base import Adapter, Prediction

SCHEMAS = ["identity", "geo", "catalog", "pricing", "inventory", "sales", "billing",
           "crm", "support", "marketing", "analytics", "comms", "audit", "ops"]
TOP_K = 15


def _sa_url(conninfo: str) -> str:
    kv = dict(p.split("=", 1) for p in conninfo.split())
    user = kv.get("user", "postgres"); db = kv.get("dbname", "postgres")
    host = kv.get("host", "/tmp"); port = kv.get("port", "5432"); pw = kv.get("password", "")
    auth = f"{user}:{pw}@" if pw else f"{user}@"
    return f"postgresql+psycopg://{auth}/{db}?host={host}&port={port}"


class LlamaIndexAdapter(Adapter):
    name = "llamaindex"

    def _setup(self, ctx):
        from sqlalchemy import create_engine, MetaData, Table
        from llama_index.core import SQLDatabase, Settings, VectorStoreIndex
        from llama_index.core.objects import ObjectIndex, SQLTableNodeMapping, SQLTableSchema
        from llama_index.core.indices.struct_store import SQLTableRetrieverQueryEngine
        from llama_index.llms.openai import OpenAI as LIOpenAI
        from llama_index.embeddings.openai import OpenAIEmbedding

        model = (ctx.get("model") or "gpt-4o").replace("openai/", "")
        Settings.llm = LIOpenAI(model=model, temperature=0)
        Settings.embed_model = OpenAIEmbedding(model="text-embedding-3-small")

        eng = create_engine(_sa_url(ctx["dsn"]))
        md = MetaData()
        # Per-table autoload (avoids SQLAlchemy's batched-comment cache collision when
        # reflecting many schemas into one MetaData). Skip any table that won't reflect.
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
        self._tables = sorted(md.tables.keys())                 # "schema.table"
        sql_db = SQLDatabase(eng, metadata=md)
        objs = [SQLTableSchema(table_name=t) for t in self._tables]
        obj_index = ObjectIndex.from_objects(objs, SQLTableNodeMapping(sql_db), VectorStoreIndex)
        self._retriever = obj_index.as_retriever(similarity_top_k=TOP_K)
        self._qe = SQLTableRetrieverQueryEngine(sql_db, self._retriever)
        self._ready = True

    def predict(self, question, ctx) -> Prediction:
        if not getattr(self, "_ready", False):
            self._setup(ctx)
        # record the retrieved tables (for Set-Recall@k)
        try:
            nodes = self._retriever.retrieve(question.text)
            tables = tuple(getattr(n, "table_name", None) or n.node.metadata.get("name")
                           for n in nodes)
            tables = tuple(t for t in tables if t)
        except Exception:
            tables = None
        try:
            resp = self._qe.query(question.text)
            sql = resp.metadata.get("sql_query") if resp.metadata else None
            return Prediction(sql=sql, tables=tables)
        except Exception as e:  # noqa: BLE001
            return Prediction(sql=None, tables=tables, error=f"llamaindex: {str(e)[:160]}")
