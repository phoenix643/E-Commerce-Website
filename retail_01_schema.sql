-- ================================================================
-- ONLINE RETAIL APPLICATION DATABASE
-- Complete Schema: Products, Customers, Orders, Payments, Auth
-- ================================================================

-- ─────────────────────────────────────────
-- AUTHENTICATION & USER ACCOUNTS
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_accounts (
    account_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    email               VARCHAR(255) NOT NULL UNIQUE,
    password_hash       VARCHAR(255) NOT NULL,        -- bcrypt hash (never plaintext)
    password_salt       VARCHAR(64)  NOT NULL,
    account_status      ENUM('active','suspended','unverified','locked') NOT NULL DEFAULT 'unverified',
    email_verified      BOOLEAN NOT NULL DEFAULT FALSE,
    email_verify_token  VARCHAR(64),
    failed_login_count  TINYINT NOT NULL DEFAULT 0,
    locked_until        DATETIME,
    last_login_at       DATETIME,
    last_login_ip       VARCHAR(45),
    password_reset_token VARCHAR(64),
    password_reset_exp  DATETIME,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_ua_email  (email),
    INDEX idx_ua_status (account_status)
);

CREATE TABLE IF NOT EXISTS user_sessions (
    session_id          VARCHAR(64) PRIMARY KEY,      -- cryptographically random
    account_id          BIGINT NOT NULL,
    ip_address          VARCHAR(45),
    user_agent          TEXT,
    expires_at          DATETIME NOT NULL,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (account_id) REFERENCES user_accounts(account_id) ON DELETE CASCADE,
    INDEX idx_sess_account (account_id),
    INDEX idx_sess_expiry  (expires_at)
);

-- ─────────────────────────────────────────
-- CUSTOMERS (linked 1:1 to user_accounts)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customers (
    customer_id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    account_id          BIGINT UNIQUE,                -- NULL for guest checkouts
    first_name          VARCHAR(100) NOT NULL,
    last_name           VARCHAR(100) NOT NULL,
    email               VARCHAR(255) NOT NULL,
    phone               VARCHAR(30),
    date_of_birth       DATE,
    loyalty_points      INT NOT NULL DEFAULT 0,
    preferred_currency  CHAR(3) NOT NULL DEFAULT 'USD',
    marketing_opt_in    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (account_id) REFERENCES user_accounts(account_id) ON DELETE SET NULL,
    INDEX idx_cust_email   (email),
    INDEX idx_cust_account (account_id)
);

CREATE TABLE IF NOT EXISTS addresses (
    address_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    customer_id         BIGINT NOT NULL,
    address_type        ENUM('shipping','billing','both') NOT NULL DEFAULT 'both',
    label               VARCHAR(50),                  -- "Home", "Office", etc.
    full_name           VARCHAR(200) NOT NULL,
    line1               VARCHAR(255) NOT NULL,
    line2               VARCHAR(255),
    city                VARCHAR(100) NOT NULL,
    state               VARCHAR(100),
    postal_code         VARCHAR(20) NOT NULL,
    country_code        CHAR(2) NOT NULL DEFAULT 'US',
    is_default          BOOLEAN NOT NULL DEFAULT FALSE,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE,
    INDEX idx_addr_customer (customer_id)
);

-- ─────────────────────────────────────────
-- PRODUCT CATALOG
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS categories (
    category_id         INT AUTO_INCREMENT PRIMARY KEY,
    parent_id           INT,                           -- for nested categories
    name                VARCHAR(100) NOT NULL,
    slug                VARCHAR(100) NOT NULL UNIQUE,
    description         TEXT,
    image_url           VARCHAR(500),
    display_order       INT NOT NULL DEFAULT 0,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (parent_id) REFERENCES categories(category_id) ON DELETE SET NULL,
    INDEX idx_cat_parent (parent_id),
    INDEX idx_cat_slug   (slug)
);

