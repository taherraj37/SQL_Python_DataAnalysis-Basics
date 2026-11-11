/* =============================================================================
   03_etl_procedures.sql
   -----------------------------------------------------------------------------
   ETL stored procedures: CSV -> stg -> (clean views) -> dw star schema

   Procedures
     etl.usp_Load_Staging      Extract : BULK INSERT the raw CSVs into stg.*
     etl.usp_Load_DimDate      Load    : generate the calendar dimension
     etl.usp_Load_DimProduct   Load    : MERGE upsert (SCD Type 1)
     etl.usp_Load_DimCampaign  Load    : MERGE upsert (SCD Type 1)
     etl.usp_Load_DimCustomer  Load    : SCD Type 2 with hash change detection
     etl.usp_Load_FactSales    Load    : incremental insert + update of status
     etl.usp_Load_FactLeads    Load    : incremental upsert
     etl.usp_Run_ETL           Orchestrator: logging, validation, transaction,
                                         TRY/CATCH error handling

   Run order: 00_setup_database.sql -> 01_data_cleaning_validation.sql -> this
   Then:      EXEC etl.usp_Run_ETL @DataPath = N'C:\repo\data\raw\';
   (the path is read by the SQL Server service, so it must be visible to it)
   ========================================================================= */
USE SalesMarketingDW;
GO

/* -------------------------------------------------------------------------
   Helper: write a step to the run log
   ------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_Log_Step
    @RunId INT, @StepName VARCHAR(100), @Inserted INT = NULL, @Updated INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT etl.etl_step_log (run_id, step_name, rows_inserted, rows_updated)
    VALUES (@RunId, @StepName, @Inserted, @Updated);
END;
GO

/* =========================================================================
   EXTRACT - BULK INSERT CSV files into staging (truncate & reload)
   ========================================================================= */
CREATE OR ALTER PROCEDURE etl.usp_Load_Staging
    @DataPath NVARCHAR(400),          -- folder containing the raw CSVs, trailing '\'
    @RunId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tables TABLE (name SYSNAME);
    INSERT @tables VALUES ('customers'), ('products'), ('campaigns'), ('leads'), ('sales');

    DECLARE @t SYSNAME, @sql NVARCHAR(MAX), @rows INT;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @tables;
    OPEN cur;
    FETCH NEXT FROM cur INTO @t;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'TRUNCATE TABLE stg.' + QUOTENAME(@t) + N';
                     BULK INSERT stg.' + QUOTENAME(@t) + N'
                     FROM N''' + REPLACE(@DataPath + @t + N'.csv', N'''', N'''''') + N'''
                     WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'',
                           FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'',
                           CODEPAGE = ''65001'', TABLOCK);
                     SET @rows = @@ROWCOUNT;';
        EXEC sp_executesql @sql, N'@rows INT OUTPUT', @rows = @rows OUTPUT;

        IF @RunId IS NOT NULL
        BEGIN
            DECLARE @step VARCHAR(100) = 'extract stg.' + @t;
            EXEC etl.usp_Log_Step @RunId, @step, @rows;
        END;
        FETCH NEXT FROM cur INTO @t;
    END;
    CLOSE cur; DEALLOCATE cur;
END;
GO

/* =========================================================================
   DIM DATE - generated, not sourced
   ========================================================================= */
CREATE OR ALTER PROCEDURE etl.usp_Load_DimDate
    @StartDate DATE = '2020-01-01',
    @EndDate   DATE = '2027-12-31'
AS
BEGIN
    SET NOCOUNT ON;
    SET DATEFIRST 1;   -- Monday = 1

    WITH n AS (   -- tally table: 0..N
        SELECT TOP (DATEDIFF(DAY, @StartDate, @EndDate) + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    ), d AS (
        SELECT DATEADD(DAY, i, @StartDate) AS dt FROM n
    )
    INSERT dw.dim_date (date_key, full_date, [year], [quarter], [month], month_name, year_month,
                        day_of_month, day_of_week, day_name, week_of_year, is_weekend)
    SELECT CONVERT(INT, CONVERT(CHAR(8), dt, 112)),
           dt, YEAR(dt), DATEPART(QUARTER, dt), MONTH(dt), DATENAME(MONTH, dt),
           CONVERT(CHAR(7), dt, 126),
           DAY(dt), DATEPART(WEEKDAY, dt), DATENAME(WEEKDAY, dt), DATEPART(ISO_WEEK, dt),
           CASE WHEN DATEPART(WEEKDAY, dt) IN (6, 7) THEN 1 ELSE 0 END
    FROM d
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date x WHERE x.full_date = d.dt);

    SELECT @@ROWCOUNT AS rows_inserted;
