-- 15_deferred_fks.sql — cross-module forward references.
-- A few lower-numbered modules carry an order_id that logically points at
-- sales.orders (module 06, higher-numbered). To keep each module free of
-- forward dependencies during load, those columns are plain bigint in their
-- own files and the FK is added here, after every module exists.

ALTER TABLE pricing.coupon_redemptions
    ADD CONSTRAINT coupon_redemptions_order_fk
    FOREIGN KEY (order_id) REFERENCES sales.orders(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS coupon_redemptions_order_idx
    ON pricing.coupon_redemptions (order_id);

ALTER TABLE inventory.stock_reservations
    ADD CONSTRAINT stock_reservations_order_fk
    FOREIGN KEY (order_id) REFERENCES sales.orders(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS stock_reservations_order_idx
    ON inventory.stock_reservations (order_id);
