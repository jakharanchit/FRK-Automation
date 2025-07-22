# QuickStart Guide

This guide provides step-by-step instructions for deploying the FRK Automation framework in under 10 minutes.

## Prerequisites Checklist

Before beginning, ensure your environment meets these technical requirements:

### SQL Server Environment
- [ ] SQL Server 2016 or later (Express, Standard, Enterprise, Developer)
- [ ] SQL Server Agent service running and enabled for automatic startup
- [ ] `sysadmin` or `SQLAgentOperatorRole` permissions for deployment account
- [ ] Database creation permissions (`dbcreator` role or `sysadmin`)

### First Responder Kit Installation
- [ ] Latest FRK procedures installed in `master` database
- [ ] Verify installation: `SELECT OBJECT_ID('master.dbo.sp_Blitz')`

### Service Account Configuration
- [ ] Dedicated service account created (avoid using `sa`)
- [ ] Service account added to SQL Server as login
- [ ] Minimum permissions granted:
  - `VIEW SERVER STATE` (for performance monitoring)
  - `ALTER TRACE` (for extended events, if used)
  - `SQLAgentUserRole` in `msdb` database

### File System Preparation
- [ ] Export directory created (default: `D:\SQL_Exports`)
- [ ] SQL Agent service account granted `FULL CONTROL` permissions on export directory
- [ ] Sufficient disk space for CSV exports (estimate 100MB per month minimum)

## Step 1: Download and Prepare the Script

1. Clone or download the repository:
   ```bash
   git clone https://github.com/your-repo/frk-automation.git
   cd frk-automation
   ```

2. Open `deploy/FRK_Automation.sql` in SQL Server Management Studio (SSMS) or Azure Data Studio

## Step 2: Configure Environment Parameters

Locate the configuration section in the script and modify the `INSERT INTO #FRK_Config` statement:

```sql
INSERT INTO #FRK_Config VALUES
(
    N'DBAtools',                        -- DatabaseName: Target database for FRK results
    30,                                 -- RetentionDays: Data retention period (minimum 7)
    N'DOMAIN\FRKServiceAccount',        -- JobOwner: Service account for job execution
    N'Database Maintenance (FRK)',      -- JobCategoryName: SQL Agent job category
    N'D:\SQL_Exports'                   -- ExportPath: Directory for CSV exports
);
```

### Configuration Parameter Details

| Parameter | Purpose | Validation Rules | Examples |
|-----------|---------|------------------|----------|
| `DatabaseName` | Storage location for FRK output tables | Must be valid SQL identifier | `DBAtools`, `HealthChecks`, `Monitoring` |
| `RetentionDays` | Days to retain historical data | Integer ≥ 7 | `30` (monthly), `90` (quarterly) |
| `JobOwner` | SQL login for job ownership | Must exist in `sys.server_principals` | `DOMAIN\SQLAgent`, `FRKService` |
| `JobCategoryName` | Organizational category | Valid category name | Custom or default value |
| `ExportPath` | File system path for exports | Must be accessible to SQL Agent | `D:\Exports`, `\\FileServer\SQLExports` |

## Step 3: Execute the Deployment Script

### Method 1: SSMS GUI Execution
1. Connect to target SQL Server instance with administrative privileges
2. Ensure correct database context (script sets `USE [msdb]`)
3. Execute the script (F5 or Ctrl+E)
4. Monitor the Messages tab for deployment progress

### Method 2: Command Line Execution
```cmd
sqlcmd -S ServerName -E -i FRK_Automation.sql -o deployment_log.txt
```

### Method 3: Parameterized Execution
```cmd
sqlcmd -S ServerName -E -i FRK_Automation.sql -v DatabaseName=ProdHealthChecks RetentionDays=60
```

## Step 4: Verify Successful Deployment

### Check Job Creation
```sql
SELECT 
    j.name AS JobName,
    j.enabled AS IsEnabled,
    j.date_created AS CreationDate,
    c.name AS Category,
    sp.name AS Owner
FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.syscategories c ON j.category_id = c.category_id
    LEFT JOIN sys.server_principals sp ON j.owner_sid = sp.sid
WHERE j.name LIKE 'FRK - %'
ORDER BY j.name;
```

Expected output should show 5 jobs:
- FRK - Daily Health Check
- FRK - Peak Hour Performance Snapshot  
- FRK - Weekly Index Analysis
- FRK - Weekly Data Cleanup
- FRK - Export Raw Data Locally

### Verify Logging Infrastructure
```sql
SELECT 
    TABLE_SCHEMA,
    TABLE_NAME,
    TABLE_TYPE
FROM msdb.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'FRK_JobExecutionLog';
```

### Check Database Creation
```sql
SELECT 
    name,
    database_id,
    create_date,
    state_desc
FROM sys.databases
WHERE name = 'DBAtools'; -- Or your configured database name
```

## Step 5: Test Job Execution

### Manual Test Run
Execute one job manually to verify functionality:

```sql
EXEC msdb.dbo.sp_start_job @job_name = 'FRK - Daily Health Check';

-- Monitor execution
SELECT 
    run_date,
    run_time,
    run_status,
    message
FROM msdb.dbo.sysjobhistory jh
    INNER JOIN msdb.dbo.sysjobs j ON jh.job_id = j.job_id
WHERE j.name = 'FRK - Daily Health Check'
ORDER BY run_date DESC, run_time DESC;
```

