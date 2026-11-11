"""
02_data_exploration.py
----------------------
Exploratory data analysis (EDA) on the *cleaned* Northwind Growth Co. data.

Techniques demonstrated
    * dataset overview: shape, dtypes, nulls, descriptive stats
    * univariate distributions & categorical frequencies
    * time-series trends (monthly revenue, MoM growth, rolling average)
    * group-by aggregation and pivot tables
    * Pareto / 80-20 analysis of customers
    * RFM customer segmentation
    * marketing funnel: lead conversion and campaign ROI
    * correlation analysis
    * charts saved to reports/figures/

Usage (run 01_data_cleaning.py first):
    python python/02_data_exploration.py
"""
from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # headless - save figures to disk
import matplotlib.pyplot as plt
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
CLEAN = ROOT / "data" / "clean"
FIG = ROOT / "reports" / "figures"
FIG.mkdir(parents=True, exist_ok=True)
pd.set_option("display.width", 120, "display.max_columns", 20, "display.float_format", "{:,.2f}".format)


def section(title: str) -> None:
    print(f"\n{'=' * 80}\n{title}\n{'=' * 80}")


def save(fig, name: str) -> None:
    fig.tight_layout()
    fig.savefig(FIG / f"{name}.png", dpi=120)
    plt.close(fig)


# --------------------------------------------------------------------------- #
# Load
# --------------------------------------------------------------------------- #
sales = pd.read_csv(CLEAN / "sales.csv", parse_dates=["order_date"])
customers = pd.read_csv(CLEAN / "customers.csv", parse_dates=["signup_date"])
products = pd.read_csv(CLEAN / "products.csv")
campaigns = pd.read_csv(CLEAN / "campaigns.csv", parse_dates=["start_date", "end_date"])
leads = pd.read_csv(CLEAN / "leads.csv", parse_dates=["created_date"])

# Enrich sales with dimensions (only completed orders count as revenue)
df = (sales.merge(customers[["customer_id", "region", "segment"]], on="customer_id", how="left")
           .merge(products[["product_id", "product_name", "category"]], on="product_id", how="left"))
done = df[df["status"] == "Completed"].copy()

# --------------------------------------------------------------------------- #
section("1. Dataset overview")
for name, d in {"sales": sales, "customers": customers, "products": products,
                "campaigns": campaigns, "leads": leads}.items():
    print(f"{name:<10} rows={len(d):>6,}  cols={d.shape[1]:>2}  "
          f"null cells={int(d.isna().sum().sum()):>5}")
print("\nSales dtypes:\n", sales.dtypes.to_string())
print("\nNumeric summary (sales):")
print(sales[["quantity", "unit_price", "discount", "net_revenue", "gross_profit"]].describe().T)

# --------------------------------------------------------------------------- #
section("2. Categorical frequencies")
for col in ("status", "channel", "sales_rep"):
    print(f"\n{col}:\n", sales[col].value_counts(normalize=True).mul(100).round(1).to_string())

# --------------------------------------------------------------------------- #
section("3. Headline KPIs (completed orders)")
kpis = {
    "Orders": done["order_id"].nunique(),
    "Customers": done["customer_id"].nunique(),
    "Net revenue": done["net_revenue"].sum(),
    "Gross profit": done["gross_profit"].sum(),
    "Gross margin %": done["gross_profit"].sum() / done["net_revenue"].sum() * 100,
    "Avg order value": done["net_revenue"].mean(),
    "Return rate %": (df["status"] == "Returned").mean() * 100,
}
for k, v in kpis.items():
    print(f"{k:<18} {v:>14,.2f}")

# --------------------------------------------------------------------------- #
section("4. Monthly revenue trend")
monthly = (done.set_index("order_date").resample("MS")
               .agg(net_revenue=("net_revenue", "sum"), orders=("order_id", "count")))
monthly["mom_growth_%"] = monthly["net_revenue"].pct_change() * 100
monthly["rolling_3m"] = monthly["net_revenue"].rolling(3).mean()
print(monthly.tail(12))

fig, ax = plt.subplots(figsize=(10, 4))
ax.plot(monthly.index, monthly["net_revenue"], marker="o", label="Net revenue")
ax.plot(monthly.index, monthly["rolling_3m"], linestyle="--", label="3-month rolling avg")
ax.set_title("Monthly net revenue"); ax.set_ylabel("CAD"); ax.legend()
save(fig, "monthly_revenue")

# --------------------------------------------------------------------------- #
section("5. Revenue by region x category (pivot)")
pivot = done.pivot_table(index="region", columns="category", values="net_revenue",
                         aggfunc="sum", margins=True, margins_name="Total")
print(pivot)

