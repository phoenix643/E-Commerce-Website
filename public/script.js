const API = 'http://localhost:3000/api';

// ── Clock ──────────────────────────────────────────────────────
setInterval(() => { document.getElementById('clock').textContent = new Date().toLocaleTimeString(); }, 1000);

// ── Tab navigation ─────────────────────────────────────────────
function go(id, btn) {
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tabs button').forEach(b => b.classList.remove('active'));
  document.getElementById('p-' + id).classList.add('active');
  btn.classList.add('active');
  if (id === 'orders'       && !ordersLoaded)    loadOrders();
  if (id === 'products'     && !productsLoaded)  { loadCategories(); loadProducts(); }
  if (id === 'customers'    && !customersLoaded) loadCustomers();
  if (id === 'alerts'       && !alertsLoaded)    loadAlerts();
  if (id === 'place-order')                      loadOrderProducts();
}

// ── Chart.js defaults ──────────────────────────────────────────
Chart.defaults.font.family = "'Outfit', sans-serif";
Chart.defaults.font.size   = 12;
Chart.defaults.color       = '#999';
Chart.defaults.borderColor = '#e8e8e8';
Chart.defaults.animation = false;

// ── Helpers ────────────────────────────────────────────────────
const fmt  = n  => '$' + Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const fmtK = n  => n >= 1000 ? '$' + (n / 1000).toFixed(0) + 'k' : '$' + n;
const ini  = nm => nm.split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase();
const ICONS = { 'Electronics':'💻','Clothing':'👔','Home & Garden':'🪑','Books':'📚','Sports & Outdoors':'👟','Beauty & Health':'🧴' };

function showContent(contentId, loadingId) {
  document.getElementById(loadingId).style.display = 'none';
  document.getElementById(contentId).style.display = 'block';
}
function showErr(loadingId, msg) {
  document.getElementById(loadingId).innerHTML = `<div class="error-msg">⚠️ ${msg}</div>`;
}
function setMsg(elId, msg, isError) {
  const el = document.getElementById(elId);
  el.textContent   = msg;
  el.style.color   = isError ? 'var(--red)' : 'var(--green)';
  if (!isError) setTimeout(() => { el.textContent = ''; }, 4000);
}

// ── Health check ───────────────────────────────────────────────
async function checkHealth() {
  const el = document.getElementById('db-status');
  try {
    const r = await fetch(`${API}/health`);
    const d = await r.json();
    el.innerHTML = d.status === 'ok'
      ? `<div class="db-banner"><div class="db-dot"></div>Connected to MySQL — <strong>shopdb</strong></div>`
      : `<div class="db-banner err"><div class="db-dot err"></div>Database disconnected</div>`;
  } catch {
    el.innerHTML = `<div class="db-banner err"><div class="db-dot err"></div>Cannot reach server — make sure <strong>node server.js</strong> is running on port 3000</div>`;
  }
}

// ── OVERVIEW ───────────────────────────────────────────────────
let mChart, catChart, statChart, payChart;

