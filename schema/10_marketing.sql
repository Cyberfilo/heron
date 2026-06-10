-- 10_marketing.sql — campaigns, segments, A/B tests, referrals, loyalty.
-- Tenant-scoped throughout. Backward (lower-numbered) FKs used: identity.tenants,
-- identity.users, geo.currencies, sales.orders (nullable conversion attribution),
-- pricing.promotions (optional campaign promo link). loyalty_transactions is an
-- IMMUTABLE earn/burn ledger (created_at only, no updated_at, no deleted_at).
-- See CONVENTIONS.md and SCHEMA-MAP.md.

-- ===========================================================================
-- email_templates — reusable rendered email bodies referenced by campaigns and
-- per-recipient sends. Defined first so campaign_messages can FK it.
-- ===========================================================================
CREATE TABLE marketing.email_templates (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    name          text NOT NULL,
    subject       text NOT NULL,
    body_html     text,
    body_text     text,
    from_name     text,
    from_email    citext,
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT email_templates_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON marketing.email_templates (tenant_id);

-- ===========================================================================
-- segments — audience definitions. The actual selection logic lives in `rules`
-- (jsonb); segment_members materializes the current membership.
-- ===========================================================================
CREATE TABLE marketing.segments (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    name          text NOT NULL,
    description   text,
    rules         jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_dynamic    boolean NOT NULL DEFAULT true,
    member_count  integer NOT NULL DEFAULT 0 CHECK (member_count >= 0),
    last_refreshed_at timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT segments_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON marketing.segments (tenant_id);

CREATE TABLE marketing.segment_members (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    segment_id  bigint NOT NULL REFERENCES marketing.segments(id) ON DELETE CASCADE,
    user_id     bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    added_at    timestamptz NOT NULL DEFAULT now(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT segment_members_uq UNIQUE (segment_id, user_id)
);
CREATE INDEX ON marketing.segment_members (tenant_id);
CREATE INDEX ON marketing.segment_members (user_id);

-- ===========================================================================
-- landing_pages — campaign destination pages. Referenced by campaigns and
-- utm_links, so defined ahead of them.
-- ===========================================================================
CREATE TABLE marketing.landing_pages (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    slug          text NOT NULL,
    title         text NOT NULL,
    url           text,
    content_html  text,
    is_published  boolean NOT NULL DEFAULT false,
    published_at  timestamptz,
    view_count    bigint NOT NULL DEFAULT 0 CHECK (view_count >= 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT landing_pages_tenant_slug_uq UNIQUE (tenant_id, slug)
);
CREATE INDEX ON marketing.landing_pages (tenant_id);

-- ===========================================================================
-- campaigns — marketing campaigns. May optionally target a segment, render via
-- an email_template, drive to a landing_page, and link a pricing.promotion.
-- ===========================================================================
CREATE TABLE marketing.campaigns (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    name              text NOT NULL,
    description       text,
    channel           text NOT NULL DEFAULT 'email',
    status            marketing.campaign_status NOT NULL DEFAULT 'draft',
    segment_id        bigint REFERENCES marketing.segments(id) ON DELETE SET NULL,
    email_template_id bigint REFERENCES marketing.email_templates(id) ON DELETE SET NULL,
    landing_page_id   bigint REFERENCES marketing.landing_pages(id) ON DELETE SET NULL,
    promotion_id      bigint REFERENCES pricing.promotions(id) ON DELETE SET NULL,
    budget            numeric(14,4) CHECK (budget >= 0),
    currency_code     char(3) REFERENCES geo.currencies(code),
    scheduled_at      timestamptz,
    started_at        timestamptz,
    ended_at          timestamptz,
    created_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz,
    CONSTRAINT campaigns_tenant_name_uq UNIQUE (tenant_id, name),
    CONSTRAINT campaigns_window_chk CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at > started_at),
    CONSTRAINT campaigns_budget_currency_chk CHECK (budget IS NULL OR currency_code IS NOT NULL)
);
CREATE INDEX ON marketing.campaigns (tenant_id);
CREATE INDEX ON marketing.campaigns (segment_id);
CREATE INDEX ON marketing.campaigns (email_template_id);
CREATE INDEX ON marketing.campaigns (landing_page_id);
CREATE INDEX ON marketing.campaigns (promotion_id);
CREATE INDEX campaigns_active_idx ON marketing.campaigns (tenant_id, status) WHERE status IN ('scheduled','sending');

-- ===========================================================================
-- campaign_messages — one row per recipient send. send_status tracks the
-- delivery/engagement lifecycle (queued -> sent -> opened -> clicked ...).
-- ===========================================================================
CREATE TABLE marketing.campaign_messages (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    campaign_id       bigint NOT NULL REFERENCES marketing.campaigns(id) ON DELETE CASCADE,
    user_id           bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    email_template_id bigint REFERENCES marketing.email_templates(id) ON DELETE SET NULL,
    status            marketing.send_status NOT NULL DEFAULT 'queued',
    recipient_email   citext,
    sent_at           timestamptz,
    delivered_at      timestamptz,
    opened_at         timestamptz,
    clicked_at        timestamptz,
    bounced_at        timestamptz,
    unsubscribed_at   timestamptz,
    error_message     text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON marketing.campaign_messages (tenant_id);
CREATE INDEX ON marketing.campaign_messages (campaign_id);
CREATE INDEX ON marketing.campaign_messages (user_id);
CREATE INDEX ON marketing.campaign_messages (email_template_id);
CREATE INDEX campaign_messages_campaign_status_idx ON marketing.campaign_messages (campaign_id, status);

-- ===========================================================================
-- A/B testing: ab_tests -> ab_variants -> ab_assignments(user -> variant).
-- ===========================================================================
CREATE TABLE marketing.ab_tests (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    campaign_id   bigint REFERENCES marketing.campaigns(id) ON DELETE SET NULL,
    name          text NOT NULL,
    hypothesis    text,
    status        marketing.experiment_status NOT NULL DEFAULT 'draft',
    goal_metric   text,
    started_at    timestamptz,
    ended_at      timestamptz,
    winner_variant_id bigint,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT ab_tests_tenant_name_uq UNIQUE (tenant_id, name),
    CONSTRAINT ab_tests_window_chk CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at > started_at)
);
CREATE INDEX ON marketing.ab_tests (tenant_id);
CREATE INDEX ON marketing.ab_tests (campaign_id);

CREATE TABLE marketing.ab_variants (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    ab_test_id    bigint NOT NULL REFERENCES marketing.ab_tests(id) ON DELETE CASCADE,
    name          text NOT NULL,
    is_control    boolean NOT NULL DEFAULT false,
    traffic_weight numeric(5,4) NOT NULL DEFAULT 0.5 CHECK (traffic_weight >= 0 AND traffic_weight <= 1),
    config        jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ab_variants_test_name_uq UNIQUE (ab_test_id, name)
);
CREATE INDEX ON marketing.ab_variants (tenant_id);
CREATE INDEX ON marketing.ab_variants (ab_test_id);
CREATE UNIQUE INDEX ab_variants_one_control_idx ON marketing.ab_variants (ab_test_id) WHERE is_control;

-- winner_variant_id closes the loop back to ab_variants; emitted as a trailing
-- ALTER because ab_variants is defined after ab_tests (same-module forward ref).
ALTER TABLE marketing.ab_tests
    ADD CONSTRAINT ab_tests_winner_variant_fk
    FOREIGN KEY (winner_variant_id) REFERENCES marketing.ab_variants(id) ON DELETE SET NULL;
CREATE INDEX ON marketing.ab_tests (winner_variant_id);

CREATE TABLE marketing.ab_assignments (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    ab_test_id    bigint NOT NULL REFERENCES marketing.ab_tests(id) ON DELETE CASCADE,
    ab_variant_id bigint NOT NULL REFERENCES marketing.ab_variants(id) ON DELETE CASCADE,
    user_id       bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    assigned_at   timestamptz NOT NULL DEFAULT now(),
    converted_at  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ab_assignments_test_user_uq UNIQUE (ab_test_id, user_id)
);
CREATE INDEX ON marketing.ab_assignments (tenant_id);
CREATE INDEX ON marketing.ab_assignments (ab_test_id);
CREATE INDEX ON marketing.ab_assignments (ab_variant_id);
CREATE INDEX ON marketing.ab_assignments (user_id);

-- ===========================================================================
-- attributions — touch attributions linking a marketing surface to a
-- conversion. order_id is a NULLABLE backward FK to sales.orders (allowed): set
-- when the touch is credited with an order, null for non-purchase conversions.
-- ===========================================================================
CREATE TABLE marketing.attributions (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    user_id       bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    campaign_id   bigint REFERENCES marketing.campaigns(id) ON DELETE SET NULL,
    order_id      bigint REFERENCES sales.orders(id) ON DELETE SET NULL,
    model         text NOT NULL DEFAULT 'last_touch',
    touch_point   text,
    weight        numeric(5,4) NOT NULL DEFAULT 1.0 CHECK (weight >= 0 AND weight <= 1),
    attributed_revenue numeric(14,4) CHECK (attributed_revenue >= 0),
    currency_code char(3) REFERENCES geo.currencies(code),
    occurred_at   timestamptz NOT NULL DEFAULT now(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT attributions_revenue_currency_chk CHECK (attributed_revenue IS NULL OR currency_code IS NOT NULL)
);
CREATE INDEX ON marketing.attributions (tenant_id);
CREATE INDEX ON marketing.attributions (user_id);
CREATE INDEX ON marketing.attributions (campaign_id);
CREATE INDEX ON marketing.attributions (order_id);

-- ===========================================================================
-- referrals — referral codes owned by a referring user; referral_redemptions
-- record a new user redeeming a code.
-- ===========================================================================
CREATE TABLE marketing.referrals (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    referrer_user_id bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    code            text NOT NULL,
    reward_amount   numeric(14,4) CHECK (reward_amount >= 0),
    currency_code   char(3) REFERENCES geo.currencies(code),
    max_redemptions integer CHECK (max_redemptions > 0),
    redemption_count integer NOT NULL DEFAULT 0 CHECK (redemption_count >= 0),
    is_active       boolean NOT NULL DEFAULT true,
    expires_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    CONSTRAINT referrals_tenant_code_uq UNIQUE (tenant_id, code),
    CONSTRAINT referrals_reward_currency_chk CHECK (reward_amount IS NULL OR currency_code IS NOT NULL)
);
CREATE INDEX ON marketing.referrals (tenant_id);
CREATE INDEX ON marketing.referrals (referrer_user_id);

CREATE TABLE marketing.referral_redemptions (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    referral_id         bigint NOT NULL REFERENCES marketing.referrals(id) ON DELETE CASCADE,
    referred_user_id    bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    order_id            bigint REFERENCES sales.orders(id) ON DELETE SET NULL,
    reward_amount       numeric(14,4) CHECK (reward_amount >= 0),
    currency_code       char(3) REFERENCES geo.currencies(code),
    redeemed_at         timestamptz NOT NULL DEFAULT now(),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT referral_redemptions_uq UNIQUE (referral_id, referred_user_id),
    CONSTRAINT referral_redemptions_reward_currency_chk CHECK (reward_amount IS NULL OR currency_code IS NOT NULL)
);
CREATE INDEX ON marketing.referral_redemptions (tenant_id);
CREATE INDEX ON marketing.referral_redemptions (referral_id);
CREATE INDEX ON marketing.referral_redemptions (referred_user_id);
CREATE INDEX ON marketing.referral_redemptions (order_id);

-- ===========================================================================
-- Loyalty: program defs -> per-user accounts (balance) -> immutable earn/burn
-- transaction ledger.
-- ===========================================================================
CREATE TABLE marketing.loyalty_programs (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    name                text NOT NULL,
    description         text,
    points_per_currency numeric(14,4) NOT NULL DEFAULT 1 CHECK (points_per_currency >= 0),
    currency_code       char(3) NOT NULL REFERENCES geo.currencies(code),
    is_active           boolean NOT NULL DEFAULT true,
    starts_at           timestamptz,
    ends_at             timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz,
    CONSTRAINT loyalty_programs_tenant_name_uq UNIQUE (tenant_id, name),
    CONSTRAINT loyalty_programs_window_chk CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX ON marketing.loyalty_programs (tenant_id);

CREATE TABLE marketing.loyalty_accounts (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    loyalty_program_id bigint NOT NULL REFERENCES marketing.loyalty_programs(id) ON DELETE CASCADE,
    user_id           bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    points_balance    bigint NOT NULL DEFAULT 0 CHECK (points_balance >= 0),
    lifetime_points   bigint NOT NULL DEFAULT 0 CHECK (lifetime_points >= 0),
    tier              text,
    enrolled_at       timestamptz NOT NULL DEFAULT now(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT loyalty_accounts_program_user_uq UNIQUE (loyalty_program_id, user_id)
);
CREATE INDEX ON marketing.loyalty_accounts (tenant_id);
CREATE INDEX ON marketing.loyalty_accounts (loyalty_program_id);
CREATE INDEX ON marketing.loyalty_accounts (user_id);

-- IMMUTABLE ledger: append-only earn/burn rows. created_at only, no updated_at.
CREATE TABLE marketing.loyalty_transactions (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    loyalty_account_id bigint NOT NULL REFERENCES marketing.loyalty_accounts(id) ON DELETE CASCADE,
    user_id           bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    direction         text NOT NULL CHECK (direction IN ('earn','burn')),
    points            bigint NOT NULL CHECK (points > 0),
    reason            text,
    order_id          bigint REFERENCES sales.orders(id) ON DELETE SET NULL,
    balance_after     bigint CHECK (balance_after >= 0),
    occurred_at       timestamptz NOT NULL DEFAULT now(),
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON marketing.loyalty_transactions (tenant_id);
CREATE INDEX ON marketing.loyalty_transactions (loyalty_account_id);
CREATE INDEX ON marketing.loyalty_transactions (user_id);
CREATE INDEX ON marketing.loyalty_transactions (order_id);
CREATE INDEX loyalty_transactions_account_time_idx ON marketing.loyalty_transactions (loyalty_account_id, occurred_at);

-- ===========================================================================
-- utm_links — tracked short/long URLs with UTM params, optionally tied to a
-- campaign and/or landing_page.
-- ===========================================================================
CREATE TABLE marketing.utm_links (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    campaign_id     bigint REFERENCES marketing.campaigns(id) ON DELETE SET NULL,
    landing_page_id bigint REFERENCES marketing.landing_pages(id) ON DELETE SET NULL,
    slug            text NOT NULL,
    target_url      text NOT NULL,
    utm_source      text,
    utm_medium      text,
    utm_campaign    text,
    utm_term        text,
    utm_content     text,
    click_count     bigint NOT NULL DEFAULT 0 CHECK (click_count >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    CONSTRAINT utm_links_tenant_slug_uq UNIQUE (tenant_id, slug)
);
CREATE INDEX ON marketing.utm_links (tenant_id);
CREATE INDEX ON marketing.utm_links (campaign_id);
CREATE INDEX ON marketing.utm_links (landing_page_id);

-- --- comments (~70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE marketing.email_templates IS 'Reusable email subject/body templates used by campaigns and per-recipient sends.';
COMMENT ON TABLE marketing.segments IS 'Audience definitions; the selection logic lives in the rules jsonb and is materialized into segment_members.';
COMMENT ON COLUMN marketing.segments.is_dynamic IS 'True if membership is recomputed from rules on a schedule; false for static lists.';
COMMENT ON TABLE marketing.campaigns IS 'Marketing campaigns; may target a segment, render via a template, drive to a landing page, and link a pricing promotion.';
COMMENT ON TABLE marketing.campaign_messages IS 'One row per recipient send; send_status tracks the delivery and engagement lifecycle.';
COMMENT ON TABLE marketing.ab_tests IS 'A/B test definitions; winner_variant_id records the chosen variant once the experiment completes.';
COMMENT ON COLUMN marketing.ab_variants.traffic_weight IS 'Fraction of eligible traffic routed to this variant; weights across a test should sum to ~1.';
COMMENT ON TABLE marketing.ab_assignments IS 'Sticky assignment of a user to one variant within an A/B test; converted_at records goal completion.';
COMMENT ON TABLE marketing.attributions IS 'Touch attributions crediting a campaign with a conversion; order_id is set for purchase conversions.';
COMMENT ON COLUMN marketing.attributions.weight IS 'Fractional credit for this touch under the attribution model (e.g. linear, last_touch).';
COMMENT ON TABLE marketing.referrals IS 'Referral codes owned by a referring user, with optional reward and redemption caps.';
COMMENT ON TABLE marketing.loyalty_accounts IS 'Per-user point balance within a loyalty program; points_balance is the current redeemable total.';
COMMENT ON TABLE marketing.loyalty_transactions IS 'Immutable earn/burn ledger of loyalty point movements; append-only, never updated.';
COMMENT ON COLUMN marketing.loyalty_transactions.balance_after IS 'Account points_balance immediately after this entry was applied.';
COMMENT ON TABLE marketing.utm_links IS 'Tracked links carrying UTM parameters, optionally tied to a campaign and landing page.';
