# Job Reference

This document provides an in-depth technical overview of each SQL Agent job deployed by the FRK Automation script, including schedules, job steps, stored procedures, and performance considerations.

## 1. FRK – Daily Health Check

| Attribute | Value |
|-----------|-------|
| **Job Name** | `FRK – Daily Health Check` |
| **Enabled** | Yes |
| **Owner** | `@JobOwner` (configured service account) |
| **Category** | `@JobCategoryName` |
| **Schedule Name** | `FRK_Daily_0200` |
| **Frequency** | Daily |
| **Start Time** | 02:00:00 (server local time) |
| **Steps** | 1 |
| **Stored Procedures** | `sp_Blitz`, `sp_BlitzFirst`, `sp_BlitzCache`, `sp_BlitzWho` |
| **Estimated Duration** | 2–5 minutes (depends on server workload) |
| **Output Tables** | `dbo.Blitz`, `dbo.BlitzFirst`, `dbo.BlitzCache`, `dbo.BlitzWho` |
| **Error Handling** | TRY…CATCH with audit logging to `msdb.dbo.FRK_JobExecutionLog` |

### Step Details
1. **Execute Full Health Check Suite** (T-SQL)
   ```sql
   EXEC master.dbo.sp_Blitz @CheckUserDatabaseObjects=0, @OutputDatabaseName=@DatabaseName, @OutputSchemaName='dbo', @OutputTableName='Blitz';
   EXEC master.dbo.sp_BlitzFirst @ExpertMode=1, @OutputDatabaseName=@DatabaseName, @OutputSchemaName='dbo', @OutputTableName='BlitzFirst', @Seconds=60;
   EXEC master.dbo.sp_BlitzCache @SortOrder='cpu', @Top=25, @OutputDatabaseName=@DatabaseName, @OutputSchemaName='dbo', @OutputTableName='BlitzCache';
   EXEC master.dbo.sp_BlitzWho @OutputDatabaseName=@DatabaseName, @OutputSchemaName='dbo', @OutputTableName='BlitzWho';
   ```

### Performance Impact Notes
- **CPU**: sp_BlitzFirst runs for 60 seconds, capturing live wait statistics
- **IO**: sp_BlitzCache accesses plan cache; moderate memory impact
- **Mitigation**: Schedule during low activity windows

---

## 2. FRK – Peak Hour Performance Snapshot

| Attribute | Value |
|-----------|-------|
| **Job Name** | `FRK – Peak Hour Performance Snapshot` |
| **Enabled** | Yes |
| **Owner** | `@JobOwner` |
| **Category** | `@JobCategoryName` |
| **Schedule Names** | `FRK_Peak_Morning_1030`, `FRK_Peak_Afternoon_1430` |
| **Frequency** | Daily |
| **Start Times** | 10:30:00 and 14:30:00 |
| **Steps** | 1 |
| **Stored Procedures** | `sp_BlitzFirst`, `sp_BlitzWho` |
| **Estimated Duration** | 45–90 seconds |
| **Output Tables** | `dbo.BlitzFirst_Peak`, `dbo.BlitzWho_Peak` |

### Step Details
1. **Execute Peak Hour Data Capture** (T-SQL)
   ```sql
   EXEC master.dbo.sp_BlitzFirst @ExpertMode=1, @OutputDatabaseName=@DatabaseName, @OutputSchemaName='dbo', @OutputTableName='BlitzFirst_Peak', @Seconds=30;
   EXEC master.dbo.sp_BlitzWho @OutputDatabaseName=@DatabaseName, @OutputSchemaName='dbo', @OutputTableName='BlitzWho_Peak';
   ```

### Performance Impact Notes
- Shorter sampling interval (30 seconds) to minimize production impact
- Two snapshots capture both morning and afternoon peak loads

---

## 3. FRK – Weekly Index Analysis

| Attribute | Value |
|-----------|-------|
| **Job Name** | `FRK – Weekly Index Analysis` |
| **Enabled** | Yes |
| **Owner** | `@JobOwner` |
| **Category** | `@JobCategoryName` |
| **Schedule Name** | `FRK_Weekly_Index_Sunday` |
| **Frequency** | Weekly |
| **Day** | Sunday |
| **Start Time** | 22:00:00 |
| **Steps** | 1 |
| **Stored Procedures** | `sp_BlitzIndex` |
| **Execution Mode** | Mode 4 (Index Usage and Missing Indexes) |
| **Estimated Duration** | 5–20 minutes (depends on database size) |
| **Output Tables** | `dbo.BlitzIndex` |

### Step Details
1. **Execute Index Deep Dive Analysis** (T-SQL)
   ```sql
   EXEC master.dbo.sp_BlitzIndex @GetAllDatabases=1, @Mode=4, @OutputDatabaseName=@DatabaseName, @OutputSchemaName='dbo', @OutputTableName='BlitzIndex';
   ```

### Performance Impact Notes
- Runs during off-peak hours (Sunday night)
- Analyze large indexes; ensure sufficient maintenance window

---

## 4. FRK – Weekly Data Cleanup

| Attribute | Value |
|-----------|-------|
| **Job Name** | `FRK – Weekly Data Cleanup` |
| **Enabled** | Yes |
| **Owner** | `@JobOwner` |
| **Category** | `@JobCategoryName` |
| **Schedule Name** | `FRK_Weekly_Cleanup_Saturday` |
| **Frequency** | Weekly |
| **Day** | Saturday |
| **Start Time** | 23:00:00 |
| **Steps** | 1 |
| **Retention Logic** | Deletes Blitz* tables older than `@RetentionDays` |
| **Estimated Duration** | < 1 minute (DDL-only operations) |
| **Error Handling** | Throws error 50020 if `@RetentionDays` < 7 |

