"""Authoritative token accounting — capture OpenAI's *billed* usage, not an estimate.

Every tool in the matrix ultimately calls the official `openai` Python SDK
(`chat.completions.create` / `embeddings.create`) — directly (raw-llm, MAC-SQL,
DIN-SQL), or buried inside its own pipeline (PromptQuery, Vanna, LangChain,
LlamaIndex). We wrap those SDK methods once and read the `response.usage` object
OpenAI returns — the exact `prompt_tokens` / `completion_tokens` it billed.

This is what makes the published token numbers real and precise (not a tiktoken
estimate, which omits chat-message framing overhead). `harness/run.py` resets the
meter before each question and reads the total after, so the count is per-question
and tool-agnostic: any system that talks to the OpenAI API is measured identically.
"""
from __future__ import annotations

import threading

_lock = threading.Lock()
_pt = _ct = _calls = 0
_installed = False

# USD per 1,000,000 tokens (input, output) — OpenAI list prices. Extend as needed.
PRICES = {
    "gpt-4o-mini": (0.15, 0.60),
    "gpt-4o": (2.50, 10.00),
    "gpt-4.1-mini": (0.40, 1.60),
    "gpt-4.1": (2.00, 8.00),
    "o4-mini": (1.10, 4.40),
}
_DEFAULT_PRICE = (2.50, 10.00)  # assume gpt-4o pricing if model is unknown


def price_for(model: str | None):
    m = (model or "gpt-4o").replace("openai/", "")
    # match the most specific (longest) price key the model name starts with
    for key in sorted(PRICES, key=len, reverse=True):
        if m.startswith(key):
            return PRICES[key]
    return _DEFAULT_PRICE


def cost_usd(prompt_tokens: int, completion_tokens: int, model: str | None) -> float:
    pin, pout = price_for(model)
    return (prompt_tokens or 0) / 1e6 * pin + (completion_tokens or 0) / 1e6 * pout


def reset():
    global _pt, _ct, _calls
    with _lock:
        _pt = _ct = _calls = 0


def totals():
    """(prompt_tokens, completion_tokens, n_api_calls) since the last reset()."""
    with _lock:
        return _pt, _ct, _calls


def _accumulate(usage):
    if usage is None:
        return
    # chat uses prompt/completion_tokens; embeddings/responses use input/output_tokens
    pt = getattr(usage, "prompt_tokens", None)
    if pt is None:
        pt = getattr(usage, "input_tokens", 0) or 0
    ct = getattr(usage, "completion_tokens", None)
    if ct is None:
        ct = getattr(usage, "output_tokens", 0) or 0
    global _pt, _ct, _calls
    with _lock:
        _pt += pt or 0
        _ct += ct or 0
        _calls += 1


def _wrap(cls, method_name):
    orig = getattr(cls, method_name, None)
    if orig is None:
        return
    def wrapped(self, *args, **kwargs):
        resp = orig(self, *args, **kwargs)
        try:
            _accumulate(getattr(resp, "usage", None))
        except Exception:  # noqa: BLE001 — metering must never break a tool
            pass
        return resp
    setattr(cls, method_name, wrapped)


def install():
    """Monkeypatch the OpenAI SDK's create() methods to record real billed usage.
    Idempotent; safe to call once at harness start."""
    global _installed
    if _installed:
        return
    try:
        from openai.resources.chat.completions import Completions, AsyncCompletions
        _wrap(Completions, "create")
        _wrap(AsyncCompletions, "create")
    except Exception:  # noqa: BLE001
        pass
    try:
        from openai.resources.embeddings import Embeddings, AsyncEmbeddings
        _wrap(Embeddings, "create")
        _wrap(AsyncEmbeddings, "create")
    except Exception:  # noqa: BLE001
        pass
    try:  # newer Responses API, if a tool uses it
        from openai.resources.responses import Responses, AsyncResponses
        _wrap(Responses, "create")
        _wrap(AsyncResponses, "create")
    except Exception:  # noqa: BLE001
        pass
    _installed = True
