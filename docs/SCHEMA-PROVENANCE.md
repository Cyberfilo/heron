# Schema provenance — what RECOGNIZED open-source schemas each domain mirrors

**Purpose.** Our benchmark is a single multi-tenant B2B SaaS commerce Postgres 16 schema
(~221 FK-linked tables, 14 domains). For it to be *recognized and trusted* by reviewers, its
table/column **shape** should echo schemas they already know from production open-source
software, not be invented from whole cloth. This file maps each of our 14 domains to 1–3
recognized reference schemas, records each reference's **exact license** (verified against the
repo's LICENSE file or official docs, June 2026), and lists the **signature tables/columns** we
should echo so the structure is instantly familiar.

**Research date:** June 2026. Every license below was checked against the actual repo LICENSE
file or official documentation this session; URLs cited per row. Licenses change (Spree, Vendure
and several CRMs re-licensed mid-life) — re-verify before relying on any figure.

> **READ THE "HOW TO BORROW SAFELY" SECTION (§16) BEFORE WRITING ANY DDL.** Several of the best
> shape references are **GPL/AGPL** (Vendure, Spree ≥4.10, Twenty, EspoCRM, SuiteCRM, Lago,
> Listmonk, FreeScout, Zammad, Mautic). We may mirror their *conceptual shapes and table names*
> (facts, not copyrightable) but must **never paste their DDL/migration files**. The permissive
> references (Saleor BSD-3, Medusa MIT, Sylius MIT, Kill Bill Apache-2.0, Keycloak Apache-2.0,
> PostHog MIT, Chatwoot MIT, Pagila PostgreSQL-license, AdventureWorks MIT) are the safe ones to
> read closely and adapt from.

---

## License legend (used throughout)

| Bucket | Licenses | Rule for us |
|---|---|---|
| **PERMISSIVE — safe to read & adapt DDL** | MIT, BSD-2/3-Clause, Apache-2.0, PostgreSQL License | Can study schema files closely; author our own DDL; attribute as courtesy. |
| **COPYLEFT — shape/names only, NO DDL copy** | GPL-3.0, AGPL-3.0 | Mirror *concepts and table names* (facts). Do **not** copy `CREATE TABLE`/migration text. Don't open their schema files side-by-side with our editor and transcribe. |
| **DOCS/PROPRIETARY — reference the public data model only** | Stripe / Salesforce / Zendesk / Shopify dev docs | Public API object models are reference facts; echo object→table names. No code to copy anyway. |

---

## 01 — identity / auth / RBAC

| Reference | URL | License (verified) | Approx model count | Signature tables/columns to echo |
|---|---|---|---|---|
| **Keycloak** (DB schema) | https://github.com/keycloak/keycloak | **Apache-2.0** ✅ (LICENSE.txt; codebase is ASL-2.0, ships no GPL libs) | ~90 tables in its Liquibase schema | `realm` (→ our `tenants`), `user_entity` (→ `users`), `client`, `keycloak_role` (→ `roles`), `user_role_mapping` (→ `user_roles`), `credential`, `user_session`, `client_scope`, `realm_attribute`, `federated_identity` (→ `oauth_accounts`) |
| **Django `auth` / Rails Devise** (canonical web-auth shape) | https://docs.djangoproject.com/en/stable/topics/auth/ | Django = **BSD-3-Clause** ✅; Devise = **MIT** ✅ | ~6 core tables | `auth_user(username,email,password,is_active,last_login,date_joined)`, `auth_group`(roles), `auth_permission`, `auth_user_groups`, `auth_group_permissions` — the classic users/groups/permissions triad we mirror with `users`/`roles`/`permissions`/`user_roles`/`role_permissions` |
| **Auth0 / Ory Kratos** (identity model, docs) | https://www.ory.sh/docs/kratos | Ory Kratos = **Apache-2.0** ✅ | n/a (identity traits) | `identities`, `identity_credentials`, `sessions`, `identity_verifiable_addresses` — informs our `sessions`, `mfa_devices`, `personal_access_tokens`, `login_attempts` |

