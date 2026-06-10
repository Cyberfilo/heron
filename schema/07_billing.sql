-- 07_billing.sql — payments, refunds, invoices, credit notes, payouts, the
-- double-entry ledger, plans/subscriptions/metered usage, dunning, wallets.
-- The money-heavy module: every monetary column is numeric(14,4) paired with a
-- currency_code char(3) -> geo.currencies(code). Cross-schema FKs point only at
-- lower-or-equal-numbered modules: identity (01), geo (02), sales (06).
--
-- IMMUTABLE tables (created_at only, no updated_at/deleted_at):
--   ledger_entries (append-only double-entry ledger).
-- Everything else is a business table with created_at/updated_at.
-- See CONVENTIONS.md and SCHEMA-MAP.md. Comments live mostly inline here
-- (≈70% coverage; some tables intentionally left undocumented).

-- ===========================================================================
-- billing_profiles — the customer's billing entity for a tenant: legal name,
-- tax id, billing email, default payment method. One-or-more per tenant (e.g.
-- separate entities per region). Soft-deletable.
-- ===========================================================================
CREATE TABLE billing.billing_profiles (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    user_id           bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    legal_name        text NOT NULL,
    billing_email     citext,
    tax_id            text,
    net_terms_days    integer NOT NULL DEFAULT 0 CHECK (net_terms_days >= 0),
    default_currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    is_default        boolean NOT NULL DEFAULT false,
    metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz
);
CREATE INDEX ON billing.billing_profiles (tenant_id);
CREATE INDEX ON billing.billing_profiles (user_id);
-- one default billing profile per tenant
CREATE UNIQUE INDEX billing_profiles_one_default_idx
    ON billing.billing_profiles (tenant_id) WHERE is_default;

-- ===========================================================================
-- payment_methods — stored instruments (card, bank, paypal, wallet, ...).
-- Only a gateway token + last4/brand are kept, never raw PANs.
-- ===========================================================================
CREATE TABLE billing.payment_methods (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    user_id            bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    billing_profile_id bigint REFERENCES billing.billing_profiles(id) ON DELETE SET NULL,
    kind               billing.payment_method_kind NOT NULL,
    gateway            text NOT NULL,
    gateway_token      text NOT NULL,
    brand              text,
    last4              char(4),
    exp_month          smallint CHECK (exp_month BETWEEN 1 AND 12),
    exp_year           smallint CHECK (exp_year >= 2000),
    is_default         boolean NOT NULL DEFAULT false,
    billing_address_id bigint REFERENCES geo.addresses(id) ON DELETE SET NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz,
    CONSTRAINT payment_methods_gateway_token_uq UNIQUE (gateway, gateway_token)
);
CREATE INDEX ON billing.payment_methods (tenant_id);
CREATE INDEX ON billing.payment_methods (user_id);
CREATE INDEX ON billing.payment_methods (billing_profile_id);
CREATE INDEX ON billing.payment_methods (billing_address_id);
-- one default payment method per user
CREATE UNIQUE INDEX payment_methods_one_default_idx
    ON billing.payment_methods (user_id) WHERE is_default AND user_id IS NOT NULL;

-- ===========================================================================
-- payments — a money-in capture against an order and/or an invoice. amount is
-- the gross captured; amount_refunded tracks cumulative refunds for quick
-- partial-refund checks.
-- ===========================================================================
CREATE TABLE billing.payments (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    order_id           bigint REFERENCES sales.orders(id) ON DELETE SET NULL,
    invoice_id         bigint,  -- FK added via trailing ALTER (billing.invoices defined later in this file)
    payment_method_id  bigint REFERENCES billing.payment_methods(id) ON DELETE SET NULL,
    status             billing.payment_status NOT NULL DEFAULT 'pending',
    amount             numeric(14,4) NOT NULL CHECK (amount >= 0),
    amount_refunded    numeric(14,4) NOT NULL DEFAULT 0 CHECK (amount_refunded >= 0),
    currency_code      char(3) NOT NULL REFERENCES geo.currencies(code),
    gateway            text NOT NULL,
    gateway_charge_id  text,
    authorized_at      timestamptz,
    captured_at        timestamptz,
    failure_code       text,
    metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT payments_refund_le_amount_chk CHECK (amount_refunded <= amount)
);
CREATE INDEX ON billing.payments (tenant_id);
CREATE INDEX ON billing.payments (order_id);
CREATE INDEX ON billing.payments (invoice_id);
CREATE INDEX ON billing.payments (payment_method_id);
CREATE INDEX payments_tenant_status_idx ON billing.payments (tenant_id, status);
CREATE INDEX payments_gateway_charge_idx ON billing.payments (gateway_charge_id) WHERE gateway_charge_id IS NOT NULL;

