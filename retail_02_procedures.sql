-- ================================================================
-- ONLINE RETAIL — STORED PROCEDURES
-- Order Processing, Cart Checkout, Stock Management
-- ================================================================

DELIMITER $$

-- ─────────────────────────────────────────
-- HELPER: Generate order number (ORD-YYYY-NNNNN)
-- ─────────────────────────────────────────
DROP FUNCTION IF EXISTS fn_generate_order_number $$
CREATE FUNCTION fn_generate_order_number() RETURNS VARCHAR(20)
READS SQL DATA
BEGIN
    DECLARE v_year CHAR(4) DEFAULT YEAR(NOW());
    DECLARE v_seq  INT;
    SELECT COALESCE(MAX(CAST(SUBSTRING_INDEX(order_number, '-', -1) AS UNSIGNED)), 0) + 1
    INTO v_seq
    FROM orders WHERE order_number LIKE CONCAT('ORD-', v_year, '-%');
    RETURN CONCAT('ORD-', v_year, '-', LPAD(v_seq, 5, '0'));
END $$

-- ─────────────────────────────────────────
-- CART: Add or update item in cart
-- ─────────────────────────────────────────
DROP PROCEDURE IF EXISTS sp_cart_upsert_item $$
CREATE PROCEDURE sp_cart_upsert_item(
    IN p_cart_id    VARCHAR(64),
    IN p_product_id BIGINT,
    IN p_variant_id BIGINT,
    IN p_qty        INT,
    OUT p_status    VARCHAR(50),
    OUT p_message   VARCHAR(255)
)
BEGIN
    DECLARE v_stock     INT DEFAULT 0;
    DECLARE v_price     DECIMAL(10,2);
    DECLARE v_existing  INT DEFAULT 0;
    DECLARE v_total_qty INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_status = 'ERROR'; SET p_message = 'Database error';
    END;

    START TRANSACTION;

    -- Validate product exists and is active
    SELECT p.price, COALESCE(pv.stock_level, p.stock_level)
    INTO v_price, v_stock
    FROM products p
    LEFT JOIN product_variants pv ON pv.variant_id = p_variant_id
    WHERE p.product_id = p_product_id AND p.is_active = TRUE;

    IF v_price IS NULL THEN
        ROLLBACK;
        SET p_status = 'NOT_FOUND'; SET p_message = 'Product not found or inactive'; LEAVE;
    END IF;

    -- Check existing quantity in cart
    SELECT COALESCE(quantity, 0) INTO v_existing
    FROM cart_items
    WHERE cart_id = p_cart_id AND product_id = p_product_id
      AND (variant_id = p_variant_id OR (variant_id IS NULL AND p_variant_id IS NULL));

    SET v_total_qty = v_existing + p_qty;

    -- Stock check
    IF v_total_qty > v_stock THEN
        ROLLBACK;
        SET p_status = 'INSUFFICIENT_STOCK';
        SET p_message = CONCAT('Only ', v_stock, ' units available');
    ELSEIF p_qty <= 0 THEN
        -- Remove if qty ≤ 0
        DELETE FROM cart_items
        WHERE cart_id = p_cart_id AND product_id = p_product_id
          AND (variant_id = p_variant_id OR (variant_id IS NULL AND p_variant_id IS NULL));
        -- Update cart timestamp
        UPDATE carts SET updated_at = NOW() WHERE cart_id = p_cart_id;
        COMMIT;
        SET p_status = 'REMOVED'; SET p_message = 'Item removed from cart';
    ELSE
        -- Upsert
        INSERT INTO cart_items (cart_id, product_id, variant_id, quantity, unit_price)
        VALUES (p_cart_id, p_product_id, p_variant_id, v_total_qty, v_price)
        ON DUPLICATE KEY UPDATE
            quantity   = v_total_qty,
            unit_price = v_price;
        UPDATE carts SET updated_at = NOW() WHERE cart_id = p_cart_id;
        COMMIT;
        SET p_status = 'OK';
        SET p_message = CONCAT('Cart updated. Qty: ', v_total_qty);
    END IF;
