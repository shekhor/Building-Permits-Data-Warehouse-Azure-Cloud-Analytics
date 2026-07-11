"""
Winnipeg Building Permits - Data Download Script
=================================================
Source: City of Winnipeg Open Data Portal
Dataset: Detailed Building Permit Data
URL: https://data.winnipeg.ca/Development-Approvals-Building-Permits-Inspections/Detailed-Building-Permit-Data/it4w-cpf4

This script downloads the full building permits dataset and saves it locally.
"""

import requests
import pandas as pd
from io import StringIO
import os

# ── Configuration ────────────────────────────────────────────────────────────
BASE_URL   = "https://data.winnipeg.ca/resource/it4w-cpf4.csv"
LIMIT      = 500000          # max rows to fetch (set high to get all records)
OUTPUT_DIR = "data"          # folder to save downloaded files
OUTPUT_CSV = os.path.join(OUTPUT_DIR, "building_permits.csv")


def download_data(url: str, limit: int) -> pd.DataFrame:
    """Download dataset from Winnipeg Open Data portal."""
    print(f"Downloading data from:\n  {url}\n")
    
    params = {"$limit": limit}
    response = requests.get(url, params=params, timeout=120)
    response.raise_for_status()
    
    df = pd.read_csv(StringIO(response.text))
    print(f"✅ Download complete — {len(df):,} rows, {len(df.columns)} columns\n")
    return df


def explore_data(df: pd.DataFrame) -> None:
    """Print a quick overview of the dataset."""
    print("=" * 60)
    print("DATASET OVERVIEW")
    print("=" * 60)

    print(f"\n📐 Shape: {df.shape[0]:,} rows × {df.shape[1]} columns")

    print("\n📋 Columns & Data Types:")
    print("-" * 40)
    for col, dtype in df.dtypes.items():
        null_count = df[col].isnull().sum()
        null_pct   = null_count / len(df) * 100
        print(f"  {col:<40} {str(dtype):<12} nulls: {null_count:,} ({null_pct:.1f}%)")

    print("\n🔍 Sample Data (first 3 rows):")
    print("-" * 40)
    print(df.head(3).to_string())

    print("\n📊 Numeric Column Summary:")
    print("-" * 40)
    numeric_cols = df.select_dtypes(include="number")
    if not numeric_cols.empty:
        print(numeric_cols.describe().to_string())
    else:
        print("  No numeric columns detected.")

    print("\n📅 Potential Date Columns:")
    print("-" * 40)
    date_keywords = ["date", "issued", "year", "month", "time"]
    date_cols = [c for c in df.columns if any(k in c.lower() for k in date_keywords)]
    for col in date_cols:
        print(f"  {col}: sample → {df[col].dropna().iloc[0] if not df[col].dropna().empty else 'N/A'}")

    print("\n🏙️  Unique Value Counts (categorical columns):")
    print("-" * 40)
    cat_cols = df.select_dtypes(include="object").columns
    for col in cat_cols:
        n = df[col].nunique()
        if n <= 50:  # only show manageable categories
            print(f"  {col} ({n} unique): {df[col].dropna().unique()[:10].tolist()}")
        else:
            print(f"  {col}: {n:,} unique values (too many to list)")


def save_data(df: pd.DataFrame, path: str) -> None:
    """Save DataFrame to CSV."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    df.to_csv(path, index=False)
    size_kb = os.path.getsize(path) / 1024
    print(f"\n💾 Saved to: {path}  ({size_kb:,.1f} KB)")


# ── Main ─────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    # 1. Download
    df = download_data(BASE_URL, LIMIT)

    # 2. Explore
    explore_data(df)

    # 3. Save locally
    save_data(df, OUTPUT_CSV)

    print("\n✅ Done! Next step: run schema_design.py to load into Azure SQL.")