**Our domain has 20 tables** (`tenants`, `users`, `user_profiles`, `roles`, `permissions`,
`role_permissions`, `user_roles`, `teams`, `api_keys`, `sessions`, `oauth_accounts`,
`mfa_devices`, `invitations`, `login_attempts`, …). Keycloak is the recognized anchor; Django/Devise
gives the universally-recognized RBAC junction shape. **All three references are permissive.**

---

## 02 — geo (countries/regions/cities/currencies/addresses)

| Reference | URL | License | Approx count | Signature tables/columns |
|---|---|---|---|---|
| **Pagila / Sakila** geo subset | https://github.com/devrimgunduz/pagila | **PostgreSQL License** ✅ (permissive, BSD-like) | `country`, `city`, `address` | `country(country_id,country)`, `city(city_id,city,country_id)`, `address(address_id,address,district,city_id,postal_code,phone)` — the canonical normalized geo chain everyone recognizes |
| **Saleor `account`/`shipping`** | https://github.com/saleor/saleor | **BSD-3-Clause** ✅ | several | `Address(first_name,last_name,company_name,street_address_1,city,postal_code,country)`, `ShippingZone`, `Warehouse` — informs our `addresses`, `postal_zones` |
| **ISO 3166 / CLDR reference data** | https://en.wikipedia.org/wiki/ISO_3166-1 | Public standard (facts) | — | `iso2 char(2)`, `iso3`, currency `code char(3)` (ISO 4217), locale `code` (BCP-47) — our `currencies.code`, `countries.iso2`, `locales.code` follow the standards |

Geo is mostly **reference data shaped by ISO standards** — uncopyrightable facts. Pagila (permissive)
is the recognized normalized layout to echo. **All permissive.**

---

## 03 — catalog (products/variants/categories/brands/attributes)

| Reference | URL | License (verified) | Approx model count | Signature tables/columns |
|---|---|---|---|---|
| **Saleor** (`product` app) | https://github.com/saleor/saleor | **BSD-3-Clause** ✅ (copyright Saleor Commerce / Mirumee) | ~40 product-domain models | `Product`, `ProductType`, `ProductVariant(sku)`, `Category(parent, lft/rght/tree_id — MPTT)`, `Collection`, `Attribute`, `AttributeValue`, `ProductMedia` — the recognized headless-commerce catalog shape we mirror with `products`/`product_variants(sku)`/`categories`/`attributes`/`collections` |
| **Medusa.js** (commerce modules) | https://github.com/medusajs/medusa | **MIT** ✅ | dozens of entities | `product`, `product_variant`, `product_option`, `product_category`, `product_collection`, `product_tag`, `image` — MIT, safest to read closely |
| **Sylius** | https://github.com/Sylius/Sylius | **MIT** ✅ (core; docs confirm MIT) | many entities | `Product`, `ProductVariant`, `Taxon` (categories), `ProductAttribute`, `Channel` — MIT, B2B-friendly |
| **Vendure** | https://github.com/vendure-ecommerce/vendure | **GPL-3.0** ⚠️ (re-licensed MIT→GPLv3 during 2.x) | many entities | `Product`, `ProductVariant`, `Collection`, `FacetValue` — **shape/names only; do NOT copy DDL** |

**Pick Saleor (BSD-3) as the primary catalog anchor** — it is the most-recognized open Postgres
commerce schema and is permissive. Medusa/Sylius (MIT) corroborate. **Vendure is GPL — names only.**

---

## 04 — pricing (price lists / tiers / promotions / tax)

| Reference | URL | License | Signature tables/columns |
|---|---|---|---|
| **Saleor** (`discount`/`channel`) | https://github.com/saleor/saleor | **BSD-3-Clause** ✅ | `ChannelListing` (per-channel price), `Sale`, `Voucher`, `VoucherCode`, `PriceList` — informs our `price_lists`, `price_list_items`, `promotions`, `coupons` |
| **Medusa** (pricing module) | https://github.com/medusajs/medusa | **MIT** ✅ | `price_set`, `price`, `price_list`, `price_rule`, `money_amount(currency_code,amount,min_quantity,max_quantity)` — the recognized multi-currency tiered-price shape |
| **Stripe** (Product/Price, docs) | https://docs.stripe.com/api/prices/object | Docs (reference only) | `Price(unit_amount,currency,billing_scheme,tiers,recurring)`, `Product` — echo for our list-price/tier columns |