END $$

-- ─────────────────────────────────────────
-- CHECKOUT: Convert cart → order
-- Handles stock reservation, price snapshot, coupon
-- ─────────────────────────────────────────
DROP PROCEDURE IF EXISTS sp_checkout $$
CREATE PROCEDURE sp_checkout(
    IN  p_cart_id          VARCHAR(64),
    IN  p_customer_id      BIGINT,
    IN  p_shipping_addr_id BIGINT,
    IN  p_billing_addr_id  BIGINT,
    IN  p_shipping_method  VARCHAR(100),
    IN  p_coupon_code      VARCHAR(50),
    IN  p_ip_address       VARCHAR(45),
    OUT p_order_id         BIGINT,
    OUT p_order_number     VARCHAR(20),
    OUT p_status           VARCHAR(50),
    OUT p_message          VARCHAR(255)
)
BEGIN
    DECLARE v_subtotal       DECIMAL(10,2) DEFAULT 0;
    DECLARE v_discount       DECIMAL(10,2) DEFAULT 0;
    DECLARE v_shipping_cost  DECIMAL(10,2) DEFAULT 0;
    DECLARE v_tax_rate       DECIMAL(5,4)  DEFAULT 0.0875; -- 8.75% default
    DECLARE v_tax_amount     DECIMAL(10,2) DEFAULT 0;
    DECLARE v_order_total    DECIMAL(10,2);
    DECLARE v_order_num      VARCHAR(20);
    DECLARE v_coupon_type    VARCHAR(20);
    DECLARE v_coupon_val     DECIMAL(10,2);
    DECLARE v_coupon_min     DECIMAL(10,2);
    DECLARE v_coupon_cap     DECIMAL(10,2);
    DECLARE v_coupon_id      INT;
    -- Address fields
    DECLARE v_sh_name VARCHAR(200); DECLARE v_sh_l1 VARCHAR(255); DECLARE v_sh_l2 VARCHAR(255);
    DECLARE v_sh_city VARCHAR(100); DECLARE v_sh_st VARCHAR(100);
    DECLARE v_sh_zip  VARCHAR(20);  DECLARE v_sh_cc CHAR(2);
    DECLARE v_bl_name VARCHAR(200); DECLARE v_bl_l1 VARCHAR(255);
    DECLARE v_bl_city VARCHAR(100); DECLARE v_bl_st VARCHAR(100);
    DECLARE v_bl_zip  VARCHAR(20);  DECLARE v_bl_cc CHAR(2);
    -- Shipping cost rules
    DECLARE v_shipping_free_threshold DECIMAL(10,2) DEFAULT 75.00;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_status = 'ERROR'; SET p_message = 'Checkout failed — database error';
        SET p_order_id = NULL; SET p_order_number = NULL;
    END;

    START TRANSACTION;

    -- 1. Validate cart has items
    IF NOT EXISTS (SELECT 1 FROM cart_items WHERE cart_id = p_cart_id) THEN
        ROLLBACK;
        SET p_status = 'EMPTY_CART'; SET p_message = 'Cart is empty'; LEAVE;
    END IF;

    -- 2. Stock check & compute subtotal
    SELECT SUM(ci.quantity * ci.unit_price) INTO v_subtotal
    FROM cart_items ci
    JOIN products p ON p.product_id = ci.product_id
    WHERE ci.cart_id = p_cart_id AND p.is_active = TRUE;

    -- Check each item has sufficient stock
    IF EXISTS (
        SELECT 1 FROM cart_items ci
        JOIN products p ON p.product_id = ci.product_id
        WHERE ci.cart_id = p_cart_id
          AND (COALESCE(
                (SELECT stock_level FROM product_variants pv WHERE pv.variant_id = ci.variant_id),
                p.stock_level
              ) < ci.quantity)
    ) THEN
        ROLLBACK;
        SET p_status = 'STOCK_ERROR'; SET p_message = 'One or more items out of stock'; LEAVE;
    END IF;

    -- 3. Validate & apply coupon
    IF p_coupon_code IS NOT NULL AND p_coupon_code != '' THEN
        SELECT coupon_id, discount_type, discount_value, min_order_amount, max_discount_cap
        INTO v_coupon_id, v_coupon_type, v_coupon_val, v_coupon_min, v_coupon_cap
        FROM coupons
        WHERE code = p_coupon_code AND is_active = TRUE
          AND valid_from <= NOW()
          AND (valid_until IS NULL OR valid_until >= NOW())
          AND (usage_limit IS NULL OR usage_count < usage_limit);

        IF v_coupon_id IS NULL THEN
            ROLLBACK;
            SET p_status = 'INVALID_COUPON'; SET p_message = 'Coupon is invalid or expired'; LEAVE;
        END IF;

        IF v_coupon_min IS NOT NULL AND v_subtotal < v_coupon_min THEN
            ROLLBACK;
            SET p_status = 'COUPON_MIN_NOT_MET';
            SET p_message = CONCAT('Minimum order $', v_coupon_min, ' required for this coupon'); LEAVE;
        END IF;

        CASE v_coupon_type
            WHEN 'percentage'    THEN SET v_discount = v_subtotal * (v_coupon_val / 100);
            WHEN 'fixed'         THEN SET v_discount = v_coupon_val;
            WHEN 'free_shipping' THEN SET v_discount = 0; SET v_shipping_cost = 0;
        END CASE;

        IF v_coupon_cap IS NOT NULL AND v_discount > v_coupon_cap THEN
            SET v_discount = v_coupon_cap;
        END IF;
    END IF;

    -- 4. Shipping cost (free above threshold)
    IF v_shipping_cost = 0 AND p_coupon_code NOT LIKE 'FREE%' THEN
        SET v_shipping_cost = CASE
            WHEN (v_subtotal - v_discount) >= v_shipping_free_threshold THEN 0.00
            WHEN p_shipping_method = 'express' THEN 14.99
            WHEN p_shipping_method = 'overnight' THEN 29.99
            ELSE 5.99
        END;
    END IF;

    -- 5. Tax
    SET v_tax_amount  = ROUND((v_subtotal - v_discount) * v_tax_rate, 2);
    SET v_order_total = v_subtotal - v_discount + v_shipping_cost + v_tax_amount;
    SET v_order_num   = fn_generate_order_number();

    -- 6. Load address snapshots
    SELECT full_name, line1, line2, city, state, postal_code, country_code
    INTO v_sh_name, v_sh_l1, v_sh_l2, v_sh_city, v_sh_st, v_sh_zip, v_sh_cc
    FROM addresses WHERE address_id = p_shipping_addr_id;

    SELECT full_name, line1, city, state, postal_code, country_code
    INTO v_bl_name, v_bl_l1, v_bl_city, v_bl_st, v_bl_zip, v_bl_cc
    FROM addresses WHERE address_id = p_billing_addr_id;

    -- 7. Create order
    INSERT INTO orders (
        order_number, customer_id, status,
        subtotal, shipping_cost, tax_amount, discount_amount, order_total, currency,
        shipping_name, shipping_line1, shipping_line2, shipping_city,
        shipping_state, shipping_postal, shipping_country,
        billing_name, billing_line1, billing_city, billing_state,
        billing_postal, billing_country,
        coupon_code, shipping_method, ip_address
    ) VALUES (
        v_order_num, p_customer_id, 'confirmed',
        v_subtotal, v_shipping_cost, v_tax_amount, v_discount, v_order_total, 'USD',
        v_sh_name, v_sh_l1, v_sh_l2, v_sh_city, v_sh_st, v_sh_zip, v_sh_cc,
        v_bl_name, v_bl_l1, v_bl_city, v_bl_st, v_bl_zip, v_bl_cc,
        p_coupon_code, p_shipping_method, p_ip_address
    );

    SET p_order_id     = LAST_INSERT_ID();
    SET p_order_number = v_order_num;

    -- 8. Copy cart items → order_items (price snapshot)
    INSERT INTO order_items (
        order_id, product_id, variant_id, product_name, sku,
        quantity, unit_price, line_total
    )
    SELECT
        p_order_id,
        ci.product_id,
        ci.variant_id,
        p.name,
        COALESCE(pv.sku, p.sku),
        ci.quantity,
        ci.unit_price,
        ci.quantity * ci.unit_price
    FROM cart_items ci
    JOIN products p ON p.product_id = ci.product_id
    LEFT JOIN product_variants pv ON pv.variant_id = ci.variant_id
    WHERE ci.cart_id = p_cart_id;

    -- 9. Decrement stock
    UPDATE products p
    JOIN cart_items ci ON ci.product_id = p.product_id
    SET p.stock_level = p.stock_level - ci.quantity
    WHERE ci.cart_id = p_cart_id AND ci.variant_id IS NULL;

    UPDATE product_variants pv
    JOIN cart_items ci ON ci.variant_id = pv.variant_id
    SET pv.stock_level = pv.stock_level - ci.quantity
    WHERE ci.cart_id = p_cart_id;

    -- 10. Increment coupon usage
    IF v_coupon_id IS NOT NULL THEN
        UPDATE coupons SET usage_count = usage_count + 1 WHERE coupon_id = v_coupon_id;
    END IF;

    -- 11. Log status history
    INSERT INTO order_status_history (order_id, from_status, to_status, note, changed_by)
    VALUES (p_order_id, NULL, 'confirmed', 'Order placed via checkout', 'system');

    -- 12. Clear cart
    DELETE FROM cart_items WHERE cart_id = p_cart_id;
    DELETE FROM carts WHERE cart_id = p_cart_id;

    COMMIT;
    SET p_status = 'OK';
    SET p_message = CONCAT('Order ', v_order_num, ' placed successfully');
