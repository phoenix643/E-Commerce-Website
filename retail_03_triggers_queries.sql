-- ================================================================
-- ONLINE RETAIL — TRIGGERS, QUERIES & REPORTS
-- ================================================================

-- ─────────────────────────────────────────
-- TRIGGERS
-- ─────────────────────────────────────────

-- 1. Auto-lock account after 5 failed logins
DELIMITER $$
DROP TRIGGER IF EXISTS trg_login_fail_lock $$
CREATE TRIGGER trg_login_fail_lock
BEFORE UPDATE ON user_accounts
FOR EACH ROW
BEGIN
    IF NEW.failed_login_count >= 5 AND OLD.locked_until IS NULL THEN
        SET NEW.locked_until = DATE_ADD(NOW(), INTERVAL 30 MINUTE);
    END IF;
END $$

-- 2. Low-stock alert log
CREATE TABLE IF NOT EXISTS stock_alerts (
    alert_id    BIGINT AUTO_INCREMENT PRIMARY KEY,
    product_id  BIGINT NOT NULL,
    sku         VARCHAR(100),
    product_name VARCHAR(255),
    stock_level INT,
    threshold   INT,
    alerted_at  DATETIME DEFAULT CURRENT_TIMESTAMP
) $$

DROP TRIGGER IF EXISTS trg_low_stock_alert $$
CREATE TRIGGER trg_low_stock_alert
AFTER UPDATE ON products
FOR EACH ROW
BEGIN
    IF NEW.stock_level <= NEW.low_stock_threshold
       AND OLD.stock_level > OLD.low_stock_threshold THEN
        INSERT INTO stock_alerts (product_id, sku, product_name, stock_level, threshold)
        VALUES (NEW.product_id, NEW.sku, NEW.name, NEW.stock_level, NEW.low_stock_threshold);
    END IF;
END $$

-- 3. Prevent negative stock
DROP TRIGGER IF EXISTS trg_prevent_negative_stock $$
CREATE TRIGGER trg_prevent_negative_stock
BEFORE UPDATE ON products
FOR EACH ROW
BEGIN
    IF NEW.stock_level < 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Stock level cannot go below zero';
    END IF;
END $$

-- 4. Auto-set order timestamps
DROP TRIGGER IF EXISTS trg_order_status_timestamps $$
CREATE TRIGGER trg_order_status_timestamps
BEFORE UPDATE ON orders
FOR EACH ROW
BEGIN
    IF NEW.status = 'shipped'   AND OLD.status != 'shipped'   THEN SET NEW.shipped_at   = COALESCE(NEW.shipped_at,   NOW()); END IF;
    IF NEW.status = 'delivered' AND OLD.status != 'delivered' THEN SET NEW.delivered_at = COALESCE(NEW.delivered_at, NOW()); END IF;
    IF NEW.status = 'cancelled' AND OLD.status != 'cancelled' THEN SET NEW.cancelled_at = COALESCE(NEW.cancelled_at, NOW()); END IF;
END $$
DELIMITER ;

-- ================================================================
-- TASK 1: PROCESS ORDER — UPDATE STOCK
-- ================================================================

-- View: Order processing queue (confirmed, not yet shipped)
CREATE OR REPLACE VIEW vw_processing_queue AS
SELECT
    o.order_id,
    o.order_number,
    o.created_at,
    o.status,
    c.first_name,
    c.last_name,
    c.email,
    o.order_total,
    o.shipping_method,
    o.shipping_name,
    CONCAT(o.shipping_line1, ', ', o.shipping_city, ', ', o.shipping_country) AS ship_to,
    COUNT(oi.order_item_id) AS item_count,
    SUM(oi.quantity)        AS total_units
FROM orders o
JOIN customers c  ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status IN ('confirmed','processing')
GROUP BY o.order_id
ORDER BY o.created_at ASC;

-- Stock level check across all products
CREATE OR REPLACE VIEW vw_stock_levels AS
SELECT
    p.product_id,
    p.sku,
    p.name,
    cat.name           AS category,
    p.stock_level,
    p.low_stock_threshold,
    CASE
        WHEN p.stock_level = 0              THEN 'OUT_OF_STOCK'
        WHEN p.stock_level <= p.low_stock_threshold THEN 'LOW_STOCK'
        ELSE 'IN_STOCK'
    END                AS stock_status,
    p.price,
    p.cost_price,
    ROUND((p.price - COALESCE(p.cost_price, 0)) / p.price * 100, 1) AS margin_pct
FROM products p
JOIN categories cat ON cat.category_id = p.category_id
WHERE p.is_active = TRUE
ORDER BY p.stock_level ASC;

-- ================================================================
-- TASK 2: ORDER HISTORY FOR INDIVIDUAL CUSTOMERS
-- ================================================================