async function loadOverview() {
  try {
    const r = await fetch(`${API}/overview`);
    const d = await r.json();
    if (d.error) throw new Error(d.error);

    const k = d.kpis;
    document.getElementById('kpi-rev').textContent      = fmtK(Math.round(k.total_revenue));
    document.getElementById('kpi-ord-note').textContent = k.total_orders + ' total orders';
    document.getElementById('kpi-aov').textContent      = fmt(k.avg_order_value);
    document.getElementById('kpi-cust').textContent     = k.total_customers;
    document.getElementById('kpi-cancel').textContent   = k.cancel_rate + '%';

    const catColors = ['#2563eb','#16a34a','#d97706','#9333ea','#db2777','#64748b'];

    if (mChart) mChart.destroy();
    mChart = new Chart(document.getElementById('c-monthly'), {
      type: 'bar',
      data: { labels: d.monthly.map(m => m.month_label),
        datasets: [{ data: d.monthly.map(m => m.revenue),
          backgroundColor: '#2563eb22', borderColor: '#2563eb',
          borderWidth: 2, borderRadius: 5, borderSkipped: false }] },
      options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } },
        scales: { x: { grid: { display: false } },
                  y: { grid: { color: '#f0f0f0' }, border: { display: false },
                       ticks: { callback: v => '$' + (v/1000).toFixed(0) + 'k' } } } }
    });

    if (catChart) catChart.destroy();
    catChart = new Chart(document.getElementById('c-cat'), {
      type: 'doughnut',
      data: { labels: d.byCategory.map(c => c.category),
        datasets: [{ data: d.byCategory.map(c => c.revenue),
          backgroundColor: catColors.slice(0, d.byCategory.length),
          borderWidth: 3, borderColor: '#fff', hoverOffset: 4 }] },
      options: { responsive: true, maintainAspectRatio: false, cutout: '65%',
        plugins: { legend: { position: 'right', labels: { padding: 12, font: { size: 11 }, color: '#555' } } } }
    });

    const sColors = { delivered:'#16a34a', shipped:'#2563eb', processing:'#d97706', confirmed:'#64748b', cancelled:'#dc2626' };
    if (statChart) statChart.destroy();
    statChart = new Chart(document.getElementById('c-status'), {
      type: 'bar',
      data: { labels: d.byStatus.map(s => s.status[0].toUpperCase() + s.status.slice(1)),
        datasets: [{ data: d.byStatus.map(s => s.count),
          backgroundColor: d.byStatus.map(s => sColors[s.status] || '#64748b'),
          borderRadius: 5, borderSkipped: false }] },
      options: { responsive: true, maintainAspectRatio: false, indexAxis: 'y',
        plugins: { legend: { display: false } },
        scales: { x: { grid: { color: '#f0f0f0' }, border: { display: false } }, y: { grid: { display: false } } } }
    });

    if (payChart) payChart.destroy();
    payChart = new Chart(document.getElementById('c-pay'), {
      type: 'doughnut',
      data: { labels: d.byPayment.map(p => p.method[0].toUpperCase() + p.method.slice(1)),
        datasets: [{ data: d.byPayment.map(p => p.count),
          backgroundColor: ['#2563eb','#0ea5e9','#64748b','#a855f7'].slice(0, d.byPayment.length),
          borderWidth: 3, borderColor: '#fff', hoverOffset: 4 }] },
      options: { responsive: true, maintainAspectRatio: false, cutout: '68%',
        plugins: { legend: { position: 'bottom', labels: { padding: 12, font: { size: 11 }, color: '#555' } } } }
    });

    showContent('ov-content', 'ov-loading');
  } catch (err) {
    showErr('ov-loading', 'Could not load overview: ' + err.message);
  }
}

// ── ORDERS ─────────────────────────────────────────────────────
let ordersLoaded = false;
let lastOrders   = [];

async function loadOrders() {
  document.getElementById('ord-loading').style.display = 'flex';
  document.getElementById('ord-content').style.display = 'none';
  try {
    const params = new URLSearchParams();
    const st = document.getElementById('ord-status').value;
    const pm = document.getElementById('ord-pay').value;
    if (st) params.append('status', st);
    if (pm) params.append('payment', pm);

    const r = await fetch(`${API}/orders?${params}`);
    const orders = await r.json();
    if (orders.error) throw new Error(orders.error);
    lastOrders = orders;

    const payLabel = { card: '💳 Card', paypal: 'PayPal', wallet: '👛 Wallet' };
    document.getElementById('orders-body').innerHTML = orders.map(o => `
      <tr>
        <td class="td-mono td-bold">${o.order_number}</td>
        <td class="td-bold">${o.customer_name}</td>
        <td style="color:#666">${o.order_date}</td>
        <td style="text-align:center;color:#666">${o.item_count}</td>
        <td class="td-bold">${fmt(o.order_total)}</td>
        <td style="color:#555">${payLabel[o.payment_method] || o.payment_method || '—'}</td>
        <td><span class="badge ${o.status}">${o.status}</span></td>
      </tr>`).join('');

    ordersLoaded = true;
    showContent('ord-content', 'ord-loading');
  } catch (err) {
    showErr('ord-loading', 'Could not load orders: ' + err.message);
  }
}

// OUTPUT: Export orders to CSV ─────────────────────────────────
function exportCSV() {
  const st = document.getElementById('ord-status').value;
  const pm = document.getElementById('ord-pay').value;
  const params = new URLSearchParams();
  if (st) params.append('status', st);
  if (pm) params.append('payment', pm);
  // Hitting the /export route triggers a file download directly
  window.location.href = `${API}/orders/export?${params}`;
}

