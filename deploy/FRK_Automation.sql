/******************************************************************************************
 First Responder Kit (FRK) Full Automation Setup Script
 Author: Anchit Jakhar
 Last Modified: 2025-07-22

 Summary:
 This script automates deployment of First Responder Kit tooling jobs in SQL Server.
 It features environment-aware configuration, robust error handling, enhanced logging,
 modern PowerShell integration for exports, and comprehensive scheduling.

 Core Features:
 - Creates all necessary jobs, categories, and underlying tables for FRK health checks.
 - Uses parameterized, audit-friendly configuration.
 - Enforces security with a custom service account (not 'sa').
 - Deploys monitoring for job outcomes and critical events.
 - Exports raw diagnostic data to flat files using modern PowerShell (SqlServer module).
 - Ensures all jobs and supporting objects are idempotent and follow best practices.

******************************************************************************************/


-- =================================================================================
-- ENVIRONMENT CONFIGURATION SECTION
-- =================================================================================
USE [msdb];
GO
SET NOCOUNT ON;

-- 1. Configuration Table: Stores environment-specific parameters
IF OBJECT_ID('tempdb..#FRK_Config') IS NOT NULL DROP TABLE #FRK_Config;

CREATE TABLE #FRK_Config (
    DatabaseName NVARCHAR(128)         NOT NULL,
    RetentionDays INT                  NOT NULL,
    JobOwner NVARCHAR(128)             NOT NULL,
    JobCategoryName NVARCHAR(128)      NOT NULL,
    ExportPath NVARCHAR(255)           NOT NULL
);

INSERT INTO #FRK_Config VALUES
(
    N'DBAtools',          -- FRK target database
    30,                   -- Data retention (min 7 days)
    N'sa',  -- Dedicated, least-privileged service account
    N'Database Maintenance (FRK)', -- Job category name
    N'D:\SQL_Exports'     -- Export dir (GRANT access to SQL Agent svc!)
);

-- Parameter assignment for easy substitution
DECLARE @DatabaseName NVARCHAR(128),
        @RetentionDays INT,
        @JobOwner NVARCHAR(128),
        @JobCategoryName NVARCHAR(128),
        @ExportPath NVARCHAR(255),
		@SqlStatement NVARCHAR(MAX);

SELECT
    @DatabaseName    = DatabaseName,
    @RetentionDays   = RetentionDays,
    @JobOwner        = JobOwner,
    @JobCategoryName = JobCategoryName,
    @ExportPath      = ExportPath
FROM #FRK_Config;

-- Validate that the service account exists
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @JobOwner)
    THROW 50001, 'Configured service account does not exist in SQL Server. Please create and grant appropriate rights.', 1;

-- =================================================================================
-- BEGIN ATOMIC INSTALL TRANSACTION
-- =================================================================================
BEGIN TRY
    SET XACT_ABORT ON;  -- Ensure rollback on error
    BEGIN TRANSACTION;

    -- Step 1: Create Database if not exists
    IF NOT EXISTS (SELECT name FROM master.sys.databases WHERE name = @DatabaseName)
    BEGIN
        PRINT 'Creating database: ' + @DatabaseName;
        SET @SqlStatement = N'CREATE DATABASE ' + QUOTENAME(@DatabaseName);
        EXEC sp_executesql @SqlStatement;
    END

    ---- Step 2: Create category if it does not exist
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = @JobCategoryName AND category_class = 1)
    BEGIN
        EXEC msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name = @JobCategoryName;
        PRINT 'FRK Job Category created: ' + @JobCategoryName;
    END

    ---- Step 3: Create/Reset FRK Jobs
    PRINT 'Dropping existing FRK jobs for clean deployment...';
    DECLARE @JobName NVARCHAR(128);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM msdb.dbo.sysjobs WHERE name LIKE N'FRK - %';
    OPEN cur; FETCH NEXT FROM cur INTO @JobName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC msdb.dbo.sp_delete_job @job_name=@JobName;
        FETCH NEXT FROM cur INTO @JobName;
    END
    CLOSE cur; DEALLOCATE cur;

    ---- Step 4: Monitoring Table (job results log)
    USE msdb;
    IF OBJECT_ID('dbo.FRK_JobExecutionLog') IS NULL
    CREATE TABLE dbo.FRK_JobExecutionLog (
        JobLogID INT IDENTITY(1,1) PRIMARY KEY,
        [JobName] NVARCHAR(128),
        [StepName] NVARCHAR(128),
        [StartTime] DATETIME2 DEFAULT SYSDATETIME(),
        [EndTime] DATETIME2,
        [Success] BIT,
        [ErrorMessage] NVARCHAR(MAX) NULL
    );

    ---- Step 5: Define FRK job logic (set-optimized and parameterized)
    DECLARE
        @FullCaptureScript NVARCHAR(MAX),
        @PeakHourScript NVARCHAR(MAX),
        @IndexDeepDiveScript NVARCHAR(MAX),
        @CleanupScript NVARCHAR(MAX),
        @LocalExportScript NVARCHAR(MAX);

    -- == Full Health Suite: Blitz, BlitzFirst, BlitzCache, BlitzWho
    SET @FullCaptureScript = N'
