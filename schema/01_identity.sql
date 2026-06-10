-- 01_identity.sql — tenants, users, RBAC, sessions, API creds, teams.
-- Foundation module: almost everything references identity.tenants(id) and
-- identity.users(id). Self-contained: tables + constraints + FK indexes +
-- selected comments. See CONVENTIONS.md and SCHEMA-MAP.md.

-- ===========================================================================
-- tenants — the platform's customer organizations. NOT tenant-scoped (it IS
-- the tenant). default_currency_code / default_locale are wired to geo via
-- ALTERs at the end of 02_geo.sql (geo loads after identity).
-- ===========================================================================
CREATE TABLE identity.tenants (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id             uuid NOT NULL DEFAULT gen_random_uuid(),
    name                  text NOT NULL,
    slug                  text NOT NULL,
    status                identity.tenant_status NOT NULL DEFAULT 'trial',
    default_currency_code char(3) NOT NULL DEFAULT 'USD',
    default_locale        char(5) NOT NULL DEFAULT 'en-US',
    industry              text,
    employee_count        integer CHECK (employee_count >= 0),
    trial_ends_at         timestamptz,
    signup_source         text,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    deleted_at            timestamptz,
    CONSTRAINT tenants_public_id_key UNIQUE (public_id),
    CONSTRAINT tenants_slug_key      UNIQUE (slug)
);

CREATE TABLE identity.tenant_settings (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id) ON DELETE CASCADE,
    key         text NOT NULL,
    value       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tenant_settings_key_uq UNIQUE (tenant_id, key)
);
CREATE INDEX ON identity.tenant_settings (tenant_id);

-- ===========================================================================
-- users — end users and staff within a tenant. Emails are citext (case-
-- insensitive) and unique per tenant, not globally.
-- ===========================================================================
CREATE TABLE identity.users (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id     uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    email         citext NOT NULL,
    full_name     text,
    status        identity.user_status NOT NULL DEFAULT 'active',
    is_staff      boolean NOT NULL DEFAULT false,
    locale        char(5),
    timezone      text,
    password_hash text,
    last_login_at timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT users_public_id_key UNIQUE (public_id),
    CONSTRAINT users_tenant_email_uq UNIQUE (tenant_id, email)
);
CREATE INDEX ON identity.users (tenant_id);
CREATE INDEX users_email_lower_idx ON identity.users (lower(email::text));

CREATE TABLE identity.user_profiles (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    user_id     bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    avatar_url  text,
    bio         text,
    phone       text,
    job_title   text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_profiles_user_uq UNIQUE (user_id)
);
CREATE INDEX ON identity.user_profiles (tenant_id);

CREATE TABLE identity.user_preferences (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        bigint NOT NULL REFERENCES identity.tenants(id),
    user_id          bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    theme            text NOT NULL DEFAULT 'system',
    email_opt_in     boolean NOT NULL DEFAULT true,
    marketing_opt_in boolean NOT NULL DEFAULT false,
    locale_override  char(5),
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_preferences_user_uq UNIQUE (user_id)
);

