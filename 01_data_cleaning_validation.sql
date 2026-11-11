/* =============================================================================
   01_data_cleaning_validation.sql
   -----------------------------------------------------------------------------
   Data cleaning & validation on the raw staging tables (stg.*).

   Part A - Profiling queries        : understand what is wrong
   Part B - Reusable cleaning funcs  : parse dates / money, proper-case, phone
   Part C - Clean views              : de-duplicated, typed, standardised data
                                       with a dq_issue column per row
   Part D - Validation procedure     : logs every failing row to
                                       etl.dq_reject_log and returns a summary

   Run after the staging tables are loaded:
       EXEC etl.usp_Load_Staging @DataPath = 'C:\data\raw\';   (see 03_...)
   ========================================================================== */
USE SalesMarketingDW;
GO

/* =========================================================================
   PART A - DATA PROFILING
   ========================================================================= */

-- A1. Row counts per staging table
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM stg.customers UNION ALL
SELECT 'products',  COUNT(*) FROM stg.products  UNION ALL
SELECT 'campaigns', COUNT(*) FROM stg.campaigns UNION ALL
SELECT 'leads',     COUNT(*) FROM stg.leads     UNION ALL
SELECT 'sales',     COUNT(*) FROM stg.sales;

-- A2. Column completeness for customers (NULL or blank)
SELECT
    COUNT(*)                                                         AS total_rows,
    SUM(CASE WHEN NULLIF(TRIM(email), '')       IS NULL THEN 1 ELSE 0 END) AS missing_email,
    SUM(CASE WHEN NULLIF(TRIM(phone), '')       IS NULL THEN 1 ELSE 0 END) AS missing_phone,
    SUM(CASE WHEN NULLIF(TRIM(signup_date), '') IS NULL THEN 1 ELSE 0 END) AS missing_signup,
    COUNT(DISTINCT customer_id)                                      AS distinct_ids
FROM stg.customers;

-- A3. Exact duplicate rows vs duplicate business keys
SELECT customer_id, COUNT(*) AS copies,
       COUNT(DISTINCT CONCAT_WS('|', first_name, last_name, email, city, region)) AS distinct_versions
FROM stg.customers
GROUP BY customer_id
HAVING COUNT(*) > 1
ORDER BY distinct_versions DESC, copies DESC;

-- A4. Inconsistent categorical values (casing / whitespace)
SELECT region, COUNT(*) AS n FROM stg.customers GROUP BY region ORDER BY region;
SELECT channel, COUNT(*) AS n FROM stg.sales GROUP BY channel ORDER BY channel;
SELECT '[' + status + ']' AS status_with_brackets, COUNT(*) AS n FROM stg.sales GROUP BY status;

-- A5. Date formats in use (pattern profiling)
SELECT
    CASE
        WHEN order_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'             THEN 'yyyy-mm-dd'
        WHEN order_date LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'             THEN 'mm/dd/yyyy'
        WHEN order_date LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]' THEN 'dd-Mon-yyyy'
        WHEN order_date LIKE '[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]'             THEN 'yyyy/mm/dd'
        ELSE 'OTHER: ' + ISNULL(NULLIF(order_date, ''), '<blank>')
    END AS date_pattern,
    COUNT(*) AS n
FROM stg.sales
GROUP BY
    CASE
        WHEN order_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'             THEN 'yyyy-mm-dd'
        WHEN order_date LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'             THEN 'mm/dd/yyyy'
        WHEN order_date LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]' THEN 'dd-Mon-yyyy'
        WHEN order_date LIKE '[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]'             THEN 'yyyy/mm/dd'
        ELSE 'OTHER: ' + ISNULL(NULLIF(order_date, ''), '<blank>')
    END
ORDER BY n DESC;

-- A6. Numeric fields stored as text that won't convert
SELECT unit_price, COUNT(*) AS n
FROM stg.sales
WHERE TRY_CAST(unit_price AS DECIMAL(12,2)) IS NULL
GROUP BY unit_price;

-- A7. Range / business-rule checks on sales
SELECT
    SUM(CASE WHEN TRY_CAST(quantity AS INT) <= 0                       THEN 1 ELSE 0 END) AS non_positive_qty,
    SUM(CASE WHEN TRY_CAST(discount AS DECIMAL(6,4)) NOT BETWEEN 0 AND 1 THEN 1 ELSE 0 END) AS bad_discount,
    MIN(TRY_CAST(quantity AS INT)) AS min_qty,
    MAX(TRY_CAST(quantity AS INT)) AS max_qty
