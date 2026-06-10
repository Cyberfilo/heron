"""Scale factors, target row counts, and realism constants for the generator.

Row counts are expressed at `bench` scale and multiplied by the scale factor.
Reference/lookup tables are FIXED (scale-independent) — there are only ~195
countries no matter how big the benchmark is. See DECISIONS.md §D3.
"""
from __future__ import annotations

# Multiplier applied to BENCH_ROWS for each scale. tiny is for CI smoke tests.
SCALE_MULT = {
    "tiny":  0.002,
    "small": 0.05,
    "bench": 1.0,
    "large": 5.0,
}

# Scale-independent reference data (real-world cardinalities).
FIXED_ROWS = {
    "geo.countries": 40,     # real ISO countries injected by a recipe (value-grounding)
    "geo.regions": 700,
    "geo.cities": 3000,
    "geo.currencies": 30,    # real ISO-4217 codes injected by a recipe
    "geo.exchange_rates": 2000,
    "geo.locales": 15,       # real BCP-47 locales injected by a recipe
    "geo.timezones": 60,
    "geo.postal_zones": 800,
    "identity.permissions": 80,
}

# Target rows at BENCH scale for the tables that carry narrative + volume.
# Everything not listed falls back to DEFAULT_TENANT_ROWS (scaled).
BENCH_ROWS = {
    # identity
    "identity.tenants": 50,
    "identity.users": 200_000,
    "identity.user_profiles": 200_000,
    "identity.user_preferences": 200_000,
    "identity.sessions": 800_000,
    "identity.login_attempts": 1_200_000,
    "identity.api_keys": 4_000,
    # geo
    "geo.addresses": 320_000,
    # catalog
    "catalog.brands": 6_000,
    "catalog.products": 40_000,
    "catalog.product_variants": 120_000,
    "catalog.categories": 4_000,
    "catalog.product_categories": 90_000,
    "catalog.product_media": 240_000,
    "catalog.product_reviews": 380_000,
    "catalog.review_votes": 900_000,
    # pricing
    "pricing.prices": 200_000,
    "pricing.coupons": 30_000,
    "pricing.coupon_redemptions": 180_000,
    # inventory
    "inventory.stock_items": 260_000,
    "inventory.stock_movements": 2_400_000,
    "inventory.stock_reservations": 700_000,
    "inventory.purchase_order_lines": 150_000,
    # sales (the spine)
    "sales.carts": 1_400_000,
    "sales.cart_items": 3_000_000,
    "sales.orders": 1_000_000,
    "sales.order_items": 3_500_000,
    "sales.order_status_history": 2_600_000,
    "sales.fulfillments": 900_000,
    "sales.fulfillment_items": 2_900_000,
    "sales.shipments": 900_000,
    "sales.shipment_tracking": 2_700_000,
    "sales.returns": 180_000,
    "sales.return_items": 320_000,
    # billing
    "billing.payments": 1_050_000,
    "billing.payment_attempts": 1_300_000,
    "billing.payment_refunds": 120_000,
    "billing.invoices": 900_000,
    "billing.invoice_lines": 2_200_000,
    "billing.plans": 250,            # ~5 real plan codes per tenant
    "billing.subscriptions": 90_000,
    "billing.subscription_items": 140_000,
    "billing.usage_records": 3_000_000,
    "billing.ledger_entries": 4_000_000,
    # crm
    "crm.accounts": 40_000,
    "crm.contacts": 160_000,
    "crm.opportunities": 120_000,
    "crm.activities": 700_000,
    # support
    "support.tickets": 260_000,
    "support.ticket_messages": 1_100_000,
    "support.ticket_events": 1_400_000,
    "support.csat_responses": 90_000,
    # marketing
    "marketing.campaign_messages": 5_000_000,
    "marketing.segment_members": 1_800_000,
    "marketing.loyalty_transactions": 1_200_000,
    "marketing.attributions": 900_000,
    # analytics (the biggest fact table)
    "analytics.events": 10_000_000,
    "analytics.web_sessions": 2_400_000,
    "analytics.page_views": 7_000_000,
    "analytics.feature_usage": 1_500_000,
    "analytics.metrics_daily": 400_000,
    # comms
    "comms.notifications": 3_000_000,
    "comms.email_log": 4_000_000,
    "comms.webhook_deliveries": 2_000_000,
    # audit
    "audit.audit_log": 2_000_000,
    "audit.change_history": 2_400_000,
    "audit.access_log": 1_600_000,
    # ops
    "ops.job_runs": 1_500_000,
    "ops.files": 500_000,
    "ops.import_errors": 600_000,
}

DEFAULT_TENANT_ROWS = 8_000   # bench default for unlisted tenant-scoped tables
DEFAULT_LOOKUP_ROWS = 300     # bench default for tables with no tenant_id

# Realistic rates reproduced as Bernoulli draws (sources in DATA-REALISM.md).
RATES = {
    "cart_abandonment": 0.70,      # ~70% of carts never convert
    "order_cancelled": 0.08,
    "order_refunded": 0.06,
    "return_rate": 0.20,           # ~20% of delivered items returned (apparel-ish)
    "payment_decline": 0.079,      # ~7.9% card declines
    "subscription_churn_monthly": 0.035,
    "email_bounce": 0.012,
    "email_open": 0.21,
    "review_left": 0.08,           # fraction of order_items that get reviewed
    "user_inactive": 0.30,
    "null_optional": 0.25,         # generic chance an optional column is NULL
}

# Zipf exponent for skew (1.0 = classic Zipf; lower = flatter).
ZIPF_A = {
    "tenant_size": 1.6,    # a few big tenants, long tail of small ones
    "product_popularity": 1.2,
    "customer_activity": 1.3,
}

# Simulation time window: data spans this many days ending at REF_DATE.
HISTORY_DAYS = 730            # ~2 years of history
REF_DATE = "2026-06-01"      # generation reference "today" (fixed for determinism)


def rows_for(table: str, scale: str) -> int:
    """Target row count for a table at a given scale."""
    if table == "identity.tenants":
        # tenants scale gently so multi-tenancy is real even at small scales
        return {"tiny": 5, "small": 25, "bench": 50, "large": 150}[scale]
    if table in FIXED_ROWS:
        # reference data barely scales; shrink only a little for tiny
        n = FIXED_ROWS[table]
        return max(5, int(n * (0.25 if scale == "tiny" else 1.0)))
    mult = SCALE_MULT[scale]
    if table in BENCH_ROWS:
        return max(1, int(BENCH_ROWS[table] * mult))
    # unlisted: depends on whether it's tenant-scoped (decided by the engine,
    # which passes the right default via rows_for_default).
    return -1  # sentinel: engine fills via rows_for_default


def rows_for_default(scale: str, tenant_scoped: bool) -> int:
    mult = SCALE_MULT[scale]
    base = DEFAULT_TENANT_ROWS if tenant_scoped else DEFAULT_LOOKUP_ROWS
    return max(3, int(base * (mult if tenant_scoped else max(mult, 0.5))))
