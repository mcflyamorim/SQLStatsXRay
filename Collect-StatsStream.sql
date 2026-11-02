/*
================================================================================
 Collect-StatsStream.sql
--------------------------------------------------------------------------------
 Runs dbo.usp_DecodeStatsStream for every statistics object of every user table
 (and indexed view) in every online database of the instance, and stores every
 result set in user tables (default: tempdb.dbo.StatsStream_<Section>):

   StatsStream_Statistics       StatsStream_DensityVector    StatsStream_StringIndex
   StatsStream_StreamHeader     StatsStream_Histogram        StatsStream_StringIndexNodes
   StatsStream_StatsColumns     StatsStream_UpdateHistory    StatsStream_SampledScanDump
   StatsStream_BlobHeader       StatsStream_TraceFlag2388    StatsStream_UnknownItems / _Layout / _Validation (optional)
   StatsStream_VariableItems    StatsStream_Skipped          (statistics blocked > 100 ms or unreadable)
                                StatsStream_Errors           (databases / tables that could not be read)

 Every table starts with [Collected At], [Database Name], [Schema Name], [Table Name],
 [Statistics Name], so the sections can be joined to each other.

 Never blocks the workload:
 - every query runs READ UNCOMMITTED with LOCK_TIMEOUT 100 ms (script and procedure);
 - the inventory reads sys.objects one table at a time through a cursor: a table whose
   metadata is blocked is logged in StatsStream_Errors and the next one is read;
 - the procedure decodes one statistics object at a time (cursor over sys.stats): a
   statistics object that is blocked (e.g. DBCC SHOW_STATISTICS waiting on a schema
   change) is logged in StatsStream_Skipped and the next one is decoded.
 - each skip is written to StatsStream_Skipped as it happens and printed in the
   Messages tab as "SKIPPED <statistic> [stage] error: message" (first 50 per database).

 Speed: the procedure is called once per database (not once per table), so its
 statements compile once per database. Roughly 25 ms per statistics object with all
 string index nodes and sampled values; the defaults of the procedure (300 nodes,
 20 values) and @VerifyChecksum = 0 are faster.

 Notes
 - Requires dbo.usp_DecodeStatsStream (usp_DecodeStatsStream.sql). Set @ProcName to its
   3-part name if it lives in another database.
 - Skipped: tempdb, database snapshots, databases that are not ONLINE or that the login
   cannot access, and Microsoft-shipped tables (msdb/master system tables).
 - tempdb is emptied when the instance restarts: copy the tables elsewhere to keep them
   (or point @OutputDatabase to a DBA database).
 - The tables hold histogram boundary values (real column data). Treat them as client
   data: restrict access and do not copy them out of the customer environment.
================================================================================
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   -- no shared locks anywhere (dynamic SQL inherits it)
SET LOCK_TIMEOUT 100;                              -- anything still blocked gives up after 100 ms and is skipped

DECLARE
    @ProcName               nvarchar(400) = N'tempdb.dbo.usp_DecodeStatsStream',   -- or N'DBA.dbo.usp_DecodeStatsStream'
    @OutputDatabase         sysname       = N'tempdb',
    @OutputSchema           sysname       = N'dbo',
    @OutputTablePrefix      sysname       = N'StatsStream_',
    @ResetTables            bit           = 1,      -- drop the output tables of a previous collection first
    @DatabaseLike           sysname       = N'%',   -- filter: database names LIKE this pattern
    @IncludeSystemDatabases bit           = 1,      -- master, model, msdb (only their user tables are decoded)
    @IncludeSnapshots       bit           = 0,
    -- usp_DecodeStatsStream options
    @IncludeStringIndex     bit           = 1,
    @IncludeSampledScanDump bit           = 1,
    @IncludeUnknownItems    bit           = 0,
    @IncludeLayout          bit           = 0,
    @Validate               bit           = 0,      -- 1 = also compare with DBCC (TF 2388 check writes to the ERRORLOG)
    @VerifyChecksum         bit           = 0,      -- 1 = byte-by-byte CRC check (slow on large streams)
    @MaxStringIndexNodes    int           = 0,      -- 0 = all nodes (slower on large string indexes; procedure default 300)
    @MaxSampledScanValues   int           = 0,      -- 0 = all values
    @FlushEvery             int           = 200,    -- statistics objects buffered by the procedure before each write
    @ProgressSeconds        int           = 10;     -- progress message interval (% done, elapsed, time remaining)

DECLARE @CollectionTime datetime2(3) = SYSDATETIME(), @sql nvarchar(max), @db sysname, @outBase nvarchar(400), @errTable nvarchar(600),
        @msg nvarchar(2048), @proc nvarchar(300), @errNo int, @errMsg nvarchar(4000), @nErrors int = 0, @nDb int = 0,
        @dbStats bigint, @dbTables int, @totalStats bigint, @totalTables int, @doneStats bigint = 0, @runStart datetime2(3), @dbStart datetime2(3);

IF OBJECT_ID(@ProcName) IS NULL BEGIN RAISERROR(N'Procedure %s not found. Create it with usp_DecodeStatsStream.sql or fix @ProcName.', 16, 1, @ProcName); RETURN; END
IF DB_ID(@OutputDatabase) IS NULL BEGIN RAISERROR(N'Output database %s not found.', 16, 1, @OutputDatabase); RETURN; END

SET @outBase = QUOTENAME(@OutputDatabase) + N'.' + QUOTENAME(@OutputSchema) + N'.';
SET @errTable = @outBase + QUOTENAME(@OutputTablePrefix + N'Errors');

------------------------------------------------------------------------------
-- Reset the output tables of a previous run
------------------------------------------------------------------------------
IF @ResetTables = 1
BEGIN
    SET @sql = N'
DECLARE @d nvarchar(max) = N'''';
SELECT @d += N''DROP TABLE '' + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name) + N''; ''
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = @schema AND t.name LIKE REPLACE(REPLACE(@prefix, N''['', N''[[]''), N''_'', N''[_]'') + N''%'';
EXEC (@d);';
    SET @proc = QUOTENAME(@OutputDatabase) + N'.sys.sp_executesql';
    EXEC @proc @sql, N'@schema sysname, @prefix sysname', @OutputSchema, @OutputTablePrefix;
END

SET @sql = N'IF OBJECT_ID(N''' + @errTable + N''') IS NULL
CREATE TABLE ' + @errTable + N' ([Collected At] datetime2(3), [Database Name] sysname, [Schema Name] sysname NULL, [Table Name] sysname NULL,
    [Stage] nvarchar(80) NULL, [Error Number] int, [Error Message] nvarchar(4000));';
EXEC (@sql);

------------------------------------------------------------------------------
-- Databases
------------------------------------------------------------------------------
DECLARE @dbs TABLE (n int IDENTITY PRIMARY KEY, name sysname, tables int NULL, stats bigint NULL);
INSERT @dbs (name)
SELECT d.name
FROM sys.databases d
WHERE d.state_desc = N'ONLINE'
  AND d.name <> N'tempdb'
  AND d.name LIKE @DatabaseLike
  AND (@IncludeSnapshots = 1 OR d.source_database_id IS NULL)
  AND (@IncludeSystemDatabases = 1 OR d.database_id > 4)
  AND HAS_DBACCESS(d.name) = 1
ORDER BY d.name;

------------------------------------------------------------------------------
-- Inventory: one table at a time through a cursor (no ORDER BY, so it stays a dynamic
-- cursor reading row by row); a table whose metadata is blocked is logged and skipped.
------------------------------------------------------------------------------
CREATE TABLE #inv (db sysname, tables int, stats bigint);
CREATE TABLE #invErr (db sysname, schema_name sysname NULL, table_name sysname NULL, error_number int, error_message nvarchar(4000));

DECLARE @d int = 1;
WHILE @d <= (SELECT ISNULL(MAX(n), 0) FROM @dbs)
BEGIN
    SELECT @db = name FROM @dbs WHERE n = @d;
    BEGIN TRY
        SET @proc = QUOTENAME(@db) + N'.sys.sp_executesql';
        EXEC @proc N'
DECLARE @o int, @sch sysname, @tn sysname, @cnt int, @tables int = 0, @stats bigint = 0, @fetchErrors int = 0;
DECLARE c CURSOR LOCAL FORWARD_ONLY READ_ONLY FOR
    SELECT object_id FROM sys.objects WHERE type IN (''U'', ''V'') AND is_ms_shipped = 0;
OPEN c;
WHILE 1 = 1
BEGIN
    BEGIN TRY
        FETCH NEXT FROM c INTO @o;
    END TRY
    BEGIN CATCH
        INSERT #invErr VALUES (DB_NAME(), NULL, NULL, ERROR_NUMBER(), N''FETCH: '' + ERROR_MESSAGE());
        SET @fetchErrors += 1;
        IF @fetchErrors >= 5 BREAK;
        CONTINUE;
    END CATCH
    IF @@FETCH_STATUS <> 0 BREAK;
    SET @fetchErrors = 0;
    BEGIN TRY
        SELECT @sch = NULL, @tn = NULL, @cnt = 0;
        SELECT @sch = s.name, @tn = o.name FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id WHERE o.object_id = @o;
        SELECT @cnt = COUNT(*) FROM sys.stats WHERE object_id = @o;
        IF @cnt > 0 SELECT @tables += 1, @stats += @cnt;
    END TRY
    BEGIN CATCH
        INSERT #invErr VALUES (DB_NAME(), @sch, ISNULL(@tn, CAST(@o AS sysname)), ERROR_NUMBER(), ERROR_MESSAGE());
    END CATCH
END
CLOSE c;
DEALLOCATE c;
INSERT #inv VALUES (DB_NAME(), @tables, @stats);';
    END TRY
    BEGIN CATCH
        INSERT #invErr VALUES (@db, NULL, NULL, ERROR_NUMBER(), ERROR_MESSAGE());
    END CATCH
    SET @d += 1;
END

UPDATE d SET tables = i.tables, stats = i.stats FROM @dbs d JOIN #inv i ON i.db = d.name;
SET @sql = N'INSERT ' + @errTable + N' SELECT @at, db, schema_name, table_name, N''inventory'', error_number, error_message FROM #invErr;';
EXEC sys.sp_executesql @sql, N'@at datetime2(3)', @CollectionTime;
SELECT @nErrors = COUNT(*) FROM #invErr;

SELECT @totalStats = ISNULL(SUM(stats), 0), @totalTables = ISNULL(SUM(tables), 0) FROM @dbs;
SET @msg = CONVERT(nvarchar(19), SYSDATETIME(), 120) + N'  Inventory: ' + CAST((SELECT COUNT(*) FROM @dbs WHERE stats > 0) AS nvarchar(10))
         + N' databases with statistics (of ' + CAST((SELECT COUNT(*) FROM @dbs) AS nvarchar(10)) + N' online), '
         + CAST(@totalTables AS nvarchar(10)) + N' tables, ' + CAST(@totalStats AS nvarchar(20)) + N' statistics'
         + CASE WHEN @nErrors > 0 THEN N', ' + CAST(@nErrors AS nvarchar(10)) + N' tables skipped (blocked/unreadable)' ELSE N'' END + N'.';
RAISERROR(@msg, 0, 1) WITH NOWAIT;

------------------------------------------------------------------------------
-- Decode: one procedure call per database; the procedure prints the server-wide
-- progress (% done, elapsed, time remaining, ETA) every @ProgressSeconds.
------------------------------------------------------------------------------
SELECT @runStart = SYSDATETIME(), @d = 1;
WHILE @d <= (SELECT ISNULL(MAX(n), 0) FROM @dbs)
BEGIN
    SELECT @db = name, @dbStats = stats, @dbTables = tables FROM @dbs WHERE n = @d;
    IF @dbStats > 0
    BEGIN
        SET @dbStart = SYSDATETIME();
        SET @msg = CONVERT(nvarchar(19), SYSDATETIME(), 120) + N'  ' + @db + N': ' + CAST(@dbTables AS nvarchar(10)) + N' tables, '
                 + CAST(@dbStats AS nvarchar(20)) + N' statistics';
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
        BEGIN TRY
            EXEC @ProcName
                @DatabaseName = @db, @TableName = NULL, @StatsName = NULL, @Validate = @Validate,
                @IncludeStringIndex = @IncludeStringIndex, @IncludeSampledScanDump = @IncludeSampledScanDump,
                @IncludeUnknownItems = @IncludeUnknownItems, @IncludeLayout = @IncludeLayout, @VerifyChecksum = @VerifyChecksum,
                @MaxStringIndexNodes = @MaxStringIndexNodes, @MaxSampledScanValues = @MaxSampledScanValues,
                @OutputDatabase = @OutputDatabase, @OutputSchema = @OutputSchema, @OutputTablePrefix = @OutputTablePrefix,
                @CollectionTime = @CollectionTime, @FlushEvery = @FlushEvery,
                @ProgressSeconds = @ProgressSeconds, @ProgressDone = @doneStats, @ProgressTotal = @totalStats, @ProgressStart = @runStart;
        END TRY
        BEGIN CATCH
            SELECT @errNo = ERROR_NUMBER(), @errMsg = ERROR_MESSAGE();
            SET @sql = N'INSERT ' + @errTable + N' VALUES (@at, @db, NULL, NULL, N''decode database'', @n, @m);';
            EXEC sys.sp_executesql @sql, N'@at datetime2(3), @db sysname, @n int, @m nvarchar(4000)', @CollectionTime, @db, @errNo, @errMsg;
            SET @nErrors += 1;
        END CATCH
        SET @doneStats += @dbStats;
        SET @nDb += 1;
        SET @msg = CONVERT(nvarchar(19), SYSDATETIME(), 120) + N'  ' + @db + N' done in ' + CAST(DATEDIFF(second, @dbStart, SYSDATETIME()) AS nvarchar(10)) + N' s';
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END
    SET @d += 1;
END

------------------------------------------------------------------------------
-- Summary
------------------------------------------------------------------------------
SET @msg = N'Collection ' + CONVERT(nvarchar(23), @CollectionTime, 121) + N': ' + CAST(@nDb AS nvarchar(10)) + N' databases, '
         + CAST(@totalStats AS nvarchar(20)) + N' statistics in ' + CAST(DATEDIFF(second, @CollectionTime, SYSDATETIME()) AS nvarchar(10))
         + N' s; ' + CAST(@nErrors AS nvarchar(10)) + N' errors (see ' + @OutputTablePrefix + N'Errors and ' + @OutputTablePrefix + N'Skipped).';
RAISERROR(@msg, 0, 1) WITH NOWAIT;

SET @sql = N'
SELECT t.name AS [Output Table], SUM(p.rows) AS [Rows]
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE s.name = @schema AND t.name LIKE REPLACE(REPLACE(@prefix, N''['', N''[[]''), N''_'', N''[_]'') + N''%''
GROUP BY t.name ORDER BY t.name;';
SET @proc = QUOTENAME(@OutputDatabase) + N'.sys.sp_executesql';
EXEC @proc @sql, N'@schema sysname, @prefix sysname', @OutputSchema, @OutputTablePrefix;

SET @sql = N'SELECT * FROM ' + @errTable + N' ORDER BY [Database Name], [Schema Name], [Table Name];';
EXEC (@sql);
IF OBJECT_ID(@outBase + QUOTENAME(@OutputTablePrefix + N'Skipped')) IS NOT NULL
BEGIN
    SET @sql = N'SELECT * FROM ' + @outBase + QUOTENAME(@OutputTablePrefix + N'Skipped') + N' ORDER BY [Database Name], [Schema Name], [Table Name];';
    EXEC (@sql);
END

/*
-- Examples once collected:

-- statistics per database, sampled vs fullscan, stale ones
SELECT b.[Database Name], COUNT(*) AS [Statistics], SUM(CASE WHEN b.Scan = 'SAMPLED' THEN 1 ELSE 0 END) AS Sampled,
       SUM(CASE WHEN s.[Modification Counter] > 0.2 * b.[Rows] THEN 1 ELSE 0 END) AS [Over 20% Modified]
FROM tempdb.dbo.StatsStream_BlobHeader b
JOIN tempdb.dbo.StatsStream_Statistics s ON s.[Database Name] = b.[Database Name] AND s.[Schema Name] = b.[Schema Name]
     AND s.[Table Name] = b.[Table Name] AND s.[Statistics Name] = b.[Statistics Name]
GROUP BY b.[Database Name];

-- smallest samples on the largest tables
SELECT TOP (50) [Database Name], [Schema Name], [Table Name], [Statistics Name], [Rows], [Sample Percent], [Pages Sampled Percent], Updated
FROM tempdb.dbo.StatsStream_BlobHeader WHERE Scan = 'SAMPLED' ORDER BY [Rows] DESC;

-- ascending keys
SELECT [Database Name], [Schema Name], [Table Name], [Statistics Name]
FROM tempdb.dbo.StatsStream_TraceFlag2388 WHERE [Row] = 1 AND [Leading column Type] = N'Ascending';
*/