-- Complete order history for a customer
CREATE OR REPLACE VIEW vw_customer_order_history AS
SELECT
    o.order_id,
    o.order_number,
    o.created_at        AS order_date,
    o.status,
    c.customer_id,
    c.first_name,
    c.last_name,
    c.email,
    o.subtotal,
    o.discount_amount,
    o.shipping_cost,
    o.tax_amount,
    o.order_total,
    o.coupon_code,
    o.shipping_method,
    o.tracking_number,
    o.carrier,
    o.shipped_at,
    o.delivered_at,
    -- Fulfillment timing
    DATEDIFF(o.shipped_at,   o.created_at) AS days_to_ship,
    DATEDIFF(o.delivered_at, o.shipped_at) AS days_to_deliver,
    -- Payment
    py.status           AS payment_status,
    py.method           AS payment_method,
    py.card_brand,
    py.card_last4
FROM orders o
JOIN customers c   ON c.customer_id   = o.customer_id
LEFT JOIN payments py ON py.order_id  = o.order_id
ORDER BY o.created_at DESC;

-- Full order detail (items) for a specific order
CREATE OR REPLACE VIEW vw_order_detail AS
SELECT
    o.order_id,
    o.order_number,
    o.status,
    o.created_at,
    -- Customer
    c.first_name,
    c.last_name,
    c.email,
    -- Item detail
    oi.order_item_id,
    oi.product_name,
    oi.sku,
    oi.quantity,
    oi.unit_price,
    oi.line_total,
    -- Current product info
    p.slug              AS product_slug,
    p.stock_level       AS current_stock,
    cat.name            AS category
FROM orders o
JOIN customers   c   ON c.customer_id   = o.customer_id
JOIN order_items oi  ON oi.order_id     = o.order_id
JOIN products    p   ON p.product_id    = oi.product_id
JOIN categories  cat ON cat.category_id = p.category_id;

-- Customer lifetime value summary
CREATE OR REPLACE VIEW vw_customer_ltv AS
SELECT
    c.customer_id,
    c.first_name,
    c.last_name,
    c.email,
    c.created_at        AS member_since,
    COUNT(DISTINCT o.order_id)                               AS total_orders,
    SUM(o.order_total)                                       AS lifetime_value,
    ROUND(AVG(o.order_total), 2)                             AS avg_order_value,
    MAX(o.order_total)                                       AS largest_order,
    MAX(o.created_at)                                        AS last_order_date,
    DATEDIFF(NOW(), MAX(o.created_at))                       AS days_since_last_order,
    SUM(CASE WHEN o.status = 'cancelled' THEN 1 ELSE 0 END)  AS cancelled_orders,
    ROUND(SUM(o.order_total) / NULLIF(COUNT(DISTINCT o.order_id), 0), 2) AS avg_basket,
    -- RFM tiers (simplified)
    CASE
        WHEN SUM(o.order_total) > 2000 AND COUNT(*) >= 5  THEN 'VIP'
        WHEN SUM(o.order_total) > 500  AND COUNT(*) >= 2  THEN 'Regular'
        WHEN COUNT(*) = 1                                  THEN 'New'
        ELSE 'Occasional'
    END AS customer_tier
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id
    AND o.status NOT IN ('cancelled')
GROUP BY c.customer_id, c.first_name, c.last_name, c.email, c.created_at
ORDER BY lifetime_value DESC;

-- ================================================================
-- TASK 3: SALES REPORTS
-- ================================================================

-- Sales by product (all time)
CREATE OR REPLACE VIEW vw_sales_by_product AS
SELECT
    p.product_id,
    p.sku,
    p.name                                                   AS product_name,
    cat.name                                                 AS category,
    p.price                                                  AS current_price,
    COUNT(DISTINCT oi.order_id)                              AS orders_containing,
    SUM(oi.quantity)                                         AS units_sold,
    SUM(oi.line_total)                                       AS gross_revenue,
    ROUND(SUM(oi.line_total) / NULLIF(SUM(oi.quantity), 0), 2) AS avg_sell_price,
    ROUND(SUM(oi.quantity) * COALESCE(p.cost_price, 0), 2)  AS total_cogs,
    ROUND(SUM(oi.line_total) - SUM(oi.quantity) * COALESCE(p.cost_price, 0), 2) AS gross_profit,
    ROUND((SUM(oi.line_total) - SUM(oi.quantity) * COALESCE(p.cost_price, 0))
          / NULLIF(SUM(oi.line_total), 0) * 100, 1)         AS margin_pct,
    p.stock_level                                            AS current_stock,
    RANK() OVER (ORDER BY SUM(oi.line_total) DESC)           AS revenue_rank
FROM products p
JOIN categories  cat ON cat.category_id = p.category_id
JOIN order_items oi  ON oi.product_id   = p.product_id
JOIN orders      o   ON o.order_id      = oi.order_id
    AND o.status NOT IN ('cancelled','refunded')
GROUP BY p.product_id, p.sku, p.name, cat.name, p.price, p.cost_price, p.stock_level
ORDER BY gross_revenue DESC;