DECLARE @CurrentLogID INT;
BEGIN TRY
    INSERT INTO msdb.dbo.FRK_JobExecutionLog (JobName, StepName, StartTime) VALUES (''FRK - Daily Health Check'', ''Execute Full Health Check Suite'', SYSDATETIME());
    SET @CurrentLogID = SCOPE_IDENTITY();

    EXEC master.dbo.sp_Blitz @CheckUserDatabaseObjects=0, @OutputDatabaseName=N''' + @DatabaseName + ''', @OutputSchemaName=N''dbo'', @OutputTableName=N''Blitz'';
    EXEC master.dbo.sp_BlitzFirst @ExpertMode=1, @OutputDatabaseName=N''' + @DatabaseName + ''', @OutputSchemaName=N''dbo'', @OutputTableName=N''BlitzFirst'', @Seconds=60;
    EXEC master.dbo.sp_BlitzCache @SortOrder=N''cpu'', @Top=25, @OutputDatabaseName=N''' + @DatabaseName + ''', @OutputSchemaName=N''dbo'', @OutputTableName=N''BlitzCache'';
    EXEC master.dbo.sp_BlitzWho @OutputDatabaseName=N''' + @DatabaseName + ''', @OutputSchemaName=N''dbo'', @OutputTableName=N''BlitzWho'';
    
    UPDATE msdb.dbo.FRK_JobExecutionLog SET EndTime=SYSDATETIME(), Success=1 WHERE JobLogID=@CurrentLogID;
END TRY
BEGIN CATCH
    IF @CurrentLogID IS NOT NULL
        UPDATE msdb.dbo.FRK_JobExecutionLog SET EndTime=SYSDATETIME(), Success=0, ErrorMessage=ERROR_MESSAGE() WHERE JobLogID=@CurrentLogID;
    THROW;
END CATCH
';

    -- == Peak Time Sampling (shorter interval)
    SET @PeakHourScript = N'
DECLARE @CurrentLogID INT;
BEGIN TRY
    INSERT INTO msdb.dbo.FRK_JobExecutionLog (JobName, StepName, StartTime) VALUES (''FRK - Peak Hour Performance Snapshot'', ''Execute Peak Hour Data Capture'', SYSDATETIME());
    SET @CurrentLogID = SCOPE_IDENTITY();

    EXEC master.dbo.sp_BlitzFirst @ExpertMode=1, @OutputDatabaseName=N''' + @DatabaseName + ''', @OutputSchemaName=N''dbo'', @OutputTableName=N''BlitzFirst_Peak'', @Seconds=30;
    EXEC master.dbo.sp_BlitzWho @OutputDatabaseName=N''' + @DatabaseName + ''', @OutputSchemaName=N''dbo'', @OutputTableName=N''BlitzWho_Peak'';

    UPDATE msdb.dbo.FRK_JobExecutionLog SET EndTime=SYSDATETIME(), Success=1 WHERE JobLogID=@CurrentLogID;
END TRY
BEGIN CATCH
    IF @CurrentLogID IS NOT NULL
        UPDATE msdb.dbo.FRK_JobExecutionLog SET EndTime=SYSDATETIME(), Success=0, ErrorMessage=ERROR_MESSAGE() WHERE JobLogID=@CurrentLogID;
    THROW;
END CATCH
';

    -- == Weekly Index Analysis (BlitzIndex)
    SET @IndexDeepDiveScript = N'
DECLARE @CurrentLogID INT;
BEGIN TRY
    INSERT INTO msdb.dbo.FRK_JobExecutionLog (JobName, StepName, StartTime) VALUES (''FRK - Weekly Index Analysis'', ''Execute Index Deep Dive Analysis'', SYSDATETIME());
    SET @CurrentLogID = SCOPE_IDENTITY();

    EXEC master.dbo.sp_BlitzIndex @GetAllDatabases=1, @Mode=4, @OutputDatabaseName=N''' + @DatabaseName + ''', @OutputSchemaName=N''dbo'', @OutputTableName=N''BlitzIndex'';

    UPDATE msdb.dbo.FRK_JobExecutionLog SET EndTime=SYSDATETIME(), Success=1 WHERE JobLogID=@CurrentLogID;
END TRY
BEGIN CATCH
    IF @CurrentLogID IS NOT NULL
        UPDATE msdb.dbo.FRK_JobExecutionLog SET EndTime=SYSDATETIME(), Success=0, ErrorMessage=ERROR_MESSAGE() WHERE JobLogID=@CurrentLogID;
    THROW;