END;
GO

/* =========================================================================
   DIM PRODUCT - SCD Type 1 via MERGE
   ========================================================================= */
CREATE OR ALTER PROCEDURE etl.usp_Load_DimProduct
    @RunId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @changes TABLE (action NVARCHAR(10));

    MERGE dw.dim_product AS tgt
    USING (SELECT * FROM etl.vw_products_clean WHERE dq_issue IS NULL) AS src
        ON tgt.product_id = src.product_id
    WHEN MATCHED AND (   tgt.product_name <> src.product_name
                      OR tgt.category     <> src.category
                      OR ISNULL(tgt.unit_cost, -1) <> ISNULL(src.unit_cost, -1)
                      OR tgt.list_price   <> src.list_price)
        THEN UPDATE SET product_name = src.product_name, category = src.category,
                        unit_cost = src.unit_cost, list_price = src.list_price,
                        updated_at = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (product_id, product_name, category, unit_cost, list_price)
             VALUES (src.product_id, src.product_name, src.category, src.unit_cost, src.list_price)
    OUTPUT $action INTO @changes;

    DECLARE @ins INT = (SELECT COUNT(*) FROM @changes WHERE action = 'INSERT'),
            @upd INT = (SELECT COUNT(*) FROM @changes WHERE action = 'UPDATE');
    IF @RunId IS NOT NULL EXEC etl.usp_Log_Step @RunId, 'dw.dim_product', @ins, @upd;
END;
GO

/* =========================================================================
   DIM CAMPAIGN - SCD Type 1 via MERGE
   ========================================================================= */
CREATE OR ALTER PROCEDURE etl.usp_Load_DimCampaign
    @RunId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @changes TABLE (action NVARCHAR(10));

    MERGE dw.dim_campaign AS tgt
    USING (SELECT * FROM etl.vw_campaigns_clean WHERE dq_issue IS NULL) AS src
        ON tgt.campaign_id = src.campaign_id
    WHEN MATCHED AND (   tgt.campaign_name <> src.campaign_name
                      OR tgt.start_date    <> src.start_date
                      OR tgt.end_date      <> src.end_date
                      OR tgt.budget        <> src.budget
                      OR ISNULL(tgt.target_region, '') <> ISNULL(src.target_region, ''))
        THEN UPDATE SET campaign_name = src.campaign_name, campaign_type = src.campaign_type,
                        start_date = src.start_date, end_date = src.end_date,
                        budget = src.budget, target_region = src.target_region,
                        updated_at = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (campaign_id, campaign_name, campaign_type, start_date, end_date, budget, target_region)
             VALUES (src.campaign_id, src.campaign_name, src.campaign_type, src.start_date,
                     src.end_date, src.budget, src.target_region)
    OUTPUT $action INTO @changes;

    DECLARE @ins INT = (SELECT COUNT(*) FROM @changes WHERE action = 'INSERT'),
            @upd INT = (SELECT COUNT(*) FROM @changes WHERE action = 'UPDATE');
    IF @RunId IS NOT NULL EXEC etl.usp_Log_Step @RunId, 'dw.dim_campaign', @ins, @upd;
END;
GO

/* =========================================================================
   DIM CUSTOMER - SCD Type 2
     * a hash of the tracked attributes detects changes
     * changed rows: expire current version, insert a new current version
     * new customers: insert
   ========================================================================= */
CREATE OR ALTER PROCEDURE etl.usp_Load_DimCustomer
    @RunId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(0) = SYSDATETIME(), @expired INT, @inserted INT;

    SELECT customer_id, first_name, last_name, email, email_valid, phone,
           city, region, segment, signup_date,
           HASHBYTES('SHA2_256', CONCAT_WS('|', first_name, last_name, email, phone,
                                           city, region, segment, signup_date)) AS row_hash
    INTO #src
    FROM etl.vw_customers_clean
    WHERE dq_issue IS NULL;

    -- 1. expire current rows whose attributes changed
    UPDATE tgt
       SET valid_to = @now, is_current = 0
    FROM dw.dim_customer tgt
    JOIN #src s ON s.customer_id = tgt.customer_id
    WHERE tgt.is_current = 1 AND tgt.row_hash <> s.row_hash;
    SET @expired = @@ROWCOUNT;

    -- 2. insert new customers + new versions of changed customers
    INSERT dw.dim_customer (customer_id, first_name, last_name, email, email_valid, phone,
                            city, region, segment, signup_date, row_hash, valid_from)
    SELECT s.customer_id, s.first_name, s.last_name, s.email, s.email_valid, s.phone,
           s.city, s.region, s.segment, s.signup_date, s.row_hash, @now
    FROM #src s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer t
                      WHERE t.customer_id = s.customer_id AND t.is_current = 1);
    SET @inserted = @@ROWCOUNT;

    IF @RunId IS NOT NULL EXEC etl.usp_Log_Step @RunId, 'dw.dim_customer (SCD2)', @inserted, @expired;