**Saleor + Medusa (both permissive)** are the pricing anchors. Stripe's Price object is the
recognized vocabulary for tiered/graduated pricing.

---

## 05 — inventory (stock / warehouses / movements)

| Reference | URL | License | Signature tables/columns |
|---|---|---|---|
| **Medusa** (inventory module) | https://github.com/medusajs/medusa | **MIT** ✅ | `inventory_item`, `inventory_level(stocked_quantity,reserved_quantity,location_id)`, `reservation_item`, `stock_location` — the recognized reservation-aware inventory shape |
| **Saleor** (`warehouse`) | https://github.com/saleor/saleor | **BSD-3-Clause** ✅ | `Warehouse`, `Stock(quantity, warehouse, product_variant)`, `Allocation`, `PreorderAllocation` — informs `warehouses`, `stock_items`, `stock_movements`, `allocations` |
| **AdventureWorks** (`Production`) | https://github.com/microsoft/sql-server-samples | **MIT** ✅ | `Production.ProductInventory(LocationID,Shelf,Bin,Quantity)`, `Production.Location` — classic, widely-taught inventory layout |

All three permissive. **Medusa's `inventory_level` (stocked vs reserved) is the modern shape;
AdventureWorks is the recognizable classic.**

---

## 06 — sales (carts / orders / order items / fulfillments / returns)

| Reference | URL | License (verified) | Signature tables/columns |
|---|---|---|---|
| **Saleor** (`order`/`checkout`) | https://github.com/saleor/saleor | **BSD-3-Clause** ✅ | `Order(status,total_gross,total_net,user,channel)`, `OrderLine(quantity,unit_price)`, `Checkout`, `CheckoutLine`, `Fulfillment`, `FulfillmentLine` — the recognized headless order model |
| **Medusa** (order module) | https://github.com/medusajs/medusa | **MIT** ✅ | `order`, `order_line_item`, `cart`, `line_item`, `fulfillment`, `return`, `order_change` — MIT, read closely |
| **Pagila/Sakila** | https://github.com/devrimgunduz/pagila | **PostgreSQL License** ✅ | `rental`, `payment`, `inventory` — the universally-recognized "order/transaction" skeleton |
| **AdventureWorks** (`Sales`) | https://github.com/microsoft/sql-server-samples | **MIT** ✅ | `Sales.SalesOrderHeader`, `Sales.SalesOrderDetail(OrderQty,UnitPrice,LineTotal)`, `Sales.Customer` — the canonical header/detail split reviewers expect |

**Saleor (BSD) + AdventureWorks (MIT)** anchor the order header/detail split. Our
`orders`/`order_items`/`carts`/`cart_items`/`fulfillments`/`returns` mirror this directly.

---

## 07 — billing / subscriptions / invoices

| Reference | URL | License (verified) | Signature tables/columns |
|---|---|---|---|
| **Kill Bill** | https://github.com/killbill/killbill | **Apache-2.0** ✅ (LICENSE = Apache v2) | ~30+ tables | `accounts`, `subscriptions`, `subscription_events`, `invoices`, `invoice_items`, `payments`, `payment_methods`, `catalog`, `bundles` — the recognized OSS subscription-billing schema, **permissive** |
| **Stripe Billing** (data model, docs) | https://docs.stripe.com/api/subscriptions/object | Docs (reference only) | object model | `Customer`, `Subscription(status,current_period_end,items[])`, `SubscriptionItem`, `Invoice(amount_due,status,period_start)`, `InvoiceItem`, `Price`, `Charge` — the de-facto vocabulary; our `subscriptions`/`subscription_items`/`invoices`/`invoice_line_items`/`charges` echo it |
| **Lago** | https://github.com/getlago/lago | **AGPL-3.0** ⚠️ | many | `customers`, `subscriptions`, `plans`, `charges`, `invoices`, `fees`, `billable_metrics`, `events` (usage) — modern usage-based shape, **names/concepts only — NO DDL copy** |

