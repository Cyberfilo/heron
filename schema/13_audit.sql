-- 13_audit.sql — audit log, change history, access log, consent, compliance.
-- Compliance/governance module. Almost everything here is APPEND-ONLY: rows are
-- written once and never mutated, so immutable tables carry only created_at (or
-- occurred_at for event-shaped records) — NO updated_at, NO deleted_at. The few
-- genuinely mutable, lifecycle-bearing tables (data_exports, data_subject_requests,
-- retention_policies, legal_holds) keep updated_at because their status/fields
-- change over time.
--
-- FK targets (lower-or-equal modules only): identity.tenants(id), identity.users(id).
-- audit_log uses a POLYMORPHIC entity reference (entity_schema/entity_table/entity_id)
-- with NO real FK — by design: audited rows live in any of the 14 schemas and may be
-- hard-deleted, so a hard FK is impossible and intentionally absent.
-- See CONVENTIONS.md and SCHEMA-MAP.md.

-- ===========================================================================
-- audit_log — the central append-only audit trail. Every meaningful mutation
-- and security-relevant action lands here. The audited entity is referenced
-- polymorphically (schema + table + row id) because it can live anywhere in
-- the database and may later be deleted. Immutable: occurred_at only.
-- ===========================================================================
CREATE TABLE audit.audit_log (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    action         audit.audit_action NOT NULL,
    actor_user_id  bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    actor_type     text NOT NULL DEFAULT 'user',
    entity_schema  text,
    entity_table   text,
    entity_id      bigint,
    summary        text,
    metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
    ip_address     inet,
    user_agent     text,
    request_id     text,
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT audit_log_entity_ref_chk
        CHECK ((entity_schema IS NULL) = (entity_table IS NULL))
);
CREATE INDEX ON audit.audit_log (tenant_id, occurred_at);
CREATE INDEX ON audit.audit_log (actor_user_id);
CREATE INDEX audit_log_entity_idx ON audit.audit_log (entity_schema, entity_table, entity_id);
CREATE INDEX ON audit.audit_log (action);