FROM stg.sales;

-- A8. Referential integrity: sales pointing at customers that do not exist
SELECT s.customer_id, COUNT(*) AS orphan_orders
FROM stg.sales s
WHERE NOT EXISTS (SELECT 1 FROM stg.customers c WHERE TRIM(c.customer_id) = TRIM(s.customer_id))
GROUP BY s.customer_id;

-- A9. Invalid e-mail addresses
SELECT customer_id, email
FROM stg.customers
WHERE email NOT LIKE '_%@_%._%' OR email LIKE '% %' OR email LIKE '%@%@%' OR email IS NULL;

-- A10. Logical date check on campaigns
SELECT campaign_id, start_date, end_date
FROM stg.campaigns
WHERE TRY_CONVERT(DATE, end_date, 23) < TRY_CONVERT(DATE, start_date, 23);
GO

/* =========================================================================
   PART B - REUSABLE CLEANING FUNCTIONS
   ========================================================================= */

-- B1. Parse a date written in any of the known formats; NULL if invalid
CREATE OR ALTER FUNCTION etl.fn_ParseDate (@v NVARCHAR(50))
RETURNS DATE
WITH SCHEMABINDING
AS
BEGIN
    SET @v = NULLIF(TRIM(@v), '');
    RETURN CASE
        WHEN @v LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'               THEN TRY_CONVERT(DATE, @v, 23)
        WHEN @v LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'               THEN TRY_CONVERT(DATE, @v, 101)
        WHEN @v LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, REPLACE(@v, '-', ' '), 106)
        WHEN @v LIKE '[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]'               THEN TRY_CONVERT(DATE, @v, 111)
    END;
END;
GO

-- B2. '$1,234.50' -> 1234.50
CREATE OR ALTER FUNCTION etl.fn_ParseMoney (@v NVARCHAR(50))
RETURNS DECIMAL(12,2)
WITH SCHEMABINDING
AS
BEGIN
    RETURN TRY_CAST(REPLACE(REPLACE(REPLACE(TRIM(@v), '$', ''), ',', ''), ' ', '') AS DECIMAL(12,2));
END;
GO

