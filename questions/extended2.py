"""Second extended heron suite (v1): q076–q100, bringing the suite to 100.

Same contract + difficulty axes as questions/core.py and questions/extended.py.
Gold SQL is validated by harness/audit.py before publication.

This set is built with two goals on top of coverage:
  1) exercise tables the first two suites never touched (carts, fulfillments,
     shipments, returns, gift cards, purchase orders, contacts, payment methods,
     email_log, page_views, login attempts, loyalty, exchange rates, ...);
  2) put deliberate load on the BIG tables (analytics.events 500k, page_views
     350k, email_log 200k, order_items 175k, payments/orders 50k+) and on
     efficiency-sensitive shapes (top-N sorts, anti-joins/NOT EXISTS, window
     running-totals) so the Valid-Efficiency-Score (VES) axis has real signal —
     a correct-but-O(n²) query is observably slower here.
"""
from __future__ import annotations

from .schema import Question

Q = Question
QUESTIONS: list[Question] = [
    # ---- easy: single-table, named / value-grounding ---------------------
    Q("q076", "How many shopping baskets were abandoned?",
      "SELECT count(*) FROM sales.carts WHERE status = 'abandoned'",
      ("sales.carts",), "single", "lexical-gap", ("lexical-gap", "value-grounding")),
    Q("q077", "How many fulfillments have been delivered?",
      "SELECT count(*) FROM sales.fulfillments WHERE status = 'delivered'",
      ("sales.fulfillments",), "single", "named", ("value-grounding",)),
    Q("q078", "How many product variants are currently active?",
      "SELECT count(*) FROM catalog.product_variants WHERE is_active = true",
      ("catalog.product_variants",), "single", "named", ("value-grounding",)),
    Q("q079", "How many purchase orders have been fully received?",
      "SELECT count(*) FROM inventory.purchase_orders WHERE status = 'received'",
      ("inventory.purchase_orders",), "single", "named", ("value-grounding",)),
    Q("q080", "How many sign-in attempts were rejected?",
      "SELECT count(*) FROM identity.login_attempts WHERE succeeded = false",
      ("identity.login_attempts",), "single", "lexical-gap",
      ("lexical-gap", "value-grounding")),

    # ---- lexical gap (NL term != schema term) ----------------------------
    Q("q081", "How many product returns were green-lit?",
      "SELECT count(*) FROM sales.returns WHERE status = 'approved'",
      ("sales.returns",), "single", "lexical-gap",
      ("lexical-gap", "value-grounding")),
    Q("q082", "How many transactional emails failed to send?",
      "SELECT count(*) FROM comms.email_log WHERE status = 'failed'",
      ("comms.email_log",), "single", "named", ("value-grounding",)),

    # ---- aggregates / group-by / ratio over big tables -------------------
    Q("q083", "What is the average page-view duration in seconds?",
      "SELECT avg(duration_seconds) FROM analytics.page_views",
      ("analytics.page_views",), "single", "named", ("aggregate",)),
    Q("q084", "What is the total amount of captured payments per gateway?",
      "SELECT gateway, sum(amount) AS captured FROM billing.payments "
      "WHERE status = 'captured' GROUP BY gateway",
      ("billing.payments",), "single", "named", ("group-by", "value-grounding")),
    Q("q085", "How many orders are in each status?",
      "SELECT status, count(*) FROM sales.orders GROUP BY status",
      ("sales.orders",), "single", "named", ("group-by",)),
    Q("q086", "Which hour of the day has the most analytics events? Give the hour and count.",
      "SELECT EXTRACT(hour FROM occurred_at) AS hr, count(*) AS n "
      "FROM analytics.events GROUP BY 1 ORDER BY n DESC LIMIT 1",
      ("analytics.events",), "single", "named",
      ("time-bucket", "group-by", "order-by", "limit")),
    Q("q087", "What fraction of logged emails were sent successfully?",
      "SELECT count(*) FILTER (WHERE status = 'success')::numeric / count(*) "
      "FROM comms.email_log",
      ("comms.email_log",), "single", "named", ("ratio", "value-grounding")),
    Q("q088", "How many messages are on each ticket, for tickets with at least 8 messages?",
      "SELECT t.id, count(*) AS msgs FROM support.tickets t "
      "JOIN support.ticket_messages m ON m.ticket_id = t.id "
      "GROUP BY t.id HAVING count(*) >= 8",
      ("support.tickets", "support.ticket_messages"), "join", "1-hop",
      ("join", "group-by", "having")),
    Q("q089", "What are the 10 orders with the highest total line value? Give order id and total.",
      "SELECT order_id, sum(line_total) AS total FROM sales.order_items "
      "GROUP BY order_id ORDER BY total DESC LIMIT 10",
      ("sales.order_items",), "single", "named",
      ("group-by", "order-by", "limit")),

    # ---- one-hop joins ---------------------------------------------------
    Q("q091", "List each contact with the name of the account they belong to.",
      "SELECT ct.first_name, ct.last_name, a.name AS account "
      "FROM crm.contacts ct JOIN crm.accounts a ON a.id = ct.account_id",
      ("crm.contacts", "crm.accounts"), "join", "1-hop", ("join",)),
    Q("q092", "How many captured payments were made with each payment-method kind?",
      "SELECT pm.kind, count(*) AS n FROM billing.payments p "
      "JOIN billing.payment_methods pm ON pm.id = p.payment_method_id "
      "WHERE p.status = 'captured' GROUP BY pm.kind",
      ("billing.payments", "billing.payment_methods"), "join", "1-hop",
      ("join", "group-by", "value-grounding")),
    Q("q094", "Which 5 warehouses shipped or delivered the most fulfillments? Give warehouse name and count.",
      "SELECT w.name, count(*) AS n FROM sales.fulfillments f "
      "JOIN inventory.warehouses w ON w.id = f.warehouse_id "
      "WHERE f.status IN ('shipped', 'delivered') "
      "GROUP BY w.name ORDER BY n DESC LIMIT 5",
      ("sales.fulfillments", "inventory.warehouses"), "join", "1-hop",
      ("join", "group-by", "order-by", "limit", "value-grounding")),
    Q("q100", "List the top 10 products by number of approved reviews.",
      "SELECT p.name, count(*) AS reviews FROM catalog.product_reviews r "
      "JOIN catalog.products p ON p.id = r.product_id "
      "WHERE r.is_approved = true "
      "GROUP BY p.name ORDER BY reviews DESC LIMIT 10",
      ("catalog.product_reviews", "catalog.products"), "join", "1-hop",
      ("join", "group-by", "order-by", "limit", "value-grounding")),

    # ---- anti-join / NOT EXISTS (efficiency-sensitive) -------------------
    Q("q099", "How many users have never had a successful sign-in?",
      "SELECT count(*) FROM identity.users u WHERE NOT EXISTS ("
      "SELECT 1 FROM identity.login_attempts la "
      "WHERE la.user_id = u.id AND la.succeeded = true)",
      ("identity.users", "identity.login_attempts"), "join", "1-hop",
      ("anti-join", "value-grounding")),

    # ---- multi-join / 2-hop+ ---------------------------------------------
    Q("q090", "Show each delivered shipment's tracking number and the order number it belongs to.",
      "SELECT s.tracking_number, o.order_number FROM sales.shipments s "
      "JOIN sales.fulfillments f ON f.id = s.fulfillment_id "
      "JOIN sales.orders o ON o.id = f.order_id "
      "WHERE s.delivered_at IS NOT NULL",
      ("sales.shipments", "sales.fulfillments", "sales.orders"),
      "multi-join", "2-hop+", ("multi-join",)),
    Q("q093", "What is the total quantity sold per product brand?",
      "SELECT b.name AS brand, sum(oi.quantity) AS units "
      "FROM sales.order_items oi "
      "JOIN catalog.product_variants pv ON pv.id = oi.product_variant_id "
      "JOIN catalog.products p ON p.id = pv.product_id "
      "JOIN catalog.brands b ON b.id = p.brand_id GROUP BY b.name",
      ("sales.order_items", "catalog.product_variants", "catalog.products",
       "catalog.brands"), "multi-join", "2-hop+", ("multi-join", "group-by")),
    Q("q095", "What is the total succeeded-refund amount per order currency?",
      "SELECT o.currency_code, sum(r.amount) AS refunded "
      "FROM billing.payment_refunds r "
      "JOIN billing.payments p ON p.id = r.payment_id "
      "JOIN sales.orders o ON o.id = p.order_id "
      "WHERE r.status = 'succeeded' GROUP BY o.currency_code",
      ("billing.payment_refunds", "billing.payments", "sales.orders"),
      "multi-join", "2-hop+", ("multi-join", "group-by", "value-grounding")),

    # ---- analytical: window / CTE over big tables ------------------------
    Q("q096", "Show a running total of each customer's order grand totals over time "
      "(first 50 rows ordered by user then time).",
      "SELECT user_id, placed_at, grand_total, "
      "sum(grand_total) OVER (PARTITION BY user_id ORDER BY placed_at) AS running "
      "FROM sales.orders ORDER BY user_id, placed_at LIMIT 50",
      ("sales.orders",), "analytical", "named",
      ("window", "order-by", "limit")),
    Q("q097", "What is the monthly order count and its change from the previous month?",
      "WITH m AS (SELECT date_trunc('month', placed_at) AS month, count(*) AS orders "
      "FROM sales.orders GROUP BY 1) "
      "SELECT month, orders, orders - lag(orders) OVER (ORDER BY month) AS delta "
      "FROM m ORDER BY month",
      ("sales.orders",), "analytical", "named",
      ("window", "cte", "time-bucket", "order-by")),
    Q("q098", "Which 5 opportunity owners have the most won deals? Give owner user id and count.",
      "SELECT owner_user_id, count(*) AS won FROM crm.opportunities "
      "WHERE is_won = true GROUP BY owner_user_id ORDER BY won DESC LIMIT 5",
      ("crm.opportunities",), "single", "named",
      ("group-by", "order-by", "limit", "value-grounding")),
]
