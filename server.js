// ============================================================
// ShopDB — Express API Server
// Connects to MySQL and serves data to the dashboard
// ============================================================

const express = require('express');
const mysql   = require('mysql2/promise');
const path    = require('path');
const cors    = require('cors');

const app  = express();
const PORT = 3000;

// ─────────────────────────────────────────
// DATABASE CONFIG — update these values
// ─────────────────────────────────────────
const DB_CONFIG = {
  host:     'localhost',
  port:     3306,
  user:     'root',        // your MySQL username
  password: 'Shrutik@123', // your MySQL password
  database: 'shopdb',
  waitForConnections: true,
  connectionLimit:    10,
};

// Create a connection pool (reuses connections, more efficient)
const pool = mysql.createPool(DB_CONFIG);

// ─────────────────────────────────────────
// MIDDLEWARE
// ─────────────────────────────────────────
app.use(cors());                           // allow browser requests
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public'))); // serve dashboard HTML

// ─────────────────────────────────────────
// HELPER: run a query safely
// ─────────────────────────────────────────
async function query(sql, params = []) {
  const [rows] = await pool.execute(sql, params);
  return rows;
}

// ─────────────────────────────────────────
// ROUTE: GET /api/overview
// KPI numbers for the overview page
// ─────────────────────────────────────────
app.get('/api/overview', async (req, res) => {
  try {
    // Total revenue, order count, customer count, avg order value
    const [kpis] = await pool.execute(`
      SELECT
        COUNT(*)                                         AS total_orders,
        SUM(CASE WHEN status != 'cancelled' THEN order_total ELSE 0 END) AS total_revenue,
        COUNT(DISTINCT customer_id)                      AS total_customers,
        ROUND(AVG(CASE WHEN status != 'cancelled' THEN order_total END), 2) AS avg_order_value,
        ROUND(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END) / COUNT(*) * 100, 1) AS cancel_rate
      FROM orders
    `);

    // Monthly revenue (current year)
    const monthly = await query(`
      SELECT
        MONTH(created_at)               AS month_num,
        DATE_FORMAT(MIN(created_at), '%b')   AS month_label,
        ROUND(SUM(order_total), 2)      AS revenue,
        COUNT(*)                        AS order_count
      FROM orders
      WHERE YEAR(created_at) = YEAR(CURDATE())
        AND status != 'cancelled'
      GROUP BY MONTH(created_at)
      ORDER BY month_num
    `);

    // Revenue by category
    const byCategory = await query(`
      SELECT
        c.name                           AS category,
        ROUND(SUM(oi.line_total), 2)     AS revenue
      FROM order_items oi
      JOIN products  p  ON p.product_id  = oi.product_id
      JOIN categories c ON c.category_id = p.category_id
      JOIN orders    o  ON o.order_id    = oi.order_id
      WHERE o.status != 'cancelled'
      GROUP BY c.name
      ORDER BY revenue DESC
    `);

    // Order status breakdown
    const byStatus = await query(`
      SELECT status, COUNT(*) AS count
      FROM orders
      GROUP BY status
      ORDER BY count DESC
    `);

    // Payment method breakdown
    const byPayment = await query(`
      SELECT method, COUNT(*) AS count
      FROM payments
      GROUP BY method
      ORDER BY count DESC
    `);

    res.json({
      kpis: kpis[0] ?? {
        total_orders:     0,
        total_revenue:    0,
        total_customers:  0,
        avg_order_value:  0,
        cancel_rate:      0,
      },
      monthly,
      byCategory,
      byStatus,
      byPayment,
    });
  } catch (err) {
    console.error('Error in /api/overview:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: GET /api/orders
// All orders with optional filters
// Query params: ?status=delivered&payment=card
// ─────────────────────────────────────────
app.get('/api/orders', async (req, res) => {
  try {
    const { status, payment } = req.query;

    let sql = `
      SELECT
        o.order_id,
        o.order_number,
        CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
        DATE_FORMAT(o.created_at, '%Y-%m-%d')  AS order_date,
        COUNT(oi.order_item_id)                AS item_count,
        o.order_total,
        MAX(p.method)                          AS payment_method,
        o.status
      FROM orders o
      JOIN customers   c  ON c.customer_id  = o.customer_id
      JOIN order_items oi ON oi.order_id    = o.order_id
      LEFT JOIN payments p ON p.order_id    = o.order_id
      WHERE 1=1
    `;

    const params = [];

    if (status) {
      sql += ' AND o.status = ?';
      params.push(status);
    }
    if (payment) {
      sql += ' AND p.method = ?';
      params.push(payment);
    }

    sql += ' GROUP BY o.order_id ORDER BY o.created_at DESC LIMIT 100';

    const orders = await query(sql, params);
    res.json(orders);
  } catch (err) {
    console.error('Error in /api/orders:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: GET /api/products
// All products with revenue from orders
// Query param: ?category=Electronics
// ─────────────────────────────────────────
app.get('/api/products', async (req, res) => {
  try {
    const { category } = req.query;

    let sql = `
      SELECT
        p.product_id,
        p.name,
        p.sku,
        c.name                                          AS category,
        p.price,
        p.stock_level                                   AS stock,
        p.low_stock_threshold,
        COALESCE(SUM(oi.line_total), 0)                 AS revenue,
        COALESCE(SUM(oi.quantity), 0)                   AS units_sold,
        CASE
          WHEN p.stock_level = 0                        THEN 'out_of_stock'
          WHEN p.stock_level <= p.low_stock_threshold   THEN 'low_stock'
          ELSE 'in_stock'
        END AS stock_status
      FROM products p
      JOIN categories  c  ON c.category_id  = p.category_id
      LEFT JOIN order_items oi ON oi.product_id = p.product_id
      LEFT JOIN orders      o  ON o.order_id    = oi.order_id AND o.status != 'cancelled'
      WHERE p.is_active = TRUE
    `;

    const params = [];
    if (category) {
      sql += ' AND c.name = ?';
      params.push(category);
    }

    sql += ' GROUP BY p.product_id ORDER BY revenue DESC';

    const products = await query(sql, params);
    res.json(products);
  } catch (err) {
    console.error('Error in /api/products:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: GET /api/customers
// Customers with lifetime value and order count
// ─────────────────────────────────────────
app.get('/api/customers', async (req, res) => {
  try {
    const customers = await query(`
      SELECT
        c.customer_id,
        CONCAT(c.first_name, ' ', c.last_name)               AS name,
        c.email,
        COUNT(DISTINCT o.order_id)                           AS total_orders,
        ROUND(COALESCE(SUM(o.order_total), 0), 2)            AS lifetime_value,
        ROUND(COALESCE(AVG(o.order_total), 0), 2)            AS avg_order_value,
        MAX(o.created_at)                                    AS last_order_date,
        CASE
          WHEN SUM(o.order_total) > 5000 AND COUNT(o.order_id) >= 5  THEN 'VIP'
          WHEN SUM(o.order_total) > 1000 AND COUNT(o.order_id) >= 2  THEN 'Regular'
          WHEN COUNT(o.order_id) = 1                                  THEN 'New'
          ELSE 'Occasional'
        END AS tier
      FROM customers c
      LEFT JOIN orders o ON o.customer_id = c.customer_id
        AND o.status != 'cancelled'
      GROUP BY c.customer_id
      ORDER BY lifetime_value DESC
      LIMIT 50
    `);

    res.json(customers);
  } catch (err) {
    console.error('Error in /api/customers:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: POST /api/products
// Add a new product to the database
// Body: { name, sku, category_id, price, stock_level, description }
// ─────────────────────────────────────────
app.post('/api/products', async (req, res) => {
  try {
    const { name, sku, category_id, price, stock_level, description } = req.body;

    // Basic validation
    if (!name || !sku || !category_id || !price) {
      return res.status(400).json({ error: 'name, sku, category_id and price are required' });
    }

    // Check SKU is unique
    const existing = await query('SELECT product_id FROM products WHERE sku = ?', [sku]);
    if (existing.length > 0) {
      return res.status(400).json({ error: `SKU "${sku}" already exists` });
    }

    // Generate a URL-friendly slug from the name
    const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
               + '-' + Date.now();

    const result = await query(
      `INSERT INTO products
         (category_id, sku, name, slug, description, price, stock_level, is_active)
       VALUES (?, ?, ?, ?, ?, ?, ?, TRUE)`,
      [category_id, sku.toUpperCase(), name, slug, description || null,
       parseFloat(price), parseInt(stock_level) || 0]
    );

    res.status(201).json({
      message:    'Product added successfully',
      product_id: result.insertId,
      name,
      sku: sku.toUpperCase(),
    });
  } catch (err) {
    console.error('Error in POST /api/products:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: GET /api/categories
// Used to populate the category dropdown in the add-product form
// ─────────────────────────────────────────
app.get('/api/categories', async (req, res) => {
  try {
    const cats = await query(
      'SELECT category_id, name FROM categories WHERE is_active = TRUE ORDER BY name'
    );
    res.json(cats);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: POST /api/customers
// Add a new customer to the database
// Body: { first_name, last_name, email, phone }
// ─────────────────────────────────────────
app.post('/api/customers', async (req, res) => {
  try {
    const { first_name, last_name, email, phone } = req.body;

    if (!first_name || !last_name || !email) {
      return res.status(400).json({ error: 'first_name, last_name and email are required' });
    }

    // Check email is unique
    const existing = await query('SELECT customer_id FROM customers WHERE email = ?', [email]);
    if (existing.length > 0) {
      return res.status(400).json({ error: `Email "${email}" is already registered` });
    }

    const result = await query(
      `INSERT INTO customers (first_name, last_name, email, phone)
       VALUES (?, ?, ?, ?)`,
      [first_name.trim(), last_name.trim(), email.toLowerCase().trim(), phone || null]
    );

    res.status(201).json({
      message:     'Customer added successfully',
      customer_id: result.insertId,
      name:        `${first_name} ${last_name}`,
      email,
    });
  } catch (err) {
    console.error('Error in POST /api/customers:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: GET /api/orders/export
// Download all orders as a CSV file
// Query params same as GET /api/orders (status, payment)
// ─────────────────────────────────────────
app.get('/api/orders/export', async (req, res) => {
  try {
    const { status, payment } = req.query;

    let sql = `
      SELECT
        o.order_number                                  AS "Order #",
        CONCAT(c.first_name, ' ', c.last_name)         AS "Customer",
        c.email                                         AS "Email",
        DATE_FORMAT(o.created_at, '%Y-%m-%d')          AS "Date",
        COUNT(oi.order_item_id)                         AS "Items",
        o.subtotal                                      AS "Subtotal",
        o.discount_amount                               AS "Discount",
        o.shipping_cost                                 AS "Shipping",
        o.tax_amount                                    AS "Tax",
        o.order_total                                   AS "Total",
        COALESCE(p.method, '')                          AS "Payment Method",
        o.status                                        AS "Status",
        COALESCE(o.tracking_number, '')                 AS "Tracking"
      FROM orders o
      JOIN customers   c  ON c.customer_id = o.customer_id
      JOIN order_items oi ON oi.order_id   = o.order_id
      LEFT JOIN payments p ON p.order_id   = o.order_id
      WHERE 1=1
    `;

    const params = [];
    if (status)  { sql += ' AND o.status = ?';   params.push(status);  }
    if (payment) { sql += ' AND p.method = ?';   params.push(payment); }
    sql += ' GROUP BY o.order_id ORDER BY o.created_at DESC';

    const rows = await query(sql, params);

    if (rows.length === 0) {
      return res.status(404).json({ error: 'No orders found for the given filters' });
    }

    // Build CSV string
    const headers = Object.keys(rows[0]);
    const escape  = v => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const csv     = [
      headers.map(escape).join(','),
      ...rows.map(r => headers.map(h => escape(r[h])).join(',')),
    ].join('\n');

    const filename = `orders-export-${new Date().toISOString().slice(0,10)}.csv`;
    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.send(csv);
  } catch (err) {
    console.error('Error in GET /api/orders/export:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: GET /api/stock-alerts
// Products at or below their low_stock_threshold
// ─────────────────────────────────────────
app.get('/api/stock-alerts', async (req, res) => {
  try {
    const alerts = await query(`
      SELECT
        p.product_id,
        p.sku,
        p.name,
        c.name                                    AS category,
        p.stock_level,
        p.low_stock_threshold,
        p.price,
        CASE
          WHEN p.stock_level = 0 THEN 'out_of_stock'
          ELSE 'low_stock'
        END                                       AS alert_type,
        (p.low_stock_threshold - p.stock_level)   AS units_needed
      FROM products p
      JOIN categories c ON c.category_id = p.category_id
      WHERE p.is_active = TRUE
        AND p.stock_level <= p.low_stock_threshold
      ORDER BY p.stock_level ASC
    `);

    res.json({
      count:  alerts.length,
      alerts,
    });
  } catch (err) {
    console.error('Error in GET /api/stock-alerts:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: GET /api/customers/search
// Search customers by name or email (for order form autocomplete)
// ─────────────────────────────────────────
app.get('/api/customers/search', async (req, res) => {
  try {
    const { q } = req.query;
    if (!q || q.length < 2) return res.json([]);
    const like = `%${q}%`;
    const rows = await query(
      `SELECT customer_id,
              CONCAT(first_name, ' ', last_name) AS name,
              email
       FROM customers
       WHERE first_name LIKE ? OR last_name LIKE ? OR email LIKE ?
       LIMIT 10`,
      [like, like, like]
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// ROUTE: POST /api/orders
// Place a new order — inserts order + order_items, decrements stock
// Body: { customer_id, items: [{product_id, quantity}], shipping_method, notes }
// ─────────────────────────────────────────
app.post('/api/orders', async (req, res) => {
  const conn = await pool.getConnection();
  try {
    const { customer_id, items, shipping_method = 'standard', notes = '' } = req.body;

    // ── Validation ──────────────────────────────────────────
    if (!customer_id)         return res.status(400).json({ error: 'customer_id is required' });
    if (!items || !items.length) return res.status(400).json({ error: 'At least one item is required' });

    // Check customer exists
    const [cust] = await conn.execute(
      'SELECT customer_id FROM customers WHERE customer_id = ?', [customer_id]
    );
    if (!cust.length) return res.status(400).json({ error: 'Customer not found' });

    await conn.beginTransaction();

    // ── Load product details & check stock ──────────────────
    let subtotal = 0;
    const resolvedItems = [];

    for (const item of items) {
      const [rows] = await conn.execute(
        `SELECT product_id, name, sku, price, stock_level
         FROM products WHERE product_id = ? AND is_active = TRUE`,
        [item.product_id]
      );
      if (!rows.length) {
        await conn.rollback();
        return res.status(400).json({ error: `Product ID ${item.product_id} not found` });
      }
      const p = rows[0];
      if (p.stock_level < item.quantity) {
        await conn.rollback();
        return res.status(400).json({
          error: `Not enough stock for "${p.name}". Available: ${p.stock_level}, requested: ${item.quantity}`
        });
      }
      const lineTotal = parseFloat(p.price) * parseInt(item.quantity);
      subtotal += lineTotal;
      resolvedItems.push({ ...p, quantity: parseInt(item.quantity), lineTotal });
    }

    // ── Calculate totals ────────────────────────────────────
    const TAX_RATE     = 0.0875;
    const shippingCost = subtotal >= 75 ? 0 : shipping_method === 'express' ? 14.99 : 5.99;
    const taxAmount    = Math.round(subtotal * TAX_RATE * 100) / 100;
    const orderTotal   = Math.round((subtotal + shippingCost + taxAmount) * 100) / 100;

    // ── Generate order number ───────────────────────────────
    const year = new Date().getFullYear();
    const [[{ maxSeq }]] = await conn.execute(
      `SELECT COALESCE(MAX(CAST(SUBSTRING_INDEX(order_number, '-', -1) AS UNSIGNED)), 0) AS maxSeq
       FROM orders WHERE order_number LIKE ?`,
      [`ORD-${year}-%`]
    );
    const orderNumber = `ORD-${year}-${String(maxSeq + 1).padStart(5, '0')}`;

    // ── Insert order ────────────────────────────────────────
    const [orderResult] = await conn.execute(
      `INSERT INTO orders
         (order_number, customer_id, status, subtotal, shipping_cost,
          tax_amount, discount_amount, order_total, currency,
          shipping_method, notes)
       VALUES (?, ?, 'confirmed', ?, ?, ?, 0, ?, 'USD', ?, ?)`,
      [orderNumber, customer_id, subtotal.toFixed(2), shippingCost.toFixed(2),
       taxAmount.toFixed(2), orderTotal.toFixed(2), shipping_method, notes]
    );
    const orderId = orderResult.insertId;

    // ── Insert order items & decrement stock ─────────────────
    for (const item of resolvedItems) {
      await conn.execute(
        `INSERT INTO order_items
           (order_id, product_id, product_name, sku, quantity, unit_price, line_total)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [orderId, item.product_id, item.name, item.sku,
         item.quantity, item.price, item.lineTotal.toFixed(2)]
      );
      await conn.execute(
        'UPDATE products SET stock_level = stock_level - ? WHERE product_id = ?',
        [item.quantity, item.product_id]
      );
    }

    // ── Log status history ───────────────────────────────────
    await conn.execute(
      `INSERT INTO order_status_history (order_id, from_status, to_status, note, changed_by)
       VALUES (?, NULL, 'confirmed', 'Order placed via dashboard', 'admin')`,
      [orderId]
    );

    await conn.commit();
    conn.release();

    res.status(201).json({
      message:      'Order placed successfully',
      order_id:     orderId,
      order_number: orderNumber,
      subtotal:     subtotal.toFixed(2),
      shipping:     shippingCost.toFixed(2),
      tax:          taxAmount.toFixed(2),
      total:        orderTotal.toFixed(2),
      items:        resolvedItems.length,
    });
  } catch (err) {
    await conn.rollback();
    conn.release();
    console.error('Error in POST /api/orders:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────
// HEALTH CHECK
// ─────────────────────────────────────────
app.get('/api/health', async (req, res) => {
  try {
    await pool.execute('SELECT 1');
    res.json({ status: 'ok', database: 'connected', timestamp: new Date() });
  } catch (err) {
    res.status(500).json({ status: 'error', database: 'disconnected', error: err.message });
  }
});

// ─────────────────────────────────────────
// START SERVER
// ─────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`\n✅  ShopDB server running at http://localhost:${PORT}`);
  console.log(`   Dashboard: http://localhost:${PORT}`);
  console.log(`   API:       http://localhost:${PORT}/api/overview\n`);
});
