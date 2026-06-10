-- 08_crm.sql — B2B CRM: accounts, contacts, leads, pipelines, opportunities,
-- deals, activities, tasks, notes, contact lists.
--
-- IMPORTANT: crm.accounts are the TENANT'S OWN customer companies (B2B). They
-- are tenant-scoped via tenant_id and are NOT identity.tenants (the platform's
-- customer orgs). Sales reps are identity.users (is_staff); the people the reps
-- sell to are crm.contacts hanging off crm.accounts.
--
-- Soft-deletable: accounts, contacts (deleted_at, NULL = live). Everything else
-- is hard-deleted / cascaded. opportunity_stages is an ordered LOOKUP table.
-- See CONVENTIONS.md and SCHEMA-MAP.md.

-- ===========================================================================
-- accounts — the tenant's B2B customer companies. Owner is an internal rep
-- (identity.users). Self-referencing parent links live in account_relationships.
-- ===========================================================================
CREATE TABLE crm.accounts (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        bigint NOT NULL REFERENCES identity.tenants(id),
    name             text NOT NULL,
    legal_name       text,
    domain           text,
    industry         text,
    employee_count   integer CHECK (employee_count >= 0),
    annual_revenue   numeric(14,4) CHECK (annual_revenue >= 0),
    currency_code    char(3) REFERENCES geo.currencies(code),
    owner_user_id    bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    phone            text,
    website          text,
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,
    CONSTRAINT accounts_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON crm.accounts (tenant_id);
CREATE INDEX ON crm.accounts (owner_user_id);
CREATE INDEX accounts_tenant_domain_idx ON crm.accounts (tenant_id, domain);

-- ===========================================================================
-- contacts — people who work at an account. Primary email is denormalized for
-- convenience; the full set lives in contact_emails.
-- ===========================================================================
CREATE TABLE crm.contacts (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    account_id      bigint REFERENCES crm.accounts(id) ON DELETE SET NULL,
    owner_user_id   bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    first_name      text,
    last_name       text,
    primary_email   citext,
    phone           text,
    job_title       text,
    department      text,
    is_primary      boolean NOT NULL DEFAULT false,
    do_not_contact  boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX ON crm.contacts (tenant_id);
CREATE INDEX ON crm.contacts (account_id);
CREATE INDEX ON crm.contacts (owner_user_id);
CREATE INDEX contacts_primary_email_idx ON crm.contacts (lower(primary_email::text));
-- one primary contact per account
CREATE UNIQUE INDEX contacts_one_primary_per_account_idx
    ON crm.contacts (account_id) WHERE is_primary AND deleted_at IS NULL;

-- ===========================================================================
-- contact_emails — multiple email addresses per contact (work, personal, ...).
-- ===========================================================================
CREATE TABLE crm.contact_emails (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    contact_id  bigint NOT NULL REFERENCES crm.contacts(id) ON DELETE CASCADE,
    email       citext NOT NULL,
    label       text NOT NULL DEFAULT 'work',
    is_primary  boolean NOT NULL DEFAULT false,
    verified_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT contact_emails_contact_email_uq UNIQUE (contact_id, email)
);
CREATE INDEX ON crm.contact_emails (tenant_id);
CREATE INDEX ON crm.contact_emails (contact_id);
CREATE UNIQUE INDEX contact_emails_one_primary_idx
    ON crm.contact_emails (contact_id) WHERE is_primary;

-- ===========================================================================
-- leads — unqualified inbound interest, before becoming an account/contact.
-- Converts forward into account_id / contact_id once qualified.
-- ===========================================================================
CREATE TABLE crm.leads (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    owner_user_id       bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    first_name          text,
    last_name           text,
    email               citext,
    phone               text,
    company             text,
    job_title           text,
    status              crm.lead_status NOT NULL DEFAULT 'new',
    source              text,
    score               integer NOT NULL DEFAULT 0 CHECK (score >= 0),
    converted_account_id bigint REFERENCES crm.accounts(id) ON DELETE SET NULL,
    converted_contact_id bigint REFERENCES crm.contacts(id) ON DELETE SET NULL,
    converted_at        timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON crm.leads (tenant_id);
CREATE INDEX ON crm.leads (owner_user_id);
CREATE INDEX ON crm.leads (converted_account_id);
CREATE INDEX leads_tenant_status_idx ON crm.leads (tenant_id, status);
CREATE INDEX leads_email_idx ON crm.leads (lower(email::text));

-- ===========================================================================
-- pipelines — named sales pipelines per tenant. Stages are in opportunity_stages.
-- ===========================================================================
CREATE TABLE crm.pipelines (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    name        text NOT NULL,
    description text,
    is_default  boolean NOT NULL DEFAULT false,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pipelines_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON crm.pipelines (tenant_id);
CREATE UNIQUE INDEX pipelines_one_default_idx
    ON crm.pipelines (tenant_id) WHERE is_default;

-- ===========================================================================
-- opportunity_stages — ordered LOOKUP of stages within a pipeline. position
-- defines the funnel order; win_probability drives weighted forecasts.
-- ===========================================================================
CREATE TABLE crm.opportunity_stages (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    pipeline_id     bigint NOT NULL REFERENCES crm.pipelines(id) ON DELETE CASCADE,
    name            text NOT NULL,
    position        integer NOT NULL CHECK (position >= 0),
    win_probability numeric(5,4) NOT NULL DEFAULT 0 CHECK (win_probability >= 0 AND win_probability <= 1),
    is_won          boolean NOT NULL DEFAULT false,
    is_lost         boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT opportunity_stages_pipeline_position_uq UNIQUE (pipeline_id, position),
    CONSTRAINT opportunity_stages_pipeline_name_uq UNIQUE (pipeline_id, name),
    CONSTRAINT opportunity_stages_not_won_and_lost CHECK (NOT (is_won AND is_lost))
);
CREATE INDEX ON crm.opportunity_stages (tenant_id);
CREATE INDEX ON crm.opportunity_stages (pipeline_id);

-- ===========================================================================
-- opportunities — deals in flight. Lives in a pipeline at a stage, tied to an
-- account. amount is the expected contract value in currency_code.
-- ===========================================================================
CREATE TABLE crm.opportunities (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    account_id      bigint NOT NULL REFERENCES crm.accounts(id) ON DELETE CASCADE,
    pipeline_id     bigint NOT NULL REFERENCES crm.pipelines(id),
    stage_id        bigint NOT NULL REFERENCES crm.opportunity_stages(id),
    primary_contact_id bigint REFERENCES crm.contacts(id) ON DELETE SET NULL,
    owner_user_id   bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    name            text NOT NULL,
    amount          numeric(14,4) NOT NULL DEFAULT 0 CHECK (amount >= 0),
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    probability     numeric(5,4) CHECK (probability >= 0 AND probability <= 1),
    source          text,
    is_closed       boolean NOT NULL DEFAULT false,
    is_won          boolean NOT NULL DEFAULT false,
    expected_close_date date,
    closed_at       timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON crm.opportunities (tenant_id);
CREATE INDEX ON crm.opportunities (account_id);
CREATE INDEX ON crm.opportunities (pipeline_id);
CREATE INDEX ON crm.opportunities (stage_id);
CREATE INDEX ON crm.opportunities (owner_user_id);
CREATE INDEX opportunities_open_idx ON crm.opportunities (tenant_id, stage_id) WHERE NOT is_closed;

-- ===========================================================================
-- deals — closed-won contracts realized from an opportunity. Holds the booked
-- contract value and term.
-- ===========================================================================
CREATE TABLE crm.deals (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    account_id      bigint NOT NULL REFERENCES crm.accounts(id) ON DELETE CASCADE,
    opportunity_id  bigint REFERENCES crm.opportunities(id) ON DELETE SET NULL,
    owner_user_id   bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    name            text NOT NULL,
    contract_value  numeric(14,4) NOT NULL DEFAULT 0 CHECK (contract_value >= 0),
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    signed_at       date,
    starts_at       date,
    ends_at         date,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT deals_term_valid CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX ON crm.deals (tenant_id);
CREATE INDEX ON crm.deals (account_id);
CREATE INDEX ON crm.deals (opportunity_id);
CREATE INDEX ON crm.deals (owner_user_id);

-- ===========================================================================
-- deal_line_items — products sold on a deal, priced per unit in the deal currency.
-- ===========================================================================
CREATE TABLE crm.deal_line_items (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    deal_id       bigint NOT NULL REFERENCES crm.deals(id) ON DELETE CASCADE,
    product_id    bigint REFERENCES catalog.products(id) ON DELETE SET NULL,
    description   text,
    quantity      integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price    numeric(14,4) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
    discount_pct  numeric(5,4) NOT NULL DEFAULT 0 CHECK (discount_pct >= 0 AND discount_pct <= 1),
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON crm.deal_line_items (tenant_id);
CREATE INDEX ON crm.deal_line_items (deal_id);
CREATE INDEX ON crm.deal_line_items (product_id);

-- ===========================================================================
-- activities — logged interactions (calls/emails/meetings/notes/tasks). The
-- target is polymorphic-ish: any of account/contact/opportunity may be set.
-- ===========================================================================
CREATE TABLE crm.activities (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    kind            crm.activity_kind NOT NULL,
    account_id      bigint REFERENCES crm.accounts(id) ON DELETE CASCADE,
    contact_id      bigint REFERENCES crm.contacts(id) ON DELETE CASCADE,
    opportunity_id  bigint REFERENCES crm.opportunities(id) ON DELETE CASCADE,
    owner_user_id   bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    subject         text,
    body            text,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    duration_minutes integer CHECK (duration_minutes >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT activities_has_target CHECK (
        account_id IS NOT NULL OR contact_id IS NOT NULL OR opportunity_id IS NOT NULL
    )
);
CREATE INDEX ON crm.activities (tenant_id);
CREATE INDEX ON crm.activities (account_id);
CREATE INDEX ON crm.activities (contact_id);
CREATE INDEX ON crm.activities (opportunity_id);
CREATE INDEX ON crm.activities (owner_user_id);
CREATE INDEX activities_tenant_occurred_idx ON crm.activities (tenant_id, occurred_at);

-- ===========================================================================
-- crm_notes — free-text notes attached to a CRM entity (polymorphic target).
-- ===========================================================================
CREATE TABLE crm.crm_notes (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    account_id     bigint REFERENCES crm.accounts(id) ON DELETE CASCADE,
    contact_id     bigint REFERENCES crm.contacts(id) ON DELETE CASCADE,
    opportunity_id bigint REFERENCES crm.opportunities(id) ON DELETE CASCADE,
    author_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    body           text NOT NULL,
    is_pinned      boolean NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT crm_notes_has_target CHECK (
        account_id IS NOT NULL OR contact_id IS NOT NULL OR opportunity_id IS NOT NULL
    )
);
CREATE INDEX ON crm.crm_notes (tenant_id);
CREATE INDEX ON crm.crm_notes (account_id);
CREATE INDEX ON crm.crm_notes (contact_id);
CREATE INDEX ON crm.crm_notes (opportunity_id);

-- ===========================================================================
-- tasks — follow-up to-dos for reps, optionally linked to a CRM entity.
-- ===========================================================================
CREATE TABLE crm.tasks (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    assignee_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    account_id      bigint REFERENCES crm.accounts(id) ON DELETE CASCADE,
    contact_id      bigint REFERENCES crm.contacts(id) ON DELETE CASCADE,
    opportunity_id  bigint REFERENCES crm.opportunities(id) ON DELETE CASCADE,
    title           text NOT NULL,
    description     text,
    priority        text NOT NULL DEFAULT 'normal',
    is_done         boolean NOT NULL DEFAULT false,
    due_at          timestamptz,
    completed_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON crm.tasks (tenant_id);
CREATE INDEX ON crm.tasks (assignee_user_id);
CREATE INDEX ON crm.tasks (account_id);
CREATE INDEX ON crm.tasks (opportunity_id);
CREATE INDEX tasks_open_due_idx ON crm.tasks (tenant_id, due_at) WHERE NOT is_done;

-- ===========================================================================
-- account_relationships — parent/subsidiary and other links between accounts.
-- child_account_id is the dependent; parent_account_id the controlling entity.
-- ===========================================================================
CREATE TABLE crm.account_relationships (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    parent_account_id bigint NOT NULL REFERENCES crm.accounts(id) ON DELETE CASCADE,
    child_account_id  bigint NOT NULL REFERENCES crm.accounts(id) ON DELETE CASCADE,
    relationship_type text NOT NULL DEFAULT 'subsidiary',
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT account_relationships_uq UNIQUE (parent_account_id, child_account_id, relationship_type),
    CONSTRAINT account_relationships_no_self CHECK (parent_account_id <> child_account_id)
);
CREATE INDEX ON crm.account_relationships (tenant_id);
CREATE INDEX ON crm.account_relationships (parent_account_id);
CREATE INDEX ON crm.account_relationships (child_account_id);

-- ===========================================================================
-- contact_lists — static, manually-curated lists of contacts.
-- ===========================================================================
CREATE TABLE crm.contact_lists (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    owner_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT contact_lists_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON crm.contact_lists (tenant_id);
CREATE INDEX ON crm.contact_lists (owner_user_id);

-- ===========================================================================
-- contact_list_members — junction of contacts into static lists.
-- ===========================================================================
CREATE TABLE crm.contact_list_members (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    contact_list_id bigint NOT NULL REFERENCES crm.contact_lists(id) ON DELETE CASCADE,
    contact_id      bigint NOT NULL REFERENCES crm.contacts(id) ON DELETE CASCADE,
    added_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT contact_list_members_uq UNIQUE (contact_list_id, contact_id)
);
CREATE INDEX ON crm.contact_list_members (tenant_id);
CREATE INDEX ON crm.contact_list_members (contact_id);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE crm.accounts IS 'The tenant''s own B2B customer companies. Tenant-scoped; distinct from identity.tenants (the platform''s customers).';
COMMENT ON COLUMN crm.accounts.owner_user_id IS 'Internal sales rep (identity.users) who owns the account relationship.';
COMMENT ON TABLE crm.contacts IS 'People who work at a CRM account. primary_email is denormalized; the full set lives in contact_emails.';
COMMENT ON TABLE crm.contact_emails IS 'All email addresses for a contact; at most one flagged is_primary per contact.';
COMMENT ON TABLE crm.leads IS 'Unqualified inbound interest before it becomes an account/contact; converts forward once qualified.';
COMMENT ON COLUMN crm.leads.score IS 'Lead score (0+); higher means more sales-ready.';
COMMENT ON TABLE crm.pipelines IS 'Named sales pipelines per tenant; at most one is the default. Stages live in opportunity_stages.';
COMMENT ON TABLE crm.opportunity_stages IS 'Ordered lookup of stages within a pipeline. position sets funnel order; win_probability drives weighted forecasts.';
COMMENT ON COLUMN crm.opportunity_stages.win_probability IS 'Default close probability for opportunities in this stage, 0..1.';
COMMENT ON TABLE crm.opportunities IS 'Deals in flight: an account being worked through a pipeline stage with an expected amount.';
COMMENT ON TABLE crm.deals IS 'Closed-won contracts realized from an opportunity, holding the booked contract value and term.';
COMMENT ON TABLE crm.deal_line_items IS 'Products sold on a deal, priced per unit in the deal currency.';
COMMENT ON TABLE crm.activities IS 'Logged interactions (calls, emails, meetings) against an account, contact, or opportunity.';
COMMENT ON TABLE crm.tasks IS 'Follow-up to-dos assigned to reps, optionally linked to a CRM entity.';
COMMENT ON TABLE crm.account_relationships IS 'Parent/subsidiary and other directed links between accounts within a tenant.';
