"""Vanna adapter — the classic RAG-over-DDL approach (vanna 0.7.9, MIT).

Vanna's design: train a vector store on per-table DDL, then at query time RAG the relevant
DDL and ask the LLM. This handles large schemas via retrieval (its claim to fame). We train on
the real per-table CREATE statements from heron's own schema/*.sql, and recover the retrieved
tables (via get_related_ddl) for Set-Recall@k. Embeddings are ChromaDB-local (free); only
generation uses gpt-4o.

NOTE: `pip install vanna` now yields the 2.0 agent rewrite — we pin 0.7.9 for this API.
Runs in the vanna venv:  ~/.heron-tools/venv-vanna/bin/python harness/run.py --adapter vanna --model openai/gpt-4o
"""
from __future__ import annotations

import glob
import os
import re

from .base import Adapter, Prediction

SCHEMA_GLOB = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), "schema", "[0-9]*_*.sql")
CREATE_RE = re.compile(r"(CREATE TABLE[\s\S]*?\)\s*;)", re.I)
TABLE_NAME_RE = re.compile(r"CREATE TABLE\s+([a-z_]+\.[a-z_]+)", re.I)


def _per_table_ddl() -> list[str]:
    ddls = []
    for f in sorted(glob.glob(SCHEMA_GLOB)):
        with open(f) as fh:
            ddls += CREATE_RE.findall(fh.read())
    return ddls


class VannaAdapter(Adapter):
    name = "vanna"

    def _setup(self, ctx):
        from vanna.openai import OpenAI_Chat
        from vanna.chromadb import ChromaDB_VectorStore

        model = (ctx.get("model") or "gpt-4o").replace("openai/", "")

        class _V(ChromaDB_VectorStore, OpenAI_Chat):
            def __init__(self, config):
                ChromaDB_VectorStore.__init__(self, config=config)
                OpenAI_Chat.__init__(self, config=config)

        path = os.path.expanduser("~/.heron-tools/chroma-heron")
        vn = _V(config={"api_key": os.environ["OPENAI_API_KEY"], "model": model,
                        "temperature": 0, "path": path})
        # train once: only if the store is empty (chroma persists across runs)
        try:
            existing = vn.get_training_data()
            trained = len(existing) if existing is not None else 0
        except Exception:  # noqa: BLE001
            trained = 0
        if not trained:
            for ddl in _per_table_ddl():
                vn.train(ddl=ddl)
        self._vn = vn
        self._ready = True

    def predict(self, question, ctx) -> Prediction:
        if not getattr(self, "_ready", False):
            self._setup(ctx)
        # Tokens are recorded by the harness usage meter (real OpenAI billed usage),
        # so the adapter just returns SQL + its retrieved tables.
        tables = None
        try:
            related = self._vn.get_related_ddl(question.text)
            names = []
            for d in (related or []):
                names += TABLE_NAME_RE.findall(d if isinstance(d, str) else str(d))
            tables = tuple(dict.fromkeys(names)) or None
        except Exception:  # noqa: BLE001
            pass
        try:
            sql = self._vn.generate_sql(question.text, allow_llm_to_see_data=False)
        except Exception as e:  # noqa: BLE001
            return Prediction(sql=None, tables=tables, error=f"vanna: {str(e)[:160]}")
        if sql and not sql.strip().lower().startswith(("select", "with")):
            return Prediction(sql=None, tables=tables, error="vanna: non-SELECT/abstained")
        return Prediction(sql=(sql.strip().rstrip(";") if sql else None), tables=tables)
