-- 05_inventory.sql — warehouses, stock locations, suppliers, on-hand stock,
-- the immutable movement ledger, reservations, purchase orders, lots/serials,
-- goods receipts and manual adjustments.
--
-- Cross-schema FKs (all backward-numbered, per SCHEMA-MAP):
--   * tenant_id            -> identity.tenants(id)        (every table is T)
--   * created_by_user_id   -> identity.users(id)          (actor on movements/adjustments)
--   * geo.addresses(id)    -> warehouse physical location
--   * geo.currencies(code) -> money on supplier_products / purchase_orders
--   * catalog.product_variants(id) -> the unit of inventory everywhere
--
-- Forward reference NOT taken: stock_reservations conceptually holds stock
-- "against an order" (sales.orders, module 06, higher-numbered). The contract
-- forbids forward FKs and SCHEMA-MAP does not expose sales keys to this module,
-- so order_id is carried as a plain bigint WITHOUT a FK constraint. See note
-- on that table.
--
-- Immutable tables (created_at only, no updated_at, no deleted_at):
--   stock_movements (ledger). Everything else is a business table.
-- See CONVENTIONS.md and SCHEMA-MAP.md.

-- ===========================================================================
-- warehouses — physical fulfillment sites. Each is anchored to a postal
-- address in geo. is_default marks the tenant's primary warehouse.
-- ===========================================================================
CREATE TABLE inventory.warehouses (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    address_id  bigint REFERENCES geo.addresses(id) ON DELETE SET NULL,
    code        text NOT NULL,
    name        text NOT NULL,
    is_default  boolean NOT NULL DEFAULT false,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,
    CONSTRAINT warehouses_tenant_code_uq UNIQUE (tenant_id, code)
);
CREATE INDEX ON inventory.warehouses (tenant_id);
CREATE INDEX ON inventory.warehouses (address_id);
CREATE UNIQUE INDEX warehouses_one_default_idx
    ON inventory.warehouses (tenant_id) WHERE is_default;

-- ===========================================================================
-- stock_locations — bins/zones/aisles within a warehouse. The physical place
-- an item actually sits; stock is counted per location, not per warehouse.
-- ===========================================================================
CREATE TABLE inventory.stock_locations (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    warehouse_id  bigint NOT NULL REFERENCES inventory.warehouses(id) ON DELETE CASCADE,
    code          text NOT NULL,
    name          text,
    kind          text NOT NULL DEFAULT 'bin',
    is_pickable    boolean NOT NULL DEFAULT true,
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT stock_locations_wh_code_uq UNIQUE (warehouse_id, code)
);
CREATE INDEX ON inventory.stock_locations (tenant_id);
CREATE INDEX ON inventory.stock_locations (warehouse_id);

-- ===========================================================================
-- suppliers — vendors that goods are purchased from.
-- ===========================================================================
CREATE TABLE inventory.suppliers (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    code          text NOT NULL,
    name          text NOT NULL,
    contact_email citext,
    contact_phone text,
    lead_time_days integer CHECK (lead_time_days >= 0),
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT suppliers_tenant_code_uq UNIQUE (tenant_id, code)
);
CREATE INDEX ON inventory.suppliers (tenant_id);

-- ===========================================================================
-- supplier_products — a supplier's catalog mapping: their SKU + cost for one
-- of our variants. is_preferred picks the default source per variant.
-- ===========================================================================
CREATE TABLE inventory.supplier_products (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    supplier_id     bigint NOT NULL REFERENCES inventory.suppliers(id) ON DELETE CASCADE,
    variant_id      bigint NOT NULL REFERENCES catalog.product_variants(id) ON DELETE CASCADE,
    supplier_sku    text,
    unit_cost       numeric(14,4) CHECK (unit_cost >= 0),
    currency_code   char(3) REFERENCES geo.currencies(code),
    min_order_qty   integer CHECK (min_order_qty > 0),
    lead_time_days  integer CHECK (lead_time_days >= 0),
    is_preferred    boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT supplier_products_uq UNIQUE (supplier_id, variant_id),
    CONSTRAINT supplier_products_cost_currency_ck
        CHECK ((unit_cost IS NULL) = (currency_code IS NULL))
);
CREATE INDEX ON inventory.supplier_products (tenant_id);
CREATE INDEX ON inventory.supplier_products (supplier_id);
CREATE INDEX ON inventory.supplier_products (variant_id);
CREATE UNIQUE INDEX supplier_products_one_preferred_idx
    ON inventory.supplier_products (tenant_id, variant_id) WHERE is_preferred;

