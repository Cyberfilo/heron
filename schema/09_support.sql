-- 09_support.sql — tickets, messages, SLAs, agents, CSAT, knowledge base.
-- Customer-support domain. Cross-schema FKs only to identity (01): tenants(id)
-- for tenancy and users(id) for ticket requesters / agent records. All tables
-- are tenant-scoped. ticket_events is IMMUTABLE (created_at only, no updated_at
-- — it is an append-only audit of ticket changes). See CONVENTIONS.md and
-- SCHEMA-MAP.md.
--
-- Soft-deletable entities (deleted_at): knowledge_articles, macros.

-- ===========================================================================
-- support_agents — staff who work tickets. One record per agent user (a thin
-- support-specific extension of identity.users carrying availability/load).
-- ===========================================================================
CREATE TABLE support.support_agents (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    user_id         bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    display_name    text,
    signature       text,
    is_available    boolean NOT NULL DEFAULT true,
    max_open_tickets integer NOT NULL DEFAULT 50 CHECK (max_open_tickets >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT support_agents_user_uq UNIQUE (tenant_id, user_id)
);
CREATE INDEX ON support.support_agents (tenant_id);
CREATE INDEX ON support.support_agents (user_id);
CREATE INDEX support_agents_available_idx ON support.support_agents (tenant_id) WHERE is_available;

-- ===========================================================================
-- agent_groups — named teams of agents for routing/assignment.
-- ===========================================================================
CREATE TABLE support.agent_groups (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    name        text NOT NULL,
    description text,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agent_groups_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON support.agent_groups (tenant_id);

CREATE TABLE support.agent_group_members (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    agent_group_id  bigint NOT NULL REFERENCES support.agent_groups(id) ON DELETE CASCADE,
    support_agent_id bigint NOT NULL REFERENCES support.support_agents(id) ON DELETE CASCADE,
    is_lead         boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agent_group_members_uq UNIQUE (agent_group_id, support_agent_id)
);
CREATE INDEX ON support.agent_group_members (tenant_id);
CREATE INDEX ON support.agent_group_members (support_agent_id);

-- ===========================================================================
-- sla_policies — lookup of response/resolution targets (minutes) applied to
-- tickets, typically by priority.
-- ===========================================================================
CREATE TABLE support.sla_policies (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id                bigint NOT NULL REFERENCES identity.tenants(id),
    name                     text NOT NULL,
    priority                 support.ticket_priority,
    first_response_target_minutes integer NOT NULL CHECK (first_response_target_minutes > 0),
    resolution_target_minutes     integer NOT NULL CHECK (resolution_target_minutes > 0),
    business_hours_only      boolean NOT NULL DEFAULT true,
    is_active                boolean NOT NULL DEFAULT true,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sla_policies_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON support.sla_policies (tenant_id);

-- ===========================================================================
-- support_tags — tag catalog for categorizing tickets.
-- ===========================================================================
CREATE TABLE support.support_tags (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    name        text NOT NULL,
    color       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT support_tags_tenant_name_uq UNIQUE (tenant_id, name)
);
CREATE INDEX ON support.support_tags (tenant_id);

-- ===========================================================================
-- Knowledge base: hierarchical categories + articles + per-article feedback.
-- ===========================================================================
CREATE TABLE support.knowledge_categories (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    name                text NOT NULL,
    slug                text NOT NULL,
    parent_category_id  bigint REFERENCES support.knowledge_categories(id) ON DELETE SET NULL,
    position            integer NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT knowledge_categories_slug_uq UNIQUE (tenant_id, slug)
);
CREATE INDEX ON support.knowledge_categories (tenant_id);
CREATE INDEX ON support.knowledge_categories (parent_category_id);

CREATE TABLE support.knowledge_articles (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               bigint NOT NULL REFERENCES identity.tenants(id),
    knowledge_category_id   bigint REFERENCES support.knowledge_categories(id) ON DELETE SET NULL,
    author_user_id          bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    title                   text NOT NULL,
    slug                    text NOT NULL,
    body                    text,
    is_published            boolean NOT NULL DEFAULT false,
    view_count              bigint NOT NULL DEFAULT 0 CHECK (view_count >= 0),
    helpful_count           integer NOT NULL DEFAULT 0 CHECK (helpful_count >= 0),
    not_helpful_count       integer NOT NULL DEFAULT 0 CHECK (not_helpful_count >= 0),
    published_at            timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    deleted_at              timestamptz,
    CONSTRAINT knowledge_articles_slug_uq UNIQUE (tenant_id, slug)
);
CREATE INDEX ON support.knowledge_articles (tenant_id);
CREATE INDEX ON support.knowledge_articles (knowledge_category_id);
CREATE INDEX ON support.knowledge_articles (author_user_id);
CREATE INDEX knowledge_articles_published_idx ON support.knowledge_articles (tenant_id, published_at) WHERE is_published;

CREATE TABLE support.article_feedback (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               bigint NOT NULL REFERENCES identity.tenants(id),
    knowledge_article_id    bigint NOT NULL REFERENCES support.knowledge_articles(id) ON DELETE CASCADE,
    user_id                 bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    was_helpful             boolean NOT NULL,
    comment                 text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON support.article_feedback (tenant_id);
CREATE INDEX ON support.article_feedback (knowledge_article_id);

-- ===========================================================================
-- macros — canned replies agents can insert into tickets. Soft-deletable.
-- ===========================================================================
CREATE TABLE support.macros (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    created_by_agent_id bigint REFERENCES support.support_agents(id) ON DELETE SET NULL,
    title              text NOT NULL,
    body               text NOT NULL,
    is_shared          boolean NOT NULL DEFAULT true,
    usage_count        bigint NOT NULL DEFAULT 0 CHECK (usage_count >= 0),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz,
    CONSTRAINT macros_tenant_title_uq UNIQUE (tenant_id, title)
);
CREATE INDEX ON support.macros (tenant_id);
CREATE INDEX ON support.macros (created_by_agent_id);

-- ===========================================================================
-- tickets — the core support request. public_id is the opaque external id.
-- requester_user_id is the customer; assignee_agent_id is nullable (unassigned
-- queue) and SET NULL when the agent record is removed.
-- ===========================================================================
CREATE TABLE support.tickets (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id           uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    requester_user_id   bigint NOT NULL REFERENCES identity.users(id),
    assignee_agent_id   bigint REFERENCES support.support_agents(id) ON DELETE SET NULL,
    agent_group_id      bigint REFERENCES support.agent_groups(id) ON DELETE SET NULL,
    sla_policy_id       bigint REFERENCES support.sla_policies(id) ON DELETE SET NULL,
    subject             text NOT NULL,
    status              support.ticket_status NOT NULL DEFAULT 'new',
    priority            support.ticket_priority NOT NULL DEFAULT 'normal',
    channel             support.support_channel NOT NULL DEFAULT 'email',
    first_response_at   timestamptz,
    resolved_at         timestamptz,
    closed_at           timestamptz,
    last_message_at     timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tickets_public_id_key UNIQUE (public_id)
);
CREATE INDEX ON support.tickets (tenant_id);
CREATE INDEX ON support.tickets (requester_user_id);
CREATE INDEX ON support.tickets (assignee_agent_id);
CREATE INDEX ON support.tickets (agent_group_id);
CREATE INDEX ON support.tickets (sla_policy_id);
CREATE INDEX tickets_tenant_status_idx ON support.tickets (tenant_id, status);
CREATE INDEX tickets_open_idx ON support.tickets (tenant_id, priority) WHERE status IN ('new','open','pending','on_hold');

-- ===========================================================================
-- ticket_messages — public replies (customer-visible) and private internal
-- notes (is_public = false). Author is an agent OR the requesting user.
-- ===========================================================================
CREATE TABLE support.ticket_messages (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    ticket_id           bigint NOT NULL REFERENCES support.tickets(id) ON DELETE CASCADE,
    author_user_id      bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    author_agent_id     bigint REFERENCES support.support_agents(id) ON DELETE SET NULL,
    body                text NOT NULL,
    is_public           boolean NOT NULL DEFAULT true,
    channel             support.support_channel,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON support.ticket_messages (tenant_id);
CREATE INDEX ON support.ticket_messages (ticket_id);
CREATE INDEX ON support.ticket_messages (author_user_id);
CREATE INDEX ON support.ticket_messages (author_agent_id);
CREATE INDEX ticket_messages_public_idx ON support.ticket_messages (ticket_id, created_at) WHERE is_public;

-- ===========================================================================
-- ticket_events — IMMUTABLE append-only audit of ticket changes (status flips,
-- reassignment, priority bumps). occurred_at only; no updated_at.
-- ===========================================================================
CREATE TABLE support.ticket_events (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    ticket_id       bigint NOT NULL REFERENCES support.tickets(id) ON DELETE CASCADE,
    actor_user_id   bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    actor_agent_id  bigint REFERENCES support.support_agents(id) ON DELETE SET NULL,
    event_type      text NOT NULL,
    old_value       text,
    new_value       text,
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON support.ticket_events (tenant_id);
CREATE INDEX ON support.ticket_events (ticket_id);
CREATE INDEX ticket_events_ticket_time_idx ON support.ticket_events (ticket_id, occurred_at);

-- ===========================================================================
-- ticket_tags_map — junction tickets × support_tags.
-- ===========================================================================
CREATE TABLE support.ticket_tags_map (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    ticket_id       bigint NOT NULL REFERENCES support.tickets(id) ON DELETE CASCADE,
    support_tag_id  bigint NOT NULL REFERENCES support.support_tags(id) ON DELETE CASCADE,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ticket_tags_map_uq UNIQUE (ticket_id, support_tag_id)
);
CREATE INDEX ON support.ticket_tags_map (tenant_id);
CREATE INDEX ON support.ticket_tags_map (support_tag_id);

-- ===========================================================================
-- sla_breaches — recorded breach of an SLA target on a ticket.
-- ===========================================================================
CREATE TABLE support.sla_breaches (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    ticket_id       bigint NOT NULL REFERENCES support.tickets(id) ON DELETE CASCADE,
    sla_policy_id   bigint REFERENCES support.sla_policies(id) ON DELETE SET NULL,
    breach_kind     text NOT NULL,
    target_at       timestamptz NOT NULL,
    breached_at     timestamptz NOT NULL,
    minutes_over    integer CHECK (minutes_over >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sla_breaches_after_target_chk CHECK (breached_at >= target_at)
);
CREATE INDEX ON support.sla_breaches (tenant_id);
CREATE INDEX ON support.sla_breaches (ticket_id);
CREATE INDEX ON support.sla_breaches (sla_policy_id);

-- ===========================================================================
-- csat_responses — customer satisfaction score (1-5) submitted per ticket.
-- ===========================================================================
CREATE TABLE support.csat_responses (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    ticket_id       bigint NOT NULL REFERENCES support.tickets(id) ON DELETE CASCADE,
    respondent_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    rated_agent_id  bigint REFERENCES support.support_agents(id) ON DELETE SET NULL,
    score           integer NOT NULL CHECK (score BETWEEN 1 AND 5),
    comment         text,
    submitted_at    timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT csat_responses_ticket_uq UNIQUE (ticket_id)
);
CREATE INDEX ON support.csat_responses (tenant_id);
CREATE INDEX ON support.csat_responses (rated_agent_id);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE support.support_agents IS 'Support staff who handle tickets; a support-specific extension of an identity.users record carrying availability and load limits.';
COMMENT ON TABLE support.agent_groups IS 'Named groups of agents used for ticket routing and assignment.';
COMMENT ON TABLE support.sla_policies IS 'Lookup of service-level targets (first-response and resolution minutes), usually keyed by ticket priority.';
COMMENT ON COLUMN support.sla_policies.business_hours_only IS 'When true, SLA timers pause outside the tenant business calendar rather than running 24/7.';
COMMENT ON TABLE support.knowledge_articles IS 'Help-center articles published to customers; soft-deletable via deleted_at.';
COMMENT ON COLUMN support.knowledge_articles.helpful_count IS 'Denormalized count of positive article_feedback rows, kept for fast sorting.';
COMMENT ON TABLE support.macros IS 'Canned reply templates agents insert into ticket messages. Soft-deletable.';
COMMENT ON TABLE support.tickets IS 'Core customer support request. requester_user_id is the customer; assignee_agent_id is the owning agent (null = unassigned queue).';
COMMENT ON COLUMN support.tickets.first_response_at IS 'Timestamp of the first public agent reply, used to measure SLA first-response compliance.';
COMMENT ON TABLE support.ticket_messages IS 'Replies on a ticket: is_public=true are customer-visible, is_public=false are internal agent notes.';
COMMENT ON TABLE support.ticket_events IS 'Immutable append-only audit of ticket changes such as status transitions, reassignment, and priority changes.';
COMMENT ON TABLE support.sla_breaches IS 'Recorded SLA-target breaches on a ticket, with how many minutes the target was missed by.';
COMMENT ON TABLE support.csat_responses IS 'Customer satisfaction rating (1-5) collected after a ticket is resolved; one response per ticket.';
COMMENT ON COLUMN support.csat_responses.rated_agent_id IS 'The agent the customer was rating, captured at submission in case the ticket is later reassigned.';