END;
GO

/* =========================================================================
   FACT SALES - incremental
     * new order_ids are inserted with surrogate-key lookups
     * existing orders get their status refreshed (e.g. Completed -> Returned)
   ========================================================================= */
CREATE OR ALTER PROCEDURE etl.usp_Load_FactSales
    @RunId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ins INT, @upd INT;

    -- IQR fence for quantity outliers (Q3 + 3 * IQR)
    DECLARE @fence DECIMAL(12,2);
    SELECT TOP (1) @fence = q3 + 3 * (q3 - q1)
    FROM (SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY quantity) OVER () AS q1,
                 PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY quantity) OVER () AS q3
          FROM etl.vw_sales_clean WHERE dq_issue IS NULL) q;

    SELECT s.order_id,
           CONVERT(INT, CONVERT(CHAR(8), s.order_date, 112)) AS date_key,
           c.customer_key, p.product_key, cp.campaign_key,
           s.channel, s.sales_rep, s.order_status,
           s.quantity, s.unit_price, s.discount, s.gross_revenue, s.net_revenue,
           CAST(s.quantity * p.unit_cost AS DECIMAL(14,2))                 AS cogs,
           CAST(s.net_revenue - s.quantity * p.unit_cost AS DECIMAL(14,2)) AS gross_profit,
           CAST(CASE WHEN s.quantity > @fence THEN 1 ELSE 0 END AS BIT)    AS is_qty_outlier
    INTO #src
    FROM etl.vw_sales_clean s
    JOIN dw.dim_customer c       ON c.customer_id = s.customer_id AND c.is_current = 1
    JOIN dw.dim_product  p       ON p.product_id  = s.product_id
    LEFT JOIN dw.dim_campaign cp ON cp.campaign_id = s.campaign_id
    WHERE s.dq_issue IS NULL;

    -- update status of orders already loaded
    UPDATE f
       SET order_status = s.order_status, etl_run_id = @RunId, loaded_at = SYSDATETIME()
    FROM dw.fact_sales f
    JOIN #src s ON s.order_id = f.order_id
    WHERE f.order_status <> s.order_status;
    SET @upd = @@ROWCOUNT;

    -- insert new orders
    INSERT dw.fact_sales (order_id, date_key, customer_key, product_key, campaign_key, channel,
                          sales_rep, order_status, quantity, unit_price, discount, gross_revenue,
                          net_revenue, cogs, gross_profit, is_qty_outlier, etl_run_id)
    SELECT s.order_id, s.date_key, s.customer_key, s.product_key, s.campaign_key, s.channel,
           s.sales_rep, s.order_status, s.quantity, s.unit_price, s.discount, s.gross_revenue,
           s.net_revenue, s.cogs, s.gross_profit, s.is_qty_outlier, @RunId
    FROM #src s
    WHERE NOT EXISTS (SELECT 1 FROM dw.fact_sales f WHERE f.order_id = s.order_id);
    SET @ins = @@ROWCOUNT;

    IF @RunId IS NOT NULL EXEC etl.usp_Log_Step @RunId, 'dw.fact_sales', @ins, @upd;
END;
GO

/* =========================================================================
   FACT LEADS - incremental upsert
   ========================================================================= */
CREATE OR ALTER PROCEDURE etl.usp_Load_FactLeads
    @RunId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @changes TABLE (action NVARCHAR(10));

    MERGE dw.fact_leads AS tgt
    USING (
        SELECT l.lead_id,
               CONVERT(INT, CONVERT(CHAR(8), l.created_date, 112)) AS date_key,
               cp.campaign_key, c.customer_key, l.lead_source, l.lead_score,
               l.lead_status, l.is_converted
        FROM etl.vw_leads_clean l
        JOIN dw.dim_campaign cp     ON cp.campaign_id = l.campaign_id
        LEFT JOIN dw.dim_customer c ON c.customer_id  = l.customer_id AND c.is_current = 1
        WHERE l.dq_issue IS NULL
    ) AS src
        ON tgt.lead_id = src.lead_id
    WHEN MATCHED AND (tgt.lead_status <> src.lead_status
                      OR ISNULL(tgt.customer_key, -1) <> ISNULL(src.customer_key, -1))
        THEN UPDATE SET lead_status = src.lead_status, is_converted = src.is_converted,
                        customer_key = src.customer_key, etl_run_id = @RunId,
                        loaded_at = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (lead_id, date_key, campaign_key, customer_key, lead_source, lead_score,
                     lead_status, is_converted, etl_run_id)
             VALUES (src.lead_id, src.date_key, src.campaign_key, src.customer_key, src.lead_source,
                     src.lead_score, src.lead_status, src.is_converted, @RunId)
    OUTPUT $action INTO @changes;

    DECLARE @ins INT = (SELECT COUNT(*) FROM @changes WHERE action = 'INSERT'),
            @upd INT = (SELECT COUNT(*) FROM @changes WHERE action = 'UPDATE');
    IF @RunId IS NOT NULL EXEC etl.usp_Log_Step @RunId, 'dw.fact_leads', @ins, @upd;
