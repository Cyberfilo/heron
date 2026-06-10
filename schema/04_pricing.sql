-- 04_pricing.sql — price lists, prices, discounts, coupons, tax, promotions.
-- Money lives here: every monetary column is numeric(14,4) paired with a
-- currency_code char(3) -> geo.currencies(code). Cross-schema FKs reach back to
-- identity (tenants), geo (currencies, countries, regions, postal_zones), and
-- catalog (product_variants, products). promotions are deliberately STANDALONE:
-- marketing (module 10) references pricing.promotions, never the reverse.
-- Soft-deletable: price_lists, discounts, coupons, promotions (deleted_at NULL = live).
-- See CONVENTIONS.md and SCHEMA-MAP.md.

-- ===========================================================================
-- price_lists — named price books, each scoped to a single currency. A tenant
-- typically keeps one "default" list per currency plus contract/region books.
-- ===========================================================================
CREATE TABLE pricing.price_lists (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    name          text NOT NULL,
    code          text NOT NULL,
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    is_default    boolean NOT NULL DEFAULT false,
    is_active     boolean NOT NULL DEFAULT true,
    starts_at     timestamptz,
    ends_at       timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT price_lists_tenant_code_uq UNIQUE (tenant_id, code),
    CONSTRAINT price_lists_window_ck CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX ON pricing.price_lists (tenant_id);
-- one default price list per (tenant, currency)
CREATE UNIQUE INDEX price_lists_one_default_idx
    ON pricing.price_lists (tenant_id, currency_code) WHERE is_default;

-- ===========================================================================
-- prices — a variant's price within a price_list, with a validity window. The
-- EXCLUDE constraint forbids two overlapping live windows for the same
-- (price_list, variant), so a variant never has an ambiguous price at a point
-- in time. valid_from/valid_to are materialized into a tstzrange for the gist.
-- ===========================================================================
CREATE TABLE pricing.prices (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    price_list_id bigint NOT NULL REFERENCES pricing.price_lists(id) ON DELETE CASCADE,
    variant_id    bigint NOT NULL REFERENCES catalog.product_variants(id) ON DELETE CASCADE,
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    amount        numeric(14,4) NOT NULL CHECK (amount >= 0),
    compare_at_amount numeric(14,4) CHECK (compare_at_amount IS NULL OR compare_at_amount >= 0),
    min_quantity  integer NOT NULL DEFAULT 1 CHECK (min_quantity > 0),
    valid_from    timestamptz NOT NULL DEFAULT now(),
    valid_to      timestamptz,
    validity      tstzrange NOT NULL GENERATED ALWAYS AS (tstzrange(valid_from, valid_to, '[)')) STORED,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT prices_window_ck CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT prices_no_overlap EXCLUDE USING gist (
        price_list_id WITH =,
        variant_id    WITH =,
        min_quantity  WITH =,
        validity      WITH &&
    )
);
CREATE INDEX ON pricing.prices (tenant_id);
CREATE INDEX ON pricing.prices (price_list_id);
CREATE INDEX ON pricing.prices (variant_id);
CREATE INDEX prices_variant_active_idx ON pricing.prices (variant_id) WHERE valid_to IS NULL;

-- ===========================================================================
-- discounts — reusable discount definitions (the "what"); coupons and
-- promotions point at these for the actual reduction. kind drives how value is
-- interpreted (percentage of subtotal, fixed amount off, free shipping, BOGO).
-- ===========================================================================
CREATE TABLE pricing.discounts (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    name              text NOT NULL,
    kind              pricing.discount_kind NOT NULL,
    value             numeric(14,4) NOT NULL CHECK (value >= 0),
    currency_code     char(3) REFERENCES geo.currencies(code),
    max_amount        numeric(14,4) CHECK (max_amount IS NULL OR max_amount >= 0),
    min_subtotal      numeric(14,4) CHECK (min_subtotal IS NULL OR min_subtotal >= 0),
    applies_to_shipping boolean NOT NULL DEFAULT false,
    is_active         boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz,
    -- fixed-amount discounts need a currency; percentage/free_shipping/bogo do not
    CONSTRAINT discounts_fixed_currency_ck
        CHECK (kind <> 'fixed_amount' OR currency_code IS NOT NULL),
    CONSTRAINT discounts_pct_range_ck
        CHECK (kind <> 'percentage' OR value <= 100)
);
CREATE INDEX ON pricing.discounts (tenant_id);

-- ===========================================================================
-- coupons — redeemable codes that grant a discount. code is unique per tenant.
-- usage_limit caps total redemptions; per_customer_limit caps per user.
-- ===========================================================================
CREATE TABLE pricing.coupons (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    discount_id        bigint NOT NULL REFERENCES pricing.discounts(id) ON DELETE RESTRICT,
    code               text NOT NULL,
    status             pricing.coupon_status NOT NULL DEFAULT 'active',
    usage_limit        integer CHECK (usage_limit IS NULL OR usage_limit > 0),
    per_customer_limit integer CHECK (per_customer_limit IS NULL OR per_customer_limit > 0),
    times_redeemed     integer NOT NULL DEFAULT 0 CHECK (times_redeemed >= 0),
    starts_at          timestamptz,
    expires_at         timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz,
    CONSTRAINT coupons_tenant_code_uq UNIQUE (tenant_id, code),
    CONSTRAINT coupons_window_ck CHECK (expires_at IS NULL OR starts_at IS NULL OR expires_at > starts_at)
);
CREATE INDEX ON pricing.coupons (tenant_id);
CREATE INDEX ON pricing.coupons (discount_id);
CREATE INDEX coupons_active_idx ON pricing.coupons (tenant_id) WHERE status = 'active';

-- ===========================================================================
-- coupon_redemptions — immutable record of each coupon use. References the
-- redeeming user (identity, lower-numbered). The redeemed order lives in sales
-- (module 06, higher-numbered): order_id is carried as a plain bigint and its
-- FK to sales.orders(id) is added by 06_sales.sql via trailing ALTER, to keep
-- pricing free of any forward dependency. discount_amount is what was applied.
-- ===========================================================================
CREATE TABLE pricing.coupon_redemptions (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    coupon_id       bigint NOT NULL REFERENCES pricing.coupons(id) ON DELETE CASCADE,
    user_id         bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    order_id        bigint,                       -- -> sales.orders(id); FK added in 06_sales.sql
    discount_amount numeric(14,4) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    redeemed_at     timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON pricing.coupon_redemptions (tenant_id);
CREATE INDEX ON pricing.coupon_redemptions (coupon_id);
CREATE INDEX ON pricing.coupon_redemptions (user_id);
CREATE INDEX ON pricing.coupon_redemptions (order_id);

-- ===========================================================================
-- tax_categories — product tax classes (e.g. standard goods, digital, food,
-- exempt). Variants/products are mapped to one of these to find their rate.
-- ===========================================================================
CREATE TABLE pricing.tax_categories (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    name        text NOT NULL,
    code        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tax_categories_tenant_code_uq UNIQUE (tenant_id, code)
);
CREATE INDEX ON pricing.tax_categories (tenant_id);

-- ===========================================================================
-- tax_zones — geographic regions for tax purposes. A zone is defined at the
-- granularity of a country, optionally narrowed to a region, optionally to a
-- specific postal zone. All three geo refs are nullable and SET NULL on delete.
-- ===========================================================================
CREATE TABLE pricing.tax_zones (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    name           text NOT NULL,
    country_id     bigint REFERENCES geo.countries(id) ON DELETE SET NULL,
    region_id      bigint REFERENCES geo.regions(id) ON DELETE SET NULL,
    postal_zone_id bigint REFERENCES geo.postal_zones(id) ON DELETE SET NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON pricing.tax_zones (tenant_id);
CREATE INDEX ON pricing.tax_zones (country_id);
CREATE INDEX ON pricing.tax_zones (region_id);
CREATE INDEX ON pricing.tax_zones (postal_zone_id);

-- ===========================================================================
-- tax_rates — the effective rate for a (tax_category, tax_zone) pair, with an
-- optional validity window so rate changes are auditable over time.
-- ===========================================================================
CREATE TABLE pricing.tax_rates (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    tax_category_id bigint NOT NULL REFERENCES pricing.tax_categories(id) ON DELETE CASCADE,
    tax_zone_id     bigint NOT NULL REFERENCES pricing.tax_zones(id) ON DELETE CASCADE,
    name            text NOT NULL,
    rate            numeric(8,5) NOT NULL CHECK (rate >= 0 AND rate <= 1),
    is_compound     boolean NOT NULL DEFAULT false,
    is_inclusive    boolean NOT NULL DEFAULT false,
    valid_from      timestamptz NOT NULL DEFAULT now(),
    valid_to        timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tax_rates_window_ck CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE INDEX ON pricing.tax_rates (tenant_id);
CREATE INDEX ON pricing.tax_rates (tax_category_id);
CREATE INDEX ON pricing.tax_rates (tax_zone_id);
CREATE INDEX tax_rates_category_zone_idx ON pricing.tax_rates (tax_category_id, tax_zone_id);

-- ===========================================================================
-- price_rules — conditional pricing rule headers (e.g. "10% off when cart has
-- 3+ items from brand X"). Conditions live in price_rule_conditions. The reward
-- references a discount definition. priority orders evaluation; lower = first.
-- ===========================================================================
CREATE TABLE pricing.price_rules (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    discount_id bigint REFERENCES pricing.discounts(id) ON DELETE SET NULL,
    name        text NOT NULL,
    priority    integer NOT NULL DEFAULT 100,
    is_active   boolean NOT NULL DEFAULT true,
    stackable   boolean NOT NULL DEFAULT false,
    starts_at   timestamptz,
    ends_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT price_rules_window_ck CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX ON pricing.price_rules (tenant_id);
CREATE INDEX ON pricing.price_rules (discount_id);

CREATE TABLE pricing.price_rule_conditions (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    price_rule_id bigint NOT NULL REFERENCES pricing.price_rules(id) ON DELETE CASCADE,
    attribute     text NOT NULL,
    operator      text NOT NULL DEFAULT 'eq',
    value         jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON pricing.price_rule_conditions (tenant_id);
CREATE INDEX ON pricing.price_rule_conditions (price_rule_id);

-- ===========================================================================
-- promotions — campaign-linked promo headers. STANDALONE on purpose: marketing
-- (module 10) FKs to pricing.promotions(id); we do NOT reference marketing. A
-- promotion grants a discount over a validity window, optionally gated by a
-- coupon code. campaign_code is a free-text correlation handle to a marketing
-- campaign, not an FK (marketing is higher-numbered).
-- ===========================================================================
CREATE TABLE pricing.promotions (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    discount_id   bigint REFERENCES pricing.discounts(id) ON DELETE SET NULL,
    coupon_id     bigint REFERENCES pricing.coupons(id) ON DELETE SET NULL,
    name          text NOT NULL,
    slug          text NOT NULL,
    campaign_code text,
    is_active     boolean NOT NULL DEFAULT true,
    starts_at     timestamptz,
    ends_at       timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT promotions_tenant_slug_uq UNIQUE (tenant_id, slug),
    CONSTRAINT promotions_window_ck CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX ON pricing.promotions (tenant_id);
CREATE INDEX ON pricing.promotions (discount_id);
CREATE INDEX ON pricing.promotions (coupon_id);
CREATE INDEX promotions_active_idx ON pricing.promotions (tenant_id) WHERE is_active;

CREATE TABLE pricing.promotion_products (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    promotion_id bigint NOT NULL REFERENCES pricing.promotions(id) ON DELETE CASCADE,
    product_id   bigint NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT promotion_products_uq UNIQUE (promotion_id, product_id)
);
CREATE INDEX ON pricing.promotion_products (tenant_id);
CREATE INDEX ON pricing.promotion_products (product_id);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE pricing.price_lists IS 'Named price books, each scoped to one currency; a tenant keeps a default list per currency plus contract/regional books.';
COMMENT ON TABLE pricing.prices IS 'A variant''s price within a price list over a validity window; an exclusion constraint forbids overlapping windows for the same list/variant/min_quantity.';
COMMENT ON COLUMN pricing.prices.compare_at_amount IS 'Optional strike-through / "was" price shown next to the effective amount.';
COMMENT ON COLUMN pricing.prices.validity IS 'Generated tstzrange of [valid_from, valid_to) backing the no-overlap exclusion constraint.';
COMMENT ON TABLE pricing.discounts IS 'Reusable discount definitions; coupons, price_rules and promotions point at these for the actual reduction.';
COMMENT ON COLUMN pricing.discounts.value IS 'Percentage (0-100) when kind=percentage, else a fixed monetary amount in currency_code.';
COMMENT ON TABLE pricing.coupons IS 'Redeemable codes granting a discount; code is unique per tenant and usage is capped by usage_limit / per_customer_limit.';
COMMENT ON COLUMN pricing.coupons.times_redeemed IS 'Denormalized running count of redemptions, capped by usage_limit.';
COMMENT ON TABLE pricing.coupon_redemptions IS 'Immutable record of each coupon use; order_id references sales.orders but its FK is added in 06_sales.sql to avoid a forward dependency.';
COMMENT ON TABLE pricing.tax_rates IS 'Effective tax rate for a (tax_category, tax_zone) pair, with an optional validity window so rate changes stay auditable.';
COMMENT ON COLUMN pricing.tax_rates.rate IS 'Fractional rate in [0,1]; e.g. 0.20000 for 20% VAT.';
COMMENT ON COLUMN pricing.tax_rates.is_inclusive IS 'True when displayed prices already include this tax (tax-inclusive pricing).';
COMMENT ON TABLE pricing.tax_zones IS 'Geographic tax regions defined at country, region or postal-zone granularity.';
COMMENT ON TABLE pricing.promotions IS 'Campaign-linked promotions; standalone by design so marketing.campaigns can reference pricing.promotions, never the reverse.';
COMMENT ON COLUMN pricing.promotions.campaign_code IS 'Free-text correlation handle to a marketing campaign; not an FK since marketing is a higher-numbered module.';
COMMENT ON TABLE pricing.promotion_products IS 'Junction restricting a promotion to specific products.';
