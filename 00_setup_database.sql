/* =============================================================================
   00_setup_database.sql
   -----------------------------------------------------------------------------
   Creates the SalesMarketingDW database used by every other script.

   Layers
     stg  - raw landing tables (everything NVARCHAR, loaded straight from CSV)
     dw   - cleaned star schema (dimensions + facts)
     etl  - ETL procedures, run log and data-quality reject log
     rpt  - reporting views, functions and report procedures

   Target: SQL Server 2017+ / Azure SQL (uses TRIM, TRANSLATE, BULK INSERT CSV)
   ========================================================================== */
IF DB_ID(N'SalesMarketingDW') IS NULL
    CREATE DATABASE SalesMarketingDW;
GO
USE SalesMarketingDW;
GO

/* ---------------------------------------------------------------- schemas */
IF SCHEMA_ID('stg') IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC (N'CREATE SCHEMA dw');
IF SCHEMA_ID('etl') IS NULL EXEC (N'CREATE SCHEMA etl');
IF SCHEMA_ID('rpt') IS NULL EXEC (N'CREATE SCHEMA rpt');
GO

/* =========================================================================
   STAGING - mirrors the CSV files 1:1, no typing, no constraints
   ========================================================================= */
DROP TABLE IF EXISTS stg.customers, stg.products, stg.campaigns, stg.leads, stg.sales;
GO
CREATE TABLE stg.customers (
    customer_id NVARCHAR(50),  first_name NVARCHAR(100), last_name NVARCHAR(100),
    email       NVARCHAR(255), phone      NVARCHAR(50),  city      NVARCHAR(100),
    region      NVARCHAR(50),  segment    NVARCHAR(50),  signup_date NVARCHAR(50)
);
CREATE TABLE stg.products (
    product_id NVARCHAR(50), product_name NVARCHAR(200), category NVARCHAR(100),
    unit_cost  NVARCHAR(50), list_price   NVARCHAR(50)
);
CREATE TABLE stg.campaigns (
    campaign_id NVARCHAR(50), campaign_name NVARCHAR(200), campaign_type NVARCHAR(100),
    start_date  NVARCHAR(50), end_date      NVARCHAR(50),  budget        NVARCHAR(50),
    target_region NVARCHAR(50)
);
CREATE TABLE stg.leads (
    lead_id    NVARCHAR(50), campaign_id NVARCHAR(50), lead_source NVARCHAR(100),
    created_date NVARCHAR(50), lead_score NVARCHAR(50), status     NVARCHAR(50),
    customer_id  NVARCHAR(50)
);
CREATE TABLE stg.sales (
    order_id   NVARCHAR(50), order_date NVARCHAR(50), customer_id NVARCHAR(50),
    product_id NVARCHAR(50), campaign_id NVARCHAR(50), quantity   NVARCHAR(50),
    unit_price NVARCHAR(50), discount    NVARCHAR(50), channel    NVARCHAR(100),
    sales_rep  NVARCHAR(100), status     NVARCHAR(50)
);
GO

/* =========================================================================
   ETL CONTROL TABLES
   ========================================================================= */