by_cat = done.groupby("category")[["net_revenue", "gross_profit"]].sum().sort_values("net_revenue")
fig, ax = plt.subplots(figsize=(8, 4))
by_cat.plot.barh(ax=ax); ax.set_title("Revenue & profit by category")
save(fig, "revenue_by_category")

# --------------------------------------------------------------------------- #
section("6. Channel and sales-rep performance")
channel = done.groupby("channel").agg(orders=("order_id", "count"),
                                      revenue=("net_revenue", "sum"),
                                      aov=("net_revenue", "mean"),
                                      avg_discount=("discount", "mean"))
print(channel.sort_values("revenue", ascending=False))
reps = done.groupby("sales_rep")["net_revenue"].agg(["count", "sum", "mean"]).sort_values("sum", ascending=False)
reps["rank"] = reps["sum"].rank(ascending=False).astype(int)
print("\n", reps)

# --------------------------------------------------------------------------- #
section("7. Top products & Pareto (80/20) on customers")
print(done.groupby("product_name")["net_revenue"].sum().nlargest(10))

cust_rev = done.groupby("customer_id")["net_revenue"].sum().sort_values(ascending=False)
cum_share = cust_rev.cumsum() / cust_rev.sum()
top_n = (cum_share <= 0.8).sum() + 1
print(f"\n{top_n} of {len(cust_rev)} customers ({top_n / len(cust_rev):.0%}) generate 80% of revenue")

# --------------------------------------------------------------------------- #
section("8. RFM segmentation")
snapshot = done["order_date"].max() + pd.Timedelta(days=1)
rfm = done.groupby("customer_id").agg(
    recency=("order_date", lambda d: (snapshot - d.max()).days),
    frequency=("order_id", "nunique"),
    monetary=("net_revenue", "sum"),
)
rfm["R"] = pd.qcut(rfm["recency"], 4, labels=[4, 3, 2, 1]).astype(int)          # recent = high
rfm["F"] = pd.qcut(rfm["frequency"].rank(method="first"), 4, labels=[1, 2, 3, 4]).astype(int)
rfm["M"] = pd.qcut(rfm["monetary"], 4, labels=[1, 2, 3, 4]).astype(int)
rfm["score"] = rfm[["R", "F", "M"]].sum(axis=1)
rfm["segment"] = pd.cut(rfm["score"], bins=[0, 5, 8, 10, 12],
                        labels=["At risk", "Needs attention", "Loyal", "Champions"])
print(rfm.groupby("segment", observed=True).agg(customers=("score", "size"),
                                                avg_recency=("recency", "mean"),
                                                avg_frequency=("frequency", "mean"),
                                                avg_monetary=("monetary", "mean")))
rfm.to_csv(CLEAN / "customer_rfm.csv")

# --------------------------------------------------------------------------- #
section("9. Marketing funnel & campaign ROI")
funnel = leads.groupby("lead_source").agg(leads=("lead_id", "count"),
                                          converted=("is_converted", "sum"),
                                          avg_score=("lead_score", "mean"))
funnel["conversion_%"] = funnel["converted"] / funnel["leads"] * 100
print(funnel.sort_values("conversion_%", ascending=False))

camp_rev = done.groupby("campaign_id")["net_revenue"].sum().rename("attributed_revenue")
camp_leads = leads.groupby("campaign_id").agg(leads=("lead_id", "count"), conversions=("is_converted", "sum"))
roi = campaigns.set_index("campaign_id").join([camp_rev, camp_leads]).fillna(0)
roi["cost_per_lead"] = roi["budget"] / roi["leads"]
roi["roi_%"] = (roi["attributed_revenue"] - roi["budget"]) / roi["budget"] * 100
print(roi[["campaign_type", "budget", "leads", "conversions", "attributed_revenue",
           "cost_per_lead", "roi_%"]].sort_values("roi_%", ascending=False).head(10))
print("\nROI by campaign type:")
print(roi.groupby("campaign_type")[["budget", "attributed_revenue"]].sum()
         .assign(roi_pct=lambda t: (t.attributed_revenue - t.budget) / t.budget * 100)
         .sort_values("roi_pct", ascending=False))

# --------------------------------------------------------------------------- #
section("10. Correlations & distribution")
print(done[["quantity", "unit_price", "discount", "net_revenue", "gross_profit"]].corr().round(2))

fig, ax = plt.subplots(figsize=(8, 4))
done.loc[~done["is_qty_outlier"], "net_revenue"].plot.hist(bins=40, ax=ax)
ax.set_title("Order-line net revenue distribution (outliers excluded)"); ax.set_xlabel("CAD")
save(fig, "order_value_distribution")

print(f"\nFigures saved to {FIG.relative_to(ROOT)}/")