// ── PRODUCTS ───────────────────────────────────────────────────
let productsLoaded = false;
let prodRevChart;

async function loadCategories() {
  try {
    const r    = await fetch(`${API}/categories`);
    const cats = await r.json();
    const sel  = document.getElementById('f-prod-cat');
    sel.innerHTML = '<option value="">Select category…</option>' +
      cats.map(c => `<option value="${c.category_id}">${c.name}</option>`).join('');
  } catch { /* silently ignore */ }
}

async function loadProducts() {
  document.getElementById('prod-loading').style.display = 'flex';
  document.getElementById('prod-content').style.display = 'none';
  try {
    const cat    = document.getElementById('prod-cat').value;
    const params = cat ? '?category=' + encodeURIComponent(cat) : '';
    const r      = await fetch(`${API}/products${params}`);
    const prods  = await r.json();
    if (prods.error) throw new Error(prods.error);

    document.getElementById('prod-grid').innerHTML = prods.map(p => {
      const maxStock = p.stock + (p.units_sold || 0);
      const pct      = maxStock > 0 ? Math.min(p.stock / maxStock * 100, 100) : 0;
      const col      = pct < 20 ? '#dc2626' : pct < 50 ? '#d97706' : '#16a34a';
      const lowCls   = p.stock_status !== 'in_stock' ? 'low' : '';
      return `<div class="prod-card">
        <div class="prod-icon">${ICONS[p.category] || '📦'}</div>
        <div class="prod-cat-tag">${p.category}</div>
        <div class="prod-name">${p.name}</div>
        <div class="prod-price">${fmt(p.price)}</div>
        <div class="prod-stock ${lowCls}">${p.stock} in stock</div>
        <div class="stock-bar"><div class="stock-fill" style="width:${pct}%;background:${col}"></div></div>
      </div>`;
    }).join('');

    if (prodRevChart) prodRevChart.destroy();
    prodRevChart = new Chart(document.getElementById('c-prod-rev'), {
      type: 'bar',
      data: { labels: prods.map(p => p.name.length > 16 ? p.name.slice(0,16) + '…' : p.name),
        datasets: [{ data: prods.map(p => p.revenue),
          backgroundColor: '#2563eb33', borderColor: '#2563eb',
          borderWidth: 1.5, borderRadius: 4, borderSkipped: false }] },
      options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } },
        scales: { x: { grid: { display: false }, ticks: { font: { size: 10 } } },
                  y: { grid: { color: '#f0f0f0' }, border: { display: false },
                       ticks: { callback: v => '$' + Math.round(v/1000) + 'k' } } } }
    });

    productsLoaded = true;
    showContent('prod-content', 'prod-loading');
  } catch (err) {
    showErr('prod-loading', 'Could not load products: ' + err.message);
  }
}

// INPUT: Submit new product ─────────────────────────────────────
async function submitProduct() {
  const name     = document.getElementById('f-prod-name').value.trim();
  const sku      = document.getElementById('f-prod-sku').value.trim();
  const catId    = document.getElementById('f-prod-cat').value;
  const price    = document.getElementById('f-prod-price').value;
  const stock    = document.getElementById('f-prod-stock').value;
  const desc     = document.getElementById('f-prod-desc').value.trim();
  const statusEl = document.getElementById('prod-submit-status');
  const msgEl    = document.getElementById('prod-form-msg');

  msgEl.innerHTML = '';
  if (!name || !sku || !catId || !price) {
    msgEl.innerHTML = '<div class="error-msg">Please fill in all required fields (Name, SKU, Category, Price).</div>';
    return;
  }

  statusEl.textContent = 'Saving…';
  statusEl.style.color = '#999';

  try {
    const r = await fetch(`${API}/products`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, sku, category_id: catId, price, stock_level: stock, description: desc }),
    });
    const d = await r.json();
    if (!r.ok) throw new Error(d.error);

    msgEl.innerHTML = `<div class="success-msg">✓ Product <strong>${d.name}</strong> (${d.sku}) added successfully.</div>`;
    statusEl.textContent = '';
    clearForm('product');
    productsLoaded = false;  // force refresh next time products tab opens
    loadProducts();
  } catch (err) {
    msgEl.innerHTML = `<div class="error-msg">⚠️ ${err.message}</div>`;
    statusEl.textContent = '';
  }
}

