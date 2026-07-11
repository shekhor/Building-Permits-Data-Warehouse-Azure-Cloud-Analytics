"""
Building Permits Data Warehouse - ETL Pipeline
==================================================
Project:  Building Permits Data Warehouse

Description:
    This script extracts building permits data from a local CSV file
    (originally downloaded from Azure Data Lake Storage Gen2),
    transforms it into a star schema, and loads it into Azure SQL Database.


Source:
    City of Winnipeg Open Data Portal
    https://data.winnipeg.ca/Development-Approvals-Building-Permits-Inspections/
    Detailed-Building-Permit-Data/it4w-cpf4
"""

import os
import pandas as pd
import numpy as np
from datetime import datetime
import pyodbc

# It should be path from Azure Data Lake Gen2, but for Python compatibility, we are using local CSV copy.
CSV_FILE_PATH = os.path.join("data", "building_permits.csv")

# Set these as environment variables — never commit real credentials.
#   AZURE_SQL_SERVER, AZURE_SQL_DATABASE, AZURE_SQL_USERNAME, AZURE_SQL_PASSWORD
SQL_SERVER = os.environ.get("AZURE_SQL_SERVER", "YOUR_SERVER.database.windows.net")
SQL_DATABASE = os.environ.get("AZURE_SQL_DATABASE", "BuildingPermitsDW")
SQL_USERNAME = os.environ.get("AZURE_SQL_USERNAME", "YOUR_USERNAME")
SQL_PASSWORD = os.environ.get("AZURE_SQL_PASSWORD", "")

CONNECTION_STRING = (
    f"DRIVER={{ODBC Driver 18 for SQL Server}};"
    f"SERVER={SQL_SERVER};"
    f"DATABASE={SQL_DATABASE};"
    f"UID={SQL_USERNAME};"
    f"PWD={SQL_PASSWORD};"
    f"Encrypt=yes;"
    f"TrustServerCertificate=no;"
    f"Connection Timeout=60;"
)



def extract_from_csv() -> pd.DataFrame:
    print("\n" + "="*60)
    print("STEP 1: EXTRACTING DATA FROM LOCAL CSV")
    print("="*60)

    df = pd.read_csv(CSV_FILE_PATH)

    # Standardize column names immediately
    df.columns = df.columns.str.strip().str.lower().str.replace(" ", "_")

    print(f"Extracted {len(df):,} rows and {len(df.columns)} columns")
    print(f"   Columns: {df.columns.tolist()}")
    return df


