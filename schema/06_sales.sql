-- 06_sales.sql — carts, orders, order items, fulfillments, shipments,
-- returns, gift cards. The CORE fact tables of the commerce domain.
--
-- References lower modules: identity.tenants/users, geo.addresses/currencies,
-- catalog.product_variants, pricing.discounts/coupons, inventory.warehouses.
-- Self-contained: tables + constraints + FK indexes + selected comments.
-- See CONVENTIONS.md and SCHEMA-MAP.md.
--
-- Immutability / soft-delete policy (per CONVENTIONS.md):
--   * orders, order_items, order_status_history are immutable FACT rows and are
--     NOT soft-deletable (no deleted_at). orders/order_items keep updated_at
--     (status/totals are mutated in place); order_status_history is append-only
--     (created_at only, no updated_at).
--   * gift_card_transactions is an append-only ledger (created_at only).
--   * No table in this module is soft-deletable.

-- ===========================================================================
-- carts — shopping carts. May belong to a logged-in user or be anonymous
-- (user_id nullable). Converts to an order; see status sales.cart_status.
-- ===========================================================================
CREATE TABLE sales.carts (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    user_id       bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    session_token text,
    status        sales.cart_status NOT NULL DEFAULT 'active',
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    item_count    integer NOT NULL DEFAULT 0 CHECK (item_count >= 0),
    subtotal      numeric(14,4) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    abandoned_at  timestamptz,
    converted_at  timestamptz,
    expires_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON sales.carts (tenant_id);
CREATE INDEX ON sales.carts (user_id);
CREATE INDEX carts_active_idx ON sales.carts (tenant_id, updated_at) WHERE status = 'active';

CREATE TABLE sales.cart_items (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    cart_id            bigint NOT NULL REFERENCES sales.carts(id) ON DELETE CASCADE,
    product_variant_id bigint NOT NULL REFERENCES catalog.product_variants(id),
    quantity           integer NOT NULL CHECK (quantity > 0),
    unit_price         numeric(14,4) NOT NULL CHECK (unit_price >= 0),
    currency_code      char(3) NOT NULL REFERENCES geo.currencies(code),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT cart_items_cart_variant_uq UNIQUE (cart_id, product_variant_id)
);
CREATE INDEX ON sales.cart_items (tenant_id);
CREATE INDEX ON sales.cart_items (cart_id);
CREATE INDEX ON sales.cart_items (product_variant_id);

-- ===========================================================================
-- orders — the central order fact table. public_id is the opaque id surfaced
-- to customers. billing_address_id / shipping_address_id both -> geo.addresses.
-- Totals are denormalized money; subtotal + tax + shipping - discount = grand.
-- ===========================================================================
CREATE TABLE sales.orders (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id           uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    user_id             bigint NOT NULL REFERENCES identity.users(id),
    cart_id             bigint REFERENCES sales.carts(id) ON DELETE SET NULL,
    order_number        text NOT NULL,
    status              sales.order_status NOT NULL DEFAULT 'pending',
    billing_address_id  bigint REFERENCES geo.addresses(id),
    shipping_address_id bigint REFERENCES geo.addresses(id),
    currency_code       char(3) NOT NULL REFERENCES geo.currencies(code),
    subtotal            numeric(14,4) NOT NULL CHECK (subtotal >= 0),
    discount_total      numeric(14,4) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    tax_total           numeric(14,4) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    shipping_total      numeric(14,4) NOT NULL DEFAULT 0 CHECK (shipping_total >= 0),
    grand_total         numeric(14,4) NOT NULL CHECK (grand_total >= 0),
    customer_email      citext,
    customer_note       text,
    placed_at           timestamptz,
    cancelled_at        timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT orders_public_id_key UNIQUE (public_id),
    CONSTRAINT orders_tenant_number_uq UNIQUE (tenant_id, order_number)
);
CREATE INDEX ON sales.orders (tenant_id);
CREATE INDEX ON sales.orders (user_id);
CREATE INDEX ON sales.orders (cart_id);
CREATE INDEX ON sales.orders (billing_address_id);
CREATE INDEX ON sales.orders (shipping_address_id);
CREATE INDEX orders_tenant_status_idx ON sales.orders (tenant_id, status);
CREATE INDEX orders_tenant_placed_idx ON sales.orders (tenant_id, placed_at);

CREATE TABLE sales.order_items (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    order_id           bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
    product_variant_id bigint NOT NULL REFERENCES catalog.product_variants(id),
    sku                text NOT NULL,
    name               text NOT NULL,
    quantity           integer NOT NULL CHECK (quantity > 0),
    quantity_fulfilled integer NOT NULL DEFAULT 0 CHECK (quantity_fulfilled >= 0),
    unit_price         numeric(14,4) NOT NULL CHECK (unit_price >= 0),
    discount_total     numeric(14,4) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    tax_total          numeric(14,4) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    line_total         numeric(14,4) NOT NULL CHECK (line_total >= 0),
    currency_code      char(3) NOT NULL REFERENCES geo.currencies(code),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT order_items_fulfilled_le_qty CHECK (quantity_fulfilled <= quantity)
);
CREATE INDEX ON sales.order_items (tenant_id);
CREATE INDEX ON sales.order_items (order_id);
CREATE INDEX ON sales.order_items (product_variant_id);

-- order_status_history — append-only audit of order status transitions.
-- IMMUTABLE: created_at only, no updated_at, never soft-deleted.
CREATE TABLE sales.order_status_history (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    order_id           bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
    from_status        sales.order_status,
    to_status          sales.order_status NOT NULL,
    changed_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    note               text,
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON sales.order_status_history (tenant_id);
CREATE INDEX ON sales.order_status_history (order_id);

-- order_discounts — discounts/coupons applied to an order. references the
-- pricing module's discount/coupon definitions; either may be null (a manual
-- discount carries neither).
CREATE TABLE sales.order_discounts (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    order_id      bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
    discount_id   bigint REFERENCES pricing.discounts(id),
    coupon_id     bigint REFERENCES pricing.coupons(id),
    code          text,
    description   text,
    amount        numeric(14,4) NOT NULL CHECK (amount >= 0),
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON sales.order_discounts (tenant_id);
CREATE INDEX ON sales.order_discounts (order_id);
CREATE INDEX ON sales.order_discounts (discount_id);
CREATE INDEX ON sales.order_discounts (coupon_id);

-- ===========================================================================
-- fulfillments — a shipment-able grouping of order items dispatched from a
-- warehouse. status sales.fulfillment_status; FK inventory.warehouses.
-- ===========================================================================
CREATE TABLE sales.fulfillments (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    order_id     bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
    warehouse_id bigint REFERENCES inventory.warehouses(id) ON DELETE SET NULL,
    status       sales.fulfillment_status NOT NULL DEFAULT 'pending',
    reference    text,
    packed_at    timestamptz,
    shipped_at   timestamptz,
    delivered_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON sales.fulfillments (tenant_id);
CREATE INDEX ON sales.fulfillments (order_id);
CREATE INDEX ON sales.fulfillments (warehouse_id);
CREATE INDEX fulfillments_tenant_status_idx ON sales.fulfillments (tenant_id, status);

CREATE TABLE sales.fulfillment_items (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      bigint NOT NULL REFERENCES identity.tenants(id),
    fulfillment_id bigint NOT NULL REFERENCES sales.fulfillments(id) ON DELETE CASCADE,
    order_item_id  bigint NOT NULL REFERENCES sales.order_items(id),
    quantity       integer NOT NULL CHECK (quantity > 0),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fulfillment_items_uq UNIQUE (fulfillment_id, order_item_id)
);
CREATE INDEX ON sales.fulfillment_items (tenant_id);
CREATE INDEX ON sales.fulfillment_items (fulfillment_id);
CREATE INDEX ON sales.fulfillment_items (order_item_id);

-- ===========================================================================
-- shipments — carrier shipments per fulfillment, plus per-event tracking.
-- ===========================================================================
CREATE TABLE sales.shipments (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    fulfillment_id  bigint NOT NULL REFERENCES sales.fulfillments(id) ON DELETE CASCADE,
    carrier         text NOT NULL,
    service_level   text,
    tracking_number text,
    tracking_url    text,
    shipping_cost   numeric(14,4) CHECK (shipping_cost >= 0),
    currency_code   char(3) REFERENCES geo.currencies(code),
    weight_grams    integer CHECK (weight_grams >= 0),
    shipped_at      timestamptz,
    delivered_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON sales.shipments (tenant_id);
CREATE INDEX ON sales.shipments (fulfillment_id);
CREATE INDEX shipments_tracking_idx ON sales.shipments (tenant_id, tracking_number);

-- shipment_tracking — append-only stream of carrier tracking events.
-- IMMUTABLE: occurred_at only, no updated_at.
CREATE TABLE sales.shipment_tracking (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    shipment_id bigint NOT NULL REFERENCES sales.shipments(id) ON DELETE CASCADE,
    status      text NOT NULL,
    description text,
    location    text,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON sales.shipment_tracking (tenant_id);
CREATE INDEX ON sales.shipment_tracking (shipment_id);
CREATE INDEX ON sales.shipment_tracking (shipment_id, occurred_at);

-- ===========================================================================
-- returns — RMA headers. status sales.return_status. return_items reference
-- the original order_items being returned.
-- ===========================================================================
CREATE TABLE sales.returns (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    order_id        bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
    rma_number      text NOT NULL,
    status          sales.return_status NOT NULL DEFAULT 'requested',
    reason          text,
    refund_total    numeric(14,4) NOT NULL DEFAULT 0 CHECK (refund_total >= 0),
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    requested_at    timestamptz NOT NULL DEFAULT now(),
    approved_at     timestamptz,
    received_at     timestamptz,
    refunded_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT returns_tenant_rma_uq UNIQUE (tenant_id, rma_number)
);
CREATE INDEX ON sales.returns (tenant_id);
CREATE INDEX ON sales.returns (order_id);
CREATE INDEX returns_tenant_status_idx ON sales.returns (tenant_id, status);

CREATE TABLE sales.return_items (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    return_id     bigint NOT NULL REFERENCES sales.returns(id) ON DELETE CASCADE,
    order_item_id bigint NOT NULL REFERENCES sales.order_items(id),
    quantity      integer NOT NULL CHECK (quantity > 0),
    reason        text,
    restock       boolean NOT NULL DEFAULT true,
    refund_amount numeric(14,4) NOT NULL DEFAULT 0 CHECK (refund_amount >= 0),
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT return_items_uq UNIQUE (return_id, order_item_id)
);
CREATE INDEX ON sales.return_items (tenant_id);
CREATE INDEX ON sales.return_items (return_id);
CREATE INDEX ON sales.return_items (order_item_id);

-- ===========================================================================
-- gift_cards — stored-value instruments. code is unique per tenant.
-- gift_card_transactions is the append-only debit/credit ledger.
-- ===========================================================================
CREATE TABLE sales.gift_cards (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    code            text NOT NULL,
    status          text NOT NULL DEFAULT 'active',
    initial_balance numeric(14,4) NOT NULL CHECK (initial_balance >= 0),
    balance         numeric(14,4) NOT NULL CHECK (balance >= 0),
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    issued_to_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    issued_order_id bigint REFERENCES sales.orders(id) ON DELETE SET NULL,
    expires_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT gift_cards_tenant_code_uq UNIQUE (tenant_id, code)
);
CREATE INDEX ON sales.gift_cards (tenant_id);
CREATE INDEX ON sales.gift_cards (issued_to_user_id);
CREATE INDEX ON sales.gift_cards (issued_order_id);

-- gift_card_transactions — immutable ledger of balance changes. Positive
-- amount = credit (issuance/top-up), negative = debit (redemption).
-- IMMUTABLE: created_at only, no updated_at.
CREATE TABLE sales.gift_card_transactions (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    gift_card_id  bigint NOT NULL REFERENCES sales.gift_cards(id) ON DELETE CASCADE,
    order_id      bigint REFERENCES sales.orders(id) ON DELETE SET NULL,
    amount        numeric(14,4) NOT NULL,
    balance_after numeric(14,4) NOT NULL CHECK (balance_after >= 0),
    currency_code char(3) NOT NULL REFERENCES geo.currencies(code),
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON sales.gift_card_transactions (tenant_id);
CREATE INDEX ON sales.gift_card_transactions (gift_card_id);
CREATE INDEX ON sales.gift_card_transactions (order_id);

-- ===========================================================================
-- order_notes — internal staff notes attached to an order (not the customer
-- note that lives on the order row itself).
-- ===========================================================================
CREATE TABLE sales.order_notes (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    order_id      bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
    author_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    body          text NOT NULL,
    is_pinned     boolean NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON sales.order_notes (tenant_id);
CREATE INDEX ON sales.order_notes (order_id);

-- ===========================================================================
-- draft_orders — quotes / merchant-created draft orders, optionally converted
-- into a real order. payload holds the in-progress line items as schemaless json.
-- ===========================================================================
CREATE TABLE sales.draft_orders (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id           bigint NOT NULL REFERENCES identity.tenants(id),
    user_id             bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    created_by_user_id  bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    converted_order_id  bigint REFERENCES sales.orders(id) ON DELETE SET NULL,
    name                text,
    status              text NOT NULL DEFAULT 'open',
    currency_code       char(3) NOT NULL REFERENCES geo.currencies(code),
    subtotal            numeric(14,4) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    grand_total         numeric(14,4) NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
    payload             jsonb NOT NULL DEFAULT '{}'::jsonb,
    expires_at          timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON sales.draft_orders (tenant_id);
CREATE INDEX ON sales.draft_orders (user_id);
CREATE INDEX ON sales.draft_orders (converted_order_id);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE sales.carts IS 'Shopping carts, anonymous (user_id null) or owned. Converts to an order; abandoned carts feed recovery campaigns.';
COMMENT ON TABLE sales.orders IS 'Central order fact table. public_id is the opaque id shown to customers; totals are denormalized money on the row.';
COMMENT ON COLUMN sales.orders.grand_total IS 'Final amount charged: subtotal - discount_total + tax_total + shipping_total.';
COMMENT ON COLUMN sales.orders.order_number IS 'Human-facing sequential order number, unique per tenant (distinct from the opaque public_id).';
COMMENT ON TABLE sales.order_items IS 'Line items of an order; sku and name are snapshotted at purchase time so historical orders survive catalog changes.';
COMMENT ON COLUMN sales.order_items.quantity_fulfilled IS 'Running count of units already dispatched across fulfillments; never exceeds quantity.';
COMMENT ON TABLE sales.order_status_history IS 'Append-only audit of order status transitions; immutable (no updated_at).';
COMMENT ON TABLE sales.order_discounts IS 'Discounts and coupon redemptions applied to an order; discount_id/coupon_id reference the pricing module.';
COMMENT ON TABLE sales.fulfillments IS 'A batch of order items dispatched together from one warehouse; tracks pick/pack/ship lifecycle.';
COMMENT ON TABLE sales.shipments IS 'Carrier shipment for a fulfillment, with tracking number and delivery timestamps.';
COMMENT ON TABLE sales.returns IS 'Return merchandise authorization (RMA) header; status walks requested -> approved -> received -> refunded.';
COMMENT ON COLUMN sales.return_items.restock IS 'Whether the returned units should be added back to sellable inventory.';
COMMENT ON TABLE sales.gift_cards IS 'Stored-value gift cards; code is unique per tenant and balance decreases as it is redeemed against orders.';
COMMENT ON TABLE sales.gift_card_transactions IS 'Immutable ledger of gift-card balance changes; positive amount credits, negative debits.';
COMMENT ON TABLE sales.draft_orders IS 'Merchant-created quotes/draft orders, optionally converted into a real order.';
