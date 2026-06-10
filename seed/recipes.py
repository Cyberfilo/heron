"""Per-table realism layered on top of the generic engine output.

apply() runs for EVERY table after generic column generation and before COPY. It does
three things in order:
  1. generic NULLing of optional columns by name (so deleted_at is mostly NULL, etc.)
  2. generic temporal coherence (updated_at >= created_at; *_to >= *_from)
  3. table-specific fixes (constraint-safety + spine narrative: orders, payments, ...)

Everything is driven by the engine's deterministic RNG streams.
"""
from __future__ import annotations

import datetime as dt

import numpy as np

DAY = 86400

# (earlier, later, min_days, max_days): set `later` = `earlier` + U(min,max) days
FUTURE_PAIRS = [
    ("created_at", "updated_at", 0, 6),
    ("started_at", "last_seen_at", 0, 3),
    ("created_at", "expires_at", 1, 365),
    ("issued_at", "due_at", 7, 30),
    ("ordered_at", "received_at", 1, 21),
]
ORDER_PAIRS = [
    ("starts_at", "ends_at"), ("start_at", "end_at"), ("valid_from", "valid_to"),
    ("start_date", "end_date"), ("period_start", "period_end"),
    ("started_at", "ended_at"), ("manufacture_date", "expiry_date"),
    ("manufactured_at", "expires_at"), ("current_period_start", "current_period_end"),
]

NULL_PROB = {
    "deleted_at": 0.96, "archived_at": 0.9, "cancelled_at": 0.85, "canceled_at": 0.85,
    "refunded_at": 0.9, "closed_at": 0.6, "resolved_at": 0.6, "solved_at": 0.6,
    "revoked_at": 0.9, "used_at": 0.7, "confirmed_at": 0.4, "accepted_at": 0.6,
    "completed_at": 0.5, "delivered_at": 0.35, "shipped_at": 0.25, "paid_at": 0.2,
    "last_login_at": 0.3, "last_used_at": 0.4, "trial_ends_at": 0.7,
    "line2": 0.6, "phone": 0.4, "bio": 0.7, "middle_name": 0.8, "notes": 0.6,
    "description": 0.3, "parent_id": 0.7,
}
DEFAULT_NULL = 0.2


def _temporal(v):
    return (isinstance(v, list) and len(v) > 0 and v[0] is not None
            and isinstance(v[0], dt.date))  # dt.datetime is a subclass of dt.date


