/*
=============================================================
Building Permits Data Warehouse - SQL Analysis Scripts
=============================================================
Project:  Building Permits Data Warehouse
Database:  BuildingPermitsDW
*/

USE BuildingPermitsDW;
GO

-- SECTION 1: VIEWS

-- -------------------------------------------------------------
-- View 1: Yearly Permit Trends
-- Purpose: Shows permit volume and dwelling unit trends by year
-- -------------------------------------------------------------
IF OBJECT_ID('vw_YearlyPermitTrends', 'V') IS NOT NULL
    DROP VIEW vw_YearlyPermitTrends;
GO

CREATE VIEW vw_YearlyPermitTrends AS
SELECT
    d.Year,
    d.Quarter,
    COUNT(f.PermitKey)              AS TotalPermits,
    SUM(f.DwellingUnitsCreated)     AS TotalDwellingUnitsCreated,
    SUM(f.DwellingUnitsLost)        AS TotalDwellingUnitsLost,
    SUM(f.DwellingUnitsCreated) 
        - SUM(f.DwellingUnitsLost)  AS NetDwellingUnits,
    AVG(f.ProcessingDays)           AS AvgProcessingDays,
    COUNT(CASE WHEN f.MajorProject = 1 
               THEN 1 END)          AS MajorProjectCount
FROM
    Fact_Permits f
    JOIN Dim_Date d ON f.IssueDateKey = d.DateKey
GROUP BY
    d.Year,
    d.Quarter;
GO

-- -------------------------------------------------------------
-- View 2: Neighbourhood Activity Summary
-- Purpose: Aggregates permit activity by neighbourhood
-- -------------------------------------------------------------
IF OBJECT_ID('vw_NeighbourhoodSummary', 'V') IS NOT NULL
    DROP VIEW vw_NeighbourhoodSummary;
GO

CREATE VIEW vw_NeighbourhoodSummary AS
SELECT
    n.NeighbourhoodName,
    n.Community,
    COUNT(f.PermitKey)              AS TotalPermits,
    SUM(f.DwellingUnitsCreated)     AS TotalDwellingUnitsCreated,
    AVG(f.ProcessingDays)           AS AvgProcessingDays,
    COUNT(CASE WHEN f.MajorProject = 1 
               THEN 1 END)          AS MajorProjects,
    COUNT(CASE WHEN f.Status = 'Closed' 
               THEN 1 END)          AS ClosedPermits,
    COUNT(CASE WHEN f.Status = 'Issued' 
               THEN 1 END)          AS IssuedPermits,
    ROUND(
        COUNT(CASE WHEN f.Status = 'Closed' THEN 1 END) * 100.0 
        / NULLIF(COUNT(f.PermitKey), 0), 2
    )                               AS ClosureRate
FROM
    Fact_Permits f
    JOIN Dim_Neighbourhood n ON f.NeighbourhoodKey = n.NeighbourhoodKey
GROUP BY
    n.NeighbourhoodName,
    n.Community;
GO

-- -------------------------------------------------------------
-- View 3: Seasonal Patterns
-- Purpose: Identifies seasonal trends in permit applications
-- -------------------------------------------------------------
IF OBJECT_ID('vw_SeasonalPatterns', 'V') IS NOT NULL
    DROP VIEW vw_SeasonalPatterns;
GO

CREATE VIEW vw_SeasonalPatterns AS
SELECT
    d.Month,
    d.MonthName,
    d.Quarter,
    COUNT(f.PermitKey)              AS TotalPermits,
    AVG(COUNT(f.PermitKey)) OVER (
        PARTITION BY d.Month
    )                               AS AvgPermitsPerMonth,
    SUM(f.DwellingUnitsCreated)     AS TotalDwellingUnits,
    AVG(f.ProcessingDays)           AS AvgProcessingDays,
    CASE
        WHEN d.Month IN (6, 7, 8)   THEN 'Summer'
        WHEN d.Month IN (9, 10, 11) THEN 'Fall'
        WHEN d.Month IN (12, 1, 2)  THEN 'Winter'
        ELSE 'Spring'
    END                             AS Season
FROM
    Fact_Permits f
    JOIN Dim_Date d ON f.IssueDateKey = d.DateKey
GROUP BY
    d.Month,
    d.MonthName,
    d.Quarter;
GO