DROP TABLE IF EXISTS etl.dq_reject_log, etl.etl_step_log, etl.etl_run_log;
GO
CREATE TABLE etl.etl_run_log (
    run_id        INT IDENTITY(1,1) PRIMARY KEY,
    started_at    DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    finished_at   DATETIME2(0) NULL,
    status        VARCHAR(20)  NOT NULL DEFAULT 'Running',   -- Running / Succeeded / Failed
    error_message NVARCHAR(4000) NULL
);
CREATE TABLE etl.etl_step_log (
    step_id       INT IDENTITY(1,1) PRIMARY KEY,
    run_id        INT NOT NULL REFERENCES etl.etl_run_log(run_id),
    step_name     VARCHAR(100) NOT NULL,
    rows_inserted INT NULL,
    rows_updated  INT NULL,
    logged_at     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
CREATE TABLE etl.dq_reject_log (
    reject_id     INT IDENTITY(1,1) PRIMARY KEY,
    run_id        INT NULL,
    source_table  VARCHAR(50)   NOT NULL,
    business_key  NVARCHAR(50)  NULL,
    reject_reason VARCHAR(200)  NOT NULL,
    raw_record    NVARCHAR(MAX) NULL,
    logged_at     DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

/* =========================================================================
   DATA WAREHOUSE - star schema
   ========================================================================= */
-- a schema-bound (indexed) view in 04_ blocks dropping fact_sales, so remove it first
DROP VIEW IF EXISTS rpt.vw_DailySalesIndexed;
DROP TABLE IF EXISTS dw.fact_sales, dw.fact_leads,
                     dw.dim_customer, dw.dim_product, dw.dim_campaign, dw.dim_date;
GO
CREATE TABLE dw.dim_date (
    date_key      INT          NOT NULL PRIMARY KEY,   -- yyyymmdd
    full_date     DATE         NOT NULL UNIQUE,
    [year]        SMALLINT     NOT NULL,
    [quarter]     TINYINT      NOT NULL,
    [month]       TINYINT      NOT NULL,
    month_name    VARCHAR(10)  NOT NULL,
    year_month    CHAR(7)      NOT NULL,              -- 2025-03
    day_of_month  TINYINT      NOT NULL,
    day_of_week   TINYINT      NOT NULL,              -- 1 = Monday
    day_name      VARCHAR(10)  NOT NULL,
    week_of_year  TINYINT      NOT NULL,
    is_weekend    BIT          NOT NULL
);

-- Customer is a Type-2 slowly changing dimension (history of region/segment/city)
CREATE TABLE dw.dim_customer (
    customer_key  INT IDENTITY(1,1) PRIMARY KEY,
    customer_id   VARCHAR(10)   NOT NULL,
    first_name    NVARCHAR(100) NULL,
    last_name     NVARCHAR(100) NULL,
    full_name     AS (CONCAT(first_name, ' ', last_name)),
    email         NVARCHAR(255) NULL,
    email_valid   BIT           NOT NULL DEFAULT 0,
    phone         CHAR(10)      NULL,
    city          NVARCHAR(100) NULL,
    region        VARCHAR(20)   NULL,
    segment       VARCHAR(20)   NULL,
    signup_date   DATE          NULL,
    row_hash      VARBINARY(32) NOT NULL,
    valid_from    DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    valid_to      DATETIME2(0)  NOT NULL DEFAULT '9999-12-31',
    is_current    BIT           NOT NULL DEFAULT 1
);
CREATE UNIQUE INDEX ux_dim_customer_current ON dw.dim_customer(customer_id) WHERE is_current = 1;

-- Product and campaign are Type-1 (overwrite)
CREATE TABLE dw.dim_product (
    product_key   INT IDENTITY(1,1) PRIMARY KEY,
    product_id    VARCHAR(10)   NOT NULL UNIQUE,
    product_name  NVARCHAR(200) NOT NULL,
    category      VARCHAR(50)   NOT NULL,
    unit_cost     DECIMAL(12,2) NULL,
    list_price    DECIMAL(12,2) NOT NULL CHECK (list_price >= 0),
    margin_pct    AS (CAST((list_price - unit_cost) / NULLIF(list_price, 0) AS DECIMAL(6,4))),
    updated_at    DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
CREATE TABLE dw.dim_campaign (
    campaign_key  INT IDENTITY(1,1) PRIMARY KEY,
    campaign_id   VARCHAR(10)   NOT NULL UNIQUE,
    campaign_name NVARCHAR(200) NOT NULL,
    campaign_type VARCHAR(50)   NOT NULL,
    start_date    DATE          NOT NULL,
    end_date      DATE          NOT NULL,
    budget        DECIMAL(12,2) NOT NULL,
    target_region VARCHAR(20)   NULL,
    duration_days AS (DATEDIFF(DAY, start_date, end_date)),
    updated_at    DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT ck_campaign_dates CHECK (end_date >= start_date)
);

CREATE TABLE dw.fact_sales (
    sales_key      BIGINT IDENTITY(1,1) PRIMARY KEY,
    order_id       VARCHAR(12)   NOT NULL UNIQUE,
    date_key       INT           NOT NULL REFERENCES dw.dim_date(date_key),
    customer_key   INT           NOT NULL REFERENCES dw.dim_customer(customer_key),
    product_key    INT           NOT NULL REFERENCES dw.dim_product(product_key),
    campaign_key   INT           NULL     REFERENCES dw.dim_campaign(campaign_key), -- NULL = organic
    channel        VARCHAR(20)   NOT NULL,
    sales_rep      VARCHAR(50)   NOT NULL,
    order_status   VARCHAR(20)   NOT NULL,
    quantity       INT           NOT NULL CHECK (quantity > 0),
    unit_price     DECIMAL(12,2) NOT NULL,
    discount       DECIMAL(5,4)  NOT NULL CHECK (discount BETWEEN 0 AND 1),
    gross_revenue  DECIMAL(14,2) NOT NULL,
    net_revenue    DECIMAL(14,2) NOT NULL,
    cogs           DECIMAL(14,2) NULL,
    gross_profit   DECIMAL(14,2) NULL,
    is_qty_outlier BIT           NOT NULL DEFAULT 0,
    etl_run_id     INT           NULL,
    loaded_at      DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX ix_fact_sales_date     ON dw.fact_sales(date_key)     INCLUDE (net_revenue, gross_profit, order_status);
CREATE INDEX ix_fact_sales_customer ON dw.fact_sales(customer_key) INCLUDE (net_revenue, date_key);
CREATE INDEX ix_fact_sales_product  ON dw.fact_sales(product_key)  INCLUDE (net_revenue, quantity);

CREATE TABLE dw.fact_leads (
    lead_key      BIGINT IDENTITY(1,1) PRIMARY KEY,
    lead_id       VARCHAR(10)  NOT NULL UNIQUE,
    date_key      INT          NULL REFERENCES dw.dim_date(date_key),
    campaign_key  INT          NOT NULL REFERENCES dw.dim_campaign(campaign_key),
    customer_key  INT          NULL REFERENCES dw.dim_customer(customer_key),
    lead_source   VARCHAR(30)  NOT NULL,
    lead_score    TINYINT      NULL CHECK (lead_score BETWEEN 0 AND 100),
    lead_status   VARCHAR(20)  NOT NULL,
    is_converted  BIT          NOT NULL,
    etl_run_id    INT          NULL,
    loaded_at     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX ix_fact_leads_campaign ON dw.fact_leads(campaign_key) INCLUDE (is_converted, lead_score);
GO

PRINT 'SalesMarketingDW schema created.';