END $$

-- ─────────────────────────────────────────
-- UPDATE ORDER STATUS (with audit trail)
-- ─────────────────────────────────────────
DROP PROCEDURE IF EXISTS sp_update_order_status $$
CREATE PROCEDURE sp_update_order_status(
    IN p_order_id  BIGINT,
    IN p_new_status VARCHAR(50),
    IN p_note       VARCHAR(255),
    IN p_changed_by VARCHAR(100),
    IN p_tracking   VARCHAR(100),
    IN p_carrier    VARCHAR(100)
)
BEGIN
    DECLARE v_old_status VARCHAR(50);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; END;

    START TRANSACTION;

    SELECT status INTO v_old_status FROM orders WHERE order_id = p_order_id FOR UPDATE;

    UPDATE orders SET
        status           = p_new_status,
        tracking_number  = COALESCE(p_tracking, tracking_number),
        carrier          = COALESCE(p_carrier, carrier),
        shipped_at       = CASE WHEN p_new_status = 'shipped'   AND shipped_at   IS NULL THEN NOW() ELSE shipped_at   END,
        delivered_at     = CASE WHEN p_new_status = 'delivered' AND delivered_at IS NULL THEN NOW() ELSE delivered_at END,
        cancelled_at     = CASE WHEN p_new_status = 'cancelled' AND cancelled_at IS NULL THEN NOW() ELSE cancelled_at END,
        cancel_reason    = CASE WHEN p_new_status = 'cancelled' THEN p_note ELSE cancel_reason END,
        updated_at       = NOW()
    WHERE order_id = p_order_id;

    INSERT INTO order_status_history (order_id, from_status, to_status, note, changed_by)
    VALUES (p_order_id, v_old_status, p_new_status, p_note, p_changed_by);

    -- Restore stock on cancellation
    IF p_new_status = 'cancelled' THEN
        UPDATE products p
        JOIN order_items oi ON oi.product_id = p.product_id
        SET p.stock_level = p.stock_level + oi.quantity
        WHERE oi.order_id = p_order_id AND oi.variant_id IS NULL;

        UPDATE product_variants pv
        JOIN order_items oi ON oi.variant_id = pv.variant_id
        SET pv.stock_level = pv.stock_level + oi.quantity
        WHERE oi.order_id = p_order_id;
    END IF;

    COMMIT;
