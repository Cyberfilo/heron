# Schema map — the cross-module FK contract (221 tables)

This is the authoritative inventory. **Table names and their FK-targetable key columns are
FIXED here.** Module authors own each table's internal columns, constraints, indexes, and
comments — but may only create the tables listed under their module, and may only FK to the
**keys** listed for other modules. This is what lets 12 modules be authored independently and
still compose.

Conventions recap (full detail in `CONVENTIONS.md`): every table has `id bigint GENERATED ALWAYS
AS IDENTITY PRIMARY KEY`; tenant-scoped tables have `tenant_id bigint NOT NULL REFERENCES
identity.tenants(id)`; audit columns `created_at`/`updated_at timestamptz`. "key:" lists the
columns OTHER modules may reference. "T" = tenant-scoped.

Load order = numeric prefix. A module may FK only to **lower-or-equal-numbered** modules; if a
backward dependency is unavoidable, emit it as a trailing `ALTER TABLE ... ADD CONSTRAINT`.

---

## 01 identity  (keys other modules use: `tenants(id)`, `users(id, public_id)`, `teams(id)`, `roles(id)`, `api_keys(id, public_id)`)
- `tenants` — the platform's customer orgs. status `identity.tenant_status`. **NOT tenant-scoped** (it *is* the tenant). key: id, public_id(uuid)
- `tenant_settings` (T) — per-tenant config kv.
- `users` (T) — end users / staff. status `identity.user_status`, email citext. key: id, public_id(uuid)
- `user_profiles` (T) — 1:1 extended profile of users.
- `user_preferences` (T) — per-user UI/notification prefs.
- `roles` (T) — RBAC roles. key: id
- `permissions` — global permission catalog (NOT tenant-scoped). key: id, code(text)
- `role_permissions` (T) — junction roles×permissions.
- `user_roles` (T) — junction users×roles.
- `teams` (T) — sub-org groupings. key: id
- `team_members` (T) — junction teams×users.
- `api_keys` (T) — programmatic creds. status `identity.api_key_status`. key: id, public_id(uuid)
- `personal_access_tokens` (T) — user-owned tokens.
- `sessions` (T) — auth sessions for users.
- `oauth_accounts` (T) — linked external identities.
- `mfa_devices` (T) — TOTP/webauthn devices per user.
- `invitations` (T) — pending user invites. status `identity.invite_status`.
- `password_resets` (T) — reset tokens.
- `service_accounts` (T) — machine principals.
- `login_attempts` (T) — auth attempt log (success/fail).

## 02 geo  (keys: `countries(id, iso2)`, `regions(id)`, `cities(id)`, `currencies(code)`, `locales(code)`, `addresses(id)`)
- `countries` — global. key: id, iso2(char2)
- `regions` — states/provinces, FK country. key: id
- `cities` — FK region. key: id
- `currencies` — **key: code char(3)** (e.g. 'USD'). NOT tenant-scoped.
- `exchange_rates` — currency pair rate by date.
- `locales` — **key: code** (e.g. 'en-US'). NOT tenant-scoped.
- `timezones` — IANA tz catalog.
- `addresses` (T) — postal addresses; FK users(id) nullable, country/region/city. key: id
- `address_validations` (T) — validation attempts on addresses.
- `postal_zones` — shipping/tax zone groupings of postal codes.

## 03 catalog  (keys: `products(id, public_id)`, `product_variants(id, sku)`, `categories(id)`, `brands(id)`, `collections(id)`, `attributes(id)`)
- `brands` (T) — key: id
- `products` (T) — product master. status `catalog.product_status`. key: id, public_id(uuid)
- `product_variants` (T) — sellable SKUs. key: id, sku(text unique per tenant)
- `categories` (T) — hierarchical (parent_id self-FK). key: id
- `category_closure` (T) — ancestor/descendant closure table.
- `product_categories` (T) — junction products×categories.
- `attributes` (T) — attribute definitions. kind `catalog.attribute_kind`. key: id
- `attribute_values` (T) — allowed values for enum attributes.
- `variant_attribute_values` (T) — junction variants×attribute_values.
- `product_media` (T) — images/video; kind `catalog.media_kind`.
- `collections` (T) — merchandising collections. key: id
- `collection_products` (T) — junction.
- `tags` (T) — free tags. key: id
- `product_tags` (T) — junction.
- `product_reviews` (T) — customer reviews; FK products, users; rating int.
- `review_votes` (T) — helpfulness votes on reviews.
- `product_relations` (T) — cross-sell/upsell pairs (product_id, related_product_id).
- `product_bundles` (T) — bundle headers.
- `bundle_items` (T) — bundle components → variants.