def transform_data(df: pd.DataFrame) -> dict:
    print("\n" + "="*60)
    print("STEP 2: TRANSFORMING DATA INTO STAR SCHEMA")
    print("="*60)

    # -- Clean dates -----------------------------------------------------------
    for col in ["issue_date", "application_received_date", "final_date"]:
        if col in df.columns:
            df[col] = pd.to_datetime(df[col], errors="coerce")

    # -- Clean strings ---------------------------------------------------------
    str_cols = df.select_dtypes(include="object").columns
    df[str_cols] = df[str_cols].apply(lambda x: x.str.strip())

    # -- Fill nulls ------------------------------------------------------------
    str_fill = {
        "applicant_business_name":       "Unknown",
        "neighbourhood_name":            "Unknown",
        "community":                     "Unknown",
        "permit_group":                  "Unknown",
        "permit_type":                   "Unknown",
        "sub_type":                      "Unknown",
        "work_type":                     "Unknown",
        "status":                        "Unknown",
        "ward":                          "Unknown",
        "type_of_structure":             "Unknown",
        "pool_type":                     "None",
        "economic_development_category": "Unknown",
        "street_number":                 "Unknown",
        "street_name":                   "Unknown",
        "street_type":                   "Unknown",
        "street_direction":              "Unknown",
        "unit_type":                     "Unknown",
        "unit_number":                   "Unknown",
    }
    for col, val in str_fill.items():
        if col in df.columns:
            df[col] = df[col].fillna(val)

    # -- Boolean columns -------------------------------------------------------
    for col in ["includes_secondary_suite", "adding_secondary_suite",
                "removing_secondary_suite", "major_project"]:
        if col in df.columns:
            df[col] = df[col].map(
                {"Yes": 1, "No": 0, "TRUE": 1, "FALSE": 0,
                 True: 1, False: 0, 1: 1, 0: 0}
            ).fillna(0).astype(int)

    # -- Processing days -------------------------------------------------------
    if "final_date" in df.columns and "application_received_date" in df.columns:
        df["processing_days"] = (
            df["final_date"] - df["application_received_date"]
        ).dt.days.clip(lower=0).fillna(0).astype(int)
    else:
        df["processing_days"] = 0

    # -- Numeric columns -------------------------------------------------------
    for col in ["dwelling_units_created", "dwelling_units_lost",
                "neighbourhood_number"]:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0)

    print("Cleaning complete")

    # ── Dim_Date ──────────────────────────────────────────────────────────────
    all_dates = pd.concat([
        df["issue_date"].dropna(),
        df["application_received_date"].dropna(),
        df["final_date"].dropna()
    ])
    date_range = pd.date_range(start=all_dates.min(), end=all_dates.max(), freq="D")

    dim_date = pd.DataFrame({
        "DateKey":   date_range.strftime("%Y%m%d").astype(int),
        "FullDate":  date_range.date,
        "Year":      date_range.year,
        "Quarter":   date_range.quarter,
        "Month":     date_range.month,
        "MonthName": date_range.strftime("%B"),
        "Day":       date_range.day,
        "DayName":   date_range.strftime("%A"),
        "IsWeekend": (date_range.dayofweek >= 5).astype(int),
    })
    print(f"Dim_Date:          {len(dim_date):,} rows")

    # ── Dim_Neighbourhood ─────────────────────────────────────────────────────
    dim_neighbourhood = (
        df[["neighbourhood_number", "neighbourhood_name", "community"]]
        .drop_duplicates()
        .reset_index(drop=True)
    )
    dim_neighbourhood.insert(0, "NeighbourhoodKey",
                             range(1, len(dim_neighbourhood) + 1))
    dim_neighbourhood.columns = ["NeighbourhoodKey", "NeighbourhoodNumber",
                                  "NeighbourhoodName", "Community"]
    print(f"Dim_Neighbourhood: {len(dim_neighbourhood):,} rows")

    # ── Dim_PermitType ────────────────────────────────────────────────────────
    dim_permit_type = (
        df[["permit_group", "permit_type", "sub_type", "work_type"]]
        .drop_duplicates()
        .reset_index(drop=True)
    )
    dim_permit_type.insert(0, "PermitTypeKey",
                           range(1, len(dim_permit_type) + 1))
    dim_permit_type.columns = ["PermitTypeKey", "PermitGroup", "PermitType",
                                "SubType", "WorkType"]
    print(f"Dim_PermitType:    {len(dim_permit_type):,} rows")

    # ── Dim_Applicant ─────────────────────────────────────────────────────────
    dim_applicant = (
        df[["applicant_business_name"]]
        .drop_duplicates()
        .reset_index(drop=True)
    )
    dim_applicant.insert(0, "ApplicantKey", range(1, len(dim_applicant) + 1))
    dim_applicant.columns = ["ApplicantKey", "ApplicantBusinessName"]
    print(f"Dim_Applicant:     {len(dim_applicant):,} rows")

    # ── Dim_Location ──────────────────────────────────────────────────────────
    location_cols = ["street_number", "street_name", "street_type",
                     "street_direction", "unit_type", "unit_number",
                     "ward", "x_coordinate_nad83", "y_coordinate_nad83"]
    avail_loc = [c for c in location_cols if c in df.columns]

    dim_location = (
        df[avail_loc]
        .drop_duplicates()
        .reset_index(drop=True)
    )
    dim_location.insert(0, "LocationKey", range(1, len(dim_location) + 1))

    # Replace NaN in coordinate columns with None (SQL NULL)
    if "x_coordinate_nad83" in dim_location.columns:
        dim_location["x_coordinate_nad83"] = dim_location["x_coordinate_nad83"].where(
            pd.notnull(dim_location["x_coordinate_nad83"]), None)
    if "y_coordinate_nad83" in dim_location.columns:
        dim_location["y_coordinate_nad83"] = dim_location["y_coordinate_nad83"].where(
            pd.notnull(dim_location["y_coordinate_nad83"]), None)

    loc_rename = {
        "street_number":      "StreetNumber",
        "street_name":        "StreetName",
        "street_type":        "StreetType",
        "street_direction":   "StreetDirection",
        "unit_type":          "UnitType",
        "unit_number":        "UnitNumber",
        "ward":               "Ward",
        "x_coordinate_nad83": "XCoordinateNAD83",
        "y_coordinate_nad83": "YCoordinateNAD83",
    }
    dim_location.rename(columns=loc_rename, inplace=True)
    print(f"Dim_Location:      {len(dim_location):,} rows")

    # ── Fact_Permits ──────────────────────────────────────────────────────────
    def to_date_key(d):
        return None if pd.isnull(d) else int(d.strftime("%Y%m%d"))

    fact = df.copy()

    # Merge neighbourhood key
    neigh_lookup = dim_neighbourhood.rename(columns={
        "NeighbourhoodName": "neighbourhood_name",
        "Community":         "community",
    })[["NeighbourhoodKey", "neighbourhood_name", "community"]]
    fact = fact.merge(neigh_lookup, on=["neighbourhood_name", "community"],
                      how="left")

    # Merge permit type key
    ptype_lookup = dim_permit_type.rename(columns={
        "PermitGroup": "permit_group",
        "PermitType":  "permit_type",
        "SubType":     "sub_type",
        "WorkType":    "work_type",
    })[["PermitTypeKey", "permit_group", "permit_type", "sub_type", "work_type"]]
    fact = fact.merge(ptype_lookup,
                      on=["permit_group", "permit_type", "sub_type", "work_type"],
                      how="left")

    # Merge applicant key
    app_lookup = dim_applicant.rename(columns={
        "ApplicantBusinessName": "applicant_business_name"
    })[["ApplicantKey", "applicant_business_name"]]
    fact = fact.merge(app_lookup, on="applicant_business_name", how="left")

    # Merge location key
    loc_lookup = dim_location.rename(columns={v: k for k, v in loc_rename.items()})
    fact = fact.merge(loc_lookup[["LocationKey"] + avail_loc],
                      on=avail_loc, how="left")

    # Build fact dataframe
    fact_permits = pd.DataFrame({
        "PermitNumber":                fact["permit_number"],
        "ParentPermitNumber":          fact.get("parent_permit_number",
                                                pd.Series([None]*len(fact))),
        "IssueDateKey":                fact["issue_date"].apply(to_date_key),
        "ApplicationDateKey":          fact["application_received_date"].apply(to_date_key),
        "FinalDateKey":                fact["final_date"].apply(to_date_key),
        "NeighbourhoodKey":            fact["NeighbourhoodKey"],
        "PermitTypeKey":               fact["PermitTypeKey"],
        "ApplicantKey":                fact["ApplicantKey"],
        "LocationKey":                 fact["LocationKey"],
        "Status":                      fact["status"],
        "DwellingUnitsCreated":        pd.to_numeric(fact.get("dwelling_units_created"), errors="coerce").fillna(0).astype(int),
        "DwellingUnitsLost":           pd.to_numeric(fact.get("dwelling_units_lost"), errors="coerce").fillna(0).astype(int),
        "ProcessingDays":              fact["processing_days"],
        "MajorProject":                fact.get("major_project", pd.Series([0]*len(fact))),
        "IncludesSecondarySuite":      fact.get("includes_secondary_suite", pd.Series([0]*len(fact))),
        "AddingSecondarySuite":        fact.get("adding_secondary_suite", pd.Series([0]*len(fact))),
        "RemovingSecondarySuite":      fact.get("removing_secondary_suite", pd.Series([0]*len(fact))),
        "PoolType":                    fact.get("pool_type", pd.Series(["None"]*len(fact))),
        "TypeOfStructure":             fact.get("type_of_structure", pd.Series(["Unknown"]*len(fact))),
        "EconomicDevelopmentCategory": fact.get("economic_development_category", pd.Series(["Unknown"]*len(fact))),
    })

    

    print(f"\nFact_Permits:      {len(fact_permits):,} rows")

    return {
        "Dim_Date":          dim_date,
        "Dim_Neighbourhood": dim_neighbourhood,
        "Dim_PermitType":    dim_permit_type,
        "Dim_Applicant":     dim_applicant,
        "Dim_Location":      dim_location,
        "Fact_Permits":      fact_permits,
    }


