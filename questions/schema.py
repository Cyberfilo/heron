"""The Question type + loader for the heron suite.

A question carries the NL text, a verified gold SQL, the set of tables any correct
answer MUST reference (the retrieval ground truth), and two difficulty axes (see
docs/METHODOLOGY.md §4). Gold SQL is validated by harness/audit.py before publication.
"""
from __future__ import annotations

import importlib
import pkgutil
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Question:
    id: str
    text: str
    gold_sql: str
    gold_tables: tuple[str, ...]          # schema-qualified tables a correct answer must use
    sql_shape: str = "single"             # single | join | multi-join | analytical
    retrieval: str = "named"              # named | 1-hop | 2-hop+ | lexical-gap
    tags: tuple[str, ...] = field(default_factory=tuple)


def load_all() -> list[Question]:
    """Collect QUESTIONS from every sibling module (questions/<set>.py)."""
    import questions  # package
    out: list[Question] = []
    for mod in pkgutil.iter_modules(questions.__path__):
        if mod.name in ("schema",):
            continue
        m = importlib.import_module(f"questions.{mod.name}")
        out.extend(getattr(m, "QUESTIONS", []))
    # stable order + dup-id guard
    seen = set()
    for q in out:
        if q.id in seen:
            raise ValueError(f"duplicate question id: {q.id}")
        seen.add(q.id)
    return sorted(out, key=lambda q: q.id)