**Anchor on Kill Bill (Apache-2.0, copyable shape) + Stripe object names (the recognized
vocabulary).** Lago is the best *usage-based metering* shape but is **AGPL — mirror concepts only.**

---

## 08 — crm (accounts / contacts / leads / opportunities / activities)

| Reference | URL | License (verified) | Signature tables/columns |
|---|---|---|---|
| **Salesforce** standard object model (docs) | https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/ | Docs (reference only) | objects | `Account`, `Contact`, `Lead`, `Opportunity(StageName,Amount,CloseDate)`, `Campaign`, `Activity`/`Task`, `Case` — the **industry-standard CRM vocabulary** reviewers expect; copy the *names/shapes* (facts) |
| **Twenty** | https://github.com/twentyhq/twenty | **AGPL-3.0** ⚠️ | standard objects | `company`, `person`, `opportunity`, `note`, `task`, `activity`, `pipeline_step` — modern OSS CRM; **shape/names only, no DDL** |
| **EspoCRM** | https://github.com/espocrm/espocrm | **AGPL-3.0** ⚠️ (moved GPLv3→AGPLv3) | many | `account`, `contact`, `lead`, `opportunity`, `case`, `activity`, `email` — **shape/names only** |
| **SuiteCRM** | https://github.com/salesagility/SuiteCRM | **AGPL-3.0** ⚠️ | many | `accounts`, `contacts`, `leads`, `opportunities`, `campaigns` — **shape/names only** |