# ── Step 3: LOAD ──────────────────────────────────────────────────────────────
def drop_and_create_tables(cursor) -> None:
    print("\n" + "="*60)
    print("STEP 3a: RECREATING TABLES IN AZURE SQL")
    print("="*60)

    for tbl in ["Fact_Permits", "Dim_Date", "Dim_Neighbourhood",
                "Dim_PermitType", "Dim_Applicant", "Dim_Location"]:
        cursor.execute(f"IF OBJECT_ID('{tbl}', 'U') IS NOT NULL DROP TABLE {tbl}")
        print(f"   Dropped {tbl} (if existed)")

    ddl = {
        "Dim_Date": """
            CREATE TABLE Dim_Date (
                DateKey INT PRIMARY KEY, FullDate DATE NOT NULL,
                Year INT, Quarter INT, Month INT, MonthName NVARCHAR(20),
                Day INT, DayName NVARCHAR(20), IsWeekend BIT
            )""",
        "Dim_Neighbourhood": """
            CREATE TABLE Dim_Neighbourhood (
                NeighbourhoodKey INT PRIMARY KEY,
                NeighbourhoodNumber NVARCHAR(50),
                NeighbourhoodName NVARCHAR(100),
                Community NVARCHAR(100)
            )""",
        "Dim_PermitType": """
            CREATE TABLE Dim_PermitType (
                PermitTypeKey INT PRIMARY KEY,
                PermitGroup NVARCHAR(100), PermitType NVARCHAR(100),
                SubType NVARCHAR(100), WorkType NVARCHAR(100)
            )""",
        "Dim_Applicant": """
            CREATE TABLE Dim_Applicant (
                ApplicantKey INT PRIMARY KEY,
                ApplicantBusinessName NVARCHAR(255)
            )""",
        "Dim_Location": """
            CREATE TABLE Dim_Location (
                LocationKey INT PRIMARY KEY,
                StreetNumber NVARCHAR(20),  StreetName NVARCHAR(100),
                StreetType NVARCHAR(50),    StreetDirection NVARCHAR(10),
                UnitType NVARCHAR(50),      UnitNumber NVARCHAR(20),
                Ward NVARCHAR(50),
                XCoordinateNAD83 FLOAT NULL, YCoordinateNAD83 FLOAT NULL
            )""",
        "Fact_Permits": """
            CREATE TABLE Fact_Permits (
                PermitKey                    INT IDENTITY(1,1) PRIMARY KEY,
                PermitNumber                 NVARCHAR(50),
                ParentPermitNumber           NVARCHAR(50),
                IssueDateKey                 INT REFERENCES Dim_Date(DateKey),
                ApplicationDateKey           INT REFERENCES Dim_Date(DateKey),
                FinalDateKey                 INT REFERENCES Dim_Date(DateKey),
                NeighbourhoodKey             INT REFERENCES Dim_Neighbourhood(NeighbourhoodKey),
                PermitTypeKey                INT REFERENCES Dim_PermitType(PermitTypeKey),
                ApplicantKey                 INT REFERENCES Dim_Applicant(ApplicantKey),
                LocationKey                  INT REFERENCES Dim_Location(LocationKey),
                Status                       NVARCHAR(50),
                DwellingUnitsCreated         INT,
                DwellingUnitsLost            INT,
                ProcessingDays               INT,
                MajorProject                 BIT,
                IncludesSecondarySuite       BIT,
                AddingSecondarySuite         BIT,
                RemovingSecondarySuite       BIT,
                PoolType                     NVARCHAR(50),
                TypeOfStructure              NVARCHAR(100),
                EconomicDevelopmentCategory  NVARCHAR(100)
            )""",
    }

    for name, stmt in ddl.items():
        cursor.execute(stmt)
        print(f"   Created {name}")

    print("All tables created")