-- -------------------------------------------------------------
-- View 4: Processing Time Analysis
-- Purpose: Analyzes permit processing efficiency over time
-- -------------------------------------------------------------
IF OBJECT_ID('vw_ProcessingTimeAnalysis', 'V') IS NOT NULL
    DROP VIEW vw_ProcessingTimeAnalysis;
GO

CREATE VIEW vw_ProcessingTimeAnalysis AS
SELECT
    pt.PermitGroup,
    pt.PermitType,
    pt.WorkType,
    f.Status,
    d.Year,
    COUNT(f.PermitKey)              AS TotalPermits,
    AVG(f.ProcessingDays)           AS AvgProcessingDays,
    MIN(f.ProcessingDays)           AS MinProcessingDays,
    MAX(f.ProcessingDays)           AS MaxProcessingDays,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY f.ProcessingDays
    ) OVER (
        PARTITION BY pt.PermitType, d.Year
    )                               AS MedianProcessingDays
FROM
    Fact_Permits f
    JOIN Dim_PermitType pt  ON f.PermitTypeKey  = pt.PermitTypeKey
    JOIN Dim_Date d         ON f.IssueDateKey   = d.DateKey
WHERE
    f.ProcessingDays > 0
GROUP BY
    pt.PermitGroup,
    pt.PermitType,
    pt.WorkType,
    f.Status,
    d.Year,
    f.ProcessingDays;
GO

-- -------------------------------------------------------------
-- View 5: Permit Type Summary
-- Purpose: Summarizes permit activity by type and group
-- -------------------------------------------------------------
IF OBJECT_ID('vw_PermitTypeSummary', 'V') IS NOT NULL
    DROP VIEW vw_PermitTypeSummary;
GO

CREATE VIEW vw_PermitTypeSummary AS
SELECT
    pt.PermitGroup,
    pt.PermitType,
    pt.SubType,
    pt.WorkType,
    COUNT(f.PermitKey)              AS TotalPermits,
    SUM(f.DwellingUnitsCreated)     AS TotalDwellingUnits,
    AVG(f.ProcessingDays)           AS AvgProcessingDays,
    COUNT(CASE WHEN f.MajorProject = 1 
               THEN 1 END)          AS MajorProjects,
    ROUND(
        COUNT(f.PermitKey) * 100.0 
        / SUM(COUNT(f.PermitKey)) OVER (), 2
    )                               AS PercentageOfTotal
FROM
    Fact_Permits f
    JOIN Dim_PermitType pt ON f.PermitTypeKey = pt.PermitTypeKey
GROUP BY
    pt.PermitGroup,
    pt.PermitType,
    pt.SubType,
    pt.WorkType;
GO



-- SECTION 2: STORED PROCEDURES

-- -------------------------------------------------------------
-- Stored Procedure 1: Top Neighbourhoods By Year
-- Purpose: Returns top N neighbourhoods by permit count
--          for a given year range — used for geographic analysis
-- -------------------------------------------------------------
IF OBJECT_ID('sp_TopNeighbourhoodsByYear', 'P') IS NOT NULL
    DROP PROCEDURE sp_TopNeighbourhoodsByYear;
GO

CREATE PROCEDURE sp_TopNeighbourhoodsByYear
    @StartYear  INT = 2015,
    @EndYear    INT = 2025,
    @TopN       INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@TopN)
        n.NeighbourhoodName,
        n.Community,
        d.Year,
        COUNT(f.PermitKey)          AS TotalPermits,
        SUM(f.DwellingUnitsCreated) AS DwellingUnitsCreated,
        AVG(f.ProcessingDays)       AS AvgProcessingDays,
        COUNT(CASE WHEN f.MajorProject = 1 
                   THEN 1 END)      AS MajorProjects
    FROM
        Fact_Permits f
        JOIN Dim_Neighbourhood n ON f.NeighbourhoodKey = n.NeighbourhoodKey
        JOIN Dim_Date d          ON f.IssueDateKey     = d.DateKey
    WHERE
        d.Year BETWEEN @StartYear AND @EndYear
    GROUP BY
        n.NeighbourhoodName,
        n.Community,
        d.Year
    ORDER BY
        TotalPermits DESC;
END;
GO

-- -------------------------------------------------------------
-- Stored Procedure 2: Processing Time By Permit Type
-- Purpose: Analyzes processing efficiency by permit type
--          Identifies which permit types take longest to process
-- -------------------------------------------------------------
IF OBJECT_ID('sp_ProcessingTimeByPermitType', 'P') IS NOT NULL
    DROP PROCEDURE sp_ProcessingTimeByPermitType;