CREATE TABLE IF NOT EXISTS products (
    product_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    category_id         INT NOT NULL,
    sku                 VARCHAR(100) NOT NULL UNIQUE,
    name                VARCHAR(255) NOT NULL,
    slug                VARCHAR(255) NOT NULL UNIQUE,
    description         TEXT,
    short_description   VARCHAR(500),
    price               DECIMAL(10,2) NOT NULL,
    compare_price       DECIMAL(10,2),                -- "was" price for sale display
    cost_price          DECIMAL(10,2),                -- for margin calculation
    stock_level         INT NOT NULL DEFAULT 0,
    low_stock_threshold INT NOT NULL DEFAULT 5,
    weight_grams        INT,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    is_featured         BOOLEAN NOT NULL DEFAULT FALSE,
    requires_shipping   BOOLEAN NOT NULL DEFAULT TRUE,
    tax_class           ENUM('standard','reduced','zero','exempt') NOT NULL DEFAULT 'standard',
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (category_id) REFERENCES categories(category_id),
    INDEX idx_prod_category (category_id),
    INDEX idx_prod_sku      (sku),
    INDEX idx_prod_stock    (stock_level),
    INDEX idx_prod_active   (is_active)
);

CREATE TABLE IF NOT EXISTS product_images (
    image_id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    product_id          BIGINT NOT NULL,
    url                 VARCHAR(500) NOT NULL,
    alt_text            VARCHAR(255),
    display_order       INT NOT NULL DEFAULT 0,
    is_primary          BOOLEAN NOT NULL DEFAULT FALSE,
    FOREIGN KEY (product_id) REFERENCES products(product_id) ON DELETE CASCADE,
    INDEX idx_pimg_product (product_id)
);

CREATE TABLE IF NOT EXISTS product_variants (
    variant_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    product_id          BIGINT NOT NULL,
    sku                 VARCHAR(100) NOT NULL UNIQUE,
    variant_name        VARCHAR(100) NOT NULL,         -- "Large / Red"
    price_modifier      DECIMAL(8,2) NOT NULL DEFAULT 0.00,
    stock_level         INT NOT NULL DEFAULT 0,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    FOREIGN KEY (product_id) REFERENCES products(product_id) ON DELETE CASCADE,
    INDEX idx_pvar_product (product_id)
);

-- ─────────────────────────────────────────
-- SHOPPING CART
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS carts (
    cart_id             VARCHAR(64) PRIMARY KEY,       -- UUID, persists across sessions
    customer_id         BIGINT,                        -- NULL until logged in
    session_token       VARCHAR(64),                   -- for anonymous carts
    currency            CHAR(3) NOT NULL DEFAULT 'USD',
    coupon_code         VARCHAR(50),
    discount_amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    notes               TEXT,
    expires_at          DATETIME NOT NULL,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE SET NULL,
    INDEX idx_cart_customer (customer_id),
    INDEX idx_cart_session  (session_token),
    INDEX idx_cart_expiry   (expires_at)
);