def clean_row(row: tuple) -> tuple:
    """Convert any float nan or numpy nan to None for SQL NULL."""
    import math
    result = []
    for val in row:
        if val is None:
            result.append(None)
        elif isinstance(val, float) and math.isnan(val):
            result.append(None)
        else:
            result.append(val)
    return tuple(result)


def get_row_count(conn, table_name: str) -> int:
    """Get current row count of a table in Azure SQL."""
    cursor = conn.cursor()
    cursor.execute(f"SELECT COUNT(*) FROM {table_name}")
    count = cursor.fetchone()[0]
    cursor.close()
    return count


def load_table(conn, df: pd.DataFrame, table_name: str,
               batch_size: int = 500) -> None:
    # ── Skip if already loaded ────────────────────────────────────────────────
    existing_count = get_row_count(conn, table_name)
    if existing_count > 0:
        print(f"Skipping {table_name} — already has {existing_count:,} rows")
        return

    cursor = conn.cursor()
    cols   = list(df.columns)

    placeholders = ", ".join(["?" for _ in cols])
    col_str      = ", ".join(cols)
    sql          = f"INSERT INTO {table_name} ({col_str}) VALUES ({placeholders})"

    # Convert all rows — replace every form of nan with None
    rows   = [clean_row(r) for r in df.itertuples(index=False, name=None)]
    total  = len(rows)
    loaded = 0

    for i in range(0, total, batch_size):
        batch = rows[i: i + batch_size]
        try:
            cursor.executemany(sql, batch)
            conn.commit()
            loaded += len(batch)
            if loaded % 10000 == 0 or loaded == total:
                pct = loaded / total * 100
                print(f"   {table_name}: {loaded:,}/{total:,} rows ({pct:.0f}%)")
        except Exception as e:
            conn.rollback()
            print(f"Error on batch {i//batch_size + 1} of {table_name}: {e}")
            print(f"   Sample row: {batch[0]}")
            raise

    cursor.close()
    print(f"{table_name}: {loaded:,} rows loaded\n")


