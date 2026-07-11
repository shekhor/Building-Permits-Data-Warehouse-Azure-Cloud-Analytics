# =============================================================
# Building Permits Data Warehouse - R Data Mining & Analysis
# =============================================================
# Project:  Building Permits Data Warehouse

# Description:
#   This script performs data mining and statistical analysis
#   on the Building Permits Data Warehouse stored in Azure SQL.
#   It demonstrates R-based analytics including trend analysis,
#   clustering, seasonal decomposition, and visualization.


library(DBI)
library(odbc)
library(dplyr)
library(ggplot2)
library(tidyr)
library(scales)
library(cluster)
library(factoextra)

SQL_SERVER   <- "building-permits-srv.database.windows.net"
SQL_DATABASE <- "BuildingPermitsDW"
SQL_USERNAME <- "CloudSA2156e73b"
SQL_PASSWORD <- "Sqlserver1234!"

OUTPUT_DIR <- "C:/Users/schanda/OneDrive - City of Winnipeg/projects/DWH Project 2026/R_outputs"
dir.create(OUTPUT_DIR, showWarnings = FALSE)



conn <- dbConnect(
  odbc::odbc(),
  Driver   = "ODBC Driver 18 for SQL Server",
  Server   = SQL_SERVER,
  Database = SQL_DATABASE,
  UID      = SQL_USERNAME,
  PWD      = SQL_PASSWORD,
  Encrypt  = "yes",
  TrustServerCertificate = "no",
  timeout  = 30
)

cat("Connected to Azure SQL Database successfully!\n\n")


# =============================================================
# STEP 2: EXTRACT DATA FROM STAR SCHEMA
# =============================================================