// INPUT: Submit new customer ────────────────────────────────────
async function submitCustomer() {
  const first    = document.getElementById('f-cust-first').value.trim();
  const last     = document.getElementById('f-cust-last').value.trim();
  const email    = document.getElementById('f-cust-email').value.trim();
  const phone    = document.getElementById('f-cust-phone').value.trim();
  const statusEl = document.getElementById('cust-submit-status');
  const msgEl    = document.getElementById('cust-form-msg');

  msgEl.innerHTML = '';
  if (!first || !last || !email) {
    msgEl.innerHTML = '<div class="error-msg">Please fill in First Name, Last Name, and Email.</div>';
    return;
  }
  if (!email.includes('@')) {
    msgEl.innerHTML = '<div class="error-msg">Please enter a valid email address.</div>';
    return;
  }

  statusEl.textContent = 'Saving…';
  statusEl.style.color = '#999';

  try {
    const r = await fetch(`${API}/customers`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ first_name: first, last_name: last, email, phone }),
    });
    const d = await r.json();
    if (!r.ok) throw new Error(d.error);

    msgEl.innerHTML = `<div class="success-msg">✓ Customer <strong>${d.name}</strong> (${d.email}) added successfully.</div>`;
    statusEl.textContent = '';
    clearForm('customer');
    customersLoaded = false; // force refresh
    loadCustomers();
  } catch (err) {
    msgEl.innerHTML = `<div class="error-msg">⚠️ ${err.message}</div>`;
    statusEl.textContent = '';
  }
}

// Clear form fields ─────────────────────────────────────────────
function clearForm(type) {
  if (type === 'product') {
    ['f-prod-name','f-prod-sku','f-prod-price','f-prod-stock','f-prod-desc'].forEach(id => {
      document.getElementById(id).value = '';
    });
    document.getElementById('f-prod-cat').value = '';
  } else {
    ['f-cust-first','f-cust-last','f-cust-email','f-cust-phone'].forEach(id => {
      document.getElementById(id).value = '';
    });
  }
}

// ── CUSTOMERS ──────────────────────────────────────────────────
let customersLoaded = false;
let ltvChart;

async function loadCustomers() {
  document.getElementById('cust-loading').style.display = 'flex';
  document.getElementById('cust-content').style.display = 'none';
  try {
    const r = await fetch(`${API}/customers`);
    const customers = await r.json();
    if (customers.error) throw new Error(customers.error);

    document.getElementById('cust-list').innerHTML = customers.slice(0, 5).map(c => `
      <div class="cust-row">
        <div class="avatar">${ini(c.name)}</div>
        <div style="flex:1">
          <div class="cust-name">${c.name}</div>
          <div class="cust-email">${c.email}</div>
        </div>
        <div style="text-align:right">
          <div style="font-size:16px;font-weight:700">${fmt(c.lifetime_value)}</div>
          <div style="font-size:11px;color:#999">${c.total_orders} orders</div>
        </div>
      </div>`).join('');

    if (ltvChart) ltvChart.destroy();
    ltvChart = new Chart(document.getElementById('c-ltv'), {
      type: 'bar',
      data: { labels: customers.slice(0,10).map(c => c.name.split(' ')[0]),
        datasets: [{ data: customers.slice(0,10).map(c => c.lifetime_value),
          backgroundColor: customers.slice(0,10).map(c => c.tier === 'VIP' ? '#2563eb' : c.tier === 'Regular' ? '#2563eb88' : '#2563eb33'),
          borderRadius: 5, borderSkipped: false }] },
      options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } },
        scales: { x: { grid: { display: false } },
                  y: { grid: { color: '#f0f0f0' }, border: { display: false },
                       ticks: { callback: v => '$' + v.toLocaleString() } } } }
    });

    document.getElementById('cust-body').innerHTML = customers.map(c => `
      <tr>
        <td class="td-bold">${c.name}</td>
        <td style="color:#666;font-size:12px">${c.email}</td>
        <td style="text-align:center;color:#666">${c.total_orders}</td>
        <td class="td-bold">${fmt(c.lifetime_value)}</td>
        <td style="color:#555">${fmt(c.avg_order_value)}</td>
        <td><span class="tier-tag ${c.tier}">${c.tier}</span></td>
      </tr>`).join('');

    customersLoaded = true;
    showContent('cust-content', 'cust-loading');
  } catch (err) {
    showErr('cust-loading', 'Could not load customers: ' + err.message);
  }
}

