"""Execution-equality result comparator.

Reimplements the semantics of Spider's `test-suite-sql-eval` `result_eq` /
`eval_exec_match` (Apache-2.0, github.com/taoyds/test-suite-sql-eval) so heron
scores with the field-standard comparator rather than a homegrown one. See
docs/METHODOLOGY.md §1.1 and docs/REUSE.md for the lineage + attribution.

Rules:
  - bag (multiset) semantics: duplicate rows must match in multiplicity
  - order-insensitive UNLESS the gold query has ORDER BY (then row order is enforced)
  - column-permutation tolerant (NL doesn't fix column order); searched up to 6 cols
  - typed equality: NULL==NULL, floats within 1e-6, Decimals normalized, datetimes by
    ISO string, uuid/bytes by value; strings exact, case-sensitive
  - empty result matches only an empty gold
"""
from __future__ import annotations

import datetime as dt
from collections import Counter
from decimal import Decimal
from itertools import permutations

FLOAT_TOL = 1e-6
MAX_PERM_COLS = 6  # beyond this, assume the predicted column order is intended


def _norm(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    if isinstance(v, Decimal):
        return round(float(v), 6)
    if isinstance(v, float):
        return round(v, 6)
    if isinstance(v, (dt.datetime, dt.date)):
        return v.isoformat()
    if isinstance(v, (bytes, bytearray, memoryview)):
        return bytes(v)
    if isinstance(v, (list, dict)):
        return repr(v)
    # int, str, uuid -> stable comparable
    return v if isinstance(v, (int, str)) else str(v)


def _rows(rows):
    return [tuple(_norm(c) for c in r) for r in rows]


def result_eq(gold, pred, order_matters: bool) -> bool:
    """True iff the predicted result set equals the gold result set."""
    if pred is None:
        return False
    g = _rows(gold)
    p = _rows(pred)
    if not g and not p:
        return True
    if not g or not p:
        return False
    nc = len(g[0])
    if len(p[0]) != nc:
        return False
    perms = [tuple(range(nc))] if nc > MAX_PERM_COLS else list(permutations(range(nc)))
    gcount = None if order_matters else Counter(g)
    for perm in perms:
        pp = [tuple(r[i] for i in perm) for r in p]
        if order_matters:
            if pp == g:
                return True
        elif Counter(pp) == gcount:
            return True
    return False


def soft_f1(gold, pred, order_matters: bool = False) -> float:
    """Row-multiset F1 between result sets — partial credit when a prediction is
    *almost* right (BIRD-2.0-style Soft-F1, table-level). 1.0 == exact bag match,
    0.0 == disjoint. Column-permutation tolerant; on a column-count mismatch we
    compare rows as-is (no alignment) so spurious/missing columns are penalized.

    F1 = 2 * |gold ∩ pred| / (|gold| + |pred|)   over the best column alignment.
    """
    if pred is None:
        return 0.0
    g = _rows(gold)
    p = _rows(pred)
    if not g and not p:
        return 1.0
    if not g or not p:
        return 0.0
    nc = len(g[0])
    denom = len(g) + len(p)
    if len(p[0]) != nc:
        inter = sum((Counter(g) & Counter(p)).values())
        return 2 * inter / denom
    perms = [tuple(range(nc))] if nc > MAX_PERM_COLS else list(permutations(range(nc)))
    gcount = Counter(g)
    best = 0
    for perm in perms:
        pc = Counter(tuple(r[i] for i in perm) for r in p)
        best = max(best, sum((gcount & pc).values()))
    return 2 * best / denom


def ves_reward(ex: bool, gold_ms: float, pred_ms: float, cap: float = 3.0) -> float:
    """BIRD Valid Efficiency Score reward for one question: sqrt(gold/pred) if the
    prediction is execution-correct, else 0. >1 means the prediction is faster than
    gold; the sqrt dampens timing noise. Capped so a near-zero pred time can't blow
    up the mean. Aggregate VES = 100 * mean(reward) over questions with valid gold.
    """
    if not ex or not gold_ms or not pred_ms or pred_ms <= 0:
        return 0.0
    return min(cap, (gold_ms / pred_ms) ** 0.5)


def has_order_by(sql: str) -> bool:
    """Cheap check: does the (outer) gold query pin row order?"""
    try:
        import sqlglot
        from sqlglot import exp
        tree = sqlglot.parse_one(sql, read="postgres")
        return tree.find(exp.Order) is not None
    except Exception:
        return "order by" in sql.lower()