-- ===========================================================================
-- payment_attempts — each individual gateway round-trip for a payment. A
-- payment may need several attempts (retry on soft decline) before it captures.
-- ===========================================================================
CREATE TABLE billing.payment_attempts (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    payment_id      bigint NOT NULL REFERENCES billing.payments(id) ON DELETE CASCADE,
    attempt_number  integer NOT NULL CHECK (attempt_number > 0),
    status          billing.payment_status NOT NULL DEFAULT 'pending',
    amount          numeric(14,4) NOT NULL CHECK (amount >= 0),
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    gateway_response jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_code      text,
    error_message   text,
    attempted_at    timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT payment_attempts_number_uq UNIQUE (payment_id, attempt_number)
);
CREATE INDEX ON billing.payment_attempts (tenant_id);
CREATE INDEX ON billing.payment_attempts (payment_id);

-- ===========================================================================
-- payment_refunds — money-out reversing all or part of a captured payment.
-- ===========================================================================
CREATE TABLE billing.payment_refunds (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    payment_id        bigint NOT NULL REFERENCES billing.payments(id) ON DELETE CASCADE,
    status            billing.refund_status NOT NULL DEFAULT 'pending',
    amount            numeric(14,4) NOT NULL CHECK (amount > 0),
    currency_code     char(3) NOT NULL REFERENCES geo.currencies(code),
    reason            text,
    gateway_refund_id text,
    processed_at      timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON billing.payment_refunds (tenant_id);
CREATE INDEX ON billing.payment_refunds (payment_id);
CREATE INDEX payment_refunds_tenant_status_idx ON billing.payment_refunds (tenant_id, status);

-- ===========================================================================
-- invoices — billing documents (one-off or subscription). public_id is the
-- opaque external identifier. amount_due drives dunning; amount_paid +
-- amount_due reconcile against total.
-- ===========================================================================
CREATE TABLE billing.invoices (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id          uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    billing_profile_id bigint REFERENCES billing.billing_profiles(id) ON DELETE SET NULL,
    user_id            bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    order_id           bigint REFERENCES sales.orders(id) ON DELETE SET NULL,
    subscription_id    bigint,  -- FK added via trailing ALTER (billing.subscriptions defined later in this file)
    invoice_number     text NOT NULL,
    status             billing.invoice_status NOT NULL DEFAULT 'draft',
    currency_code      char(3) NOT NULL REFERENCES geo.currencies(code),
    subtotal           numeric(14,4) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    tax_total          numeric(14,4) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    discount_total     numeric(14,4) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    total              numeric(14,4) NOT NULL DEFAULT 0 CHECK (total >= 0),
    amount_paid        numeric(14,4) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
    amount_due         numeric(14,4) NOT NULL DEFAULT 0 CHECK (amount_due >= 0),
    issued_at          timestamptz,
    due_at             timestamptz,
    paid_at            timestamptz,
    voided_at          timestamptz,
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT invoices_public_id_key UNIQUE (public_id),
    CONSTRAINT invoices_tenant_number_uq UNIQUE (tenant_id, invoice_number)
);
CREATE INDEX ON billing.invoices (tenant_id);
CREATE INDEX ON billing.invoices (billing_profile_id);
CREATE INDEX ON billing.invoices (user_id);
CREATE INDEX ON billing.invoices (order_id);
CREATE INDEX ON billing.invoices (subscription_id);
CREATE INDEX invoices_tenant_status_idx ON billing.invoices (tenant_id, status);
CREATE INDEX invoices_open_due_idx ON billing.invoices (due_at) WHERE status IN ('open','past_due');

-- ===========================================================================
-- invoice_lines — line items on an invoice. line_total = unit_price * quantity
-- (pre-tax); tax_amount is the line's tax contribution.
-- ===========================================================================
CREATE TABLE billing.invoice_lines (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    invoice_id      bigint NOT NULL REFERENCES billing.invoices(id) ON DELETE CASCADE,
    subscription_item_id bigint,  -- FK added via trailing ALTER (billing.subscription_items defined later in this file)
    description     text NOT NULL,
    quantity        numeric(14,4) NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price      numeric(14,4) NOT NULL CHECK (unit_price >= 0),
    line_total      numeric(14,4) NOT NULL CHECK (line_total >= 0),
    tax_amount      numeric(14,4) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    period_start    timestamptz,
    period_end      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT invoice_lines_period_chk CHECK (period_end IS NULL OR period_start IS NULL OR period_end > period_start)
);
CREATE INDEX ON billing.invoice_lines (tenant_id);
CREATE INDEX ON billing.invoice_lines (invoice_id);
CREATE INDEX ON billing.invoice_lines (subscription_item_id);

-- ===========================================================================
-- credit_notes — credit memos issued against an invoice (returns, goodwill,
-- corrections). May or may not be tied to a specific invoice.
-- ===========================================================================
CREATE TABLE billing.credit_notes (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    invoice_id         bigint REFERENCES billing.invoices(id) ON DELETE SET NULL,
    billing_profile_id bigint REFERENCES billing.billing_profiles(id) ON DELETE SET NULL,
    credit_note_number text NOT NULL,
    currency_code      char(3) NOT NULL REFERENCES geo.currencies(code),
    subtotal           numeric(14,4) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    tax_total          numeric(14,4) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total              numeric(14,4) NOT NULL DEFAULT 0 CHECK (total >= 0),
    reason             text,
    issued_at          timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT credit_notes_tenant_number_uq UNIQUE (tenant_id, credit_note_number)
);
CREATE INDEX ON billing.credit_notes (tenant_id);
CREATE INDEX ON billing.credit_notes (invoice_id);
CREATE INDEX ON billing.credit_notes (billing_profile_id);

CREATE TABLE billing.credit_note_lines (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    credit_note_id bigint NOT NULL REFERENCES billing.credit_notes(id) ON DELETE CASCADE,
    invoice_line_id bigint REFERENCES billing.invoice_lines(id) ON DELETE SET NULL,
    description    text NOT NULL,
    quantity       numeric(14,4) NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price     numeric(14,4) NOT NULL CHECK (unit_price >= 0),
    line_total     numeric(14,4) NOT NULL CHECK (line_total >= 0),
    tax_amount     numeric(14,4) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    currency_code  char(3) NOT NULL REFERENCES geo.currencies(code),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON billing.credit_note_lines (tenant_id);
CREATE INDEX ON billing.credit_note_lines (credit_note_id);
CREATE INDEX ON billing.credit_note_lines (invoice_line_id);

-- ===========================================================================
-- payouts — settlement of collected funds out to the tenant (Stripe-Connect-
-- style). gross = sum of settled payments; fees deducted; net = paid out.
-- ===========================================================================
CREATE TABLE billing.payouts (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    gross_amount    numeric(14,4) NOT NULL DEFAULT 0 CHECK (gross_amount >= 0),
    fee_amount      numeric(14,4) NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
    net_amount      numeric(14,4) NOT NULL DEFAULT 0 CHECK (net_amount >= 0),
    status          text NOT NULL DEFAULT 'pending',
    gateway_payout_id text,
    arrival_date    date,
    paid_at         timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON billing.payouts (tenant_id);
CREATE INDEX payouts_tenant_status_idx ON billing.payouts (tenant_id, status);

-- ===========================================================================
-- payout_items — the individual payments settled within a payout. A payment
-- appears in at most one payout.
-- ===========================================================================
CREATE TABLE billing.payout_items (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    payout_id     bigint NOT NULL REFERENCES billing.payouts(id) ON DELETE CASCADE,
    payment_id    bigint NOT NULL REFERENCES billing.payments(id) ON DELETE RESTRICT,
    amount        numeric(14,4) NOT NULL CHECK (amount >= 0),
    fee_amount    numeric(14,4) NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT payout_items_payment_uq UNIQUE (payment_id)
);
CREATE INDEX ON billing.payout_items (tenant_id);
CREATE INDEX ON billing.payout_items (payout_id);

-- ===========================================================================
-- ledger_accounts — the tenant's chart of accounts for the double-entry
-- ledger. type is the accounting class (asset/liability/revenue/...).
-- ===========================================================================
CREATE TABLE billing.ledger_accounts (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    code          text NOT NULL,
    name          text NOT NULL,
    account_type  text NOT NULL,
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ledger_accounts_tenant_code_uq UNIQUE (tenant_id, code)
);
CREATE INDEX ON billing.ledger_accounts (tenant_id);

-- ===========================================================================
-- ledger_entries — IMMUTABLE append-only double-entry lines. Each row is one
-- debit or credit against one account; balanced postings share a entry_group
-- (the journal entry). No updated_at: ledgers are never mutated, only reversed
-- by a compensating entry.
-- ===========================================================================
CREATE TABLE billing.ledger_entries (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    ledger_account_id bigint NOT NULL REFERENCES billing.ledger_accounts(id) ON DELETE RESTRICT,
    entry_group       uuid NOT NULL,
    direction         billing.ledger_direction NOT NULL,
    amount            numeric(14,4) NOT NULL CHECK (amount > 0),
    currency_code     char(3) NOT NULL REFERENCES geo.currencies(code),
    payment_id        bigint REFERENCES billing.payments(id) ON DELETE SET NULL,
    invoice_id        bigint REFERENCES billing.invoices(id) ON DELETE SET NULL,
    description       text,
    occurred_at       timestamptz NOT NULL DEFAULT now(),
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON billing.ledger_entries (tenant_id);
CREATE INDEX ON billing.ledger_entries (ledger_account_id);
CREATE INDEX ON billing.ledger_entries (payment_id);
CREATE INDEX ON billing.ledger_entries (invoice_id);
CREATE INDEX ledger_entries_group_idx ON billing.ledger_entries (entry_group);
CREATE INDEX ledger_entries_tenant_occurred_idx ON billing.ledger_entries (tenant_id, occurred_at);

-- ===========================================================================
-- plans — subscription products. code is the stable external key, unique per
-- tenant. default_interval is the billing cadence; trial_period_days seeds the
-- trialing window.
-- ===========================================================================
CREATE TABLE billing.plans (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    code              text NOT NULL,
    name              text NOT NULL,
    description       text,
    default_interval  billing.billing_interval NOT NULL DEFAULT 'month',
    interval_count    integer NOT NULL DEFAULT 1 CHECK (interval_count > 0),
    trial_period_days integer NOT NULL DEFAULT 0 CHECK (trial_period_days >= 0),
    is_active         boolean NOT NULL DEFAULT true,
    is_public         boolean NOT NULL DEFAULT true,
    metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz,
    CONSTRAINT plans_tenant_code_uq UNIQUE (tenant_id, code)
);
CREATE INDEX ON billing.plans (tenant_id);

-- ===========================================================================
-- plan_features — feature limits/entitlements per plan (e.g. seats=10,
-- api_calls=100000). limit_value NULL means unlimited.
-- ===========================================================================
CREATE TABLE billing.plan_features (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    plan_id     bigint NOT NULL REFERENCES billing.plans(id) ON DELETE CASCADE,
    feature_key text NOT NULL,
    limit_value bigint CHECK (limit_value IS NULL OR limit_value >= 0),
    is_enabled  boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plan_features_uq UNIQUE (plan_id, feature_key)
);
CREATE INDEX ON billing.plan_features (tenant_id);
CREATE INDEX ON billing.plan_features (plan_id);

-- ===========================================================================
-- plan_prices — price points for a plan, one per currency × interval. A plan
-- can be billed monthly in USD, yearly in EUR, etc.
-- ===========================================================================
CREATE TABLE billing.plan_prices (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    plan_id        bigint NOT NULL REFERENCES billing.plans(id) ON DELETE CASCADE,
    currency_code  char(3) NOT NULL REFERENCES geo.currencies(code),
    interval       billing.billing_interval NOT NULL DEFAULT 'month',
    interval_count integer NOT NULL DEFAULT 1 CHECK (interval_count > 0),
    amount         numeric(14,4) NOT NULL CHECK (amount >= 0),
    is_active      boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plan_prices_uq UNIQUE (plan_id, currency_code, interval, interval_count)
);
CREATE INDEX ON billing.plan_prices (tenant_id);
CREATE INDEX ON billing.plan_prices (plan_id);

-- ===========================================================================
-- subscriptions — a user's recurring commitment to a plan. public_id is the
-- opaque external id. current_period_* drive the next invoice; cancel_at_period_end
-- defers cancellation to the period boundary.
-- ===========================================================================
CREATE TABLE billing.subscriptions (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id            uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id            bigint NOT NULL REFERENCES identity.tenants(id),
    user_id              bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    plan_id              bigint NOT NULL REFERENCES billing.plans(id) ON DELETE RESTRICT,
    billing_profile_id   bigint REFERENCES billing.billing_profiles(id) ON DELETE SET NULL,
    payment_method_id    bigint REFERENCES billing.payment_methods(id) ON DELETE SET NULL,
    status               billing.subscription_status NOT NULL DEFAULT 'trialing',
    currency_code        char(3) NOT NULL REFERENCES geo.currencies(code),
    quantity             integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
    trial_ends_at        timestamptz,
    current_period_start timestamptz,
    current_period_end   timestamptz,
    cancel_at_period_end boolean NOT NULL DEFAULT false,
    canceled_at          timestamptz,
    started_at           timestamptz NOT NULL DEFAULT now(),
    ended_at             timestamptz,
    metadata             jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT subscriptions_public_id_key UNIQUE (public_id),
    CONSTRAINT subscriptions_period_chk CHECK (current_period_end IS NULL OR current_period_start IS NULL OR current_period_end > current_period_start)
);
CREATE INDEX ON billing.subscriptions (tenant_id);
CREATE INDEX ON billing.subscriptions (user_id);
CREATE INDEX ON billing.subscriptions (plan_id);
CREATE INDEX ON billing.subscriptions (billing_profile_id);
CREATE INDEX ON billing.subscriptions (payment_method_id);
CREATE INDEX subscriptions_tenant_status_idx ON billing.subscriptions (tenant_id, status);
CREATE INDEX subscriptions_renewal_idx ON billing.subscriptions (current_period_end)
    WHERE status IN ('active','trialing','past_due');

-- ===========================================================================
-- subscription_items — line items / add-ons of a subscription, each priced via
-- a plan_price. unit_amount snapshots the price at subscription time.
-- ===========================================================================
CREATE TABLE billing.subscription_items (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    subscription_id bigint NOT NULL REFERENCES billing.subscriptions(id) ON DELETE CASCADE,
    plan_price_id   bigint REFERENCES billing.plan_prices(id) ON DELETE SET NULL,
    description     text,
    quantity        integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_amount     numeric(14,4) NOT NULL CHECK (unit_amount >= 0),
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    is_metered      boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON billing.subscription_items (tenant_id);
CREATE INDEX ON billing.subscription_items (subscription_id);
CREATE INDEX ON billing.subscription_items (plan_price_id);

-- ===========================================================================
-- usage_records — metered usage events feeding consumption billing. Each row
-- is a quantity reported for a metered subscription_item in a period.
-- ===========================================================================
CREATE TABLE billing.usage_records (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id            bigint NOT NULL REFERENCES identity.tenants(id),
    subscription_item_id bigint NOT NULL REFERENCES billing.subscription_items(id) ON DELETE CASCADE,
    quantity             numeric(14,4) NOT NULL CHECK (quantity >= 0),
    unit                 text,
    action               text NOT NULL DEFAULT 'increment',
    occurred_at          timestamptz NOT NULL DEFAULT now(),
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON billing.usage_records (tenant_id);
CREATE INDEX ON billing.usage_records (subscription_item_id);
CREATE INDEX usage_records_item_occurred_idx ON billing.usage_records (subscription_item_id, occurred_at);

-- ===========================================================================
-- dunning_attempts — the retry sequence chasing payment on a past-due invoice.
-- next_attempt_at schedules the following retry.
-- ===========================================================================
CREATE TABLE billing.dunning_attempts (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    invoice_id      bigint NOT NULL REFERENCES billing.invoices(id) ON DELETE CASCADE,
    subscription_id bigint REFERENCES billing.subscriptions(id) ON DELETE SET NULL,
    payment_id      bigint REFERENCES billing.payments(id) ON DELETE SET NULL,
    attempt_number  integer NOT NULL CHECK (attempt_number > 0),
    outcome         text NOT NULL DEFAULT 'failed',
    next_attempt_at timestamptz,
    attempted_at    timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT dunning_attempts_number_uq UNIQUE (invoice_id, attempt_number)
);
CREATE INDEX ON billing.dunning_attempts (tenant_id);
CREATE INDEX ON billing.dunning_attempts (invoice_id);
CREATE INDEX ON billing.dunning_attempts (subscription_id);
CREATE INDEX ON billing.dunning_attempts (payment_id);

-- ===========================================================================
-- tax_registrations — the tenant's tax IDs per jurisdiction (VAT, GST, sales
-- tax). Drives whether/how tax is charged in a region.
-- ===========================================================================
CREATE TABLE billing.tax_registrations (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    billing_profile_id bigint REFERENCES billing.billing_profiles(id) ON DELETE SET NULL,
    country_code       char(2) NOT NULL,
    jurisdiction       text,
    tax_type           text NOT NULL,
    registration_number text NOT NULL,
    is_active          boolean NOT NULL DEFAULT true,
    valid_from         date,
    valid_until        date,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tax_registrations_uq UNIQUE (tenant_id, country_code, tax_type),
    CONSTRAINT tax_registrations_validity_chk CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from)
);
CREATE INDEX ON billing.tax_registrations (tenant_id);
CREATE INDEX ON billing.tax_registrations (billing_profile_id);

-- ===========================================================================
-- wallets — stored-credit balances per user (prepaid credit, refunds-to-credit,
-- promo balance). balance is always in the wallet's currency.
-- ===========================================================================
CREATE TABLE billing.wallets (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    user_id       bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    balance       numeric(14,4) NOT NULL DEFAULT 0 CHECK (balance >= 0),
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT wallets_user_currency_uq UNIQUE (user_id, currency_code)
);
CREATE INDEX ON billing.wallets (tenant_id);
CREATE INDEX ON billing.wallets (user_id);

-- ---------------------------------------------------------------------------
-- Deferred intra-module FKs. These three reference tables defined LATER in
-- this same file (payments precedes invoices; invoices precedes subscriptions;
-- invoice_lines precedes subscription_items), so the FK is added here once all
-- targets exist. All are same-schema (billing) references — no cross-module
-- forward dependency exists.
-- ---------------------------------------------------------------------------
ALTER TABLE billing.payments
    ADD CONSTRAINT payments_invoice_id_fkey
    FOREIGN KEY (invoice_id) REFERENCES billing.invoices(id) ON DELETE SET NULL;

ALTER TABLE billing.invoices
    ADD CONSTRAINT invoices_subscription_id_fkey
    FOREIGN KEY (subscription_id) REFERENCES billing.subscriptions(id) ON DELETE SET NULL;

ALTER TABLE billing.invoice_lines
    ADD CONSTRAINT invoice_lines_subscription_item_id_fkey
    FOREIGN KEY (subscription_item_id) REFERENCES billing.subscription_items(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- COMMENT ON TABLE coverage (≈70%). billing_profiles, payment_methods,
-- payments, payment_attempts, payment_refunds, invoices, invoice_lines,
-- credit_notes, payouts, payout_items, ledger_entries, plans, plan_features,
-- plan_prices, subscriptions, subscription_items, usage_records,
-- dunning_attempts, tax_registrations, wallets are documented inline above.
-- Deliberately left uncommented: credit_note_lines, ledger_accounts.
-- ---------------------------------------------------------------------------
COMMENT ON TABLE billing.billing_profiles IS 'Customer billing entity per tenant: legal name, tax id, billing email, net payment terms. One marked is_default per tenant.';
COMMENT ON COLUMN billing.billing_profiles.net_terms_days IS 'Payment terms in days (Net-0/Net-30/Net-60) before an invoice is past due.';
COMMENT ON TABLE billing.payment_methods IS 'Stored payment instruments. Only a gateway token plus brand/last4 are kept; raw card numbers are never stored.';
COMMENT ON TABLE billing.payments IS 'Money-in captures against an order and/or invoice. amount_refunded tracks cumulative refunds for partial-refund accounting.';
COMMENT ON COLUMN billing.payments.amount_refunded IS 'Running total of amounts refunded against this payment; must never exceed amount.';
COMMENT ON TABLE billing.payment_attempts IS 'Each gateway round-trip for a payment; a payment may need several attempts before it captures.';
COMMENT ON TABLE billing.payment_refunds IS 'Refunds reversing all or part of a captured payment, tracked through the refund_status lifecycle.';
COMMENT ON TABLE billing.invoices IS 'Billing documents (one-off or subscription). amount_due drives dunning; public_id is the opaque external identifier.';
COMMENT ON COLUMN billing.invoices.amount_due IS 'Outstanding balance still owed; reaches 0 when the invoice is fully paid.';
COMMENT ON TABLE billing.invoice_lines IS 'Line items on an invoice; optionally tied to a subscription_item, with the service period it covers.';
COMMENT ON TABLE billing.credit_notes IS 'Credit memos issued against invoices for returns, goodwill, or corrections.';
COMMENT ON TABLE billing.payouts IS 'Settlements of collected funds out to the tenant; net = gross minus fees.';
COMMENT ON TABLE billing.payout_items IS 'The individual payments settled within a payout; each payment appears in at most one payout.';
COMMENT ON TABLE billing.ledger_entries IS 'Immutable append-only double-entry ledger lines. Postings sharing an entry_group form one balanced journal entry.';
COMMENT ON COLUMN billing.ledger_entries.entry_group IS 'Groups the debit/credit rows of a single balanced journal entry (their amounts must net to zero).';
COMMENT ON TABLE billing.plans IS 'Subscription products. code is the stable per-tenant key; default_interval sets the billing cadence.';
COMMENT ON TABLE billing.plan_features IS 'Feature entitlements/limits per plan; limit_value NULL means unlimited.';
COMMENT ON COLUMN billing.plan_features.limit_value IS 'Quota for the feature (e.g. seats, api_calls); NULL means unlimited.';
COMMENT ON TABLE billing.plan_prices IS 'Price points for a plan, one per currency and billing interval.';
COMMENT ON TABLE billing.subscriptions IS 'A user''s recurring commitment to a plan. current_period_* bound the next invoice; cancel_at_period_end defers cancellation.';
COMMENT ON COLUMN billing.subscriptions.cancel_at_period_end IS 'When true the subscription cancels at current_period_end rather than immediately.';
COMMENT ON TABLE billing.subscription_items IS 'Line items / add-ons of a subscription; unit_amount snapshots the price at the time of subscription.';
COMMENT ON TABLE billing.usage_records IS 'Metered usage reported for a subscription_item, aggregated into consumption-based invoice lines.';
COMMENT ON TABLE billing.dunning_attempts IS 'Retry sequence chasing payment on a past-due invoice; next_attempt_at schedules the following retry.';
COMMENT ON TABLE billing.tax_registrations IS 'Tenant tax IDs per jurisdiction (VAT/GST/sales tax) governing how tax is charged in a region.';
COMMENT ON COLUMN billing.tax_registrations.registration_number IS 'The official tax/VAT registration number issued by the jurisdiction.';
COMMENT ON TABLE billing.wallets IS 'Stored-credit balances per user and currency (prepaid credit, refunds-to-credit, promo balance).';