// ── STOCK ALERTS ───────────────────────────────────────────────
let alertsLoaded = false;
let lastAlerts   = [];

async function loadAlerts() {
  document.getElementById('alerts-loading').style.display = 'flex';
  document.getElementById('alerts-content').style.display = 'none';
  try {
    const r = await fetch(`${API}/stock-alerts`);
    const d = await r.json();
    if (d.error) throw new Error(d.error);
    lastAlerts = d.alerts;

    const oos = d.alerts.filter(a => a.alert_type === 'out_of_stock').length;
    const low = d.alerts.filter(a => a.alert_type === 'low_stock').length;
    document.getElementById('kpi-oos').textContent = oos;
    document.getElementById('kpi-low').textContent = low;

    if (d.alerts.length === 0) {
      document.getElementById('alerts-list').innerHTML =
        '<div style="padding:24px 0;text-align:center;color:#999;font-size:13px">✓ All products have healthy stock levels.</div>';
    } else {
      document.getElementById('alerts-list').innerHTML = d.alerts.map(a => `
        <div class="alert-row">
          <div class="alert-icon">${ICONS[a.category] || '📦'}</div>
          <div style="flex:1">
            <div class="alert-name">${a.name}</div>
            <div class="alert-sku">${a.sku} · ${a.category}</div>
          </div>
          <div style="text-align:right">
            <div class="stock-num ${a.stock_level === 0 ? 'zero' : 'low'}">${a.stock_level}</div>
            <div class="restock-needed">Threshold: ${a.low_stock_threshold}</div>
          </div>
          <div style="margin-left:16px">
            <span class="badge ${a.alert_type}">${a.alert_type === 'out_of_stock' ? 'Out of stock' : 'Low stock'}</span>
            <div style="font-size:11px;color:#999;margin-top:4px">Need ${a.units_needed} units</div>
          </div>
        </div>`).join('');
    }

    alertsLoaded = true;
    showContent('alerts-content', 'alerts-loading');
  } catch (err) {
    showErr('alerts-loading', 'Could not load stock alerts: ' + err.message);
  }
}

