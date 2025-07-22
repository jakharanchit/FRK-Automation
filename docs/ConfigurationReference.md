# Configuration Reference

This document provides comprehensive details about all configuration parameters, deployment options, and advanced customization settings for the FRK Automation framework.

## Core Configuration Parameters

The FRK Automation script uses a temporary configuration table (`#FRK_Config`) to centralize all environment-specific settings. This design enables easy customization without modifying the core script logic.

### Configuration Table Schema

```sql
CREATE TABLE #FRK_Config (
    DatabaseName NVARCHAR(128)         NOT NULL,    -- Target database for FRK output
    RetentionDays INT                  NOT NULL,    -- Data retention period
    JobOwner NVARCHAR(128)             NOT NULL,    -- Service account for job execution
    JobCategoryName NVARCHAR(128)      NOT NULL,    -- SQL Agent job category
    ExportPath NVARCHAR(255)           NOT NULL     -- File system path for exports
);
```

## Parameter Specifications

### DatabaseName
**Purpose**: Specifies the target database where all FRK output tables will be created and maintained.

**Technical Details**:
- **Data Type**: `NVARCHAR(128)`
- **Constraints**: Must be a valid SQL Server database identifier
- **Default Value**: `DBAtools`
- **Character Limits**: 1-128 characters, following SQL Server naming conventions

**Validation Rules**:
- Cannot contain reserved SQL keywords without proper bracketing
- Must not contain invalid characters: `/ \ : * ? " < > |`
- Cannot be NULL or empty string
- Cannot be a system database name (`master`, `model`, `msdb`, `tempdb`)

**Examples**:
```sql
-- Valid configurations
N'HealthChecks'           -- Simple identifier
N'DBA_Monitoring'         -- Underscore separator
N'[Performance-DB]'       -- Bracketed for special characters
N'FRK_Production'         -- Environment-specific naming

-- Invalid configurations  
N''                       -- Empty string (ERROR)
N'master'                 -- System database (WARNING)
N'Database*Name'          -- Invalid character (ERROR)
```

**Database Creation Behavior**:
- If database does not exist: Automatically created with default settings
- If database exists: Used as-is without modification
- File growth settings: Uses SQL Server defaults (10% auto-growth)
- Recovery model: Inherits from model database (typically FULL)

**Advanced Configuration**:
For custom database settings, pre-create the database before script execution:

```sql
CREATE DATABASE [HealthChecks]
ON (
    NAME = 'HealthChecks_Data',
    FILENAME = 'D:\Data\HealthChecks.mdf',
    SIZE = 500MB,
    FILEGROWTH = 100MB
)
LOG ON (
    NAME = 'HealthChecks_Log', 
    FILENAME = 'E:\Logs\HealthChecks.ldf',
    SIZE = 100MB,
    FILEGROWTH = 10%
);

-- Set appropriate recovery model
ALTER DATABASE [HealthChecks] SET RECOVERY SIMPLE;
```

### RetentionDays
**Purpose**: Controls how long historical FRK data is retained before automatic cleanup.

**Technical Details**:
- **Data Type**: `INT`
- **Default Value**: `30`
- **Minimum Value**: `7` (enforced by cleanup job)
- **Maximum Value**: `2147483647` (INT max, practically unlimited)
- **Recommended Range**: 30-90 days for most environments

**Validation Rules**:
- Must be integer value ≥ 7
- Values < 7 cause cleanup job to fail with error 50020
- NULL values not permitted

**Storage Impact Calculations**:

| Environment Size | Daily Growth | 30-Day Storage | 90-Day Storage |
|------------------|--------------|----------------|----------------|
| Small (1-5 DBs) | 2-5 MB | 60-150 MB | 180-450 MB |
| Medium (5-20 DBs) | 10-25 MB | 300-750 MB | 900-2.25 GB |
| Large (20+ DBs) | 50-100 MB | 1.5-3 GB | 4.5-9 GB |
| Enterprise | 100+ MB | 3+ GB | 9+ GB |