CREATE TABLE IF NOT EXISTS cart_items (
    cart_item_id        BIGINT AUTO_INCREMENT PRIMARY KEY,
    cart_id             VARCHAR(64) NOT NULL,
    product_id          BIGINT NOT NULL,
    variant_id          BIGINT,
    quantity            INT NOT NULL DEFAULT 1,
    unit_price          DECIMAL(10,2) NOT NULL,        -- snapshot at time of add
    added_at            DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (cart_id)    REFERENCES carts(cart_id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(product_id),
    FOREIGN KEY (variant_id) REFERENCES product_variants(variant_id) ON DELETE SET NULL,
    UNIQUE KEY uq_cart_product (cart_id, product_id, variant_id),
    INDEX idx_ci_cart (cart_id)
);

-- ─────────────────────────────────────────
-- COUPONS & DISCOUNTS
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS coupons (
    coupon_id           INT AUTO_INCREMENT PRIMARY KEY,
    code                VARCHAR(50) NOT NULL UNIQUE,
    description         VARCHAR(255),
    discount_type       ENUM('percentage','fixed','free_shipping') NOT NULL,
    discount_value      DECIMAL(10,2) NOT NULL,
    min_order_amount    DECIMAL(10,2),
    max_discount_cap    DECIMAL(10,2),
    usage_limit         INT,
    usage_count         INT NOT NULL DEFAULT 0,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    valid_from          DATETIME NOT NULL,
    valid_until         DATETIME,
    INDEX idx_coupon_code (code)
);

-- ─────────────────────────────────────────
-- ORDERS
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS orders (
    order_id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_number        VARCHAR(20) NOT NULL UNIQUE,   -- human-readable e.g. ORD-2024-00001
    customer_id         BIGINT NOT NULL,
    status              ENUM('pending','confirmed','processing','shipped',
                             'delivered','cancelled','refunded','on_hold') NOT NULL DEFAULT 'pending',
    -- Pricing
    subtotal            DECIMAL(10,2) NOT NULL,
    shipping_cost       DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    tax_amount          DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    discount_amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    order_total         DECIMAL(10,2) NOT NULL,
    currency            CHAR(3) NOT NULL DEFAULT 'USD',
    -- Addresses (snapshot at checkout)
    shipping_name       VARCHAR(200),
    shipping_line1      VARCHAR(255),
    shipping_line2      VARCHAR(255),
    shipping_city       VARCHAR(100),
    shipping_state      VARCHAR(100),
    shipping_postal     VARCHAR(20),
    shipping_country    CHAR(2),
    billing_name        VARCHAR(200),
    billing_line1       VARCHAR(255),
    billing_city        VARCHAR(100),
    billing_state       VARCHAR(100),
    billing_postal      VARCHAR(20),
    billing_country     CHAR(2),
    -- Fulfillment
    coupon_code         VARCHAR(50),
    shipping_method     VARCHAR(100),
    tracking_number     VARCHAR(100),
    carrier             VARCHAR(100),
    estimated_delivery  DATE,
    shipped_at          DATETIME,
    delivered_at        DATETIME,
    cancelled_at        DATETIME,
    cancel_reason       VARCHAR(255),
    notes               TEXT,
    -- Meta
    ip_address          VARCHAR(45),
    user_agent          TEXT,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    INDEX idx_order_customer  (customer_id),
    INDEX idx_order_status    (status),
    INDEX idx_order_created   (created_at),
    INDEX idx_order_number    (order_number)
);

CREATE TABLE IF NOT EXISTS order_items (
    order_item_id       BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id            BIGINT NOT NULL,
    product_id          BIGINT NOT NULL,
    variant_id          BIGINT,
    product_name        VARCHAR(255) NOT NULL,          -- snapshot
    sku                 VARCHAR(100) NOT NULL,           -- snapshot
    quantity            INT NOT NULL,
    unit_price          DECIMAL(10,2) NOT NULL,          -- snapshot
    discount_amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    tax_amount          DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    line_total          DECIMAL(10,2) NOT NULL,
    FOREIGN KEY (order_id)   REFERENCES orders(order_id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(product_id),
    INDEX idx_oi_order   (order_id),
    INDEX idx_oi_product (product_id)
);

-- ─────────────────────────────────────────
-- PAYMENTS
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS payments (
    payment_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id            BIGINT NOT NULL,
    gateway             ENUM('stripe','paypal','braintree','manual') NOT NULL,
    gateway_txn_id      VARCHAR(255),                   -- Stripe charge ID, etc.
    gateway_intent_id   VARCHAR(255),                   -- Stripe PaymentIntent
    method              ENUM('card','paypal','bank_transfer','wallet','cash') NOT NULL,
    status              ENUM('pending','authorized','captured','failed','refunded','partial_refund') NOT NULL DEFAULT 'pending',
    amount              DECIMAL(10,2) NOT NULL,
    currency            CHAR(3) NOT NULL DEFAULT 'USD',
    -- Card details (tokenized — never raw PAN)
    card_brand          VARCHAR(30),                    -- "visa", "mastercard"
    card_last4          CHAR(4),
    card_exp_month      TINYINT,
    card_exp_year       SMALLINT,
    -- Risk
    fraud_score         DECIMAL(5,3),
    avs_result          CHAR(1),                        -- Address Verification
    cvv_result          CHAR(1),
    -- Refunds
    refunded_amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    refund_reason       VARCHAR(255),
    -- Meta
    gateway_response    JSON,                           -- raw gateway payload
    failure_code        VARCHAR(50),
    failure_message     TEXT,
    processed_at        DATETIME,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    INDEX idx_pay_order   (order_id),
    INDEX idx_pay_gateway (gateway_txn_id),
    INDEX idx_pay_status  (status)
);

-- ─────────────────────────────────────────
-- ORDER STATUS HISTORY (audit trail)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS order_status_history (
    history_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id            BIGINT NOT NULL,
    from_status         VARCHAR(50),
    to_status           VARCHAR(50) NOT NULL,
    note                TEXT,
    changed_by          VARCHAR(100),                   -- email or 'system'
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (order_id) REFERENCES orders(order_id) ON DELETE CASCADE,
    INDEX idx_osh_order (order_id)
);

-- ─────────────────────────────────────────
-- REVIEWS
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS product_reviews (
    review_id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    product_id          BIGINT NOT NULL,
    customer_id         BIGINT NOT NULL,
    order_id            BIGINT,                         -- verified purchase link
    rating              TINYINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    title               VARCHAR(255),
    body                TEXT,
    status              ENUM('pending','approved','rejected') NOT NULL DEFAULT 'pending',
    helpful_count       INT NOT NULL DEFAULT 0,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id)  REFERENCES products(product_id),
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    FOREIGN KEY (order_id)    REFERENCES orders(order_id) ON DELETE SET NULL,
    UNIQUE KEY uq_review_purchase (customer_id, order_id, product_id),
    INDEX idx_rev_product (product_id)
);

-- ─────────────────────────────────────────
-- SEED: CATEGORIES & SAMPLE PRODUCTS
-- ─────────────────────────────────────────
INSERT IGNORE INTO categories (category_id, name, slug, description) VALUES
(1,  'Electronics',        'electronics',        'Gadgets, devices & tech accessories'),
(2,  'Clothing',           'clothing',           'Fashion for all seasons'),
(3,  'Home & Garden',      'home-garden',        'Furniture, decor, and tools'),
(4,  'Books',              'books',              'Fiction, non-fiction, and reference'),
(5,  'Sports & Outdoors',  'sports-outdoors',    'Gear for every adventure'),
(6,  'Beauty & Health',    'beauty-health',      'Skincare, wellness, and personal care');

INSERT IGNORE INTO products
  (product_id,category_id,sku,name,slug,short_description,price,compare_price,cost_price,stock_level,is_featured)
VALUES
(1,1,'ELEC-001','ProBook Laptop 15"','probook-laptop-15','High-performance laptop with 16GB RAM',1299.99,1499.99,820.00,42,TRUE),
(2,1,'ELEC-002','UltraSound Headphones','ultrasound-headphones','Noise-cancelling wireless headphones',249.99,299.99,95.00,118,TRUE),
(3,1,'ELEC-003','SmartWatch Series X','smartwatch-series-x','GPS, heart rate, and sleep tracking',399.99,NULL,160.00,65,FALSE),
(4,2,'CLTH-001','Classic Oxford Shirt','classic-oxford-shirt','100% cotton, multiple colors',59.99,79.99,18.00,200,FALSE),
(5,2,'CLTH-002','Slim Fit Chinos','slim-fit-chinos','Stretch fabric, tapered cut',49.99,NULL,14.00,175,FALSE),
(6,3,'HOME-001','Ergonomic Office Chair','ergonomic-office-chair','Lumbar support, adjustable arms',449.99,599.99,210.00,28,TRUE),
(7,3,'HOME-002','Bamboo Desk Organizer','bamboo-desk-organizer','Eco-friendly, 6 compartments',34.99,NULL,10.00,90,FALSE),
(8,4,'BOOK-001','Clean Code','clean-code','Robert C. Martin — essential reading',38.99,NULL,12.00,155,FALSE),
(9,5,'SPRT-001','Trail Running Shoes','trail-running-shoes','Waterproof, grip outsole',129.99,149.99,48.00,82,TRUE),
(10,6,'BEAU-001','Vitamin C Serum 30ml','vitamin-c-serum','Brightening formula with hyaluronic acid',44.99,NULL,9.50,210,FALSE);
