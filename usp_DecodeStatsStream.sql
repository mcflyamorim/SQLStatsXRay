/*
================================================================================
 dbo.usp_DecodeStatsStream
--------------------------------------------------------------------------------
 T-SQL port of Decode-StatsStream.ps1. Decodes the undocumented STATS_STREAM
 returned by DBCC SHOW_STATISTICS ... WITH STATS_STREAM and returns it as a set
 of result sets (header, columns, blob header, variable items, density vector,
 histogram, update history, trace flag 2388 view, string index, sampled scan
 dump, unknown items, optional layout and validation).

 Input:
   @TableName   [+ @StatsName]  every statistics object of a table, or one of them
   @StatsName   alone           every statistics object with that name in the database
   neither                      every statistics object of every user table / indexed view
                                of the database (meant for output-table mode)
 (To decode a saved STATS_STREAM without the table, use Decode-StatsStream.ps1 -StatsStream.)

 Never blocks the workload: it runs READ UNCOMMITTED with LOCK_TIMEOUT 100 ms, reads the
 statistics one at a time through a cursor, and skips (and reports in "Skipped") any
 statistics object that is blocked or cannot be read, then carries on with the next one.

 Result sets, per statistics object (every one starts with Section, Statistic):
    1 Statistics          metadata from sys.stats / dm_db_stats_properties, warnings, raw stream
    2 Stream Header       version, column count, checksum (+ CRC check), lengths
    3 Stats Columns       24-byte column definitions, collation and code page
    4 Blob Header         324-byte fixed section + unfiltered rows, pages sampled, table pages, persisted %,
                          string index YES/NO, leading column type, presence bitmask,
                          columnstore page counts (bit 6), streaming statistics flags (bit 11)
    5 Variable Items      bitmask items with offsets and lengths
    6 Density Vector      All density, Average Length (running sum, as DBCC), stored per-column length
    7 Histogram           RANGE_HI_KEY (sql_variant of the column type), RANGE_HI_KEY_TEXT,
                          RANGE_ROWS, EQ_ROWS, DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS, record offset/bytes
    8 Update History      raw 76-byte records (newest first)
    9 Trace Flag 2388     same rows/columns as DBCC SHOW_STATISTICS under TF 2388
   10 String Index        trie header + compressed string        (@IncludeStringIndex = 1)
   11 String Index Nodes  trie nodes with depth, counts, text     (@IncludeStringIndex = 1)
   12 Sampled Scan Dump   distinct value synopsis (bit 5): per vector, the k smallest hash values
                          kept by the estimator: count, sum, min, max, values (@IncludeSampledScanDump = 1)
   13 Unknown Items       undocumented items / trailer as hex    (@IncludeUnknownItems = 1)
   14 Layout              decoded fields with offsets             (@IncludeLayout = 1)
   15 Validation          checks against DBCC, dm_db_stats_histogram and TF 2388 (@Validate = 1;
                          the TF 2388 check needs sysadmin, and its TRACEON/OFF pair is logged
                          once per call in the ERRORLOG)
 and, at the end, "Skipped" when any statistics object was blocked or failed.

 Output-table mode: with @OutputDatabase set, nothing is returned; each result set is appended to
 <@OutputDatabase>.<@OutputSchema>.<@OutputTablePrefix><Section without spaces> (for example
 tempdb.dbo.StatsStream_Histogram), created on first use with five leading columns:
 [Collected At], [Database Name], [Schema Name], [Table Name], [Statistics Name].
 Rows are flushed every @FlushEvery statistics objects. Collect-StatsStream.sql uses this mode.

 Trace flag 2388 row 1 "Snapshot Ctr" is not stored in the stream (it is in sys.sysobjvalues):
 the procedure reads it when run over the DAC (admin:<instance>), otherwise it shows the row
 count as an estimate ([Snapshot Ctr Source] says which).

 Requires SQL Server 2017+ (STRING_AGG, CREATE OR ALTER). Can be created in any database:
 @DatabaseName selects where the table lives.

 Layout reverse engineered on SQL Server 2025 (17.x); see STATS_STREAM-format.md.
 Not an official Microsoft format: use @Validate = 1 to compare with DBCC.

 Histogram boundary values are real data: be careful where you paste the output
 of customer databases.

 Examples:
   EXEC dbo.usp_DecodeStatsStream @DatabaseName = N'StatsStreamLab', @TableName = N'dbo.T', @StatsName = N's_c_int';
   EXEC dbo.usp_DecodeStatsStream @DatabaseName = N'Northwind', @TableName = N'dbo.Orders', @Validate = 1;
   EXEC dbo.usp_DecodeStatsStream @DatabaseName = N'Northwind', @OutputDatabase = N'tempdb', @ProgressSeconds = 10;
================================================================================
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_DecodeStatsStream
    @DatabaseName           sysname        = NULL,  -- default: current database
    @TableName              nvarchar(776)  = NULL,  -- 'schema.table' (or table); NULL with @StatsName NULL = whole database
    @StatsName              sysname        = NULL,  -- statistics or index name
    @Validate               bit            = 0,     -- compare with DBCC SHOW_STATISTICS / dm_db_stats_histogram / TF 2388
    @IncludeStringIndex     bit            = 1,
    @IncludeSampledScanDump bit            = 1,
    @IncludeUnknownItems    bit            = 0,
    @IncludeLayout          bit            = 0,
    @VerifyChecksum         bit            = 1,     -- byte-by-byte CRC: the slowest part for large streams
    @MaxStringIndexNodes    int            = 300,   -- 0 = all (the trie walk costs time on large string indexes)
    @MaxSampledScanValues   int            = 20,    -- 0 = all
    -- output-table mode: instead of returning result sets, append each one to
    -- <@OutputDatabase>.<@OutputSchema>.<@OutputTablePrefix><Section> (created on first use)
    @OutputDatabase         sysname        = NULL,
    @OutputSchema           sysname        = N'dbo',
    @OutputTablePrefix      sysname        = N'StatsStream_',
    @CollectionTime         datetime2(3)   = NULL,  -- stamped in [Collected At]; default SYSDATETIME()
    @FlushEvery             int            = 200,   -- output mode: statistics objects buffered before each write
    -- progress messages (RAISERROR ... WITH NOWAIT) every @ProgressSeconds; 0 = none.
    -- @ProgressDone / @ProgressTotal / @ProgressStart let a caller report a server-wide percentage and ETA.
    @ProgressSeconds        int            = 0,
    @ProgressDone           bigint         = 0,
    @ProgressTotal          bigint         = NULL,
    @ProgressStart          datetime2(3)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET TEXTSIZE 2147483647;   -- the sqlcmd/ODBC default (4096) truncates the STATS_STREAM captured by INSERT ... EXEC
    SET ANSI_WARNINGS OFF;     -- the field pivots below would print "Null value is eliminated by an aggregate" many times
    -- Never block the workload: every query (dynamic SQL included) reads uncommitted, and whatever still needs
    -- a lock (DBCC SHOW_STATISTICS takes Sch-S, metadata functions) gives up after 100 ms. The statistics that
    -- time out are skipped and reported in the "Skipped" result set. Both settings revert when the procedure ends.
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    SET LOCK_TIMEOUT 100;

    DECLARE @proc nvarchar(300), @sql nvarchar(max), @msg nvarchar(2048), @callStart datetime2(3) = SYSDATETIME();

    IF @OutputDatabase IS NOT NULL AND (DB_ID(@OutputDatabase) IS NULL OR CHARINDEX(N'''', @OutputDatabase + ISNULL(@OutputSchema, N'') + ISNULL(@OutputTablePrefix, N'')) > 0)
    BEGIN RAISERROR(N'Invalid @OutputDatabase / @OutputSchema / @OutputTablePrefix.', 16, 1); RETURN; END
    SET @CollectionTime = ISNULL(@CollectionTime, SYSDATETIME());
    SET @OutputTablePrefix = ISNULL(@OutputTablePrefix, N'');
    SET @FlushEvery = CASE WHEN @FlushEvery > 0 THEN @FlushEvery ELSE 200 END;
    SET @ProgressStart = ISNULL(@ProgressStart, @callStart);
    DECLARE @outBase nvarchar(400) = CASE WHEN @OutputDatabase IS NOT NULL THEN QUOTENAME(@OutputDatabase) + N'.' + QUOTENAME(ISNULL(@OutputSchema, N'dbo')) + N'.' ELSE N'' END,
            @emitSchema sysname, @emitTable sysname;

    ----------------------------------------------------------------------------
    -- Work tables (created once per call, emptied per statistics object)
    ----------------------------------------------------------------------------
    CREATE TABLE #T (
        seq int IDENTITY PRIMARY KEY, object_id int NULL, schema_name sysname NULL, table_name sysname NULL,
        stats_id int NULL, stats_name sysname NULL, kind nvarchar(80) NULL, auto_created bit NULL, user_created bit NULL,
        no_recompute bit NULL, is_incremental bit NULL, has_filter bit NULL, filter_definition nvarchar(max) NULL,
        is_temporary bit NULL, modification_counter bigint NULL, auto_drop bit NULL, has_persisted_sample bit NULL);
    CREATE TABLE #SS (Stats_Stream varbinary(max) NULL, [Rows] bigint NULL, [Data Pages] bigint NULL);
    -- number table for the row generators (sys.all_columns is a costly view); extended when a trie is larger
    CREATE TABLE #N (n int NOT NULL PRIMARY KEY);
    ;WITH e1(x) AS (SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) v(x)), e3(x) AS (SELECT 1 FROM e1 a CROSS JOIN e1 b CROSS JOIN e1 c)
    INSERT #N (n) SELECT TOP (4096) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM e3;
    -- little-endian field reader: lo = bytes 0..3, hi = bytes 4..7 (unsigned), read straight from @s
    CREATE TABLE #F (
        grp varchar(10) NOT NULL, idx int NOT NULL, sub int NOT NULL, fld varchar(20) NOT NULL,
        ofs int NOT NULL, len int NOT NULL, lo bigint NULL, hi bigint NULL, i bigint NULL, fl float NULL, dt datetime NULL,
        done bit NOT NULL DEFAULT 0, PRIMARY KEY (grp, idx, sub, fld));
    CREATE TABLE #Names (ord int IDENTITY PRIMARY KEY, name sysname NOT NULL);
    CREATE TABLE #CK (ord int IDENTITY PRIMARY KEY, name sysname NOT NULL);
    CREATE TABLE #Cols (
        ordinal int PRIMARY KEY, name sysname NULL, sys_type int, flags int, unused2 int, user_type int, max_length int,
        [precision] int, scale int, extra12 int, collation_id int, unused20 bigint, is_nullable bit, type_name nvarchar(128) NULL,
        collation_name sysname NULL, code_page int NULL);
    CREATE TABLE #Coll (id int PRIMARY KEY, name sysname NOT NULL, cp int NULL);
    CREATE TABLE #Bits (ord int PRIMARY KEY, bit int NOT NULL);
    CREATE TABLE #Items (bit int PRIMARY KEY, ord int, name nvarchar(60), rel_start bigint, rel_end bigint, abs_start bigint, len bigint);
    CREATE TABLE #Steps (
        step int PRIMARY KEY, rs int, re int, statusA int NULL, statusB int NULL, fixedEnd int NULL, ncols int NULL, nb int NULL,
        nullbm int NULL, p int NULL, varCount int NULL, off0 int NULL, keyOff int NULL, keyLen int NULL, keyIsNull bit NULL,
        eq real NULL, rr real NULL, avg_stored real NULL);
    CREATE TABLE #Keys (
        kid int IDENTITY PRIMARY KEY, parent int NULL, step int NULL, sys_type int, user_type int, max_length int, [precision] int,
        scale int, collation_id int, ofs int, len int, bytes varbinary(8000) NULL, gid int NULL,
        a_i bigint NULL, a_f float NULL, a_lo bigint NULL, a_hi bigint NULL, t_u bigint NULL, d_u int NULL, o_i int NULL,
        dec_str varchar(50) NULL, val sql_variant NULL, txt nvarchar(4000) NULL);
    CREATE TABLE #KG (gid int IDENTITY PRIMARY KEY, sys_type int, user_type int, max_length int, [precision] int, scale int, collation_id int);
    CREATE TABLE #Hist (
        step int PRIMARY KEY, RANGE_HI_KEY sql_variant NULL, RANGE_HI_KEY_TEXT nvarchar(4000) NULL, RANGE_ROWS real, EQ_ROWS real,
        DISTINCT_RANGE_ROWS real, AVG_RANGE_ROWS real, StoredAvgRangeRows real NULL, RecordOffset int NULL, RecordLength int NULL,
        KeyBytes varbinary(8000) NULL, IsNullStep bit);
    CREATE TABLE #UH (
        rec int PRIMARY KEY, Updated datetime, TableCardinality float, SnapshotCtr bigint, Steps int, Density float,
        RowsAbove float, RowsBelow float, Inserts float, Deletes float, SqVarErr float);
    CREATE TABLE #TFV (
        rowno int PRIMARY KEY, Updated datetime NULL, [Table Cardinality] float NULL, [Snapshot Ctr] bigint NULL, Steps int NULL,
        Density float NULL, [Rows Above] float NULL, [Rows Below] float NULL, [Squared Variance Error] float NULL,
        [Inserts Since Last Update] float NULL, [Deletes Since Last Update] float NULL, [Leading column Type] nvarchar(20) NULL,
        [Snapshot Ctr Source] nvarchar(80) NULL);
    CREATE TABLE #DV (vec int PRIMARY KEY, AllDensity real NULL, AverageLength real NULL, ColumnAverageLength real NULL, Columns nvarchar(max) NULL);
    CREATE TABLE #SIN (
        NodeIndex int PRIMARY KEY, Depth int NULL, Flags int, [Count] int, HasChildren bit, HasSibling bit, SegmentOffset int,
        SegmentLength int, Segment nvarchar(4000), FullText nvarchar(max) NULL, RecordOffset bigint NULL, RecordLength int NULL);
    CREATE TABLE #SD (vec int, j int, v float, PRIMARY KEY (vec, j));
    CREATE TABLE #Unk (Item nvarchar(40), StreamOffset bigint, Length bigint, Hex varbinary(max));
    CREATE TABLE #Skipped (seq int IDENTITY PRIMARY KEY, db sysname NULL, schema_name sysname NULL, table_name nvarchar(776) NULL,
        stats_name sysname NULL, object_id int NULL, stats_id int NULL, stage nvarchar(80), error_number int, error_message nvarchar(4000));
    CREATE TABLE #Val (seq int IDENTITY PRIMARY KEY, [Check] nvarchar(200), [Server] nvarchar(max), [Decoded] nvarchar(max), Result varchar(10));
    CREATE TABLE #VH (Name sysname NULL, Updated datetime NULL, [Rows] bigint NULL, [Rows Sampled] bigint NULL, Steps int NULL, Density real NULL,
        [Average key length] real NULL, [String Index] varchar(3) NULL, [Filter Expression] nvarchar(max) NULL, [Unfiltered Rows] bigint NULL,
        [Persisted Sample Percent] float NULL);
    CREATE TABLE #VD (n int IDENTITY PRIMARY KEY, [All density] real NULL, [Average Length] real NULL, [Columns] nvarchar(max) NULL);
    CREATE TABLE #VHist (step int PRIMARY KEY, k sql_variant NULL, rr real NULL, eq real NULL, dr bigint NULL, ar real NULL);
    CREATE TABLE #TFRaw (rowno int IDENTITY PRIMARY KEY, Updated datetime NULL, [Table Cardinality] float NULL, [Snapshot Ctr] bigint NULL, Steps int NULL,
        Density float NULL, [Rows Above] float NULL, [Rows Below] float NULL, [Squared Variance Error] float NULL,
        [Inserts Since Last Update] float NULL, [Deletes Since Last Update] float NULL, [Leading column Type] nvarchar(20) NULL);
    CREATE TABLE #TF (seq int, rowno int, Updated datetime NULL, [Table Cardinality] float NULL, [Snapshot Ctr] bigint NULL, Steps int NULL,
        Density float NULL, [Rows Above] float NULL, [Rows Below] float NULL, [Squared Variance Error] float NULL,
        [Inserts Since Last Update] float NULL, [Deletes Since Last Update] float NULL, [Leading column Type] nvarchar(20) NULL,
        PRIMARY KEY (seq, rowno));

    ----------------------------------------------------------------------------
    -- Result staging tables: created once with fixed schemas (no per-statistics SELECT INTO / DROP,
    -- which made SQL Server recompile every statement for every statistics object). The first five
    -- columns identify the statistics object; client mode returns the rest.
    ----------------------------------------------------------------------------
    CREATE TABLE #rs1 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), Kind nvarchar(80), [Database] sysname NULL, [Schema] sysname NULL, [Table] sysname NULL,
        [Stats Name] sysname NULL, [Stats Id] int, [Auto Created] bit, [User Created] bit, [No Recompute] bit, [Incremental] bit, [Temporary] bit,
        [Filter] nvarchar(max), [Modification Counter] bigint, [Auto Drop] bit, [Has Persisted Sample] bit, Warnings nvarchar(max), StatsStream varbinary(max));
    CREATE TABLE #rs2 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Stream Version] int, [Number Of Columns] int, [Checksum] binary(4), [Checksum Status] varchar(11),
        [Calculated Checksum] binary(4), [Stream Length] bigint, [Actual Length] int, [Blob Length] bigint, [Reserved 8-15] bigint, [Reserved 20-23] bigint);
    CREATE TABLE #rs3 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [#] int, [Name] sysname NULL, [Type] nvarchar(128), [System Type Id] int, [User Type Id] int,
        [Max Length] int, [Precision] int, [Scale] int, [Nullable] bit, [Flags] binary(1), [Collation Id] binary(4), [Collation] sysname NULL, [Code Page] int,
        [Bytes 12-15] int, [Bytes 2-3 (unused)] binary(2), [Bytes 20-23 (unused)] binary(4));
    CREATE TABLE #rs4 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Blob Version] int, [Updated] datetime, [Rows] bigint, [Rows Sampled] bigint, [Sample Percent] decimal(19, 4),
        [Scan] varchar(8), [Density] real, [Steps (stored)] int, [Steps (DBCC)] int, [Steps (second copy)] int, [Vector Count] int, [Histogram Fixed Length] int,
        [Average Key Length] real, [Rows (real copy)] real, [NULL Step EQ_ROWS] real, [Unfiltered Rows] bigint, [Pages Sampled] bigint,
        [Table Pages (current)] bigint, [Pages Sampled Percent] decimal(19, 4), [Persisted Sample Percent] float, [String Index] varchar(3),
        [Leading Column Type] nvarchar(20), [Presence Bitmask] binary(8), [Columnstore Page Counts] nvarchar(max), [Streaming Statistics Flags] bigint);
    CREATE TABLE #rs5 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Bit] int, [Name] nvarchar(60), [Relative Offset] bigint, [Stream Offset] bigint, [Length] bigint);
    CREATE TABLE #rs6 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Vector] int, [All density] real, [Average Length] real, [Column Average Length (stored)] real, Columns nvarchar(max));
    CREATE TABLE #rs7 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Step] int, RANGE_HI_KEY sql_variant, RANGE_HI_KEY_TEXT nvarchar(4000), RANGE_ROWS real, EQ_ROWS real,
        DISTINCT_RANGE_ROWS real, AVG_RANGE_ROWS real, [Stored AVG_RANGE_ROWS] real, [Record Offset] int, [Record Length] int, [Key Bytes] varbinary(8000));
    CREATE TABLE #rs8 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Record] int, Updated datetime, [Table Cardinality] float, [Snapshot Ctr] bigint, Steps int, Density float,
        [Next: Rows Above] float, [Next: Rows Below] float, [Next: Inserts] float, [Next: Deletes] float, [Next: Squared Variance Error] float);
    CREATE TABLE #rs9 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Row] int, Updated datetime, [Table Cardinality] float, [Snapshot Ctr] bigint, Steps int, Density float,
        [Rows Above] float, [Rows Below] float, [Squared Variance Error] float, [Inserts Since Last Update] float, [Deletes Since Last Update] float,
        [Leading column Type] nvarchar(20), [Snapshot Ctr Source] nvarchar(80));
    CREATE TABLE #rs10 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Strings Sampled (incl. NULL)] bigint, [NULLs In Sample] bigint, [Distinct Strings] bigint,
        [Sum Of Node Counts] bigint, [Compressed Length (chars)] bigint, [Node Count] bigint, [Trie Marker] binary(1), [Trie Version] bigint,
        [Full Prefix] bigint, [Full Suffix] bigint, [Unused +25] bigint, [Compressed String] nvarchar(max), [Trailer] varbinary(max));
    CREATE TABLE #rs11 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Node] int, Depth int, [Tree] nvarchar(max), [Strings Ending Here] int, [String] nvarchar(max),
        Flags binary(1), [Has Children] bit, [Has Sibling] bit, [Segment Offset] int, [Segment Length] int, Segment nvarchar(4000), [Full Text] nvarchar(max));
    CREATE TABLE #rs12 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Vector] int, [Offset] bigint, [Count] bigint, [Sum] float, [Min] float, [Max] float, [Values] nvarchar(max),
        [Distinct In Sample] float);
    CREATE TABLE #rs13 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), Item nvarchar(40), [Stream Offset] bigint, Length bigint, Hex varbinary(max));
    CREATE TABLE #rs14 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Offset] int, [Offset Hex] binary(4), [Length] int, [Field] varchar(100), [Bytes] varbinary(8000),
        [Integer] bigint, [Float] float, [Datetime] datetime);
    CREATE TABLE #rs15 ([Collected At] datetime2(3), [Database Name] sysname NULL, [Schema Name] sysname NULL, [Table Name] sysname NULL, [Statistics Name] sysname NULL,
        Section nvarchar(30), [Statistic] nvarchar(1000), [Check #] int, [Check] nvarchar(200), [Server] nvarchar(max), [Decoded] nvarchar(max), Result varchar(10));

    -- output mode: one statement that appends every staging table to its output table and empties it
    -- skipped statistics are reported as they happen: a SKIPPED message (first 50 per call) and, in output
    -- mode, an immediate write to <prefix>Skipped (@skipSql appends the rows not written yet)
    DECLARE @skipSql nvarchar(max) = NULL, @skipWritten int = 0, @skipPrintedSeq int = 0, @skipPrinted int = 0;
    IF @OutputDatabase IS NOT NULL
        SET @skipSql = REPLACE(N'
IF OBJECT_ID(N''{X}'') IS NULL
    SELECT CAST(NULL AS datetime2(3)) AS [Collected At], db AS [Database Name], schema_name AS [Schema Name], table_name AS [Table Name],
           stats_name AS [Statistics Name], object_id AS [Object Id], stats_id AS [Stats Id], stage AS [Stage],
           error_number AS [Error Number], error_message AS [Error Message]
    INTO {X} FROM #Skipped WHERE 1 = 0;
INSERT INTO {X}
SELECT @at, db, schema_name, table_name, stats_name, object_id, stats_id, stage, error_number, error_message FROM #Skipped WHERE seq > @last ORDER BY seq;
SELECT @lastOut = ISNULL(MAX(seq), @last) FROM #Skipped;',
            N'{X}', @outBase + QUOTENAME(@OutputTablePrefix + N'Skipped'));

    DECLARE @flushSql nvarchar(max) = N'', @pending int = 0;
    IF @OutputDatabase IS NOT NULL
        SELECT @flushSql += N'
IF EXISTS (SELECT 1 FROM ' + t.tmp + N')
BEGIN
    IF OBJECT_ID(N''' + @outBase + QUOTENAME(@OutputTablePrefix + t.sect) + N''') IS NULL
        SELECT TOP (0) * INTO ' + @outBase + QUOTENAME(@OutputTablePrefix + t.sect) + N' FROM ' + t.tmp + N';
    INSERT INTO ' + @outBase + QUOTENAME(@OutputTablePrefix + t.sect) + N' SELECT * FROM ' + t.tmp + N';
    TRUNCATE TABLE ' + t.tmp + N';
END'
        FROM (VALUES (N'#rs1', N'Statistics'), (N'#rs2', N'StreamHeader'), (N'#rs3', N'StatsColumns'), (N'#rs4', N'BlobHeader'),
                     (N'#rs5', N'VariableItems'), (N'#rs6', N'DensityVector'), (N'#rs7', N'Histogram'), (N'#rs8', N'UpdateHistory'),
                     (N'#rs9', N'TraceFlag2388'), (N'#rs10', N'StringIndex'), (N'#rs11', N'StringIndexNodes'), (N'#rs12', N'SampledScanDump'),
                     (N'#rs13', N'UnknownItems'), (N'#rs14', N'Layout'), (N'#rs15', N'Validation')) t(tmp, sect);

    -- Field calculator, run after every batch of #F inserts: one pass, bytes read straight from @s
    DECLARE @calc nvarchar(max) = N'
UPDATE f SET lo = x.lo, hi = x.hi,
    i = CASE f.len WHEN 1 THEN x.lo
                   WHEN 2 THEN CASE WHEN x.lo >= 32768 THEN x.lo - 65536 ELSE x.lo END
                   WHEN 3 THEN x.lo
                   WHEN 4 THEN CASE WHEN x.lo >= 2147483648 THEN x.lo - 4294967296 ELSE x.lo END
                   WHEN 8 THEN (CASE WHEN x.hi >= 2147483648 THEN x.hi - 4294967296 ELSE x.hi END) * 4294967296 + x.lo
                   ELSE x.lo + x.hi * 4294967296 END,
    fl = CASE f.len
           WHEN 4 THEN CASE WHEN (x.lo / 8388608) % 256 = 255 THEN NULL
                            ELSE (1 - 2 * (x.lo / CAST(2147483648 AS bigint))) *
                                 CASE WHEN (x.lo / 8388608) % 256 = 0 THEN CAST(x.lo % 8388608 AS float) * POWER(CAST(2 AS float), -149)
                                      ELSE CAST(8388608 + x.lo % 8388608 AS float) * POWER(CAST(2 AS float), (x.lo / 8388608) % 256 - 150) END END
           WHEN 8 THEN CASE WHEN (x.hi / 1048576) % 2048 = 2047 THEN NULL
                            ELSE (1 - 2 * (x.hi / CAST(2147483648 AS bigint))) *
                                 CASE WHEN (x.hi / 1048576) % 2048 = 0 THEN CAST((x.hi % 1048576) * 4294967296 + x.lo AS float) * POWER(CAST(2 AS float), -1074)
                                      ELSE CAST(4503599627370496 + (x.hi % 1048576) * 4294967296 + x.lo AS float) * POWER(CAST(2 AS float), (x.hi / 1048576) % 2048 - 1075) END END
         END,
    dt = CASE WHEN f.len = 8 AND f.grp IN (''b'', ''u'') THEN
              TRY_CAST(CONVERT(binary(4), CAST(CASE WHEN x.hi >= 2147483648 THEN x.hi - 4294967296 ELSE x.hi END AS int)) +
                       CONVERT(binary(4), CAST(CASE WHEN x.lo >= 2147483648 THEN x.lo - 4294967296 ELSE x.lo END AS int)) AS datetime) END,
    done = 1
FROM #F f
CROSS APPLY (SELECT
      CASE WHEN f.len > 0 THEN CAST(SUBSTRING(@s, f.ofs + 1, 1) AS bigint) ELSE 0 END
    + CASE WHEN f.len > 1 THEN CAST(SUBSTRING(@s, f.ofs + 2, 1) AS bigint) * 256 ELSE 0 END
    + CASE WHEN f.len > 2 THEN CAST(SUBSTRING(@s, f.ofs + 3, 1) AS bigint) * 65536 ELSE 0 END
    + CASE WHEN f.len > 3 THEN CAST(SUBSTRING(@s, f.ofs + 4, 1) AS bigint) * 16777216 ELSE 0 END AS lo,
      CASE WHEN f.len > 4 THEN CAST(SUBSTRING(@s, f.ofs + 5, 1) AS bigint) ELSE 0 END
    + CASE WHEN f.len > 5 THEN CAST(SUBSTRING(@s, f.ofs + 6, 1) AS bigint) * 256 ELSE 0 END
    + CASE WHEN f.len > 6 THEN CAST(SUBSTRING(@s, f.ofs + 7, 1) AS bigint) * 65536 ELSE 0 END
    + CASE WHEN f.len > 7 THEN CAST(SUBSTRING(@s, f.ofs + 8, 1) AS bigint) * 16777216 ELSE 0 END AS hi) x
WHERE f.done = 0;';

    ----------------------------------------------------------------------------
    -- Targets
    ----------------------------------------------------------------------------
    IF @DatabaseName IS NULL SET @DatabaseName = DB_NAME();
    IF DB_ID(@DatabaseName) IS NULL BEGIN RAISERROR(N'Database %s not found.', 16, 1, @DatabaseName); RETURN; END
    SET @proc = QUOTENAME(@DatabaseName) + N'.sys.sp_executesql';

    -- One statistics object at a time through a cursor (no ORDER BY, so it stays a dynamic cursor and reads
    -- row by row): a row that cannot be read within the lock timeout is logged in #Skipped and the rest continue.
    -- Without @TableName, Microsoft-shipped objects are left out.
    SET @sql = N'
DECLARE @oid int = NULL, @o int, @st int, @fetchErrors int = 0;
IF @t IS NOT NULL
BEGIN
    SET @oid = OBJECT_ID(@t);
    IF @oid IS NULL RETURN;
END
DECLARE c CURSOR LOCAL FORWARD_ONLY READ_ONLY FOR
    SELECT object_id, stats_id FROM sys.stats WHERE (@oid IS NULL OR object_id = @oid) AND (@s IS NULL OR name = @s);
OPEN c;
WHILE 1 = 1
BEGIN
    BEGIN TRY
        FETCH NEXT FROM c INTO @o, @st;
    END TRY
    BEGIN CATCH
        INSERT #Skipped (db, table_name, stage, error_number, error_message)
        VALUES (DB_NAME(), @t, N''enumerate statistics (FETCH)'', ERROR_NUMBER(), ERROR_MESSAGE());
        SET @fetchErrors += 1;
        IF @fetchErrors >= 5 BREAK;
        CONTINUE;
    END CATCH
    IF @@FETCH_STATUS <> 0 BREAK;
    SET @fetchErrors = 0;
    BEGIN TRY
        INSERT #T (object_id, schema_name, table_name, stats_id, stats_name, kind, auto_created, user_created, no_recompute,
                   is_incremental, has_filter, filter_definition, is_temporary, modification_counter, auto_drop, has_persisted_sample)
        SELECT s.object_id, sc.name, o.name, s.stats_id, s.name,
               CASE WHEN i.index_id IS NULL THEN N''column statistics'' ELSE N''index statistics ('' + i.type_desc COLLATE DATABASE_DEFAULT + N'')'' END,
               s.auto_created, s.user_created, s.no_recompute, s.is_incremental, s.has_filter, s.filter_definition, s.is_temporary,
               sp.modification_counter, ' +
            CASE WHEN COL_LENGTH(N'sys.stats', N'auto_drop') IS NOT NULL THEN N's.auto_drop' ELSE N'NULL' END + N', ' +
            CASE WHEN COL_LENGTH(N'sys.stats', N'has_persisted_sample') IS NOT NULL THEN N's.has_persisted_sample' ELSE N'NULL' END + N'
        FROM sys.stats s
        JOIN sys.objects o ON o.object_id = s.object_id
        JOIN sys.schemas sc ON sc.schema_id = o.schema_id
        LEFT JOIN sys.indexes i ON i.object_id = s.object_id AND i.index_id = s.stats_id
        OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
        WHERE s.object_id = @o AND s.stats_id = @st AND o.type IN (''U'', ''V'') AND (@t IS NOT NULL OR o.is_ms_shipped = 0);
    END TRY
    BEGIN CATCH
        INSERT #Skipped (db, table_name, object_id, stats_id, stage, error_number, error_message)
        VALUES (DB_NAME(), @t, @o, @st, N''read statistics metadata'', ERROR_NUMBER(), ERROR_MESSAGE());
    END CATCH
END
CLOSE c;
DEALLOCATE c;';
    BEGIN TRY
        EXEC @proc @sql, N'@t nvarchar(776), @s sysname', @TableName, @StatsName;
    END TRY
    BEGIN CATCH
        -- e.g. OBJECT_ID() waiting on a schema change in progress
        INSERT #Skipped (db, table_name, stats_name, stage, error_number, error_message)
        VALUES (@DatabaseName, @TableName, @StatsName, N'resolve table / enumerate statistics', ERROR_NUMBER(), ERROR_MESSAGE());
    END CATCH

    IF NOT EXISTS (SELECT 1 FROM #T) AND NOT EXISTS (SELECT 1 FROM #Skipped) AND (@TableName IS NOT NULL OR @StatsName IS NOT NULL)
    BEGIN
        SET @msg = N'No statistics found for table ' + ISNULL(@TableName, N'(any)') + N', statistics ' + ISNULL(@StatsName, N'(any)') + N' in database ' + @DatabaseName + N'.';
        RAISERROR(@msg, 16, 1); RETURN;
    END

    -- sys.sysobjvalues (current Snapshot Ctr) is only visible over the DAC: probe once per call
    -- statistics skipped while enumerating still count as done for the progress percentage
    DECLARE @enumSkipped int = (SELECT COUNT(*) FROM #Skipped WHERE stats_id IS NOT NULL);
    DECLARE @dacOk bit = 0;
    BEGIN TRY
        EXEC @proc N'DECLARE @x int; SELECT @x = 1 FROM sys.sysobjvalues WHERE 1 = 0;';
        SET @dacOk = 1;
    END TRY
    BEGIN CATCH SET @dacOk = 0; END CATCH

    ----------------------------------------------------------------------------
    -- Optional: trace flag 2388 output, captured once (each TRACEON/OFF writes to the ERRORLOG)
    ----------------------------------------------------------------------------
    DECLARE @tfStatus nvarchar(400) = NULL, @seq int, @qt nvarchar(600), @sn sysname, @maxSeq int = (SELECT ISNULL(MAX(seq), 0) FROM #T);
    IF @Validate = 1
    BEGIN
        IF IS_SRVROLEMEMBER(N'sysadmin') = 1
        BEGIN
            BEGIN TRY
                DBCC TRACEON(2388) WITH NO_INFOMSGS;
                SET @seq = 1;
                WHILE @seq <= @maxSeq
                BEGIN
                    SELECT @qt = QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name), @sn = stats_name FROM #T WHERE seq = @seq;
                    TRUNCATE TABLE #TFRaw;
                    BEGIN TRY
                        INSERT #TFRaw (Updated, [Table Cardinality], [Snapshot Ctr], Steps, Density, [Rows Above], [Rows Below], [Squared Variance Error],
                                       [Inserts Since Last Update], [Deletes Since Last Update], [Leading column Type])
                        EXEC @proc N'DBCC SHOW_STATISTICS(@t, @s) WITH NO_INFOMSGS', N'@t nvarchar(600), @s sysname', @qt, @sn;
                        INSERT #TF SELECT @seq, rowno, Updated, [Table Cardinality], [Snapshot Ctr], Steps, Density, [Rows Above], [Rows Below],
                                          [Squared Variance Error], [Inserts Since Last Update], [Deletes Since Last Update], [Leading column Type]
                                   FROM #TFRaw;
                    END TRY
                    BEGIN CATCH END CATCH;
                    SET @seq += 1;
                END
                DBCC TRACEOFF(2388) WITH NO_INFOMSGS;
            END TRY
            BEGIN CATCH
                SET @tfStatus = ERROR_MESSAGE();
                BEGIN TRY DBCC TRACEOFF(2388) WITH NO_INFOMSGS; END TRY BEGIN CATCH END CATCH;
            END CATCH
        END
        ELSE SET @tfStatus = N'requires sysadmin (session-level DBCC TRACEON)';
    END

    ----------------------------------------------------------------------------
    -- CRC-32 table (reflected polynomial 0xEDB88320), 4 bytes per entry, big-endian
    ----------------------------------------------------------------------------
    DECLARE @crcTab varbinary(1024) = 0x, @n int = 0, @k int, @c bigint;
    IF @VerifyChecksum = 1
        WHILE @n < 256
        BEGIN
            SELECT @c = @n, @k = 0;
            WHILE @k < 8
            BEGIN
                SET @c = CASE WHEN @c & 1 = 1 THEN CAST(3988292384 AS bigint) ^ (@c / 2) ELSE @c / 2 END;
                SET @k += 1;
            END
            SET @crcTab = @crcTab + CONVERT(binary(4), CAST(CASE WHEN @c >= 2147483648 THEN @c - 4294967296 ELSE @c END AS int));
            SET @n += 1;
        END

    ----------------------------------------------------------------------------
    -- Per statistics object
    ----------------------------------------------------------------------------
    DECLARE @s varbinary(max), @len int, @objId int, @statsId int, @statName sysname, @label nvarchar(1000),
            @ncols int, @hdrVer int, @crcStored bigint, @crcCalc bigint, @slen bigint, @blen bigint, @res8 bigint, @res20 bigint,
            @B int, @bver int, @updated datetime, @rows bigint, @rowsSampled bigint, @density real, @steps int, @steps2 int,
            @vc int, @mrs int, @akl real, @rowsReal real, @nullEq real, @maskLo bigint, @maskHi bigint, @nbits int,
            @varBase bigint, @varEnd bigint, @H bigint, @itemEnd bigint, @byte int, @i int, @crc bigint,
            @unfiltered bigint, @pages bigint, @persisted float, @leading nvarchar(20), @snap bigint, @snapSrc nvarchar(80),
            @csCount bigint, @csPages nvarchar(max), @streamFlags bigint,
            @SI bigint, @siLen int, @cs int, @nodeCount int, @nodeBase bigint, @nodeEnd bigint, @walk int, @cstr nvarchar(max), @keyColl sysname, @csb varbinary(max),
            @U bigint, @uhCount int, @uhSize int, @SD bigint, @g int, @T nvarchar(200), @expr nvarchar(max), @style int,
            @gtype int, @guser int, @gmax int, @gprec int, @gscale int, @gcoll int, @gcollName sysname, @hasSI bit,
            @warn nvarchar(max), @qtable nvarchar(600), @tablePages bigint, @stage nvarchar(80),
            @lastProgress datetime2(3) = SYSDATETIME(), @pDone bigint, @pTotal bigint, @elapsedS bigint, @remainS bigint;

    SET @seq = 1;
    WHILE @seq <= @maxSeq
    BEGIN
        TRUNCATE TABLE #F; TRUNCATE TABLE #Names; TRUNCATE TABLE #Cols; TRUNCATE TABLE #Bits; TRUNCATE TABLE #Items;
        TRUNCATE TABLE #Steps; TRUNCATE TABLE #Keys; TRUNCATE TABLE #KG; TRUNCATE TABLE #Hist; TRUNCATE TABLE #UH; TRUNCATE TABLE #TFV;
        TRUNCATE TABLE #DV; TRUNCATE TABLE #SIN; TRUNCATE TABLE #SD; TRUNCATE TABLE #Unk; TRUNCATE TABLE #Val; TRUNCATE TABLE #SS;
        SELECT @warn = N'', @unfiltered = NULL, @pages = NULL, @tablePages = NULL, @persisted = NULL, @leading = N'Unknown', @snap = NULL, @cstr = NULL,
               @SI = NULL, @hasSI = 0, @B = NULL, @bver = NULL, @updated = NULL, @rows = NULL, @rowsSampled = NULL, @density = NULL,
               @steps = 0, @steps2 = NULL, @vc = 0, @mrs = NULL, @akl = NULL, @rowsReal = NULL, @nullEq = 0, @maskLo = NULL, @maskHi = NULL,
               @s = NULL, @crcCalc = NULL, @nodeBase = NULL, @nodeEnd = NULL, @nodeCount = NULL, @itemEnd = NULL, @walk = NULL, @stage = N'start',
               @csCount = NULL, @csPages = NULL, @streamFlags = NULL;

        SELECT @objId = object_id, @statsId = stats_id, @statName = stats_name,
               @qtable = QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name), @emitSchema = schema_name, @emitTable = table_name
        FROM #T WHERE seq = @seq;
        SET @label = QUOTENAME(@DatabaseName) + N'.' + @qtable + N'.' + QUOTENAME(@statName);

        BEGIN TRY
            -- the statistics stream (needs Sch-S on the table: times out while a schema change holds Sch-M)
            SET @stage = N'DBCC SHOW_STATISTICS WITH STATS_STREAM';
            INSERT #SS EXEC @proc N'DBCC SHOW_STATISTICS(@t, @s) WITH STATS_STREAM, NO_INFOMSGS', N'@t nvarchar(600), @s sysname', @qtable, @statName;
            SELECT TOP (1) @s = Stats_Stream FROM #SS;
            SET @stage = N'decode';

            -- current Snapshot Ctr: only readable over the DAC (sys.sysobjvalues); otherwise estimated later
            IF @dacOk = 1
            BEGIN
            BEGIN TRY
                EXEC @proc N'SELECT TOP (1) @v = CAST(value AS bigint) FROM sys.sysobjvalues WHERE valclass = 60 AND objid = @o AND subobjid = @st ORDER BY valnum;',
                     N'@o int, @st int, @v bigint OUTPUT', @objId, @statsId, @snap OUTPUT;
            END TRY
            BEGIN CATCH SET @snap = NULL; END CATCH
            END
            -- current in-row data pages of the structure sampled by UPDATE STATISTICS: the index itself
            -- for index statistics, otherwise the heap / clustered index (all partitions)
            BEGIN TRY
                EXEC @proc N'
SELECT @p = SUM(au.data_pages)
FROM sys.partitions p
JOIN sys.allocation_units au ON au.container_id = p.partition_id AND au.type = 1   -- IN_ROW_DATA
WHERE p.object_id = @o
  AND p.index_id = CASE WHEN @st > 1 AND EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = @o AND i.index_id = @st) THEN @st
                        ELSE (SELECT MIN(i.index_id) FROM sys.indexes i WHERE i.object_id = @o AND i.index_id IN (0, 1)) END;',
                     N'@o int, @st int, @p bigint OUTPUT', @objId, @statsId, @tablePages OUTPUT;
            END TRY
            BEGIN CATCH SET @tablePages = NULL; END CATCH

            SET @len = ISNULL(DATALENGTH(@s), 0);
            IF @len < 40
            BEGIN
                SET @msg = N'STATS_STREAM is too short (' + CAST(@len AS nvarchar(20)) + N' bytes).';
                RAISERROR(@msg, 16, 1);
            END

            --------------------------------------------------------------------
            -- Stream header (40 bytes)
            --------------------------------------------------------------------
            INSERT #F (grp, idx, sub, fld, ofs, len) VALUES
                ('h',0,0,'ver',0,4), ('h',0,0,'ncols',4,4), ('h',0,0,'res8',8,8), ('h',0,0,'crc',16,4),
                ('h',0,0,'res20',20,4), ('h',0,0,'slen',24,8), ('h',0,0,'blen',32,8);
            EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
            SELECT @hdrVer = MAX(CASE fld WHEN 'ver' THEN i END), @ncols = MAX(CASE fld WHEN 'ncols' THEN i END),
                   @res8 = MAX(CASE fld WHEN 'res8' THEN i END), @crcStored = MAX(CASE fld WHEN 'crc' THEN lo END),
                   @res20 = MAX(CASE fld WHEN 'res20' THEN i END), @slen = MAX(CASE fld WHEN 'slen' THEN i END),
                   @blen = MAX(CASE fld WHEN 'blen' THEN i END)
            FROM #F WHERE grp = 'h';

            -- checksum: ~CRC32 with bytes 16..19 zeroed == CRC loop without the final xor
            IF @VerifyChecksum = 1
            BEGIN
                SELECT @crc = 4294967295, @i = 0;
                WHILE @i < @len
                BEGIN
                    SET @byte = CASE WHEN @i BETWEEN 16 AND 19 THEN 0 ELSE CAST(SUBSTRING(@s, @i + 1, 1) AS int) END;
                    SET @crc = CAST(SUBSTRING(@crcTab, ((@crc ^ @byte) & 255) * 4 + 1, 4) AS bigint) ^ (@crc / 256);
                    SET @i += 1;
                END
                SET @crcCalc = @crc;
            END

            --------------------------------------------------------------------
            -- Column definitions (24 bytes each)
            --------------------------------------------------------------------
            ;WITH c AS (SELECT TOP (@ncols) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM #N)
            INSERT #F (grp, idx, sub, fld, ofs, len)
            SELECT 'c', c.n, 0, f.fld, 40 + 24 * (c.n - 1) + f.o, f.l
            FROM c CROSS JOIN (VALUES ('type',0,1),('flags',1,1),('unused2',2,2),('utype',4,4),('maxlen',8,2),('prec',10,1),
                                      ('scale',11,1),('extra12',12,4),('coll',16,4),('unused20',20,4)) f(fld, o, l);
            EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
            INSERT #Cols (ordinal, sys_type, flags, unused2, user_type, max_length, [precision], scale, extra12, collation_id, unused20, is_nullable)
            SELECT idx, MAX(CASE fld WHEN 'type' THEN i END), MAX(CASE fld WHEN 'flags' THEN i END), MAX(CASE fld WHEN 'unused2' THEN i END),
                   MAX(CASE fld WHEN 'utype' THEN i END), MAX(CASE fld WHEN 'maxlen' THEN i END), MAX(CASE fld WHEN 'prec' THEN i END),
                   MAX(CASE fld WHEN 'scale' THEN i END), MAX(CASE fld WHEN 'extra12' THEN i END), MAX(CASE fld WHEN 'coll' THEN i END),
                   MAX(CASE fld WHEN 'unused20' THEN lo END), CASE WHEN MAX(CASE fld WHEN 'flags' THEN i END) & 1 = 1 THEN 0 ELSE 1 END
            FROM #F WHERE grp = 'c' GROUP BY idx;

            -- column names (on a lock timeout the decode continues with Column1..N); an index's columns
            -- follow key_ordinal, as the stream does (sys.stats_columns lists them in index_column_id order)
            BEGIN TRY
                INSERT #Names (name) EXEC @proc N'
SELECT c.name FROM sys.stats_columns sc JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
LEFT JOIN sys.index_columns ic ON ic.object_id = sc.object_id AND ic.index_id = sc.stats_id AND ic.column_id = sc.column_id AND ic.key_ordinal > 0
WHERE sc.object_id = @o AND sc.stats_id = @st ORDER BY COALESCE(ic.key_ordinal, sc.stats_column_id);', N'@o int, @st int', @objId, @statsId;
                IF (SELECT COUNT(*) FROM #Names) < @ncols
                BEGIN
                    -- nonclustered index statistics carry the clustering key as trailing columns
                    TRUNCATE TABLE #CK;
                    INSERT #CK (name) EXEC @proc N'
SELECT c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
WHERE ic.object_id = @o AND i.type = 1 AND ic.key_ordinal > 0 ORDER BY ic.key_ordinal;', N'@o int', @objId;
                    INSERT #Names (name) SELECT name FROM #CK k WHERE NOT EXISTS (SELECT 1 FROM #Names n WHERE n.name = k.name) ORDER BY ord;
                END
            END TRY
            BEGIN CATCH
                SET @warn += N'Column names unavailable (' + ERROR_MESSAGE() + N'). ';
            END CATCH
            UPDATE c SET name = ISNULL(n.name, N'Column' + CAST(c.ordinal AS nvarchar(10))) FROM #Cols c LEFT JOIN #Names n ON n.ord = c.ordinal;

            -- collations: COLLATIONPROPERTYFROMID, cached for the whole call; fn_helpcollations scan only as a fallback
            INSERT #Coll (id, name, cp)
            SELECT x.id, x.name, CAST(COLLATIONPROPERTY(x.name, 'CodePage') AS int)
            FROM (SELECT DISTINCT collation_id AS id, CAST(COLLATIONPROPERTYFROMID(collation_id, 'Name') AS sysname) AS name
                  FROM #Cols WHERE collation_id <> 0 AND collation_id NOT IN (SELECT id FROM #Coll)) x
            WHERE x.name IS NOT NULL;
            IF EXISTS (SELECT 1 FROM #Cols WHERE collation_id <> 0 AND collation_id NOT IN (SELECT id FROM #Coll))
                INSERT #Coll (id, name, cp)
                SELECT CAST(COLLATIONPROPERTY(h.name, 'CollationId') AS int), h.name, CAST(COLLATIONPROPERTY(h.name, 'CodePage') AS int)
                FROM sys.fn_helpcollations() h
                WHERE CAST(COLLATIONPROPERTY(h.name, 'CollationId') AS int) IN (SELECT collation_id FROM #Cols WHERE collation_id <> 0)
                  AND CAST(COLLATIONPROPERTY(h.name, 'CollationId') AS int) NOT IN (SELECT id FROM #Coll);
            UPDATE c SET collation_name = l.name, code_page = l.cp FROM #Cols c JOIN #Coll l ON l.id = c.collation_id;
            UPDATE #Cols SET type_name =
                CASE WHEN sys_type = 240 AND user_type = 128 THEN N'hierarchyid'
                     WHEN sys_type = 240 AND user_type = 129 THEN N'geometry'
                     WHEN sys_type = 240 AND user_type = 130 THEN N'geography'
                     ELSE ISNULL(TYPE_NAME(sys_type), N'type' + CAST(sys_type AS nvarchar(10))) END +
                CASE WHEN sys_type IN (167, 175, 165, 173) THEN CASE WHEN max_length = -1 THEN N'(max)' ELSE N'(' + CAST(max_length AS nvarchar(10)) + N')' END
                     WHEN sys_type IN (231, 239) THEN CASE WHEN max_length = -1 THEN N'(max)' ELSE N'(' + CAST(max_length / 2 AS nvarchar(10)) + N')' END
                     WHEN sys_type IN (106, 108) THEN N'(' + CAST([precision] AS nvarchar(10)) + N',' + CAST(scale AS nvarchar(10)) + N')'
                     WHEN sys_type IN (41, 42, 43) THEN N'(' + CAST(scale AS nvarchar(10)) + N')'
                     WHEN sys_type = 62 AND max_length = 4 THEN N'(24)'
                     ELSE N'' END;

            SET @B = 40 + 24 * @ncols;

            --------------------------------------------------------------------
            -- Stats blob
            --------------------------------------------------------------------
            IF @blen > 0 AND @len > @B
            BEGIN
                INSERT #F (grp, idx, sub, fld, ofs, len) VALUES
                    ('b',0,0,'ver',@B,4), ('b',0,0,'updated',@B+4,8), ('b',0,0,'rows',@B+12,8), ('b',0,0,'sampled',@B+20,8),
                    ('b',0,0,'density',@B+28,4), ('b',0,0,'steps',@B+164,4), ('b',0,0,'steps2',@B+168,4), ('b',0,0,'vc',@B+172,4),
                    ('b',0,0,'mrs',@B+176,4), ('b',0,0,'akl',@B+180,4), ('b',0,0,'rowsreal',@B+184,4), ('b',0,0,'nulleq',@B+188,4),
                    ('b',0,0,'mask',@B+324,8);
                ;WITH v AS (SELECT TOP (33) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM #N)
                INSERT #F (grp, idx, sub, fld, ofs, len)
                SELECT 'd', n, 0, 'dens', @B + 32 + 4 * (n - 1), 4 FROM v
                UNION ALL SELECT 'd', n, 0, 'len', @B + 192 + 4 * (n - 1), 4 FROM v;
                EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;

                SELECT @bver = MAX(CASE fld WHEN 'ver' THEN i END), @updated = MAX(CASE fld WHEN 'updated' THEN dt END),
                       @rows = MAX(CASE fld WHEN 'rows' THEN i END), @rowsSampled = MAX(CASE fld WHEN 'sampled' THEN i END),
                       @density = MAX(CASE fld WHEN 'density' THEN fl END), @steps = MAX(CASE fld WHEN 'steps' THEN i END),
                       @steps2 = MAX(CASE fld WHEN 'steps2' THEN i END), @vc = MAX(CASE fld WHEN 'vc' THEN i END),
                       @mrs = MAX(CASE fld WHEN 'mrs' THEN i END), @akl = MAX(CASE fld WHEN 'akl' THEN fl END),
                       @rowsReal = MAX(CASE fld WHEN 'rowsreal' THEN fl END), @nullEq = MAX(CASE fld WHEN 'nulleq' THEN fl END),
                       @maskLo = MAX(CASE fld WHEN 'mask' THEN lo END), @maskHi = MAX(CASE fld WHEN 'mask' THEN hi END)
                FROM #F WHERE grp = 'b';
                -- with more than 33 vectors the last one takes fixed density slot 33 (blob+160); vectors 33 .. n-1 are in bit 8
                IF @vc > 33 UPDATE #F SET idx = @vc WHERE grp = 'd' AND fld = 'dens' AND idx = 33;

                -- presence bitmask -> items in bit order; (k + 1) int64 offsets relative to the variable section
                ;WITH b AS (SELECT TOP (64) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n FROM #N)
                INSERT #Bits (ord, bit)
                SELECT ROW_NUMBER() OVER (ORDER BY n) - 1, n FROM b
                WHERE CASE WHEN n < 32 THEN (@maskLo / POWER(CAST(2 AS bigint), n)) % 2 ELSE (@maskHi / POWER(CAST(2 AS bigint), n - 32)) % 2 END = 1;
                SET @nbits = (SELECT COUNT(*) FROM #Bits);
                ;WITH o AS (SELECT TOP (@nbits + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n FROM #N)
                INSERT #F (grp, idx, sub, fld, ofs, len) SELECT 'o', n, 0, 'ofs', @B + 332 + 8 * n, 8 FROM o;
                EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                SET @varBase = @B + 332 + 8 * (@nbits + 1);

                INSERT #Items (bit, ord, name, rel_start, rel_end, abs_start, len)
                SELECT b.bit, b.ord,
                       CASE b.bit WHEN 0 THEN N'Histogram' WHEN 1 THEN N'String Index' WHEN 3 THEN N'Update History' WHEN 4 THEN N'Unfiltered Rows'
                                  WHEN 5 THEN N'Distinct Value Synopsis' WHEN 6 THEN N'Columnstore Page Counts' WHEN 7 THEN N'Pages Sampled'
                                  WHEN 8 THEN N'Densities (vectors 33 to n-1)' WHEN 9 THEN N'Average Lengths (columns 34+)'
                                  WHEN 10 THEN N'Persisted Sample Percent' WHEN 11 THEN N'Streaming Statistics Flags'
                                  ELSE N'Unknown item (bit ' + CAST(b.bit AS nvarchar(5)) + N')' END,
                       o1.i, o2.i, @varBase + o1.i, o2.i - o1.i
                FROM #Bits b
                JOIN #F o1 ON o1.grp = 'o' AND o1.idx = b.ord
                JOIN #F o2 ON o2.grp = 'o' AND o2.idx = b.ord + 1;

                SELECT @varEnd = @varBase + i FROM #F WHERE grp = 'o' AND idx = @nbits;
                IF @varEnd > @B + @blen SET @warn += N'Variable section ends at ' + CAST(@varEnd - @B AS nvarchar(20)) + N' but the blob has ' + CAST(@blen AS nvarchar(20)) + N' bytes. ';
                ELSE IF @nbits = 1 AND EXISTS (SELECT 1 FROM #Items WHERE bit = 6) AND @varEnd + 4 <= @B + @blen
                BEGIN
                    -- columnstore index statistics: bit 6 alone, recorded with length 0; uint32 column count and one
                    -- int64 page count per column follow it (CStatMan::FExtractCSPageCounts)
                    INSERT #F (grp, idx, sub, fld, ofs, len) SELECT 'csn', 0, 0, 'cols', abs_start, 4 FROM #Items WHERE bit = 6;
                    EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                    SELECT @csCount = lo FROM #F WHERE grp = 'csn';
                    ;WITH c AS (SELECT TOP (@csCount) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM #N)
                    INSERT #F (grp, idx, sub, fld, ofs, len)
                    SELECT 'cs', c.n, 0, 'pages', i.abs_start + 4 + 8 * (c.n - 1), 8 FROM #Items i CROSS JOIN c
                    WHERE i.bit = 6 AND i.abs_start + 4 + 8 * c.n <= @B + @blen;
                    EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                    SELECT @csPages = STRING_AGG(CAST(i AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY idx) FROM #F WHERE grp = 'cs';
                    IF @varEnd + 4 + 8 * @csCount <> @B + @blen
                        SET @warn += N'Columnstore page counts: ' + CAST(@csCount AS nvarchar(20)) + N' columns do not fill the blob. ';
                END
                ELSE IF @varEnd < @B + @blen
                    INSERT #Unk VALUES (N'trailer (after last item)', @varEnd, @B + @blen - @varEnd, SUBSTRING(@s, @varEnd + 1, @B + @blen - @varEnd));
                INSERT #Unk SELECT name, abs_start, len, SUBSTRING(@s, abs_start + 1, len) FROM #Items WHERE bit NOT IN (0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11);

                ----------------------------------------------------------------
                -- Histogram step records (FixedVar rows)
                ----------------------------------------------------------------
                IF EXISTS (SELECT 1 FROM #Items WHERE bit = 0) AND @steps > 0
                BEGIN
                    SELECT @H = abs_start, @itemEnd = abs_start + len FROM #Items WHERE bit = 0;
                    ;WITH st AS (SELECT TOP (@steps) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM #N)
                    INSERT #F (grp, idx, sub, fld, ofs, len) SELECT 's', n, 0, 'ofs', @H + 8 * (n - 1), 8 FROM st;
                    EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                    INSERT #Steps (step, rs, re)
                    SELECT f.idx, @H + f.i, ISNULL(@H + LEAD(f.i) OVER (ORDER BY f.idx), @itemEnd) FROM #F f WHERE f.grp = 's';

                    UPDATE #Steps SET statusA = CAST(SUBSTRING(@s, rs + 1, 1) AS int), statusB = CAST(SUBSTRING(@s, rs + 2, 1) AS int),
                                      fixedEnd = CAST(SUBSTRING(@s, rs + 3, 1) AS int) + 256 * CAST(SUBSTRING(@s, rs + 4, 1) AS int);
                    UPDATE #Steps SET ncols = CAST(SUBSTRING(@s, rs + fixedEnd + 1, 1) AS int) + 256 * CAST(SUBSTRING(@s, rs + fixedEnd + 2, 1) AS int),
                                      nullbm = CAST(SUBSTRING(@s, rs + fixedEnd + 3, 1) AS int);
                    UPDATE #Steps SET nb = (ncols + 7) / 8, p = fixedEnd + 2 + (ncols + 7) / 8;
                    UPDATE #Steps SET varCount = CASE WHEN fixedEnd <= 16 AND statusA & 32 = 32
                                                      THEN CAST(SUBSTRING(@s, rs + p + 1, 1) AS int) + 256 * CAST(SUBSTRING(@s, rs + p + 2, 1) AS int) ELSE 0 END;
                    UPDATE #Steps SET off0 = CASE WHEN varCount > 0 THEN CAST(SUBSTRING(@s, rs + p + 3, 1) AS int) + 256 * CAST(SUBSTRING(@s, rs + p + 4, 1) AS int) END;
                    UPDATE #Steps SET keyOff = CASE WHEN fixedEnd > 16 THEN rs + 16 WHEN varCount > 0 THEN rs + p + 2 + 2 * varCount ELSE rs END,
                                      keyLen = CASE WHEN fixedEnd > 16 THEN fixedEnd - 16 WHEN varCount > 0 THEN (off0 & 32767) - (p + 2 + 2 * varCount) ELSE 0 END,
                                      keyIsNull = CASE WHEN (nullbm / 8) & 1 = 1 THEN 1 ELSE 0 END;

                    INSERT #F (grp, idx, sub, fld, ofs, len)
                    SELECT 'r', step, 0, f.fld, rs + f.o, 4 FROM #Steps CROSS JOIN (VALUES ('eq', 4), ('rr', 8), ('avg', 12)) f(fld, o);
                    EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                    UPDATE s SET eq = CAST(x.eq AS real), rr = CAST(x.rr AS real), avg_stored = CAST(x.av AS real)
                    FROM #Steps s
                    CROSS APPLY (SELECT MAX(CASE fld WHEN 'eq' THEN fl END) eq, MAX(CASE fld WHEN 'rr' THEN fl END) rr, MAX(CASE fld WHEN 'avg' THEN fl END) av
                                 FROM #F WHERE grp = 'r' AND idx = s.step) x;

                    INSERT #Keys (step, sys_type, user_type, max_length, [precision], scale, collation_id, ofs, len, bytes)
                    SELECT s.step, c.sys_type, c.user_type, c.max_length, c.[precision], c.scale, c.collation_id, s.keyOff, s.keyLen,
                           SUBSTRING(@s, s.keyOff + 1, s.keyLen)
                    FROM #Steps s CROSS JOIN #Cols c WHERE c.ordinal = 1 AND s.keyIsNull = 0;
                END

                ----------------------------------------------------------------
                -- Other single-value items, update history, vectors past 33, distinct value synopsis: one field pass
                ----------------------------------------------------------------
                INSERT #F (grp, idx, sub, fld, ofs, len)
                SELECT 'x', bit, 0, 'v', abs_start, 8 FROM #Items WHERE bit IN (4, 7, 10) AND len >= 8
                UNION ALL SELECT 'x', bit, 0, 'v', abs_start, 4 FROM #Items WHERE bit = 11 AND len >= 4
                UNION ALL SELECT 'uc', 0, 0, 'n', abs_start, 4 FROM #Items WHERE bit = 3
                UNION ALL SELECT 'sdo', v.n, 0, 'ofs', i.abs_start + 8 * (v.n - 1), 8
                          FROM #Items i CROSS JOIN (SELECT TOP (ISNULL(@vc, 0)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM #N) v
                          WHERE i.bit = 5 AND @IncludeSampledScanDump = 1
                -- bit 8: densities of vectors 33 .. n-1 (the last vector is in fixed slot 33)
                UNION ALL SELECT 'd', v.n, 0, 'dens', i.abs_start + 4 * (v.n - 33), 4
                          FROM #Items i CROSS JOIN (SELECT TOP (CASE WHEN @vc > 33 THEN @vc - 33 ELSE 0 END) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) + 32 AS n FROM #N) v
                          WHERE i.bit = 8 AND i.len >= 4 * (v.n - 32)
                -- bit 9: average lengths of columns 34 .. n
                UNION ALL SELECT 'd', v.n, 0, 'len', i.abs_start + 4 * (v.n - 34), 4
                          FROM #Items i CROSS JOIN (SELECT TOP (CASE WHEN @vc > 33 THEN @vc - 33 ELSE 0 END) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) + 33 AS n FROM #N) v
                          WHERE i.bit = 9 AND i.len >= 4 * (v.n - 33);
                EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                SELECT @unfiltered = MAX(CASE WHEN idx = 4 THEN i END), @pages = MAX(CASE WHEN idx = 7 THEN i END),
                       @persisted = MAX(CASE WHEN idx = 10 THEN fl END), @streamFlags = MAX(CASE WHEN idx = 11 THEN lo END)
                FROM #F WHERE grp = 'x';

                -- update history: int32 count + 76-byte records, newest first
                IF EXISTS (SELECT 1 FROM #Items WHERE bit = 3)
                BEGIN
                    SELECT @U = abs_start FROM #Items WHERE bit = 3;
                    SELECT @uhCount = i FROM #F WHERE grp = 'uc';
                    SELECT @uhSize = CASE WHEN @uhCount > 0 THEN (len - 4) / @uhCount ELSE 0 END FROM #Items WHERE bit = 3;
                    IF @uhCount > 0
                    BEGIN
                        ;WITH r AS (SELECT TOP (@uhCount) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n FROM #N)
                        INSERT #F (grp, idx, sub, fld, ofs, len)
                        SELECT 'u', r.n, 0, f.fld, @U + 4 + r.n * @uhSize + f.o, f.l
                        FROM r CROSS JOIN (VALUES ('updated',0,8),('card',8,8),('snap',16,8),('steps',24,4),('density',28,8),('above',36,8),
                                                  ('below',44,8),('ins',52,8),('del',60,8),('sqv',68,8)) f(fld, o, l);
                        EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                        INSERT #UH (rec, Updated, TableCardinality, SnapshotCtr, Steps, Density, RowsAbove, RowsBelow, Inserts, Deletes, SqVarErr)
                        SELECT idx, MAX(CASE fld WHEN 'updated' THEN dt END), MAX(CASE fld WHEN 'card' THEN fl END), MAX(CASE fld WHEN 'snap' THEN i END),
                               MAX(CASE fld WHEN 'steps' THEN i END), MAX(CASE fld WHEN 'density' THEN fl END), MAX(CASE fld WHEN 'above' THEN fl END),
                               MAX(CASE fld WHEN 'below' THEN fl END), MAX(CASE fld WHEN 'ins' THEN fl END), MAX(CASE fld WHEN 'del' THEN fl END),
                               MAX(CASE fld WHEN 'sqv' THEN fl END)
                        FROM #F WHERE grp = 'u' GROUP BY idx;
                    END
                END

                -- distinct value synopsis (CDVEstimator): int64 offset per vector, then uint32 count + hash values (doubles)
                IF EXISTS (SELECT 1 FROM #F WHERE grp = 'sdo')
                BEGIN
                    INSERT #F (grp, idx, sub, fld, ofs, len) SELECT 'sdc', idx, 0, 'n', @varBase + i, 4 FROM #F WHERE grp = 'sdo';
                    EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                    ;WITH j AS (SELECT TOP (4096) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n FROM #N)
                    INSERT #F (grp, idx, sub, fld, ofs, len)
                    SELECT 'sdv', c.idx, j.n, 'v', c.ofs + 4 + 8 * j.n, 8 FROM #F c JOIN j ON j.n < c.i WHERE c.grp = 'sdc';
                    EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                    INSERT #SD (vec, j, v) SELECT idx, sub, fl FROM #F WHERE grp = 'sdv';
                END

                ----------------------------------------------------------------
                -- String index (trie)
                ----------------------------------------------------------------
                IF EXISTS (SELECT 1 FROM #Items WHERE bit = 1)
                BEGIN
                    SET @hasSI = 1;
                    IF @IncludeStringIndex = 1
                    BEGIN
                        SELECT @SI = abs_start, @itemEnd = abs_start + len FROM #Items WHERE bit = 1;
                        SELECT @cs = CASE WHEN sys_type IN (231, 239, 99) THEN 2 ELSE 1 END, @keyColl = ISNULL(collation_name, N'Latin1_General_CI_AS')
                        FROM #Cols WHERE ordinal = 1;
                        INSERT #F (grp, idx, sub, fld, ofs, len) VALUES
                            -- CTrieOnDisk::Flatten after the 0xFF marker byte written by COnDiskHistogram::Persist
                            ('si',0,0,'marker',@SI,1), ('si',0,0,'ver',@SI+1,4), ('si',0,0,'nulls',@SI+5,4), ('si',0,0,'sampled',@SI+9,4),
                            ('si',0,0,'distinct',@SI+13,4), ('si',0,0,'prefix',@SI+17,4), ('si',0,0,'suffix',@SI+21,4), ('si',0,0,'u25',@SI+25,8),
                            ('si',0,0,'clen',@SI+33,4);
                        EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                        SELECT @siLen = i FROM #F WHERE grp = 'si' AND fld = 'clen';
                        INSERT #F (grp, idx, sub, fld, ofs, len) VALUES ('si',0,0,'nodes',@SI + 37 + @siLen * @cs, 4);
                        EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
                        SELECT @nodeCount = i FROM #F WHERE grp = 'si' AND fld = 'nodes';
                        SET @nodeBase = @SI + 37 + @siLen * @cs + 4;

                        IF @cs = 2 SET @cstr = CAST(SUBSTRING(@s, @SI + 38, @siLen * 2) AS nvarchar(max));
                        ELSE
                        BEGIN
                            -- varbinary -> varchar column with the key collation keeps the bytes (COLLATE on an expression re-encodes);
                            -- a table variable keeps the statement free of recompiles
                            SET @sql = N'DECLARE @cs TABLE (v varchar(max) COLLATE ' + @keyColl + N'); INSERT @cs VALUES (@b); SELECT @r = CAST(v AS nvarchar(max)) FROM @cs;';
                            SET @csb = SUBSTRING(@s, @SI + 38, @siLen);
                            EXEC sys.sp_executesql @sql, N'@b varbinary(max), @r nvarchar(max) OUTPUT', @csb, @cstr OUTPUT;
                        END

                        IF @nodeCount > (SELECT MAX(n) FROM #N)
                        BEGIN
                            ;WITH e1(x) AS (SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) v(x)), e4(x) AS (SELECT 1 FROM e1 a CROSS JOIN e1 b CROSS JOIN e1 c CROSS JOIN e1 d CROSS JOIN e1 e)
                            INSERT #N (n) SELECT TOP (@nodeCount + 1 - (SELECT MAX(n) FROM #N)) (SELECT MAX(n) FROM #N) + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM e4;
                        END
                        -- every node: [info][segment length][segment offset: 3 bytes][occurrences: 1 byte if info & 0x10, 4 bytes if info & 0x20]
                        -- (info & 0x0F = occurrences 0-15). Nodes vary in length, so a recursive walk carries each node's offset.
                        ;WITH r AS (
                            SELECT 0 AS i, CAST(@nodeBase AS bigint) AS o
                            WHERE ISNULL(@nodeCount, 0) > 0
                            UNION ALL
                            SELECT r.i + 1, r.o + 5 + CASE WHEN f.fl & 32 = 32 THEN 4 WHEN f.fl & 16 = 16 THEN 1 ELSE 0 END
                            FROM r CROSS APPLY (SELECT CAST(SUBSTRING(@s, r.o + 1, 1) AS int) AS fl) f
                            WHERE r.i + 1 < @nodeCount)
                        INSERT #SIN (NodeIndex, Flags, [Count], HasChildren, HasSibling, SegmentOffset, SegmentLength, Segment, RecordOffset, RecordLength)
                        SELECT r.i, x.fl,
                               CASE WHEN x.fl & 32 = 32 THEN CAST(SUBSTRING(@s, r.o + 6, 1) AS bigint) + 256 * CAST(SUBSTRING(@s, r.o + 7, 1) AS bigint)
                                                             + 65536 * CAST(SUBSTRING(@s, r.o + 8, 1) AS bigint) + 16777216 * CAST(SUBSTRING(@s, r.o + 9, 1) AS bigint)
                                    WHEN x.fl & 16 = 16 THEN CAST(SUBSTRING(@s, r.o + 6, 1) AS int)
                                    ELSE x.fl & 15 END,
                               CASE WHEN x.fl & 64 = 64 THEN 1 ELSE 0 END, CASE WHEN x.fl & 128 = 128 THEN 1 ELSE 0 END,
                               x.so, x.sl, SUBSTRING(@cstr, x.so + 1, x.sl), r.o, 5 + CASE WHEN x.fl & 32 = 32 THEN 4 WHEN x.fl & 16 = 16 THEN 1 ELSE 0 END
                        FROM r
                        CROSS APPLY (SELECT CAST(SUBSTRING(@s, r.o + 1, 1) AS int) AS fl,
                                            CAST(SUBSTRING(@s, r.o + 2, 1) AS int) AS sl,
                                            CAST(SUBSTRING(@s, r.o + 3, 1) AS int) + 256 * CAST(SUBSTRING(@s, r.o + 4, 1) AS int)
                                            + 65536 * CAST(SUBSTRING(@s, r.o + 5, 1) AS int) AS so) x
                        OPTION (MAXRECURSION 0);
                        SELECT @nodeEnd = ISNULL(MAX(RecordOffset + RecordLength), @nodeBase) FROM #SIN;

                        -- pre-order walk (depth and full text) in one recursive query, up to @MaxStringIndexNodes.
                        -- Stack entries (13 chars): Y/N = ancestor has a next sibling, depth (5), prefix length (7).
                        -- Leaf without sibling: pop up to and including the deepest 'Y' entry (or everything).
                        SET @walk = CASE WHEN @MaxStringIndexNodes > 0 AND @MaxStringIndexNodes < @nodeCount THEN @MaxStringIndexNodes ELSE @nodeCount END;
                        ;WITH w AS (
                            SELECT s.NodeIndex AS i, 0 AS depth, CAST(N'' AS nvarchar(max)) AS prefix, CAST('' AS varchar(max)) AS stk, s.Flags AS fl, s.Segment AS seg
                            FROM #SIN s WHERE s.NodeIndex = 0
                            UNION ALL
                            SELECT n.NodeIndex, x.depth, x.prefix, x.stk, n.Flags, n.Segment
                            FROM w
                            JOIN #SIN n ON n.NodeIndex = w.i + 1
                            CROSS APPLY (SELECT CASE WHEN CHARINDEX('Y', REVERSE(w.stk)) = 0 THEN 1
                                                     ELSE DATALENGTH(w.stk) - CHARINDEX('Y', REVERSE(w.stk)) + 1 END AS popAt) p
                            CROSS APPLY (SELECT
                                CASE WHEN w.fl & 64 = 64 THEN w.depth + 1
                                     WHEN w.fl & 128 = 128 OR DATALENGTH(w.stk) = 0 THEN w.depth
                                     ELSE CAST(SUBSTRING(w.stk, p.popAt + 1, 5) AS int) END AS depth,
                                CASE WHEN w.fl & 64 = 64 THEN w.prefix + w.seg
                                     WHEN w.fl & 128 = 128 OR DATALENGTH(w.stk) = 0 THEN w.prefix
                                     ELSE LEFT(w.prefix, CAST(SUBSTRING(w.stk, p.popAt + 6, 7) AS int)) END AS prefix,
                                CASE WHEN w.fl & 64 = 64
                                          THEN w.stk + CASE WHEN w.fl & 128 = 128 THEN 'Y' ELSE 'N' END
                                               + RIGHT('00000' + CAST(w.depth AS varchar(5)), 5) + RIGHT('0000000' + CAST(DATALENGTH(w.prefix) / 2 AS varchar(7)), 7)
                                     WHEN w.fl & 128 = 128 OR DATALENGTH(w.stk) = 0 THEN w.stk
                                     ELSE LEFT(w.stk, p.popAt - 1) END AS stk) x
                            WHERE n.NodeIndex < @walk)
                        UPDATE s SET Depth = w.depth, FullText = w.prefix + w.seg
                        FROM #SIN s JOIN w ON w.i = s.NodeIndex
                        OPTION (MAXRECURSION 0);
                    END
                END
            END
            ELSE SET @warn += N'The statistics blob is empty: the statistics have never been populated (for example created on an empty table and never updated). ';

            IF @crcCalc IS NOT NULL AND @crcCalc <> @crcStored SET @warn += N'Checksum mismatch: the stream was modified or is truncated. ';
            IF @slen <> @len SET @warn += N'Header says ' + CAST(@slen AS nvarchar(20)) + N' bytes, stream has ' + CAST(@len AS nvarchar(20)) + N'. ';

            --------------------------------------------------------------------
            -- Key decoding (histogram RANGE_HI_KEY)
            --------------------------------------------------------------------
            SET @stage = N'decode histogram keys';
            -- sql_variant: base type, version, type properties, value
            INSERT #Keys (parent, step, sys_type, user_type, max_length, [precision], scale, collation_id, ofs, len, bytes)
            SELECT k.kid, k.step, x.bt, x.bt,
                   CASE WHEN x.bt IN (165, 173, 167, 175, 231, 239) THEN CAST(SUBSTRING(k.bytes, 3, 1) AS int) + 256 * CAST(SUBSTRING(k.bytes, 4, 1) AS int) ELSE 0 END,
                   CASE WHEN x.bt IN (106, 108) THEN CAST(SUBSTRING(k.bytes, 3, 1) AS int) ELSE 0 END,
                   CASE WHEN x.bt IN (106, 108) THEN CAST(SUBSTRING(k.bytes, 4, 1) AS int) WHEN x.bt IN (41, 42, 43) THEN CAST(SUBSTRING(k.bytes, 3, 1) AS int) ELSE 0 END,
                   CASE WHEN x.bt IN (167, 175, 231, 239)
                        THEN CAST(SUBSTRING(k.bytes, 5, 1) AS int) + 256 * CAST(SUBSTRING(k.bytes, 6, 1) AS int) + 65536 * CAST(SUBSTRING(k.bytes, 7, 1) AS int)
                             + 16777216 * (CAST(SUBSTRING(k.bytes, 8, 1) AS int) - CASE WHEN CAST(SUBSTRING(k.bytes, 8, 1) AS int) >= 128 THEN 256 ELSE 0 END)
                        ELSE 0 END,
                   k.ofs + x.p, k.len - x.p, SUBSTRING(k.bytes, x.p + 1, k.len - x.p)
            FROM #Keys k
            CROSS APPLY (SELECT CAST(SUBSTRING(k.bytes, 1, 1) AS int) AS bt) b
            CROSS APPLY (SELECT b.bt AS bt, CASE WHEN b.bt IN (106, 108) THEN 4 WHEN b.bt IN (41, 42, 43) THEN 3 WHEN b.bt IN (165, 173) THEN 4
                                                WHEN b.bt IN (167, 175, 231, 239) THEN 8 ELSE 2 END AS p) x
            WHERE k.sys_type = 98 AND k.len >= 2;
            IF EXISTS (SELECT 1 FROM #Keys WHERE parent IS NOT NULL AND collation_id <> 0 AND collation_id NOT IN (SELECT id FROM #Coll))
            BEGIN
                INSERT #Coll (id, name, cp)
                SELECT x.id, x.name, CAST(COLLATIONPROPERTY(x.name, 'CodePage') AS int)
                FROM (SELECT DISTINCT collation_id AS id, CAST(COLLATIONPROPERTYFROMID(collation_id, 'Name') AS sysname) AS name
                      FROM #Keys WHERE parent IS NOT NULL AND collation_id <> 0 AND collation_id NOT IN (SELECT id FROM #Coll)) x
                WHERE x.name IS NOT NULL;
                INSERT #Coll (id, name, cp)
                SELECT CAST(COLLATIONPROPERTY(h.name, 'CollationId') AS int), h.name, CAST(COLLATIONPROPERTY(h.name, 'CodePage') AS int)
                FROM sys.fn_helpcollations() h
                WHERE CAST(COLLATIONPROPERTY(h.name, 'CollationId') AS int) IN (SELECT collation_id FROM #Keys WHERE parent IS NOT NULL AND collation_id <> 0)
                  AND CAST(COLLATIONPROPERTY(h.name, 'CollationId') AS int) NOT IN (SELECT id FROM #Coll);
            END

            -- numeric parts through the field reader
            INSERT #F (grp, idx, sub, fld, ofs, len)
            SELECT 'k', kid, 0, 'a', ofs, len FROM #Keys
            WHERE sys_type IN (48, 52, 56, 127, 104, 59, 62, 60, 122, 61, 58) AND len BETWEEN 1 AND 8
            UNION ALL SELECT 'k', kid, 0, 't', ofs, len - CASE sys_type WHEN 41 THEN 0 WHEN 42 THEN 3 ELSE 5 END FROM #Keys WHERE sys_type IN (41, 42, 43)
            UNION ALL SELECT 'k', kid, 0, 'd', ofs + CASE sys_type WHEN 40 THEN 0 WHEN 42 THEN len - 3 ELSE len - 5 END, 3 FROM #Keys WHERE sys_type IN (40, 42, 43)
            UNION ALL SELECT 'k', kid, 0, 'o', ofs + len - 2, 2 FROM #Keys WHERE sys_type = 43;
            EXEC sys.sp_executesql @calc, N'@s varbinary(max)', @s;
            UPDATE k SET a_i = x.ai, a_f = x.af, a_lo = x.alo, a_hi = x.ahi, t_u = x.tu, d_u = x.du, o_i = x.oi
            FROM #Keys k
            CROSS APPLY (SELECT MAX(CASE fld WHEN 'a' THEN i END) ai, MAX(CASE fld WHEN 'a' THEN fl END) af, MAX(CASE fld WHEN 'a' THEN lo END) alo,
                                MAX(CASE fld WHEN 'a' THEN hi END) ahi, MAX(CASE fld WHEN 't' THEN i END) tu, MAX(CASE fld WHEN 'd' THEN i END) du,
                                MAX(CASE fld WHEN 'o' THEN i END) oi
                         FROM #F WHERE grp = 'k' AND idx = k.kid) x
            WHERE k.sys_type IN (48, 52, 56, 127, 104, 59, 62, 60, 122, 61, 58, 40, 41, 42, 43);
            -- decimal/numeric: sign byte + little-endian magnitude (up to 16 bytes), rendered as an exact string
            UPDATE k SET dec_str = CASE WHEN CAST(SUBSTRING(k.bytes, 1, 1) AS int) = 0 AND m.mag <> 0 THEN '-' ELSE '' END +
                                   CASE WHEN k.scale > 0
                                        THEN STUFF(RIGHT(REPLICATE('0', k.scale + 1) + CAST(m.mag AS varchar(40)), CASE WHEN LEN(CAST(m.mag AS varchar(40))) > k.scale THEN LEN(CAST(m.mag AS varchar(40))) ELSE k.scale + 1 END),
                                                   CASE WHEN LEN(CAST(m.mag AS varchar(40))) > k.scale THEN LEN(CAST(m.mag AS varchar(40))) ELSE k.scale + 1 END - k.scale + 1, 0, '.')
                                        ELSE CAST(m.mag AS varchar(40)) END
            FROM #Keys k
            JOIN (SELECT k2.kid, SUM(CAST(CAST(SUBSTRING(k2.bytes, b.n + 2, 1) AS int) AS decimal(38, 0)) * POWER(CAST(256 AS decimal(38, 0)), b.n)) AS mag
                  FROM #Keys k2
                  JOIN (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15)) b(n) ON b.n < k2.len - 1
                  WHERE k2.sys_type IN (106, 108)
                  GROUP BY k2.kid) m ON m.kid = k.kid
            WHERE k.sys_type IN (106, 108);

            -- one dynamic conversion per distinct type signature (constant text per type: plans are reused)
            INSERT #KG (sys_type, user_type, max_length, [precision], scale, collation_id)
            SELECT DISTINCT sys_type, user_type, max_length, [precision], scale, ISNULL(collation_id, 0) FROM #Keys WHERE sys_type <> 98;
            UPDATE k SET gid = g.gid FROM #Keys k JOIN #KG g ON g.sys_type = k.sys_type AND g.user_type = k.user_type AND g.max_length = k.max_length
                                                            AND g.[precision] = k.[precision] AND g.scale = k.scale AND g.collation_id = ISNULL(k.collation_id, 0);
            SET @g = 1;
            WHILE @g <= (SELECT ISNULL(MAX(gid), 0) FROM #KG)
            BEGIN
                SELECT @gtype = sys_type, @guser = user_type, @gmax = max_length, @gprec = [precision], @gscale = scale, @gcoll = collation_id FROM #KG WHERE gid = @g;
                SET @gcollName = ISNULL((SELECT name FROM #Coll WHERE id = @gcoll), N'Latin1_General_CI_AS');
                SET @T = CASE @gtype
                    WHEN 48 THEN N'tinyint' WHEN 52 THEN N'smallint' WHEN 56 THEN N'int' WHEN 127 THEN N'bigint' WHEN 104 THEN N'bit'
                    WHEN 59 THEN N'real' WHEN 62 THEN CASE WHEN @gmax = 4 THEN N'real' ELSE N'float' END
                    WHEN 60 THEN N'money' WHEN 122 THEN N'smallmoney'
                    WHEN 106 THEN N'decimal(' + CAST(@gprec AS nvarchar(5)) + N',' + CAST(@gscale AS nvarchar(5)) + N')'
                    WHEN 108 THEN N'numeric(' + CAST(@gprec AS nvarchar(5)) + N',' + CAST(@gscale AS nvarchar(5)) + N')'
                    WHEN 40 THEN N'date' WHEN 41 THEN N'time(' + CAST(@gscale AS nvarchar(5)) + N')'
                    WHEN 42 THEN N'datetime2(' + CAST(@gscale AS nvarchar(5)) + N')' WHEN 43 THEN N'datetimeoffset(' + CAST(@gscale AS nvarchar(5)) + N')'
                    WHEN 61 THEN N'datetime' WHEN 58 THEN N'smalldatetime' WHEN 36 THEN N'uniqueidentifier'
                    WHEN 173 THEN N'binary(' + CAST(CASE WHEN @gmax BETWEEN 1 AND 8000 THEN @gmax ELSE 8000 END AS nvarchar(5)) + N')'
                    WHEN 165 THEN N'varbinary(' + CAST(CASE WHEN @gmax BETWEEN 1 AND 8000 THEN @gmax ELSE 8000 END AS nvarchar(5)) + N')'
                    WHEN 189 THEN N'binary(8)'
                    WHEN 175 THEN N'char(' + CAST(CASE WHEN @gmax BETWEEN 1 AND 8000 THEN @gmax ELSE 8000 END AS nvarchar(5)) + N')'
                    WHEN 167 THEN N'varchar(' + CAST(CASE WHEN @gmax BETWEEN 1 AND 8000 THEN @gmax ELSE 8000 END AS nvarchar(5)) + N')'
                    WHEN 239 THEN N'nchar(' + CAST(CASE WHEN @gmax BETWEEN 2 AND 8000 THEN @gmax / 2 ELSE 4000 END AS nvarchar(5)) + N')'
                    WHEN 231 THEN N'nvarchar(' + CAST(CASE WHEN @gmax BETWEEN 2 AND 8000 THEN @gmax / 2 ELSE 4000 END AS nvarchar(5)) + N')'
                    -- text / ntext keys are stored like varchar / nvarchar (and sql_variant cannot hold the legacy types)
                    WHEN 35 THEN N'varchar(8000)' WHEN 99 THEN N'nvarchar(4000)'
                    ELSE N'varbinary(8000)' END;
                SET @expr = CASE
                    WHEN @gtype IN (48, 52, 56, 127) THEN N'CONVERT(' + @T + N', k.a_i)'
                    WHEN @gtype = 104 THEN N'CONVERT(bit, k.a_i & 1)'
                    WHEN @gtype IN (59, 62) THEN N'CONVERT(' + @T + N', k.a_f)'
                    WHEN @gtype IN (60, 122) THEN N'CONVERT(' + @T + N', CAST(k.a_i AS decimal(19, 0)) / 10000)'
                    WHEN @gtype IN (106, 108) THEN N'CONVERT(' + @T + N', k.dec_str)'
                    WHEN @gtype = 40 THEN N'DATEADD(day, k.d_u, CAST(''0001-01-01'' AS date))'
                    WHEN @gtype = 41 THEN N'CONVERT(' + @T + N', DATEADD(nanosecond, CAST((k.t_u % POWER(CAST(10 AS bigint), ' + CAST(@gscale AS nvarchar(5)) + N')) * POWER(CAST(10 AS bigint), ' + CAST(9 - @gscale AS nvarchar(5)) + N') AS int), DATEADD(second, CAST(k.t_u / POWER(CAST(10 AS bigint), ' + CAST(@gscale AS nvarchar(5)) + N') AS int), CAST(''00:00:00'' AS time(7)))))'
                    WHEN @gtype IN (42, 43) THEN N'DATEADD(nanosecond, CAST((k.t_u % POWER(CAST(10 AS bigint), ' + CAST(@gscale AS nvarchar(5)) + N')) * POWER(CAST(10 AS bigint), ' + CAST(9 - @gscale AS nvarchar(5)) + N') AS int), DATEADD(second, CAST(k.t_u / POWER(CAST(10 AS bigint), ' + CAST(@gscale AS nvarchar(5)) + N') AS int), DATEADD(day, k.d_u, CAST(''0001-01-01'' AS datetime2(7)))))'
                    WHEN @gtype = 61 THEN N'CAST(CONVERT(binary(4), CAST(CASE WHEN k.a_hi >= 2147483648 THEN k.a_hi - 4294967296 ELSE k.a_hi END AS int)) + CONVERT(binary(4), CAST(CASE WHEN k.a_lo >= 2147483648 THEN k.a_lo - 4294967296 ELSE k.a_lo END AS int)) AS datetime)'
                    WHEN @gtype = 58 THEN N'DATEADD(minute, CAST(k.a_lo % 65536 AS int), DATEADD(day, CAST(k.a_lo / 65536 AS int), CAST(''19000101'' AS smalldatetime)))'
                    WHEN @gtype = 36 THEN N'CONVERT(uniqueidentifier, k.bytes)'
                    WHEN @gtype IN (173, 165, 189) THEN N'CONVERT(' + @T + N', k.bytes)'
                    -- Unicode: relabel with the column collation (sql_variant comparisons and sorting depend on it)
                    WHEN @gtype IN (239, 231, 99) THEN N'CONVERT(' + @T + N', k.bytes) COLLATE ' + @gcollName
                    ELSE N'k.bytes' END;
                IF @gtype = 42 SET @expr = N'CONVERT(' + @T + N', ' + @expr + N')';
                IF @gtype = 43 SET @expr = N'CONVERT(' + @T + N', TODATETIMEOFFSET(DATEADD(minute, k.o_i, ' + @expr + N'), k.o_i))';
                SET @style = CASE WHEN @gtype IN (61, 42, 43, 58, 41) THEN 121 WHEN @gtype = 40 THEN 23 WHEN @gtype IN (59, 62) THEN 3
                                  WHEN @gtype IN (60, 122) THEN 2 WHEN @gtype IN (173, 165, 189) THEN 1 ELSE 0 END;

                IF @gtype IN (175, 167, 35)
                    SET @sql = N'DECLARE @cv TABLE (kid int PRIMARY KEY, v varchar(8000) COLLATE ' + @gcollName + N');
INSERT @cv (kid, v) SELECT kid, bytes FROM #Keys WHERE gid = @g;
UPDATE k SET val = CAST(CAST(c.v AS ' + @T + N') AS sql_variant), txt = CAST(CAST(c.v AS ' + @T + N') AS nvarchar(4000))
FROM #Keys k JOIN @cv c ON c.kid = k.kid;';
                ELSE IF @gtype = 240 AND @guser = 128
                    SET @sql = N'UPDATE #Keys SET val = CAST(bytes AS sql_variant), txt = CAST(bytes AS hierarchyid).ToString() WHERE gid = @g;';
                ELSE
                    SET @sql = N'UPDATE k SET val = CAST(x.v AS sql_variant), txt = CONVERT(nvarchar(4000), x.v, ' + CAST(@style AS nvarchar(5)) + N')
FROM #Keys k CROSS APPLY (SELECT ' + @expr + N' AS v) x WHERE k.gid = @g;';
                BEGIN TRY
                    EXEC sys.sp_executesql @sql, N'@g int', @g;
                END TRY
                BEGIN CATCH
                    SET @warn += N'Keys of type ' + @T + N' could not be decoded: ' + ERROR_MESSAGE() + N' ';
                    UPDATE #Keys SET val = CAST(bytes AS sql_variant), txt = CONVERT(nvarchar(4000), bytes, 1) WHERE gid = @g;
                END CATCH
                SET @g += 1;
            END
            UPDATE p SET val = c.val, txt = c.txt FROM #Keys p JOIN #Keys c ON c.parent = p.kid WHERE p.sys_type = 98;

            --------------------------------------------------------------------
            -- Histogram (NULL step first), density vector, update history, TF 2388 view
            --------------------------------------------------------------------
            SET @stage = N'assemble results';
            IF @nullEq > 0
                INSERT #Hist (step, RANGE_HI_KEY, RANGE_HI_KEY_TEXT, RANGE_ROWS, EQ_ROWS, DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS, StoredAvgRangeRows, IsNullStep)
                VALUES (1, NULL, N'NULL', 0, @nullEq, 0, 1, NULL, 1);
            INSERT #Hist (step, RANGE_HI_KEY, RANGE_HI_KEY_TEXT, RANGE_ROWS, EQ_ROWS, DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS, StoredAvgRangeRows,
                          RecordOffset, RecordLength, KeyBytes, IsNullStep)
            SELECT s.step + CASE WHEN @nullEq > 0 THEN 1 ELSE 0 END,
                   k.val, ISNULL(k.txt, CASE WHEN s.keyIsNull = 1 THEN N'NULL' END), s.rr, s.eq,
                   -- DBCC: DISTINCT = RANGE / AVG; a stored average below 1 is shown as 1 with DISTINCT = round(RANGE)
                   CASE WHEN s.rr = 0 OR s.avg_stored = 0 THEN 0 WHEN s.avg_stored < 1 THEN ROUND(s.rr, 0) ELSE CAST(s.rr / s.avg_stored AS real) END,
                   CASE WHEN s.rr <> 0 AND s.avg_stored > 0 AND s.avg_stored < 1 THEN 1 ELSE s.avg_stored END,
                   s.avg_stored, s.rs, s.re - s.rs, k.bytes, 0
            FROM #Steps s LEFT JOIN #Keys k ON k.step = s.step AND k.parent IS NULL;

            -- average lengths are stored per column; DBCC shows the running sum
            INSERT #DV (vec, AllDensity, ColumnAverageLength, Columns)
            SELECT v.n, CAST(d.fl AS real), CAST(l.fl AS real),
                   (SELECT STRING_AGG(CAST(c.name AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY c.ordinal) FROM #Cols c WHERE c.ordinal <= v.n)
            FROM (SELECT TOP (ISNULL(@vc, 0)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM #N) v
            LEFT JOIN #F d ON d.grp = 'd' AND d.idx = v.n AND d.fld = 'dens'
            LEFT JOIN #F l ON l.grp = 'd' AND l.idx = v.n AND l.fld = 'len';
            UPDATE d SET AverageLength = CAST(x.s AS real)
            FROM #DV d CROSS APPLY (SELECT SUM(CAST(ColumnAverageLength AS float)) s FROM #DV d2 WHERE d2.vec <= d.vec) x;

            -- leading column type (TF 2389/2390 branding): three updates with >90% of new rows above/below.
            -- The 3 latest updates are read newest first, as DBCC does: the first one without inserts makes it
            -- Unknown, the first one that is neither ascending nor descending (or turns the other way) makes it
            -- Stationary. (Checked against TF 2388 on ~10,600 SQL Server 2022 statistics: "any update without
            -- inserts = Unknown" was wrong for patterns such as stationary-then-no-inserts.)
            IF (SELECT COUNT(*) FROM #UH) >= 3
            BEGIN
                WITH u AS (
                    SELECT rec, CASE WHEN ISNULL(Inserts, 0) <= 0 THEN 'Z' WHEN RowsAbove >= 0.9 * Inserts THEN 'A'
                                     WHEN RowsBelow >= 0.9 * Inserts THEN 'D' ELSE 'S' END AS t
                    FROM #UH WHERE rec < 3)
                SELECT @leading = CASE WHEN b.t IS NULL THEN CASE f.t WHEN 'A' THEN N'Ascending' ELSE N'Descending' END
                                       WHEN b.t = 'Z' THEN N'Unknown' ELSE N'Stationary' END
                FROM u AS f
                OUTER APPLY (SELECT TOP (1) u.t FROM u WHERE u.t IN ('Z', 'S') OR u.t <> f.t ORDER BY u.rec) AS b
                WHERE f.rec = 0;
            END

            IF @B IS NULL OR @blen = 0 OR @len <= @B OR ISNULL(@vc, 0) = 0
                INSERT #TFV (rowno) VALUES (1);  -- DBCC returns one row of NULLs
            ELSE
            BEGIN
                SELECT @snapSrc = CASE WHEN @snap IS NOT NULL THEN N'sys.sysobjvalues (DAC)' ELSE N'estimated: row count (not in stream)' END;
                INSERT #TFV
                SELECT 1, @updated, CAST(@rows AS float), ISNULL(@snap, ISNULL(@unfiltered, @rows)), @steps,
                       (SELECT CAST(fl AS float) FROM #F WHERE grp = 'd' AND idx = 1 AND fld = 'dens'),
                       h0.RowsAbove, h0.RowsBelow, h0.SqVarErr, h0.Inserts, h0.Deletes, @leading, @snapSrc
                FROM (SELECT 1 AS x) d LEFT JOIN #UH h0 ON h0.rec = 0;
                INSERT #TFV
                SELECT h.rec + 2, h.Updated, h.TableCardinality, h.SnapshotCtr, h.Steps, h.Density,
                       n.RowsAbove, n.RowsBelow, n.SqVarErr, n.Inserts, n.Deletes, NULL, N'update history record ' + CAST(h.rec AS nvarchar(5))
                FROM #UH h LEFT JOIN #UH n ON n.rec = h.rec + 1;
            END

            --------------------------------------------------------------------
            -- Validation
            --------------------------------------------------------------------
            IF @Validate = 1
            BEGIN
                SET @stage = N'validate';
                TRUNCATE TABLE #VH; TRUNCATE TABLE #VD; TRUNCATE TABLE #VHist;
                BEGIN TRY INSERT #VH EXEC @proc N'DBCC SHOW_STATISTICS(@t, @s) WITH STAT_HEADER, NO_INFOMSGS', N'@t nvarchar(600), @s sysname', @qtable, @statName; END TRY
                BEGIN CATCH INSERT #Val VALUES (N'Header', N'not run', ERROR_MESSAGE(), 'SKIPPED'); END CATCH
                IF EXISTS (SELECT 1 FROM #VH WHERE [Rows] IS NOT NULL) AND @B IS NOT NULL AND @blen > 0
                BEGIN
                    INSERT #Val SELECT N'Header: Rows', CAST([Rows] AS nvarchar(30)), CAST(@rows AS nvarchar(30)), CASE WHEN [Rows] = @rows THEN 'OK' ELSE 'MISMATCH' END FROM #VH;
                    INSERT #Val SELECT N'Header: Rows Sampled', CAST([Rows Sampled] AS nvarchar(30)), CAST(@rowsSampled AS nvarchar(30)), CASE WHEN [Rows Sampled] = @rowsSampled THEN 'OK' ELSE 'MISMATCH' END FROM #VH;
                    INSERT #Val SELECT N'Header: Steps', CAST(Steps AS nvarchar(30)), CAST(@steps + CASE WHEN @nullEq > 0 THEN 1 ELSE 0 END AS nvarchar(30)),
                                       CASE WHEN Steps = @steps + CASE WHEN @nullEq > 0 THEN 1 ELSE 0 END THEN 'OK' ELSE 'MISMATCH' END FROM #VH;
                    INSERT #Val SELECT N'Header: Density', CONVERT(nvarchar(30), Density, 3), CONVERT(nvarchar(30), @density, 3), CASE WHEN Density = @density THEN 'OK' ELSE 'MISMATCH' END FROM #VH;
                    INSERT #Val SELECT N'Header: Average key length', CONVERT(nvarchar(30), [Average key length], 3), CONVERT(nvarchar(30), @akl, 3), CASE WHEN [Average key length] = @akl THEN 'OK' ELSE 'MISMATCH' END FROM #VH;
                    INSERT #Val SELECT N'Header: String Index', RTRIM([String Index]), CASE WHEN @hasSI = 1 THEN 'YES' ELSE 'NO' END, CASE WHEN RTRIM([String Index]) = CASE WHEN @hasSI = 1 THEN 'YES' ELSE 'NO' END THEN 'OK' ELSE 'MISMATCH' END FROM #VH;
                    INSERT #Val SELECT N'Header: Updated (minute)', CONVERT(nvarchar(16), Updated, 120), CONVERT(nvarchar(16), @updated, 120), CASE WHEN CONVERT(nvarchar(16), Updated, 120) = CONVERT(nvarchar(16), @updated, 120) THEN 'OK' ELSE 'MISMATCH' END FROM #VH;
                    IF @unfiltered IS NOT NULL
                        INSERT #Val SELECT N'Header: Unfiltered Rows', CAST([Unfiltered Rows] AS nvarchar(30)), CAST(@unfiltered AS nvarchar(30)), CASE WHEN [Unfiltered Rows] = @unfiltered THEN 'OK' ELSE 'MISMATCH' END FROM #VH;
                    IF @persisted IS NOT NULL
                        INSERT #Val SELECT N'Header: Persisted Sample Percent', CONVERT(nvarchar(30), [Persisted Sample Percent], 3), CONVERT(nvarchar(30), @persisted, 3), CASE WHEN [Persisted Sample Percent] = @persisted THEN 'OK' ELSE 'MISMATCH' END FROM #VH;
                END

                BEGIN TRY INSERT #VD ([All density], [Average Length], [Columns]) EXEC @proc N'DBCC SHOW_STATISTICS(@t, @s) WITH DENSITY_VECTOR, NO_INFOMSGS', N'@t nvarchar(600), @s sysname', @qtable, @statName; END TRY
                BEGIN CATCH INSERT #Val VALUES (N'Density vector', N'not run', ERROR_MESSAGE(), 'SKIPPED'); END CATCH
                INSERT #Val
                SELECT N'Density vector ' + CAST(v.n AS nvarchar(5)),
                       CONVERT(nvarchar(30), v.[All density], 3) + N' / ' + CONVERT(nvarchar(30), v.[Average Length], 3),
                       CONVERT(nvarchar(30), d.AllDensity, 3) + N' / ' + CONVERT(nvarchar(30), d.AverageLength, 3),
                       CASE WHEN ABS(CAST(v.[All density] AS float) - d.AllDensity) <= 1e-6 * ABS(CAST(v.[All density] AS float)) + 1e-12
                             AND ABS(CAST(v.[Average Length] AS float) - d.AverageLength) <= 1e-5 * ABS(CAST(v.[Average Length] AS float)) + 1e-6 THEN 'OK' ELSE 'MISMATCH' END
                FROM #VD v LEFT JOIN #DV d ON d.vec = v.n;

                BEGIN TRY
                    INSERT #VHist EXEC @proc N'SELECT ROW_NUMBER() OVER (ORDER BY step_number), range_high_key, range_rows, equal_rows, distinct_range_rows, average_range_rows FROM sys.dm_db_stats_histogram(@o, @st);',
                                       N'@o int, @st int', @objId, @statsId;
                END TRY
                BEGIN CATCH INSERT #Val VALUES (N'Histogram', N'not run', ERROR_MESSAGE(), 'SKIPPED'); END CATCH
                -- A histogram with only the NULL step (every sampled value NULL) is one step in DBCC SHOW_STATISTICS,
                -- but sys.dm_db_stats_histogram returns no rows for it (133 such statistics on SQL Server 2022).
                INSERT #Val SELECT N'Histogram: step count', CAST((SELECT COUNT(*) FROM #VHist) AS nvarchar(10)), CAST((SELECT COUNT(*) FROM #Hist) AS nvarchar(10)),
                                   CASE WHEN (SELECT COUNT(*) FROM #VHist) = (SELECT COUNT(*) FROM #Hist) THEN 'OK'
                                        WHEN NOT EXISTS (SELECT 1 FROM #VHist) AND NOT EXISTS (SELECT 1 FROM #Hist WHERE ISNULL(IsNullStep, 0) = 0) THEN 'OK'
                                        ELSE 'MISMATCH' END;
                INSERT #Val
                SELECT TOP (20) N'Histogram step ' + CAST(v.step AS nvarchar(10)),
                       ISNULL(CONVERT(nvarchar(400), v.k), N'NULL') + N' | ' + CONVERT(nvarchar(30), v.rr, 3) + N' | ' + CONVERT(nvarchar(30), v.eq, 3) + N' | ' + CAST(v.dr AS nvarchar(30)) + N' | ' + CONVERT(nvarchar(30), v.ar, 3),
                       ISNULL(CONVERT(nvarchar(400), h.RANGE_HI_KEY), N'NULL') + N' | ' + CONVERT(nvarchar(30), h.RANGE_ROWS, 3) + N' | ' + CONVERT(nvarchar(30), h.EQ_ROWS, 3) + N' | ' + CONVERT(nvarchar(30), h.DISTINCT_RANGE_ROWS, 3) + N' | ' + CONVERT(nvarchar(30), h.AVG_RANGE_ROWS, 3),
                       'MISMATCH'
                FROM #VHist v LEFT JOIN #Hist h ON h.step = v.step
                WHERE h.step IS NULL
                   OR NOT ((v.k IS NULL AND h.RANGE_HI_KEY IS NULL) OR v.k = h.RANGE_HI_KEY)
                   OR v.rr <> h.RANGE_ROWS OR v.eq <> h.EQ_ROWS OR v.ar <> h.AVG_RANGE_ROWS
                   OR ABS(v.dr - CAST(h.DISTINCT_RANGE_ROWS AS float)) > 0.5 + 1e-5 * v.dr
                ORDER BY v.step;
                INSERT #Val SELECT N'Histogram: all steps (key, RANGE_ROWS, EQ_ROWS, DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS)',
                                   CAST((SELECT COUNT(*) FROM #VHist) AS nvarchar(10)) + N' steps',
                                   CAST(COUNT(*) AS nvarchar(10)) + N' mismatching', CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'MISMATCH' END
                            FROM #VHist v LEFT JOIN #Hist h ON h.step = v.step
                            WHERE h.step IS NULL OR NOT ((v.k IS NULL AND h.RANGE_HI_KEY IS NULL) OR v.k = h.RANGE_HI_KEY)
                               OR v.rr <> h.RANGE_ROWS OR v.eq <> h.EQ_ROWS OR v.ar <> h.AVG_RANGE_ROWS
                               OR ABS(v.dr - CAST(h.DISTINCT_RANGE_ROWS AS float)) > 0.5 + 1e-5 * v.dr;

                IF @tfStatus IS NOT NULL
                    INSERT #Val VALUES (N'Trace flag 2388 view', N'not run', @tfStatus, 'SKIPPED');
                ELSE
                BEGIN
                    INSERT #Val SELECT N'TF 2388: row count', CAST((SELECT COUNT(*) FROM #TF WHERE seq = @seq) AS nvarchar(10)), CAST((SELECT COUNT(*) FROM #TFV) AS nvarchar(10)),
                                       CASE WHEN (SELECT COUNT(*) FROM #TF WHERE seq = @seq) = (SELECT COUNT(*) FROM #TFV) THEN 'OK' ELSE 'MISMATCH' END;
                    -- row 1 Snapshot Ctr is not in the stream: an estimate is reported as INFO
                    INSERT #Val
                    SELECT N'TF 2388: row 1 Snapshot Ctr (estimate, not in stream)', CAST(t.[Snapshot Ctr] AS nvarchar(30)), CAST(v.[Snapshot Ctr] AS nvarchar(30)), 'INFO'
                    FROM #TF t JOIN #TFV v ON v.rowno = 1 WHERE t.seq = @seq AND t.rowno = 1 AND @snap IS NULL AND ISNULL(t.[Snapshot Ctr], -1) <> ISNULL(v.[Snapshot Ctr], -1);
                    ;WITH cmp AS (
                        SELECT t.rowno,
                               -- DBCC returns Updated at minute precision
                               CASE WHEN NOT ((t.Updated IS NULL AND v.Updated IS NULL) OR CONVERT(char(16), t.Updated, 120) = CONVERT(char(16), v.Updated, 120)) THEN N'Updated ' ELSE N'' END +
                               CASE WHEN NOT ((t.[Table Cardinality] IS NULL AND v.[Table Cardinality] IS NULL) OR ABS(t.[Table Cardinality] - v.[Table Cardinality]) <= 1e-6 * ABS(t.[Table Cardinality])) THEN N'Table Cardinality ' ELSE N'' END +
                               CASE WHEN NOT ((t.[Snapshot Ctr] IS NULL AND v.[Snapshot Ctr] IS NULL) OR t.[Snapshot Ctr] = v.[Snapshot Ctr] OR (t.rowno = 1 AND @snap IS NULL)) THEN N'Snapshot Ctr ' ELSE N'' END +
                               CASE WHEN NOT ((t.Steps IS NULL AND v.Steps IS NULL) OR t.Steps = v.Steps) THEN N'Steps ' ELSE N'' END +
                               CASE WHEN NOT ((t.Density IS NULL AND v.Density IS NULL) OR ABS(t.Density - v.Density) <= 1e-6 * ABS(t.Density)) THEN N'Density ' ELSE N'' END +
                               CASE WHEN NOT ((t.[Rows Above] IS NULL AND v.[Rows Above] IS NULL) OR ABS(t.[Rows Above] - v.[Rows Above]) <= 1e-6 * ABS(t.[Rows Above]) + 1e-9) THEN N'Rows Above ' ELSE N'' END +
                               CASE WHEN NOT ((t.[Rows Below] IS NULL AND v.[Rows Below] IS NULL) OR ABS(t.[Rows Below] - v.[Rows Below]) <= 1e-6 * ABS(t.[Rows Below]) + 1e-9) THEN N'Rows Below ' ELSE N'' END +
                               CASE WHEN NOT ((t.[Squared Variance Error] IS NULL AND v.[Squared Variance Error] IS NULL) OR ABS(t.[Squared Variance Error] - v.[Squared Variance Error]) <= 1e-6 * ABS(t.[Squared Variance Error]) + 1e-9) THEN N'Squared Variance Error ' ELSE N'' END +
                               CASE WHEN NOT ((t.[Inserts Since Last Update] IS NULL AND v.[Inserts Since Last Update] IS NULL) OR ABS(t.[Inserts Since Last Update] - v.[Inserts Since Last Update]) <= 1e-6 * ABS(t.[Inserts Since Last Update]) + 1e-9) THEN N'Inserts ' ELSE N'' END +
                               CASE WHEN NOT ((t.[Deletes Since Last Update] IS NULL AND v.[Deletes Since Last Update] IS NULL) OR ABS(t.[Deletes Since Last Update] - v.[Deletes Since Last Update]) <= 1e-6 * ABS(t.[Deletes Since Last Update]) + 1e-9) THEN N'Deletes ' ELSE N'' END +
                               CASE WHEN ISNULL(t.[Leading column Type], N'') <> ISNULL(v.[Leading column Type], N'') THEN N'Leading column Type ' ELSE N'' END AS diff
                        FROM #TF t LEFT JOIN #TFV v ON v.rowno = t.rowno WHERE t.seq = @seq)
                    INSERT #Val
                    SELECT N'TF 2388: row ' + CAST(rowno AS nvarchar(5)), N'differs in: ' + diff, N'', 'MISMATCH' FROM cmp WHERE diff <> N''
                    UNION ALL
                    SELECT N'TF 2388: all rows and columns', CAST(COUNT(*) AS nvarchar(10)) + N' rows', CAST(SUM(CASE WHEN diff <> N'' THEN 1 ELSE 0 END) AS nvarchar(10)) + N' mismatching',
                           CASE WHEN SUM(CASE WHEN diff <> N'' THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'MISMATCH' END FROM cmp;
                END
            END

            --------------------------------------------------------------------
            -- Stage the result sets (fixed-schema tables: no recompiles)
            --------------------------------------------------------------------
            SET @stage = N'stage results';
            -- a table that shrank (or was emptied) since the last update: the pages percentage is not meaningful
            IF @pages > 0 AND @tablePages IS NOT NULL AND @tablePages < @pages AND ISNULL(@rows, 0) <> ISNULL(@rowsSampled, -1)
                SET @warn += N'The table has fewer pages now (' + CAST(@tablePages AS nvarchar(20)) + N') than were sampled at the last update (' + CAST(@pages AS nvarchar(20)) + N'): it shrank since; the statistics are stale and Pages Sampled Percent is not meaningful. ';
            INSERT #rs1
            SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName,
                   N'Statistics', @label, t.kind, @DatabaseName, t.schema_name, t.table_name, t.stats_name, t.stats_id, t.auto_created,
                   t.user_created, t.no_recompute, t.is_incremental, t.is_temporary, t.filter_definition, t.modification_counter,
                   t.auto_drop, t.has_persisted_sample, NULLIF(RTRIM(@warn), N''), @s
            FROM #T t WHERE t.seq = @seq;

            INSERT #rs2
            SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName,
                   N'Stream Header', @label, @hdrVer, @ncols,
                   CONVERT(binary(4), CAST(CASE WHEN @crcStored >= 2147483648 THEN @crcStored - 4294967296 ELSE @crcStored END AS int)),
                   CASE WHEN @crcCalc IS NULL THEN 'NOT CHECKED' WHEN @crcCalc = @crcStored THEN 'VALID' ELSE 'INVALID' END,
                   CONVERT(binary(4), CAST(CASE WHEN @crcCalc >= 2147483648 THEN @crcCalc - 4294967296 ELSE @crcCalc END AS int)),
                   @slen, @len, @blen, @res8, @res20;

            INSERT #rs3
            SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName,
                   N'Stats Columns', @label, ordinal, name, type_name, sys_type, user_type, max_length, [precision], scale, is_nullable,
                   CONVERT(binary(1), flags), CASE WHEN collation_id <> 0 THEN CONVERT(binary(4), collation_id) END,
                   collation_name, code_page, extra12, CONVERT(binary(2), unused2),
                   CONVERT(binary(4), CAST(CASE WHEN unused20 >= 2147483648 THEN unused20 - 4294967296 ELSE unused20 END AS int))
            FROM #Cols;

            INSERT #rs4
            SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName,
                   N'Blob Header', @label, @bver, @updated, @rows, @rowsSampled,
                   CASE WHEN @rows > 0 THEN CAST(100.0 * @rowsSampled / @rows AS decimal(19, 4)) END,
                   CASE WHEN @rows IS NULL THEN NULL WHEN @rows = @rowsSampled THEN 'FULLSCAN' ELSE 'SAMPLED' END,
                   @density, @steps, @steps + CASE WHEN @nullEq > 0 THEN 1 ELSE 0 END, @steps2, @vc, @mrs, @akl, @rowsReal, @nullEq,
                   @unfiltered, @pages, @tablePages,
                   -- FULLSCAN reads every page (its stream usually has no page count; incremental statistics keep
                   -- the count of a partition resample). Otherwise: sampled pages (last update) / current table pages.
                   CASE WHEN @rows IS NOT NULL AND @rows = @rowsSampled THEN CAST(100 AS decimal(19, 4))
                        WHEN @pages IS NOT NULL AND @tablePages > 0 THEN CAST(100.0 * @pages / @tablePages AS decimal(19, 4)) END,
                   @persisted, CASE WHEN @hasSI = 1 THEN 'YES' ELSE 'NO' END, @leading,
                   CASE WHEN @maskLo IS NOT NULL THEN CONVERT(binary(4), CAST(CASE WHEN @maskHi >= 2147483648 THEN @maskHi - 4294967296 ELSE @maskHi END AS int)) +
                                                      CONVERT(binary(4), CAST(CASE WHEN @maskLo >= 2147483648 THEN @maskLo - 4294967296 ELSE @maskLo END AS int)) END,
                   @csPages, @streamFlags;

            INSERT #rs5
            SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Variable Items', @label, bit, name, rel_start, abs_start, len
            FROM #Items;

            INSERT #rs6
            SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Density Vector', @label, vec, AllDensity, AverageLength, ColumnAverageLength, Columns
            FROM #DV;

            INSERT #rs7
            SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Histogram', @label, step, RANGE_HI_KEY, RANGE_HI_KEY_TEXT, RANGE_ROWS, EQ_ROWS,
                   DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS, StoredAvgRangeRows, RecordOffset, RecordLength, KeyBytes
            FROM #Hist;

            INSERT #rs8
            SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Update History', @label, rec, Updated, TableCardinality, SnapshotCtr, Steps, Density,
                   RowsAbove, RowsBelow, Inserts, Deletes, SqVarErr
            FROM #UH;

            INSERT #rs9
            SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Trace Flag 2388', @label, rowno, Updated, [Table Cardinality], [Snapshot Ctr], Steps, Density,
                   [Rows Above], [Rows Below], [Squared Variance Error], [Inserts Since Last Update], [Deletes Since Last Update], [Leading column Type], [Snapshot Ctr Source]
            FROM #TFV;

            IF @IncludeStringIndex = 1 AND @nodeBase IS NOT NULL
            BEGIN
                INSERT #rs10
                SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'String Index', @label,
                       MAX(CASE fld WHEN 'sampled' THEN i END), MAX(CASE fld WHEN 'nulls' THEN i END), MAX(CASE fld WHEN 'distinct' THEN i END),
                       (SELECT SUM([Count]) FROM #SIN), MAX(CASE fld WHEN 'clen' THEN i END), MAX(CASE fld WHEN 'nodes' THEN i END),
                       CONVERT(binary(1), CAST(MAX(CASE fld WHEN 'marker' THEN i END) AS tinyint)), MAX(CASE fld WHEN 'ver' THEN i END),
                       MAX(CASE fld WHEN 'prefix' THEN i END), MAX(CASE fld WHEN 'suffix' THEN i END), MAX(CASE fld WHEN 'u25' THEN i END), @cstr,
                       SUBSTRING(@s, @nodeEnd + 1, @itemEnd - @nodeEnd)
                FROM #F WHERE grp = 'si' HAVING COUNT(*) > 0;

                INSERT #rs11
                SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'String Index Nodes', @label, NodeIndex, Depth,
                       REPLICATE(N'  ', Depth) + CASE WHEN HasChildren = 1 THEN N'+ ' ELSE N'- ' END + N'''' + Segment + N'''',
                       [Count], CASE WHEN [Count] > 0 THEN FullText END, CONVERT(binary(1), Flags), HasChildren, HasSibling,
                       SegmentOffset, SegmentLength, Segment, FullText
                FROM #SIN WHERE NodeIndex < @walk;
            END

            IF @IncludeSampledScanDump = 1
                INSERT #rs12
                SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Sampled Scan Dump', @label, f.idx, f.i, c.i,
                       x.s, x.mn, x.mx,
                       (SELECT STRING_AGG(CAST(CONVERT(nvarchar(30), d.v, 3) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY d.j)
                        FROM #SD d WHERE d.vec = f.idx AND (@MaxSampledScanValues = 0 OR d.j < @MaxSampledScanValues)),
                       -- hashes in (0, 1): exact below the 1024-value capacity, else the k-minimum-values estimate (k - 1) / max
                       CASE WHEN c.i < 1024 THEN c.i WHEN x.mx > 0 THEN (c.i - 1) / x.mx END
                FROM #F f JOIN #F c ON c.grp = 'sdc' AND c.idx = f.idx
                CROSS APPLY (SELECT SUM(v) s, MIN(v) mn, MAX(v) mx FROM #SD WHERE vec = f.idx) x
                WHERE f.grp = 'sdo';

            IF @IncludeUnknownItems = 1
                INSERT #rs13
                SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Unknown Items', @label, Item, StreamOffset, Length, Hex FROM #Unk;

            IF @IncludeLayout = 1
                INSERT #rs14
                SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Layout', @label, ofs, CONVERT(binary(4), ofs), len,
                       grp + CASE WHEN idx > 0 THEN '[' + CAST(idx AS varchar(10)) + ']' ELSE '' END + '.' + fld,
                       SUBSTRING(@s, ofs + 1, len), i, fl, dt
                FROM #F WHERE grp IN ('h', 'c', 'b', 'd', 'o', 'x', 'si', 'uc', 'csn', 'cs')
                UNION ALL
                SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Layout', @label, CAST(abs_start AS int), CONVERT(binary(4), CAST(abs_start AS int)), CAST(len AS int),
                       'item.bit' + CAST(bit AS varchar(5)) + ' ' + CAST(name AS varchar(60)), NULL, NULL, NULL, NULL
                FROM #Items;

            IF @Validate = 1
                INSERT #rs15
                SELECT @CollectionTime, @DatabaseName, @emitSchema, @emitTable, @statName, N'Validation', @label, seq, [Check], [Server], [Decoded], Result FROM #Val;

            --------------------------------------------------------------------
            -- Emit: client result sets now, or buffered writes to the output tables
            --------------------------------------------------------------------
            SET @stage = N'emit results';
            IF @OutputDatabase IS NULL
            BEGIN
                SELECT Section, [Statistic], Kind, [Database], [Schema], [Table], [Stats Name], [Stats Id], [Auto Created], [User Created], [No Recompute],
                       [Incremental], [Temporary], [Filter], [Modification Counter], [Auto Drop], [Has Persisted Sample], Warnings, StatsStream FROM #rs1;
                SELECT Section, [Statistic], [Stream Version], [Number Of Columns], [Checksum], [Checksum Status], [Calculated Checksum], [Stream Length],
                       [Actual Length], [Blob Length], [Reserved 8-15], [Reserved 20-23] FROM #rs2;
                SELECT Section, [Statistic], [#], [Name], [Type], [System Type Id], [User Type Id], [Max Length], [Precision], [Scale], [Nullable], [Flags],
                       [Collation Id], [Collation], [Code Page], [Bytes 12-15], [Bytes 2-3 (unused)], [Bytes 20-23 (unused)] FROM #rs3 ORDER BY [#];
                SELECT Section, [Statistic], [Blob Version], [Updated], [Rows], [Rows Sampled], [Sample Percent], [Scan], [Density], [Steps (stored)],
                       [Steps (DBCC)], [Steps (second copy)], [Vector Count], [Histogram Fixed Length], [Average Key Length], [Rows (real copy)],
                       [NULL Step EQ_ROWS], [Unfiltered Rows], [Pages Sampled], [Table Pages (current)], [Pages Sampled Percent],
                       [Persisted Sample Percent], [String Index], [Leading Column Type], [Presence Bitmask], [Columnstore Page Counts],
                       [Streaming Statistics Flags] FROM #rs4;
                SELECT Section, [Statistic], [Bit], [Name], [Relative Offset], [Stream Offset], [Length] FROM #rs5 ORDER BY [Bit];
                SELECT Section, [Statistic], [Vector], [All density], [Average Length], [Column Average Length (stored)], Columns FROM #rs6 ORDER BY [Vector];
                SELECT Section, [Statistic], [Step], RANGE_HI_KEY, RANGE_HI_KEY_TEXT, RANGE_ROWS, EQ_ROWS, DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS,
                       [Stored AVG_RANGE_ROWS], [Record Offset], [Record Length], [Key Bytes] FROM #rs7 ORDER BY [Step];
                SELECT Section, [Statistic], [Record], Updated, [Table Cardinality], [Snapshot Ctr], Steps, Density, [Next: Rows Above], [Next: Rows Below],
                       [Next: Inserts], [Next: Deletes], [Next: Squared Variance Error] FROM #rs8 ORDER BY [Record];
                SELECT Section, [Statistic], [Row], Updated, [Table Cardinality], [Snapshot Ctr], Steps, Density, [Rows Above], [Rows Below],
                       [Squared Variance Error], [Inserts Since Last Update], [Deletes Since Last Update], [Leading column Type], [Snapshot Ctr Source]
                FROM #rs9 ORDER BY [Row];
                IF @IncludeStringIndex = 1
                BEGIN
                    SELECT Section, [Statistic], [Strings Sampled (incl. NULL)], [NULLs In Sample], [Distinct Strings], [Sum Of Node Counts],
                           [Compressed Length (chars)], [Node Count], [Trie Marker], [Trie Version], [Full Prefix], [Full Suffix], [Unused +25], [Compressed String], [Trailer]
                    FROM #rs10;
                    SELECT Section, [Statistic], [Node], Depth, [Tree], [Strings Ending Here], [String], Flags, [Has Children], [Has Sibling],
                           [Segment Offset], [Segment Length], Segment, [Full Text] FROM #rs11 ORDER BY [Node];
                END
                IF @IncludeSampledScanDump = 1
                    SELECT Section, [Statistic], [Vector], [Offset], [Count], [Sum], [Min], [Max], [Distinct In Sample], [Values] FROM #rs12 ORDER BY [Vector];
                IF @IncludeUnknownItems = 1
                    SELECT Section, [Statistic], Item, [Stream Offset], Length, Hex FROM #rs13;
                IF @IncludeLayout = 1
                    SELECT Section, [Statistic], [Offset], [Offset Hex], [Length], [Field], [Bytes], [Integer], [Float], [Datetime] FROM #rs14 ORDER BY [Offset], [Length] DESC;
                IF @Validate = 1
                    SELECT Section, [Statistic], [Check #], [Check], [Server], [Decoded], Result FROM #rs15 ORDER BY [Check #];
                TRUNCATE TABLE #rs1; TRUNCATE TABLE #rs2; TRUNCATE TABLE #rs3; TRUNCATE TABLE #rs4; TRUNCATE TABLE #rs5;
                TRUNCATE TABLE #rs6; TRUNCATE TABLE #rs7; TRUNCATE TABLE #rs8; TRUNCATE TABLE #rs9; TRUNCATE TABLE #rs10;
                TRUNCATE TABLE #rs11; TRUNCATE TABLE #rs12; TRUNCATE TABLE #rs13; TRUNCATE TABLE #rs14; TRUNCATE TABLE #rs15;
            END
            ELSE
            BEGIN
                SET @pending += 1;
                IF @pending >= @FlushEvery
                BEGIN
                    EXEC sys.sp_executesql @flushSql;
                    SET @pending = 0;
                END
            END
        END TRY
        BEGIN CATCH
            -- this statistics object is skipped (lock timeout, read error, ...); the next one continues
            INSERT #Skipped (db, schema_name, table_name, stats_name, object_id, stats_id, stage, error_number, error_message)
            VALUES (@DatabaseName, @emitSchema, @emitTable, @statName, @objId, @statsId, @stage, ERROR_NUMBER(), ERROR_MESSAGE());
            -- drop rows of this statistics object that were already staged
            DELETE #rs1 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs2 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs3 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs4 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs5 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs6 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs7 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs8 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs9 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs10 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs11 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs12 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs13 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs14 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
            DELETE #rs15 WHERE [Schema Name] = @emitSchema AND [Table Name] = @emitTable AND [Statistics Name] = @statName;
        END CATCH

        -- report new skips right away (enumeration skips show up after the first statistics object)
        IF EXISTS (SELECT 1 FROM #Skipped WHERE seq > @skipPrintedSeq)
        BEGIN
            WHILE EXISTS (SELECT 1 FROM #Skipped WHERE seq > @skipPrintedSeq)
            BEGIN
                SELECT TOP (1) @skipPrintedSeq = seq,
                       @msg = CONVERT(nvarchar(19), SYSDATETIME(), 120) + N'    SKIPPED ' + QUOTENAME(ISNULL(db, @DatabaseName)) + N'.'
                            + ISNULL(QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name), N'(object_id ' + ISNULL(CAST(object_id AS nvarchar(12)), N'?') + N')')
                            + ISNULL(N'.' + QUOTENAME(stats_name), ISNULL(N' (stats_id ' + CAST(stats_id AS nvarchar(12)) + N')', N''))
                            + N'  [' + ISNULL(stage, N'?') + N'] ' + ISNULL(CAST(error_number AS nvarchar(10)), N'') + N': ' + ISNULL(LEFT(error_message, 300), N'')
                FROM #Skipped WHERE seq > @skipPrintedSeq ORDER BY seq;
                SET @skipPrinted += 1;
                IF @skipPrinted <= 50 RAISERROR(N'%s', 0, 1, @msg) WITH NOWAIT;
                ELSE IF @skipPrinted = 51 RAISERROR(N'    (more skipped statistics are not printed; see the Skipped table / result set)', 0, 1) WITH NOWAIT;
            END
            IF @skipSql IS NOT NULL
                EXEC sys.sp_executesql @skipSql, N'@at datetime2(3), @last int, @lastOut int OUTPUT', @CollectionTime, @skipWritten, @skipWritten OUTPUT;
        END

        -- progress: every @ProgressSeconds and at the end
        IF @ProgressSeconds > 0 AND (DATEDIFF(second, @lastProgress, SYSDATETIME()) >= @ProgressSeconds OR @seq = @maxSeq)
        BEGIN
            SET @pDone = @ProgressDone + @enumSkipped + @seq;
            SET @pTotal = CASE WHEN ISNULL(@ProgressTotal, 0) < @ProgressDone + @enumSkipped + @maxSeq THEN @ProgressDone + @enumSkipped + @maxSeq ELSE @ProgressTotal END;
            SET @elapsedS = DATEDIFF(second, @ProgressStart, SYSDATETIME());
            SET @remainS = CAST(1.0 * DATEDIFF(millisecond, @ProgressStart, SYSDATETIME()) * (@pTotal - @pDone) / NULLIF(@pDone, 0) / 1000 AS bigint);
            SET @msg = CONVERT(nvarchar(19), SYSDATETIME(), 120) + N'    '
                     + RIGHT(N'     ' + CONVERT(nvarchar(10), CAST(100.0 * @pDone / NULLIF(@pTotal, 0) AS decimal(5, 1))), 5) + N'%%'   -- %% = literal % in RAISERROR
                     + N'  stats ' + CAST(@pDone AS nvarchar(20)) + N'/' + CAST(@pTotal AS nvarchar(20))
                     + N'  | ' + @DatabaseName + N' ' + CAST(@seq AS nvarchar(10)) + N'/' + CAST(@maxSeq AS nvarchar(10))
                     + N'  | elapsed ' + CAST(@elapsedS / 3600 AS nvarchar(10)) + N':' + RIGHT(N'0' + CAST(@elapsedS / 60 % 60 AS nvarchar(2)), 2) + N':' + RIGHT(N'0' + CAST(@elapsedS % 60 AS nvarchar(2)), 2)
                     + ISNULL(N'  | remaining ~' + CAST(@remainS / 3600 AS nvarchar(10)) + N':' + RIGHT(N'0' + CAST(@remainS / 60 % 60 AS nvarchar(2)), 2) + N':' + RIGHT(N'0' + CAST(@remainS % 60 AS nvarchar(2)), 2)
                              + N'  | ETA ' + CONVERT(nvarchar(8), DATEADD(second, @remainS, SYSDATETIME()), 108), N'')
                     + CASE WHEN EXISTS (SELECT 1 FROM #Skipped) THEN N'  | skipped ' + CAST((SELECT COUNT(*) FROM #Skipped) AS nvarchar(10)) ELSE N'' END;
            RAISERROR(@msg, 0, 1) WITH NOWAIT;
            SET @lastProgress = SYSDATETIME();
        END

        SET @seq += 1;
    END

    -- output mode: write what is still buffered
    IF @OutputDatabase IS NOT NULL AND @pending > 0
        EXEC sys.sp_executesql @flushSql;

    ----------------------------------------------------------------------------
    -- Skipped statistics (lock timeouts and other read errors)
    ----------------------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM #Skipped)
    BEGIN
        -- skips not reported yet (e.g. every statistics object of the call was skipped during enumeration)
        WHILE EXISTS (SELECT 1 FROM #Skipped WHERE seq > @skipPrintedSeq)
        BEGIN
            SELECT TOP (1) @skipPrintedSeq = seq,
                   @msg = CONVERT(nvarchar(19), SYSDATETIME(), 120) + N'    SKIPPED ' + QUOTENAME(ISNULL(db, @DatabaseName)) + N'.'
                        + ISNULL(QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name), N'(object_id ' + ISNULL(CAST(object_id AS nvarchar(12)), N'?') + N')')
                        + ISNULL(N'.' + QUOTENAME(stats_name), ISNULL(N' (stats_id ' + CAST(stats_id AS nvarchar(12)) + N')', N''))
                        + N'  [' + ISNULL(stage, N'?') + N'] ' + ISNULL(CAST(error_number AS nvarchar(10)), N'') + N': ' + ISNULL(LEFT(error_message, 300), N'')
            FROM #Skipped WHERE seq > @skipPrintedSeq ORDER BY seq;
            SET @skipPrinted += 1;
            IF @skipPrinted <= 50 RAISERROR(N'%s', 0, 1, @msg) WITH NOWAIT;
        END
        IF @skipSql IS NOT NULL
            EXEC sys.sp_executesql @skipSql, N'@at datetime2(3), @last int, @lastOut int OUTPUT', @CollectionTime, @skipWritten, @skipWritten OUTPUT;

        SET @msg = CAST((SELECT COUNT(*) FROM #Skipped) AS nvarchar(10)) + N' item(s) skipped in ' + QUOTENAME(@DatabaseName)
                 + N' (blocked for more than 100 ms or unreadable); see the Skipped result set / table.';
        RAISERROR(N'%s', 10, 1, @msg) WITH NOWAIT;
        IF @OutputDatabase IS NULL
            SELECT N'Skipped' AS Section, db AS [Database], schema_name AS [Schema], table_name AS [Table], stats_name AS [Stats Name],
                   object_id AS [Object Id], stats_id AS [Stats Id], stage AS [Stage], error_number AS [Error Number], error_message AS [Error Message]
            FROM #Skipped ORDER BY seq;
    END
END
GO
