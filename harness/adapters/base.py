from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Prediction:
    sql: str | None
    tables: tuple[str, ...] | None = None   # tables the system retrieved (None = end-to-end)
    error: str | None = None
    prompt_tokens: int | None = None        # tokens sent to the LLM for this question
    completion_tokens: int | None = None    # tokens returned


class Adapter:
    """Subclasses implement predict(). ctx is a dict with at least {'dsn', 'schema_text'}."""
    name = "base"

    def predict(self, question, ctx) -> Prediction:  # noqa: D401
        raise NotImplementedError
