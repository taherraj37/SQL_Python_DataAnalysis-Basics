/* =============================================================================
   02_data_exploration.sql
   -----------------------------------------------------------------------------
   Exploratory analysis on the loaded star schema (dw.*).
   Run after: EXEC etl.usp_Run_ETL @DataPath = N'...';

   Techniques: aggregates, GROUP BY ROLLUP, window functions (LAG, running
   totals, moving averages, RANK, NTILE), PERCENTILE_CONT, PIVOT, CTEs,
   cohort analysis, Pareto analysis, funnel and ROI analysis.
   ========================================================================= */
USE SalesMarketingDW;
GO

/* ---------------------------------------------------------------------------
   1. Overview - size and date coverage of the warehouse
   ------------------------------------------------------------------------- */
SELECT 'fact_sales' AS object_name, COUNT(*) AS row_count FROM dw.fact_sales UNION ALL
SELECT 'fact_leads',               COUNT(*) FROM dw.fact_leads   UNION ALL
SELECT 'dim_customer (current)',   COUNT(*) FROM dw.dim_customer WHERE is_current = 1 UNION ALL
SELECT 'dim_product',              COUNT(*) FROM dw.dim_product  UNION ALL
SELECT 'dim_campaign',             COUNT(*) FROM dw.dim_campaign;

SELECT MIN(d.full_date) AS first_order, MAX(d.full_date) AS last_order,
       COUNT(DISTINCT d.year_month) AS months_covered
FROM dw.fact_sales f JOIN dw.dim_date d ON d.date_key = f.date_key;

/* ---------------------------------------------------------------------------
   2. Headline KPIs (completed orders only)
   ------------------------------------------------------------------------- */
SELECT
    COUNT(*)                                              AS orders,
    COUNT(DISTINCT customer_key)                          AS active_customers,
    SUM(net_revenue)                                      AS net_revenue,
    SUM(gross_profit)                                     AS gross_profit,
    CAST(SUM(gross_profit) / NULLIF(SUM(net_revenue), 0) * 100 AS DECIMAL(5,2)) AS gross_margin_pct,
    CAST(AVG(net_revenue) AS DECIMAL(12,2))               AS avg_order_value,
    CAST(AVG(discount) * 100 AS DECIMAL(5,2))             AS avg_discount_pct
FROM dw.fact_sales
WHERE order_status = 'Completed';

-- order status mix
SELECT order_status, COUNT(*) AS orders,
       CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_of_orders
FROM dw.fact_sales
GROUP BY order_status;

/* ---------------------------------------------------------------------------
   3. Distribution of order value - percentiles
   ------------------------------------------------------------------------- */
SELECT DISTINCT
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY net_revenue) OVER () AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY net_revenue) OVER () AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY net_revenue) OVER () AS p75,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY net_revenue) OVER () AS p95
FROM dw.fact_sales
WHERE order_status = 'Completed';

-- histogram in 1,000-dollar buckets
SELECT FLOOR(net_revenue / 1000) * 1000 AS bucket_from, COUNT(*) AS orders
FROM dw.fact_sales
WHERE order_status = 'Completed' AND is_qty_outlier = 0
GROUP BY FLOOR(net_revenue / 1000) * 1000
ORDER BY bucket_from;

/* ---------------------------------------------------------------------------
   4. Monthly trend: MoM growth, 3-month moving average, running total
   ------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT d.year_month, SUM(f.net_revenue) AS revenue, COUNT(*) AS orders
    FROM dw.fact_sales f
    JOIN dw.dim_date d ON d.date_key = f.date_key
    WHERE f.order_status = 'Completed'
    GROUP BY d.year_month
)
SELECT year_month, orders, revenue,
       LAG(revenue) OVER (ORDER BY year_month)                                   AS prev_month,
       CAST((revenue - LAG(revenue) OVER (ORDER BY year_month))
            / NULLIF(LAG(revenue) OVER (ORDER BY year_month), 0) * 100 AS DECIMAL(7,2)) AS mom_growth_pct,
       AVG(revenue) OVER (ORDER BY year_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_avg_3m,
       SUM(revenue) OVER (PARTITION BY LEFT(year_month, 4) ORDER BY year_month
                          ROWS UNBOUNDED PRECEDING)                               AS ytd_revenue
FROM monthly
ORDER BY year_month;

/* ---------------------------------------------------------------------------
   5. Year-over-year by quarter (PIVOT)
   ------------------------------------------------------------------------- */
