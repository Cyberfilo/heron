-- 14_ops.sql — feature flags, settings, jobs, integrations, files, imports.
-- Operational / platform-internal module. Mostly tenant-scoped config and
-- run records. Several tables here are IMMUTABLE (job_runs, integration_syncs,
-- import_errors, system_health_checks) and carry only created_at/occurred_at.
-- FK targets used: identity.tenants(id), identity.users(id), identity.api_keys(id).
-- See CONVENTIONS.md and SCHEMA-MAP.md.

-- ===========================================================================
-- feature_flags — toggle/rollout definitions, keyed uniquely per tenant.
-- ===========================================================================
CREATE TABLE ops.feature_flags (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    key         text NOT NULL,
    name        text NOT NULL,
    description text,
    kind        ops.flag_kind NOT NULL DEFAULT 'boolean',
    is_enabled  boolean NOT NULL DEFAULT false,
    default_value jsonb NOT NULL DEFAULT 'false'::jsonb,
    rollout_percentage integer CHECK (rollout_percentage BETWEEN 0 AND 100),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT feature_flags_tenant_key_uq UNIQUE (tenant_id, key)
);
CREATE INDEX ON ops.feature_flags (tenant_id);

CREATE TABLE ops.feature_flag_rules (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    feature_flag_id bigint NOT NULL REFERENCES ops.feature_flags(id) ON DELETE CASCADE,
    position        integer NOT NULL DEFAULT 0,
    conditions      jsonb NOT NULL DEFAULT '{}'::jsonb,
    serve_value     jsonb NOT NULL DEFAULT 'true'::jsonb,
    is_active       boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT feature_flag_rules_position_uq UNIQUE (feature_flag_id, position)
);
CREATE INDEX ON ops.feature_flag_rules (tenant_id);
CREATE INDEX ON ops.feature_flag_rules (feature_flag_id);