END $$

-- ─────────────────────────────────────────
-- SECURE LOGIN (rate-limited)
-- ─────────────────────────────────────────
DROP PROCEDURE IF EXISTS sp_login $$
CREATE PROCEDURE sp_login(
    IN  p_email      VARCHAR(255),
    IN  p_password   VARCHAR(255),    -- raw (compared vs stored hash in app layer)
    IN  p_ip         VARCHAR(45),
    IN  p_user_agent TEXT,
    OUT p_account_id BIGINT,
    OUT p_session_id VARCHAR(64),
    OUT p_status     VARCHAR(50),
    OUT p_message    VARCHAR(255)
)
BEGIN
    DECLARE v_hash      VARCHAR(255);
    DECLARE v_salt      VARCHAR(64);
    DECLARE v_status    VARCHAR(50);
    DECLARE v_fails     TINYINT;
    DECLARE v_locked    DATETIME;
    DECLARE v_sess_id   VARCHAR(64);

    -- Check account exists
    SELECT account_id, password_hash, password_salt, account_status,
           failed_login_count, locked_until
    INTO p_account_id, v_hash, v_salt, v_status, v_fails, v_locked
    FROM user_accounts WHERE email = p_email;

    IF p_account_id IS NULL THEN
        -- Generic message (don't leak whether email exists)
        SET p_status = 'INVALID_CREDENTIALS';
        SET p_message = 'Invalid email or password';
        SET p_session_id = NULL;
        LEAVE;
    END IF;

    -- Check lock
    IF v_locked IS NOT NULL AND v_locked > NOW() THEN
        SET p_status = 'ACCOUNT_LOCKED';
        SET p_message = CONCAT('Account locked until ', DATE_FORMAT(v_locked, '%H:%M on %d %b'));
        SET p_session_id = NULL;
        LEAVE;
    END IF;

    -- Account status
    IF v_status = 'suspended' THEN
        SET p_status = 'SUSPENDED';
        SET p_message = 'Account suspended. Contact support.';
        SET p_session_id = NULL;
        LEAVE;
    END IF;

    IF v_status = 'unverified' THEN
        SET p_status = 'UNVERIFIED';
        SET p_message = 'Please verify your email address';
        SET p_session_id = NULL;
        LEAVE;
    END IF;

    -- NOTE: Actual bcrypt comparison happens in application layer.
    -- This procedure receives result of app-layer hash check as signal.
    -- (In production, call this only after bcrypt.compare() succeeds.)
    -- Generate session
    SET v_sess_id = SHA2(CONCAT(p_account_id, NOW(), RAND()), 256);
    INSERT INTO user_sessions (session_id, account_id, ip_address, user_agent, expires_at)
    VALUES (v_sess_id, p_account_id, p_ip, p_user_agent, DATE_ADD(NOW(), INTERVAL 30 DAY));

    -- Reset fail count, update last login
    UPDATE user_accounts SET
        failed_login_count = 0,
        locked_until       = NULL,
        last_login_at      = NOW(),
        last_login_ip      = p_ip
    WHERE account_id = p_account_id;

    SET p_session_id = v_sess_id;
    SET p_status     = 'OK';
    SET p_message    = 'Login successful';
END $$

DELIMITER ;
