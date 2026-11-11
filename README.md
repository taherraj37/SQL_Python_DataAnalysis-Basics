# Sales & Marketing Data Analytics: Python + SQL Server

Reusable code snippets for the full analytics workflow, built around a dummy dataset for a fictional sales & marketing company, **Northwind Growth Co.**

| # | Task | File |
|---|------|------|
| 1 | Data cleaning in Python | [`python/01_data_cleaning.py`](python/01_data_cleaning.py) |
| 2 | Data exploration in Python | [`python/02_data_exploration.py`](python/02_data_exploration.py) |
| 3 | Data cleaning & validation in SQL | [`sql/01_data_cleaning_validation.sql`](sql/01_data_cleaning_validation.sql) |
| 4 | Data exploration in SQL | [`sql/02_data_exploration.sql`](sql/02_data_exploration.sql) |
| 5 | ETL procedures in SQL | [`sql/03_etl_procedures.sql`](sql/03_etl_procedures.sql) |
| 6 | Reports & views in SQL | [`sql/04_reports_and_views.sql`](sql/04_reports_and_views.sql) |

SQL scripts target **Microsoft SQL Server 2017+ / Azure SQL (T-SQL)**.

---

## Dataset

`data/generate_dummy_data.py` creates 5 CSVs in `data/raw/` (seeded, so it's reproducible):

| File | Rows | Description |
|------|------|-------------|
| `customers.csv` | ~517 | Customer master: name, email, phone, city, region, segment, signup date |
| `products.csv` | 40 | Catalogue: software, services, hardware, subscriptions |
| `campaigns.csv` | 24 | Marketing campaigns: type, dates, budget, target region |
| `leads.csv` | ~3,030 | Leads by campaign and source, with lead score and conversion status |
| `sales.csv` | ~6,040 | Order lines: date, customer, product, campaign, qty, price, discount, channel, rep, status |

The data has **deliberate quality problems** for the cleaning scripts to fix:

- exact duplicate rows and duplicate keys with conflicting values
- extra whitespace and inconsistent casing (`NORTH`, `  online `, `completed `)
- mixed date formats (`2025-03-07`, `03/07/2025`, `07-Mar-2025`) and invalid dates (`31/31/2024`, `TBD`)
- currency stored as text (`$1,234.50`)
- missing values, invalid emails and phone numbers
- negative quantities, discounts over 100%, extreme outliers
- orphan foreign keys (orders for customer `C99999`) and a campaign whose end date is before its start date

## Project structure

```
sales-marketing-data-analytics/
├── data/
│   ├── generate_dummy_data.py     # creates data/raw/*.csv
│   └── raw/                       # messy source CSVs
├── python/
│   ├── 01_data_cleaning.py        # -> data/clean/*.csv + data_quality_report.csv
│   └── 02_data_exploration.py     # -> console EDA + reports/figures/*.png
├── sql/
│   ├── 00_setup_database.sql      # database, schemas, staging + star schema
│   ├── 01_data_cleaning_validation.sql
│   ├── 02_data_exploration.sql
│   ├── 03_etl_procedures.sql
│   └── 04_reports_and_views.sql
├── requirements.txt
└── README.md
```

---

## Python quick start

```bash
pip install -r requirements.txt
python data/generate_dummy_data.py     # optional: raw CSVs are already committed
python python/01_data_cleaning.py
python python/02_data_exploration.py
```

**01_data_cleaning.py** covers text standardisation, multi-format date parsing, currency parsing, de-duplication, email and phone validation, imputation (category median margin, source median lead score), business-rule validation with a **rejects file**, derived measures (net revenue, COGS, profit), IQR outlier flagging, and a **data-quality report**.

**02_data_exploration.py** covers dataset overview, frequencies, KPIs, monthly trend with MoM growth and a rolling average, pivot tables, channel and rep performance, top products, Pareto (80/20) analysis, **RFM segmentation**, the lead funnel, **campaign ROI**, correlations, and saved charts.

---

## SQL Server quick start

Run the scripts in **this order** (SSMS, Azure Data Studio or `sqlcmd`):

```sql
-- 1. create database, schemas and tables
:r sql/00_setup_database.sql
-- 2. cleaning functions, clean views and validation procedure
:r sql/01_data_cleaning_validation.sql
-- 3. ETL procedures
:r sql/03_etl_procedures.sql

-- 4. run the ETL (path must be readable by the SQL Server service)
EXEC etl.usp_Run_ETL @DataPath = N'C:\repos\sales-marketing-data-analytics\data\raw\';

-- 5. explore and report
:r sql/02_data_exploration.sql
:r sql/04_reports_and_views.sql
```

> `:r` needs SQLCMD mode. Otherwise, open and run each file in turn.
> On Azure SQL, `BULK INSERT` must read from Azure Blob Storage through an `EXTERNAL DATA SOURCE`. You can also load the CSVs with the SSMS *Import Flat File* wizard into the `stg.*` tables, then run `EXEC etl.usp_Run_ETL;` with no path.

### Architecture

```
CSV files ──BULK INSERT──► stg.*  (raw NVARCHAR)
                             │
                             ▼  etl.vw_*_clean   (typed, standardised, de-duplicated, dq_issue flag)
                             │  etl.usp_Validate_Staging ──► etl.dq_reject_log
                             ▼
         dw.dim_date / dim_customer (SCD2) / dim_product / dim_campaign
         dw.fact_sales / dw.fact_leads
                             │
                             ▼
         rpt.vw_* views, rpt.fn_TopCustomers, rpt.usp_SalesReport, rpt.usp_ExecutiveSummary
```

### What each SQL script shows

**01 – Cleaning & validation:** profiling (completeness, duplicates, value domains, date-pattern detection, range and FK checks), reusable functions (`fn_ParseDate`, `fn_ParseMoney`, `fn_ProperCase`, `fn_CleanPhone`, `fn_IsValidEmail`), clean views with `ROW_NUMBER()` de-duplication and imputation using `PERCENTILE_CONT`, and a validation procedure that logs every rejected row.

**02 – Exploration:** KPIs, percentiles and histogram, monthly trend with `LAG` / moving average / YTD, YoY `PIVOT`, `ROLLUP` subtotals, top-N per category, Pareto, cohort retention, lead funnel, lead-score quartiles with `NTILE`, campaign ROI, organic vs campaign revenue, and weekday seasonality.

**03 – ETL:** dynamic `BULK INSERT` extract, a generated date dimension, `MERGE` upserts (SCD Type 1), a **hash-based SCD Type 2** customer dimension, incremental fact loads, a **quality gate** that aborts when the reject rate is too high, a transaction with `TRY/CATCH`, and run/step logging.

**04 – Reports & views:** a flat BI view, monthly summary with MoM/YoY, product ranking, RFM segments, campaign ROI/ROAS/CPA, rep leaderboard with quota attainment, a data-quality dashboard, an **indexed (materialised) view**, an inline TVF, and parameterised report procedures.

---

## Useful queries after loading

```sql
SELECT * FROM etl.etl_run_log ORDER BY run_id DESC;
SELECT * FROM rpt.vw_DataQualityDashboard WHERE run_id = (SELECT MAX(run_id) FROM etl.etl_run_log);
SELECT * FROM rpt.vw_CampaignPerformance ORDER BY roi_pct DESC;
SELECT * FROM rpt.fn_TopCustomers(10, 2025);
EXEC rpt.usp_ExecutiveSummary @Year = 2025;
EXEC rpt.usp_SalesReport @StartDate = '2025-01-01', @EndDate = '2025-03-31', @Region = 'Central';
```

## Notes

- All data is synthetic. Names, emails and phone numbers are fake.
- `fn_ParseDate` uses style 106 for `dd-Mon-yyyy`, which expects an English session language (`SET LANGUAGE us_english`).