// OUTPUT: Export alert list as CSV ─────────────────────────────
function exportAlerts() {
  if (!lastAlerts.length) return;
  const headers = ['SKU','Product','Category','Stock Level','Threshold','Units Needed','Alert Type','Price'];
  const rows    = lastAlerts.map(a => [a.sku, a.name, a.category, a.stock_level, a.low_stock_threshold, a.units_needed, a.alert_type, a.price]);
  const esc     = v => `"${String(v).replace(/"/g,'""')}"`;
  const csv     = [headers.map(esc).join(','), ...rows.map(r => r.map(esc).join(','))].join('\n');
  const blob    = new Blob([csv], { type: 'text/csv' });
  const url     = URL.createObjectURL(blob);
  const a       = document.createElement('a');
  a.href        = url;
  a.download    = `stock-alerts-${new Date().toISOString().slice(0,10)}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

// ── PLACE ORDER ────────────────────────────────────────────────
let selectedCustomerId = null;
let cartItems          = [];      // [{ product_id, name, sku, price, stock, quantity }]
let allProducts        = [];      // cached product list for the dropdown

// Load products into the item-product dropdown
async function loadOrderProducts() {
  if (allProducts.length) return;
  try {
    const r = await fetch(`${API}/products`);
    allProducts = await r.json();
    const sel = document.getElementById('item-product');
    sel.innerHTML = '<option value="">Select a product…</option>' +
      allProducts.map(p =>
        `<option value="${p.product_id}" data-price="${p.price}" data-stock="${p.stock}" data-name="${p.name}" data-sku="${p.sku}">
           ${p.name} — $${Number(p.price).toFixed(2)} (${p.stock} in stock)
         </option>`
      ).join('');
  } catch { /* ignore */ }
}

// Customer search autocomplete
let searchTimer;
async function searchCustomers(val) {
  clearTimeout(searchTimer);
  if (selectedCustomerId) return;
  const box = document.getElementById('cust-suggestions');
  if (val.length < 2) { box.style.display = 'none'; return; }
  searchTimer = setTimeout(async () => {
    try {
      const r   = await fetch(`${API}/customers/search?q=${encodeURIComponent(val)}`);
      const res = await r.json();
      if (!res.length) { box.style.display = 'none'; return; }
      box.innerHTML = res.map(c => `
        <div onclick="selectCustomer(${c.customer_id}, '${c.name.replace(/'/g,"\\'")}', '${c.email}')"
             style="padding:10px 14px;cursor:pointer;font-size:13px;border-bottom:1px solid var(--border)"
             onmouseover="this.style.background='var(--bg)'" onmouseout="this.style.background=''">
          <strong>${c.name}</strong>
          <span style="color:var(--faint);margin-left:8px;font-size:11px">${c.email}</span>
        </div>`).join('');
      box.style.display = 'block';
    } catch { box.style.display = 'none'; }
  }, 300);
}

function selectCustomer(id, name, email) {
  selectedCustomerId = id;
  document.getElementById('cust-search').value        = name;
  document.getElementById('cust-suggestions').style.display = 'none';
  // Show selected card
  document.getElementById('sel-cust-avatar').textContent = name.split(' ').map(w=>w[0]).join('').slice(0,2).toUpperCase();
  document.getElementById('sel-cust-name').textContent    = name;
  document.getElementById('sel-cust-email').textContent   = email;
  document.getElementById('selected-customer').style.display = 'flex';
}

function clearCustomer() {
  selectedCustomerId = null;
  document.getElementById('cust-search').value = '';
  document.getElementById('selected-customer').style.display = 'none';
  document.getElementById('cust-search').focus();
}

// Add item to cart
function addItem() {
  const sel   = document.getElementById('item-product');
  const qty   = parseInt(document.getElementById('item-qty').value) || 1;
  const errEl = document.getElementById('item-error');
  errEl.style.display = 'none';

  if (!sel.value) { errEl.textContent = 'Please select a product.'; errEl.style.display = 'block'; return; }

  const opt   = sel.options[sel.selectedIndex];
  const pid   = parseInt(sel.value);
  const price = parseFloat(opt.dataset.price);
  const stock = parseInt(opt.dataset.stock);
  const name  = opt.dataset.name;
  const sku   = opt.dataset.sku;

  if (qty < 1) { errEl.textContent = 'Quantity must be at least 1.'; errEl.style.display = 'block'; return; }

  // Check against stock, accounting for already-added qty
  const alreadyInCart = cartItems.find(i => i.product_id === pid);
  const totalQty      = qty + (alreadyInCart ? alreadyInCart.quantity : 0);
  if (totalQty > stock) {
    errEl.textContent = `Only ${stock} in stock (you already have ${alreadyInCart?.quantity || 0} in the cart).`;
    errEl.style.display = 'block';
    return;
  }

  if (alreadyInCart) {
    alreadyInCart.quantity += qty;
  } else {
    cartItems.push({ product_id: pid, name, sku, price, stock, quantity: qty });
  }

  // Reset selects
  sel.value = '';
  document.getElementById('item-qty').value = 1;
  renderCart();
}

function removeItem(pid) {
  cartItems = cartItems.filter(i => i.product_id !== pid);
  renderCart();
}

function changeQty(pid, delta) {
  const item = cartItems.find(i => i.product_id === pid);
  if (!item) return;
  item.quantity = Math.max(1, Math.min(item.stock, item.quantity + delta));
  renderCart();
}

function renderCart() {
  const emptyEl = document.getElementById('cart-empty');
  const tableEl = document.getElementById('cart-table');

  if (!cartItems.length) {
    emptyEl.style.display = 'block';
    tableEl.style.display  = 'none';
    recalcTotals();
    return;
  }

  emptyEl.style.display = 'none';
  tableEl.style.display  = 'block';

  document.getElementById('cart-body').innerHTML = cartItems.map(item => `
    <tr>
      <td>
        <div style="font-weight:600;font-size:13px">${item.name}</div>
        <div style="font-size:10px;color:var(--faint);font-family:'Courier New',monospace">${item.sku}</div>
      </td>
      <td style="text-align:right;color:var(--sub)">$${item.price.toFixed(2)}</td>
      <td style="text-align:center">
        <div style="display:inline-flex;align-items:center;gap:6px">
          <button onclick="changeQty(${item.product_id},-1)" style="width:22px;height:22px;border-radius:4px;border:1px solid var(--border);background:var(--bg);cursor:pointer;font-size:14px;line-height:1;display:flex;align-items:center;justify-content:center">−</button>
          <span style="min-width:20px;text-align:center;font-weight:600">${item.quantity}</span>
          <button onclick="changeQty(${item.product_id},1)" style="width:22px;height:22px;border-radius:4px;border:1px solid var(--border);background:var(--bg);cursor:pointer;font-size:14px;line-height:1;display:flex;align-items:center;justify-content:center">+</button>
        </div>
      </td>
      <td style="text-align:right;font-weight:600">$${(item.price * item.quantity).toFixed(2)}</td>
      <td style="text-align:right">
        <button onclick="removeItem(${item.product_id})" style="border:none;background:none;color:var(--red);cursor:pointer;font-size:16px;line-height:1;padding:2px 4px" title="Remove">×</button>
      </td>
    </tr>`).join('');

  recalcTotals();
}

function recalcTotals() {
  const TAX_RATE  = 0.0875;
  const subtotal  = cartItems.reduce((s, i) => s + i.price * i.quantity, 0);
  const shipMethod= document.getElementById('order-shipping')?.value || 'standard';
  const shipping  = subtotal >= 75 ? 0 : shipMethod === 'express' ? 14.99 : 5.99;
  const tax       = subtotal * TAX_RATE;
  const total     = subtotal + shipping + tax;
  const count     = cartItems.reduce((s, i) => s + i.quantity, 0);

  document.getElementById('sum-subtotal').textContent = '$' + subtotal.toFixed(2);
  document.getElementById('sum-shipping').textContent = shipping === 0 ? 'FREE' : '$' + shipping.toFixed(2);
  document.getElementById('sum-tax').textContent      = '$' + tax.toFixed(2);
  document.getElementById('sum-total').textContent    = '$' + total.toFixed(2);
  document.getElementById('sum-items').textContent    = count + (count === 1 ? ' item' : ' items') + ' in order';
}

// Submit the order
async function submitOrder() {
  const resultEl = document.getElementById('order-result');
  resultEl.innerHTML = '';

  if (!selectedCustomerId) {
    resultEl.innerHTML = '<div class="error-msg">⚠️ Please select a customer first.</div>';
    return;
  }
  if (!cartItems.length) {
    resultEl.innerHTML = '<div class="error-msg">⚠️ Please add at least one product.</div>';
    return;
  }

  const btn = event.currentTarget;
  btn.textContent = 'Placing order…';
  btn.disabled    = true;

  try {
    const r = await fetch(`${API}/orders`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        customer_id:     selectedCustomerId,
        items:           cartItems.map(i => ({ product_id: i.product_id, quantity: i.quantity })),
        shipping_method: document.getElementById('order-shipping').value,
        notes:           document.getElementById('order-notes').value.trim(),
      }),
    });

    const d = await r.json();
    if (!r.ok) throw new Error(d.error);

    resultEl.innerHTML = `
      <div class="success-msg" style="font-size:14px">
        ✓ Order <strong>${d.order_number}</strong> placed successfully!
        &nbsp;·&nbsp; ${d.items} item(s)
        &nbsp;·&nbsp; Total: <strong>$${d.total}</strong>
        &nbsp;·&nbsp; <a href="#" onclick="go('orders', document.querySelector('.tabs button:nth-child(2)')); return false" style="color:var(--green)">View in Orders →</a>
      </div>`;

    resetOrderForm();
    // Refresh orders & products (stock changed)
    ordersLoaded   = false;
    productsLoaded = false;
    alertsLoaded   = false;
  } catch (err) {
    resultEl.innerHTML = `<div class="error-msg">⚠️ ${err.message}</div>`;
  } finally {
    btn.textContent = 'Place Order';
    btn.disabled    = false;
  }
}

function resetOrderForm() {
  selectedCustomerId = null;
  cartItems          = [];
  document.getElementById('cust-search').value              = '';
  document.getElementById('selected-customer').style.display = 'none';
  document.getElementById('order-notes').value               = '';
  document.getElementById('order-shipping').value            = 'standard';
  document.getElementById('item-product').value              = '';
  document.getElementById('item-qty').value                  = 1;
  renderCart();
}

// ── Init ───────────────────────────────────────────────────────
checkHealth();
loadOverview();