def verify_counts(conn) -> None:
    cursor = conn.cursor()
    print("\n Final Row Counts in Azure SQL:")
    print("-" * 40)
    for tbl in ["Dim_Date", "Dim_Neighbourhood", "Dim_PermitType",
                "Dim_Applicant", "Dim_Location", "Fact_Permits"]:
        cursor.execute(f"SELECT COUNT(*) FROM {tbl}")
        count  = cursor.fetchone()[0]
        status = "OK" if count > 0 else "EMPTY"
        print(f"   {status}  {tbl:<25} {count:>10,} rows")
    cursor.close()


def load_all(tables: dict) -> None:
    print("\n" + "="*60)
    print("STEP 3b: LOADING ALL TABLES INTO AZURE SQL")
    print("="*60)

    conn   = pyodbc.connect(CONNECTION_STRING)
    cursor = conn.cursor()

    drop_and_create_tables(cursor)
    conn.commit()
    cursor.close()

    for tbl in ["Dim_Date", "Dim_Neighbourhood", "Dim_PermitType",
                "Dim_Applicant", "Dim_Location", "Fact_Permits"]:
        print(f"\n→ Loading {tbl}...")
        load_table(conn, tables[tbl], tbl, batch_size=500)

    verify_counts(conn)
    conn.close()


# ── Main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if not SQL_PASSWORD:
        raise SystemExit(
            "AZURE_SQL_PASSWORD is not set. "
            "Set Azure SQL credentials as environment variables before running."
        )

    start = datetime.now()
    print(f"\n ETL Pipeline Started: {start.strftime('%Y-%m-%d %H:%M:%S')}")

    raw_df = extract_from_csv()
    tables = transform_data(raw_df)
    load_all(tables)

    end      = datetime.now()
    duration = (end - start).seconds
    print(f"\n ETL Complete: {end.strftime('%Y-%m-%d %H:%M:%S')}  ({duration}s)")
    print("Next Step: Connect Power BI to your Azure SQL Database!")