## 04 pricing  (keys: `price_lists(id)`, `discounts(id)`, `coupons(id, code)`, `tax_rates(id)`, `promotions(id)`)
- `price_lists` (T) — named price books per currency. key: id
- `prices` (T) — variant price in a price_list/currency (use btree_gist exclusion on overlapping validity).
- `discounts` (T) — discount definitions. kind `pricing.discount_kind`. key: id
- `coupons` (T) — redeemable codes. status `pricing.coupon_status`. key: id, code(text)
- `coupon_redemptions` (T) — uses of a coupon by an order/user.
- `tax_categories` (T) — product tax classes.
- `tax_rates` (T) — rate by tax_category × tax_zone. key: id
- `tax_zones` (T) — geographic tax regions (FK countries/regions/postal_zones).
- `price_rules` (T) — conditional pricing rule headers.
- `price_rule_conditions` (T) — conditions for a price_rule.
- `promotions` (T) — campaign-linked promos. key: id
- `promotion_products` (T) — junction promotions×products.

## 05 inventory  (keys: `warehouses(id)`, `suppliers(id)`, `stock_items(id)`, `purchase_orders(id, public_id)`, `lots(id)`)
- `warehouses` (T) — FK addresses. key: id
- `stock_locations` (T) — bins/zones within a warehouse.
- `suppliers` (T) — vendors. key: id
- `supplier_products` (T) — supplier SKU mapping → variants.
- `stock_items` (T) — on-hand quantity per variant×location. key: id
- `stock_movements` (T) — immutable ledger of qty changes. kind `inventory.movement_kind`.
- `stock_reservations` (T) — soft holds against orders.
- `purchase_orders` (T) — POs to suppliers. status `inventory.po_status`. key: id, public_id(uuid)
- `purchase_order_lines` (T) — PO line items → variants.
- `lots` (T) — batch/lot tracking. key: id
- `serial_numbers` (T) — serialized units → variants/lots.
- `inbound_receipts` (T) — goods-receipt headers vs POs.
- `receipt_lines` (T) — received quantities.
- `stock_adjustments` (T) — manual corrections with reason.

## 06 sales  (keys: `orders(id, public_id)`, `order_items(id)`, `carts(id)`, `fulfillments(id)`, `returns(id)`, `shipments(id)`, `gift_cards(id, code)`)
- `carts` (T) — status `sales.cart_status`; FK users nullable. key: id
- `cart_items` (T) — → variants.
- `orders` (T) — status `sales.order_status`; FK users, billing/shipping addresses, currency. key: id, public_id(uuid)
- `order_items` (T) — → variants; qty, unit_price, totals. key: id
- `order_status_history` (T) — status transitions of an order.
- `order_discounts` (T) — discounts/coupons applied to an order.
- `fulfillments` (T) — status `sales.fulfillment_status`; FK warehouses. key: id
- `fulfillment_items` (T) — → order_items.
- `shipments` (T) — carrier shipments per fulfillment. key: id
- `shipment_tracking` (T) — tracking events.
- `returns` (T) — RMA headers. status `sales.return_status`. key: id
- `return_items` (T) — → order_items.
- `gift_cards` (T) — balance instruments. key: id, code(text)
- `gift_card_transactions` (T) — debits/credits to a gift_card.
- `order_notes` (T) — internal notes on orders.
- `draft_orders` (T) — quotes/draft orders.

