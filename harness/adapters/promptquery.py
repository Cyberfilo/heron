"""PromptQuery adapter — the retrieval-aware system, scored on BOTH axes.

Drives the installed `promptquery` pipeline per question: TF-IDF rank -> (optional) LLM
table selector -> FK-graph expansion (this is the retrieved-table set used for
Set-Recall@k) -> build prompt over only those tables -> generate -> extract SQL. This is
the head-to-head against the naive full-schema baseline that heron exists to produce.

Requires `pip install -e <promptquery repo>` into the harness venv. Same generation model
as the baseline => the only difference is retrieval. Defaults mirror prq's CLI
(top-k 50, select 15, max-tables 25).
"""
from __future__ import annotations

from .base import Adapter, Prediction


class PromptQueryAdapter(Adapter):
    name = "promptquery"

    def __init__(self, top_k: int = 50, select_n: int = 15, max_tables: int = 25):
        self.top_k, self.select_n, self.max_tables = top_k, select_n, max_tables
        self._ready = False

    def _setup(self, ctx):
        from promptquery.db import Database
        from promptquery.schema import introspect
        from promptquery.retrieval import TfIdfRetriever
        from promptquery.llm import make_client
        self._db = Database(ctx["dsn"]).__enter__()
        self._schema = introspect(self._db)
        self._retriever = TfIdfRetriever(self._schema)
        model = ctx.get("model")
        self._llm = make_client(model)
        sel = ctx.get("selector_model") or model
        self._selector = make_client(sel) if sel else self._llm
        self._ready = True

    def predict(self, question, ctx) -> Prediction:
        if not self._ready:
            self._setup(ctx)
        from promptquery.retrieval import expand_via_fks, llm_select_tables
        from promptquery.llm import extract_sql
        from promptquery.prompts import build_system_prompt

        ranked = self._retriever.rank(question.text, top_k=self.top_k)
        candidates = [t for t, s in ranked if s > 0] or [t for t, _ in ranked[:3]]
        if self._selector is not None and len(candidates) > self.select_n:
            try:
                sel = llm_select_tables(question.text, candidates, self._selector,
                                        max_select=self.select_n)
                if sel:
                    candidates = sel
            except Exception:  # noqa: BLE001 — selector failure degrades to TF-IDF (prq behavior)
                pass
        relevant = expand_via_fks(self._schema, candidates, max_total=self.max_tables)
        tables = tuple(t.qualified_name for t in relevant)
        system = build_system_prompt(relevant)
        try:
            raw = self._llm.generate(system, question.text)
        except Exception as e:  # noqa: BLE001
            return Prediction(sql=None, tables=tables, error=f"llm: {e}")

        def _tok(s):  # tiktoken estimate of the actual strings sent/received
            try:
                import tiktoken
                return len(tiktoken.get_encoding("o200k_base").encode(s or ""))
            except Exception:
                return max(1, len(s or "") // 4)

        return Prediction(sql=extract_sql(raw), tables=tables,
                          prompt_tokens=_tok(system) + _tok(question.text),
                          completion_tokens=_tok(raw or ""))