**Salesforce's public object model is the recognized vocabulary** and is the safest provenance to
cite (it's docs/facts, nothing to copy). Twenty/EspoCRM/SuiteCRM are all **AGPL — names/concepts
only.** Our `accounts`/`contacts`/`leads`/`opportunities`/`crm_activities` follow the Salesforce shape.

---

## 09 — support / helpdesk (tickets / conversations / messages / SLAs)

| Reference | URL | License (verified) | Signature tables/columns |
|---|---|---|---|
| **Chatwoot** | https://github.com/chatwoot/chatwoot | **MIT** ✅ (community edition LICENSE = MIT/Expat) | many | `conversations`, `contacts`, `inboxes`, `messages(content,message_type,content_type)`, `contact_inboxes(source_id)`, `teams`, `labels` — **permissive, the safest helpdesk shape to read closely** |
| **Zendesk** data model (docs) | https://developer.zendesk.com/api-reference/ticketing/tickets/tickets/ | Docs (reference only) | objects | `Ticket(status,priority,requester_id,assignee_id,group_id)`, `Comment`, `User`, `Organization`, `SLAPolicy` — the recognized vocabulary for `tickets`/`ticket_messages`/`sla_policies` |
| **FreeScout** | https://github.com/freescout-helpdesk/freescout | **AGPL-3.0** ⚠️ | ~30 tables | `conversations`, `threads`, `mailboxes`, `customers`, `users` (Help Scout clone) — **shape/names only** |
| **Zammad** | https://github.com/zammad/zammad | **AGPL-3.0** ⚠️ | many | `tickets`, `ticket_articles`, `groups`, `sla`, `organizations` — **shape/names only** |

**Anchor on Chatwoot (MIT — copyable shape) + Zendesk vocabulary (recognized).** FreeScout/Zammad
are AGPL — concepts only. Our `tickets`/`ticket_messages`/`ticket_events`/`sla_policies` mirror this.

---

## 10 — marketing / loyalty (campaigns / segments / coupons / points)

| Reference | URL | License (verified) | Signature tables/columns |
|---|---|---|---|
| **Listmonk** | https://github.com/knadh/listmonk | **AGPL-3.0** ⚠️ (schema.sql is AGPL) | ~15 tables | `subscribers(uuid,email,attribs jsonb,status)`, `lists(type,optin)`, `campaigns(status,sent,to_send)`, `subscriber_lists`, `campaign_views`, `link_clicks` — clean email-marketing shape; **concepts/names only** |
| **Mautic** | https://github.com/mautic/mautic | **GPL-3.0** ⚠️ (core; some AGPL components) | many | `leads`(contacts), `campaigns`, `campaign_events`, `email_stats`, `lead_lists`(segments), `points`, `lead_points_change_log` — marketing-automation + **loyalty points** shape; **concepts/names only** |
| **Saleor** (`discount`) | https://github.com/saleor/saleor | **BSD-3-Clause** ✅ | several | `Voucher`, `VoucherCode`, `GiftCard`, `Promotion` — **permissive** source for our `coupons`/`gift_cards`/`loyalty_*` |

Marketing's best shape references (Listmonk, Mautic) are **copyleft — names/concepts only.** For
anything we want to read closely, lean on **Saleor's discount/giftcard tables (BSD)**. Our
`campaigns`/`segments`/`coupons`/`loyalty_accounts`/`loyalty_transactions` mirror the Mautic+Saleor shapes.

---

## 11 — analytics / events (event stream / sessions / funnels)

| Reference | URL | License (verified) | Signature tables/columns |
|---|---|---|---|
| **Snowplow canonical event model** | https://docs.snowplow.io/docs/fundamentals/canonical-event/ + https://github.com/snowplow/snowplow | **Apache-2.0** ✅ (snowplow core) | 131-field `atomic.events` (89 in use) | `event_id(uuid)`, `app_id`, `collector_tstamp`, `dvce_created_tstamp`, `event_name`, `domain_userid`, `domain_sessionid`, `page_url`, `geo_country` — **the canonical wide-event schema**; permissive |
| **PostHog** | https://github.com/PostHog/posthog | **MIT** ✅ (self-hosted is MIT; some Cloud features under separate license) | events + persons | `events(event,distinct_id,properties jsonb,timestamp,person_id)`, `persons(properties jsonb)`, `person_distinct_ids`, `groups` — the recognized product-analytics shape; **permissive** |
| **Segment** spec (docs) | https://segment.com/docs/connections/spec/ | Spec (reference only) | track/identify/page | `track(event,userId,properties,timestamp)`, `identify(traits)`, `page`, `group` — the recognized event taxonomy vocabulary |

**Anchor on Snowplow's canonical `atomic.events` (Apache-2.0) for column names + PostHog (MIT) for
the `events`/`persons` split.** Both permissive. Our `events`/`event_properties`/`sessions`/`page_views`
mirror these — this is the domain that drives the "millions of rows" fact table.

---

## 12 — comms (notifications / emails / templates / delivery logs)

| Reference | URL | License (verified) | Signature tables/columns |
|---|---|---|---|
| **Listmonk** | https://github.com/knadh/listmonk | **AGPL-3.0** ⚠️ | several | `campaigns`, `bounces`, `media`, `templates` — email send/delivery shape; **concepts only** |
| **Chatwoot** (notifications) | https://github.com/chatwoot/chatwoot | **MIT** ✅ | several | `notifications`, `notification_settings`, `messages`, `webhooks` — **permissive**, copyable |
| **Twilio/SendGrid** event vocab (docs) | https://www.twilio.com/docs/sendgrid/for-developers/tracking-events/event | Docs (reference only) | event types | delivery events `processed/delivered/bounce/open/click/spamreport` — the recognized message-delivery status vocabulary for our `message_deliveries.status` |

**Anchor on Chatwoot (MIT) for notification/webhook tables** + Twilio/SendGrid's delivery-event
vocabulary (facts). Our `notifications`/`email_templates`/`message_deliveries`/`webhook_deliveries` follow these.

---

## 13 — audit (audit log / change history / access log)

| Reference | URL | License (verified) | Signature tables/columns |
|---|---|---|---|
| **pgAudit / Postgres audit-trigger** patterns | https://github.com/pgaudit/pgaudit ; https://wiki.postgresql.org/wiki/Audit_trigger_91plus | pgAudit = **PostgreSQL License** ✅; wiki trigger = public/CC | `audit.logged_actions(event_id,table_name,action,row_data,changed_fields,transaction_id,client_addr,action_tstamp_tx)` — the canonical Postgres audit-trigger table everyone recognizes; **permissive** |
| **Rails `audited` / `paper_trail` gems** | https://github.com/paper-trail-gem/paper_trail | **MIT** ✅ | `versions` | `versions(item_type,item_id,event,whodunnit,object jsonb,object_changes jsonb,created_at)` — the recognized app-level change-history shape; **permissive** |
| **Django `LogEntry`** | https://docs.djangoproject.com/en/stable/ref/contrib/admin/ | **BSD-3-Clause** ✅ | `django_admin_log` | `django_admin_log(action_time,user_id,content_type_id,object_id,action_flag,change_message)` — recognized admin audit shape |

All **permissive**. Our `audit_log`/`change_history`/`access_log` mirror the pgAudit `logged_actions`
trigger shape + paper_trail `versions` shape.

---

## 14 — ops (jobs / feature flags / settings / webhooks / API usage)

| Reference | URL | License (verified) | Signature tables/columns |
|---|---|---|---|
| **Sidekiq / `solid_queue` / `good_job`** (job tables) | https://github.com/rails/solid_queue | **MIT** ✅ | job tables | `solid_queue_jobs(queue_name,class_name,arguments,scheduled_at,finished_at)`, `solid_queue_failed_executions` — recognized background-job shape for our `jobs`/`job_runs` |
| **Unleash / Flipper** (feature flags) | https://github.com/Unleash/unleash | Unleash = **Apache-2.0** ✅; Flipper = **MIT** ✅ | flag tables | `features(name,enabled,strategy)`, `feature_strategies`, `flipper_features`, `flipper_gates` — recognized feature-flag shape for our `feature_flags`/`feature_flag_rules` |
| **Svix / standard webhook** model | https://github.com/svix/svix-webhooks | **MIT** ✅ | webhook tables | `endpoint`, `message`, `message_attempt(status,response_status_code,timestamp)` — recognized webhook-delivery shape for `webhooks`/`webhook_deliveries` |

All **permissive**. Ops is a grab-bag mirroring well-known infra tables (jobs, flags, webhooks, settings).

---

## 15 — multi-tenancy encoding (cross-cutting, all domains)

How real SaaS encodes the tenant boundary — the pattern our `tenant_id bigint NOT NULL REFERENCES
identity.tenants(id)` on every tenant-scoped table follows:

| Reference | URL | License | What we mirror |
|---|---|---|---|
| **Citus multi-tenant guide** | https://docs.citusdata.com/en/stable/use_cases/multi_tenant.html ; https://docs.citusdata.com/en/stable/sharding/data_modeling.html | Citus = **AGPL-3.0** (engine) ⚠️; **docs are the reference** (facts) | A single `tenant_id`/`company_id` **distribution column on every table**; small cross-tenant tables (`countries`, `currencies`, `permissions`) modeled as **reference tables** (our NOT-tenant-scoped tables); **PK/FK must include the tenant column** for co-location. This is exactly our SCHEMA-MAP convention: `(T)` tables carry `tenant_id`; `tenants`, `countries`, `currencies`, `locales`, `permissions` are global. |
| **Apartment / acts_as_tenant (Rails), django-tenants** | https://github.com/ErwinM/acts_as_tenant ; https://github.com/django-tenant-schemas/django-tenant-schemas | acts_as_tenant = **MIT** ✅ | The shared-DB, `tenant_id`-column ("row-level") multi-tenancy pattern (vs schema-per-tenant) — we chose the shared-DB/`tenant_id` form, the most common production SaaS shape |

The Citus guide is the **recognized authority** for the row-level `tenant_id` pattern; cite it as
the provenance for our multi-tenancy. (The Citus *engine* is AGPL, but we copy no code — only the
documented data-modeling pattern, which is a fact.)

---

## 16 — HOW TO BORROW SAFELY (read before writing DDL)

**Table names and column names are facts; verbatim DDL/migration files are copyrightable code.**
Our rule, in one paragraph: **author 100% original DDL.** For every table, write fresh
`CREATE TABLE` statements that follow our own `CONVENTIONS.md` (every table `id bigint GENERATED
ALWAYS AS IDENTITY`, tenant-scoped tables carry `tenant_id`, `created_at`/`updated_at timestamptz`,
our naming + enum conventions). Use the references **only to decide which tables exist and what they
are roughly called** — the *shape* — so a reviewer recognizes "ah, that's the Saleor/Stripe/Salesforce
layout." You may read **permissive** schemas (Saleor BSD-3, Medusa MIT, Sylius MIT, Kill Bill
Apache-2.0, Keycloak Apache-2.0, Chatwoot MIT, PostHog MIT, Pagila PostgreSQL-license, AdventureWorks
MIT, Snowplow Apache-2.0) closely and adapt freely, keeping a NOTICE/attribution line as courtesy.
For **GPL/AGPL** references (Vendure, Spree ≥4.10, Twenty, EspoCRM, SuiteCRM, Lago, Listmonk, Mautic,
FreeScout, Zammad, Citus engine) **do not open their schema/migration files and transcribe** —
take only the conceptual entity list and standard names (which are also the same names the
permissive projects and the vendor docs use, so there is independent, non-copyleft provenance for
every name we adopt). **Never paste a GPL/AGPL schema file into this repo.** When in doubt, derive
the name from the **docs/vendor object model** (Stripe, Salesforce, Zendesk, Segment, ISO standards)
— those are pure facts. Cite all references in a `PROVENANCE`/`NOTICE` section of the repo so the
lineage is transparent and auditable.