-- ===========================================================================
-- change_history — column-level before/after diffs for an audited row. Often
-- written alongside an audit_log entry but can stand alone. Immutable.
-- ===========================================================================
CREATE TABLE audit.change_history (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    audit_log_id   bigint REFERENCES audit.audit_log(id) ON DELETE CASCADE,
    actor_user_id  bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    entity_schema  text NOT NULL,
    entity_table   text NOT NULL,
    entity_id      bigint NOT NULL,
    changed_columns text[] NOT NULL DEFAULT '{}',
    before_data    jsonb NOT NULL DEFAULT '{}'::jsonb,
    after_data     jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON audit.change_history (tenant_id);
CREATE INDEX ON audit.change_history (audit_log_id);
CREATE INDEX change_history_entity_idx ON audit.change_history (entity_schema, entity_table, entity_id);

-- ===========================================================================
-- access_log — records reads of sensitive data (PII, financial, exports) for
-- compliance and breach forensics. Append-only, very high volume.
-- ===========================================================================
CREATE TABLE audit.access_log (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    actor_user_id  bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    entity_schema  text NOT NULL,
    entity_table   text NOT NULL,
    entity_id      bigint,
    access_kind    text NOT NULL DEFAULT 'read',
    field_names    text[] NOT NULL DEFAULT '{}',
    purpose        text,
    ip_address     inet,
    user_agent     text,
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON audit.access_log (tenant_id, occurred_at);
CREATE INDEX ON audit.access_log (actor_user_id);
CREATE INDEX access_log_entity_idx ON audit.access_log (entity_schema, entity_table, entity_id);

-- ===========================================================================
-- data_exports — GDPR / data-portability export jobs. Tracks request through
-- completion; the produced artifact lives in object storage (file_url).
-- ===========================================================================
CREATE TABLE audit.data_exports (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id          uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    requested_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    subject_user_id    bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    status             text NOT NULL DEFAULT 'pending',
    format             text NOT NULL DEFAULT 'json',
    file_url           text,
    row_count          bigint CHECK (row_count >= 0),
    requested_at       timestamptz NOT NULL DEFAULT now(),
    completed_at       timestamptz,
    expires_at         timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT data_exports_public_id_key UNIQUE (public_id)
);
CREATE INDEX ON audit.data_exports (tenant_id);
CREATE INDEX ON audit.data_exports (subject_user_id);
CREATE INDEX ON audit.data_exports (requested_by_user_id);

-- ===========================================================================
-- consent_records — per-user consent grants/withdrawals for a named purpose
-- (marketing, analytics, terms, ...). Append-only consent history; the latest
-- row per (user, purpose) is the effective state. status audit.consent_status.
-- ===========================================================================
CREATE TABLE audit.consent_records (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    user_id       bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    purpose       text NOT NULL,
    status        audit.consent_status NOT NULL DEFAULT 'granted',
    source        text,
    policy_version text,
    ip_address    inet,
    granted_at    timestamptz,
    withdrawn_at  timestamptz,
    expires_at    timestamptz,
    occurred_at   timestamptz NOT NULL DEFAULT now(),
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON audit.consent_records (tenant_id);
CREATE INDEX consent_records_user_purpose_idx ON audit.consent_records (user_id, purpose);

-- ===========================================================================
-- compliance_events — flagged compliance incidents / policy violations needing
-- review (suspicious access, retention overrun, failed DSAR SLA, ...).
-- ===========================================================================
CREATE TABLE audit.compliance_events (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    event_type      text NOT NULL,
    severity        text NOT NULL DEFAULT 'medium',
    detected_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    entity_schema   text,
    entity_table    text,
    entity_id       bigint,
    details         jsonb NOT NULL DEFAULT '{}'::jsonb,
    resolved        boolean NOT NULL DEFAULT false,
    resolved_at     timestamptz,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON audit.compliance_events (tenant_id, occurred_at);
CREATE INDEX compliance_events_unresolved_idx ON audit.compliance_events (tenant_id) WHERE NOT resolved;

-- ===========================================================================
-- data_subject_requests — DSAR / right-to-erasure / access / rectification
-- requests under GDPR/CCPA. Mutable lifecycle: status changes as the request
-- is processed, so this table keeps updated_at. FK-targetable key (id).
-- ===========================================================================
CREATE TABLE audit.data_subject_requests (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id         uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    subject_user_id   bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    subject_email     citext,
    request_type      text NOT NULL,
    status            text NOT NULL DEFAULT 'received',
    assigned_to_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    data_export_id    bigint REFERENCES audit.data_exports(id) ON DELETE SET NULL,
    notes             text,
    received_at       timestamptz NOT NULL DEFAULT now(),
    due_at            timestamptz,
    completed_at      timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT dsr_public_id_key UNIQUE (public_id),
    CONSTRAINT dsr_subject_present_chk
        CHECK (subject_user_id IS NOT NULL OR subject_email IS NOT NULL)
);
CREATE INDEX ON audit.data_subject_requests (tenant_id);
CREATE INDEX ON audit.data_subject_requests (subject_user_id);
CREATE INDEX ON audit.data_subject_requests (assigned_to_user_id);
CREATE INDEX ON audit.data_subject_requests (data_export_id);
CREATE INDEX dsr_open_idx ON audit.data_subject_requests (tenant_id, due_at) WHERE completed_at IS NULL;

-- ===========================================================================
-- retention_policies — per-entity data-retention rules driving automated
-- purges. Mutable config: rules are edited over time, so keeps updated_at.
-- FK-targetable key (id) — legal_holds reference the policy they suspend.
-- ===========================================================================
CREATE TABLE audit.retention_policies (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        bigint NOT NULL REFERENCES identity.tenants(id),
    name             text NOT NULL,
    entity_schema    text NOT NULL,
    entity_table     text NOT NULL,
    retention_days   integer NOT NULL CHECK (retention_days > 0),
    action_on_expiry text NOT NULL DEFAULT 'delete',
    is_active        boolean NOT NULL DEFAULT true,
    last_run_at      timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT retention_policies_entity_uq UNIQUE (tenant_id, entity_schema, entity_table)
);
CREATE INDEX ON audit.retention_policies (tenant_id);
CREATE INDEX retention_policies_active_idx ON audit.retention_policies (tenant_id) WHERE is_active;

-- ===========================================================================
-- legal_holds — suspend deletion/retention for a subject or entity scope while
-- litigation/investigation is pending. Mutable: a hold is released over time.
-- ===========================================================================
CREATE TABLE audit.legal_holds (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    name                text NOT NULL,
    reason              text,
    retention_policy_id bigint REFERENCES audit.retention_policies(id) ON DELETE SET NULL,
    subject_user_id     bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    entity_schema       text,
    entity_table        text,
    entity_id           bigint,
    placed_by_user_id   bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    is_active           boolean NOT NULL DEFAULT true,
    placed_at           timestamptz NOT NULL DEFAULT now(),
    released_at         timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT legal_holds_release_chk CHECK (released_at IS NULL OR released_at >= placed_at)
);
CREATE INDEX ON audit.legal_holds (tenant_id);
CREATE INDEX ON audit.legal_holds (retention_policy_id);
CREATE INDEX ON audit.legal_holds (subject_user_id);
CREATE INDEX legal_holds_active_idx ON audit.legal_holds (tenant_id) WHERE is_active;

-- ===========================================================================
-- audit_log_archive — cold copy of aged-out audit_log rows. Same shape as
-- audit_log, written once by the archival job and never mutated. Keeps the
-- original id as source_audit_log_id for provenance.
-- ===========================================================================
CREATE TABLE audit.audit_log_archive (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_audit_log_id bigint,
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    action              audit.audit_action NOT NULL,
    actor_user_id       bigint,
    actor_type          text NOT NULL DEFAULT 'user',
    entity_schema       text,
    entity_table        text,
    entity_id           bigint,
    summary             text,
    metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
    ip_address          inet,
    user_agent          text,
    request_id          text,
    occurred_at         timestamptz NOT NULL,
    archived_at         timestamptz NOT NULL DEFAULT now(),
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON audit.audit_log_archive (tenant_id, occurred_at);
CREATE INDEX ON audit.audit_log_archive (source_audit_log_id);
CREATE INDEX audit_log_archive_entity_idx ON audit.audit_log_archive (entity_schema, entity_table, entity_id);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE audit.audit_log IS 'Central append-only audit trail of meaningful mutations and security actions. The audited row is referenced polymorphically via entity_schema/entity_table/entity_id (no FK).';
COMMENT ON COLUMN audit.audit_log.actor_type IS 'Principal kind that performed the action: user, api_key, service_account, or system.';
COMMENT ON COLUMN audit.audit_log.entity_id IS 'Primary-key id of the audited row in entity_schema.entity_table; intentionally not a foreign key.';
COMMENT ON TABLE audit.change_history IS 'Column-level before/after JSON diffs for an audited row, usually linked to an audit_log entry.';
COMMENT ON TABLE audit.access_log IS 'Append-only record of reads of sensitive/PII data, for compliance and breach forensics.';
COMMENT ON TABLE audit.consent_records IS 'Append-only per-user consent grants and withdrawals by purpose; the latest row per (user, purpose) is the effective consent state.';
COMMENT ON COLUMN audit.consent_records.policy_version IS 'Version of the privacy policy / terms the user consented to at the time.';
COMMENT ON TABLE audit.data_subject_requests IS 'GDPR/CCPA data-subject requests (access, erasure, rectification, portability) tracked through their processing lifecycle.';
COMMENT ON COLUMN audit.data_subject_requests.request_type IS 'Kind of DSAR: access, erasure, rectification, portability, or restriction.';
COMMENT ON TABLE audit.retention_policies IS 'Per-entity data-retention rules (retention_days + action_on_expiry) driving automated purges.';
COMMENT ON TABLE audit.legal_holds IS 'Active legal/investigation holds that suspend retention-driven deletion for a subject or entity scope.';
COMMENT ON TABLE audit.audit_log_archive IS 'Cold archive of aged-out audit_log rows; same shape as audit_log, written once by the archival job. source_audit_log_id preserves the original id.';