-- ===========================================================================
-- stock_items — the on-hand quantity of one variant in one location. This is
-- the live balance; stock_movements is the immutable history that produces it.
-- One row per (variant, location).
-- ===========================================================================
CREATE TABLE inventory.stock_items (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    variant_id        bigint NOT NULL REFERENCES catalog.product_variants(id) ON DELETE CASCADE,
    stock_location_id bigint NOT NULL REFERENCES inventory.stock_locations(id) ON DELETE CASCADE,
    quantity          integer NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    reserved_quantity integer NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),
    reorder_point     integer CHECK (reorder_point >= 0),
    reorder_quantity  integer CHECK (reorder_quantity > 0),
    last_counted_at   timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT stock_items_variant_location_uq UNIQUE (variant_id, stock_location_id),
    CONSTRAINT stock_items_reserved_le_qty_ck CHECK (reserved_quantity <= quantity)
);
CREATE INDEX ON inventory.stock_items (tenant_id);
CREATE INDEX ON inventory.stock_items (variant_id);
CREATE INDEX ON inventory.stock_items (stock_location_id);
CREATE INDEX stock_items_low_stock_idx
    ON inventory.stock_items (tenant_id, variant_id)
    WHERE reorder_point IS NOT NULL AND quantity <= reorder_point;