Practically: prefer the permissive anchor per domain as the schema you *read*; use the copyleft and
docs references only to *cross-check the entity list and names*. Because every signature name below
appears in at least one permissive source or vendor doc, we never need a copyleft file as the sole
provenance for anything.

---

## 17 — RECOMMENDED PROVENANCE MAPPING (domain → chosen reference[s])

| # | Domain | Primary anchor (read & adapt) | Corroborating refs (names/concepts) | License posture |
|---|---|---|---|---|
| 01 | identity / RBAC | **Keycloak** (Apache-2.0) | Django auth (BSD), Ory Kratos (Apache) | all permissive ✅ |
| 02 | geo | **Pagila/Sakila** (PostgreSQL Lic) | ISO 3166/4217 (facts), Saleor (BSD) | all permissive ✅ |
| 03 | catalog | **Saleor** (BSD-3) | Medusa (MIT), Sylius (MIT); Vendure names-only (GPL) | anchor permissive ✅ |
| 04 | pricing | **Medusa** (MIT) + **Saleor** (BSD) | Stripe Price (docs) | anchor permissive ✅ |
| 05 | inventory | **Medusa** (MIT) | Saleor (BSD), AdventureWorks (MIT) | all permissive ✅ |
| 06 | sales/orders | **Saleor** (BSD) + **AdventureWorks** (MIT) | Medusa (MIT), Pagila (PG Lic) | all permissive ✅ |
| 07 | billing/subscriptions | **Kill Bill** (Apache-2.0) + **Stripe** object names (docs) | Lago names-only (AGPL) | anchor permissive ✅ |
| 08 | crm | **Salesforce** object model (docs) | Twenty/EspoCRM/SuiteCRM names-only (AGPL) | shape from docs; copyleft names-only ⚠️ |
| 09 | support | **Chatwoot** (MIT) + **Zendesk** names (docs) | FreeScout/Zammad names-only (AGPL) | anchor permissive ✅ |
| 10 | marketing/loyalty | **Saleor discount** (BSD) | Mautic (GPL) + Listmonk (AGPL) names-only | anchor permissive ✅ |
| 11 | analytics/events | **Snowplow** canonical (Apache-2.0) + **PostHog** (MIT) | Segment spec (docs) | all permissive ✅ |
| 12 | comms | **Chatwoot** (MIT) | Twilio/SendGrid event vocab (docs); Listmonk names-only (AGPL) | anchor permissive ✅ |
| 13 | audit | **pgAudit** trigger (PG Lic) + **paper_trail** (MIT) | Django LogEntry (BSD) | all permissive ✅ |
| 14 | ops | **solid_queue/Unleash/Svix** (MIT/Apache) | Flipper (MIT) | all permissive ✅ |
| — | multi-tenancy | **Citus multi-tenant guide** (docs/facts) | acts_as_tenant (MIT) | pattern from docs ✅ |

