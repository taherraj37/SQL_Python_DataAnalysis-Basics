"""
01_data_cleaning.py
-------------------
Cleans the raw Northwind Growth Co. sales & marketing CSVs with pandas.

Techniques demonstrated
    * standardising text (trim, casing, canonical values)
    * parsing mixed-format dates
    * converting currency strings to numbers
    * removing exact duplicates and resolving duplicate business keys
    * validating emails / phone numbers
    * handling missing values (impute vs. flag)
    * enforcing business rules (no negative qty, discount 0-1, valid FKs)
    * IQR-based outlier flagging
    * writing a data-quality report alongside the clean files

Usage:
    python python/01_data_cleaning.py
Outputs:
    data/clean/*.csv  and  data/clean/data_quality_report.csv
"""
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW, CLEAN = ROOT / "data" / "raw", ROOT / "data" / "clean"
CLEAN.mkdir(parents=True, exist_ok=True)

DQ_LOG: list[dict] = []  # data-quality findings collected as we go


def log(table: str, check: str, rows: int, action: str) -> None:
    DQ_LOG.append({"table": table, "check": check, "rows_affected": int(rows), "action": action})


# --------------------------------------------------------------------------- #
# Reusable helpers
# --------------------------------------------------------------------------- #
def clean_text(s: pd.Series, case: str | None = "title") -> pd.Series:
    """Trim whitespace, collapse inner spaces, normalise case, '' -> NaN."""
    s = s.astype("string").str.strip().str.replace(r"\s+", " ", regex=True)
    if case == "title":
        s = s.str.title()
    elif case == "upper":
        s = s.str.upper()
    elif case == "lower":
        s = s.str.lower()
    return s.replace({"": pd.NA})


def parse_mixed_dates(s: pd.Series) -> pd.Series:
    """Try several known formats; anything unparseable becomes NaT."""
    s = s.astype("string").str.strip()
    result = pd.Series(pd.NaT, index=s.index, dtype="datetime64[ns]")
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%d-%b-%Y", "%Y/%m/%d"):
        mask = result.isna()
        result[mask] = pd.to_datetime(s[mask], format=fmt, errors="coerce")
    return result


def to_money(s: pd.Series) -> pd.Series:
    """'$1,234.50' -> 1234.50 (float)."""
    return pd.to_numeric(s.astype("string").str.replace(r"[$,\s]", "", regex=True), errors="coerce")


def drop_exact_duplicates(df: pd.DataFrame, table: str) -> pd.DataFrame:
    n = df.duplicated().sum()
    log(table, "exact duplicate rows", n, "dropped")
    return df.drop_duplicates()


def dedupe_on_key(df: pd.DataFrame, key: str, table: str, order_by: str | None = None) -> pd.DataFrame:
    """Keep one row per business key (first occurrence, or latest by `order_by`)."""
    n = df.duplicated(subset=key).sum()
    log(table, f"duplicate {key}", n, "kept first occurrence")
    if order_by:
        df = df.sort_values(order_by, ascending=False)
    return df.drop_duplicates(subset=key, keep="first")


def iqr_outlier_flag(s: pd.Series, k: float = 3.0) -> pd.Series:
    q1, q3 = s.quantile([0.25, 0.75])
    iqr = q3 - q1
    return (s < q1 - k * iqr) | (s > q3 + k * iqr)


# --------------------------------------------------------------------------- #
# Customers
# --------------------------------------------------------------------------- #
def clean_customers() -> pd.DataFrame:
    df = pd.read_csv(RAW / "customers.csv", dtype=str, keep_default_na=False)
    df = drop_exact_duplicates(df, "customers")

    for col in ("first_name", "last_name", "city", "region"):
        df[col] = clean_text(df[col])
    df["segment"] = clean_text(df["segment"])
    df["customer_id"] = clean_text(df["customer_id"], case="upper")

    # e-mail validation
    df["email"] = clean_text(df["email"], case="lower")
    valid_email = df["email"].str.match(r"^[\w.+-]+@[\w-]+\.[a-z]{2,}$", na=False)
    log("customers", "invalid / missing email", (~valid_email).sum(), "set to NULL, flagged")
    df["email_valid"] = valid_email
    df.loc[~valid_email, "email"] = pd.NA

    # phone -> digits only, must be 10 digits
    digits = df["phone"].str.replace(r"\D", "", regex=True)
    df["phone"] = digits.where(digits.str.len() == 10)
    log("customers", "missing / invalid phone", df["phone"].isna().sum(), "set to NULL")

    df["signup_date"] = parse_mixed_dates(df["signup_date"])
    log("customers", "unparseable signup_date", df["signup_date"].isna().sum(), "set to NULL")

    df["full_name"] = df["first_name"] + " " + df["last_name"]
    df = dedupe_on_key(df, "customer_id", "customers")
    return df.sort_values("customer_id").reset_index(drop=True)


# --------------------------------------------------------------------------- #
# Products
# --------------------------------------------------------------------------- #
def clean_products() -> pd.DataFrame:
    df = pd.read_csv(RAW / "products.csv", dtype=str)
    df = drop_exact_duplicates(df, "products")
    df["product_name"] = clean_text(df["product_name"], case=None)
    df["category"] = clean_text(df["category"])
    df["list_price"] = to_money(df["list_price"])
    df["unit_cost"] = to_money(df["unit_cost"])

    # impute missing cost with the category's median cost-to-price ratio
    missing = df["unit_cost"].isna()
    ratio = (df["unit_cost"] / df["list_price"]).groupby(df["category"]).transform("median")
    df.loc[missing, "unit_cost"] = (df["list_price"] * ratio).round(2)
    log("products", "missing unit_cost", missing.sum(), "imputed with category median margin")

    df["margin_pct"] = ((df["list_price"] - df["unit_cost"]) / df["list_price"]).round(4)
    return df