## 07 billing  (keys: `payments(id)`, `invoices(id, public_id)`, `plans(id, code)`, `subscriptions(id, public_id)`, `ledger_accounts(id)`, `payment_methods(id)`)
- `billing_profiles` (T) — customer billing entity (tax id, billing email).
- `payment_methods` (T) — kind `billing.payment_method_kind`. key: id
- `payments` (T) — status `billing.payment_status`; FK orders/invoices. key: id
- `payment_attempts` (T) — each gateway attempt for a payment.
- `payment_refunds` (T) — status `billing.refund_status`; FK payments.
- `invoices` (T) — status `billing.invoice_status`. key: id, public_id(uuid)
- `invoice_lines` (T) — invoice line items.
- `credit_notes` (T) — credit memos vs invoices.
- `credit_note_lines` (T)
- `payouts` (T) — money out to the tenant.
- `payout_items` (T) — settled payments in a payout.
- `ledger_accounts` (T) — chart of accounts. key: id
- `ledger_entries` (T) — double-entry lines. direction `billing.ledger_direction`.
- `plans` (T) — subscription products. interval `billing.billing_interval`. key: id, code(text)
- `plan_features` (T) — feature limits per plan.
- `plan_prices` (T) — price points per plan×currency.
- `subscriptions` (T) — status `billing.subscription_status`; FK users/plans. key: id, public_id(uuid)
- `subscription_items` (T) — line items / add-ons of a subscription.
- `usage_records` (T) — metered usage feeding billing.
- `dunning_attempts` (T) — failed-payment retry sequence.
- `tax_registrations` (T) — tenant tax IDs per jurisdiction.
- `wallets` (T) — stored credit balances per user.

