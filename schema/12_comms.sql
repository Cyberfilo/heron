-- 12_comms.sql — notifications, in-app messaging, webhooks, and outbound
-- email/sms/push delivery records. Loads after identity (01). Cross-schema FKs
-- target only identity.tenants(id) and identity.users(id). Self-contained:
-- tables + constraints + FK indexes + selected comments. See CONVENTIONS.md
-- and SCHEMA-MAP.md.
--
-- Soft-deletable: none in this module.
-- IMMUTABLE (created_at only, no updated_at): webhook_deliveries, email_log,
-- sms_log — these are append-only delivery/attempt records.

-- ===========================================================================
-- notification_templates — reusable notification bodies, keyed per tenant and
-- channel. Referenced (nullably) by notifications that were rendered from a
-- template vs. composed ad hoc.
-- ===========================================================================
CREATE TABLE comms.notification_templates (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    code          text NOT NULL,
    name          text NOT NULL,
    channel       text NOT NULL DEFAULT 'in_app',
    subject       text,
    body          text NOT NULL,
    locale        char(5),
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT notification_templates_tenant_code_uq UNIQUE (tenant_id, code)
);
CREATE INDEX ON comms.notification_templates (tenant_id);

-- ===========================================================================
-- notifications — per-user notifications with a delivery lifecycle. May be
-- rendered from a template or composed directly (template_id nullable).
-- ===========================================================================
CREATE TABLE comms.notifications (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    user_id       bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    template_id   bigint REFERENCES comms.notification_templates(id) ON DELETE SET NULL,
    channel       text NOT NULL DEFAULT 'in_app',
    status        comms.notification_status NOT NULL DEFAULT 'queued',
    title         text NOT NULL,
    body          text,
    data          jsonb NOT NULL DEFAULT '{}'::jsonb,
    sent_at       timestamptz,
    delivered_at  timestamptz,
    read_at       timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON comms.notifications (tenant_id);
CREATE INDEX ON comms.notifications (user_id);
CREATE INDEX ON comms.notifications (template_id);
CREATE INDEX notifications_unread_idx ON comms.notifications (user_id) WHERE read_at IS NULL;
CREATE INDEX ON comms.notifications (tenant_id, created_at);

-- ===========================================================================
-- notification_preferences — per-user opt-in matrix by channel and category.
-- ===========================================================================
CREATE TABLE comms.notification_preferences (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    user_id       bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    channel       text NOT NULL,
    category      text NOT NULL DEFAULT 'all',
    is_enabled    boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT notification_preferences_uq UNIQUE (user_id, channel, category)
);
CREATE INDEX ON comms.notification_preferences (tenant_id);
CREATE INDEX ON comms.notification_preferences (user_id);

-- ===========================================================================
-- message_threads — in-app conversation threads (e.g. between a customer and
-- the tenant's support/comms). Holds an optional owning user.
-- ===========================================================================
CREATE TABLE comms.message_threads (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    user_id         bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    subject         text,
    channel         text NOT NULL DEFAULT 'in_app',
    is_closed       boolean NOT NULL DEFAULT false,
    last_message_at timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON comms.message_threads (tenant_id);
CREATE INDEX ON comms.message_threads (user_id);
CREATE INDEX message_threads_open_idx ON comms.message_threads (tenant_id) WHERE NOT is_closed;

-- ===========================================================================
-- thread_messages — individual messages within a thread. direction marks
-- whether the message is inbound (from the user) or outbound (from the tenant).
-- ===========================================================================
CREATE TABLE comms.thread_messages (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    thread_id    bigint NOT NULL REFERENCES comms.message_threads(id) ON DELETE CASCADE,
    sender_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    direction    comms.message_direction NOT NULL,
    body         text NOT NULL,
    attachments  jsonb NOT NULL DEFAULT '[]'::jsonb,
    read_at      timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON comms.thread_messages (tenant_id);
CREATE INDEX ON comms.thread_messages (thread_id);
CREATE INDEX ON comms.thread_messages (sender_user_id);
CREATE INDEX ON comms.thread_messages (thread_id, created_at);

-- ===========================================================================
-- webhooks — subscriber endpoints that receive event callbacks. secret_hash
-- is used to sign delivery payloads; only the hash is stored.
-- ===========================================================================
CREATE TABLE comms.webhooks (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    created_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    name          text NOT NULL,
    target_url    text NOT NULL,
    secret_hash   text NOT NULL,
    event_types   text[] NOT NULL DEFAULT '{}',
    is_active     boolean NOT NULL DEFAULT true,
    last_delivered_at timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON comms.webhooks (tenant_id);
CREATE INDEX ON comms.webhooks (created_by_user_id);
CREATE INDEX webhooks_active_idx ON comms.webhooks (tenant_id) WHERE is_active;

-- ===========================================================================
-- webhook_deliveries — IMMUTABLE append-only log of each delivery attempt for
-- a webhook subscription, including the response code and retry attempt count.
-- ===========================================================================
CREATE TABLE comms.webhook_deliveries (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    webhook_id    bigint NOT NULL REFERENCES comms.webhooks(id) ON DELETE CASCADE,
    event_type    text NOT NULL,
    status        comms.delivery_status NOT NULL DEFAULT 'pending',
    attempt       integer NOT NULL DEFAULT 1 CHECK (attempt > 0),
    response_code integer CHECK (response_code BETWEEN 100 AND 599),
    request_body  jsonb,
    response_body text,
    duration_ms   integer CHECK (duration_ms >= 0),
    delivered_at  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON comms.webhook_deliveries (tenant_id);
CREATE INDEX ON comms.webhook_deliveries (webhook_id);
CREATE INDEX ON comms.webhook_deliveries (webhook_id, created_at);
CREATE INDEX webhook_deliveries_failed_idx ON comms.webhook_deliveries (webhook_id) WHERE status = 'failed';

-- ===========================================================================
-- email_log — IMMUTABLE record of each outbound email sent on behalf of a
-- tenant. recipient_email is stored denormalized (the user may be deleted or
-- the address may be off-platform).
-- ===========================================================================
CREATE TABLE comms.email_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    user_id         bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    template_id     bigint REFERENCES comms.notification_templates(id) ON DELETE SET NULL,
    recipient_email citext NOT NULL,
    from_email      citext,
    subject         text,
    provider        text,
    provider_message_id text,
    status          comms.delivery_status NOT NULL DEFAULT 'pending',
    error_message   text,
    sent_at         timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON comms.email_log (tenant_id);
CREATE INDEX ON comms.email_log (user_id);
CREATE INDEX ON comms.email_log (template_id);
CREATE INDEX email_log_recipient_idx ON comms.email_log (lower(recipient_email::text));
CREATE INDEX ON comms.email_log (tenant_id, created_at);

-- ===========================================================================
-- sms_log — IMMUTABLE record of each outbound SMS. (Intentionally uncommented
-- at table level — see CONVENTIONS.md on deliberate comment gaps.)
-- ===========================================================================
CREATE TABLE comms.sms_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    user_id         bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    template_id     bigint REFERENCES comms.notification_templates(id) ON DELETE SET NULL,
    recipient_phone text NOT NULL,
    from_number     text,
    body            text NOT NULL,
    provider        text,
    provider_message_id text,
    status          comms.delivery_status NOT NULL DEFAULT 'pending',
    error_message   text,
    segments        integer NOT NULL DEFAULT 1 CHECK (segments > 0),
    sent_at         timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON comms.sms_log (tenant_id);
CREATE INDEX ON comms.sms_log (user_id);
CREATE INDEX ON comms.sms_log (template_id);
CREATE INDEX ON comms.sms_log (tenant_id, created_at);

-- ===========================================================================
-- push_tokens — device push-notification tokens registered per user. A token
-- is unique per tenant; (user, platform, device) identifies a device install.
-- ===========================================================================
CREATE TABLE comms.push_tokens (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    user_id       bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    platform      text NOT NULL,
    token         text NOT NULL,
    device_name   text,
    is_active     boolean NOT NULL DEFAULT true,
    last_used_at  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT push_tokens_tenant_token_uq UNIQUE (tenant_id, token)
);
CREATE INDEX ON comms.push_tokens (tenant_id);
CREATE INDEX ON comms.push_tokens (user_id);
CREATE INDEX push_tokens_active_idx ON comms.push_tokens (user_id) WHERE is_active;

-- ===========================================================================
-- unsubscribes — suppression list of addresses/channels that must not receive
-- further messages. user_id is nullable (an address may unsubscribe without an
-- account); the address is stored denormalized for matching.
-- ===========================================================================
CREATE TABLE comms.unsubscribes (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    user_id       bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    channel       text NOT NULL,
    address       text NOT NULL,
    category      text NOT NULL DEFAULT 'all',
    reason        text,
    unsubscribed_at timestamptz NOT NULL DEFAULT now(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT unsubscribes_uq UNIQUE (tenant_id, channel, address, category)
);
CREATE INDEX ON comms.unsubscribes (tenant_id);
CREATE INDEX ON comms.unsubscribes (user_id);

-- ===========================================================================
-- contact_channels — verified contact endpoints (email/phone) per user, with
-- a verification lifecycle. At most one primary channel of each kind per user.
-- ===========================================================================
CREATE TABLE comms.contact_channels (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    user_id       bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    kind          text NOT NULL,
    value         text NOT NULL,
    is_primary    boolean NOT NULL DEFAULT false,
    is_verified   boolean NOT NULL DEFAULT false,
    verified_at   timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT contact_channels_user_kind_value_uq UNIQUE (user_id, kind, value)
);
CREATE INDEX ON comms.contact_channels (tenant_id);
CREATE INDEX ON comms.contact_channels (user_id);
CREATE UNIQUE INDEX contact_channels_primary_idx
    ON comms.contact_channels (user_id, kind) WHERE is_primary;

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE comms.notification_templates IS 'Reusable, per-tenant notification bodies keyed by code and channel; rendered into notifications and email/sms logs.';
COMMENT ON TABLE comms.notifications IS 'Per-user notifications with a queued→sent→delivered→read lifecycle. template_id is null when composed ad hoc.';
COMMENT ON TABLE comms.notification_preferences IS 'Per-user opt-in matrix across channels and categories; an absent row means the tenant default applies.';
COMMENT ON TABLE comms.message_threads IS 'In-app conversation threads between a tenant and a user. last_message_at is denormalized for inbox sorting.';
COMMENT ON COLUMN comms.thread_messages.direction IS 'inbound = sent by the user toward the tenant; outbound = sent by the tenant toward the user.';
COMMENT ON TABLE comms.webhooks IS 'Subscriber HTTP endpoints that receive signed event callbacks. Only the hash of the signing secret is stored.';
COMMENT ON COLUMN comms.webhooks.secret_hash IS 'Hash of the HMAC signing secret used to sign delivery payloads; the plaintext secret is shown once at creation.';
COMMENT ON TABLE comms.webhook_deliveries IS 'Append-only log of each webhook delivery attempt, including HTTP response_code and retry attempt number.';
COMMENT ON COLUMN comms.webhook_deliveries.attempt IS '1-based retry counter; multiple rows per logical event when a delivery is retried.';
COMMENT ON TABLE comms.email_log IS 'Immutable record of every outbound email; recipient_email is denormalized since the user or address may be off-platform.';
COMMENT ON TABLE comms.push_tokens IS 'Device push-notification tokens per user; deactivated rather than deleted when a device unregisters.';
COMMENT ON TABLE comms.unsubscribes IS 'Suppression list of addresses/channels that must be excluded from further sends; user_id may be null for off-platform addresses.';
COMMENT ON TABLE comms.contact_channels IS 'Verified contact endpoints (email/phone) per user with a verification lifecycle; one primary per kind via a partial unique index.';