SELECT quarter_label, [2024], [2025],
       CAST(([2025] - [2024]) / NULLIF([2024], 0) * 100 AS DECIMAL(6,2)) AS yoy_growth_pct
FROM (
    SELECT CONCAT('Q', d.[quarter]) AS quarter_label, d.[year], f.net_revenue
    FROM dw.fact_sales f JOIN dw.dim_date d ON d.date_key = f.date_key
    WHERE f.order_status = 'Completed'
) src
PIVOT (SUM(net_revenue) FOR [year] IN ([2024], [2025])) p
ORDER BY quarter_label;

/* ---------------------------------------------------------------------------
   6. Region x segment with subtotals (ROLLUP)
   ------------------------------------------------------------------------- */
SELECT COALESCE(c.region,  'ALL REGIONS')  AS region,
       COALESCE(c.segment, 'ALL SEGMENTS') AS segment,
       COUNT(*)            AS orders,
       SUM(f.net_revenue)  AS revenue,
       SUM(f.gross_profit) AS profit
FROM dw.fact_sales f
JOIN dw.dim_customer c ON c.customer_key = f.customer_key
WHERE f.order_status = 'Completed'
GROUP BY ROLLUP (c.region, c.segment)
ORDER BY GROUPING(c.region), c.region, GROUPING(c.segment), revenue DESC;

/* ---------------------------------------------------------------------------
   7. Top 3 products in each category (RANK within partition)
   ------------------------------------------------------------------------- */
WITH prod AS (
    SELECT p.category, p.product_name,
           SUM(f.quantity) AS units, SUM(f.net_revenue) AS revenue,
           CAST(AVG(p.margin_pct) * 100 AS DECIMAL(5,2)) AS margin_pct
    FROM dw.fact_sales f JOIN dw.dim_product p ON p.product_key = f.product_key
    WHERE f.order_status = 'Completed'
    GROUP BY p.category, p.product_name
)
SELECT *
FROM (SELECT *, DENSE_RANK() OVER (PARTITION BY category ORDER BY revenue DESC) AS rnk FROM prod) r
WHERE rnk <= 3
ORDER BY category, rnk;

/* ---------------------------------------------------------------------------
   8. Channel and sales-rep performance
   ------------------------------------------------------------------------- */
SELECT channel, COUNT(*) AS orders, SUM(net_revenue) AS revenue,
       CAST(AVG(net_revenue) AS DECIMAL(12,2)) AS aov,
       CAST(SUM(net_revenue) * 100.0 / SUM(SUM(net_revenue)) OVER () AS DECIMAL(5,2)) AS revenue_share_pct
FROM dw.fact_sales
WHERE order_status = 'Completed'
GROUP BY channel
ORDER BY revenue DESC;