GO

CREATE PROCEDURE sp_ProcessingTimeByPermitType
    @StartYear  INT = 2015,
    @EndYear    INT = 2025,
    @Status     NVARCHAR(50) = 'Closed'
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pt.PermitGroup,
        pt.PermitType,
        COUNT(f.PermitKey)          AS TotalPermits,
        AVG(f.ProcessingDays)       AS AvgProcessingDays,
        MIN(f.ProcessingDays)       AS MinProcessingDays,
        MAX(f.ProcessingDays)       AS MaxProcessingDays,
        CASE
            WHEN AVG(f.ProcessingDays) > (
                SELECT AVG(ProcessingDays) 
                FROM Fact_Permits 
                WHERE ProcessingDays > 0
            )
            THEN 'Above Average'
            ELSE 'Below Average'
        END                         AS ProcessingEfficiency
    FROM
        Fact_Permits f
        JOIN Dim_PermitType pt  ON f.PermitTypeKey  = pt.PermitTypeKey
        JOIN Dim_Date d         ON f.IssueDateKey   = d.DateKey
    WHERE
        d.Year      BETWEEN @StartYear AND @EndYear
        AND f.Status        = @Status
        AND f.ProcessingDays > 0
    GROUP BY
        pt.PermitGroup,
        pt.PermitType
    ORDER BY
        AvgProcessingDays DESC;
END;
GO

-- -------------------------------------------------------------
-- Stored Procedure 3: Year Over Year Growth
-- Purpose: Calculates YoY permit growth by neighbourhood
--          Key business metric for construction trend analysis
-- -------------------------------------------------------------
IF OBJECT_ID('sp_YearOverYearGrowth', 'P') IS NOT NULL
    DROP PROCEDURE sp_YearOverYearGrowth;
GO

CREATE PROCEDURE sp_YearOverYearGrowth
    @StartYear  INT = 2015,
    @EndYear    INT = 2025
AS
BEGIN
    SET NOCOUNT ON;

    WITH YearlyData AS (
        SELECT
            d.Year,
            n.NeighbourhoodName,
            COUNT(f.PermitKey)          AS TotalPermits,
            SUM(f.DwellingUnitsCreated) AS DwellingUnits
        FROM
            Fact_Permits f
            JOIN Dim_Date d          ON f.IssueDateKey     = d.DateKey
            JOIN Dim_Neighbourhood n ON f.NeighbourhoodKey = n.NeighbourhoodKey
        WHERE
            d.Year BETWEEN @StartYear AND @EndYear
        GROUP BY
            d.Year,
            n.NeighbourhoodName
    )
    SELECT
        curr.Year,
        curr.NeighbourhoodName,
        curr.TotalPermits                               AS CurrentYearPermits,
        prev.TotalPermits                               AS PreviousYearPermits,
        curr.TotalPermits - prev.TotalPermits           AS PermitGrowth,
        ROUND(
            (curr.TotalPermits - prev.TotalPermits) * 100.0
            / NULLIF(prev.TotalPermits, 0), 2
        )                                               AS GrowthPercentage,
        curr.DwellingUnits                              AS CurrentYearDwellings,
        CASE
            WHEN curr.TotalPermits > prev.TotalPermits  THEN 'Growing'
            WHEN curr.TotalPermits < prev.TotalPermits  THEN 'Declining'
            ELSE 'Stable'
        END                                             AS GrowthStatus
    FROM
        YearlyData curr
        LEFT JOIN YearlyData prev
            ON curr.NeighbourhoodName = prev.NeighbourhoodName
            AND curr.Year = prev.Year + 1
    WHERE
        prev.TotalPermits IS NOT NULL
    ORDER BY
        GrowthPercentage DESC;
END;
GO

-- -------------------------------------------------------------
-- Stored Procedure 4: Major Project Analysis
-- Purpose: Analyzes major construction projects by area and type
--          Provides insight into significant development activity
-- -------------------------------------------------------------
IF OBJECT_ID('sp_MajorProjectAnalysis', 'P') IS NOT NULL
    DROP PROCEDURE sp_MajorProjectAnalysis;
GO