def _add(base, secs):
    if base is None:
        return None
    if isinstance(base, dt.datetime):
        return base + dt.timedelta(seconds=int(secs))
    return base + dt.timedelta(days=max(1, int(secs) // DAY))  # plain date column


def _partner(name):
    """Name of the 'end' column paired with a 'start' column, if any."""
    for a, b in (("start", "end"), ("_from", "_to"), ("begin", "finish"), ("opened", "closed")):
        if a in name:
            p = name.replace(a, b)
            if p != name:
                return p
    return None


RANGE_STATIC = [("manufacture_date", "expiry_date"), ("manufactured_at", "expires_at")]


def apply(fqtn, n, data, eng, tenant_arr):
    g = eng.rng.s(f"recipe.{fqtn}")
    colmeta = {c["name"]: c for c in eng.S["cols"][fqtn]}
    uniq = eng.S["uniq"][fqtn]

    # 1) NULL optional columns by name
    for name, v in list(data.items()):
        c = colmeta.get(name)
        if not c or not c["nullable"] or name in ("tenant_id", "created_at", "updated_at"):
            continue
        if name in uniq:
            continue
        p = NULL_PROB.get(name, DEFAULT_NULL if name.endswith("_at") and name not in (
            "occurred_at",) else 0.0)
        if p <= 0:
            continue
        mask = g.random(n) < p
        if isinstance(v, np.ndarray):
            v = v.astype(object); v[mask] = None; data[name] = v
        elif isinstance(v, list):
            data[name] = [None if mask[i] else v[i] for i in range(n)]

    # 2a) "later = earlier + small offset" forward pairs (created->updated, etc.)
    for a, b, lo, hi in FUTURE_PAIRS:
        if a in data and b in data and _temporal(data[a]):
            base = data[a]
            adds = g.integers(lo * DAY, hi * DAY + 1, n)
            data[b] = [_add(base[i], adds[i]) for i in range(n)]
    # 2b) generic + static range ordering (end >= start), datetime OR date
    pairs = [(a, _partner(a)) for a in list(data)]
    pairs = [(a, b) for a, b in pairs if b and b in data] + \
            [(a, b) for a, b in (ORDER_PAIRS + RANGE_STATIC) if a in data and b in data]
    for a, b in pairs:
        if _temporal(data.get(a)) and _temporal(data.get(b)):
            base = data[a]
            adds = g.integers(1 * DAY, 200 * DAY, n)
            data[b] = [_add(base[i], adds[i]) for i in range(n)]

    # 3) table-specific
    fn = SPECIFIC.get(fqtn)
    if fn:
        fn(n, data, eng, g, tenant_arr)


# --------------------------------------------------------------------------- #
# table-specific recipes (constraint-safety + spine narrative)
# --------------------------------------------------------------------------- #
def _money(g, n, mu=3.2, sigma=1.0):
    return np.round(g.lognormal(mu, sigma, n), 2)


def r_prices(n, data, eng, g, tenant_arr):
    # the EXCLUDE constraint forbids overlapping validity per (price_list,variant,min_quantity).
    # Make min_quantity unique per row -> the equality clause never matches -> no overlap.
    if "min_quantity" in data:
        data["min_quantity"] = np.arange(1, n + 1)


def r_orders(n, data, eng, g, tenant_arr):
    if "subtotal" in data:
        sub = _money(g, n, 3.5, 0.9)
        tax = np.round(sub * 0.08, 2)
        ship = np.round(g.choice([0, 4.99, 9.99, 14.99], n), 2)
        data["subtotal"] = sub
        if "tax_total" in data: data["tax_total"] = tax
        if "shipping_total" in data: data["shipping_total"] = ship
        if "discount_total" in data: data["discount_total"] = np.round(sub * g.choice([0, 0, 0, 0.1, 0.2], n), 2)
        grand = sub + tax + ship - (data.get("discount_total", np.zeros(n)) if "discount_total" in data else 0)
        for gname in ("grand_total", "total", "total_amount"):
            if gname in data: data[gname] = np.round(grand, 2)


def r_order_items(n, data, eng, g, tenant_arr):
    if "quantity" in data:
        data["quantity"] = g.integers(1, 6, n)
    if "unit_price" in data:
        up = _money(g, n, 2.8, 0.8)
        data["unit_price"] = up
        if "line_total" in data:
            data["line_total"] = np.round(up * data["quantity"], 2)


def r_subscriptions(n, data, eng, g, tenant_arr):
    # churn: a fraction are canceled
    if "status" in data:
        labels = eng.S["enums"].get("subscription_status", [])
        if labels:
            roll = g.random(n)
            st = np.where(roll < 0.035 * 24, "canceled",
                 np.where(roll < 0.18, "past_due", "active"))
            # keep only labels that exist
            st = np.where(np.isin(st, labels), st, labels[0])
            data["status"] = st.astype(object)


def r_payments(n, data, eng, g, tenant_arr):
    if "status" in data:
        labels = eng.S["enums"].get("payment_status", [])
        if labels:
            roll = g.random(n)
            target = np.where(roll < 0.079, "failed",
                     np.where(roll < 0.13, "refunded", "captured"))
            target = np.where(np.isin(target, labels), target, labels[0])
            data["status"] = target.astype(object)
    if "amount" in data:
        data["amount"] = _money(g, n, 3.4, 0.95)


def r_events(n, data, eng, g, tenant_arr):
    if "event_name" in data:
        vocab = np.array([
            "page_view", "product_viewed", "add_to_cart", "checkout_started",
            "order_completed", "search", "signup", "login", "feature_used",
            "subscription_started", "support_ticket_opened", "email_opened",
        ], dtype=object)
        # power-law popularity over events
        w = 1.0 / np.arange(1, len(vocab) + 1) ** 1.1
        w /= w.sum()
        data["event_name"] = vocab[g.choice(len(vocab), n, p=w)]


# --------------------------------------------------------------------------- #
# reference-data recipes: inject REAL ISO values so value-grounding questions
# ("revenue in EUR", "users in Germany", "Pro-plan subscribers") are natural.
# --------------------------------------------------------------------------- #
CURRENCIES = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "CNY", "SEK", "NZD",
              "MXN", "SGD", "HKD", "NOK", "KRW", "INR", "BRL", "ZAR", "DKK", "PLN",
              "TWD", "THB", "MYR", "IDR", "HUF", "CZK", "ILS", "CLP", "PHP", "AED"]
COUNTRIES = [("US", "USA", "United States"), ("GB", "GBR", "United Kingdom"),
             ("DE", "DEU", "Germany"), ("FR", "FRA", "France"), ("IT", "ITA", "Italy"),
             ("ES", "ESP", "Spain"), ("CA", "CAN", "Canada"), ("AU", "AUS", "Australia"),
             ("JP", "JPN", "Japan"), ("CN", "CHN", "China"), ("IN", "IND", "India"),
             ("BR", "BRA", "Brazil"), ("MX", "MEX", "Mexico"), ("NL", "NLD", "Netherlands"),
             ("SE", "SWE", "Sweden"), ("CH", "CHE", "Switzerland"), ("PL", "POL", "Poland"),
             ("IE", "IRL", "Ireland"), ("SG", "SGP", "Singapore"), ("KR", "KOR", "South Korea"),
             ("NO", "NOR", "Norway"), ("DK", "DNK", "Denmark"), ("FI", "FIN", "Finland"),
             ("BE", "BEL", "Belgium"), ("AT", "AUT", "Austria"), ("PT", "PRT", "Portugal"),
             ("NZ", "NZL", "New Zealand"), ("ZA", "ZAF", "South Africa"), ("AE", "ARE", "UAE"),
             ("IL", "ISR", "Israel"), ("HK", "HKG", "Hong Kong"), ("TW", "TWN", "Taiwan"),
             ("TH", "THA", "Thailand"), ("MY", "MYS", "Malaysia"), ("ID", "IDN", "Indonesia"),
             ("PH", "PHL", "Philippines"), ("CL", "CHL", "Chile"), ("CZ", "CZE", "Czechia"),
             ("HU", "HUN", "Hungary"), ("AR", "ARG", "Argentina")]
LOCALES = ["en-US", "en-GB", "de-DE", "fr-FR", "it-IT", "es-ES", "pt-BR", "nl-NL",
           "sv-SE", "ja-JP", "zh-CN", "ko-KR", "pl-PL", "da-DK", "fi-FI"]
PLAN_CODES = ["free", "starter", "pro", "business", "enterprise"]
CONTINENTS = {"US": "North America", "CA": "North America", "MX": "North America",
              "BR": "South America", "AR": "South America", "CL": "South America"}


def r_currencies(n, data, eng, g, tenant_arr):
    codes = CURRENCIES[:n]
    data["code"] = np.array(codes, dtype=object)
    if "name" in data:
        data["name"] = np.array([f"{c} currency" for c in codes], dtype=object)


def r_countries(n, data, eng, g, tenant_arr):
    cs = COUNTRIES[:n]
    if "iso2" in data: data["iso2"] = np.array([c[0] for c in cs], dtype=object)
    if "iso3" in data: data["iso3"] = np.array([c[1] for c in cs], dtype=object)
    if "name" in data: data["name"] = np.array([c[2] for c in cs], dtype=object)
    if "continent" in data:
        data["continent"] = np.array(
            [CONTINENTS.get(c[0], "Europe" if c[0] in
             ("GB", "DE", "FR", "IT", "ES", "NL", "SE", "CH", "PL", "IE", "NO", "DK",
              "FI", "BE", "AT", "PT", "CZ", "HU") else "Asia") for c in cs], dtype=object)


def r_locales(n, data, eng, g, tenant_arr):
    data["code"] = np.array(LOCALES[:n], dtype=object)


def r_plans(n, data, eng, g, tenant_arr):
    if "code" in data:
        data["code"] = np.array([PLAN_CODES[i % len(PLAN_CODES)] for i in range(n)], dtype=object)
    if "name" in data:
        data["name"] = np.array([PLAN_CODES[i % len(PLAN_CODES)].title() + " Plan"
                                 for i in range(n)], dtype=object)


def r_accounts(n, data, eng, g, tenant_arr):
    # B2B accounts have realistic, skewed company sizes (not the generic 1-12 cap)
    if "employee_count" in data:
        emp = (g.lognormal(3.5, 1.5, n)).astype(int) + 1
        data["employee_count"] = emp
        if "annual_revenue" in data:
            data["annual_revenue"] = np.round(emp * g.lognormal(11.0, 0.6, n), 2)


SPECIFIC = {
    "crm.accounts": r_accounts,
    "geo.currencies": r_currencies,
    "geo.countries": r_countries,
    "geo.locales": r_locales,
    "billing.plans": r_plans,
    "pricing.prices": r_prices,
    "sales.orders": r_orders,
    "sales.order_items": r_order_items,
    "billing.subscriptions": r_subscriptions,
    "billing.payments": r_payments,
    "analytics.events": r_events,
}