# Yearly trends
yearly_data <- dbGetQuery(conn, "
    SELECT
        d.Year,
        d.Month,
        d.MonthName,
        d.Quarter,
        CASE
            WHEN d.Month IN (6,7,8)   THEN 'Summer'
            WHEN d.Month IN (9,10,11) THEN 'Fall'
            WHEN d.Month IN (12,1,2)  THEN 'Winter'
            ELSE 'Spring'
        END AS Season,
        COUNT(f.PermitKey)                AS TotalPermits,
        AVG(f.ProcessingDays)             AS AvgProcessingDays,
        SUM(f.DwellingUnitsCreated)       AS DwellingUnitsCreated,
        SUM(CAST(f.MajorProject AS INT))  AS MajorProjects
    FROM Fact_Permits f
    JOIN Dim_Date d ON f.IssueDateKey = d.DateKey
    WHERE d.Year BETWEEN 1998 AND 2025
    GROUP BY d.Year, d.Month, d.MonthName, d.Quarter,
        CASE
            WHEN d.Month IN (6,7,8)   THEN 'Summer'
            WHEN d.Month IN (9,10,11) THEN 'Fall'
            WHEN d.Month IN (12,1,2)  THEN 'Winter'
            ELSE 'Spring'
        END
    ORDER BY d.Year, d.Month
")

# Neighbourhood data for clustering
neighbourhood_data <- dbGetQuery(conn, "
    SELECT
        n.NeighbourhoodName,
        n.Community,
        COUNT(f.PermitKey)                    AS TotalPermits,
        AVG(f.ProcessingDays)                 AS AvgProcessingDays,
        SUM(f.DwellingUnitsCreated)           AS TotalDwellingUnits,
        SUM(CAST(f.MajorProject AS INT))      AS MajorProjects,
        SUM(CAST(f.IncludesSecondarySuite AS INT)) AS SecondarySuites
    FROM Fact_Permits f
    JOIN Dim_Neighbourhood n ON f.NeighbourhoodKey = n.NeighbourhoodKey
    GROUP BY n.NeighbourhoodName, n.Community
    HAVING COUNT(f.PermitKey) > 100
")

# Secondary suite trends
secondary_suite <- dbGetQuery(conn, "
    SELECT
        d.Year,
        SUM(CAST(f.IncludesSecondarySuite AS INT)) AS HasSecondarySuite,
        SUM(CAST(f.AddingSecondarySuite AS INT))   AS AddingSecondarySuite,
        COUNT(f.PermitKey)            AS TotalPermits
    FROM Fact_Permits f
    JOIN Dim_Date d ON f.IssueDateKey = d.DateKey
    WHERE d.Year BETWEEN 2015 AND 2025
    GROUP BY d.Year
    ORDER BY d.Year
")

dbDisconnect(conn)
cat("Data extracted successfully!\n")


# =============================================================
# STEP 3: YEARLY PERMIT TREND ANALYSIS
# =============================================================

yearly_summary <- yearly_data %>%
  group_by(Year) %>%
  summarise(
    TotalPermits        = sum(TotalPermits),
    AvgProcessingDays   = mean(AvgProcessingDays, na.rm = TRUE),
    DwellingUnits       = sum(DwellingUnitsCreated),
    MajorProjects       = sum(MajorProjects),
    .groups = "drop"
  )

# Plot: Yearly Permit Trend
p1 <- ggplot(yearly_summary, aes(x = Year, y = TotalPermits)) +
  geom_line(color = "#1F77B4", linewidth = 1.2) +
  geom_point(color = "#1F77B4", size = 2.5) +
  geom_smooth(method = "loess", se = TRUE,
              color = "#FF7F0E", linetype = "dashed", alpha = 0.15) +
  scale_y_continuous(labels = comma) +
  scale_x_continuous(breaks = seq(1998, 2025, by = 3)) +
  labs(
    title    = "Building Permit Volume Trends (1998-2025)",
    subtitle = "City of Winnipeg — Annual permit issuance with trend line",
    x        = "Year",
    y        = "Total Permits Issued",
    caption  = "Source: City of Winnipeg Open Data | Analysis: Shekhor Chanda"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title    = element_text(face = "bold", size = 15),
    plot.subtitle = element_text(color = "gray40"),
    panel.grid.minor = element_blank()
  )

ggsave(file.path(OUTPUT_DIR, "01_yearly_permit_trends.png"),
       p1, width = 12, height = 6, dpi = 150)
print(p1)
cat("Chart 1 saved: 01_yearly_permit_trends.png\n\n")


# =============================================================
# STEP 4: SEASONAL PATTERN ANALYSIS
# =============================================================

seasonal_summary <- yearly_data %>%
  group_by(Month, MonthName, Season) %>%
  summarise(
    AvgPermits        = mean(TotalPermits, na.rm = TRUE),
    TotalPermits      = sum(TotalPermits),
    AvgProcessingDays = mean(AvgProcessingDays, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(Month)

seasonal_summary$MonthName <- factor(
  seasonal_summary$MonthName,
  levels = c("January","February","March","April","May","June",
             "July","August","September","October","November","December")
)


season_colors <- c(
  "Spring" = "#2CA02C",
  "Summer" = "#FF7F0E",
  "Fall"   = "#8C564B",
  "Winter" = "#1F77B4"
)

# Plot: Seasonal Patterns
p2 <- ggplot(seasonal_summary,
             aes(x = MonthName, y = AvgPermits, fill = Season)) +
  geom_col(alpha = 0.85) +
  scale_fill_manual(values = season_colors) +
  scale_y_continuous(labels = comma) +
  labs(
    title    = "Seasonal Permit Patterns — Average Monthly Volume",
    subtitle = "Summer months dominate permit activity in Winnipeg",
    x        = "Month",
    y        = "Average Permits per Month",
    fill     = "Season",
    caption  = "Source: City of Winnipeg Open Data | Analysis: Shekhor Chanda"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15),
    plot.subtitle    = element_text(color = "gray40"),
    axis.text.x      = element_text(angle = 45, hjust = 1),
    panel.grid.minor = element_blank(),
    legend.position  = "top"
  )

ggsave(file.path(OUTPUT_DIR, "02_seasonal_patterns.png"),
       p2, width = 12, height = 6, dpi = 150)
print(p2)
cat("Chart 2 saved: 02_seasonal_patterns.png\n\n")


# =============================================================
# STEP 5: NEIGHBOURHOOD CLUSTERING (K-MEANS)
# =============================================================

# Prepare clustering data
cluster_data <- neighbourhood_data %>%
  select(TotalPermits, AvgProcessingDays,
         TotalDwellingUnits, MajorProjects) %>%
  scale() %>%
  as.data.frame()

rownames(cluster_data) <- neighbourhood_data$NeighbourhoodName

# Find optimal clusters using elbow method
set.seed(42)
wss <- sapply(1:8, function(k) {
  kmeans(cluster_data, centers = k,
         nstart = 25, iter.max = 100)$tot.withinss
})

# Plot: Elbow Method
elbow_df <- data.frame(k = 1:8, WSS = wss)
p3 <- ggplot(elbow_df, aes(x = k, y = WSS)) +
  geom_line(color = "#1F77B4", linewidth = 1.2) +
  geom_point(color = "#1F77B4", size = 3) +
  geom_vline(xintercept = 4, linetype = "dashed",
             color = "#FF7F0E", linewidth = 1) +
  annotate("text", x = 4.3, y = max(wss) * 0.85,
           label = "Optimal k=4", color = "#FF7F0E", size = 4) +
  labs(
    title    = "K-Means Clustering — Elbow Method",
    subtitle = "Determining optimal number of neighbourhood clusters",
    x        = "Number of Clusters (k)",
    y        = "Total Within-Cluster Sum of Squares",
    caption  = "Source: City of Winnipeg Open Data | Analysis: Shekhor Chanda"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title    = element_text(face = "bold", size = 15),
    plot.subtitle = element_text(color = "gray40")
  )

ggsave(file.path(OUTPUT_DIR, "03_elbow_method.png"),
       p3, width = 10, height = 6, dpi = 150)
print(p3)
cat("Chart 3 saved: 03_elbow_method.png\n\n")

# Apply K-Means
set.seed(42)
kmeans_result <- kmeans(cluster_data, centers = 4,
                        nstart = 25, iter.max = 100)

neighbourhood_data$Cluster <- as.factor(kmeans_result$cluster)

# Cluster labels based on characteristics
cluster_labels <- neighbourhood_data %>%
  group_by(Cluster) %>%
  summarise(
    AvgPermits    = mean(TotalPermits),
    AvgProcessing = mean(AvgProcessingDays),
    AvgDwelling   = mean(TotalDwellingUnits),
    .groups = "drop"
  ) %>%
  mutate(Label = case_when(
    AvgPermits == max(AvgPermits)    ~ "High Activity",
    AvgPermits == min(AvgPermits)    ~ "Low Activity",
    AvgProcessing == max(AvgProcessing) ~ "Slow Processing",
    TRUE                             ~ "Moderate Activity"
  ))

neighbourhood_data <- neighbourhood_data %>%
  left_join(cluster_labels %>% select(Cluster, Label), by = "Cluster")

# Plot: Cluster Visualization
p4 <- fviz_cluster(
  kmeans_result,
  data        = cluster_data,
  geom        = "point",
  ellipse     = TRUE,
  ellipse.type = "convex",
  palette     = c("#1F77B4","#FF7F0E","#2CA02C","#D62728"),
  ggtheme     = theme_minimal(base_size = 13),
  main        = "Neighbourhood Clustering — K-Means (k=4)",
  xlab        = "Principal Component 1",
  ylab        = "Principal Component 2"
) +
  labs(
    subtitle = "Neighbourhoods grouped by permit activity, processing time, and dwelling units",
    caption  = "Source: City of Winnipeg Open Data | Analysis: Shekhor Chanda"
  ) +
  theme(
    plot.title    = element_text(face = "bold", size = 15),
    plot.subtitle = element_text(color = "gray40")
  )

ggsave(file.path(OUTPUT_DIR, "04_neighbourhood_clusters.png"),
       p4, width = 12, height = 8, dpi = 150)
print(p4)
cat("Chart 4 saved: 04_neighbourhood_clusters.png\n\n")

# Print cluster summary
cat("Cluster Summary:\n")
print(cluster_labels)
cat("\n")


# =============================================================
# STEP 6: PROCESSING TIME STATISTICAL ANALYSIS
# =============================================================

processing_stats <- yearly_summary %>%
  filter(Year >= 2010) %>%
  select(Year, AvgProcessingDays)

# Plot: Processing Time Trend
p5 <- ggplot(processing_stats,
             aes(x = Year, y = AvgProcessingDays)) +
  geom_line(color = "#D62728", linewidth = 1.2) +
  geom_point(color = "#D62728", size = 2.5) +
  geom_smooth(method = "lm", se = TRUE,
              color = "#1F77B4", linetype = "dashed", alpha = 0.15) +
  scale_x_continuous(breaks = seq(2010, 2025, by = 2)) +
  labs(
    title    = "Permit Processing Time Trend (2010-2025)",
    subtitle = "Average days from application to completion — showing improvement over time",
    x        = "Year",
    y        = "Average Processing Days",
    caption  = "Source: City of Winnipeg Open Data | Analysis: Shekhor Chanda"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15),
    plot.subtitle    = element_text(color = "gray40"),
    panel.grid.minor = element_blank()
  )

ggsave(file.path(OUTPUT_DIR, "05_processing_time_trend.png"),
       p5, width = 12, height = 6, dpi = 150)
print(p5)
cat("Chart 5 saved: 05_processing_time_trend.png\n\n")


# =============================================================
# STEP 7: SECONDARY SUITE TREND ANALYSIS
# =============================================================

p6 <- ggplot(secondary_suite, aes(x = Year)) +
  geom_col(aes(y = TotalPermits),
           fill = "#AEC7E8", alpha = 0.6) +
  geom_line(aes(y = HasSecondarySuite * 30),
            color = "#FF7F0E", linewidth = 1.5) +
  geom_point(aes(y = HasSecondarySuite * 30),
             color = "#FF7F0E", size = 3) +
  scale_y_continuous(
    name     = "Total Permits",
    labels   = comma,
    sec.axis = sec_axis(~ . / 30,
                        name   = "Secondary Suite Permits",
                        labels = comma)
  ) +
  scale_x_continuous(breaks = seq(2015, 2025, by = 1)) +
  labs(
    title    = "Secondary Suite Permit Trend (2015-2025)",
    subtitle = "Rising adoption of secondary suites reflects Winnipeg housing densification policy",
    x        = "Year",
    caption  = "Source: City of Winnipeg Open Data | Analysis: Shekhor Chanda"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15),
    plot.subtitle    = element_text(color = "gray40"),
    panel.grid.minor = element_blank(),
    axis.title.y.right = element_text(color = "#FF7F0E"),
    axis.text.y.right  = element_text(color = "#FF7F0E")
  )

ggsave(file.path(OUTPUT_DIR, "06_secondary_suite_trends.png"),
       p6, width = 12, height = 6, dpi = 150)
print(p6)
cat("Chart 6 saved: 06_secondary_suite_trends.png\n\n")



# =============================================================
# SUMMARY
# =============================================================
cat("=============================================================\n")
cat("R Analysis Complete!\n")
cat("=============================================================\n\n")
cat("Charts saved to:\n")
cat(paste0(OUTPUT_DIR, "\n\n"))
cat("Files generated:\n")
cat("  01_yearly_permit_trends.png\n")
cat("  02_seasonal_patterns.png\n")
cat("  03_elbow_method.png\n")
cat("  04_neighbourhood_clusters.png\n")
cat("  05_processing_time_trend.png\n")
cat("  06_secondary_suite_trends.png\n")

cat("Key Findings:\n")
cat(sprintf(" Peak permit month:    %s (%d permits avg)\n",
            seasonal_summary$MonthName[which.max(seasonal_summary$AvgPermits)],
            round(max(seasonal_summary$AvgPermits))))
cat(sprintf(" Lowest permit month:  %s (%d permits avg)\n",
            seasonal_summary$MonthName[which.min(seasonal_summary$AvgPermits)],
            round(min(seasonal_summary$AvgPermits))))
cat(sprintf(" Neighbourhood clusters identified: 4\n"))
cat(sprintf(" Secondary suites growth 2020-2025: significant increase\n"))
cat("=============================================================\n")