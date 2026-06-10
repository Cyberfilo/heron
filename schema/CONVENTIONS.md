# Schema conventions — the style guide every module obeys

Every `NN_<module>.sql` file in this directory MUST follow these rules so the 14 modules
compose into one consistent, FK-linked, production-shaped database. Treat this as a contract:
if two modules disagree, this file wins.

> **Why so strict?** The benchmark's gold SQL is hand-written against these conventions. If a
> module silently uses `customer_id` where the convention says `user_id`, every gold query that
> joins it breaks. Consistency is the difference between a benchmark and a pile of tables.

---

## Postgres schemas (namespaces)

Tables live in **domain schemas**, not all in `public`. This mirrors a real platform, exercises
schema-qualified retrieval, and keeps 220+ tables navigable.

| Schema       | Module file              | Domain                                                        |
|--------------|--------------------------|---------------------------------------------------------------|
| `identity`   | `01_identity.sql`        | tenants, users, roles, permissions, sessions, api keys, teams |
| `geo`        | `02_geo.sql`             | countries, regions, currencies, fx rates, locales, addresses  |
| `catalog`    | `03_catalog.sql`         | products, variants, categories, brands, attributes, media     |
| `pricing`    | `04_pricing.sql`         | price lists, prices, discounts, coupons, tax rates            |
| `inventory`  | `05_inventory.sql`       | warehouses, stock, movements, suppliers, purchase orders      |
| `sales`      | `06_sales.sql`           | carts, orders, order items, fulfillments, returns, gift cards |
| `billing`    | `07_billing.sql`         | payments, refunds, invoices, subscriptions, plans, ledger     |
| `crm`        | `08_crm.sql`             | accounts, contacts, leads, opportunities, pipelines, deals    |
| `support`    | `09_support.sql`         | tickets, messages, SLAs, agents, CSAT, knowledge base         |
| `marketing`  | `10_marketing.sql`       | campaigns, segments, A/B tests, referrals, loyalty            |
| `analytics`  | `11_analytics.sql`       | events (big fact table), web sessions, experiments, metrics   |
| `comms`      | `12_comms.sql`           | notifications, webhooks, email/sms logs, threads              |
| `audit`      | `13_audit.sql`           | audit log, change history, access log, consent, compliance    |
| `ops`        | `14_ops.sql`             | feature flags, settings, jobs, integrations, files, imports   |

Load order is the numeric prefix. `00_extensions.sql` runs first (extensions + schemas +
shared enums + shared lookup helper); `99_indexes.sql` and `98_comments.sql` run last.

Cross-schema FKs are expected and fully qualified, e.g. `sales.orders.tenant_id ->
identity.tenants(id)`.

---

## Naming

- **snake_case** everywhere. **Plural** table names (`orders`, `order_items`, `payment_attempts`).
- **Primary key:** `id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY`. Always named `id`.
- **Foreign key column:** `<referent_singular>_id`. `order_id` references `sales.orders(id)`.
  When a table has two FKs to the same target, qualify the role: `billing_address_id`,
  `shipping_address_id` (both → `geo.addresses(id)`).
- **Public/external identifier (selected entities only):** `public_id uuid NOT NULL DEFAULT
  gen_random_uuid()` with a `UNIQUE` constraint — for orders, invoices, users, tickets,
  subscriptions, api keys. Internal joins use `id`; the `public_id` exists because real systems
  expose opaque IDs. (A nice source of "look up order by its public id" questions.)
- **Junction tables:** `<a>_<b>` plural of the second, e.g. `role_permissions`, `variant_attributes`.

## Mandatory columns

Every business (non-pure-lookup) table carries audit columns:

```sql
created_at  timestamptz NOT NULL DEFAULT now(),
updated_at  timestamptz NOT NULL DEFAULT now()
```

Tenant-scoped tables (almost everything except `geo`, global `ops` config, and platform-level
`identity.tenants`) carry:

```sql
tenant_id   bigint NOT NULL REFERENCES identity.tenants(id)
```

Soft-deletable entities additionally carry `deleted_at timestamptz` (NULL = live). Document which
ones in the module header. Do **not** soft-delete fact tables (orders/events) — they are immutable.

## Types

- **Money:** `numeric(14,4)` for amounts; pair every monetary table with `currency_code char(3)
  NOT NULL REFERENCES geo.currencies(code)`. Never use float for money.