**Net posture:** every domain has a **permissive primary anchor OR a docs/facts anchor** that we
can read and adapt safely. The copyleft projects (Vendure, Spree ≥4.10, Twenty, EspoCRM, SuiteCRM,
Lago, Mautic, Listmonk, FreeScout, Zammad) are used **only to confirm entity lists and standard
names** — never as a DDL source. This keeps the benchmark's schema both **recognizable** and
**license-clean**.

---

## Sources

Verified against repo LICENSE files / official docs, June 2026.

- Saleor (BSD-3-Clause): https://github.com/saleor/saleor/blob/main/LICENSE
- Medusa.js (MIT): https://github.com/medusajs/medusa/blob/develop/LICENSE
- Sylius (MIT): https://docs.sylius.com/the-book/contributing/contributing-code/sylius-license-and-trademark
- Vendure (GPL-3.0, re-licensed from MIT): https://github.com/vendure-ecommerce/vendure
- Spree (BSD-3 ≤4.9 / AGPL-3.0 ≥4.10 dual): https://github.com/spree/spree/blob/main/license.md ; https://spreecommerce.org/why-spree-is-changing-its-open-source-license-to-agpl-3-0-and-introducing-a-commercial-license/
- AdventureWorks (MIT): https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/adventure-works
- Pagila (PostgreSQL License): https://github.com/devrimgunduz/pagila
- Kill Bill (Apache-2.0): https://github.com/killbill/killbill/blob/master/LICENSE
- Lago (AGPL-3.0): https://github.com/getlago/lago
- Stripe Billing object model (docs): https://docs.stripe.com/api/subscriptions/object ; https://docs.stripe.com/api/invoices/object ; https://docs.stripe.com/api/prices/object
- Twenty (AGPL-3.0): https://github.com/twentyhq/twenty/blob/main/LICENSE
- EspoCRM (AGPL-3.0): https://github.com/espocrm/espocrm ; https://www.espocrm.com/blog/espocrm-license/
- SuiteCRM (AGPL-3.0): https://docs.suitecrm.com/admin/licensing/
- Salesforce standard object reference (docs): https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/
- Chatwoot (MIT): https://github.com/chatwoot/chatwoot/blob/develop/LICENSE
- Zendesk Ticketing API (docs): https://developer.zendesk.com/api-reference/ticketing/tickets/tickets/
- FreeScout (AGPL-3.0): https://github.com/freescout-helpdesk/freescout
- Zammad (AGPL-3.0): https://zammad.org/ ; https://github.com/zammad/zammad
- Listmonk (AGPL-3.0): https://github.com/knadh/listmonk/blob/master/schema.sql
- Mautic (GPL-3.0): https://github.com/mautic/mautic
- PostHog (MIT, self-hosted): https://github.com/PostHog/posthog
- Snowplow canonical event model (Apache-2.0): https://docs.snowplow.io/docs/fundamentals/canonical-event/ ; https://github.com/snowplow/snowplow
- Segment spec (docs): https://segment.com/docs/connections/spec/
- Keycloak (Apache-2.0): https://github.com/keycloak/keycloak ; https://github.com/keycloak/keycloak/issues/16395
- Ory Kratos (Apache-2.0): https://github.com/ory/kratos
- Django auth (BSD-3-Clause): https://docs.djangoproject.com/en/stable/topics/auth/
- pgAudit (PostgreSQL License): https://github.com/pgaudit/pgaudit ; Postgres audit-trigger wiki: https://wiki.postgresql.org/wiki/Audit_trigger_91plus
- paper_trail (MIT): https://github.com/paper-trail-gem/paper_trail
- solid_queue (MIT): https://github.com/rails/solid_queue
- Unleash (Apache-2.0): https://github.com/Unleash/unleash
- Svix (MIT): https://github.com/svix/svix-webhooks
- Citus multi-tenant guide (docs): https://docs.citusdata.com/en/stable/use_cases/multi_tenant.html ; https://docs.citusdata.com/en/stable/sharding/data_modeling.html
- acts_as_tenant (MIT): https://github.com/ErwinM/acts_as_tenant