# --------------------------------------------------------------------------- #
# Campaigns
# --------------------------------------------------------------------------- #
def clean_campaigns() -> pd.DataFrame:
    df = pd.read_csv(RAW / "campaigns.csv", dtype=str)
    df = drop_exact_duplicates(df, "campaigns")
    df["start_date"] = parse_mixed_dates(df["start_date"])
    df["end_date"] = parse_mixed_dates(df["end_date"])
    df["budget"] = to_money(df["budget"])

    # swap start/end when they are reversed
    bad = df["end_date"] < df["start_date"]
    df.loc[bad, ["start_date", "end_date"]] = df.loc[bad, ["end_date", "start_date"]].values
    log("campaigns", "end_date before start_date", bad.sum(), "dates swapped")

    df["duration_days"] = (df["end_date"] - df["start_date"]).dt.days
    return df


# --------------------------------------------------------------------------- #
# Leads
# --------------------------------------------------------------------------- #
def clean_leads(valid_campaigns: set) -> pd.DataFrame:
    df = pd.read_csv(RAW / "leads.csv", dtype=str, keep_default_na=False)
    df = drop_exact_duplicates(df, "leads")
    df["lead_source"] = clean_text(df["lead_source"])
    df["lead_source"] = df["lead_source"].replace({"Linkedin": "LinkedIn"})
    df["status"] = clean_text(df["status"])
    df["created_date"] = parse_mixed_dates(df["created_date"])
    df["customer_id"] = clean_text(df["customer_id"], case="upper")

    df["lead_score"] = pd.to_numeric(df["lead_score"], errors="coerce")
    missing = df["lead_score"].isna()
    df.loc[missing, "lead_score"] = df.groupby("lead_source")["lead_score"].transform("median")[missing]
    df["lead_score"] = df["lead_score"].round().astype("Int64")
    log("leads", "missing lead_score", missing.sum(), "imputed with source median")

    orphan = ~df["campaign_id"].isin(valid_campaigns)
    log("leads", "unknown campaign_id", orphan.sum(), "rows removed")
    df = df[~orphan]

    df["is_converted"] = df["status"].eq("Converted")
    return dedupe_on_key(df, "lead_id", "leads")


# --------------------------------------------------------------------------- #
# Sales
# --------------------------------------------------------------------------- #
def clean_sales(customers: pd.DataFrame, products: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    df = pd.read_csv(RAW / "sales.csv", dtype=str, keep_default_na=False)
    df = drop_exact_duplicates(df, "sales")

    df["order_date"] = parse_mixed_dates(df["order_date"])
    df["quantity"] = pd.to_numeric(df["quantity"], errors="coerce")
    df["unit_price"] = to_money(df["unit_price"])
    df["discount"] = pd.to_numeric(df["discount"], errors="coerce")
    df["channel"] = clean_text(df["channel"])
    df["status"] = clean_text(df["status"])
    df["sales_rep"] = clean_text(df["sales_rep"], case=None).fillna("Unassigned")
    df["campaign_id"] = clean_text(df["campaign_id"], case="upper")  # '' -> NA (organic sale)

    # ---- business rules: rows that fail go to a reject file, not silently lost
    rules = {
        "missing / bad order_date": df["order_date"].isna(),
        "quantity <= 0": df["quantity"] <= 0,
        "discount outside 0-1": ~df["discount"].between(0, 1),
        "unknown customer_id": ~df["customer_id"].isin(customers["customer_id"]),
        "unknown product_id": ~df["product_id"].isin(products["product_id"]),
    }
    df["reject_reason"] = pd.NA
    for reason, mask in rules.items():
        log("sales", reason, mask.sum(), "moved to rejects")
        df.loc[mask & df["reject_reason"].isna(), "reject_reason"] = reason
    rejects = df[df["reject_reason"].notna()].copy()
    df = df[df["reject_reason"].isna()].drop(columns="reject_reason")

    # ---- derived measures
    cost = products.set_index("product_id")["unit_cost"]
    df["gross_revenue"] = (df["quantity"] * df["unit_price"]).round(2)
    df["net_revenue"] = (df["gross_revenue"] * (1 - df["discount"])).round(2)
    df["cogs"] = (df["quantity"] * df["product_id"].map(cost)).round(2)
    df["gross_profit"] = (df["net_revenue"] - df["cogs"]).round(2)

    # ---- flag (don't delete) statistical outliers for analyst review
    df["is_qty_outlier"] = iqr_outlier_flag(df["quantity"])
    log("sales", "quantity outlier (3x IQR)", df["is_qty_outlier"].sum(), "flagged")

    df = dedupe_on_key(df, "order_id", "sales")
    return df.sort_values("order_date").reset_index(drop=True), rejects


# --------------------------------------------------------------------------- #
def main() -> None:
    customers = clean_customers()
    products = clean_products()
    campaigns = clean_campaigns()
    leads = clean_leads(set(campaigns["campaign_id"]))
    sales, rejects = clean_sales(customers, products)

    outputs = {"customers": customers, "products": products, "campaigns": campaigns,
               "leads": leads, "sales": sales, "sales_rejects": rejects,
               "data_quality_report": pd.DataFrame(DQ_LOG)}
    for name, df in outputs.items():
        df.to_csv(CLEAN / f"{name}.csv", index=False, date_format="%Y-%m-%d")
        print(f"{name:<22} {len(df):>6,} rows")

    print("\nData-quality summary:")
    print(pd.DataFrame(DQ_LOG).query("rows_affected > 0").to_string(index=False))


if __name__ == "__main__":
    main()