CREATE PROCEDURE sp_MajorProjectAnalysis
    @StartYear  INT = 2015,
    @EndYear    INT = 2025
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        d.Year,
        n.NeighbourhoodName,
        n.Community,
        pt.PermitGroup,
        pt.PermitType,
        COUNT(f.PermitKey)          AS TotalMajorProjects,
        AVG(f.ProcessingDays)       AS AvgProcessingDays,
        SUM(f.DwellingUnitsCreated) AS TotalDwellingUnits
    FROM
        Fact_Permits f
        JOIN Dim_Date d          ON f.IssueDateKey     = d.DateKey
        JOIN Dim_Neighbourhood n ON f.NeighbourhoodKey = n.NeighbourhoodKey
        JOIN Dim_PermitType pt   ON f.PermitTypeKey    = pt.PermitTypeKey
    WHERE
        f.MajorProject  = 1
        AND d.Year      BETWEEN @StartYear AND @EndYear
    GROUP BY
        d.Year,
        n.NeighbourhoodName,
        n.Community,
        pt.PermitGroup,
        pt.PermitType
    ORDER BY
        d.Year DESC,
        TotalMajorProjects DESC;
END;
GO


-- SECTION 3: SQL ANALYTICAL QUERIES

-- Query 1: Seasonal Analysis — Which months have most permits?
SELECT
    d.MonthName,
    d.Month,
    CASE
        WHEN d.Month IN (6, 7, 8)   THEN 'Summer'
        WHEN d.Month IN (9, 10, 11) THEN 'Fall'
        WHEN d.Month IN (12, 1, 2)  THEN 'Winter'
        ELSE 'Spring'
    END                             AS Season,
    COUNT(f.PermitKey)              AS TotalPermits,
    AVG(f.ProcessingDays)           AS AvgProcessingDays
FROM
    Fact_Permits f
    JOIN Dim_Date d ON f.IssueDateKey = d.DateKey
GROUP BY
    d.MonthName,
    d.Month
ORDER BY
    TotalPermits DESC;


-- Query 2: Processing Time Outliers — Permits taking too long
SELECT TOP 20
    f.PermitNumber,
    pt.PermitType,
    n.NeighbourhoodName,
    f.ProcessingDays,
    f.Status,
    d.Year
FROM
    Fact_Permits f
    JOIN Dim_PermitType pt  ON f.PermitTypeKey  = pt.PermitTypeKey
    JOIN Dim_Neighbourhood n ON f.NeighbourhoodKey = n.NeighbourhoodKey
    JOIN Dim_Date d         ON f.IssueDateKey   = d.DateKey
WHERE
    f.ProcessingDays > (
        SELECT AVG(ProcessingDays) + 2 * STDEV(ProcessingDays)
        FROM Fact_Permits
        WHERE ProcessingDays > 0
    )
ORDER BY
    f.ProcessingDays DESC;


-- Query 3: Secondary Suite Analysis
SELECT
    d.Year,
    COUNT(CASE WHEN f.IncludesSecondarySuite = 1 THEN 1 END) AS HasSecondarySuite,
    COUNT(CASE WHEN f.AddingSecondarySuite = 1 THEN 1 END)   AS AddingSecondarySuite,
    COUNT(CASE WHEN f.RemovingSecondarySuite = 1 THEN 1 END) AS RemovingSecondarySuite,
    COUNT(f.PermitKey)                                        AS TotalPermits,
    ROUND(
        COUNT(CASE WHEN f.IncludesSecondarySuite = 1 THEN 1 END) * 100.0
        / NULLIF(COUNT(f.PermitKey), 0), 2
    )                                                         AS SecondarySuitePct
FROM
    Fact_Permits f
    JOIN Dim_Date d ON f.IssueDateKey = d.DateKey
GROUP BY
    d.Year
ORDER BY
    d.Year;


-- Query 4: Community Level Summary
SELECT
    n.Community,
    COUNT(f.PermitKey)              AS TotalPermits,
    SUM(f.DwellingUnitsCreated)     AS TotalDwellingUnits,
    AVG(f.ProcessingDays)           AS AvgProcessingDays,
    COUNT(DISTINCT n.NeighbourhoodName) AS NeighbourhoodsCount,
    COUNT(CASE WHEN f.MajorProject = 1 
               THEN 1 END)          AS MajorProjects
FROM
    Fact_Permits f
    JOIN Dim_Neighbourhood n ON f.NeighbourhoodKey = n.NeighbourhoodKey
GROUP BY
    n.Community
ORDER BY
    TotalPermits DESC;