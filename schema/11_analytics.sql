-- 11_analytics.sql — product analytics: the events fact table, web sessions,
-- page views, device profiles, feature usage, experiments (variants +
-- assignments), funnels (+ steps), cohorts (+ members), pre-aggregated daily
-- metrics, and KPI snapshots.
--
-- IMMUTABLE fact/log tables (events, page_views, feature_usage) carry only
-- created_at/occurred_at — no updated_at, no deleted_at. The remaining tables
-- are mutable definition/config tables with created_at/updated_at.
--
-- Cross-schema FK targets: identity.tenants(id), identity.users(id).
-- All other FKs are intra-analytics and reference lower-or-equal tables.
-- See CONVENTIONS.md and SCHEMA-MAP.md.

-- ===========================================================================
-- web_sessions — analytics sessions, DISTINCT from identity.sessions (which
-- are auth sessions). A web session groups a visitor's activity; user_id is
-- nullable because anonymous (pre-login) traffic still produces sessions.
-- ===========================================================================
CREATE TABLE analytics.web_sessions (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    user_id         bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    anonymous_id    uuid,
    started_at      timestamptz NOT NULL DEFAULT now(),
    ended_at        timestamptz,
    landing_page    text,
    referrer        text,
    utm_source      text,
    utm_medium      text,
    utm_campaign    text,
    ip_address      inet,
    user_agent      text,
    is_bounce       boolean NOT NULL DEFAULT false,
    page_view_count integer NOT NULL DEFAULT 0 CHECK (page_view_count >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT web_sessions_ended_after_started_ck CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX ON analytics.web_sessions (tenant_id);
CREATE INDEX ON analytics.web_sessions (user_id);
CREATE INDEX web_sessions_tenant_started_idx ON analytics.web_sessions (tenant_id, started_at);
CREATE INDEX web_sessions_anonymous_idx ON analytics.web_sessions (anonymous_id) WHERE anonymous_id IS NOT NULL;

-- ===========================================================================
-- events — THE big fact table (bench scale ~10M rows). Immutable: only
-- occurred_at/created_at, no updated_at/deleted_at. user_id and web_session_id
-- are nullable; user deletion sets user_id NULL rather than dropping events.
-- ===========================================================================
CREATE TABLE analytics.events (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    user_id        bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    web_session_id bigint REFERENCES analytics.web_sessions(id) ON DELETE SET NULL,
    event_name     text NOT NULL,
    properties     jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at    timestamptz NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX events_tenant_occurred_idx ON analytics.events (tenant_id, occurred_at);
CREATE INDEX events_event_name_idx ON analytics.events (event_name);
CREATE INDEX events_web_session_idx ON analytics.events (web_session_id);
CREATE INDEX events_user_idx ON analytics.events (user_id);

-- ===========================================================================
-- page_views — individual page hits within a web session. Immutable log:
-- viewed_at only, no updated_at.
-- ===========================================================================
CREATE TABLE analytics.page_views (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        bigint NOT NULL REFERENCES identity.tenants(id),
    web_session_id   bigint NOT NULL REFERENCES analytics.web_sessions(id) ON DELETE CASCADE,
    url              text NOT NULL,
    path             text,
    title            text,
    referrer         text,
    duration_seconds integer CHECK (duration_seconds >= 0),
    viewed_at        timestamptz NOT NULL DEFAULT now(),
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON analytics.page_views (tenant_id);
CREATE INDEX ON analytics.page_views (web_session_id);
CREATE INDEX page_views_tenant_viewed_idx ON analytics.page_views (tenant_id, viewed_at);

-- ===========================================================================
-- device_profiles — browser/device fingerprints observed per tenant. A
-- profile may be linked to a user once they authenticate.
-- ===========================================================================
CREATE TABLE analytics.device_profiles (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    user_id         bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    fingerprint     text NOT NULL,
    device_type     text,
    os              text,
    os_version      text,
    browser         text,
    browser_version text,
    screen_width    integer CHECK (screen_width >= 0),
    screen_height   integer CHECK (screen_height >= 0),
    first_seen_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT device_profiles_tenant_fingerprint_uq UNIQUE (tenant_id, fingerprint)
);
CREATE INDEX ON analytics.device_profiles (tenant_id);
CREATE INDEX ON analytics.device_profiles (user_id);

-- ===========================================================================
-- feature_usage — per-user product-feature adoption counters. Aggregated
-- usage rolled up per (user, feature, day); immutable counter snapshot row.
-- ===========================================================================
CREATE TABLE analytics.feature_usage (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    user_id      bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    feature_key  text NOT NULL,
    usage_count  integer NOT NULL DEFAULT 0 CHECK (usage_count >= 0),
    usage_day    date NOT NULL,
    last_used_at timestamptz,
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT feature_usage_uq UNIQUE (tenant_id, user_id, feature_key, usage_day)
);
CREATE INDEX ON analytics.feature_usage (tenant_id);
CREATE INDEX ON analytics.feature_usage (user_id);
CREATE INDEX feature_usage_feature_day_idx ON analytics.feature_usage (tenant_id, feature_key, usage_day);

-- ===========================================================================
-- experiments — product experiments (server-side / feature experiments,
-- distinct from marketing.ab_tests). status reuses marketing.experiment_status.
-- ===========================================================================
CREATE TABLE analytics.experiments (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    key             text NOT NULL,
    name            text NOT NULL,
    description     text,
    hypothesis      text,
    status          marketing.experiment_status NOT NULL DEFAULT 'draft',
    primary_metric  text,
    starts_at       timestamptz,
    ends_at         timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    CONSTRAINT experiments_tenant_key_uq UNIQUE (tenant_id, key),
    CONSTRAINT experiments_window_ck CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX ON analytics.experiments (tenant_id);

CREATE TABLE analytics.experiment_variants (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    experiment_id  bigint NOT NULL REFERENCES analytics.experiments(id) ON DELETE CASCADE,
    key            text NOT NULL,
    name           text NOT NULL,
    is_control     boolean NOT NULL DEFAULT false,
    allocation_pct numeric(5,2) NOT NULL DEFAULT 0 CHECK (allocation_pct >= 0 AND allocation_pct <= 100),
    config         jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT experiment_variants_key_uq UNIQUE (experiment_id, key)
);
CREATE INDEX ON analytics.experiment_variants (tenant_id);
CREATE INDEX ON analytics.experiment_variants (experiment_id);
CREATE UNIQUE INDEX experiment_variants_one_control_idx
    ON analytics.experiment_variants (experiment_id) WHERE is_control;

CREATE TABLE analytics.experiment_assignments (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    experiment_id bigint NOT NULL REFERENCES analytics.experiments(id) ON DELETE CASCADE,
    variant_id    bigint NOT NULL REFERENCES analytics.experiment_variants(id) ON DELETE CASCADE,
    user_id       bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    anonymous_id  uuid,
    assigned_at   timestamptz NOT NULL DEFAULT now(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT experiment_assignments_user_uq UNIQUE (experiment_id, user_id)
);
CREATE INDEX ON analytics.experiment_assignments (tenant_id);
CREATE INDEX ON analytics.experiment_assignments (experiment_id);
CREATE INDEX ON analytics.experiment_assignments (variant_id);
CREATE INDEX ON analytics.experiment_assignments (user_id);

-- ===========================================================================
-- funnels — ordered conversion-funnel definitions and their steps.
-- ===========================================================================
CREATE TABLE analytics.funnels (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    name        text NOT NULL,
    description text,
    is_active   boolean NOT NULL DEFAULT true,
    window_days integer CHECK (window_days > 0),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,
    CONSTRAINT funnels_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON analytics.funnels (tenant_id);

CREATE TABLE analytics.funnel_steps (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    funnel_id   bigint NOT NULL REFERENCES analytics.funnels(id) ON DELETE CASCADE,
    step_order  integer NOT NULL CHECK (step_order >= 0),
    name        text NOT NULL,
    event_name  text NOT NULL,
    filters     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT funnel_steps_order_uq UNIQUE (funnel_id, step_order)
);
CREATE INDEX ON analytics.funnel_steps (tenant_id);
CREATE INDEX ON analytics.funnel_steps (funnel_id);

-- ===========================================================================
-- cohorts — named user cohorts and their materialized membership.
-- ===========================================================================
CREATE TABLE analytics.cohorts (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    name         text NOT NULL,
    description  text,
    definition   jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_dynamic   boolean NOT NULL DEFAULT true,
    member_count integer NOT NULL DEFAULT 0 CHECK (member_count >= 0),
    computed_at  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz,
    CONSTRAINT cohorts_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON analytics.cohorts (tenant_id);

CREATE TABLE analytics.cohort_members (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  bigint NOT NULL REFERENCES identity.tenants(id),
    cohort_id  bigint NOT NULL REFERENCES analytics.cohorts(id) ON DELETE CASCADE,
    user_id    bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    added_at   timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT cohort_members_uq UNIQUE (cohort_id, user_id)
);
CREATE INDEX ON analytics.cohort_members (tenant_id);
CREATE INDEX ON analytics.cohort_members (cohort_id);
CREATE INDEX ON analytics.cohort_members (user_id);

-- ===========================================================================
-- metrics_daily — pre-aggregated daily metric values per tenant. One row per
-- (tenant, metric_key, day). dimensions holds optional breakdown labels.
-- ===========================================================================
CREATE TABLE analytics.metrics_daily (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    metric_key  text NOT NULL,
    day         date NOT NULL,
    value       numeric(20,6) NOT NULL DEFAULT 0,
    dimensions  jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT metrics_daily_uq UNIQUE (tenant_id, metric_key, day)
);
CREATE INDEX ON analytics.metrics_daily (tenant_id);
CREATE INDEX metrics_daily_key_day_idx ON analytics.metrics_daily (tenant_id, metric_key, day);

-- ===========================================================================
-- kpi_snapshots — periodic captures of headline KPIs (MRR, active users,
-- conversion rate, ...) for trend dashboards.
-- ===========================================================================
CREATE TABLE analytics.kpi_snapshots (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    kpi_key       text NOT NULL,
    period        text NOT NULL DEFAULT 'daily',
    period_start  date NOT NULL,
    period_end    date NOT NULL,
    value         numeric(20,6) NOT NULL DEFAULT 0,
    previous_value numeric(20,6),
    metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
    captured_at   timestamptz NOT NULL DEFAULT now(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT kpi_snapshots_uq UNIQUE (tenant_id, kpi_key, period, period_start),
    CONSTRAINT kpi_snapshots_period_ck CHECK (period_end >= period_start)
);
CREATE INDEX ON analytics.kpi_snapshots (tenant_id);
CREATE INDEX kpi_snapshots_key_period_idx ON analytics.kpi_snapshots (tenant_id, kpi_key, period_start);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE analytics.events IS 'The primary product analytics fact table (~10M rows at bench scale). Each row is one tracked event with a free-form event_name and schemaless jsonb properties.';
COMMENT ON COLUMN analytics.events.web_session_id IS 'Nullable link to the analytics web session this event occurred in; server-side events may have none.';
COMMENT ON TABLE analytics.web_sessions IS 'Visitor analytics sessions, distinct from identity.sessions (auth). Anonymous traffic still produces a session with a null user_id.';
COMMENT ON COLUMN analytics.web_sessions.anonymous_id IS 'Client-generated visitor identifier used to stitch sessions before the user authenticates.';
COMMENT ON TABLE analytics.page_views IS 'Individual page hits within a web session, used for path and dwell-time analysis.';
COMMENT ON TABLE analytics.device_profiles IS 'Browser/device fingerprints observed per tenant, optionally linked to a user once authenticated.';
COMMENT ON TABLE analytics.feature_usage IS 'Per-user, per-day product feature adoption counters feeding engagement and stickiness metrics.';
COMMENT ON COLUMN analytics.feature_usage.feature_key IS 'Stable identifier of the product feature being measured (e.g. bulk_export, dashboard_share).';
COMMENT ON TABLE analytics.experiments IS 'Server-side product experiments (feature experiments), distinct from marketing.ab_tests which are message-level tests.';
COMMENT ON TABLE analytics.experiment_variants IS 'Variants (arms) of an experiment; exactly one may be flagged is_control, with allocation_pct summing across arms.';
COMMENT ON TABLE analytics.experiment_assignments IS 'Records which variant a user (or anonymous visitor) was bucketed into for an experiment.';
COMMENT ON TABLE analytics.funnels IS 'Ordered conversion-funnel definitions evaluated over the events stream.';
COMMENT ON TABLE analytics.cohorts IS 'Named user cohorts, dynamic (rule-based) or static, used for retention and segmentation analysis.';
COMMENT ON TABLE analytics.metrics_daily IS 'Pre-aggregated daily metric values per tenant; one row per (tenant, metric_key, day) for fast dashboard reads.';
COMMENT ON COLUMN analytics.metrics_daily.dimensions IS 'Optional breakdown labels (e.g. {"channel":"organic"}) when a metric is sliced; empty object for the headline total.';
COMMENT ON TABLE analytics.kpi_snapshots IS 'Periodic captures of headline KPIs (MRR, active users, conversion rate) with the prior-period value for trend deltas.';
