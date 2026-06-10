-- 00_extensions.sql
-- Runs first. Creates extensions, the 14 domain schemas, and ALL shared enum
-- types (centralized here so the 14 module files can reference them in any
-- order without racing to define them). See schema/CONVENTIONS.md.
--
-- Target: PostgreSQL 16+. gen_random_uuid() is in core; we still enable
-- pgcrypto for compatibility. citext = case-insensitive emails. btree_gist =
-- exclusion constraints on overlapping ranges (used for prices/subscriptions).

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------------
-- Schemas (domain namespaces). Load order of module files = numeric prefix.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS identity;   -- tenants, users, roles, sessions, teams
CREATE SCHEMA IF NOT EXISTS geo;        -- countries, currencies, fx, locales, addresses
CREATE SCHEMA IF NOT EXISTS catalog;    -- products, variants, categories, brands, media
CREATE SCHEMA IF NOT EXISTS pricing;    -- price lists, prices, discounts, coupons, tax
CREATE SCHEMA IF NOT EXISTS inventory;  -- warehouses, stock, movements, suppliers, POs
CREATE SCHEMA IF NOT EXISTS sales;      -- carts, orders, items, fulfillments, returns
CREATE SCHEMA IF NOT EXISTS billing;    -- payments, refunds, invoices, subscriptions, ledger
CREATE SCHEMA IF NOT EXISTS crm;        -- accounts, contacts, leads, opportunities, deals
CREATE SCHEMA IF NOT EXISTS support;    -- tickets, messages, SLAs, agents, CSAT, KB
CREATE SCHEMA IF NOT EXISTS marketing;  -- campaigns, segments, A/B tests, referrals, loyalty
CREATE SCHEMA IF NOT EXISTS analytics;  -- events (big fact), web sessions, experiments, metrics
CREATE SCHEMA IF NOT EXISTS comms;      -- notifications, webhooks, email/sms logs, threads
CREATE SCHEMA IF NOT EXISTS audit;      -- audit log, change history, access log, consent
CREATE SCHEMA IF NOT EXISTS ops;        -- feature flags, settings, jobs, integrations, files

-- ---------------------------------------------------------------------------
-- Shared enum types. Declared in their domain schema. Modules USE these but do
-- not (re)declare them. Lookup *tables* (plans, opportunity_stages, sla_policies,
-- tax_rates, ...) live in their module files, not here.
-- ---------------------------------------------------------------------------

-- identity
CREATE TYPE identity.user_status      AS ENUM ('active','invited','suspended','deactivated');
CREATE TYPE identity.tenant_status    AS ENUM ('trial','active','past_due','suspended','churned');
CREATE TYPE identity.api_key_status   AS ENUM ('active','revoked','expired');
CREATE TYPE identity.invite_status    AS ENUM ('pending','accepted','expired','revoked');

-- catalog
CREATE TYPE catalog.product_status    AS ENUM ('draft','active','archived');
CREATE TYPE catalog.media_kind        AS ENUM ('image','video','document','model_3d');
CREATE TYPE catalog.attribute_kind    AS ENUM ('text','number','boolean','enum','color','dimension');

-- pricing
CREATE TYPE pricing.discount_kind     AS ENUM ('percentage','fixed_amount','free_shipping','bogo');
CREATE TYPE pricing.coupon_status     AS ENUM ('active','scheduled','expired','disabled');

-- inventory
CREATE TYPE inventory.movement_kind   AS ENUM ('receipt','shipment','adjustment','transfer','return','cycle_count');
CREATE TYPE inventory.po_status       AS ENUM ('draft','submitted','partially_received','received','cancelled');

-- sales
CREATE TYPE sales.cart_status         AS ENUM ('active','converted','abandoned','merged');
CREATE TYPE sales.order_status        AS ENUM ('pending','confirmed','paid','partially_fulfilled','fulfilled','cancelled','refunded');
CREATE TYPE sales.fulfillment_status  AS ENUM ('pending','picked','packed','shipped','delivered','returned');
CREATE TYPE sales.return_status       AS ENUM ('requested','approved','received','refunded','rejected');

-- billing
CREATE TYPE billing.payment_status        AS ENUM ('pending','authorized','captured','failed','voided','refunded','partially_refunded');
CREATE TYPE billing.payment_method_kind   AS ENUM ('card','bank_transfer','paypal','wallet','wire','credit');
CREATE TYPE billing.invoice_status        AS ENUM ('draft','open','paid','void','uncollectible','past_due');
CREATE TYPE billing.subscription_status   AS ENUM ('trialing','active','past_due','canceled','paused','incomplete');
CREATE TYPE billing.refund_status         AS ENUM ('pending','succeeded','failed','cancelled');
CREATE TYPE billing.ledger_direction      AS ENUM ('debit','credit');
CREATE TYPE billing.billing_interval      AS ENUM ('day','week','month','quarter','year');

-- crm
CREATE TYPE crm.lead_status           AS ENUM ('new','contacted','qualified','unqualified','converted');
CREATE TYPE crm.activity_kind         AS ENUM ('call','email','meeting','note','task');

-- support
CREATE TYPE support.ticket_status     AS ENUM ('new','open','pending','on_hold','solved','closed');
CREATE TYPE support.ticket_priority   AS ENUM ('low','normal','high','urgent');
CREATE TYPE support.support_channel   AS ENUM ('email','chat','phone','web','social','api');

-- marketing
CREATE TYPE marketing.campaign_status AS ENUM ('draft','scheduled','sending','sent','paused','archived');
CREATE TYPE marketing.send_status     AS ENUM ('queued','sent','delivered','opened','clicked','bounced','complained','failed','unsubscribed');
CREATE TYPE marketing.experiment_status AS ENUM ('draft','running','paused','completed','archived');

-- comms
CREATE TYPE comms.notification_status AS ENUM ('queued','sent','delivered','read','failed');
CREATE TYPE comms.delivery_status     AS ENUM ('pending','success','failed','retrying');
CREATE TYPE comms.message_direction   AS ENUM ('inbound','outbound');

-- audit
CREATE TYPE audit.consent_status      AS ENUM ('granted','withdrawn','expired');
CREATE TYPE audit.audit_action        AS ENUM ('create','update','delete','login','logout','export','access_denied');

-- ops
CREATE TYPE ops.job_status            AS ENUM ('queued','running','succeeded','failed','cancelled','retrying');
CREATE TYPE ops.integration_status    AS ENUM ('connected','disconnected','error','syncing');
CREATE TYPE ops.import_status         AS ENUM ('pending','processing','completed','failed','partially_failed');
CREATE TYPE ops.flag_kind             AS ENUM ('boolean','multivariate','percentage_rollout');