### Verify Data Collection
```sql
-- Switch to your configured database
USE DBAtools;

-- Check for Blitz output tables
SELECT 
    name AS TableName,
    create_date AS CreatedDate,
    (SELECT COUNT(*) FROM sys.dm_db_partition_stats ps WHERE ps.object_id = t.object_id AND ps.index_id IN (0,1)) AS RowCount
FROM sys.tables t
WHERE name LIKE 'Blitz%'
ORDER BY create_date DESC;
```

### Check Execution Logging
```sql
USE msdb;

SELECT 
    JobLogID,
    JobName,
    StepName,
    StartTime,
    EndTime,
    Success,
    DATEDIFF(SECOND, StartTime, EndTime) AS DurationSeconds,
    ErrorMessage
FROM dbo.FRK_JobExecutionLog
ORDER BY StartTime DESC;
```

## Step 6: Configure PowerShell Module (For Export Functionality)

### Install SqlServer PowerShell Module
Run as Administrator on the SQL Server machine:

```powershell
# Check current execution policy
Get-ExecutionPolicy

# Set execution policy if needed (choose appropriate policy for your environment)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine

# Install SqlServer module
Install-Module -Name SqlServer -Force -AllowClobber

# Verify installation
Get-Module -ListAvailable SqlServer
```

### Test Export Job
```sql
-- Execute export job manually
EXEC msdb.dbo.sp_start_job @job_name = 'FRK - Export Raw Data Locally';

-- Check export directory for CSV files
-- Directory structure: D:\SQL_Exports\RawExport_YYYYMMDD\*.csv
```

## Advanced Configuration

### Custom Schedule Modification
To modify job schedules after deployment:

```sql
-- Example: Change daily health check to 1:00 AM
EXEC msdb.dbo.sp_update_schedule 
    @name = 'FRK_Daily_0200',
    @active_start_time = 010000; -- 01:00:00 in HHMMSS format
```

### Additional FRK Procedures
To add more FRK procedures to existing jobs, modify the script variables before deployment:

```sql
-- Example addition to @FullCaptureScript
EXEC master.dbo.sp_BlitzLock @Top=10, @OutputDatabaseName=N''' + @DatabaseName + ''', @OutputSchemaName=N''dbo'', @OutputTableName=N''BlitzLock'';
```

### Multi-Instance Deployment
For multiple SQL Server instances:

1. Create instance-specific configuration files
2. Use SQL Server configuration management for batch deployment
3. Consider central logging database for consolidated monitoring

## Troubleshooting Common Issues

### Issue: "Configured service account does not exist"
**Cause**: Invalid service account in configuration
**Resolution**:
```sql
-- Create the service account login
CREATE LOGIN [DOMAIN\FRKServiceAccount] FROM WINDOWS;

-- Grant necessary permissions
GRANT VIEW SERVER STATE TO [DOMAIN\FRKServiceAccount];
EXEC sp_addsrvrolemember 'DOMAIN\FRKServiceAccount', 'SQLAgentUserRole';
```

### Issue: Export job fails with PowerShell errors
**Cause**: Missing SqlServer module or execution policy restrictions
**Resolution**:
```powershell
# Check module availability
Get-Module -ListAvailable SqlServer

# Install if missing
Install-Module SqlServer -Force

# Check execution policy
Get-ExecutionPolicy -List
```

### Issue: Jobs created but not executing on schedule
**Cause**: SQL Agent service stopped or disabled
**Resolution**:
```sql
-- Check SQL Agent status
SELECT 
    servicename,
    status_desc,
    startup_type_desc
FROM sys.dm_server_services
WHERE servicename LIKE '%Agent%';

-- Enable and start SQL Agent service (requires sysadmin)
-- Use SQL Server Configuration Manager or Services.msc
```

## Next Steps

After successful deployment:

1. **Monitor Initial Runs**: Check job execution logs for first 24-48 hours
2. **Baseline Data**: Review initial FRK findings to establish performance baseline
3. **Schedule Maintenance**: Plan regular review of retention policies and export schedules
4. **Documentation**: Update internal documentation with deployment details and contacts
5. **Alerting**: Consider integrating with existing monitoring solutions for job failure alerts

## Performance Impact Assessment

### Expected Resource Usage
- **CPU Impact**: <5% during job execution periods
- **Memory Usage**: 50-200MB additional during FRK procedure execution
- **Disk I/O**: Moderate during data collection, minimal during export operations
- **Storage Growth**: ~10-50MB per day depending on server activity

### Monitoring Recommendations
```sql
-- Monitor job execution times
SELECT 
    JobName,
    AVG(DATEDIFF(SECOND, StartTime, EndTime)) AS AvgDurationSeconds,
    MAX(DATEDIFF(SECOND, StartTime, EndTime)) AS MaxDurationSeconds,
    COUNT(*) AS ExecutionCount
FROM msdb.dbo.FRK_JobExecutionLog
WHERE StartTime >= DATEADD(DAY, -30, GETDATE())
    AND Success = 1
GROUP BY JobName;
```

This completes the technical deep-dive QuickStart guide. The system is now ready for production monitoring and health analysis.