- **Timestamps:** `timestamptz` always (never naive `timestamp`). Dates without time: `date`.
- **Text:** `text` (not `varchar(n)`) unless a real length cap is meaningful (e.g. `char(3)`
  country/currency codes, `char(2)` locale). Use `citext` for emails (extension enabled).
- **Quantities/counts:** `integer` or `bigint`. **Booleans:** real `boolean`, never `0/1`.
- **JSON:** `jsonb` for genuinely schemaless payloads (event properties, webhook bodies,
  feature-flag rules, integration config). Don't over-use it — most columns are typed.

## Enums vs lookup tables (use BOTH, realistically)

- **Native `enum` types** for small, stable status sets that rarely change:
  `sales.order_status`, `billing.payment_status`, `support.ticket_priority`. Declare these in
  `00_extensions.sql` so cross-module references resolve.
- **Lookup tables** for sets that carry attributes or churn: `crm.opportunity_stages`,
  `billing.plans`, `support.sla_policies`. These have their own rows and FKs.

## Constraints (production systems are full of them — so is this)

- `NOT NULL` on every column that is logically required. Be honest: nullable means "really optional".
- `CHECK` constraints: `CHECK (amount >= 0)`, `CHECK (quantity > 0)`,
  `CHECK (ends_at > starts_at)`, status transitions where natural.
- `UNIQUE` on natural keys: `users(tenant_id, email)`, `currencies(code)`.
- **Partial unique** for "one default" patterns:
  `CREATE UNIQUE INDEX ... ON geo.addresses(user_id) WHERE is_default;`
- FK `ON DELETE` policy: default `ON DELETE RESTRICT`; use `CASCADE` only for true child/owned
  rows (order_items → orders), `SET NULL` for optional references (e.g. `assigned_agent_id`).

## Comments (load-bearing for the retrieval axis)

`prq`-style retrieval weights table/column comments heavily, so comments are part of the
benchmark surface — and a place to test robustness. Rules:

- **~70% of tables** get a `COMMENT ON TABLE` (one realistic sentence). Put these in
  `98_comments.sql` (kept separate so a module's DDL stays readable).
- **~30% of tables are deliberately uncommented or terse** — real schemas are inconsistent, and
  retrieval that only works on well-documented tables is not production-ready. This is intentional
  difficulty, documented in `docs/METHODOLOGY.md`, not an oversight.
- Comment a column only when its name is non-obvious (`net_terms_days`, `mrr_cents`,
  `is_backorderable`). Don't comment `created_at`.

## Indexes (`99_indexes.sql`)

- Index every FK column used in joins (Postgres does **not** auto-index FKs).
- A handful of realistic composite / partial / expression indexes:
  `(tenant_id, created_at)` on big fact tables, `lower(email)`, partial `WHERE status='open'`.
- The point is realism, not query tuning — the benchmark measures correctness, not latency.

## Data realism contract (what the generator must honor)

The schema is only half the benchmark; the *data* must be production-shaped. The generator
(`seed/generate.py`) must produce, and module authors should design columns to allow:

- **Skew, not uniformity.** Power-law customers (a few whales, a long tail), Zipfian product
  popularity, weekly/seasonal order seasonality, diurnal event spikes.
- **Dirty-but-valid values.** Mixed email casing, nullable middle names, free-text notes,
  a realistic fraction of cancelled/refunded/failed rows — not a clean happy path.
- **Referential integrity always holds.** Every FK resolves. No orphans. (Generated in
  dependency order with retained id pools.)
- **Temporal coherence.** `shipped_at >= paid_at >= order.created_at`; a subscription's invoices
  fall within its active period; events reference sessions that started earlier.
- **Tenant isolation.** A row's `tenant_id` matches the `tenant_id` of every row it references.
  (This is the single most common real-world bug and a rich source of hard questions.)

## A worked example (copy this shape)

```sql
-- in 06_sales.sql
CREATE TABLE sales.orders (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    user_id         bigint NOT NULL REFERENCES identity.users(id),
    billing_address_id  bigint REFERENCES geo.addresses(id),
    shipping_address_id bigint REFERENCES geo.addresses(id),
    status          sales.order_status NOT NULL DEFAULT 'pending',
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    subtotal        numeric(14,4) NOT NULL CHECK (subtotal >= 0),
    tax_total       numeric(14,4) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    grand_total     numeric(14,4) NOT NULL CHECK (grand_total >= 0),
    placed_at       timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT orders_public_id_key UNIQUE (public_id)
);
```