-- ===========================================================================
-- stock_movements — IMMUTABLE append-only ledger of every quantity change.
-- quantity is SIGNED (positive = stock in, negative = stock out); summing the
-- ledger for a (variant, location) reproduces stock_items.quantity. No
-- updated_at: ledger rows are never mutated, only appended. reference_type /
-- reference_id loosely point at the source document (PO, order, adjustment).
-- ===========================================================================
CREATE TABLE inventory.stock_movements (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    variant_id        bigint NOT NULL REFERENCES catalog.product_variants(id),
    stock_location_id bigint NOT NULL REFERENCES inventory.stock_locations(id),
    lot_id            bigint,  -- FK to inventory.lots added via ALTER below (lots is defined later in this file)
    kind              inventory.movement_kind NOT NULL,
    quantity          integer NOT NULL CHECK (quantity <> 0),
    reference_type    text,
    reference_id      bigint,
    note              text,
    created_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    occurred_at       timestamptz NOT NULL DEFAULT now(),
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON inventory.stock_movements (tenant_id);
CREATE INDEX ON inventory.stock_movements (variant_id);
CREATE INDEX ON inventory.stock_movements (stock_location_id);
CREATE INDEX ON inventory.stock_movements (lot_id);
CREATE INDEX stock_movements_variant_loc_time_idx
    ON inventory.stock_movements (variant_id, stock_location_id, occurred_at);
CREATE INDEX stock_movements_reference_idx
    ON inventory.stock_movements (reference_type, reference_id);

-- ===========================================================================
-- stock_reservations — soft holds that earmark on-hand stock for an order so
-- it isn't double-sold before fulfillment. order_id intentionally has NO FK:
-- sales.orders lives in module 06 (higher-numbered) and the contract forbids
-- forward FKs; it is carried as a plain bigint reference. released_at non-null
-- means the hold was released (order shipped or cancelled).
-- ===========================================================================
CREATE TABLE inventory.stock_reservations (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    variant_id        bigint NOT NULL REFERENCES catalog.product_variants(id) ON DELETE CASCADE,
    stock_location_id bigint NOT NULL REFERENCES inventory.stock_locations(id) ON DELETE CASCADE,
    order_id          bigint,
    quantity          integer NOT NULL CHECK (quantity > 0),
    expires_at        timestamptz,
    released_at       timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON inventory.stock_reservations (tenant_id);
CREATE INDEX ON inventory.stock_reservations (variant_id);
CREATE INDEX ON inventory.stock_reservations (stock_location_id);
CREATE INDEX ON inventory.stock_reservations (order_id);
CREATE INDEX stock_reservations_active_idx
    ON inventory.stock_reservations (variant_id, stock_location_id)
    WHERE released_at IS NULL;

-- ===========================================================================
-- purchase_orders — replenishment orders sent to a supplier, delivered to a
-- warehouse. public_id is the opaque external identifier. expected_total is a
-- denormalized convenience; the authoritative sum is over purchase_order_lines.
-- ===========================================================================
CREATE TABLE inventory.purchase_orders (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       bigint NOT NULL REFERENCES identity.tenants(id),
    supplier_id     bigint NOT NULL REFERENCES inventory.suppliers(id),
    warehouse_id    bigint REFERENCES inventory.warehouses(id) ON DELETE SET NULL,
    po_number       text NOT NULL,
    status          inventory.po_status NOT NULL DEFAULT 'draft',
    currency_code   char(3) NOT NULL REFERENCES geo.currencies(code),
    expected_total  numeric(14,4) NOT NULL DEFAULT 0 CHECK (expected_total >= 0),
    notes           text,
    ordered_at      timestamptz,
    expected_at     timestamptz,
    received_at     timestamptz,
    created_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT purchase_orders_public_id_key UNIQUE (public_id),
    CONSTRAINT purchase_orders_tenant_number_uq UNIQUE (tenant_id, po_number)
);
CREATE INDEX ON inventory.purchase_orders (tenant_id);
CREATE INDEX ON inventory.purchase_orders (supplier_id);
CREATE INDEX ON inventory.purchase_orders (warehouse_id);
CREATE INDEX ON inventory.purchase_orders (created_by_user_id);
CREATE INDEX purchase_orders_open_idx
    ON inventory.purchase_orders (tenant_id, status)
    WHERE status IN ('submitted','partially_received');

-- ===========================================================================
-- purchase_order_lines — the variants and quantities on a PO, with the agreed
-- unit cost. quantity_received accrues as goods arrive against inbound_receipts.
-- ===========================================================================
CREATE TABLE inventory.purchase_order_lines (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    purchase_order_id  bigint NOT NULL REFERENCES inventory.purchase_orders(id) ON DELETE CASCADE,
    variant_id         bigint NOT NULL REFERENCES catalog.product_variants(id),
    quantity_ordered   integer NOT NULL CHECK (quantity_ordered > 0),
    quantity_received  integer NOT NULL DEFAULT 0 CHECK (quantity_received >= 0),
    unit_cost          numeric(14,4) NOT NULL CHECK (unit_cost >= 0),
    currency_code      char(3) NOT NULL REFERENCES geo.currencies(code),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT po_lines_uq UNIQUE (purchase_order_id, variant_id),
    CONSTRAINT po_lines_received_le_ordered_ck CHECK (quantity_received <= quantity_ordered)
);
CREATE INDEX ON inventory.purchase_order_lines (tenant_id);
CREATE INDEX ON inventory.purchase_order_lines (purchase_order_id);
CREATE INDEX ON inventory.purchase_order_lines (variant_id);

-- ===========================================================================
-- lots — batch/lot tracking for a variant (manufacturing batch, expiry).
-- ===========================================================================
CREATE TABLE inventory.lots (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    variant_id    bigint NOT NULL REFERENCES catalog.product_variants(id) ON DELETE CASCADE,
    supplier_id   bigint REFERENCES inventory.suppliers(id) ON DELETE SET NULL,
    lot_code      text NOT NULL,
    manufactured_at date,
    expires_at    date,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT lots_tenant_variant_code_uq UNIQUE (tenant_id, variant_id, lot_code),
    CONSTRAINT lots_expiry_after_mfg_ck CHECK (expires_at IS NULL OR manufactured_at IS NULL OR expires_at >= manufactured_at)
);
CREATE INDEX ON inventory.lots (tenant_id);
CREATE INDEX ON inventory.lots (variant_id);
CREATE INDEX ON inventory.lots (supplier_id);

-- ===========================================================================
-- serial_numbers — individually tracked units (one row per physical unit),
-- optionally grouped under a lot and located in a stock location.
-- ===========================================================================
CREATE TABLE inventory.serial_numbers (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    variant_id        bigint NOT NULL REFERENCES catalog.product_variants(id) ON DELETE CASCADE,
    lot_id            bigint REFERENCES inventory.lots(id) ON DELETE SET NULL,
    stock_location_id bigint REFERENCES inventory.stock_locations(id) ON DELETE SET NULL,
    serial            text NOT NULL,
    status            text NOT NULL DEFAULT 'in_stock',
    received_at       timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT serial_numbers_tenant_serial_uq UNIQUE (tenant_id, serial)
);
CREATE INDEX ON inventory.serial_numbers (tenant_id);
CREATE INDEX ON inventory.serial_numbers (variant_id);
CREATE INDEX ON inventory.serial_numbers (lot_id);
CREATE INDEX ON inventory.serial_numbers (stock_location_id);

-- ===========================================================================
-- inbound_receipts — goods-receipt headers recording a delivery against a PO.
-- ===========================================================================
CREATE TABLE inventory.inbound_receipts (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    purchase_order_id  bigint REFERENCES inventory.purchase_orders(id) ON DELETE SET NULL,
    warehouse_id       bigint NOT NULL REFERENCES inventory.warehouses(id),
    receipt_number     text NOT NULL,
    carrier            text,
    tracking_number    text,
    received_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    received_at        timestamptz NOT NULL DEFAULT now(),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT inbound_receipts_tenant_number_uq UNIQUE (tenant_id, receipt_number)
);
CREATE INDEX ON inventory.inbound_receipts (tenant_id);
CREATE INDEX ON inventory.inbound_receipts (purchase_order_id);
CREATE INDEX ON inventory.inbound_receipts (warehouse_id);

-- ===========================================================================
-- receipt_lines — the quantities of each variant actually received on a
-- receipt, put away into a specific location (and optionally a lot).
-- ===========================================================================
CREATE TABLE inventory.receipt_lines (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    inbound_receipt_id bigint NOT NULL REFERENCES inventory.inbound_receipts(id) ON DELETE CASCADE,
    purchase_order_line_id bigint REFERENCES inventory.purchase_order_lines(id) ON DELETE SET NULL,
    variant_id         bigint NOT NULL REFERENCES catalog.product_variants(id),
    stock_location_id  bigint REFERENCES inventory.stock_locations(id) ON DELETE SET NULL,
    lot_id             bigint REFERENCES inventory.lots(id) ON DELETE SET NULL,
    quantity_received  integer NOT NULL CHECK (quantity_received > 0),
    quantity_rejected  integer NOT NULL DEFAULT 0 CHECK (quantity_rejected >= 0),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON inventory.receipt_lines (tenant_id);
CREATE INDEX ON inventory.receipt_lines (inbound_receipt_id);
CREATE INDEX ON inventory.receipt_lines (purchase_order_line_id);
CREATE INDEX ON inventory.receipt_lines (variant_id);
CREATE INDEX ON inventory.receipt_lines (stock_location_id);
CREATE INDEX ON inventory.receipt_lines (lot_id);

-- ===========================================================================
-- stock_adjustments — manual corrections to on-hand quantity (cycle counts,
-- shrinkage, damage) with a required reason. quantity_delta is signed.
-- ===========================================================================
CREATE TABLE inventory.stock_adjustments (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         bigint NOT NULL REFERENCES identity.tenants(id),
    variant_id        bigint NOT NULL REFERENCES catalog.product_variants(id),
    stock_location_id bigint NOT NULL REFERENCES inventory.stock_locations(id),
    lot_id            bigint REFERENCES inventory.lots(id) ON DELETE SET NULL,
    quantity_delta    integer NOT NULL CHECK (quantity_delta <> 0),
    reason            text NOT NULL,
    note              text,
    adjusted_by_user_id bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON inventory.stock_adjustments (tenant_id);
CREATE INDEX ON inventory.stock_adjustments (variant_id);
CREATE INDEX ON inventory.stock_adjustments (stock_location_id);
CREATE INDEX ON inventory.stock_adjustments (lot_id);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE inventory.warehouses IS 'Physical fulfillment sites for a tenant, each anchored to a postal address; one is flagged as the default.';
COMMENT ON TABLE inventory.stock_locations IS 'Bins, shelves and zones inside a warehouse. Stock is counted at this granularity, not at the warehouse level.';
COMMENT ON TABLE inventory.suppliers IS 'Vendors that goods are purchased from on purchase orders.';
COMMENT ON TABLE inventory.supplier_products IS 'Per-supplier sourcing of a variant: their SKU and unit cost; is_preferred marks the default source.';
COMMENT ON TABLE inventory.stock_items IS 'Live on-hand quantity of a variant in a single location; one row per (variant, location). The movements ledger is its history.';
COMMENT ON COLUMN inventory.stock_items.reserved_quantity IS 'Portion of quantity earmarked by open reservations and not available to sell.';
COMMENT ON COLUMN inventory.stock_items.reorder_point IS 'Replenishment trigger: at or below this on-hand level the variant is flagged for reorder.';
COMMENT ON TABLE inventory.stock_movements IS 'Immutable append-only ledger of inventory quantity changes; quantity is signed (in positive, out negative) and the running sum reproduces stock_items.';
COMMENT ON COLUMN inventory.stock_movements.reference_id IS 'Loose pointer to the source document (PO line, order, adjustment) identified by reference_type; not a foreign key.';
COMMENT ON TABLE inventory.stock_reservations IS 'Soft holds that earmark stock for an order so it is not double-sold; order_id references sales.orders by id but has no FK (forward module).';
COMMENT ON TABLE inventory.purchase_orders IS 'Replenishment orders sent to a supplier and delivered to a warehouse; public_id is the opaque external identifier.';
COMMENT ON COLUMN inventory.purchase_orders.expected_total IS 'Denormalized order total; the authoritative figure is the sum over purchase_order_lines.';
COMMENT ON TABLE inventory.purchase_order_lines IS 'Line items on a purchase order: variant, quantity and agreed unit cost, with received quantity accruing as goods arrive.';
COMMENT ON TABLE inventory.lots IS 'Batch/lot tracking for a variant, carrying manufacture and expiry dates for FEFO picking and recalls.';
COMMENT ON TABLE inventory.inbound_receipts IS 'Goods-receipt headers recording a physical delivery into a warehouse, usually against a purchase order.';
COMMENT ON TABLE inventory.stock_adjustments IS 'Manual corrections to on-hand stock (cycle counts, shrinkage, damage); quantity_delta is signed and a reason is required.';

-- --- deferred FK (intra-module ordering, NOT a forward cross-module ref) ---
-- stock_movements is defined before lots in this file, so its lot_id FK is
-- attached here once lots exists.
ALTER TABLE inventory.stock_movements
    ADD CONSTRAINT stock_movements_lot_id_fkey
    FOREIGN KEY (lot_id) REFERENCES inventory.lots(id) ON DELETE SET NULL;