**Retention Strategy Recommendations**:
- **Development**: 7-14 days (rapid iteration, limited storage)
- **Production**: 30-60 days (troubleshooting history, compliance)
- **Audit/Compliance**: 90-365 days (regulatory requirements)
- **Long-term Analysis**: 365+ days (trend analysis, capacity planning)

**Dynamic Retention Configuration**:
```sql
-- Modify retention for existing deployment
UPDATE #FRK_Config SET RetentionDays = 60;

-- Query current retention settings
SELECT 
    'Current Retention: ' + CAST(@RetentionDays AS NVARCHAR(10)) + ' days' AS Configuration,
    'Oldest Data: ' + CONVERT(NVARCHAR(19), DATEADD(DAY, -@RetentionDays, GETDATE()), 120) AS OldestRetainedData;
```

### JobOwner
**Purpose**: Specifies the SQL Server login that will own and execute all FRK automation jobs.

**Technical Details**:
- **Data Type**: `NVARCHAR(128)`
- **Default Value**: `sa` (not recommended for production)
- **Validation**: Must exist in `sys.server_principals`
- **Authentication Types**: Supports both SQL and Windows authentication

**Security Requirements**:

**Minimum Permissions**:
```sql
-- Server-level permissions
GRANT VIEW SERVER STATE TO [DOMAIN\FRKServiceAccount];
GRANT VIEW ANY DEFINITION TO [DOMAIN\FRKServiceAccount];

-- msdb database permissions (for job logging)
USE msdb;
ALTER ROLE SQLAgentUserRole ADD MEMBER [DOMAIN\FRKServiceAccount];
ALTER ROLE db_datareader ADD MEMBER [DOMAIN\FRKServiceAccount];
ALTER ROLE db_datawriter ADD MEMBER [DOMAIN\FRKServiceAccount];

-- Target database permissions  
USE [DBAtools];
ALTER ROLE db_ddladmin ADD MEMBER [DOMAIN\FRKServiceAccount];  -- For table creation
ALTER ROLE db_datawriter ADD MEMBER [DOMAIN\FRKServiceAccount]; -- For data insertion
ALTER ROLE db_datareader ADD MEMBER [DOMAIN\FRKServiceAccount]; -- For data export
```

**Extended Permissions (if using advanced FRK features)**:
```sql
-- For extended events and traces (if required by FRK procedures)
GRANT ALTER TRACE TO [DOMAIN\FRKServiceAccount];

-- For plan cache analysis (BlitzCache advanced features)
GRANT VIEW DATABASE PERFORMANCE STATE TO [DOMAIN\FRKServiceAccount];

-- For cross-database index analysis (BlitzIndex)
GRANT VIEW ANY DATABASE TO [DOMAIN\FRKServiceAccount];
```

**Service Account Best Practices**:

1. **Dedicated Account**: Create specific account for FRK automation
```sql
-- Example Windows account creation
CREATE LOGIN [DOMAIN\FRKServiceAccount] FROM WINDOWS;
```

2. **SQL Account Alternative** (if Windows authentication unavailable):
```sql  
CREATE LOGIN [FRKServiceAccount] WITH 
    PASSWORD = 'ComplexPassword123!',
    DEFAULT_DATABASE = [msdb],
    CHECK_EXPIRATION = ON,
    CHECK_POLICY = ON;
```

3. **Service Account Validation**:
```sql
-- Verify account exists and permissions
SELECT 
    sp.name AS LoginName,
    sp.type_desc AS LoginType,
    sp.is_disabled AS IsDisabled,
    sp.create_date AS CreatedDate
FROM sys.server_principals sp
WHERE sp.name = 'DOMAIN\FRKServiceAccount';

-- Check server-level permissions
SELECT 
    pr.permission_name,
    pr.state_desc
FROM sys.server_permissions pr
    INNER JOIN sys.server_principals sp ON pr.grantee_principal_id = sp.principal_id
WHERE sp.name = 'DOMAIN\FRKServiceAccount';
```

### JobCategoryName
**Purpose**: Organizes FRK jobs within SQL Server Agent using a logical category grouping.

**Technical Details**:
- **Data Type**: `NVARCHAR(128)`  
- **Default Value**: `Database Maintenance (FRK)`
- **Category Type**: `LOCAL` job category
- **Auto-Creation**: Category created automatically if it doesn't exist

