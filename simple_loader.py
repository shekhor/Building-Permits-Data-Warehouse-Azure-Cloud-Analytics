"""
Simple Data Loader for Building Permits Data Warehouse
Loads data in small batches with reconnection logic to handle network timeouts
"""

import os
import pyodbc
import pandas as pd
from datetime import datetime
import time

# Set these as environment variables — never commit real credentials.
#   AZURE_SQL_SERVER, AZURE_SQL_DATABASE, AZURE_SQL_USERNAME, AZURE_SQL_PASSWORD
SQL_SERVER = os.environ.get("AZURE_SQL_SERVER", "YOUR_SERVER.database.windows.net")
SQL_DATABASE = os.environ.get("AZURE_SQL_DATABASE", "BuildingPermitsDW")
SQL_USERNAME = os.environ.get("AZURE_SQL_USERNAME", "YOUR_USERNAME")
SQL_PASSWORD = os.environ.get("AZURE_SQL_PASSWORD", "")

CONNECTION_STRING = (
    f"DRIVER={{ODBC Driver 18 for SQL Server}};"
    f"SERVER={SQL_SERVER},1433;"
    f"DATABASE={SQL_DATABASE};"
    f"UID={SQL_USERNAME};"
    f"PWD={SQL_PASSWORD};"
    f"Encrypt=yes;"
    f"TrustServerCertificate=no;"
    f"Connection Timeout=30;"
)

def get_connection(max_retries=3):
    """Get database connection with retry logic"""
    if not SQL_PASSWORD:
        raise ValueError(
            "AZURE_SQL_PASSWORD is not set. "
            "Set Azure SQL credentials as environment variables before running."
        )
    for attempt in range(max_retries):
        try:
            conn = pyodbc.connect(CONNECTION_STRING)
            return conn
        except Exception as e:
            print(f"Connection attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(2 ** attempt)  # Exponential backoff
            else:
                raise

def load_table_data(table_name, df, sql_template, batch_size=50):
    """Load DataFrame to table with robust error handling"""
    total_rows = len(df)
    inserted = 0

    print(f"Loading {total_rows:,} rows into {table_name}...")

    while inserted < total_rows:
        try:
            conn = get_connection()
            cursor = conn.cursor()

            # Get remaining rows
            remaining_df = df.iloc[inserted:]
            batch_df = remaining_df.head(batch_size)
            rows = [tuple(row) for row in batch_df.itertuples(index=False, name=None)]

            cursor.executemany(sql_template, rows)
            conn.commit()

            inserted += len(rows)
            print(f"  → {inserted:,}/{total_rows:,} rows loaded")

            cursor.close()
            conn.close()

        except Exception as e:
            print(f"Error loading batch at row {inserted}: {e}")
            batch_size = max(10, batch_size // 2)  # Reduce batch size on error
            print(f"Reducing batch size to {batch_size}")
            time.sleep(5)  # Wait before retrying

    print(f"✅ Completed loading {table_name}")

def main():
    print("🚀 Starting data load...")

    # Create sample Dim_Date data
    date_range = pd.date_range(start='1998-01-01', end='2026-12-31', freq='D')
    dim_date = pd.DataFrame({
        'date_key':   date_range.strftime('%Y%m%d').astype(int),
        'full_date':  date_range.date,
        'year':       date_range.year,
        'quarter':    date_range.quarter,
        'month':      date_range.month,
        'month_name': date_range.strftime('%B'),
        'day':        date_range.day,
        'day_name':   date_range.strftime('%A'),
        'is_weekend': (date_range.dayofweek >= 5).astype(int),
    })

    # Clear and load Dim_Date
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute('DELETE FROM Dim_Date')
    conn.commit()
    cursor.close()
    conn.close()

    load_table_data(
        'Dim_Date',
        dim_date,
        'INSERT INTO Dim_Date (DateKey, FullDate, Year, Quarter, Month, MonthName, Day, DayName, IsWeekend) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
    )

    # Verify
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute('SELECT COUNT(*) FROM Dim_Date')
    count = cursor.fetchone()[0]
    print(f"\n✅ Dim_Date verification: {count:,} rows loaded")
    cursor.close()
    conn.close()

if __name__ == "__main__":
    main()