CREATE TABLE ops.feature_flag_overrides (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    feature_flag_id bigint NOT NULL REFERENCES ops.feature_flags(id) ON DELETE CASCADE,
    user_id         bigint REFERENCES identity.users(id) ON DELETE CASCADE,
    value           jsonb NOT NULL,
    reason          text,
    expires_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON ops.feature_flag_overrides (tenant_id);
CREATE INDEX ON ops.feature_flag_overrides (feature_flag_id);
CREATE INDEX ON ops.feature_flag_overrides (user_id);
-- One tenant-wide override (user_id NULL) per flag; user-specific overrides unique per user.
CREATE UNIQUE INDEX feature_flag_overrides_tenant_default_uq
    ON ops.feature_flag_overrides (feature_flag_id) WHERE user_id IS NULL;
CREATE UNIQUE INDEX feature_flag_overrides_user_uq
    ON ops.feature_flag_overrides (feature_flag_id, user_id) WHERE user_id IS NOT NULL;

-- ===========================================================================
-- settings — typed key/value configuration store, scoped per tenant.
-- ===========================================================================
CREATE TABLE ops.settings (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    key         text NOT NULL,
    value       jsonb NOT NULL DEFAULT '{}'::jsonb,
    value_type  text NOT NULL DEFAULT 'string',
    is_secret   boolean NOT NULL DEFAULT false,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT settings_tenant_key_uq UNIQUE (tenant_id, key),
    CONSTRAINT settings_value_type_chk CHECK (value_type IN ('string','number','boolean','json','date'))
);
CREATE INDEX ON ops.settings (tenant_id);

-- ===========================================================================
-- jobs / job_runs — background job definitions and their (immutable) executions.
-- ===========================================================================
CREATE TABLE ops.jobs (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    name          text NOT NULL,
    queue         text NOT NULL DEFAULT 'default',
    handler       text NOT NULL,
    payload       jsonb NOT NULL DEFAULT '{}'::jsonb,
    max_attempts  integer NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
    is_enabled    boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT jobs_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON ops.jobs (tenant_id);

CREATE TABLE ops.job_runs (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    job_id       bigint NOT NULL REFERENCES ops.jobs(id) ON DELETE CASCADE,
    status       ops.job_status NOT NULL DEFAULT 'queued',
    attempt      integer NOT NULL DEFAULT 1 CHECK (attempt > 0),
    queued_at    timestamptz NOT NULL DEFAULT now(),
    started_at   timestamptz,
    finished_at  timestamptz,
    duration_ms  integer CHECK (duration_ms >= 0),
    error_message text,
    result       jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT job_runs_finish_chk CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX ON ops.job_runs (tenant_id);
CREATE INDEX ON ops.job_runs (job_id);
CREATE INDEX job_runs_status_idx ON ops.job_runs (status) WHERE status IN ('queued','running','retrying');
CREATE INDEX ON ops.job_runs (tenant_id, created_at);

-- ===========================================================================
-- integrations / integration_syncs — third-party connections and sync runs.
-- ===========================================================================
CREATE TABLE ops.integrations (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    provider      text NOT NULL,
    name          text NOT NULL,
    status        ops.integration_status NOT NULL DEFAULT 'disconnected',
    config        jsonb NOT NULL DEFAULT '{}'::jsonb,
    connected_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    connected_at  timestamptz,
    last_synced_at timestamptz,
    last_error    text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT integrations_tenant_provider_name_uq UNIQUE (tenant_id, provider, name)
);
CREATE INDEX ON ops.integrations (tenant_id);
CREATE INDEX ON ops.integrations (connected_by_user_id);
CREATE INDEX integrations_status_idx ON ops.integrations (tenant_id, status);

CREATE TABLE ops.integration_syncs (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    integration_id bigint NOT NULL REFERENCES ops.integrations(id) ON DELETE CASCADE,
    status         ops.job_status NOT NULL DEFAULT 'queued',
    direction      text NOT NULL DEFAULT 'inbound',
    records_processed integer NOT NULL DEFAULT 0 CHECK (records_processed >= 0),
    records_failed integer NOT NULL DEFAULT 0 CHECK (records_failed >= 0),
    started_at     timestamptz,
    finished_at    timestamptz,
    error_message  text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT integration_syncs_direction_chk CHECK (direction IN ('inbound','outbound','bidirectional')),
    CONSTRAINT integration_syncs_finish_chk CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX ON ops.integration_syncs (tenant_id);
CREATE INDEX ON ops.integration_syncs (integration_id);

-- ===========================================================================
-- files / file_versions — uploaded file metadata (blobs live in object storage)
-- plus an explicit version chain per file.
-- ===========================================================================
CREATE TABLE ops.files (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    filename        text NOT NULL,
    content_type    text NOT NULL,
    byte_size       bigint NOT NULL CHECK (byte_size >= 0),
    storage_bucket  text NOT NULL,
    storage_key     text NOT NULL,
    checksum        text,
    uploaded_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    CONSTRAINT files_public_id_key UNIQUE (public_id),
    CONSTRAINT files_storage_key_uq UNIQUE (storage_bucket, storage_key)
);
CREATE INDEX ON ops.files (tenant_id);
CREATE INDEX ON ops.files (uploaded_by_user_id);

CREATE TABLE ops.file_versions (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    file_id        bigint NOT NULL REFERENCES ops.files(id) ON DELETE CASCADE,
    version        integer NOT NULL CHECK (version > 0),
    byte_size      bigint NOT NULL CHECK (byte_size >= 0),
    storage_key    text NOT NULL,
    checksum       text,
    is_current     boolean NOT NULL DEFAULT false,
    created_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT file_versions_file_version_uq UNIQUE (file_id, version)
);
CREATE INDEX ON ops.file_versions (tenant_id);
CREATE INDEX ON ops.file_versions (file_id);
-- Exactly one current version per file.
CREATE UNIQUE INDEX file_versions_current_uq
    ON ops.file_versions (file_id) WHERE is_current;

-- ===========================================================================
-- import_batches / import_errors — bulk import runs and their (immutable)
-- per-row failures.
-- ===========================================================================
CREATE TABLE ops.import_batches (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    entity_type    text NOT NULL,
    source_filename text,
    file_id        bigint REFERENCES ops.files(id) ON DELETE SET NULL,
    status         ops.import_status NOT NULL DEFAULT 'pending',
    total_rows     integer NOT NULL DEFAULT 0 CHECK (total_rows >= 0),
    processed_rows integer NOT NULL DEFAULT 0 CHECK (processed_rows >= 0),
    succeeded_rows integer NOT NULL DEFAULT 0 CHECK (succeeded_rows >= 0),
    failed_rows    integer NOT NULL DEFAULT 0 CHECK (failed_rows >= 0),
    started_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    started_at     timestamptz,
    finished_at    timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT import_batches_finish_chk CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX ON ops.import_batches (tenant_id);
CREATE INDEX ON ops.import_batches (file_id);
CREATE INDEX ON ops.import_batches (started_by_user_id);
CREATE INDEX import_batches_status_idx ON ops.import_batches (tenant_id, status);

CREATE TABLE ops.import_errors (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        bigint NOT NULL REFERENCES identity.tenants(id),
    import_batch_id  bigint NOT NULL REFERENCES ops.import_batches(id) ON DELETE CASCADE,
    row_number       integer NOT NULL CHECK (row_number > 0),
    column_name      text,
    error_code       text NOT NULL,
    error_message    text NOT NULL,
    raw_row          jsonb,
    occurred_at      timestamptz NOT NULL DEFAULT now(),
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON ops.import_errors (tenant_id);
CREATE INDEX ON ops.import_errors (import_batch_id);

-- ===========================================================================
-- scheduled_tasks — cron-expression driven recurring tasks.
-- ===========================================================================
CREATE TABLE ops.scheduled_tasks (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    name            text NOT NULL,
    cron_expression text NOT NULL,
    timezone        text NOT NULL DEFAULT 'UTC',
    job_id          bigint REFERENCES ops.jobs(id) ON DELETE SET NULL,
    is_enabled      boolean NOT NULL DEFAULT true,
    last_run_at     timestamptz,
    next_run_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT scheduled_tasks_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON ops.scheduled_tasks (tenant_id);
CREATE INDEX ON ops.scheduled_tasks (job_id);
CREATE INDEX scheduled_tasks_due_idx ON ops.scheduled_tasks (next_run_at) WHERE is_enabled;

-- ===========================================================================
-- system_health_checks — immutable periodic health probe results.
-- ===========================================================================
CREATE TABLE ops.system_health_checks (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    component     text NOT NULL,
    is_healthy    boolean NOT NULL,
    latency_ms    integer CHECK (latency_ms >= 0),
    details       jsonb,
    checked_at    timestamptz NOT NULL DEFAULT now(),
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON ops.system_health_checks (tenant_id);
CREATE INDEX system_health_checks_component_idx ON ops.system_health_checks (tenant_id, component, checked_at);

-- ===========================================================================
-- rate_limits — per-tenant / per-api-key quota windows.
-- ===========================================================================
CREATE TABLE ops.rate_limits (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    api_key_id    bigint REFERENCES identity.api_keys(id) ON DELETE CASCADE,
    scope         text NOT NULL,
    max_requests  integer NOT NULL CHECK (max_requests > 0),
    window_seconds integer NOT NULL CHECK (window_seconds > 0),
    is_enabled    boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON ops.rate_limits (tenant_id);
CREATE INDEX ON ops.rate_limits (api_key_id);
-- One limit per (api_key, scope); and one tenant-wide default (api_key NULL) per scope.
CREATE UNIQUE INDEX rate_limits_key_scope_uq
    ON ops.rate_limits (api_key_id, scope) WHERE api_key_id IS NOT NULL;
CREATE UNIQUE INDEX rate_limits_tenant_scope_uq
    ON ops.rate_limits (tenant_id, scope) WHERE api_key_id IS NULL;

-- ===========================================================================
-- secrets_vault — references/metadata for externally-stored secrets. NEVER
-- stores plaintext: only a pointer (provider + external ref) and metadata.
-- ===========================================================================
CREATE TABLE ops.secrets_vault (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    key             text NOT NULL,
    provider        text NOT NULL DEFAULT 'internal',
    external_ref    text NOT NULL,
    version         integer NOT NULL DEFAULT 1 CHECK (version > 0),
    last_rotated_at timestamptz,
    expires_at      timestamptz,
    created_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT secrets_vault_tenant_key_uq UNIQUE (tenant_id, key)
);
CREATE INDEX ON ops.secrets_vault (tenant_id);
CREATE INDEX ON ops.secrets_vault (created_by_user_id);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE ops.feature_flags IS 'Feature toggle and rollout definitions, addressed by a tenant-unique key. kind distinguishes boolean toggles from multivariate and percentage rollouts.';
COMMENT ON COLUMN ops.feature_flags.default_value IS 'Fallback value served when no rule or override matches; jsonb to support multivariate payloads, not just booleans.';
COMMENT ON TABLE ops.feature_flag_rules IS 'Ordered targeting rules for a flag; the first rule whose jsonb conditions match decides the served value.';
COMMENT ON TABLE ops.feature_flag_overrides IS 'Explicit per-user or tenant-wide overrides that bypass rule evaluation for a flag.';
COMMENT ON TABLE ops.settings IS 'Typed key/value configuration per tenant. value_type tags how the jsonb value should be interpreted by the application.';
COMMENT ON COLUMN ops.settings.value_type IS 'Logical type hint for value (string/number/boolean/json/date); the column itself is always jsonb.';
COMMENT ON TABLE ops.jobs IS 'Background job definitions registered per tenant; job_runs records each execution.';
COMMENT ON TABLE ops.job_runs IS 'Immutable record of a single background job execution, including status, attempt number and timing.';
COMMENT ON TABLE ops.integrations IS 'Third-party service connections for a tenant (e.g. ERP, shipping, accounting), with current status and config.';
COMMENT ON TABLE ops.integration_syncs IS 'Immutable record of a single data-sync run against an integration.';
COMMENT ON TABLE ops.files IS 'Metadata for files uploaded to object storage; the actual blob lives in storage_bucket/storage_key, not in the database.';
COMMENT ON TABLE ops.file_versions IS 'Version chain for a file; is_current flags the active version (one per file, enforced by partial unique index).';
COMMENT ON TABLE ops.import_batches IS 'Bulk data-import runs with row-level progress counters and a terminal status.';
COMMENT ON TABLE ops.import_errors IS 'Immutable per-row failures captured during an import batch, with the offending raw row preserved as jsonb.';
COMMENT ON TABLE ops.scheduled_tasks IS 'Cron-expression driven recurring tasks; next_run_at is the precomputed next fire time used by the scheduler.';
COMMENT ON TABLE ops.rate_limits IS 'Request quota windows scoped per tenant or per API key; an api_key-null row is the tenant-wide default for a scope.';
COMMENT ON TABLE ops.secrets_vault IS 'References and metadata for secrets held in an external vault; never stores plaintext, only a provider pointer (external_ref).';
COMMENT ON COLUMN ops.secrets_vault.external_ref IS 'Opaque pointer into the external secret store (e.g. a Vault path or KMS key id); resolved at runtime, never the secret value itself.';
