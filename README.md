# ShopDB — Online Retail Database System

A full-stack online retail database system with a live admin dashboard. Built with MySQL, Node.js, and vanilla JavaScript.

---

## Features

- **Dashboard** — live KPIs, monthly revenue chart, order status breakdown, category revenue
- **Orders** — browse, filter by status and payment method, export to CSV
- **Products** — catalog with live stock levels, add new products via form
- **Customers** — lifetime value ranking, tier classification, add new customers
- **Stock Alerts** — automatic alerts for low and out-of-stock products
- **Place Order** — full order form with customer search, cart, and totals

---

## Tech Stack

| Layer | Technology |
|---|---|
| Database | MySQL |
| Backend | Node.js, Express |
| Frontend | HTML, CSS, JavaScript |
| Charts | Chart.js |

---

## Database Design

- 16 tables — products, categories, customers, orders, order items, payments, cart, sessions and more
- Stored procedures for checkout, cart management, and login
- Triggers for low stock alerts, account lockout, and stock decrement on order
- Views for sales reports, customer lifetime value, and order history

---

## Project Structure

```
e-commerce site/
├── server.js              # Express API server
├── package.json
├── public/
│   ├── index.html         # Dashboard
│   ├── style.css
│   └── script.js
└── sql/
    ├── retail_01_schema.sql
    ├── retail_02_procedures.sql
    ├── retail_03_triggers_queries.sql
    └── retail_04_seed_data.sql
```

---

## Getting Started

### Prerequisites

- Node.js
- MySQL

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/shopdb.git
cd shopdb
```

### 2. Install dependencies

```bash
npm install
```

### 3. Set up the database

Open MySQL Workbench, create the database, and run the SQL files in order:

```sql
CREATE DATABASE shopdb;
```

Then open and run each file in MySQL Workbench:
1. `retail_01_schema.sql`
2. `retail_02_procedures.sql`
3. `retail_03_triggers_queries.sql`
4. `retail_04_seed_data.sql`

### 4. Configure database credentials

Open `server.js` and update:

```js
const DB_CONFIG = {
  host:     'localhost',
  user:     'root',
  password: 'yourpassword',  // update this
  database: 'shopdb',
};
```

### 5. Start the server

```bash
node server.js
```

### 6. Open the dashboard

```
http://localhost:3000/index.html
```

---

## API Endpoints

| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/overview` | KPIs, revenue, charts data |
| GET | `/api/orders` | All orders with optional filters |
| GET | `/api/orders/export` | Download orders as CSV |
| GET | `/api/products` | All products with stock and revenue |
| GET | `/api/customers` | Customers with lifetime value |
| GET | `/api/categories` | All product categories |
| GET | `/api/stock-alerts` | Low and out of stock products |
| GET | `/api/customers/search` | Search customers by name or email |
| POST | `/api/products` | Add a new product |
| POST | `/api/customers` | Add a new customer |
| POST | `/api/orders` | Place a new order |
| GET | `/api/health` | Database connection status |

---

## Seed Data

The database comes pre-loaded with:
- 10 products across 6 categories
- 80 customers
- 300 orders with 785 line items

---

## Security

- Passwords stored as bcrypt hashes
- Account lockout after 5 failed login attempts
- Payment card numbers never stored raw
- Parameterized queries throughout to prevent SQL injection
