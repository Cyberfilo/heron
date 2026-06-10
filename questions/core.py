"""Core heron question suite (v0). Gold SQL is validated by harness/audit.py.

Difficulty axes (docs/METHODOLOGY.md §4):
  sql_shape: single | join | multi-join | analytical
  retrieval: named | 1-hop | 2-hop+ | lexical-gap   (how hard to FIND the tables)
"""
from __future__ import annotations

from .schema import Question

Q = Question
QUESTIONS: list[Question] = [
    # ---- easy: single-table, named ---------------------------------------
    Q("q001", "How many users are there in total?",
      "SELECT count(*) FROM identity.users",
      ("identity.users",), "single", "named", ("count",)),
    Q("q002", "How many products are currently active?",
      "SELECT count(*) FROM catalog.products WHERE status = 'active'",
      ("catalog.products",), "single", "named", ("value-grounding",)),
    Q("q003", "List all currency codes we support.",
      "SELECT code FROM geo.currencies",
      ("geo.currencies",), "single", "named", ("lookup",)),
    Q("q004", "How many orders have been refunded?",
      "SELECT count(*) FROM sales.orders WHERE status = 'refunded'",
      ("sales.orders",), "single", "named", ("value-grounding",)),
    Q("q005", "What is the average grand total of an order?",
      "SELECT avg(grand_total) FROM sales.orders",
      ("sales.orders",), "single", "named", ("aggregate",)),
    Q("q006", "How many support tickets have urgent priority?",
      "SELECT count(*) FROM support.tickets WHERE priority = 'urgent'",
      ("support.tickets",), "single", "named", ("value-grounding",)),
    Q("q007", "What distinct order statuses exist?",
      "SELECT DISTINCT status FROM sales.orders",
      ("sales.orders",), "single", "named", ("distinct",)),
    Q("q008", "What is the total amount of all captured payments?",
      "SELECT sum(amount) FROM billing.payments WHERE status = 'captured'",
      ("billing.payments",), "single", "named", ("value-grounding", "aggregate")),
    Q("q009", "How many products have been archived?",
      "SELECT count(*) FROM catalog.products WHERE status = 'archived'",
      ("catalog.products",), "single", "named", ("value-grounding",)),
    Q("q010", "How many subscriptions are active?",
      "SELECT count(*) FROM billing.subscriptions WHERE status = 'active'",
      ("billing.subscriptions",), "single", "named", ("value-grounding",)),
    Q("q011", "How many countries are in Europe?",
      "SELECT count(*) FROM geo.countries WHERE continent = 'Europe'",
      ("geo.countries",), "single", "named", ("value-grounding",)),
    Q("q012", "What is the average number of employees across accounts?",
      "SELECT avg(employee_count) FROM crm.accounts",
      ("crm.accounts",), "single", "named", ("aggregate",)),

    # ---- easy/medium: lexical gap (NL term != schema term) ----------------
    Q("q013", "How many sign-ups do we have?",
      "SELECT count(*) FROM identity.users",
      ("identity.users",), "single", "lexical-gap", ("lexical-gap",)),
    Q("q014", "How many help desk tickets are still open?",
      "SELECT count(*) FROM support.tickets WHERE status = 'open'",
      ("support.tickets",), "single", "lexical-gap", ("lexical-gap", "value-grounding")),
    Q("q015", "How many invoices are overdue?",
      "SELECT count(*) FROM billing.invoices WHERE status = 'past_due'",
      ("billing.invoices",), "single", "lexical-gap", ("lexical-gap", "value-grounding")),

    # ---- medium: one-hop joins -------------------------------------------
    Q("q016", "List each product with its brand name.",
      "SELECT p.name AS product, b.name AS brand "
      "FROM catalog.products p JOIN catalog.brands b ON b.id = p.brand_id",
      ("catalog.products", "catalog.brands"), "join", "1-hop", ("join",)),
    Q("q017", "Show each review together with the name of the product it is about.",
      "SELECT r.rating, p.name FROM catalog.product_reviews r "
      "JOIN catalog.products p ON p.id = r.product_id",
      ("catalog.product_reviews", "catalog.products"), "join", "1-hop", ("join",)),
    Q("q018", "List each subscription with the name of its plan.",
      "SELECT s.id, pl.name FROM billing.subscriptions s "
      "JOIN billing.plans pl ON pl.id = s.plan_id",
      ("billing.subscriptions", "billing.plans"), "join", "1-hop", ("join",)),
    Q("q019", "Show each order with the email of the user who placed it.",
      "SELECT o.id, u.email FROM sales.orders o JOIN identity.users u ON u.id = o.user_id",
      ("sales.orders", "identity.users"), "join", "1-hop", ("join",)),
    Q("q020", "Which products have never been reviewed?",
      "SELECT p.id, p.name FROM catalog.products p "
      "LEFT JOIN catalog.product_reviews r ON r.product_id = p.id WHERE r.id IS NULL",
      ("catalog.products", "catalog.product_reviews"), "join", "1-hop", ("anti-join",)),
    Q("q021", "How many active subscribers are on the pro plan?",
      "SELECT count(*) FROM billing.subscriptions s JOIN billing.plans pl ON pl.id = s.plan_id "
      "WHERE pl.code = 'pro' AND s.status = 'active'",
      ("billing.subscriptions", "billing.plans"), "join", "1-hop",
      ("value-grounding", "join")),

    # ---- medium: group by / having ---------------------------------------
    Q("q022", "What is the total order revenue per currency?",
      "SELECT currency_code, sum(grand_total) AS revenue FROM sales.orders GROUP BY currency_code",
      ("sales.orders",), "single", "named", ("group-by",)),
    Q("q023", "How many orders does each tenant have?",
      "SELECT tenant_id, count(*) FROM sales.orders GROUP BY tenant_id",
      ("sales.orders",), "single", "named", ("group-by", "tenant-aware")),
    Q("q024", "Which products have an average review rating above 4?",
      "SELECT product_id, avg(rating) AS avg_rating FROM catalog.product_reviews "
      "GROUP BY product_id HAVING avg(rating) > 4",
      ("catalog.product_reviews",), "single", "named", ("group-by", "having")),
    Q("q025", "Which users have placed more than 3 orders?",
      "SELECT u.id, u.email, count(o.id) AS n FROM identity.users u "
      "JOIN sales.orders o ON o.user_id = u.id GROUP BY u.id, u.email HAVING count(o.id) > 3",
      ("identity.users", "sales.orders"), "join", "1-hop", ("group-by", "having")),

    # ---- hard: multi-join / 2-hop+ / analytical --------------------------
    Q("q026", "What is the total order revenue per shipping country?",
      "SELECT c.name AS country, sum(o.grand_total) AS revenue FROM sales.orders o "
      "JOIN geo.addresses a ON a.id = o.shipping_address_id "
      "JOIN geo.countries c ON c.id = a.country_id GROUP BY c.name",
      ("sales.orders", "geo.addresses", "geo.countries"), "multi-join", "2-hop+",
      ("multi-join", "group-by")),
    Q("q027", "What are the top 5 products by total units sold?",
      "SELECT pv.product_id, sum(oi.quantity) AS units FROM sales.order_items oi "
      "JOIN catalog.product_variants pv ON pv.id = oi.product_variant_id "
      "GROUP BY pv.product_id ORDER BY units DESC LIMIT 5",
      ("sales.order_items", "catalog.product_variants"), "multi-join", "1-hop",
      ("group-by", "order-by", "limit")),
    Q("q028", "Which customers have ever received a refund? List their emails.",
      "SELECT DISTINCT u.email FROM identity.users u "
      "JOIN sales.orders o ON o.user_id = u.id "
      "JOIN billing.payments p ON p.order_id = o.id WHERE p.status = 'refunded'",
      ("identity.users", "sales.orders", "billing.payments"), "multi-join", "1-hop",
      ("multi-join", "distinct")),
    Q("q029", "How many users have a shipping or billing address in Germany?",
      "SELECT count(DISTINCT a.user_id) FROM geo.addresses a "
      "JOIN geo.countries c ON c.id = a.country_id WHERE c.name = 'Germany'",
      ("geo.addresses", "geo.countries"), "join", "2-hop+",
      ("value-grounding", "distinct")),
    Q("q030", "How many active subscriptions are there per plan code?",
      "SELECT pl.code, count(*) FROM billing.subscriptions s "
      "JOIN billing.plans pl ON pl.id = s.plan_id WHERE s.status = 'active' GROUP BY pl.code",
      ("billing.subscriptions", "billing.plans"), "join", "1-hop",
      ("group-by", "value-grounding")),
    Q("q031", "What is the monthly order count for the last 12 months?",
      "SELECT date_trunc('month', placed_at) AS month, count(*) AS orders FROM sales.orders "
      "WHERE placed_at >= date_trunc('month', DATE '2026-06-01') - INTERVAL '12 months' "
      "GROUP BY 1",
      ("sales.orders",), "single", "named", ("time-bucket",)),
    Q("q032", "Rank tenants by their total order revenue.",
      "SELECT tenant_id, sum(grand_total) AS revenue, "
      "rank() OVER (ORDER BY sum(grand_total) DESC) AS rnk FROM sales.orders "
      "GROUP BY tenant_id ORDER BY revenue DESC",
      ("sales.orders",), "analytical", "named", ("window", "tenant-aware", "order-by")),
    Q("q033", "What is the average number of days to resolve a support ticket?",
      "SELECT avg(EXTRACT(EPOCH FROM (resolved_at - created_at)) / 86400.0) AS avg_days "
      "FROM support.tickets WHERE resolved_at IS NOT NULL",
      ("support.tickets",), "single", "named", ("date-math",)),
    Q("q034", "For each order, confirm the user belongs to the same tenant: count such orders.",
      "SELECT count(*) FROM sales.orders o JOIN identity.users u "
      "ON u.id = o.user_id AND u.tenant_id = o.tenant_id",
      ("sales.orders", "identity.users"), "join", "1-hop", ("tenant-isolation",)),
    Q("q035", "What are the top 3 categories by number of products?",
      "SELECT c.name, count(p.id) AS n FROM catalog.categories c "
      "JOIN catalog.products p ON p.primary_category_id = c.id "
      "GROUP BY c.name ORDER BY n DESC LIMIT 3",
      ("catalog.categories", "catalog.products"), "join", "1-hop",
      ("group-by", "order-by", "limit")),
    Q("q036", "What is the total revenue from orders placed in EUR?",
      "SELECT sum(grand_total) FROM sales.orders WHERE currency_code = 'EUR'",
      ("sales.orders",), "single", "named", ("value-grounding",)),
    Q("q037", "How many orders were cancelled, as a fraction of all orders?",
      "SELECT count(*) FILTER (WHERE status = 'cancelled')::numeric / count(*) FROM sales.orders",
      ("sales.orders",), "single", "named", ("ratio", "value-grounding")),
    Q("q038", "List accounts with more than 100 employees.",
      "SELECT id, name FROM crm.accounts WHERE employee_count > 100",
      ("crm.accounts",), "single", "named", ("filter",)),
    Q("q039", "What is the average order value per subscription plan?",
      "SELECT pl.code, avg(o.grand_total) AS aov FROM sales.orders o "
      "JOIN identity.users u ON u.id = o.user_id "
      "JOIN billing.subscriptions s ON s.user_id = u.id "
      "JOIN billing.plans pl ON pl.id = s.plan_id GROUP BY pl.code",
      ("sales.orders", "identity.users", "billing.subscriptions", "billing.plans"),
      "multi-join", "2-hop+", ("multi-join", "group-by")),
    Q("q040", "How many invoices were paid, per invoice status?",
      "SELECT status, count(*) FROM billing.invoices GROUP BY status",
      ("billing.invoices",), "single", "named", ("group-by",)),
]