**Category Management**:
```sql
-- View existing job categories
SELECT 
    category_id,
    name,
    category_class,
    category_type
FROM msdb.dbo.syscategories
WHERE category_class = 1 -- Job categories
ORDER BY name;

-- Create custom category manually (optional)
EXEC msdb.dbo.sp_add_category 
    @class = N'JOB',
    @type = N'LOCAL', 
    @name = N'Performance Monitoring';
```

**Organizational Strategies**:
- **Environment-based**: `Production FRK`, `Development FRK`, `Test FRK`
- **Function-based**: `Health Monitoring`, `Performance Analysis`, `Database Maintenance`
- **Team-based**: `DBA Team - Monitoring`, `Infrastructure - SQL`

### ExportPath  
**Purpose**: Defines the file system directory where PowerShell export jobs will write CSV files.

**Technical Details**:
- **Data Type**: `NVARCHAR(255)`
- **Default Value**: `D:\SQL_Exports`
- **Path Type**: Supports local paths, UNC paths, mapped drives
- **Access Requirements**: SQL Agent service account needs Full Control permissions

**Path Configuration Examples**:
```sql
-- Local drive configurations
N'D:\SQL_Exports'                    -- Local fixed drive
N'E:\DatabaseExports\FRK'            -- Subfolder organization  
N'C:\SQLExports'                     -- System drive (not recommended)

-- Network share configurations  
N'\\FileServer\SQLExports\FRK'       -- UNC path to file server
N'\\NAS01\DatabaseBackups\Exports'   -- Network attached storage
N'Z:\Exports'                        -- Mapped network drive

-- Complex path examples
N'D:\Exports\SQL\' + @@SERVERNAME    -- Server-specific subfolders
```

**Directory Structure Created by Export Job**:
```
ExportPath\
├── RawExport_20250122\              -- Daily dated folders
│   ├── Blitz.csv                    -- FRK output tables
│   ├── BlitzFirst.csv
│   ├── BlitzCache.csv  
│   ├── BlitzWho.csv
│   └── BlitzIndex.csv
├── RawExport_20250123\
└── RawExport_20250124\
```

**Permission Configuration**:

**Windows File System Permissions**:
```cmd
REM Grant permissions via command line (run as Administrator)
icacls "D:\SQL_Exports" /grant "DOMAIN\SQLServiceAccount":(OI)(CI)F /T

REM Alternative using PowerShell
$acl = Get-Acl "D:\SQL_Exports"  
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("DOMAIN\SQLServiceAccount","FullControl","ContainerInherit,ObjectInherit","None","Allow")
$acl.SetAccessRule($accessRule)
Set-Acl "D:\SQL_Exports" $acl
```

**Validation Script**:
```sql
-- Test export path accessibility  
DECLARE @TestPath NVARCHAR(255) = 'D:\SQL_Exports';
DECLARE @TestFile NVARCHAR(300) = @TestPath + '\test_access.txt';
DECLARE @PowerShellCmd NVARCHAR(500);

SET @PowerShellCmd = 'powershell.exe -Command "
    try { 
        ''Testing access'' | Out-File -FilePath ''' + @TestFile + ''' -Force; 
        Remove-Item ''' + @TestFile + ''' -Force;
        Write-Output ''SUCCESS: Path accessible''
    } catch { 
        Write-Output ''ERROR: '' + $_.Exception.Message 
    }"';

EXEC xp_cmdshell @PowerShellCmd;
```

## Advanced Configuration Options

### Multi-Server Deployment Configuration

For deploying across multiple SQL Server instances:

```sql
-- Central configuration table approach
CREATE TABLE [CentralConfig].[dbo].[FRK_ServerConfigurations] (
    ServerName NVARCHAR(128) PRIMARY KEY,
    DatabaseName NVARCHAR(128) NOT NULL,
    RetentionDays INT NOT NULL,
    JobOwner NVARCHAR(128) NOT NULL,
    ExportPath NVARCHAR(255) NOT NULL,
    IsActive BIT DEFAULT 1,
    LastDeployed DATETIME2 DEFAULT SYSDATETIME()
);

-- Sample multi-server configuration
INSERT INTO [CentralConfig].[dbo].[FRK_ServerConfigurations] VALUES
('SQLPROD01', 'DBAtools_Prod', 60, 'DOMAIN\FRKProd', '\\FileServer\SQL\PROD01', 1, DEFAULT),
('SQLTEST01', 'DBAtools_Test', 14, 'DOMAIN\FRKTest', '\\FileServer\SQL\TEST01', 1, DEFAULT),
('SQLDEV01', 'DBAtools_Dev', 7, 'DOMAIN\FRKDev', 'D:\LocalExports', 1, DEFAULT);
```

### Environment-Specific Configurations

**Production Environment**:
```sql
INSERT INTO #FRK_Config VALUES
(
    N'DBAtools_Production',
    60,                               -- Longer retention for production
    N'DOMAIN\SQLPROD_FRKService',    -- Dedicated production service account
    N'Production - Database Health',  -- Clear environment identification
    N'\\ProdFileServer\SQLExports'   -- Centralized storage
);
```

**Development Environment**:
```sql  
INSERT INTO #FRK_Config VALUES
(
    N'DBAtools_Dev',
    7,                                -- Minimal retention for dev
    N'DOMAIN\SQLDEV_Service',        -- Development service account
    N'Development - FRK Testing',     -- Development-specific category
    N'D:\DevExports'                 -- Local storage acceptable
);
```

### Dynamic Configuration with Variables

For automated deployments, support configuration via SQLCMD variables:

```sql
-- Modified configuration section for variable support
DECLARE @ConfigDatabaseName NVARCHAR(128) = COALESCE('$(DatabaseName)', N'DBAtools');
DECLARE @ConfigRetentionDays INT = COALESCE(CONVERT(INT, '$(RetentionDays)'), 30);
DECLARE @ConfigJobOwner NVARCHAR(128) = COALESCE('$(JobOwner)', N'sa');  
DECLARE @ConfigExportPath NVARCHAR(255) = COALESCE('$(ExportPath)', N'D:\SQL_Exports');

INSERT INTO #FRK_Config VALUES
(
    @ConfigDatabaseName,
    @ConfigRetentionDays, 
    @ConfigJobOwner,
    N'Database Maintenance (FRK)',
    @ConfigExportPath
);
```

**Deployment with variables**:
```cmd
sqlcmd -S ServerName -E -i FRK_Automation.sql ^
    -v DatabaseName="HealthCheck_Prod" ^
    -v RetentionDays=90 ^
    -v JobOwner="DOMAIN\FRKProdService" ^
    -v ExportPath="\\FileServer\SQLExports\PROD"
```

## Configuration Validation and Testing

### Pre-Deployment Validation Script

```sql
-- Comprehensive configuration validation
DECLARE @ValidationResults TABLE (
    CheckName NVARCHAR(100),
    Status NVARCHAR(20),
    Details NVARCHAR(500)
);

-- Validate service account
INSERT INTO @ValidationResults
SELECT 
    'Service Account Existence',
    CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @JobOwner) 
         THEN 'PASS' ELSE 'FAIL' END,
    'Account: ' + @JobOwner;

-- Validate retention period
INSERT INTO @ValidationResults  
SELECT
    'Retention Period',
    CASE WHEN @RetentionDays >= 7 THEN 'PASS' ELSE 'FAIL' END,
    'Days: ' + CAST(@RetentionDays AS NVARCHAR(10));

-- Validate database name
INSERT INTO @ValidationResults
SELECT
    'Database Name Format',
    CASE WHEN @DatabaseName NOT IN ('master', 'model', 'msdb', 'tempdb') 
         AND LEN(@DatabaseName) > 0 
         THEN 'PASS' ELSE 'FAIL' END,  
    'Database: ' + @DatabaseName;

-- Display results
SELECT * FROM @ValidationResults WHERE Status = 'FAIL';
```

This comprehensive configuration reference provides all necessary details for customizing the FRK Automation framework to meet specific technical and organizational requirements.