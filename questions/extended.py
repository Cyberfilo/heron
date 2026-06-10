"""Extended heron question suite (v0). Gold SQL is validated by harness/audit.py.

Same contract and difficulty axes as questions/core.py:
  sql_shape: single | join | multi-join | analytical
  retrieval: named | 1-hop | 2-hop+ | lexical-gap   (how hard to FIND the tables)

This set exercises tables the core suite leaves untouched (inventory ledgers,
marketing sends, comms notifications, audit log, CRM pipeline, support CSAT,
analytics events/sessions, billing invoices/ledger, pricing coupons, FX rates)
and leans harder on multi-joins, window functions, CTEs, HAVING, anti-joins,
time-buckets, value-grounding and tenant isolation.
"""
from __future__ import annotations

from .schema import Question

Q = Question
QUESTIONS: list[Question] = [
    # ---- easy: single-table, named / value-grounding ---------------------
    Q("q041", "How many web sessions bounced?",
      "SELECT count(*) FROM analytics.web_sessions WHERE is_bounce = true",
      ("analytics.web_sessions",), "single", "named", ("value-grounding",)),
    Q("q042", "How many active coupons do we have?",
      "SELECT count(*) FROM pricing.coupons WHERE status = 'active'",
      ("pricing.coupons",), "single", "named", ("value-grounding",)),
    Q("q043", "What is the total amount of all successful refunds?",
      "SELECT sum(amount) FROM billing.payment_refunds WHERE status = 'succeeded'",
      ("billing.payment_refunds",), "single", "named",
      ("value-grounding", "aggregate")),
    Q("q044", "How many deletions are recorded in the audit log?",
      "SELECT count(*) FROM audit.audit_log WHERE action = 'delete'",
      ("audit.audit_log",), "single", "named", ("value-grounding",)),
    Q("q045", "What is the average CSAT score?",
      "SELECT avg(score) FROM support.csat_responses",
      ("support.csat_responses",), "single", "named", ("aggregate",)),
    Q("q046", "How many opportunities have been won?",
      "SELECT count(*) FROM crm.opportunities WHERE is_won = true",
      ("crm.opportunities",), "single", "named", ("value-grounding",)),

    # ---- easy/medium: lexical gap (NL term != schema term) ---------------
    Q("q047", "How many subscriptions have churned?",
      "SELECT count(*) FROM billing.subscriptions WHERE status = 'canceled'",
      ("billing.subscriptions",), "single", "lexical-gap",
      ("lexical-gap", "value-grounding")),
    Q("q048", "How many marketing blasts have already gone out?",
      "SELECT count(*) FROM marketing.campaigns WHERE status = 'sent'",
      ("marketing.campaigns",), "single", "lexical-gap",
      ("lexical-gap", "value-grounding")),
    Q("q049", "How many goods-out movements happened in the warehouse?",
      "SELECT count(*) FROM inventory.stock_movements WHERE kind = 'shipment'",
      ("inventory.stock_movements",), "single", "lexical-gap",
      ("lexical-gap", "value-grounding")),
    Q("q050", "How many leads turned into customers?",
      "SELECT count(*) FROM crm.leads WHERE status = 'converted'",
      ("crm.leads",), "single", "lexical-gap",
      ("lexical-gap", "value-grounding")),
    Q("q051", "How many failed webhook callbacks were there?",
      "SELECT count(*) FROM comms.webhook_deliveries WHERE status = 'failed'",
      ("comms.webhook_deliveries",), "single", "lexical-gap",
      ("lexical-gap", "value-grounding")),

    # ---- medium: group-by / time-bucket / ratio --------------------------
    Q("q052", "How many notifications are in each delivery state?",
      "SELECT status, count(*) FROM comms.notifications GROUP BY status",
      ("comms.notifications",), "single", "named", ("group-by",)),
    Q("q053", "Break down audit-log entries by action type.",
      "SELECT action, count(*) FROM audit.audit_log GROUP BY action",
      ("audit.audit_log",), "single", "named", ("group-by",)),
    Q("q054", "How many product-analytics events were recorded each month?",
      "SELECT date_trunc('month', occurred_at) AS month, count(*) AS events "
      "FROM analytics.events GROUP BY 1",
      ("analytics.events",), "single", "named", ("time-bucket", "group-by")),
    Q("q055", "How many background job runs failed, per status?",
      "SELECT status, count(*) FROM ops.job_runs GROUP BY status",
      ("ops.job_runs",), "single", "named", ("group-by",)),
    Q("q056", "What fraction of campaign messages bounced?",
      "SELECT count(*) FILTER (WHERE status = 'bounced')::numeric / count(*) "
      "FROM marketing.campaign_messages",
      ("marketing.campaign_messages",), "single", "named",
      ("ratio", "value-grounding")),
    Q("q057", "What is the total invoiced amount per currency?",
      "SELECT currency_code, sum(total) AS invoiced FROM billing.invoices "
      "GROUP BY currency_code",
      ("billing.invoices",), "single", "named", ("group-by",)),
    Q("q058", "How many opportunities are still open per tenant?",
      "SELECT tenant_id, count(*) FROM crm.opportunities "
      "WHERE is_closed = false GROUP BY tenant_id",
      ("crm.opportunities",), "single", "named",
      ("group-by", "tenant-aware", "value-grounding")),

    # ---- medium: one-hop joins -------------------------------------------
    Q("q059", "List each notification with the email of the user it was sent to.",
      "SELECT n.id, u.email FROM comms.notifications n "
      "JOIN identity.users u ON u.id = n.user_id",
      ("comms.notifications", "identity.users"), "join", "1-hop", ("join",)),
    Q("q060", "Show each opportunity with the name of its pipeline.",
      "SELECT o.name, p.name AS pipeline FROM crm.opportunities o "
      "JOIN crm.pipelines p ON p.id = o.pipeline_id",
      ("crm.opportunities", "crm.pipelines"), "join", "1-hop", ("join",)),
    Q("q061", "How many refunds were issued against captured payments?",
      "SELECT count(*) FROM billing.payment_refunds r "
      "JOIN billing.payments p ON p.id = r.payment_id "
      "WHERE p.status = 'captured'",
      ("billing.payment_refunds", "billing.payments"), "join", "1-hop",
      ("join", "value-grounding")),
    Q("q062", "Which coupons have never been redeemed?",
      "SELECT c.id, c.code FROM pricing.coupons c "
      "LEFT JOIN pricing.coupon_redemptions r ON r.coupon_id = c.id "
      "WHERE r.id IS NULL",
      ("pricing.coupons", "pricing.coupon_redemptions"), "join", "1-hop",
      ("anti-join",)),
    Q("q063", "What is the total redeemed discount per coupon code?",
      "SELECT c.code, sum(r.discount_amount) AS redeemed "
      "FROM pricing.coupon_redemptions r "
      "JOIN pricing.coupons c ON c.id = r.coupon_id GROUP BY c.code",
      ("pricing.coupon_redemptions", "pricing.coupons"), "join", "1-hop",
      ("join", "group-by")),
    Q("q064", "Which support agents have an average CSAT below 3? List agent id and score.",
      "SELECT rated_agent_id, avg(score) AS avg_score "
      "FROM support.csat_responses WHERE rated_agent_id IS NOT NULL "
      "GROUP BY rated_agent_id HAVING avg(score) < 3",
      ("support.csat_responses",), "single", "named", ("group-by", "having")),

    # ---- medium/hard: HAVING + window + analytical -----------------------
    Q("q065", "Which campaigns sent more than 100 messages? Give the campaign name and the count.",
      "SELECT c.name, count(*) AS sends FROM marketing.campaigns c "
      "JOIN marketing.campaign_messages m ON m.campaign_id = c.id "
      "GROUP BY c.name HAVING count(*) > 100",
      ("marketing.campaigns", "marketing.campaign_messages"), "join", "1-hop",
      ("group-by", "having")),
    Q("q066", "Rank pipelines by their number of won opportunities.",
      "SELECT p.name, count(*) AS won, "
      "rank() OVER (ORDER BY count(*) DESC) AS rnk "
      "FROM crm.opportunities o JOIN crm.pipelines p ON p.id = o.pipeline_id "
      "WHERE o.is_won = true GROUP BY p.name ORDER BY won DESC",
      ("crm.opportunities", "crm.pipelines"), "analytical", "1-hop",
      ("window", "order-by", "value-grounding")),
    Q("q067", "What is the running monthly total of net ledger debits over time?",
      "WITH monthly AS ("
      "  SELECT date_trunc('month', occurred_at) AS month, sum(amount) AS debit "
      "  FROM billing.ledger_entries WHERE direction = 'debit' GROUP BY 1) "
      "SELECT month, debit, sum(debit) OVER (ORDER BY month) AS running_total "
      "FROM monthly ORDER BY month",
      ("billing.ledger_entries",), "analytical", "named",
      ("window", "cte", "time-bucket", "order-by", "value-grounding")),
    Q("q068", "What are the top 5 event names by volume?",
      "SELECT event_name, count(*) AS n FROM analytics.events "
      "GROUP BY event_name ORDER BY n DESC LIMIT 5",
      ("analytics.events",), "single", "named",
      ("group-by", "order-by", "limit")),

    # ---- hard: multi-join / 2-hop+ ---------------------------------------
    Q("q069", "What is the average CSAT score per support agent display name?",
      "SELECT sa.display_name, avg(cr.score) AS avg_score "
      "FROM support.csat_responses cr "
      "JOIN support.support_agents sa ON sa.id = cr.rated_agent_id "
      "GROUP BY sa.display_name",
      ("support.csat_responses", "support.support_agents"), "join", "1-hop",
      ("join", "group-by")),
    Q("q070", "How many stock movements happened per warehouse name?",
      "SELECT w.name, count(*) AS movements FROM inventory.stock_movements m "
      "JOIN inventory.stock_locations l ON l.id = m.stock_location_id "
      "JOIN inventory.warehouses w ON w.id = l.warehouse_id "
      "GROUP BY w.name",
      ("inventory.stock_movements", "inventory.stock_locations",
       "inventory.warehouses"), "multi-join", "2-hop+",
      ("multi-join", "group-by")),
    Q("q071", "Which users opened a marketing email but never placed an order? List their emails.",
      "SELECT DISTINCT u.email FROM identity.users u "
      "JOIN marketing.campaign_messages m ON m.user_id = u.id "
      "LEFT JOIN sales.orders o ON o.user_id = u.id "
      "WHERE m.opened_at IS NOT NULL AND o.id IS NULL",
      ("identity.users", "marketing.campaign_messages", "sales.orders"),
      "multi-join", "1-hop", ("multi-join", "anti-join", "distinct")),
    Q("q072", "For paid invoices, what is the total invoiced amount per subscription plan code?",
      "SELECT pl.code, sum(i.total) AS invoiced FROM billing.invoices i "
      "JOIN billing.subscriptions s ON s.id = i.subscription_id "
      "JOIN billing.plans pl ON pl.id = s.plan_id "
      "WHERE i.status = 'paid' GROUP BY pl.code",
      ("billing.invoices", "billing.subscriptions", "billing.plans"),
      "multi-join", "2-hop+", ("multi-join", "group-by", "value-grounding")),
    Q("q073", "What is the total refunded amount per shipping country?",
      "SELECT c.name AS country, sum(r.amount) AS refunded "
      "FROM billing.payment_refunds r "
      "JOIN billing.payments p ON p.id = r.payment_id "
      "JOIN sales.orders o ON o.id = p.order_id "
      "JOIN geo.addresses a ON a.id = o.shipping_address_id "
      "JOIN geo.countries c ON c.id = a.country_id "
      "WHERE r.status = 'succeeded' GROUP BY c.name",
      ("billing.payment_refunds", "billing.payments", "sales.orders",
       "geo.addresses", "geo.countries"), "multi-join", "2-hop+",
      ("multi-join", "group-by", "value-grounding")),
    Q("q074", "Confirm each notification's user shares the notification's tenant: count such notifications.",
      "SELECT count(*) FROM comms.notifications n "
      "JOIN identity.users u ON u.id = n.user_id "
      "AND u.tenant_id = n.tenant_id",
      ("comms.notifications", "identity.users"), "join", "1-hop",
      ("tenant-isolation",)),
    Q("q075", "Which active subscribers on the enterprise plan have ever opened a support ticket? List their emails.",
      "SELECT DISTINCT u.email FROM identity.users u "
      "JOIN billing.subscriptions s ON s.user_id = u.id "
      "JOIN billing.plans pl ON pl.id = s.plan_id "
      "JOIN support.tickets t ON t.requester_user_id = u.id "
      "WHERE s.status = 'active' AND pl.code = 'enterprise'",
      ("identity.users", "billing.subscriptions", "billing.plans",
       "support.tickets"), "multi-join", "2-hop+",
      ("multi-join", "value-grounding", "distinct")),
]