-- Sales by category
CREATE OR REPLACE VIEW vw_sales_by_category AS
SELECT
    cat.category_id,
    cat.name                                                 AS category,
    COUNT(DISTINCT p.product_id)                             AS product_count,
    COUNT(DISTINCT o.order_id)                               AS order_count,
    SUM(oi.quantity)                                         AS units_sold,
    ROUND(SUM(oi.line_total), 2)                             AS gross_revenue,
    ROUND(SUM(oi.line_total) / (SELECT SUM(oi2.line_total)
          FROM order_items oi2
          JOIN orders o2 ON o2.order_id = oi2.order_id
          WHERE o2.status NOT IN ('cancelled','refunded')) * 100, 1) AS revenue_share_pct,
    ROUND(AVG(oi.unit_price), 2)                             AS avg_unit_price
FROM categories cat
JOIN products    p   ON p.category_id   = cat.category_id
JOIN order_items oi  ON oi.product_id   = p.product_id
JOIN orders      o   ON o.order_id      = oi.order_id
    AND o.status NOT IN ('cancelled','refunded')
GROUP BY cat.category_id, cat.name
ORDER BY gross_revenue DESC;

-- Monthly revenue trend
CREATE OR REPLACE VIEW vw_monthly_revenue AS
SELECT
    YEAR(o.created_at)                                       AS yr,
    MONTH(o.created_at)                                      AS mo,
    DATE_FORMAT(o.created_at, '%b %Y')                       AS month_label,
    COUNT(DISTINCT o.order_id)                               AS orders,
    COUNT(DISTINCT o.customer_id)                            AS unique_customers,
    ROUND(SUM(o.subtotal), 2)                                AS gross_revenue,
    ROUND(SUM(o.discount_amount), 2)                         AS total_discounts,
    ROUND(SUM(o.order_total), 2)                             AS net_revenue,
    ROUND(AVG(o.order_total), 2)                             AS avg_order_value,
    SUM(CASE WHEN o.status = 'cancelled' THEN 1 ELSE 0 END)  AS cancellations,
    ROUND(SUM(CASE WHEN o.status = 'cancelled'
              THEN o.order_total ELSE 0 END), 2)             AS cancelled_revenue
FROM orders o
GROUP BY YEAR(o.created_at), MONTH(o.created_at)
ORDER BY yr DESC, mo DESC;

-- ================================================================
-- BONUS: USEFUL ANALYTICAL QUERIES
-- ================================================================

-- Top 10 products needing restock
SELECT sku, name, stock_level, low_stock_threshold,
       (low_stock_threshold - stock_level) AS units_needed,
       stock_status
FROM vw_stock_levels
WHERE stock_status IN ('OUT_OF_STOCK','LOW_STOCK')
ORDER BY stock_level ASC
LIMIT 10;

-- Orders awaiting shipment > 24 hours
SELECT o.order_number, o.created_at, c.first_name, c.last_name,
       o.order_total, o.status,
       TIMESTAMPDIFF(HOUR, o.created_at, NOW()) AS hours_waiting
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
WHERE o.status IN ('confirmed','processing')
  AND o.created_at < DATE_SUB(NOW(), INTERVAL 24 HOUR)
ORDER BY o.created_at ASC;

-- Revenue per customer (top 20)
SELECT customer_id, first_name, last_name, email,
       total_orders, lifetime_value, avg_order_value,
       days_since_last_order, customer_tier
FROM vw_customer_ltv
LIMIT 20;

-- Payment method breakdown
SELECT
    py.method,
    COUNT(*) AS transactions,
    ROUND(SUM(py.amount), 2) AS total_processed,
    ROUND(AVG(py.amount), 2) AS avg_amount,
    SUM(CASE WHEN py.status = 'captured' THEN 1 ELSE 0 END) AS successful,
    SUM(CASE WHEN py.status = 'failed'   THEN 1 ELSE 0 END) AS failed,
    ROUND(SUM(CASE WHEN py.status = 'captured' THEN 1 ELSE 0 END)
          / COUNT(*) * 100, 1) AS success_rate_pct
FROM payments py
GROUP BY py.method
ORDER BY total_processed DESC;

-- Abandoned cart report
SELECT
    c.cart_id,
    c.customer_id,
    cu.email,
    cu.first_name,
    COUNT(ci.cart_item_id)           AS items,
    SUM(ci.quantity * ci.unit_price) AS cart_value,
    c.created_at,
    c.updated_at,
    TIMESTAMPDIFF(HOUR, c.updated_at, NOW()) AS hours_idle
FROM carts c
LEFT JOIN customers cu ON cu.customer_id = c.customer_id
JOIN cart_items ci ON ci.cart_id = c.cart_id
WHERE c.updated_at < DATE_SUB(NOW(), INTERVAL 1 HOUR)
GROUP BY c.cart_id, c.customer_id, cu.email, cu.first_name, c.created_at, c.updated_at
ORDER BY cart_value DESC;