-- ===========================================================================
-- RBAC: roles (per-tenant) + global permission catalog + junctions.
-- ===========================================================================
CREATE TABLE identity.roles (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    name        text NOT NULL,
    description text,
    is_system   boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT roles_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON identity.roles (tenant_id);

CREATE TABLE identity.permissions (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text NOT NULL,
    description text,
    category    text,
    CONSTRAINT permissions_code_key UNIQUE (code)
);

CREATE TABLE identity.role_permissions (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    role_id       bigint NOT NULL REFERENCES identity.roles(id) ON DELETE CASCADE,
    permission_id bigint NOT NULL REFERENCES identity.permissions(id),
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT role_permissions_uq UNIQUE (role_id, permission_id)
);
CREATE INDEX ON identity.role_permissions (tenant_id);
CREATE INDEX ON identity.role_permissions (permission_id);

CREATE TABLE identity.user_roles (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        bigint NOT NULL REFERENCES identity.tenants(id),
    user_id          bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    role_id          bigint NOT NULL REFERENCES identity.roles(id) ON DELETE CASCADE,
    granted_by_user_id bigint REFERENCES identity.users(id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_roles_uq UNIQUE (user_id, role_id)
);
CREATE INDEX ON identity.user_roles (tenant_id);
CREATE INDEX ON identity.user_roles (role_id);

-- ===========================================================================
-- teams — hierarchical sub-org groupings.
-- ===========================================================================
CREATE TABLE identity.teams (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    name           text NOT NULL,
    parent_team_id bigint REFERENCES identity.teams(id),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT teams_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON identity.teams (tenant_id);
CREATE INDEX ON identity.teams (parent_team_id);

CREATE TABLE identity.team_members (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  bigint NOT NULL REFERENCES identity.tenants(id),
    team_id    bigint NOT NULL REFERENCES identity.teams(id) ON DELETE CASCADE,
    user_id    bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    team_role  text NOT NULL DEFAULT 'member',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT team_members_uq UNIQUE (team_id, user_id)
);
CREATE INDEX ON identity.team_members (tenant_id);
CREATE INDEX ON identity.team_members (user_id);

-- ===========================================================================
-- Credentials & auth artifacts.
-- ===========================================================================
CREATE TABLE identity.api_keys (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id          uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    name               text NOT NULL,
    prefix             text NOT NULL,
    hashed_key         text NOT NULL,
    status             identity.api_key_status NOT NULL DEFAULT 'active',
    created_by_user_id bigint REFERENCES identity.users(id),
    last_used_at       timestamptz,
    expires_at         timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT api_keys_public_id_key UNIQUE (public_id),
    CONSTRAINT api_keys_prefix_key UNIQUE (prefix)
);
CREATE INDEX ON identity.api_keys (tenant_id);

CREATE TABLE identity.personal_access_tokens (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    user_id      bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    name         text NOT NULL,
    hashed_token text NOT NULL,
    scopes       text[] NOT NULL DEFAULT '{}',
    last_used_at timestamptz,
    expires_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pat_token_key UNIQUE (hashed_token)
);
CREATE INDEX ON identity.personal_access_tokens (tenant_id);
CREATE INDEX ON identity.personal_access_tokens (user_id);

CREATE TABLE identity.sessions (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    user_id     bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    token_hash  text NOT NULL,
    ip_address  inet,
    user_agent  text,
    started_at  timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    revoked_at  timestamptz,
    CONSTRAINT sessions_token_key UNIQUE (token_hash)
);
CREATE INDEX ON identity.sessions (tenant_id);
CREATE INDEX ON identity.sessions (user_id);
CREATE INDEX sessions_active_idx ON identity.sessions (user_id) WHERE revoked_at IS NULL;

CREATE TABLE identity.oauth_accounts (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    user_id             bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    provider            text NOT NULL,
    provider_account_id text NOT NULL,
    access_token_hash   text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT oauth_provider_uq UNIQUE (provider, provider_account_id)
);
CREATE INDEX ON identity.oauth_accounts (tenant_id);
CREATE INDEX ON identity.oauth_accounts (user_id);

CREATE TABLE identity.mfa_devices (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    user_id      bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    kind         text NOT NULL DEFAULT 'totp',
    secret_hash  text NOT NULL,
    confirmed_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON identity.mfa_devices (tenant_id);
CREATE INDEX ON identity.mfa_devices (user_id);

CREATE TABLE identity.invitations (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    email             citext NOT NULL,
    role_id           bigint REFERENCES identity.roles(id),
    invited_by_user_id bigint REFERENCES identity.users(id),
    status            identity.invite_status NOT NULL DEFAULT 'pending',
    token_hash        text NOT NULL,
    expires_at        timestamptz NOT NULL,
    accepted_at       timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT invitations_token_key UNIQUE (token_hash)
);
CREATE INDEX ON identity.invitations (tenant_id);

CREATE TABLE identity.password_resets (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  bigint NOT NULL REFERENCES identity.tenants(id),
    user_id    bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    token_hash text NOT NULL,
    expires_at timestamptz NOT NULL,
    used_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT password_resets_token_key UNIQUE (token_hash)
);
CREATE INDEX ON identity.password_resets (user_id);

CREATE TABLE identity.service_accounts (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT service_accounts_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON identity.service_accounts (tenant_id);

CREATE TABLE identity.login_attempts (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    user_id     bigint REFERENCES identity.users(id),
    email       citext,
    succeeded   boolean NOT NULL,
    ip_address  inet,
    user_agent  text,
    occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON identity.login_attempts (tenant_id, occurred_at);
CREATE INDEX ON identity.login_attempts (user_id);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE identity.tenants IS 'Customer organizations on the platform; the root of multi-tenancy. Every tenant-scoped row hangs off a tenant_id.';
COMMENT ON TABLE identity.users IS 'End users and staff belonging to a tenant. Email is unique per tenant, not globally.';
COMMENT ON COLUMN identity.users.is_staff IS 'True for internal/admin operators of the tenant, as opposed to customer end-users.';
COMMENT ON TABLE identity.roles IS 'Per-tenant RBAC roles. is_system marks built-in roles that cannot be deleted.';
COMMENT ON TABLE identity.permissions IS 'Global catalog of permission codes (e.g. orders.refund). Shared across all tenants.';
COMMENT ON TABLE identity.user_roles IS 'Assignment of roles to users. granted_by_user_id records who made the grant.';
COMMENT ON TABLE identity.api_keys IS 'Programmatic API credentials for a tenant. Only the hash and a short prefix are stored.';
COMMENT ON TABLE identity.sessions IS 'Authenticated browser/app sessions. revoked_at non-null means force-logged-out.';
COMMENT ON TABLE identity.invitations IS 'Pending invitations to join a tenant; consumed when status becomes accepted.';
COMMENT ON TABLE identity.login_attempts IS 'Audit of authentication attempts, successful and failed, for security analytics.';
COMMENT ON COLUMN identity.tenants.default_currency_code IS 'ISO-4217 default currency; FK to geo.currencies added in 02_geo.sql.';
