/* =============================================================================
   04_reports_and_views.sql
   -----------------------------------------------------------------------------
   Reporting layer (rpt schema) for BI tools such as Power BI / Excel / SSRS.

   Views
     rpt.vw_SalesDetail            flat, denormalised sales (BI-friendly)
     rpt.vw_MonthlySalesSummary    month x region KPIs with MoM / YoY
     rpt.vw_ProductPerformance     product ranking, margin, return rate
     rpt.vw_CustomerRFM            RFM scores and segment per customer
     rpt.vw_CampaignPerformance    leads, conversions, revenue, ROI
     rpt.vw_SalesRepLeaderboard    rep ranking and quota attainment
     rpt.vw_DataQualityDashboard   reject counts per ETL run
     rpt.vw_DailySalesIndexed      materialised (indexed) daily totals

   Functions / procedures
     rpt.fn_TopCustomers(@TopN, @Year)            inline TVF
     rpt.usp_SalesReport @Start, @End, @Region    parameterised report
     rpt.usp_ExecutiveSummary @Year               KPI pack, current vs prior year
   ========================================================================= */
USE SalesMarketingDW;
GO

/* ---------------------------------------------------------------------------
   1. Flat sales view - one row per order line, all attributes resolved
   ------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_SalesDetail
AS
SELECT
    f.order_id,
    d.full_date        AS order_date,
    d.[year], d.[quarter], d.year_month, d.month_name, d.day_name,
    c.customer_id, c.full_name AS customer_name, c.segment, c.region, c.city,
    p.product_id, p.product_name, p.category,
    ISNULL(cp.campaign_id, 'ORGANIC')   AS campaign_id,
    ISNULL(cp.campaign_type, 'Organic') AS campaign_type,
    f.channel, f.sales_rep, f.order_status,
    f.quantity, f.unit_price, f.discount,
    f.gross_revenue, f.net_revenue, f.cogs, f.gross_profit,
    CAST(f.gross_profit / NULLIF(f.net_revenue, 0) AS DECIMAL(6,4)) AS margin_pct,
    f.is_qty_outlier
FROM dw.fact_sales f
JOIN dw.dim_date     d       ON d.date_key      = f.date_key
JOIN dw.dim_customer c       ON c.customer_key  = f.customer_key
JOIN dw.dim_product  p       ON p.product_key   = f.product_key
LEFT JOIN dw.dim_campaign cp ON cp.campaign_key = f.campaign_key;
GO

/* ---------------------------------------------------------------------------
   2. Monthly summary by region with MoM and YoY growth
   ------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_MonthlySalesSummary
AS
WITH m AS (
    SELECT [year], [month], year_month, region,
           COUNT(*)                         AS orders,
           COUNT(DISTINCT customer_id)      AS customers,
           SUM(net_revenue)                 AS revenue,
           SUM(gross_profit)                AS profit
    FROM rpt.vw_SalesDetail
    WHERE order_status = 'Completed'
    GROUP BY [year], [month], year_month, region
)
SELECT m.*,
       CAST(profit / NULLIF(revenue, 0) * 100 AS DECIMAL(6,2))                AS margin_pct,
       CAST(revenue / NULLIF(orders, 0) AS DECIMAL(12,2))                     AS avg_order_value,
       LAG(revenue, 1)  OVER (PARTITION BY region ORDER BY year_month)        AS revenue_prev_month,
       LAG(revenue, 12) OVER (PARTITION BY region ORDER BY year_month)        AS revenue_same_month_ly,
       CAST((revenue - LAG(revenue, 1) OVER (PARTITION BY region ORDER BY year_month))
            / NULLIF(LAG(revenue, 1) OVER (PARTITION BY region ORDER BY year_month), 0) * 100
            AS DECIMAL(8,2))                                                  AS mom_growth_pct,
       CAST((revenue - LAG(revenue, 12) OVER (PARTITION BY region ORDER BY year_month))
            / NULLIF(LAG(revenue, 12) OVER (PARTITION BY region ORDER BY year_month), 0) * 100
            AS DECIMAL(8,2))                                                  AS yoy_growth_pct
FROM m;
GO

/* ---------------------------------------------------------------------------
   3. Product performance
   ------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_ProductPerformance
AS
SELECT p.product_id, p.product_name, p.category, p.list_price, p.margin_pct AS list_margin_pct,
       SUM(CASE WHEN f.order_status = 'Completed' THEN f.quantity    ELSE 0 END) AS units_sold,
       SUM(CASE WHEN f.order_status = 'Completed' THEN f.net_revenue ELSE 0 END) AS revenue,
       SUM(CASE WHEN f.order_status = 'Completed' THEN f.gross_profit ELSE 0 END) AS profit,
       CAST(SUM(CASE WHEN f.order_status = 'Returned' THEN 1 ELSE 0 END) * 100.0
            / NULLIF(COUNT(f.sales_key), 0) AS DECIMAL(5,2))                    AS return_rate_pct,
       RANK() OVER (ORDER BY SUM(CASE WHEN f.order_status = 'Completed' THEN f.net_revenue ELSE 0 END) DESC)
                                                                                AS overall_rank,
       RANK() OVER (PARTITION BY p.category
                    ORDER BY SUM(CASE WHEN f.order_status = 'Completed' THEN f.net_revenue ELSE 0 END) DESC)
                                                                                AS category_rank
FROM dw.dim_product p
LEFT JOIN dw.fact_sales f ON f.product_key = p.product_key
GROUP BY p.product_id, p.product_name, p.category, p.list_price, p.margin_pct;
GO

/* ---------------------------------------------------------------------------
   4. Customer RFM segmentation
   ------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_CustomerRFM
AS
WITH base AS (
    SELECT c.customer_id, c.full_name, c.segment, c.region,
           MAX(d.full_date)            AS last_order_date,
           COUNT(DISTINCT f.order_id)  AS frequency,
           SUM(f.net_revenue)          AS monetary
    FROM dw.fact_sales f
    JOIN dw.dim_customer c ON c.customer_key = f.customer_key
    JOIN dw.dim_date d     ON d.date_key     = f.date_key
    WHERE f.order_status = 'Completed'
    GROUP BY c.customer_id, c.full_name, c.segment, c.region
), scored AS (
    SELECT *,
           DATEDIFF(DAY, last_order_date, MAX(last_order_date) OVER ()) AS recency_days,
           NTILE(4) OVER (ORDER BY last_order_date ASC) AS r_score,   -- most recent = 4
           NTILE(4) OVER (ORDER BY frequency ASC)       AS f_score,
           NTILE(4) OVER (ORDER BY monetary ASC)        AS m_score
    FROM base
)
SELECT *,
       r_score + f_score + m_score AS rfm_total,
       CASE
           WHEN r_score + f_score + m_score >= 11 THEN 'Champions'
           WHEN r_score + f_score + m_score >= 9  THEN 'Loyal'
           WHEN r_score >= 3 AND f_score <= 2     THEN 'Promising'
           WHEN r_score <= 2 AND m_score >= 3     THEN 'At Risk - High Value'
           WHEN r_score + f_score + m_score <= 5  THEN 'Hibernating'
           ELSE 'Needs Attention'
       END AS rfm_segment
FROM scored;
GO

/* ---------------------------------------------------------------------------
   5. Campaign performance & ROI
   ------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_CampaignPerformance
AS
WITH lds AS (
    SELECT campaign_key, COUNT(*) AS leads,
           SUM(CAST(is_converted AS INT)) AS conversions,
           AVG(CAST(lead_score AS DECIMAL(6,2))) AS avg_lead_score
    FROM dw.fact_leads GROUP BY campaign_key
), rev AS (
    SELECT campaign_key, COUNT(*) AS orders, SUM(net_revenue) AS revenue, SUM(gross_profit) AS profit
    FROM dw.fact_sales WHERE order_status = 'Completed' AND campaign_key IS NOT NULL
    GROUP BY campaign_key
)
SELECT c.campaign_id, c.campaign_name, c.campaign_type, c.target_region,
       c.start_date, c.end_date, c.duration_days, c.budget,
       ISNULL(l.leads, 0)        AS leads,
       ISNULL(l.conversions, 0)  AS conversions,
       l.avg_lead_score,
       CAST(ISNULL(l.conversions, 0) * 100.0 / NULLIF(l.leads, 0) AS DECIMAL(5,2)) AS conversion_rate_pct,
       ISNULL(r.orders, 0)       AS attributed_orders,
       ISNULL(r.revenue, 0)      AS attributed_revenue,
       ISNULL(r.profit, 0)       AS attributed_profit,
       CAST(c.budget / NULLIF(l.leads, 0) AS DECIMAL(10,2))          AS cost_per_lead,
       CAST(c.budget / NULLIF(l.conversions, 0) AS DECIMAL(10,2))    AS cost_per_acquisition,
       CAST(ISNULL(r.revenue, 0) / NULLIF(c.budget, 0) AS DECIMAL(10,2)) AS roas,
       CAST((ISNULL(r.profit, 0) - c.budget) / NULLIF(c.budget, 0) * 100 AS DECIMAL(10,2)) AS roi_pct
FROM dw.dim_campaign c
LEFT JOIN lds l ON l.campaign_key = c.campaign_key
LEFT JOIN rev r ON r.campaign_key = c.campaign_key;
GO

/* ---------------------------------------------------------------------------
   6. Sales rep leaderboard (with an example quarterly quota of 750k)
   ------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_SalesRepLeaderboard
AS
WITH q AS (
    SELECT sales_rep, [year], [quarter],
           COUNT(*) AS orders, SUM(net_revenue) AS revenue, SUM(gross_profit) AS profit,
           CAST(AVG(discount) * 100 AS DECIMAL(5,2)) AS avg_discount_pct
    FROM rpt.vw_SalesDetail
    WHERE order_status = 'Completed'
    GROUP BY sales_rep, [year], [quarter]
)
SELECT *,
       CAST(750000 AS DECIMAL(12,2))                          AS quota,
       CAST(revenue / 750000 * 100 AS DECIMAL(6,2))           AS quota_attainment_pct,
       RANK() OVER (PARTITION BY [year], [quarter] ORDER BY revenue DESC) AS rank_in_quarter
FROM q;
GO

/* ---------------------------------------------------------------------------
   7. Data-quality dashboard
   ------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_DataQualityDashboard
AS
SELECT r.run_id, r.started_at, r.status AS run_status,
       q.source_table, q.reject_reason, COUNT(q.reject_id) AS rejected_rows
FROM etl.etl_run_log r
LEFT JOIN etl.dq_reject_log q ON q.run_id = r.run_id
GROUP BY r.run_id, r.started_at, r.status, q.source_table, q.reject_reason;
GO

/* ---------------------------------------------------------------------------
   8. Indexed (materialised) view - pre-aggregated daily totals.
      Requires SCHEMABINDING, two-part names, COUNT_BIG and no outer joins.
   ------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_DailySalesIndexed
WITH SCHEMABINDING
AS
SELECT f.date_key, f.product_key,
       COUNT_BIG(*)            AS order_lines,
       SUM(f.quantity)         AS units,
       SUM(f.net_revenue)      AS revenue,
       SUM(ISNULL(f.gross_profit, 0)) AS profit
FROM dw.fact_sales f
WHERE f.order_status = 'Completed'
GROUP BY f.date_key, f.product_key;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'cix_vw_DailySalesIndexed')
    CREATE UNIQUE CLUSTERED INDEX cix_vw_DailySalesIndexed
        ON rpt.vw_DailySalesIndexed (date_key, product_key);
GO

/* ---------------------------------------------------------------------------
   9. Inline table-valued function - top N customers for a year
   ------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION rpt.fn_TopCustomers (@TopN INT, @Year SMALLINT)
RETURNS TABLE
AS
RETURN
    SELECT TOP (@TopN)
           customer_id, customer_name, segment, region,
           COUNT(*) AS orders, SUM(net_revenue) AS revenue,
           RANK() OVER (ORDER BY SUM(net_revenue) DESC) AS revenue_rank
    FROM rpt.vw_SalesDetail
    WHERE order_status = 'Completed' AND [year] = @Year
    GROUP BY customer_id, customer_name, segment, region
    ORDER BY revenue DESC;
GO

/* ---------------------------------------------------------------------------
   10. Parameterised sales report (for SSRS / Power BI / Excel)
       Returns 3 result sets: KPIs, breakdown by category, daily trend
   ------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE rpt.usp_SalesReport
    @StartDate DATE,
    @EndDate   DATE,
    @Region    VARCHAR(20) = NULL    -- NULL = all regions
AS
BEGIN
    SET NOCOUNT ON;
    IF @EndDate < @StartDate
        THROW 50010, '@EndDate must be on or after @StartDate.', 1;

    SELECT * INTO #s
    FROM rpt.vw_SalesDetail
    WHERE order_date BETWEEN @StartDate AND @EndDate
      AND (@Region IS NULL OR region = @Region);

    -- KPIs
    SELECT @StartDate AS period_start, @EndDate AS period_end, ISNULL(@Region, 'All') AS region,
           SUM(CASE WHEN order_status = 'Completed' THEN net_revenue END)  AS net_revenue,
           SUM(CASE WHEN order_status = 'Completed' THEN gross_profit END) AS gross_profit,
           COUNT(CASE WHEN order_status = 'Completed' THEN 1 END)          AS completed_orders,
           COUNT(DISTINCT customer_id)                                     AS customers,
           CAST(COUNT(CASE WHEN order_status = 'Returned' THEN 1 END) * 100.0
                / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                     AS return_rate_pct
    FROM #s;

    -- by category and channel
    SELECT category, channel, COUNT(*) AS orders, SUM(net_revenue) AS revenue,
           CAST(SUM(net_revenue) * 100.0 / SUM(SUM(net_revenue)) OVER () AS DECIMAL(5,2)) AS share_pct
    FROM #s WHERE order_status = 'Completed'
    GROUP BY category, channel
    ORDER BY revenue DESC;

    -- daily trend with 7-day moving average
    SELECT order_date, SUM(net_revenue) AS revenue,
           AVG(SUM(net_revenue)) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS ma_7d
    FROM #s WHERE order_status = 'Completed'
    GROUP BY order_date
    ORDER BY order_date;
END;
GO

/* ---------------------------------------------------------------------------
   11. Executive summary - current year vs prior year, one row per KPI
   ------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE rpt.usp_ExecutiveSummary
    @Year SMALLINT
AS
BEGIN
    SET NOCOUNT ON;

    WITH y AS (
        SELECT [year],
               SUM(net_revenue)                AS revenue,
               SUM(gross_profit)               AS profit,
               COUNT(*)                        AS orders,
               COUNT(DISTINCT customer_id)     AS customers,
               AVG(net_revenue)                AS aov
        FROM rpt.vw_SalesDetail
        WHERE order_status = 'Completed' AND [year] IN (@Year, @Year - 1)
        GROUP BY [year]
    ), l AS (
        SELECT d.[year], COUNT(*) AS leads, SUM(CAST(fl.is_converted AS INT)) AS conversions
        FROM dw.fact_leads fl JOIN dw.dim_date d ON d.date_key = fl.date_key
        WHERE d.[year] IN (@Year, @Year - 1)
        GROUP BY d.[year]
    ), kpi AS (
        SELECT y.[year], v.kpi, v.sort_order, v.val
        FROM y LEFT JOIN l ON l.[year] = y.[year]
        CROSS APPLY (VALUES
            (1, 'Net revenue',       CAST(y.revenue AS DECIMAL(18,2))),
            (2, 'Gross profit',      CAST(y.profit AS DECIMAL(18,2))),
            (3, 'Gross margin %',    CAST(y.profit / NULLIF(y.revenue, 0) * 100 AS DECIMAL(18,2))),
            (4, 'Orders',            CAST(y.orders AS DECIMAL(18,2))),
            (5, 'Active customers',  CAST(y.customers AS DECIMAL(18,2))),
            (6, 'Avg order value',   CAST(y.aov AS DECIMAL(18,2))),
            (7, 'Leads',             CAST(l.leads AS DECIMAL(18,2))),
            (8, 'Lead conversion %', CAST(l.conversions * 100.0 / NULLIF(l.leads, 0) AS DECIMAL(18,2)))
        ) v (sort_order, kpi, val)
    )
    SELECT cur.kpi,
           cur.val AS current_year,
           prv.val AS prior_year,
           cur.val - prv.val AS change,
           CAST((cur.val - prv.val) / NULLIF(prv.val, 0) * 100 AS DECIMAL(8,2)) AS change_pct
    FROM kpi cur
    LEFT JOIN kpi prv ON prv.kpi = cur.kpi AND prv.[year] = @Year - 1
    WHERE cur.[year] = @Year
    ORDER BY cur.sort_order;
END;
GO

/* ---------------------------------------------------------------------------
   Example usage
   ------------------------------------------------------------------------- */
-- SELECT TOP 100 * FROM rpt.vw_SalesDetail ORDER BY order_date DESC;
-- SELECT * FROM rpt.vw_MonthlySalesSummary WHERE region = 'Central' ORDER BY year_month;
-- SELECT rfm_segment, COUNT(*) AS customers, SUM(monetary) AS revenue
--   FROM rpt.vw_CustomerRFM GROUP BY rfm_segment ORDER BY revenue DESC;
-- SELECT * FROM rpt.vw_CampaignPerformance ORDER BY roi_pct DESC;
-- SELECT * FROM rpt.vw_SalesRepLeaderboard WHERE [year] = 2025 AND [quarter] = 4;
-- SELECT * FROM rpt.fn_TopCustomers(10, 2025);
-- EXEC rpt.usp_SalesReport @StartDate = '2025-01-01', @EndDate = '2025-06-30', @Region = 'West';
-- EXEC rpt.usp_ExecutiveSummary @Year = 2025;