SELECT sales_rep, COUNT(*) AS orders, SUM(net_revenue) AS revenue,
       CAST(SUM(CASE WHEN order_status = 'Returned' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS return_rate_pct,
       RANK() OVER (ORDER BY SUM(net_revenue) DESC) AS revenue_rank
FROM dw.fact_sales
GROUP BY sales_rep;

/* ---------------------------------------------------------------------------
   9. Pareto: what share of customers drives 80 % of revenue?
   ------------------------------------------------------------------------- */
WITH cust AS (
    SELECT customer_key, SUM(net_revenue) AS revenue
    FROM dw.fact_sales WHERE order_status = 'Completed'
    GROUP BY customer_key
), cum AS (
    SELECT *, SUM(revenue) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING)
                / SUM(revenue) OVER () AS cum_share,
              ROW_NUMBER() OVER (ORDER BY revenue DESC) AS rn,
              COUNT(*) OVER () AS total_customers
    FROM cust
)
SELECT MIN(rn) AS customers_for_80pct, MAX(total_customers) AS total_customers,
       CAST(MIN(rn) * 100.0 / MAX(total_customers) AS DECIMAL(5,2)) AS pct_of_customers
FROM cum
WHERE cum_share >= 0.80;

/* ---------------------------------------------------------------------------
   10. Monthly acquisition cohorts - retention by months since first order
   ------------------------------------------------------------------------- */
WITH orders AS (
    SELECT f.customer_key, d.full_date
    FROM dw.fact_sales f JOIN dw.dim_date d ON d.date_key = f.date_key
    WHERE f.order_status = 'Completed'
), firsts AS (
    SELECT customer_key, DATEFROMPARTS(YEAR(MIN(full_date)), MONTH(MIN(full_date)), 1) AS cohort_month
    FROM orders GROUP BY customer_key
), activity AS (
    SELECT DISTINCT o.customer_key, fi.cohort_month,
           DATEDIFF(MONTH, fi.cohort_month, o.full_date) AS month_n
    FROM orders o JOIN firsts fi ON fi.customer_key = o.customer_key
)
SELECT cohort_month,
       COUNT(DISTINCT CASE WHEN month_n = 0 THEN customer_key END) AS cohort_size,
       COUNT(DISTINCT CASE WHEN month_n = 1 THEN customer_key END) AS m1,
       COUNT(DISTINCT CASE WHEN month_n = 2 THEN customer_key END) AS m2,
       COUNT(DISTINCT CASE WHEN month_n = 3 THEN customer_key END) AS m3,
       COUNT(DISTINCT CASE WHEN month_n = 6 THEN customer_key END) AS m6
FROM activity
GROUP BY cohort_month
ORDER BY cohort_month;

/* ---------------------------------------------------------------------------
   11. Marketing funnel by lead source
   ------------------------------------------------------------------------- */
SELECT lead_source,
       COUNT(*)                                                 AS leads,
       SUM(CASE WHEN lead_status IN ('Qualified', 'Converted') THEN 1 ELSE 0 END) AS qualified_or_better,
       SUM(CAST(is_converted AS INT))                           AS converted,
       CAST(AVG(CAST(is_converted AS DECIMAL(5,2))) * 100 AS DECIMAL(5,2)) AS conversion_pct,
       AVG(lead_score)                                          AS avg_lead_score
FROM dw.fact_leads
GROUP BY lead_source
ORDER BY conversion_pct DESC;

-- does lead score predict conversion? (score quartiles)
SELECT score_quartile, MIN(lead_score) AS min_score, MAX(lead_score) AS max_score, COUNT(*) AS leads,
       CAST(AVG(CAST(is_converted AS DECIMAL(5,2))) * 100 AS DECIMAL(5,2)) AS conversion_pct
FROM (SELECT *, NTILE(4) OVER (ORDER BY lead_score) AS score_quartile FROM dw.fact_leads) q
GROUP BY score_quartile
ORDER BY score_quartile;

/* ---------------------------------------------------------------------------
   12. Campaign ROI and cost per lead
   ------------------------------------------------------------------------- */
WITH rev AS (
    SELECT campaign_key, SUM(net_revenue) AS attributed_revenue
    FROM dw.fact_sales WHERE order_status = 'Completed' AND campaign_key IS NOT NULL
    GROUP BY campaign_key
), lds AS (
    SELECT campaign_key, COUNT(*) AS leads, SUM(CAST(is_converted AS INT)) AS conversions
    FROM dw.fact_leads GROUP BY campaign_key
)
SELECT c.campaign_id, c.campaign_type, c.budget, l.leads, l.conversions,
       r.attributed_revenue,
       CAST(c.budget / NULLIF(l.leads, 0) AS DECIMAL(10,2))       AS cost_per_lead,
       CAST(c.budget / NULLIF(l.conversions, 0) AS DECIMAL(10,2)) AS cost_per_conversion,
       CAST((r.attributed_revenue - c.budget) / c.budget * 100 AS DECIMAL(10,2)) AS roi_pct
FROM dw.dim_campaign c
LEFT JOIN rev r ON r.campaign_key = c.campaign_key
LEFT JOIN lds l ON l.campaign_key = c.campaign_key
ORDER BY roi_pct DESC;

-- organic vs campaign-driven revenue
SELECT CASE WHEN campaign_key IS NULL THEN 'Organic' ELSE 'Campaign' END AS source,
       COUNT(*) AS orders, SUM(net_revenue) AS revenue,
       CAST(AVG(net_revenue) AS DECIMAL(12,2)) AS aov
FROM dw.fact_sales WHERE order_status = 'Completed'
GROUP BY CASE WHEN campaign_key IS NULL THEN 'Organic' ELSE 'Campaign' END;

/* ---------------------------------------------------------------------------
   13. Seasonality - weekday pattern
   ------------------------------------------------------------------------- */
SELECT d.day_of_week, d.day_name, COUNT(*) AS orders, SUM(f.net_revenue) AS revenue
FROM dw.fact_sales f JOIN dw.dim_date d ON d.date_key = f.date_key
WHERE f.order_status = 'Completed'
GROUP BY d.day_of_week, d.day_name
ORDER BY d.day_of_week;