END;
GO

/* =========================================================================
   ORCHESTRATOR
   ========================================================================= */
CREATE OR ALTER PROCEDURE etl.usp_Run_ETL
    @DataPath      NVARCHAR(400) = NULL,  -- NULL = skip extract, use what is in stg.*
    @MaxRejectPct  DECIMAL(5,2)  = 5.00   -- abort if more than x% of sales rows fail
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT etl.etl_run_log DEFAULT VALUES;
    DECLARE @RunId INT = SCOPE_IDENTITY();

    BEGIN TRY
        -- E: extract (outside the transaction - staging is disposable)
        IF @DataPath IS NOT NULL
            EXEC etl.usp_Load_Staging @DataPath = @DataPath, @RunId = @RunId;

        -- T: validate + quality gate
        EXEC etl.usp_Validate_Staging @RunId = @RunId;

        DECLARE @total INT = (SELECT COUNT(*) FROM stg.sales),
                @bad   INT = (SELECT COUNT(*) FROM etl.dq_reject_log
                              WHERE run_id = @RunId AND source_table = 'sales');
        IF @total = 0
            THROW 50001, 'stg.sales is empty - nothing to load.', 1;
        IF @bad * 100.0 / @total > @MaxRejectPct
        BEGIN
            DECLARE @msg NVARCHAR(400) = CONCAT('Quality gate failed: ',
                    CAST(@bad * 100.0 / @total AS DECIMAL(5,2)), '% of sales rows rejected (limit ',
                    @MaxRejectPct, '%).');
            THROW 50002, @msg, 1;
        END;

        -- L: load dimensions then facts in one transaction
        BEGIN TRANSACTION;
            IF NOT EXISTS (SELECT 1 FROM dw.dim_date) EXEC etl.usp_Load_DimDate;
            EXEC etl.usp_Load_DimProduct  @RunId;
            EXEC etl.usp_Load_DimCampaign @RunId;
            EXEC etl.usp_Load_DimCustomer @RunId;
            EXEC etl.usp_Load_FactSales   @RunId;
            EXEC etl.usp_Load_FactLeads   @RunId;
        COMMIT TRANSACTION;

        UPDATE etl.etl_run_log SET status = 'Succeeded', finished_at = SYSDATETIME()
        WHERE run_id = @RunId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        UPDATE etl.etl_run_log
           SET status = 'Failed', finished_at = SYSDATETIME(),
               error_message = CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE())
        WHERE run_id = @RunId;
        THROW;   -- re-raise so the caller / SQL Agent job sees the failure
    END CATCH;

    -- run summary
    SELECT r.run_id, r.status, r.started_at, r.finished_at,
           s.step_name, s.rows_inserted, s.rows_updated
    FROM etl.etl_run_log r
    LEFT JOIN etl.etl_step_log s ON s.run_id = r.run_id
    WHERE r.run_id = @RunId
    ORDER BY s.step_id;
END;
GO

/* -------------------------------------------------------------------------
   Usage
   -------------------------------------------------------------------------
   -- full run from CSV
   EXEC etl.usp_Run_ETL @DataPath = N'C:\repos\sales-marketing-data-analytics\data\raw\';

   -- re-run on what is already staged (idempotent: nothing new is inserted)
   EXEC etl.usp_Run_ETL;

   -- history
   SELECT * FROM etl.etl_run_log ORDER BY run_id DESC;
   SELECT * FROM etl.dq_reject_log WHERE run_id = (SELECT MAX(run_id) FROM etl.etl_run_log);

   -- schedule nightly with a SQL Server Agent job step:
   --   EXEC SalesMarketingDW.etl.usp_Run_ETL @DataPath = N'\\fileserver\exports\';
   ------------------------------------------------------------------------- */