## 08 crm  (keys: `accounts(id)`, `contacts(id)`, `opportunities(id)`, `pipelines(id)`, `opportunity_stages(id)`, `leads(id)`)
- `accounts` (T) — B2B accounts (may FK identity.tenants' customers). key: id
- `contacts` (T) — people at accounts. key: id
- `contact_emails` (T) — multiple emails per contact.
- `leads` (T) — status `crm.lead_status`. key: id
- `pipelines` (T) — sales pipelines. key: id
- `opportunity_stages` (T) — ordered stages within a pipeline (lookup). key: id
- `opportunities` (T) — deals in flight; FK pipeline/stage/account. key: id
- `deals` (T) — closed-won contracts.
- `deal_line_items` (T) — → catalog products.
- `activities` (T) — kind `crm.activity_kind`; polymorphic-ish (account/contact/opp).
- `crm_notes` (T) — notes on CRM entities.
- `tasks` (T) — follow-up tasks for reps.
- `account_relationships` (T) — parent/subsidiary links.
- `contact_lists` (T) — static lists.
- `contact_list_members` (T) — junction.

## 09 support  (keys: `tickets(id, public_id)`, `support_agents(id)`, `sla_policies(id)`, `knowledge_articles(id)`)
- `tickets` (T) — status `support.ticket_status`, priority `support.ticket_priority`, channel `support.support_channel`; FK users (requester), support_agents (assignee). key: id, public_id(uuid)
- `ticket_messages` (T) — public/private replies.
- `ticket_events` (T) — audit of ticket changes.
- `support_tags` (T) — tag catalog. 
- `ticket_tags_map` (T) — junction tickets×support_tags.
- `sla_policies` (T) — response/resolution targets (lookup). key: id
- `sla_breaches` (T) — recorded breaches per ticket.
- `macros` (T) — canned responses.
- `support_agents` (T) — agent records (FK users). key: id
- `agent_groups` (T) — teams of agents.
- `agent_group_members` (T) — junction.
- `csat_responses` (T) — satisfaction scores per ticket.
- `knowledge_categories` (T) — KB taxonomy.
- `knowledge_articles` (T) — help-center articles. key: id
- `article_feedback` (T) — thumbs up/down on articles.

## 10 marketing  (keys: `campaigns(id)`, `segments(id)`, `email_templates(id)`, `loyalty_accounts(id)`, `referrals(id)`)
- `campaigns` (T) — status `marketing.campaign_status`. key: id
- `campaign_messages` (T) — per-recipient sends; status `marketing.send_status`.
- `email_templates` (T) — key: id
- `segments` (T) — audience definitions (jsonb rules). key: id
- `segment_members` (T) — materialized membership → users.
- `ab_tests` (T) — status `marketing.experiment_status`.
- `ab_variants` (T) — variants of an ab_test.
- `ab_assignments` (T) — user→variant assignments.
- `attributions` (T) — touch attributions to conversions/orders.
- `referrals` (T) — referral codes. key: id
- `referral_redemptions` (T) — redemptions by new users.
- `loyalty_programs` (T) — program defs.
- `loyalty_accounts` (T) — per-user point balance. key: id
- `loyalty_transactions` (T) — earn/burn ledger.
- `utm_links` (T) — tracked links.
- `landing_pages` (T) — campaign landing pages.

## 11 analytics  (keys: `web_sessions(id)`, `experiments(id)`, `funnels(id)`, `cohorts(id)`)
- `events` (T) — **the big fact table**; jsonb properties, FK users/web_sessions nullable, event_name text, occurred_at. (bench scale ~10M rows)
- `web_sessions` (T) — analytics sessions (distinct from identity.sessions). key: id
- `page_views` (T) — → web_sessions.
- `device_profiles` (T) — browser/device fingerprints.
- `feature_usage` (T) — product feature adoption counters.
- `experiments` (T) — product experiments. key: id
- `experiment_variants` (T)
- `experiment_assignments` (T) — user→variant.
- `funnels` (T) — funnel definitions. key: id
- `funnel_steps` (T)
- `cohorts` (T) — key: id
- `cohort_members` (T) — junction → users.
- `metrics_daily` (T) — pre-aggregated daily metrics per tenant.
- `kpi_snapshots` (T) — periodic KPI captures.

## 12 comms  (keys: `notifications(id)`, `message_threads(id)`, `webhooks(id)`, `notification_templates(id)`)
- `notifications` (T) — status `comms.notification_status`; FK users. key: id
- `notification_preferences` (T) — per-user channel opt-in.
- `notification_templates` (T) — key: id
- `message_threads` (T) — in-app threads. key: id
- `thread_messages` (T) — direction `comms.message_direction`.
- `webhooks` (T) — subscriber endpoints. key: id
- `webhook_deliveries` (T) — status `comms.delivery_status`.
- `email_log` (T) — outbound email record.
- `sms_log` (T) — outbound sms record.
- `push_tokens` (T) — device push tokens per user.
- `unsubscribes` (T) — suppression list.
- `contact_channels` (T) — verified channels (email/phone) per user.

## 13 audit  (keys: `audit_log(id)`, `data_subject_requests(id)`, `retention_policies(id)`)
- `audit_log` (T) — action `audit.audit_action`; actor_user_id FK users; entity ref by (schema,table,row_id). key: id
- `change_history` (T) — column-level before/after diffs (jsonb).
- `access_log` (T) — read-access records for sensitive data.
- `data_exports` (T) — GDPR/export jobs.
- `consent_records` (T) — status `audit.consent_status`; per-user consents.
- `compliance_events` (T) — flagged compliance incidents.
- `data_subject_requests` (T) — DSAR/erasure requests. key: id
- `retention_policies` (T) — per-entity retention rules. key: id
- `legal_holds` (T) — holds suspending deletion.
- `audit_log_archive` (T) — cold archive of old audit rows.

## 14 ops  (keys: `feature_flags(id, key)`, `integrations(id)`, `files(id)`, `jobs(id)`, `import_batches(id)`)
- `feature_flags` (T) — kind `ops.flag_kind`. key: id, key(text)
- `feature_flag_rules` (T) — targeting rules (jsonb).
- `feature_flag_overrides` (T) — per-user/tenant overrides.
- `settings` (T) — typed settings kv.
- `jobs` (T) — background job defs. key: id
- `job_runs` (T) — status `ops.job_status`; executions of a job.
- `integrations` (T) — status `ops.integration_status`; 3rd-party connections. key: id
- `integration_syncs` (T) — sync runs.
- `files` (T) — uploaded file metadata (blob in object storage). key: id
- `file_versions` (T) — version chain of a file.
- `import_batches` (T) — status `ops.import_status`; bulk imports. key: id
- `import_errors` (T) — per-row import failures.
- `scheduled_tasks` (T) — cron-like schedules.
- `system_health_checks` (T) — periodic health probes.
- `rate_limits` (T) — per-tenant/key quotas.
- `secrets_vault` (T) — references to secret material (never plaintext).