### Step Details
1. **Execute Data Retention Cleanup** (T-SQL)
   ```sql
   DECLARE @CutoffDate DATE = DATEADD(DAY, -@RetentionDays, GETDATE());
   -- Dynamic DROP TABLE generation via FOR XML PATH
   -- Ensures compatibility with SQL Server 2016 (no STRING_AGG)
   ```

### Performance Impact Notes
- Minimal server impact; drops tables older than retention threshold
- Transaction-safe with error rollback

---

## 5. FRK – Export Raw Data Locally

| Attribute | Value |
|-----------|-------|
| **Job Name** | `FRK – Export Raw Data Locally` |
| **Enabled** | Yes (manual execution) |
| **Owner** | `@JobOwner` |
| **Category** | `@JobCategoryName` |
| **Schedule** | None (on-demand) |
| **Steps** | 1 |
| **Subsystem** | PowerShell |
| **PowerShell Module** | `SqlServer` (modern replacement for SQLPS) |
| **Output** | CSV files in `@ExportPath\RawExport_YYYYMMDD\` |
| **Estimated Duration** | 10–60 seconds (depends on data volume) |

### Step Details
1. **Export Raw CSV Files to Local Path** (PowerShell)
   ```powershell
   Import-Module SqlServer -Force
   $SqlServer = $env:COMPUTERNAME
   $Database = "@DatabaseName"
   $ExportPath = "@ExportPath"
   $Today = Get-Date -Format "yyyyMMdd"
   $LocalDumpPath = Join-Path $ExportPath ("RawExport_{0}" -f $Today)
   # Create folder structure, iterate Blitz* tables, export to CSV
   ```

### Performance Impact Notes
- Runs under `#NOSQLPS` to suppress deprecated snap-in
- Recommended to execute during low I/O usage windows

---

## Execution Log Table (msdb.dbo.FRK_JobExecutionLog)

| Column | Data Type | Description |
|--------|-----------|-------------|
| `JobLogID` | `INT IDENTITY(1,1)` | Primary key |
| `JobName` | `NVARCHAR(128)` | Name of the job |
| `StepName` | `NVARCHAR(128)` | Job step executed |
| `StartTime` | `DATETIME2` | Automatically populated on job start |
| `EndTime` | `DATETIME2` | Populated on success/failure |
| `Success` | `BIT` | `1` = success, `0` = failure |
| `ErrorMessage` | `NVARCHAR(MAX)` | Detailed error message captured in TRY…CATCH |

### Usage Examples

#### Query Recent Failures
```sql
SELECT TOP 20
    JobLogID,
    JobName,
    StepName,
    StartTime,
    EndTime,
    ErrorMessage
FROM msdb.dbo.FRK_JobExecutionLog
WHERE Success = 0
ORDER BY StartTime DESC;
```

#### Calculate Average Duration per Job
```sql
SELECT 
    JobName,
    COUNT(*) AS RunCount,
    AVG(DATEDIFF(SECOND, StartTime, EndTime)) AS AvgDurationSec,
    MAX(DATEDIFF(SECOND, StartTime, EndTime)) AS MaxDurationSec
FROM msdb.dbo.FRK_JobExecutionLog
WHERE Success = 1
GROUP BY JobName
ORDER BY AvgDurationSec DESC;
```

---

## Performance Planning & Scheduling Recommendations

### CPU & Memory Considerations
- **sp_BlitzFirst** sampling period (30–60 seconds) collects wait stats; negligible CPU impact on modern hardware
- **sp_BlitzCache** may consume additional memory when analyzing large plan cache; schedule during off-peak hours if server memory is constrained
- **sp_BlitzIndex** runs across all databases; execution time grows with database count and data volume

### IO & Storage Considerations
- Output tables grow daily; monitor row counts and implement appropriate retention policy
- CSV exports can be compressed; consider enabling NTFS compression on export directory

### Scheduling Best Practices
- **Daily Health Check**: Run outside business hours (02:00 AM default)
- **Peak Hour Snapshot**: Align with busiest application periods
- **Weekly Index Analysis**: Schedule after weekly maintenance window (e.g., Sunday after backups)
- **Cleanup**: Run after backups and index maintenance to avoid dropping tables needed for troubleshooting
- **Export Job**: Execute after cleanup or on-demand for reporting

---

## Advanced Job Customization

### Adding Additional Job Steps
Example: Add `sp_BlitzLock` to detect blocking and deadlocks
```sql
-- Modify @FullCaptureScript before deployment
SET @FullCaptureScript += N'
EXEC master.dbo.sp_BlitzLock @OutputDatabaseName=N''' + @DatabaseName + ''', @OutputSchemaName=N''dbo'', @OutputTableName=N''BlitzLock'';
';
```

### Splitting Jobs Across Servers
- Deploy FRK jobs independently on each server for local monitoring
- Centralize output tables using linked servers or ETL processes if consolidated analysis is required

### Alerting Integration
- Use Database Mail and sp_send_dbmail for on-failure notifications
- Integrate SQL Agent alerts with monitoring platforms (e.g., SCOM, Zabbix, Prometheus) for enterprise dashboards

---

**End of Job Reference**