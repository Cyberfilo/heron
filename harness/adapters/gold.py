from __future__ import annotations

from .base import Adapter, Prediction


class GoldAdapter(Adapter):
    """Returns the gold SQL itself. A sanity adapter: EX must be 1.0 and retrieval
    Set-Recall must be 1.0 — if not, the harness/data/comparator is broken."""
    name = "gold"

    def predict(self, question, ctx) -> Prediction:
        return Prediction(sql=question.gold_sql, tables=tuple(question.gold_tables))