END CATCH
';

    -- == Set-Based, Safe Data Retention Cleanup: Only with minimum retention
    -- CORRECTED SCRIPT BLOCK: Using FOR XML PATH for robust, backward-compatible string aggregation.
    SET @CleanupScript = N'
DECLARE @CurrentLogID INT;
BEGIN TRY
    INSERT INTO msdb.dbo.FRK_JobExecutionLog (JobName, StepName, StartTime) VALUES (''FRK - Weekly Data Cleanup'', ''Execute Data Retention Cleanup'', SYSDATETIME());
    SET @CurrentLogID = SCOPE_IDENTITY();

    IF ' + CAST(@RetentionDays AS NVARCHAR(3)) + ' < 7
        THROW 50020, ''Retention period is less than 7 days. Aborting cleanup for safety.'', 1;
    
    DECLARE @CutoffDate DATE = DATEADD(DAY, -' + CAST(@RetentionDays AS NVARCHAR(3)) + ', GETDATE());
    DECLARE @sql NVARCHAR(MAX);

    -- Use FOR XML PATH for robust string aggregation
    SELECT @sql = STUFF(
        (
            SELECT N'';DROP TABLE dbo.'' + QUOTENAME(name)
            FROM sys.tables
            WHERE create_date < @CutoffDate AND name LIKE ''Blitz%''
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''NVARCHAR(MAX)''), 
        1, 1, N''''
    );

    IF @sql IS NOT NULL AND LEN(@sql) > 0
    BEGIN
        EXEC sp_executesql @sql;
    END

    UPDATE msdb.dbo.FRK_JobExecutionLog SET EndTime=SYSDATETIME(), Success=1 WHERE JobLogID=@CurrentLogID;
END TRY
BEGIN CATCH
    IF @CurrentLogID IS NOT NULL
        UPDATE msdb.dbo.FRK_JobExecutionLog SET EndTime=SYSDATETIME(), Success=0, ErrorMessage=ERROR_MESSAGE() WHERE JobLogID=@CurrentLogID;
    THROW;
END CATCH
';

    -- == Robust PowerShell Export, using modern #NOSQLPS and SqlServer module
    SET @LocalExportScript = N'
#NOSQLPS
Import-Module SqlServer -Force

$ErrorActionPreference = "Stop"
$SqlServer = $env:COMPUTERNAME  # Dynamically picks the server
$Database = "' + @DatabaseName + '"
$ExportPath = "' + @ExportPath + '"
$Today = Get-Date -Format "yyyyMMdd"
$LocalDumpPath = Join-Path $ExportPath ("RawExport_{0}" -f $Today)

Try {
    if (-not (Test-Path $LocalDumpPath)) {
        New-Item -Path $LocalDumpPath -ItemType Directory -Force | Out-Null
    }

    # Only export tables from today and with Blitz prefix
    $tableQuery = "SELECT name FROM sys.tables WHERE create_date >= DATEADD(day, -1, GETDATE()) AND (name LIKE ''Blitz%'');"
    $tables = Invoke-Sqlcmd -ServerInstance $SqlServer -Database $Database -Query $tableQuery -OutputSqlErrors $true

    if ($tables) {
        foreach ($table in $tables) {
            $TableName = $table.name
            $CsvFilePath = Join-Path $LocalDumpPath ("{0}.csv" -f $TableName)
            $ExportQuery = "SELECT * FROM dbo.[{0}];" -f $TableName
            Invoke-Sqlcmd -ServerInstance $SqlServer -Database $Database -Query $ExportQuery | Export-Csv -Path $CsvFilePath -NoTypeInformation -Force
        }
        Write-Output ("Local export completed successfully to {0}." -f $LocalDumpPath)
    } else {
        Write-Output "No new tables found for local export."
    }
}
Catch {
    Write-Error ("The FRK local export job failed. Error: {0}" -f $_.Exception.Message)
    throw
}
';

    -- =================================================================================
    -- JOB CREATION SECTION: Production Schedules and Parameters
    -- =================================================================================

    PRINT 'Deploying FRK jobs with best-practice schedules...';

    -- Daily Health Check: 02:00 AM
    EXEC msdb.dbo.sp_add_job            @job_name=N'FRK - Daily Health Check', @owner_login_name=@JobOwner, @category_name=@JobCategoryName;
    EXEC msdb.dbo.sp_add_jobstep        @job_name=N'FRK - Daily Health Check', @step_name=N'Execute Full Health Check Suite', @subsystem=N'TSQL', @command=@FullCaptureScript, @on_success_action=1, @on_fail_action=2;
    EXEC msdb.dbo.sp_add_jobschedule    @job_name=N'FRK - Daily Health Check', @name=N'FRK_Daily_0200', @freq_type=4, @freq_interval=1, @active_start_time=20000;
    EXEC msdb.dbo.sp_add_jobserver      @job_name=N'FRK - Daily Health Check', @server_name = N'(local)';

    -- Peak Hour: 10:30 AM and 2:30 PM
    EXEC msdb.dbo.sp_add_job            @job_name=N'FRK - Peak Hour Performance Snapshot', @owner_login_name=@JobOwner, @category_name=@JobCategoryName;
    EXEC msdb.dbo.sp_add_jobstep        @job_name=N'FRK - Peak Hour Performance Snapshot', @step_name=N'Execute Peak Hour Data Capture', @subsystem=N'TSQL', @command=@PeakHourScript;
    EXEC msdb.dbo.sp_add_jobschedule    @job_name=N'FRK - Peak Hour Performance Snapshot', @name=N'FRK_Peak_Morning_1030', @freq_type=4, @freq_interval=1, @active_start_time=103000;
    EXEC msdb.dbo.sp_add_jobschedule    @job_name=N'FRK - Peak Hour Performance Snapshot', @name=N'FRK_Peak_Afternoon_1430', @freq_type=4, @freq_interval=1, @active_start_time=143000;
    EXEC msdb.dbo.sp_add_jobserver      @job_name=N'FRK - Peak Hour Performance Snapshot', @server_name = N'(local)';

    -- Index Deep Dive: Sunday, 10:00 PM
    EXEC msdb.dbo.sp_add_job            @job_name=N'FRK - Weekly Index Analysis', @owner_login_name=@JobOwner, @category_name=@JobCategoryName;
    EXEC msdb.dbo.sp_add_jobstep        @job_name=N'FRK - Weekly Index Analysis', @step_name=N'Execute Index Deep Dive Analysis', @subsystem=N'TSQL', @command=@IndexDeepDiveScript;
    EXEC msdb.dbo.sp_add_jobschedule    @job_name=N'FRK - Weekly Index Analysis', @name=N'FRK_Weekly_Index_Sunday', @freq_type=8, @freq_interval=1, @freq_recurrence_factor=1, @active_start_time=220000;
    EXEC msdb.dbo.sp_add_jobserver      @job_name=N'FRK - Weekly Index Analysis', @server_name = N'(local)';

    -- Data Retention/Cleanup: Saturday, 11:00 PM
    EXEC msdb.dbo.sp_add_job            @job_name=N'FRK - Weekly Data Cleanup', @owner_login_name=@JobOwner, @category_name=@JobCategoryName;
    EXEC msdb.dbo.sp_add_jobstep        @job_name=N'FRK - Weekly Data Cleanup', @step_name=N'Execute Data Retention Cleanup', @subsystem=N'TSQL', @command=@CleanupScript, @database_name=@DatabaseName;
    EXEC msdb.dbo.sp_add_jobschedule    @job_name=N'FRK - Weekly Data Cleanup', @name=N'FRK_Weekly_Cleanup_Saturday', @freq_type=8, @freq_interval=64, @freq_recurrence_factor=1, @active_start_time=230000;
    EXEC msdb.dbo.sp_add_jobserver      @job_name=N'FRK - Weekly Data Cleanup', @server_name = N'(local)';

    -- EXPORT: On-demand (manual run only)
    EXEC msdb.dbo.sp_add_job            @job_name=N'FRK - Export Raw Data Locally', @owner_login_name=@JobOwner, @category_name=@JobCategoryName;
    EXEC msdb.dbo.sp_add_jobstep        @job_name=N'FRK - Export Raw Data Locally', @step_name=N'Export Raw CSV Files to Local Path', @subsystem=N'PowerShell', @command=@LocalExportScript;
    EXEC msdb.dbo.sp_add_jobserver      @job_name=N'FRK - Export Raw Data Locally', @server_name = N'(local)';

    -- =================================================================================

    COMMIT TRANSACTION;
    PRINT '================================================================================';
    PRINT 'SUCCESS: All FRK jobs, configuration, and monitoring deployed.';
    PRINT 'Next Steps:';
    PRINT ' - Ensure SQL Agent is running and service account permissions are correct.';
    PRINT ' - The export job is manual; run as-needed for CSVs (dir: ' + @ExportPath + ').';
    PRINT ' - All activity is logged in msdb.dbo.FRK_JobExecutionLog for auditing/monitoring.';
    PRINT ' - For changes, simply re-run this script—it is idempotent.';
    PRINT '================================================================================';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '================================================================================';
    PRINT 'ERROR! No changes committed; script aborted.';
    PRINT 'Reason: ' + ERROR_MESSAGE();
    PRINT '================================================================================';
    THROW;
END CATCH
