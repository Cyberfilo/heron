"""Adapter registry. An adapter maps an NL question to a predicted SQL (and,
optionally, the set of tables it retrieved — for the retrieval axis)."""
from __future__ import annotations

from .base import Adapter, Prediction


def get_adapter(name: str) -> Adapter:
    if name == "gold":
        from .gold import GoldAdapter
        return GoldAdapter()
    if name == "raw-llm":
        from .raw_llm import RawLLMAdapter
        return RawLLMAdapter()
    if name == "promptquery":
        from .promptquery import PromptQueryAdapter
        return PromptQueryAdapter()
    if name == "llamaindex":
        from .llamaindex import LlamaIndexAdapter
        return LlamaIndexAdapter()
    if name == "langchain":
        from .langchain_tool import LangChainAdapter
        return LangChainAdapter()
    if name == "vanna":
        from .vanna_tool import VannaAdapter
        return VannaAdapter()
    if name == "mac-sql":
        from .macsql import MacSqlAdapter
        return MacSqlAdapter()
    if name == "din-sql":
        from .dinsql import DinSqlAdapter
        return DinSqlAdapter()
    raise SystemExit(f"unknown adapter: {name!r} (have: gold, raw-llm, promptquery, "
                     f"llamaindex, langchain, vanna, mac-sql, din-sql)")