-- B3. '  direct SALES ' -> 'Direct Sales'
CREATE OR ALTER FUNCTION etl.fn_ProperCase (@v NVARCHAR(200))
RETURNS NVARCHAR(200)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(200) = LOWER(TRIM(@v)), @i INT = 1, @out NVARCHAR(200) = N'';
    IF @s IS NULL OR @s = N'' RETURN NULL;
    WHILE CHARINDEX(N'  ', @s) > 0 SET @s = REPLACE(@s, N'  ', N' ');   -- collapse spaces
    WHILE @i <= LEN(@s)
    BEGIN
        SET @out += CASE WHEN @i = 1 OR SUBSTRING(@s, @i - 1, 1) IN (N' ', N'-', N'''')
                         THEN UPPER(SUBSTRING(@s, @i, 1)) ELSE SUBSTRING(@s, @i, 1) END;
        SET @i += 1;
    END;
    RETURN @out;
END;
GO

-- B4. Keep digits only, must be exactly 10 digits
CREATE OR ALTER FUNCTION etl.fn_CleanPhone (@v NVARCHAR(50))
RETURNS CHAR(10)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @d NVARCHAR(50) = REPLACE(TRANSLATE(ISNULL(@v, N''), N'()-.+', N'     '), N' ', N'');
    RETURN CASE WHEN LEN(@d) = 10 AND @d NOT LIKE N'%[^0-9]%' THEN @d END;
END;
GO

-- B5. Basic e-mail validation
CREATE OR ALTER FUNCTION etl.fn_IsValidEmail (@v NVARCHAR(255))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE WHEN @v LIKE N'_%@_%._%'
                 AND @v NOT LIKE N'% %'
                 AND @v NOT LIKE N'%@%@%'
                 AND @v NOT LIKE N'%..%'
                THEN 1 ELSE 0 END;
END;
GO

-- quick self-test
SELECT etl.fn_ParseDate('2025-03-07')   AS iso,
       etl.fn_ParseDate('03/07/2025')   AS us,
       etl.fn_ParseDate('07-Mar-2025')  AS dmy_text,
       etl.fn_ParseDate('31/31/2024')   AS invalid,
       etl.fn_ParseMoney('$1,234.50')   AS money,
       etl.fn_ProperCase('  direct   SALES ') AS proper,
       etl.fn_CleanPhone('(416) 555-0199') AS phone,
       etl.fn_IsValidEmail('a.b@example.com') AS good_email,
       etl.fn_IsValidEmail('a.bexample.com')  AS bad_email;
GO

/* =========================================================================
   PART C - CLEAN VIEWS (typed, standardised, de-duplicated)
   Each view exposes dq_issue: NULL = row passes all rules
   ========================================================================= */

CREATE OR ALTER VIEW etl.vw_customers_clean
AS
WITH typed AS (
    SELECT
        UPPER(TRIM(customer_id))                          AS customer_id,
        etl.fn_ProperCase(first_name)                     AS first_name,
        etl.fn_ProperCase(last_name)                      AS last_name,
        LOWER(NULLIF(TRIM(email), ''))                    AS email_raw,
        etl.fn_CleanPhone(phone)                          AS phone,
        etl.fn_ProperCase(city)                           AS city,
        etl.fn_ProperCase(region)                         AS region,
        etl.fn_ProperCase(segment)                        AS segment,
        etl.fn_ParseDate(signup_date)                     AS signup_date,
        -- one row per customer_id: exact duplicates collapse, conflicting
        -- duplicates keep the first version seen
        ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(customer_id)) ORDER BY (SELECT NULL)) AS rn
    FROM stg.customers
)
SELECT
    customer_id, first_name, last_name,
    CASE WHEN etl.fn_IsValidEmail(email_raw) = 1 THEN email_raw END AS email,
    CAST(etl.fn_IsValidEmail(email_raw) AS BIT)                     AS email_valid,
    phone, city, region, segment, signup_date,
    CASE
        WHEN customer_id NOT LIKE 'C[0-9][0-9][0-9][0-9][0-9]' THEN 'invalid customer_id'
        WHEN region NOT IN ('North', 'South', 'East', 'West', 'Central') THEN 'unknown region'
    END AS dq_issue
FROM typed
WHERE rn = 1;
GO

CREATE OR ALTER VIEW etl.vw_products_clean
AS
WITH typed AS (
    SELECT UPPER(TRIM(product_id))       AS product_id,
           TRIM(product_name)            AS product_name,
           etl.fn_ProperCase(category)   AS category,
           etl.fn_ParseMoney(unit_cost)  AS unit_cost,
           etl.fn_ParseMoney(list_price) AS list_price,
           ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(product_id)) ORDER BY (SELECT NULL)) AS rn
    FROM stg.products
), ratio AS (   -- category median cost/price ratio for imputing missing cost
    SELECT DISTINCT category,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY unit_cost / list_price)
               OVER (PARTITION BY category) AS median_cost_ratio
    FROM typed WHERE unit_cost IS NOT NULL AND list_price > 0
)
SELECT t.product_id, t.product_name, t.category,
       COALESCE(t.unit_cost, CAST(t.list_price * r.median_cost_ratio AS DECIMAL(12,2))) AS unit_cost,
       CAST(CASE WHEN t.unit_cost IS NULL THEN 1 ELSE 0 END AS BIT)                     AS unit_cost_imputed,
       t.list_price,
       CASE WHEN t.list_price IS NULL OR t.list_price < 0 THEN 'invalid list_price' END AS dq_issue
FROM typed t
LEFT JOIN ratio r ON r.category = t.category
WHERE t.rn = 1;
GO

CREATE OR ALTER VIEW etl.vw_campaigns_clean
AS
WITH typed AS (
    SELECT UPPER(TRIM(campaign_id))            AS campaign_id,
           TRIM(campaign_name)                 AS campaign_name,
           etl.fn_ProperCase(campaign_type)    AS campaign_type,
           etl.fn_ParseDate(start_date)        AS d1,
           etl.fn_ParseDate(end_date)          AS d2,
           etl.fn_ParseMoney(budget)           AS budget,
           etl.fn_ProperCase(target_region)    AS target_region,
           ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(campaign_id)) ORDER BY (SELECT NULL)) AS rn
    FROM stg.campaigns
)
SELECT campaign_id, campaign_name, campaign_type,
       -- fix reversed start / end dates
       CASE WHEN d2 < d1 THEN d2 ELSE d1 END AS start_date,
       CASE WHEN d2 < d1 THEN d1 ELSE d2 END AS end_date,
       CAST(CASE WHEN d2 < d1 THEN 1 ELSE 0 END AS BIT) AS dates_swapped,
       budget, target_region,
       CASE WHEN d1 IS NULL OR d2 IS NULL THEN 'invalid campaign dates'
            WHEN budget IS NULL OR budget < 0 THEN 'invalid budget' END AS dq_issue
FROM typed
WHERE rn = 1;
GO

CREATE OR ALTER VIEW etl.vw_leads_clean
AS
WITH typed AS (
    SELECT UPPER(TRIM(l.lead_id))                         AS lead_id,
           UPPER(TRIM(l.campaign_id))                     AS campaign_id,
           CASE UPPER(TRIM(l.lead_source))
                WHEN 'LINKEDIN'   THEN 'LinkedIn'
                WHEN 'GOOGLE ADS' THEN 'Google Ads'
                ELSE etl.fn_ProperCase(l.lead_source) END AS lead_source,
           etl.fn_ParseDate(l.created_date)               AS created_date,
           CAST(ROUND(TRY_CAST(l.lead_score AS DECIMAL(5,1)), 0) AS TINYINT) AS lead_score_raw,
           etl.fn_ProperCase(l.status)                    AS lead_status,
           NULLIF(UPPER(TRIM(l.customer_id)), '')         AS customer_id,
           ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(l.lead_id)) ORDER BY (SELECT NULL)) AS rn
    FROM stg.leads l
)
SELECT t.lead_id, t.campaign_id, t.lead_source, t.created_date,
       -- impute missing score with the median score of the same lead source
       COALESCE(t.lead_score_raw,
                CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY t.lead_score_raw)
                     OVER (PARTITION BY t.lead_source) AS TINYINT)) AS lead_score,
       CAST(CASE WHEN t.lead_score_raw IS NULL THEN 1 ELSE 0 END AS BIT) AS lead_score_imputed,
       t.lead_status,
       CAST(CASE WHEN t.lead_status = 'Converted' THEN 1 ELSE 0 END AS BIT) AS is_converted,
       t.customer_id,
       CASE
           WHEN NOT EXISTS (SELECT 1 FROM etl.vw_campaigns_clean c WHERE c.campaign_id = t.campaign_id)
                THEN 'unknown campaign_id'
           WHEN t.lead_status = 'Converted' AND t.customer_id IS NULL
                THEN 'converted lead without customer'
       END AS dq_issue
FROM typed t
WHERE t.rn = 1;
GO

CREATE OR ALTER VIEW etl.vw_sales_clean
AS
WITH typed AS (
    SELECT UPPER(TRIM(s.order_id))                      AS order_id,
           etl.fn_ParseDate(s.order_date)               AS order_date,
           UPPER(TRIM(s.customer_id))                   AS customer_id,
           UPPER(TRIM(s.product_id))                    AS product_id,
           NULLIF(UPPER(TRIM(s.campaign_id)), '')       AS campaign_id,
           TRY_CAST(s.quantity AS INT)                  AS quantity,
           etl.fn_ParseMoney(s.unit_price)              AS unit_price,
           TRY_CAST(s.discount AS DECIMAL(6,4))         AS discount,
           etl.fn_ProperCase(s.channel)                 AS channel,
           COALESCE(NULLIF(TRIM(s.sales_rep), ''), 'Unassigned') AS sales_rep,
           etl.fn_ProperCase(s.status)                  AS order_status,
           ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(s.order_id)) ORDER BY (SELECT NULL)) AS rn
    FROM stg.sales s
)
SELECT t.*,
       CAST(t.quantity * t.unit_price AS DECIMAL(14,2))                      AS gross_revenue,
       CAST(t.quantity * t.unit_price * (1 - t.discount) AS DECIMAL(14,2))   AS net_revenue,
       -- validation rules, first failing rule wins
       CASE
           WHEN t.order_date IS NULL                         THEN 'missing / bad order_date'
           WHEN t.quantity IS NULL OR t.quantity <= 0        THEN 'quantity <= 0'
           WHEN t.unit_price IS NULL OR t.unit_price < 0     THEN 'invalid unit_price'
           WHEN t.discount IS NULL OR t.discount NOT BETWEEN 0 AND 1 THEN 'discount outside 0-1'
           WHEN NOT EXISTS (SELECT 1 FROM etl.vw_customers_clean c WHERE c.customer_id = t.customer_id)
                                                             THEN 'unknown customer_id'
           WHEN NOT EXISTS (SELECT 1 FROM etl.vw_products_clean p WHERE p.product_id = t.product_id)
                                                             THEN 'unknown product_id'
           WHEN t.campaign_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM etl.vw_campaigns_clean c WHERE c.campaign_id = t.campaign_id)
                                                             THEN 'unknown campaign_id'
           WHEN t.order_status NOT IN ('Completed', 'Returned', 'Cancelled') THEN 'unknown status'
       END AS dq_issue
FROM typed t
WHERE t.rn = 1;
GO

/* =========================================================================
   PART D - VALIDATION PROCEDURE
   Writes every rejected row (incl. duplicates) to etl.dq_reject_log
   ========================================================================= */
CREATE OR ALTER PROCEDURE etl.usp_Validate_Staging
    @RunId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Duplicate rows (anything beyond the first copy of a business key)
    INSERT etl.dq_reject_log (run_id, source_table, business_key, reject_reason, raw_record)
    SELECT @RunId, 'sales', order_id, 'duplicate order_id', raw_record
    FROM (SELECT order_id,
                 CONCAT_WS('|', order_id, order_date, customer_id, product_id, quantity, unit_price) AS raw_record,
                 ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(order_id)) ORDER BY (SELECT NULL)) AS rn
          FROM stg.sales) d
    WHERE rn > 1;

    INSERT etl.dq_reject_log (run_id, source_table, business_key, reject_reason, raw_record)
    SELECT @RunId, 'customers', customer_id, 'duplicate customer_id', raw_record
    FROM (SELECT customer_id,
                 CONCAT_WS('|', customer_id, first_name, last_name, email, city) AS raw_record,
                 ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(customer_id)) ORDER BY (SELECT NULL)) AS rn
          FROM stg.customers) d
    WHERE rn > 1;

    -- 2. Rule failures surfaced by the clean views
    INSERT etl.dq_reject_log (run_id, source_table, business_key, reject_reason, raw_record)
    SELECT @RunId, 'sales', order_id, dq_issue,
           CONCAT_WS('|', order_id, order_date, customer_id, product_id, quantity, unit_price, discount)
    FROM etl.vw_sales_clean WHERE dq_issue IS NOT NULL;

    INSERT etl.dq_reject_log (run_id, source_table, business_key, reject_reason, raw_record)
    SELECT @RunId, 'leads', lead_id, dq_issue, CONCAT_WS('|', lead_id, campaign_id, lead_status, customer_id)
    FROM etl.vw_leads_clean WHERE dq_issue IS NOT NULL;

    INSERT etl.dq_reject_log (run_id, source_table, business_key, reject_reason, raw_record)
    SELECT @RunId, 'customers', customer_id, dq_issue, CONCAT_WS('|', customer_id, region)
    FROM etl.vw_customers_clean WHERE dq_issue IS NOT NULL;

    -- 3. Warnings (row is kept but flagged) - for the summary only
    SELECT source_table, reject_reason, COUNT(*) AS rows_rejected
    FROM etl.dq_reject_log
    WHERE (run_id = @RunId) OR (@RunId IS NULL AND run_id IS NULL)
    GROUP BY source_table, reject_reason
    UNION ALL
    SELECT 'customers', 'WARNING: invalid email (kept, set NULL)', COUNT(*)
    FROM etl.vw_customers_clean WHERE email_valid = 0
    UNION ALL
    SELECT 'products', 'WARNING: unit_cost imputed', COUNT(*)
    FROM etl.vw_products_clean WHERE unit_cost_imputed = 1
    UNION ALL
    SELECT 'campaigns', 'WARNING: start/end dates swapped', COUNT(*)
    FROM etl.vw_campaigns_clean WHERE dates_swapped = 1
    ORDER BY source_table, rows_rejected DESC;
END;
GO

-- Example: EXEC etl.usp_Validate_Staging;
