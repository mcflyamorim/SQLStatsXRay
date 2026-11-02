#Requires -Version 5.1

<#
.SYNOPSIS
    SQLStatsXRay: reads a statistics object's STATS_STREAM from SQL Server and decodes it completely.

.DESCRIPTION
    Decodes the undocumented binary returned by DBCC SHOW_STATISTICS ... WITH STATS_STREAM
    (the same structure stored in sys.sysobjvalues valclass 60) and prints a full report:

      * STATS_STREAM header (version, column count, checksum + CRC validation, sizes)
      * Stats column definitions (type, length, precision, scale, nullability, collation)
      * Stats blob fixed section (version, updated, rows, rows sampled, density, steps,
        vector count, histogram record length, average key length, NULL step, densities and
        average lengths for vectors 1-33)
      * Stats blob variable section, located through its presence bitmask + offset array:
          bit 0  Histogram                     bit 6  Columnstore page counts
          bit 1  String index (trie)           bit 7  Pages sampled
          bit 3  Update history (TF 2388)      bit 8  Densities, vectors 33 to n-1
          bit 4  Unfiltered rows               bit 9  Average lengths, columns 34+
          bit 5  Distinct value synopsis       bit 10 Persisted sample percent
                                               bit 11 Streaming statistics flags
        Unknown bits are reported with a hex dump, so nothing in the stream is skipped.
      * Density vector, histogram (with the NULL step), update history, string index tree,
        distinct value synopsis.

    Histogram keys are decoded for every type that can carry statistics: integer types, bit,
    decimal/numeric, money/smallmoney, float/real, date/time/datetime/datetime2/
    datetimeoffset/smalldatetime, char/varchar/nchar/nvarchar (code page from the collation,
    UTF-8 included), binary/varbinary/rowversion, uniqueidentifier, sql_variant and
    hierarchyid.

    The layout was reverse engineered on SQL Server 2025 (17.x), building on the work of
    André Renato Furtado (SqlServerForenseLab/StatsStreamParser) and Joe Chang. It is not
    an official Microsoft format: validate with -Validate before relying on it.

    Statistics streams carry histogram boundary values, which are real data. Be careful
    where you paste or store the report, especially for customer databases.

.PARAMETER ServerInstance
    SQL Server instance to read from (for example "amorim-PF5ZTLCK\SQL2025").

.PARAMETER Database
    Database that holds the table.

.PARAMETER Table
    Table or indexed view, optionally schema qualified ("dbo.Orders" or "Sales.[Order Lines]").

.PARAMETER Statistics
    One or more statistics/index names. Default: every statistics object on the table.

.PARAMETER Credential
    SQL login credential. Default: Windows integrated authentication.

.PARAMETER ConnectionString
    Full connection string; overrides ServerInstance/Database/Credential.

.PARAMETER TrustServerCertificate
    Adds Encrypt=True;TrustServerCertificate=True to the connection.

.PARAMETER Validate
    Also runs DBCC SHOW_STATISTICS (STAT_HEADER, DENSITY_VECTOR, HISTOGRAM) and compares
    every decoded value with what SQL Server reports.

.PARAMETER UseDac
    Opens a Dedicated Admin Connection (admin:<instance>, sysadmin) to read the current
    "Snapshot Ctr" of the trace flag 2388 result from sys.sysobjvalues. That value is not
    part of STATS_STREAM; without -UseDac the row count is shown as an estimate. Only one
    DAC session is allowed per instance, and remote DAC is disabled by default.

.PARAMETER VerifyData
    Checks each histogram against the table data. The table is read only through a rowstore
    index whose first key column is the statistics' leading column (the smallest such index),
    with one seek per step: it counts the real EQ_ROWS, RANGE_ROWS and DISTINCT_RANGE_ROWS,
    the largest number of rows for one value inside each step, the NULL rows and the rows
    above the last step. The queries run under READ UNCOMMITTED, LOCK_TIMEOUT 1000, MAXDOP 1
    and KEEPFIXED PLAN, which keeps them from triggering an automatic update of the
    statistics they check. Each range is rated by q-error (how many times the estimate is
    off, either way), and the results separate sampling error from modifications since the
    update. Filtered, incremental and columnstore statistics, and statistics with no
    supporting index, are skipped. Needs SELECT on the table. The results show step numbers
    and counts, not key values.

.PARAMETER VerifyPageBudget
    Leaf pages -VerifyData may read per statistics object. Above it, the check becomes a
    spot check: the NULL rows, both ends of the histogram, then steps at random while their
    estimated pages fit. Default 100000 (about 780 MB).

.PARAMETER VerifyTimeout
    Query timeout of each -VerifyData query, in seconds. Default 60.

.PARAMETER VerifyStepDelay
    Pause between -VerifyData queries, in milliseconds, to spread the reads. Default 0.

.PARAMETER Build
    BETA: still being developed; check its scripts on a test copy first.
    Builds a histogram of our own for one column, instead of decoding: reads the column's values
    (every row, or SQL Server's sample), runs the histogram algorithms, scores every candidate and
    the current statistics against the rows read (q-error per distinct value and over random
    ranges), and writes the script that loads the best candidate: CREATE STATISTICS ... WITH
    STATS_STREAM for a new statistics object (-Column), UPDATE STATISTICS ... WITH STATS_STREAM for
    an existing one (-Statistics, one column). Nothing is changed on the server. It handles
    numbers, dates and times, uniqueidentifier, binary and character columns (char, varchar,
    nchar, nvarchar: ordered by the server in the column's collation, with the string index for
    LIKE built from the same rows the way SQL Server builds it; none for UTF-8 collations and
    double-byte code pages).

.PARAMETER Column
    -Build: the column of a new statistics object.

.PARAMETER Sample
    -Build: Default (SQL Server's own default sample size), FULLSCAN, '<n> PERCENT' or '<n> ROWS',
    with SQL Server's rules (whole table under 1,024 pages, at least 1,024 pages otherwise).

.PARAMETER Sampler
    -Build: SqlServer reads the sample SQL Server would (TABLESAMPLE of base table pages). Adaptive
    measures a pilot of about 64 pages (rows per page, how much the values cluster by page) and
    reads as many useful rows as SQL Server's sample would hold, from the table or from the leaf of
    the column's own index when that is cheaper; with an index on the column it also counts each
    step key's EQ_ROWS and the true minimum and maximum exactly.

.PARAMETER Algorithm
    -Build: histogram algorithms to try (default all): EqualRows, MaxDiff, FrequentFirst, VOptimal,
    and Workload (steps where the Query Store workload filters; only when it has values).

.PARAMETER AllStatistics
    -Build: builds every statistics object of the table the builder supports, from ONE read of the
    table (SQL Server reads it once per statistics object), and writes one script.

.PARAMETER ShowCandidates
    -Build: also lists every algorithm tried with all its scores. By default the report shows a
    verdict and only the chosen histogram next to SQL Server's current statistics.

.PARAMETER NoWorkload
    -Build: does not read the Query Store workload.

.PARAMETER AdaptiveLimit
    -Build -Sampler Adaptive: the most pages the adaptive sampler reads, as a multiple of SQL Server's
    sample (default 4). 0 = no limit.

.PARAMETER NewStatisticsName
    -Build -Column: name of the new statistics object (default xray_<column>).

.PARAMETER NoRecompute
    -Build: adds NORECOMPUTE to the script (recommended: otherwise the next automatic update
    replaces the built histogram).

.PARAMETER OutputScript
    -Build: writes the script to this file (UTF-8) instead of appending it to the report.

.PARAMETER Seed
    -Build: seed of the sample (TABLESAMPLE REPEATABLE) and of the random ranges used to score.

.PARAMETER StatsStream
    Offline mode: the STATS_STREAM as a hex string (with or without 0x).

.PARAMETER InputFile
    Offline mode: file with the STATS_STREAM as hex text, or the raw binary (.bin).

.PARAMETER ColumnNames
    Offline mode: names to show for the stats columns (default Column1..N).

.PARAMETER CodePage
    Offline mode: code page for char/varchar keys when the collation is not in the
    built-in map. Server mode always resolves collations on the server.

.PARAMETER OutputFile
    Writes the report to this file (UTF-8) as well.

.PARAMETER PassThru
    Returns the decoded objects instead of the text report.

.PARAMETER IncludeHexDump
    Appends an annotated layout map and a full hex dump of the stream.

.PARAMETER MaxStringIndexNodes
    Maximum trie nodes printed in the string index tree (0 = all). Default 300.

.PARAMETER MaxSampledScanValues
    Values printed per vector from the distinct value synopsis (0 = all). Default 20.

.PARAMETER FullPrecision
    Prints float values round-trip exact instead of DBCC-like 7 significant digits.

.PARAMETER Gui
    Opens SQLStatsXRay, the Windows Forms app (dark or light theme, saved per user). This is the default
    when the script runs without parameters. The app browses databases, tables and
    statistics on a server, or takes a hex string or file, and shows the report plus
    header, histogram, density vector, trace flag 2388 and validation grids. The Data check
    tab runs the -VerifyData check for the selected statistics object on request (F6).
    With "Edit statistics" on, the header values, histogram steps (insert and delete
    with a right click) and density vector can be changed. "Generate script..." then
    rebuilds the STATS_STREAM with a new checksum and writes an
    UPDATE STATISTICS ... WITH STATS_STREAM script, optionally with NORECOMPUTE and a
    commented block that restores the original statistics. The app never runs the
    script. STATS_STREAM is undocumented: load edited statistics on test copies. Run it from an STA
    host (Windows PowerShell 5.1 and PowerShell 7 are STA by default), or use
    SQLStatsXRay.cmd.

.EXAMPLE
    PS> .\Decode-StatsStream.ps1

    Opens the SQLStatsXRay app.

.EXAMPLE
    PS> .\Decode-StatsStream.ps1 -ServerInstance "amorim-PF5ZTLCK\SQL2025" -Database AdventureWorks -Table Sales.SalesOrderDetail -Statistics IX_SalesOrderDetail_ProductID

.EXAMPLE
    PS> .\Decode-StatsStream.ps1 -ServerInstance . -Database DB1 -Table dbo.T -Validate -OutputFile .\T_stats.txt

.EXAMPLE
    PS> .\Decode-StatsStream.ps1 -InputFile .\stream.txt -ColumnNames OrderDate

.EXAMPLE
    PS> $s = .\Decode-StatsStream.ps1 -ServerInstance . -Database DB1 -Table dbo.T -Statistics s1 -PassThru
    $s.Histogram | Format-Table
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Gui')]
    [switch]$Gui,

    [Parameter(ParameterSetName = 'Server', Mandatory = $true)]
    [string]$ServerInstance,

    [Parameter(ParameterSetName = 'Server', Mandatory = $true)]
    [Parameter(ParameterSetName = 'ConnStr', Mandatory = $true)]
    [string]$Database,

    [Parameter(ParameterSetName = 'Server', Mandatory = $true)]
    [Parameter(ParameterSetName = 'ConnStr', Mandatory = $true)]
    [string]$Table,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [string[]]$Statistics,

    [Parameter(ParameterSetName = 'Server')]
    [pscredential]$Credential,

    [Parameter(ParameterSetName = 'ConnStr', Mandatory = $true)]
    [string]$ConnectionString,

    [Parameter(ParameterSetName = 'Server')]
    [switch]$TrustServerCertificate,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [switch]$Validate,

    [Parameter(ParameterSetName = 'Server')]
    [switch]$UseDac,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [switch]$VerifyData,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [long]$VerifyPageBudget = 100000,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [int]$VerifyTimeout = 60,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [int]$VerifyStepDelay = 0,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [switch]$Build,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [string]$Column,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [string]$Sample = 'Default',

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [ValidateSet('SqlServer', 'Adaptive')]
    [string]$Sampler = 'SqlServer',

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [ValidateSet('EqualRows', 'MaxDiff', 'FrequentFirst', 'VOptimal', 'Workload')]
    [string[]]$Algorithm,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [switch]$AllStatistics,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [switch]$ShowCandidates,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [switch]$NoWorkload,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [double]$AdaptiveLimit = 4,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [string]$NewStatisticsName,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [switch]$NoRecompute,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [string]$OutputScript,

    [Parameter(ParameterSetName = 'Server')]
    [Parameter(ParameterSetName = 'ConnStr')]
    [int]$Seed = 1,

    [Parameter(ParameterSetName = 'Hex', Mandatory = $true)]
    [string]$StatsStream,

    [Parameter(ParameterSetName = 'File', Mandatory = $true)]
    [string]$InputFile,

    [Parameter(ParameterSetName = 'Hex')]
    [Parameter(ParameterSetName = 'File')]
    [string[]]$ColumnNames,

    [Parameter(ParameterSetName = 'Hex')]
    [Parameter(ParameterSetName = 'File')]
    [int]$CodePage = 0,

    [string]$OutputFile,
    [switch]$PassThru,
    [switch]$IncludeHexDump,
    [int]$MaxStringIndexNodes = 300,
    [int]$MaxSampledScanValues = 20,
    [switch]$FullPrecision,

    # Used by the app's background run: returns the decoded objects and the report together.
    [Parameter(DontShow = $true)]
    [switch]$GuiRun
)

$ErrorActionPreference = 'Stop'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# .NET Core (PowerShell 7) needs the code pages provider for 1252, 932, ...
try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch { }

#region ---------------------------------------------------------------- constants

$script:TypeNames = @{
    34 = 'image'; 35 = 'text'; 36 = 'uniqueidentifier'; 40 = 'date'; 41 = 'time'; 42 = 'datetime2'
    43 = 'datetimeoffset'; 48 = 'tinyint'; 52 = 'smallint'; 56 = 'int'; 58 = 'smalldatetime'
    59 = 'real'; 60 = 'money'; 61 = 'datetime'; 62 = 'float'; 98 = 'sql_variant'; 99 = 'ntext'
    104 = 'bit'; 106 = 'decimal'; 108 = 'numeric'; 122 = 'smallmoney'; 127 = 'bigint'
    165 = 'varbinary'; 167 = 'varchar'; 173 = 'binary'; 175 = 'char'; 189 = 'timestamp'
    231 = 'nvarchar'; 239 = 'nchar'; 240 = 'clr_udt'; 241 = 'xml'; 244 = 'json'; 255 = 'vector'
}

# Presence bitmask of the blob's variable section. Items follow bit order in the offset array.
$script:VarItemNames = @{
    0 = 'Histogram'; 1 = 'String Index'; 3 = 'Update History'; 4 = 'Unfiltered Rows'
    5 = 'Distinct Value Synopsis'; 6 = 'Columnstore Page Counts'; 7 = 'Pages Sampled'
    8 = 'Densities (vectors 33 to n-1)'; 9 = 'Average Lengths (columns 34+)'; 10 = 'Persisted Sample Percent'
    11 = 'Streaming Statistics Flags'
}

# Offline collation -> code page map, derived from sys.fn_helpcollations() on SQL Server 2025.
# Windows collations: (CollationId & 0x7F) -> code page; SQL collations: sort id (CollationId >> 24).
# CollationId bit 0x80 set means a UTF-8 collation.
$script:WinCollationCodePage = @{}
'1:1256 2:1256 3:950 4:1250 5:1252 6:1251 7:1253 8:1252 9:1252 10:1252 11:1252 12:1255 13:1250 14:1252 15:1252 16:932 17:949 19:1250 20:1250 21:1251 22:1250 23:1250 24:1250 25:874 26:1254 27:1251 28:1250 29:1257 30:1257 31:1257 32:1258 36:936 37:1256 38:1252 40:1252 41:1252 42:1250 43:932 45:1252 46:936 47:950 48:932 49:936 50:936 51:950 52:950 55:1251 56:1254 57:1251 58:1251 62:950 63:1252 64:949 65:950 66:950 67:936 68:936 69:950 70:950 71:1252 72:932 73:932 74:1252 75:1252 76:1250 77:1251 78:1250 79:1251 80:1256 81:1256 82:1252 83:1252 84:1251 86:1252 87:1252 88:1250 93:1252 96:1252 97:1252 99:1254 100:1251'.Split(' ') |
    ForEach-Object { $p = $_.Split(':'); $script:WinCollationCodePage[[int]$p[0]] = [int]$p[1] }
$script:SqlSortIdCodePage = @{}
'30-34:437 40-44:850 49:850 51-54:1252 55-61:850 81-96:1250 105-108:1251 113:1253 114:1253 120:1253 122:1253 124:1253 130:1254 131:1254 138:1255 139:1255 146:1256 147:1256 154-161:1257 184-187:1252 211-220:1252'.Split(' ') |
    ForEach-Object {
        $p = $_.Split(':'); $r = $p[0].Split('-'); $hi = $r[$r.Count - 1]
        foreach ($i in ([int]$r[0])..([int]$hi)) { $script:SqlSortIdCodePage[$i] = [int]$p[1] }
    }

#endregion

#region ---------------------------------------------------------------- byte helpers

function Get-Bytes([byte[]]$Buffer, [long]$Offset, [long]$Count) {
    if ($Count -le 0) { return , ([byte[]]@()) }
    $r = New-Object byte[] $Count
    [Array]::Copy($Buffer, $Offset, $r, 0, $Count)
    return , $r
}

function ConvertTo-Hex([byte[]]$Bytes, [int]$Max = 0) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '0x' }
    $b = $Bytes
    $suffix = ''
    if ($Max -gt 0 -and $Bytes.Length -gt $Max) { $b = Get-Bytes $Bytes 0 $Max; $suffix = "... ($($Bytes.Length) bytes)" }
    return '0x' + [BitConverter]::ToString($b).Replace('-', '') + $suffix
}

function ConvertFrom-HexString([string]$Text) {
    $h = ($Text -replace '\s', '')
    if ($h.StartsWith('0x') -or $h.StartsWith('0X')) { $h = $h.Substring(2) }
    if ($h.Length % 2 -ne 0) { throw 'Hex string has an odd number of digits.' }
    $r = New-Object byte[] ($h.Length / 2)
    for ($i = 0; $i -lt $r.Length; $i++) { $r[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }
    return , $r
}

function Read-UIntLE([byte[]]$Buffer, [int]$Offset, [int]$Count) {
    [uint64]$v = 0
    for ($i = $Count - 1; $i -ge 0; $i--) { $v = ($v -shl 8) -bor $Buffer[$Offset + $i] }
    return $v
}

function Get-StatsStreamCrc([byte[]]$Stream) {
    # CRC-32 (reflected, poly 0xEDB88320) over the stream with the checksum field (16..19) zeroed;
    # the stored value is the bitwise NOT of the standard CRC-32 result.
    # (int64 arithmetic: PowerShell reads 0xFFFFFFFF as the int32 -1)
    [int64]$mask = 4294967295
    if (-not $script:CrcTable) {
        [int64]$poly = 3988292384   # 0xEDB88320
        $script:CrcTable = New-Object 'int64[]' 256
        for ($n = 0; $n -lt 256; $n++) {
            [int64]$c = $n
            for ($k = 0; $k -lt 8; $k++) {
                if ($c -band 1) { $c = $poly -bxor ($c -shr 1) } else { $c = $c -shr 1 }
            }
            $script:CrcTable[$n] = $c
        }
    }
    [int64]$crc = $mask
    $t = $script:CrcTable
    for ($i = 0; $i -lt $Stream.Length; $i++) {
        $b = $Stream[$i]
        if ($i -ge 16 -and $i -le 19) { $b = 0 }
        $crc = $t[($crc -bxor $b) -band 255] -bxor ($crc -shr 8)
    }
    # standard CRC-32 = crc xor 0xFFFFFFFF; the stream stores its complement, i.e. crc itself
    return [uint32]($crc -band $mask)
}

function ConvertFrom-SqlDateTimeParts([int]$Days, [int]$Ticks) {
    # Same conversion SqlClient uses (1/300 s ticks, rounded to ms)
    return ([System.Data.SqlTypes.SqlDateTime]::new($Days, $Ticks)).Value
}

function ConvertFrom-SqlDateTimeBytes([byte[]]$Buffer, [int]$Offset) {
    $ticks = [BitConverter]::ToInt32($Buffer, $Offset)
    $days = [BitConverter]::ToInt32($Buffer, $Offset + 4)
    try { return ConvertFrom-SqlDateTimeParts $days $ticks } catch { return $null }
}

#endregion

#region ---------------------------------------------------------------- value decoding

function Get-TypeDisplayName($Col) {
    $n = $script:TypeNames[[int]$Col.SystemTypeId]
    if (-not $n) { $n = "type$($Col.SystemTypeId)" }
    if ($Col.SystemTypeId -eq 240 -and $Col.UserTypeId -eq 128) { return 'hierarchyid' }
    if ($Col.SystemTypeId -eq 240 -and $Col.UserTypeId -eq 129) { return 'geometry' }
    if ($Col.SystemTypeId -eq 240 -and $Col.UserTypeId -eq 130) { return 'geography' }
    switch ($n) {
        { $_ -in 'varchar', 'char', 'varbinary', 'binary' } {
            if ($Col.MaxLength -eq -1) { return "$n(max)" } else { return "$n($($Col.MaxLength))" }
        }
        { $_ -in 'nvarchar', 'nchar' } {
            if ($Col.MaxLength -eq -1) { return "$n(max)" } else { return "$n($($Col.MaxLength / 2))" }
        }
        { $_ -in 'decimal', 'numeric' } { return "$n($($Col.Precision),$($Col.Scale))" }
        { $_ -in 'datetime2', 'time', 'datetimeoffset' } { return "$n($($Col.Scale))" }
        'float' { if ($Col.MaxLength -eq 4) { return 'float(24)' } }
    }
    return $n
}

function Get-CodePage([int]$CollationId) {
    if ($script:CollationInfo -and $script:CollationInfo.ContainsKey($CollationId)) { return $script:CollationInfo[$CollationId].CodePage }
    if ($CollationId -band 0x80) { return 65001 }
    $sortId = ($CollationId -shr 24) -band 0xFF
    if ($sortId -ne 0 -and $script:SqlSortIdCodePage.ContainsKey($sortId)) { return $script:SqlSortIdCodePage[$sortId] }
    if ($sortId -eq 0 -and $script:WinCollationCodePage.ContainsKey($CollationId -band 0x7F)) {
        return $script:WinCollationCodePage[$CollationId -band 0x7F]
    }
    if ($CodePage -gt 0) { return $CodePage }
    return 1252
}

function Get-CollationName([int]$CollationId) {
    if ($CollationId -eq 0) { return '' }
    if ($script:CollationInfo -and $script:CollationInfo.ContainsKey($CollationId)) { return $script:CollationInfo[$CollationId].Name }
    return ''
}

function ConvertFrom-ScaledInteger([System.Numerics.BigInteger]$Value, [int]$Scale, [bool]$Negative) {
    $s = [System.Numerics.BigInteger]::Abs($Value).ToString($script:Inv)
    if ($Scale -gt 0) {
        $s = $s.PadLeft($Scale + 1, '0')
        $s = $s.Substring(0, $s.Length - $Scale) + '.' + $s.Substring($s.Length - $Scale)
    }
    if ($Negative -and $Value -ne 0) { $s = '-' + $s }
    return $s
}

function ConvertFrom-TimeBytes([byte[]]$Data, [int]$Offset, [int]$Count, [int]$Scale) {
    $units = Read-UIntLE $Data $Offset $Count
    $ticks = [int64]$units * [int64][Math]::Pow(10, 7 - $Scale)
    return [TimeSpan]::FromTicks($ticks)
}

function ConvertFrom-DateBytes([byte[]]$Data, [int]$Offset) {
    $days = [int](Read-UIntLE $Data $Offset 3)
    return ([datetime]::new(1, 1, 1)).AddDays($days)
}

function Get-TimeByteCount([int]$Scale) {
    if ($Scale -le 2) { return 3 } elseif ($Scale -le 4) { return 4 } else { return 5 }
}

function ConvertFrom-HierarchyIdBytes([byte[]]$Data) {
    if ($Data.Length -eq 0) { return '/' }
    if ($null -eq $script:HierarchyIdType) {
        $script:HierarchyIdType = $false
        $candidates = @()
        $candidates += 'Microsoft.SqlServer.Types, Version=17.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91'
        $candidates += 'Microsoft.SqlServer.Types, Version=16.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91'
        $candidates += 'Microsoft.SqlServer.Types, Version=15.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91'
        $candidates += 'Microsoft.SqlServer.Types, Version=14.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91'
        $candidates += 'Microsoft.SqlServer.Types, Version=13.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91'
        foreach ($c in $candidates) {
            try { $a = [Reflection.Assembly]::Load($c); $script:HierarchyIdType = $a.GetType('Microsoft.SqlServer.Types.SqlHierarchyId'); break } catch { }
        }
        if (-not $script:HierarchyIdType) {
            $paths = @(Get-ChildItem -Path "$env:ProgramFiles\Microsoft SQL Server" -Recurse -Filter 'Microsoft.SqlServer.Types.dll' -ErrorAction SilentlyContinue |
                    Sort-Object { $_.VersionInfo.FileVersion } -Descending)
            foreach ($p in $paths) {
                try { $a = [Reflection.Assembly]::LoadFrom($p.FullName); $script:HierarchyIdType = $a.GetType('Microsoft.SqlServer.Types.SqlHierarchyId'); if ($script:HierarchyIdType) { break } } catch { }
            }
        }
    }
    if ($script:HierarchyIdType) {
        try {
            $h = [Activator]::CreateInstance($script:HierarchyIdType)
            $ms = New-Object IO.MemoryStream (, $Data)
            $br = New-Object IO.BinaryReader $ms
            $script:HierarchyIdType.GetMethod('Read').Invoke($h, @($br))
            return $h.ToString()
        } catch { }
    }
    return $null   # resolved later on the server, or shown as hex
}

function ConvertFrom-SqlBytes {
    <# Decodes a value in SQL Server storage format. Returns a .NET value comparable with SqlClient. #>
    param([byte[]]$Data, [int]$SystemTypeId, [int]$UserTypeId, [int]$MaxLength, [int]$Precision, [int]$Scale, [int]$CollationId)

    switch ($SystemTypeId) {
        48 { return [byte]$Data[0] }
        52 { return [BitConverter]::ToInt16($Data, 0) }
        56 { return [BitConverter]::ToInt32($Data, 0) }
        127 { return [BitConverter]::ToInt64($Data, 0) }
        104 { return [bool]($Data[0] -band 1) }
        59 { return [BitConverter]::ToSingle($Data, 0) }
        62 { if ($Data.Length -eq 4) { return [BitConverter]::ToSingle($Data, 0) } else { return [BitConverter]::ToDouble($Data, 0) } }
        60 {
            # money: little-endian int64 / 10000
            $v = [BitConverter]::ToInt64($Data, 0)
            return ConvertFrom-ScaledInteger ([System.Numerics.BigInteger]$v) 4 ($v -lt 0)
        }
        122 {
            $v = [BitConverter]::ToInt32($Data, 0)
            return ConvertFrom-ScaledInteger ([System.Numerics.BigInteger]$v) 4 ($v -lt 0)
        }
        { $_ -eq 106 -or $_ -eq 108 } {
            # sign byte (1 = positive) + little-endian magnitude
            $mag = New-Object byte[] ($Data.Length)   # extra 0x00 keeps BigInteger positive
            [Array]::Copy($Data, 1, $mag, 0, $Data.Length - 1)
            $bi = New-Object System.Numerics.BigInteger (, $mag)
            return ConvertFrom-ScaledInteger $bi $Scale ($Data[0] -eq 0)
        }
        40 { return ConvertFrom-DateBytes $Data 0 }
        41 { return ConvertFrom-TimeBytes $Data 0 ($Data.Length) $Scale }
        42 {
            $tb = $Data.Length - 3
            $d = ConvertFrom-DateBytes $Data $tb
            return $d.Add((ConvertFrom-TimeBytes $Data 0 $tb $Scale))
        }
        43 {
            $tb = $Data.Length - 5
            $utc = (ConvertFrom-DateBytes $Data $tb).Add((ConvertFrom-TimeBytes $Data 0 $tb $Scale))
            $offMin = [BitConverter]::ToInt16($Data, $Data.Length - 2)
            $off = [TimeSpan]::FromMinutes($offMin)
            return New-Object DateTimeOffset ($utc.Add($off).Ticks, $off)
        }
        61 { return ConvertFrom-SqlDateTimeBytes $Data 0 }
        58 {
            $min = [BitConverter]::ToUInt16($Data, 0); $days = [BitConverter]::ToUInt16($Data, 2)
            return ([datetime]::new(1900, 1, 1)).AddDays($days).AddMinutes($min)
        }
        36 { return New-Object Guid (, $Data) }
        # text (35) and ntext (99) keys are stored like varchar / nvarchar
        { $_ -eq 175 -or $_ -eq 167 -or $_ -eq 35 } {
            $cp = Get-CodePage $CollationId
            try { $enc = [Text.Encoding]::GetEncoding($cp) } catch { $enc = [Text.Encoding]::GetEncoding(1252) }
            return $enc.GetString($Data)
        }
        { $_ -eq 239 -or $_ -eq 231 -or $_ -eq 99 } { return [Text.Encoding]::Unicode.GetString($Data) }
        { $_ -eq 173 -or $_ -eq 165 -or $_ -eq 189 } { return , $Data }
        98 {
            # sql_variant: base type, version, type properties, value
            $bt = [int]$Data[0]
            $p = 2; $prec = 0; $sc = 0; $coll = 0; $ml = 0
            if ($bt -in 106, 108) { $prec = $Data[2]; $sc = $Data[3]; $p = 4 }
            elseif ($bt -in 41, 42, 43) { $sc = $Data[2]; $p = 3 }
            elseif ($bt -in 165, 173) { $ml = [BitConverter]::ToInt16($Data, 2); $p = 4 }
            elseif ($bt -in 167, 175, 231, 239) { $ml = [BitConverter]::ToInt16($Data, 2); $coll = [BitConverter]::ToInt32($Data, 4); $p = 8 }
            $inner = Get-Bytes $Data $p ($Data.Length - $p)
            return ConvertFrom-SqlBytes -Data $inner -SystemTypeId $bt -UserTypeId $bt -MaxLength $ml -Precision $prec -Scale $sc -CollationId $coll
        }
        240 {
            if ($UserTypeId -eq 128) {
                $s = ConvertFrom-HierarchyIdBytes $Data
                if ($s) { return $s }
                return [pscustomobject]@{ PSTypeName = 'StatsStream.PendingHierarchyId'; Bytes = $Data }
            }
            return , $Data
        }
        default { return , $Data }
    }
}

function Format-Float($Value) {
    if ($null -eq $Value) { return '' }
    if ($FullPrecision) { return $Value.ToString('R', $script:Inv) }
    if ($Value -is [single]) { return $Value.ToString('G7', $script:Inv) }
    return ([double]$Value).ToString('G15', $script:Inv)
}

function Format-SqlValue($Value, [int]$SystemTypeId = 0, [int]$Scale = 7) {
    <# Display format, close to what SSMS shows. #>
    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [byte[]]) { return ConvertTo-Hex $Value }
    if ($Value.PSObject.TypeNames -contains 'StatsStream.PendingHierarchyId') { return ConvertTo-Hex $Value.Bytes }
    if ($Value -is [bool]) { if ($Value) { return '1' } else { return '0' } }
    if ($Value -is [single] -or $Value -is [double]) { return $Value.ToString('R', $script:Inv) }
    if ($Value -is [datetime]) {
        switch ($SystemTypeId) {
            40 { return $Value.ToString('yyyy-MM-dd', $script:Inv) }
            58 { return $Value.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv) }
            61 { return $Value.ToString('yyyy-MM-dd HH:mm:ss.fff', $script:Inv) }
            default {
                if ($Scale -le 0) { return $Value.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv) }
                return $Value.ToString('yyyy-MM-dd HH:mm:ss.' + ('f' * $Scale), $script:Inv)
            }
        }
    }
    if ($Value -is [DateTimeOffset]) {
        $f = 'yyyy-MM-dd HH:mm:ss'
        if ($Scale -gt 0) { $f += '.' + ('f' * $Scale) }
        return $Value.ToString($f + ' zzz', $script:Inv)
    }
    if ($Value -is [TimeSpan]) {
        $s = '{0:00}:{1:00}:{2:00}' -f [Math]::Floor($Value.TotalHours), $Value.Minutes, $Value.Seconds
        if ($Scale -gt 0) { $s += '.' + ($Value.Ticks % 10000000).ToString('0000000').Substring(0, $Scale) }
        return $s
    }
    if ($Value -is [IFormattable]) { return $Value.ToString($null, $script:Inv) }
    return [string]$Value
}

function Get-CanonicalValue($Value) {
    <# Normalized representation used to compare decoded values with SqlClient values. #>
    if ($null -eq $Value -or $Value -is [DBNull]) { return 'NULL' }
    if ($Value -is [byte[]]) { return ConvertTo-Hex $Value }
    if ($Value.PSObject.TypeNames -contains 'StatsStream.PendingHierarchyId') { return ConvertTo-Hex $Value.Bytes }
    if ($Value -is [System.Data.SqlTypes.INullable]) {
        if ($Value.IsNull) { return 'NULL' }
        if ($Value -is [System.Data.SqlTypes.SqlBinary]) { return ConvertTo-Hex $Value.Value }
        if ($Value -is [System.Data.SqlTypes.SqlBytes]) { return ConvertTo-Hex $Value.Value }
        if ($Value -is [System.Data.SqlTypes.SqlDecimal] -or $Value -is [System.Data.SqlTypes.SqlMoney]) { return $Value.ToString() }
        try { $Value = $Value.Value } catch { return $Value.ToString() }
    }
    if ($Value -is [bool]) { if ($Value) { return '1' } else { return '0' } }
    if ($Value -is [single] -or $Value -is [double]) { return $Value.ToString('R', $script:Inv) }
    if ($Value -is [decimal]) { return $Value.ToString($script:Inv) }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss.fffffff', $script:Inv) }
    if ($Value -is [DateTimeOffset]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss.fffffff zzz', $script:Inv) }
    if ($Value -is [TimeSpan]) { return $Value.Ticks.ToString($script:Inv) }
    if ($Value -is [IFormattable]) { return $Value.ToString($null, $script:Inv) }
    return [string]$Value
}

#endregion

#region ---------------------------------------------------------------- record parsing

function Read-HistogramStep([byte[]]$Rec) {
    <#
      A step is stored as a FixedVar row with 4 columns:
        [status A][status B][fixed-data end: uint16]
        EQ_ROWS real | RANGE_ROWS real | AVG_RANGE_ROWS real | RANGE_HI_KEY fixed bytes (fixed types)
        [column count: uint16 = 4][NULL bitmap: 1 byte]
        status A bit 0x20 -> [variable column count: uint16][end offsets: uint16 each][variable data]
      DISTINCT_RANGE_ROWS is not stored: RANGE_ROWS / AVG_RANGE_ROWS.
    #>
    $statusA = $Rec[0]
    $fixedEnd = [BitConverter]::ToUInt16($Rec, 2)
    $eq = [BitConverter]::ToSingle($Rec, 4)
    $range = [BitConverter]::ToSingle($Rec, 8)
    $avg = [BitConverter]::ToSingle($Rec, 12)
    $ncols = [BitConverter]::ToUInt16($Rec, $fixedEnd)
    $nbLen = [int][Math]::Ceiling($ncols / 8.0)
    $nullBitmap = 0
    for ($i = 0; $i -lt $nbLen; $i++) { $nullBitmap = $nullBitmap -bor ($Rec[$fixedEnd + 2 + $i] -shl (8 * $i)) }
    $p = $fixedEnd + 2 + $nbLen
    $keyIsNull = (($nullBitmap -shr 3) -band 1) -eq 1
    $varCount = 0
    $complex = $false
    if ($fixedEnd -gt 16) {
        $key = Get-Bytes $Rec 16 ($fixedEnd - 16)
    } elseif ($statusA -band 0x20) {
        $varCount = [BitConverter]::ToUInt16($Rec, $p)
        $offs = @()
        for ($i = 0; $i -lt $varCount; $i++) { $offs += [BitConverter]::ToUInt16($Rec, $p + 2 + 2 * $i) }
        $start = $p + 2 + 2 * $varCount
        $end = $offs[0] -band 0x7FFF
        $complex = ($offs[0] -band 0x8000) -ne 0
        $key = Get-Bytes $Rec $start ($end - $start)
    } else {
        $key = [byte[]]@()
    }
    [pscustomobject]@{
        StatusA = $statusA; StatusB = $Rec[1]; FixedEnd = $fixedEnd; ColumnCount = $ncols; NullBitmap = $nullBitmap
        VarColumnCount = $varCount; KeyComplex = $complex
        EqRows = $eq; RangeRows = $range; AvgRangeRows = $avg; KeyIsNull = $keyIsNull; KeyBytes = $key
    }
}

function Read-StringIndex([byte[]]$D, [bool]$Unicode) {
    <#
      String summary (trie) used for LIKE estimates (COnDiskHistogram::Persist, CTrieOnDisk::Flatten):
        +0  byte   0xFF trie present
        +1  int32  trie format version (1)
        +5  int32  NULL values in the sample
        +9  int32  strings sampled (NULLs included)
        +13 int32  distinct strings in the sample (NULL counts as one)
        +17 int32  full prefix length (40)       +21 int32 full suffix length (40)
                   (longer strings keep their first 40 and last 40 characters)
        +25 8      two unused int32 (0)
        +33 int32  length of the character buffer, in characters
        +37        character buffer (UTF-16 for n-types)
        then int32 node count, the nodes in pre-order, and 1 unused byte (Persist advances
        its cursor one byte past the trie).
      Node: [info][string: uint32 = offset << 8 | length][occurrences, only when info & 0x30]
        info 0x80 = next sibling follows, 0x40 = has children, 0x0F = occurrences 0-15,
        0x10 = occurrences 16-255 in one more byte, 0x20 = occurrences > 255 in one more uint32.
        Occurrences = sampled strings that end exactly at this node.
    #>
    $cs = 1; if ($Unicode) { $cs = 2 }
    $len = [BitConverter]::ToInt32($D, 33)
    $raw = Get-Bytes $D 37 ($len * $cs)
    if ($Unicode) { $str = [Text.Encoding]::Unicode.GetString($raw) } else { $str = $script:CurrentStringEncoding.GetString($raw) }
    $p = 37 + $len * $cs
    $nodeCount = [BitConverter]::ToInt32($D, $p); $p += 4
    $nodes = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Generic.List[object]'
    $prefix = ''
    $depth = 0
    for ($i = 0; $i -lt $nodeCount; $i++) {
        $o = $p
        $flags = $D[$o]; $segLen = $D[$o + 1]; $segOff = [int](Read-UIntLE $D ($o + 2) 3)
        $p += 5
        $count = $flags -band 0x0F
        if ($flags -band 0x20) { $count = [int][BitConverter]::ToUInt32($D, $p); $p += 4 }
        elseif ($flags -band 0x10) { $count = [int]$D[$p]; $p += 1 }
        if ($segOff + $segLen -le $str.Length) { $seg = $str.Substring($segOff, $segLen) } else { $seg = '?' }
        $full = $prefix + $seg
        $nodes.Add([pscustomobject]@{
                Index = $i; Depth = $depth; Flags = $flags; Count = $count; RecordOffset = $o; RecordLength = $p - $o
                HasChildren = [bool]($flags -band 0x40); HasSibling = [bool]($flags -band 0x80)
                SegmentOffset = $segOff; SegmentLength = $segLen; Segment = $seg; Text = $full
            })
        if ($flags -band 0x40) {
            $stack.Add(@($prefix, $depth, [bool]($flags -band 0x80)))
            $prefix = $full; $depth++
        } elseif (-not ($flags -band 0x80)) {
            # last child: climb until an ancestor that still has siblings
            while ($stack.Count -gt 0) {
                $top = $stack[$stack.Count - 1]; $stack.RemoveAt($stack.Count - 1)
                $prefix = $top[0]; $depth = $top[1]
                if ($top[2]) { break }
            }
        }
    }
    $tailStart = $p
    [pscustomobject]@{
        PresentMarker = $D[0]; Version = [BitConverter]::ToInt32($D, 1)
        NullsInSample = [BitConverter]::ToInt32($D, 5); StringsSampled = [BitConverter]::ToInt32($D, 9)
        DistinctStrings = [BitConverter]::ToInt32($D, 13); FullPrefix = [BitConverter]::ToInt32($D, 17)
        FullSuffix = [BitConverter]::ToInt32($D, 21); Unused25 = [BitConverter]::ToInt64($D, 25)
        CompressedLength = $len; CompressedString = $str; NodeCount = $nodeCount; Nodes = $nodes.ToArray()
        CountSum = ($nodes | Measure-Object -Property Count -Sum).Sum
        Trailer = (Get-Bytes $D $tailStart ($D.Length - $tailStart))
    }
}

function Read-UpdateHistory([byte[]]$D) {
    <#
      int32 record count, then 76-byte records, newest first, excluding the current update.
      Each record is the statistics as they were at that update, plus what was measured on
      the following update (the TF 2388 columns of the row above it):
        +0 datetime Updated   +8 float Table Cardinality   +16 bigint Snapshot Ctr
        +24 int Steps         +28 float Density             +36 float Rows Above
        +44 float Rows Below  +52 float Inserts Since Last Update
        +60 float Deletes Since Last Update                 +68 float Squared Variance Error
    #>
    $count = [BitConverter]::ToInt32($D, 0)
    $recs = @()
    if ($count -le 0) { return , $recs }
    $size = [int](($D.Length - 4) / $count)
    for ($i = 0; $i -lt $count; $i++) {
        $o = 4 + $i * $size
        $recs += [pscustomobject]@{
            Index = $i
            Updated = ConvertFrom-SqlDateTimeBytes $D $o
            TableCardinality = [BitConverter]::ToDouble($D, $o + 8)
            SnapshotCtr = [BitConverter]::ToInt64($D, $o + 16)
            Steps = [BitConverter]::ToInt32($D, $o + 24)
            Density = [BitConverter]::ToDouble($D, $o + 28)
            RowsAbove = [BitConverter]::ToDouble($D, $o + 36)
            RowsBelow = [BitConverter]::ToDouble($D, $o + 44)
            InsertsSinceLastUpdate = [BitConverter]::ToDouble($D, $o + 52)
            DeletesSinceLastUpdate = [BitConverter]::ToDouble($D, $o + 60)
            SquaredVarianceError = [BitConverter]::ToDouble($D, $o + 68)
            RecordSize = $size
        }
    }
    return , $recs
}

function Get-LeadingColumnType($History) {
    # Branding logic (TF 2389/2390): three consecutive updates with >90% of the new rows
    # above (ascending) or below (descending) the previous histogram. The 3 latest updates are read
    # newest first, as DBCC does: an update without inserts makes it Unknown, and one that is neither
    # ascending nor descending, or turns the other way, makes it Stationary. (Checked against TF 2388
    # on ~10,600 SQL Server 2022 statistics: "any update without inserts = Unknown" was wrong for
    # patterns such as stationary-then-no-inserts, which DBCC reports as Stationary.)
    if ($null -eq $History -or $History.Count -lt 3) { return 'Unknown' }
    $direction = $null
    foreach ($h in $History[0..2]) {
        if ($h.InsertsSinceLastUpdate -le 0) { return 'Unknown' }
        if ($h.RowsAbove -ge 0.9 * $h.InsertsSinceLastUpdate) { $t = 'Ascending' }
        elseif ($h.RowsBelow -ge 0.9 * $h.InsertsSinceLastUpdate) { $t = 'Descending' }
        else { return 'Stationary' }
        if ($null -eq $direction) { $direction = $t } elseif ($t -ne $direction) { return 'Stationary' }
    }
    return $direction
}

function Get-TraceFlag2388View($Decoded) {
    <#
      Rebuilds the result set of DBCC SHOW_STATISTICS under trace flag 2388:
        row 1    = current statistics (blob header), change columns from history record 0
        row i+1  = history record i, change columns from history record i (the update after it)
        last row = oldest history record, change columns NULL
      Statistics without a blob, or with a blob that has no vectors (columnstore index
      statistics), return one row of NULLs, as DBCC does.
    #>
    $cols = 'Updated', 'Table Cardinality', 'Snapshot Ctr', 'Steps', 'Density', 'Rows Above', 'Rows Below',
    'Squared Variance Error', 'Inserts Since Last Update', 'Deletes Since Last Update', 'Leading column Type'
    $m = $Decoded.Blob
    if (-not $m -or $m.VectorCount -eq 0) {
        $o = [ordered]@{}; foreach ($c in $cols) { $o[$c] = $null }
        return , @([pscustomobject]$o)
    }
    $hist = @($Decoded.UpdateHistory)
    # The current Snapshot Ctr (leading column modification counter when the statistics were
    # updated) is not in the stream. -UseDac reads it from sys.sysobjvalues; otherwise the
    # table row count is shown, which matches whenever the table was only loaded by inserts.
    $snapshot = $m.Rows
    if ($null -ne $Decoded.UnfilteredRows) { $snapshot = $Decoded.UnfilteredRows }
    if ($null -ne $Decoded.CurrentSnapshotCtr) { $snapshot = $Decoded.CurrentSnapshotCtr }
    $own = @([pscustomobject]@{ Updated = $m.Updated; TableCardinality = [double]$m.Rows; SnapshotCtr = [int64]$snapshot; Steps = $m.Steps; Density = [double]$m.Densities[0] }) + $hist
    $rows = @()
    for ($i = 0; $i -lt $own.Count; $i++) {
        $chg = $null
        if ($i -lt $hist.Count) { $chg = $hist[$i] }
        $lct = $null
        if ($i -eq 0) { $lct = $Decoded.LeadingColumnType; if (-not $lct) { $lct = 'Unknown' } }
        $rows += [pscustomobject][ordered]@{
            'Updated'                   = $own[$i].Updated
            'Table Cardinality'         = [double]$own[$i].TableCardinality
            'Snapshot Ctr'              = [int64]$own[$i].SnapshotCtr
            'Steps'                     = [int]$own[$i].Steps
            'Density'                   = [double]$own[$i].Density
            'Rows Above'                = $(if ($chg) { $chg.RowsAbove } else { $null })
            'Rows Below'                = $(if ($chg) { $chg.RowsBelow } else { $null })
            'Squared Variance Error'    = $(if ($chg) { $chg.SquaredVarianceError } else { $null })
            'Inserts Since Last Update' = $(if ($chg) { $chg.InsertsSinceLastUpdate } else { $null })
            'Deletes Since Last Update' = $(if ($chg) { $chg.DeletesSinceLastUpdate } else { $null })
            'Leading column Type'       = $lct
        }
    }
    return , $rows
}

function Get-StatsDensitySlot([int]$Vector, [int]$VectorCount) {
    <# Where a vector's density is stored (CStatBlob::AddDensities / GetDensity in SQL Server 2025).
       Fixed = index into the real[33] array at blob+32; Extra = index into the bit 8 array.
       Vectors 1-32 are fixed. With more than 33 vectors the LAST one takes fixed slot 33 (blob+160)
       and vectors 33 .. n-1 go to the bit 8 array. #>
    if ($Vector -le 32 -or $VectorCount -le 33) { return @{ Fixed = $Vector - 1; Extra = $null } }
    if ($Vector -eq $VectorCount) { return @{ Fixed = 32; Extra = $null } }
    return @{ Fixed = $null; Extra = $Vector - 33 }
}

function Read-SampledScanDump([byte[]]$D, [long]$ItemOffset, [int]$VectorCount) {
    <# Distinct value synopsis (CDVEstimator): int64 offset per vector (relative to the variable section),
       then per vector an int32 count + that many doubles, in heap order. The estimator keeps the k smallest
       hash values seen (a max-heap: a value at or above the top is dropped once it is full). #>
    $vectors = @()
    for ($v = 0; $v -lt $VectorCount; $v++) {
        $abs = [BitConverter]::ToInt64($D, 8 * $v)
        $o = [int]($abs - $ItemOffset)
        $n = [BitConverter]::ToInt32($D, $o)
        $vals = New-Object 'double[]' $n
        for ($j = 0; $j -lt $n; $j++) { $vals[$j] = [BitConverter]::ToDouble($D, $o + 4 + 8 * $j) }
        $m = $vals | Measure-Object -Sum -Minimum -Maximum
        # hashes are in (0, 1): below the 1024-value capacity the count is exact, otherwise (k - 1) / max (k-minimum-values)
        $est = if ($n -lt 1024) { [double]$n } elseif ($m.Maximum -gt 0) { ($n - 1) / $m.Maximum } else { $null }
        $vectors += [pscustomobject]@{
            Vector = $v + 1; Offset = $abs; Count = $n; Sum = $m.Sum; Min = $m.Minimum; Max = $m.Maximum; DistinctInSample = $est; Values = $vals
        }
    }
    return , $vectors
}

#endregion

#region ---------------------------------------------------------------- main decoder

function ConvertFrom-StatsStream {
    param([byte[]]$Bytes, [string[]]$Names, [string]$Label)

    $layout = New-Object 'System.Collections.Generic.List[object]'
    function Add-Layout([long]$Off, [long]$Len, [string]$Field, [string]$Value) {
        $layout.Add([pscustomobject]@{ Offset = $Off; Length = $Len; Field = $Field; Value = $Value })
    }

    if ($Bytes.Length -lt 40) { throw "STATS_STREAM too short ($($Bytes.Length) bytes)." }

    # ---- STATS_STREAM header (40 bytes)
    $hdr = [pscustomobject]@{
        StreamVersion = [BitConverter]::ToInt32($Bytes, 0)
        NumberOfColumns = [BitConverter]::ToInt32($Bytes, 4)
        Reserved8 = [BitConverter]::ToInt64($Bytes, 8)
        Checksum = [BitConverter]::ToUInt32($Bytes, 16)
        Reserved20 = [BitConverter]::ToInt32($Bytes, 20)
        StreamLength = [BitConverter]::ToInt64($Bytes, 24)
        BlobLength = [BitConverter]::ToInt64($Bytes, 32)
        CalculatedChecksum = (Get-StatsStreamCrc $Bytes)
        ActualLength = $Bytes.Length
    }
    $hdr | Add-Member ChecksumValid ($hdr.Checksum -eq $hdr.CalculatedChecksum)
    Add-Layout 0 4 'Header: stream version' $hdr.StreamVersion
    Add-Layout 4 4 'Header: number of stats columns' $hdr.NumberOfColumns
    Add-Layout 8 8 'Header: reserved' $hdr.Reserved8
    Add-Layout 16 4 'Header: checksum (~CRC32)' ('0x{0:X8}' -f $hdr.Checksum)
    Add-Layout 20 4 'Header: reserved' $hdr.Reserved20
    Add-Layout 24 8 'Header: STATS_STREAM length' $hdr.StreamLength
    Add-Layout 32 8 'Header: stats blob length' $hdr.BlobLength

    # ---- column definitions (24 bytes each)
    $cols = @()
    for ($i = 0; $i -lt $hdr.NumberOfColumns; $i++) {
        $o = 40 + 24 * $i
        $c = [pscustomobject]@{
            Ordinal = $i + 1
            Name = $null
            SystemTypeId = [int]$Bytes[$o]
            Flags = $Bytes[$o + 1]
            Unused2 = [BitConverter]::ToUInt16($Bytes, $o + 2)
            UserTypeId = [BitConverter]::ToInt32($Bytes, $o + 4)
            MaxLength = [int][BitConverter]::ToInt16($Bytes, $o + 8)
            Precision = [int]$Bytes[$o + 10]
            Scale = [int]$Bytes[$o + 11]
            Extra12 = [BitConverter]::ToInt32($Bytes, $o + 12)
            CollationId = [BitConverter]::ToInt32($Bytes, $o + 16)
            Unused20 = [BitConverter]::ToUInt32($Bytes, $o + 20)
            IsNullable = -not ($Bytes[$o + 1] -band 1)
            TypeName = ''
            Collation = ''
            CodePage = 0
        }
        if ($Names -and $Names.Count -gt $i -and $Names[$i]) { $c.Name = $Names[$i] } else { $c.Name = "Column$($i + 1)" }
        $c.TypeName = Get-TypeDisplayName $c
        if ($c.CollationId -ne 0) { $c.Collation = Get-CollationName $c.CollationId; $c.CodePage = Get-CodePage $c.CollationId }
        $cols += $c
        Add-Layout $o 24 "Column $($i + 1) definition ($($c.Name))" ("{0} {1}" -f $c.TypeName, (ConvertTo-Hex (Get-Bytes $Bytes $o 24)))
    }

    $B = 40 + 24 * $hdr.NumberOfColumns
    $result = [ordered]@{
        Label = $Label; Header = $hdr; Columns = $cols; BlobOffset = $B; Blob = $null; DensityVector = @(); Histogram = @()
        StringIndex = $null; UpdateHistory = @(); SampledScanDump = @(); UnfilteredRows = $null; PagesSampled = $null
        PersistedSamplePercent = $null; ColumnstorePageCounts = @(); StreamingStatisticsFlags = $null; VariableItems = @(); UnknownItems = @(); Layout = $layout; Warnings = @(); Raw = $Bytes
        LeadingColumnType = $null; TraceFlag2388 = @(); CurrentSnapshotCtr = $null
    }
    if ($hdr.BlobLength -le 0 -or $Bytes.Length -le $B) {
        $result.Warnings += 'The statistics blob is empty: the statistics have never been populated (for example created on an empty table and never updated).'
        $result.TraceFlag2388 = Get-TraceFlag2388View ([pscustomobject]$result)
        return [pscustomobject]$result
    }
    $blob = Get-Bytes $Bytes $B ([Math]::Min($hdr.BlobLength, $Bytes.Length - $B))

    # ---- blob fixed section (324 bytes)
    $dens = New-Object 'single[]' 33
    $lens = New-Object 'single[]' 33
    for ($i = 0; $i -lt 33; $i++) {
        $dens[$i] = [BitConverter]::ToSingle($blob, 32 + 4 * $i)
        $lens[$i] = [BitConverter]::ToSingle($blob, 192 + 4 * $i)
    }
    $meta = [pscustomobject]@{
        BlobVersion = [BitConverter]::ToInt32($blob, 0)
        Updated = ConvertFrom-SqlDateTimeBytes $blob 4
        Rows = [BitConverter]::ToInt64($blob, 12)
        RowsSampled = [BitConverter]::ToInt64($blob, 20)
        Density = [BitConverter]::ToSingle($blob, 28)
        Steps = [BitConverter]::ToInt32($blob, 164)
        Steps2 = [BitConverter]::ToInt32($blob, 168)
        VectorCount = [BitConverter]::ToInt32($blob, 172)
        HistogramFixedLength = [BitConverter]::ToInt32($blob, 176)
        AverageKeyLength = [BitConverter]::ToSingle($blob, 180)
        HistogramRows = [BitConverter]::ToSingle($blob, 184)
        NullStepEqRows = [BitConverter]::ToSingle($blob, 188)
        Densities = $dens
        AverageLengths = $lens
        PresenceBitmask = [BitConverter]::ToUInt64($blob, 324)
    }
    $result.Blob = $meta
    Add-Layout ($B + 0) 4 'Blob: version' $meta.BlobVersion
    Add-Layout ($B + 4) 8 'Blob: updated (datetime)' (Format-SqlValue $meta.Updated 61)
    Add-Layout ($B + 12) 8 'Blob: rows' $meta.Rows
    Add-Layout ($B + 20) 8 'Blob: rows sampled' $meta.RowsSampled
    Add-Layout ($B + 28) 4 'Blob: density (pre-2008 compatibility)' (Format-Float $meta.Density)
    Add-Layout ($B + 32) 132 'Blob: densities, vectors 1-33 (real[33])' ''
    Add-Layout ($B + 164) 4 'Blob: histogram steps (without NULL step)' $meta.Steps
    Add-Layout ($B + 168) 4 'Blob: histogram steps (second copy)' $meta.Steps2
    Add-Layout ($B + 172) 4 'Blob: vector count' $meta.VectorCount
    Add-Layout ($B + 176) 4 'Blob: histogram record fixed-data length' $meta.HistogramFixedLength
    Add-Layout ($B + 180) 4 'Blob: average key length' (Format-Float $meta.AverageKeyLength)
    Add-Layout ($B + 184) 4 'Blob: rows (real)' (Format-Float $meta.HistogramRows)
    Add-Layout ($B + 188) 4 'Blob: NULL step EQ_ROWS' (Format-Float $meta.NullStepEqRows)
    Add-Layout ($B + 192) 132 'Blob: average lengths, vectors 1-33 (real[33])' ''
    Add-Layout ($B + 324) 8 'Blob: variable section presence bitmask' ('0x{0:X16}' -f $meta.PresenceBitmask)

    # ---- variable section: bitmask + (n + 1) int64 offsets, relative to the section start
    $bits = @(0..63 | Where-Object { ($meta.PresenceBitmask -shr $_) -band 1 })
    $offs = @()
    for ($i = 0; $i -le $bits.Count; $i++) { $offs += [BitConverter]::ToInt64($blob, 332 + 8 * $i) }
    $varBase = 332 + 8 * ($bits.Count + 1)
    Add-Layout ($B + 332) (8 * ($bits.Count + 1)) 'Blob: variable item offset array (int64)' ($offs -join ', ')
    $varEnd = $varBase + $offs[$offs.Count - 1]
    if ($varEnd -gt $blob.Length) {
        $result.Warnings += "Variable section ends at $varEnd but the blob has $($blob.Length) bytes."
    } elseif ($bits -contains 6 -and $bits.Count -eq 1 -and $blob.Length -ge $varEnd + 4) {
        # Columnstore index statistics: bit 6 is the only item, recorded with length 0. Its data follows:
        # uint32 column count, then one int64 page count per column (CStatMan::FExtractCSPageCounts).
        $csAt = $varBase + $offs[0]
        $csCount = [BitConverter]::ToUInt32($blob, $csAt)
        $pc = @()
        for ($i = 0; $i -lt $csCount -and $csAt + 12 + 8 * $i -le $blob.Length; $i++) {
            $pc += [pscustomobject]@{ ColumnId = $i + 1; Pages = [BitConverter]::ToInt64($blob, $csAt + 4 + 8 * $i) }
        }
        $result.ColumnstorePageCounts = $pc
        Add-Layout ($B + $csAt) 4 'Blob: columnstore column count' $csCount
        Add-Layout ($B + $csAt + 4) (8 * $pc.Count) 'Blob: columnstore page count per column (int64)' (($pc | ForEach-Object { $_.Pages }) -join ', ')
        if ($csAt + 4 + 8 * $csCount -ne $blob.Length) { $result.Warnings += "Columnstore page counts: $csCount columns do not fill the blob ($($blob.Length) bytes)." }
    } elseif ($varEnd -lt $blob.Length) {
        $tail = Get-Bytes $blob $varEnd ($blob.Length - $varEnd)
        $result.UnknownItems += [pscustomobject]@{ Bit = 'trailer'; Length = $tail.Length; Hex = ConvertTo-Hex $tail 256 }
        Add-Layout ($B + $varEnd) $tail.Length 'Blob: data after the last variable item (undocumented)' (ConvertTo-Hex $tail 64)
    }
    $items = @{}
    for ($i = 0; $i -lt $bits.Count; $i++) {
        $bit = $bits[$i]
        $name = $script:VarItemNames[[int]$bit]
        if (-not $name) { $name = "Unknown item (bit $bit)" }
        $data = Get-Bytes $blob ($varBase + $offs[$i]) ($offs[$i + 1] - $offs[$i])
        $items[[int]$bit] = @{ Data = $data; RelOffset = $offs[$i] }
        $result.VariableItems += [pscustomobject]@{
            Bit = $bit; Name = $name; RelativeOffset = $offs[$i]; StreamOffset = $B + $varBase + $offs[$i]; Length = $data.Length
        }
        Add-Layout ($B + $varBase + $offs[$i]) $data.Length "Variable item bit $($bit): $name" ''
        if (-not $script:VarItemNames[[int]$bit]) { $result.UnknownItems += [pscustomobject]@{ Bit = $bit; Length = $data.Length; Hex = ConvertTo-Hex $data 256 } }
    }

    # ---- density vector
    $extDens = $null; $extLens = $null
    if ($items.ContainsKey(8)) { $extDens = $items[8].Data }
    if ($items.ContainsKey(9)) { $extLens = $items[9].Data }
    # Average lengths are stored per column; DBCC shows the running sum over the vector's columns.
    $dv = @()
    [single]$runLen = 0
    for ($v = 0; $v -lt $meta.VectorCount; $v++) {
        $d = $null; $l = $null
        $slot = Get-StatsDensitySlot ($v + 1) $meta.VectorCount
        if ($null -ne $slot.Fixed) { $d = $dens[$slot.Fixed] }
        elseif ($extDens -and $extDens.Length -ge 4 * ($slot.Extra + 1)) { $d = [BitConverter]::ToSingle($extDens, 4 * $slot.Extra) }
        if ($v -lt 33) { $l = $lens[$v] }
        elseif ($extLens -and $extLens.Length -ge 4 * ($v - 32)) { $l = [BitConverter]::ToSingle($extLens, 4 * ($v - 33)) }
        if ($null -ne $l) { $runLen = [single]($runLen + $l) }
        $names = @($cols | Select-Object -First ([Math]::Min($v + 1, $cols.Count)) | ForEach-Object { $_.Name })
        $dv += [pscustomobject]@{ Vector = $v + 1; AllDensity = $d; AverageLength = $runLen; ColumnAverageLength = $l; Columns = ($names -join ', ') }
    }
    $result.DensityVector = $dv

    # ---- histogram
    $keyCol = $cols[0]
    $script:CurrentStringEncoding = [Text.Encoding]::GetEncoding(1252)
    if ($keyCol.SystemTypeId -in 167, 175, 35) { try { $script:CurrentStringEncoding = [Text.Encoding]::GetEncoding((Get-CodePage $keyCol.CollationId)) } catch { } }
    $steps = @()
    if ($meta.NullStepEqRows -gt 0) {
        $steps += [pscustomobject]@{
            Step = 1; RangeHiKey = $null; RangeHiKeyText = 'NULL'; RangeRows = [single]0; EqRows = $meta.NullStepEqRows
            DistinctRangeRows = [single]0; AvgRangeRows = [single]1; StoredAvgRangeRows = $null; IsNullStep = $true; RecordOffset = $null; RecordLength = 0; KeyHex = ''
            Record = $null
        }
    }
    if ($items.ContainsKey(0)) {
        $h = $items[0].Data
        $n = $meta.Steps
        $so = @()
        for ($i = 0; $i -lt $n; $i++) { $so += [BitConverter]::ToInt64($h, 8 * $i) }
        for ($i = 0; $i -lt $n; $i++) {
            if ($i + 1 -lt $n) { $end = $so[$i + 1] } else { $end = $h.Length }
            $rec = Read-HistogramStep (Get-Bytes $h $so[$i] ($end - $so[$i]))
            if ($rec.KeyIsNull) { $val = $null }
            else {
                $val = ConvertFrom-SqlBytes -Data $rec.KeyBytes -SystemTypeId $keyCol.SystemTypeId -UserTypeId $keyCol.UserTypeId `
                    -MaxLength $keyCol.MaxLength -Precision $keyCol.Precision -Scale $keyCol.Scale -CollationId $keyCol.CollationId
            }
            # DBCC derives DISTINCT_RANGE_ROWS = RANGE_ROWS / AVG_RANGE_ROWS; a stored average below 1
            # (possible after sampling) is shown as 1 with DISTINCT_RANGE_ROWS = round(RANGE_ROWS).
            $avg = $rec.AvgRangeRows
            if ($rec.RangeRows -eq 0 -or $avg -eq 0) { $dr = [single]0 }
            elseif ($avg -lt 1) { $avg = [single]1; $dr = [single][Math]::Round($rec.RangeRows, [MidpointRounding]::AwayFromZero) }
            else { $dr = [single]($rec.RangeRows / $avg) }
            $steps += [pscustomobject]@{
                Step = $steps.Count + 1; RangeHiKey = $val; RangeHiKeyText = ''; RangeRows = $rec.RangeRows; EqRows = $rec.EqRows
                DistinctRangeRows = $dr; AvgRangeRows = $avg; StoredAvgRangeRows = $rec.AvgRangeRows; IsNullStep = $false
                RecordOffset = $B + $varBase + $items[0].RelOffset + $so[$i]; RecordLength = $end - $so[$i]
                KeyHex = ConvertTo-Hex $rec.KeyBytes; Record = $rec
            }
        }
    }
    $result.Histogram = $steps

    # ---- other variable items
    if ($items.ContainsKey(1)) {
        $uni = $keyCol.SystemTypeId -in 231, 239, 99
        try { $result.StringIndex = Read-StringIndex $items[1].Data $uni }
        catch { $result.Warnings += "String index could not be decoded: $($_.Exception.Message)" }
    }
    if ($items.ContainsKey(3)) {
        $result.UpdateHistory = Read-UpdateHistory $items[3].Data
        $result.LeadingColumnType = Get-LeadingColumnType $result.UpdateHistory
    }
    if ($items.ContainsKey(4)) { $result.UnfilteredRows = [BitConverter]::ToInt64($items[4].Data, 0) }
    if ($items.ContainsKey(5)) {
        try { $result.SampledScanDump = Read-SampledScanDump $items[5].Data $items[5].RelOffset $meta.VectorCount }
        catch { $result.Warnings += "Distinct value synopsis could not be decoded: $($_.Exception.Message)" }
    }
    if ($items.ContainsKey(7)) { $result.PagesSampled = [BitConverter]::ToInt64($items[7].Data, 0) }
    if ($items.ContainsKey(10)) { $result.PersistedSamplePercent = [BitConverter]::ToDouble($items[10].Data, 0) }
    if ($items.ContainsKey(11) -and $items[11].Data.Length -ge 4) { $result.StreamingStatisticsFlags = [BitConverter]::ToUInt32($items[11].Data, 0) }

    if (-not $hdr.ChecksumValid) { $result.Warnings += 'Checksum mismatch: the stream was modified or is truncated.' }
    if ($hdr.StreamLength -ne $Bytes.Length) { $result.Warnings += "Header says $($hdr.StreamLength) bytes, stream has $($Bytes.Length)." }
    if (-not $result.LeadingColumnType) { $result.LeadingColumnType = 'Unknown' }
    $result.TraceFlag2388 = Get-TraceFlag2388View ([pscustomobject]$result)
    return [pscustomobject]$result
}

function Resolve-PendingValues($Decoded, $Connection) {
    # hierarchyid keys that could not be decoded locally are converted on the server.
    $pending = @($Decoded.Histogram | Where-Object { $_.RangeHiKey -and $_.RangeHiKey.PSObject.TypeNames -contains 'StatsStream.PendingHierarchyId' })
    if ($pending.Count -eq 0 -or $null -eq $Connection) { return }
    foreach ($s in $pending) {
        $cmd = $Connection.CreateCommand()
        $cmd.CommandText = 'SELECT CAST(@b AS hierarchyid).ToString()'
        $null = $cmd.Parameters.Add('@b', [Data.SqlDbType]::VarBinary, -1)
        $cmd.Parameters['@b'].Value = $s.RangeHiKey.Bytes
        try { $s.RangeHiKey = [string]$cmd.ExecuteScalar() } catch { }
    }
}

#endregion

#region ---------------------------------------------------------------- encoder (edited statistics -> STATS_STREAM)

<#
  The app edits a model of the decoded statistics (header values, histogram steps, density vector) and
  turns it back into a STATS_STREAM for UPDATE STATISTICS ... WITH STATS_STREAM. Anything the model
  does not change is copied byte for byte, so an unedited model returns the original stream.
  Verified on SQL Server 2025: the import keeps the stream's Updated date, rejects a wrong checksum
  ("The provided statistics stream is corrupt") and accepts records whose length changed.
#>

function ConvertTo-SqlDecimalBytes([string]$Text, [int]$Scale, [int]$Length) {
    # sign byte (1 = positive) + little-endian magnitude scaled by 10^scale
    if ($Text -notmatch '^\s*([+-]?)(\d*)(?:\.(\d*))?\s*$' -or -not ($Matches[2] + $Matches[3])) { throw "'$Text' is not a number." }
    $negative = $Matches[1] -eq '-'; $int = $Matches[2]; $frac = [string]$Matches[3]
    if ($frac.Length -gt $Scale) {
        if ($frac.Substring($Scale).Trim('0')) { throw "The column keeps $Scale decimal places." }
        $frac = $frac.Substring(0, $Scale)
    }
    $digits = ($int + $frac.PadRight($Scale, '0')).TrimStart('0')
    if (-not $digits) { $digits = '0' }
    $mag = [System.Numerics.BigInteger]::Parse($digits, $script:Inv).ToByteArray()
    $n = $mag.Length
    while ($n -gt 1 -and $mag[$n - 1] -eq 0) { $n-- }
    if ($n -gt $Length - 1) { throw "'$Text' does not fit the column's precision." }
    $out = New-Object byte[] $Length
    $out[0] = $(if ($negative -and $digits -ne '0') { 0 } else { 1 })
    [Array]::Copy($mag, 0, $out, 1, $n)
    return , $out
}

function ConvertTo-SqlTimeBytes([TimeSpan]$Time, [int]$Scale) {
    $units = [int64][Math]::Round($Time.Ticks / [Math]::Pow(10, 7 - $Scale))
    $n = Get-TimeByteCount $Scale
    return , [byte[]]([BitConverter]::GetBytes($units)[0..($n - 1)])
}

function ConvertTo-SqlDateBytes([datetime]$Date) {
    $days = [int]($Date.Date - [datetime]::new(1, 1, 1)).TotalDays
    return , [byte[]]([BitConverter]::GetBytes($days)[0..2])
}

function ConvertTo-SqlDateTimeBytes([datetime]$Value) {
    # datetime: int32 ticks of 1/300 s, then int32 days since 1900-01-01 (SqlDateTime rounds like SQL Server)
    $sd = [System.Data.SqlTypes.SqlDateTime]::new($Value)
    return , [byte[]]([BitConverter]::GetBytes([int32]$sd.TimeTicks) + [BitConverter]::GetBytes([int32]$sd.DayTicks))
}

function ConvertTo-SqlKeyBytes([string]$Text, $Column, [int]$FixedLength = 0) {
    <# Inverse of ConvertFrom-SqlBytes for the key types the app can edit. FixedLength > 0: the key sits in
       the fixed part of the step record (char, binary and nchar are padded to it). #>
    $inv = $script:Inv
    $t = $Text.Trim()
    $pad = $null
    switch ($Column.SystemTypeId) {
        48 { $b = [byte[]]@([byte]::Parse($t, $inv)) }
        52 { $b = [BitConverter]::GetBytes([int16]::Parse($t, $inv)) }
        56 { $b = [BitConverter]::GetBytes([int32]::Parse($t, $inv)) }
        127 { $b = [BitConverter]::GetBytes([int64]::Parse($t, $inv)) }
        104 {
            if ($t -in '1', 'true') { $b = [byte[]]@(1) } elseif ($t -in '0', 'false') { $b = [byte[]]@(0) } else { throw "'$Text' is not a bit (0 or 1)." }
        }
        59 { $b = [BitConverter]::GetBytes([single]::Parse($t, $inv)) }
        62 { if ($FixedLength -eq 4) { $b = [BitConverter]::GetBytes([single]::Parse($t, $inv)) } else { $b = [BitConverter]::GetBytes([double]::Parse($t, $inv)) } }
        60 {
            $m = [decimal]::Parse($t, [Globalization.NumberStyles]::Number, $inv) * 10000
            if ($m -ne [decimal]::Truncate($m)) { throw 'money keeps 4 decimal places.' }
            $b = [BitConverter]::GetBytes([int64]$m)
        }
        122 {
            $m = [decimal]::Parse($t, [Globalization.NumberStyles]::Number, $inv) * 10000
            if ($m -ne [decimal]::Truncate($m)) { throw 'smallmoney keeps 4 decimal places.' }
            $b = [BitConverter]::GetBytes([int32]$m)
        }
        { $_ -in 106, 108 } { $b = ConvertTo-SqlDecimalBytes $t $Column.Scale $FixedLength }
        40 { $b = ConvertTo-SqlDateBytes ([datetime]::Parse($t, $inv)) }
        41 { $b = ConvertTo-SqlTimeBytes ([TimeSpan]::Parse($t, $inv)) $Column.Scale }
        42 {
            $v = [datetime]::Parse($t, $inv)
            $b = [byte[]]((ConvertTo-SqlTimeBytes $v.TimeOfDay $Column.Scale) + (ConvertTo-SqlDateBytes $v))
        }
        43 {
            $v = [DateTimeOffset]::Parse($t, $inv)
            $utc = $v.UtcDateTime
            $b = [byte[]]((ConvertTo-SqlTimeBytes $utc.TimeOfDay $Column.Scale) + (ConvertTo-SqlDateBytes $utc) + [BitConverter]::GetBytes([int16]$v.Offset.TotalMinutes))
        }
        61 { $b = ConvertTo-SqlDateTimeBytes ([datetime]::Parse($t, $inv)) }
        58 {
            $minutes = [int64][Math]::Round(([datetime]::Parse($t, $inv) - [datetime]::new(1900, 1, 1)).TotalMinutes)
            $b = [byte[]]([BitConverter]::GetBytes([uint16]($minutes % 1440)) + [BitConverter]::GetBytes([uint16][Math]::Floor($minutes / 1440)))
        }
        36 { $b = [Guid]::Parse($t).ToByteArray() }
        { $_ -in 175, 167, 35 } {
            # strings keep their spaces; only char pads
            try { $enc = [Text.Encoding]::GetEncoding((Get-CodePage $Column.CollationId)) } catch { $enc = [Text.Encoding]::GetEncoding(1252) }
            $b = $enc.GetBytes($Text); $pad = [byte[]]@(0x20)
        }
        { $_ -in 239, 231, 99 } { $b = [Text.Encoding]::Unicode.GetBytes($Text); $pad = [byte[]]@(0x20, 0x00) }
        { $_ -in 173, 165, 189 } {
            if ($t -notmatch '^0x([0-9A-Fa-f]{2})*$') { throw "'$Text' is not a binary value (0x...)." }
            $b = ConvertFrom-HexString $t; $pad = [byte[]]@(0x00)
        }
        default { throw "Editing RANGE_HI_KEY is not supported for $($Column.TypeName) keys." }
    }
    $b = [byte[]]$b
    if ($FixedLength -gt 0 -and $b.Length -ne $FixedLength) {
        if ($b.Length -gt $FixedLength -or -not $pad) { throw "The key takes $($b.Length) bytes; $($Column.TypeName) keys take $FixedLength." }
        $list = New-Object 'System.Collections.Generic.List[byte]'
        $list.AddRange($b)
        while ($list.Count -lt $FixedLength) { $list.AddRange($pad) }
        $b = $list.ToArray()
    }
    return , $b
}

function Format-StatsKey([byte[]]$KeyBytes, $Column) {
    # Display text of a key, as in the report (Format-SqlValue of the decoded value).
    $v = ConvertFrom-SqlBytes -Data $KeyBytes -SystemTypeId $Column.SystemTypeId -UserTypeId $Column.UserTypeId `
        -MaxLength $Column.MaxLength -Precision $Column.Precision -Scale $Column.Scale -CollationId $Column.CollationId
    return Format-SqlValue $v $Column.SystemTypeId $Column.Scale
}

function Get-StatsKeySortValue([byte[]]$KeyBytes, $Column) {
    # Comparable value for the ordering check; $null for types whose order depends on the collation or bytes.
    if ($Column.SystemTypeId -notin 48, 52, 56, 127, 104, 59, 62, 60, 122, 106, 108, 40, 41, 42, 43, 61, 58) { return $null }
    $v = ConvertFrom-SqlBytes -Data $KeyBytes -SystemTypeId $Column.SystemTypeId -UserTypeId $Column.UserTypeId `
        -MaxLength $Column.MaxLength -Precision $Column.Precision -Scale $Column.Scale -CollationId $Column.CollationId
    if ($v -is [string]) {
        # decimal(38) can exceed System.Decimal; double keeps the order for the check
        try { return [decimal]::Parse($v, [Globalization.NumberStyles]::Number, $script:Inv) } catch { return [double]::Parse($v, $script:Inv) }
    }
    if ($v -is [DateTimeOffset]) { return $v.UtcDateTime }
    if ($v -is [bool]) { return [int]$v }
    return $v
}

function Get-StatsStepDisplay([single]$RangeRows, [single]$StoredAvg) {
    # DISTINCT_RANGE_ROWS and AVG_RANGE_ROWS as DBCC shows them (same rule as the decoder).
    if ($RangeRows -eq 0 -or $StoredAvg -eq 0) { return @{ Distinct = [single]0; Avg = $(if ($StoredAvg -lt 1) { [single]1 } else { $StoredAvg }) } }
    if ($StoredAvg -lt 1) { return @{ Distinct = [single][Math]::Round($RangeRows, [MidpointRounding]::AwayFromZero); Avg = [single]1 } }
    return @{ Distinct = [single]($RangeRows / $StoredAvg); Avg = $StoredAvg }
}

function New-StatsEditStep($Step, $Column, $Template) {
    if ($Step) {
        $key = 'NULL'; $bytes = [byte[]]@(); $avg = [single]1
        if (-not $Step.IsNullStep) { $bytes = [byte[]]$Step.Record.KeyBytes; $key = Format-StatsKey $bytes $Column; $avg = [single]$Step.Record.AvgRangeRows }
        return [pscustomobject]@{
            IsNull = [bool]$Step.IsNullStep; Key = $key; KeyBytes = $bytes
            RangeRows = [single]$Step.RangeRows; EqRows = [single]$Step.EqRows; StoredAvg = $avg
            Source = $Step; Template = $Step
        }
    }
    # a new step copies the record layout of a neighbor; its key stays empty until the user types one
    return [pscustomobject]@{
        IsNull = $false; Key = ''; KeyBytes = $null
        RangeRows = [single]0; EqRows = [single]1; StoredAvg = [single]1
        Source = $null; Template = $Template.Template
    }
}

function New-StatsEditModel($D) {
    if (-not $D.Blob) { return $null }
    $m = $D.Blob
    $kc = $D.Columns[0]
    $header = [ordered]@{
        'Updated' = $m.Updated; 'Rows' = [int64]$m.Rows; 'Rows Sampled' = [int64]$m.RowsSampled
        'Density' = [single]$m.Density; 'Average key length' = [single]$m.AverageKeyLength
    }
    if ($null -ne $D.UnfilteredRows) { $header['Unfiltered Rows'] = [int64]$D.UnfilteredRows }
    if ($null -ne $D.PagesSampled) { $header['Pages sampled'] = [int64]$D.PagesSampled }
    if ($null -ne $D.PersistedSamplePercent) { $header['Persisted sample percent'] = [double]$D.PersistedSamplePercent }
    $original = [ordered]@{}
    foreach ($k in $header.Keys) { $original[$k] = $header[$k] }
    $steps = New-Object 'System.Collections.Generic.List[object]'
    foreach ($st in $D.Histogram) { $steps.Add((New-StatsEditStep $st $kc $null)) }
    $vectors = @($D.DensityVector | ForEach-Object {
            [pscustomobject]@{ Vector = $_.Vector; Columns = $_.Columns; AllDensity = $_.AllDensity; ColumnAverageLength = $_.ColumnAverageLength; Source = $_ }
        })
    return [pscustomobject]@{ Decoded = $D; Header = $header; OriginalHeader = $original; Steps = $steps; Vectors = $vectors }
}

function Get-StatsEditChanges($Model) {
    # Human-readable list of what differs from the decoded statistics (script comments, status bar).
    $changes = New-Object 'System.Collections.Generic.List[string]'
    $fmt = { param($v) if ($v -is [datetime]) { Format-SqlValue $v 61 } elseif ($v -is [single] -or $v -is [double]) { $v.ToString('R', $script:Inv) } else { [string]$v } }
    foreach ($k in $Model.Header.Keys) {
        if ([string](& $fmt $Model.Header[$k]) -ne [string](& $fmt $Model.OriginalHeader[$k])) { $changes.Add("$($k): $(& $fmt $Model.OriginalHeader[$k]) -> $(& $fmt $Model.Header[$k])") }
    }
    $kept = @{}
    foreach ($st in $Model.Steps) {
        if (-not $st.Source) { $changes.Add("Inserted step: RANGE_HI_KEY $($st.Key), RANGE_ROWS $($st.RangeRows), EQ_ROWS $($st.EqRows)"); continue }
        $kept[$st.Source.Step] = $true
        $diff = @()
        if (-not $st.IsNull -and [Convert]::ToBase64String($st.KeyBytes) -ne [Convert]::ToBase64String([byte[]]$st.Source.Record.KeyBytes)) { $diff += "RANGE_HI_KEY $(Format-StatsKey ([byte[]]$st.Source.Record.KeyBytes) $Model.Decoded.Columns[0]) -> $($st.Key)" }
        if ($st.RangeRows -ne [single]$st.Source.RangeRows) { $diff += "RANGE_ROWS $($st.Source.RangeRows) -> $($st.RangeRows)" }
        if ($st.EqRows -ne [single]$st.Source.EqRows) { $diff += "EQ_ROWS $($st.Source.EqRows) -> $($st.EqRows)" }
        if (-not $st.IsNull -and $st.StoredAvg -ne [single]$st.Source.Record.AvgRangeRows) { $diff += "AVG_RANGE_ROWS $($st.Source.Record.AvgRangeRows) -> $($st.StoredAvg)" }
        if ($diff) { $changes.Add("Step $($st.Source.Step) ($($st.Source.RangeHiKeyText)): " + ($diff -join ', ')) }
    }
    foreach ($st in $Model.Decoded.Histogram) { if (-not $kept.ContainsKey($st.Step)) { $changes.Add("Deleted step $($st.Step): RANGE_HI_KEY $($st.RangeHiKeyText)") } }
    foreach ($v in $Model.Vectors) {
        if ($v.AllDensity -ne $v.Source.AllDensity) { $changes.Add("Density vector $($v.Vector): All density $($v.Source.AllDensity) -> $($v.AllDensity)") }
        if ($v.ColumnAverageLength -ne $v.Source.ColumnAverageLength) { $changes.Add("Density vector $($v.Vector): column average length $($v.Source.ColumnAverageLength) -> $($v.ColumnAverageLength)") }
    }
    return , $changes.ToArray()
}

function New-StatsHistogramRecord($Step, [byte[]]$Raw) {
    # One step record (FixedVar row): the template record with new floats and key.
    $tpl = $Step.Template
    $rec = $tpl.Record
    $orig = Get-Bytes $Raw $tpl.RecordOffset $tpl.RecordLength
    $same = $Step.Source -and $Step.RangeRows -eq [single]$rec.RangeRows -and $Step.EqRows -eq [single]$rec.EqRows -and $Step.StoredAvg -eq [single]$rec.AvgRangeRows -and
    [Convert]::ToBase64String($Step.KeyBytes) -eq [Convert]::ToBase64String([byte[]]$rec.KeyBytes)
    if ($same) { return , $orig }
    $floats = [byte[]]([BitConverter]::GetBytes([single]$Step.EqRows) + [BitConverter]::GetBytes([single]$Step.RangeRows) + [BitConverter]::GetBytes([single]$Step.StoredAvg))
    if ($rec.FixedEnd -gt 16) {
        # key in the fixed part: same length (ConvertTo-SqlKeyBytes pads to it)
        if ($Step.KeyBytes.Length -ne $rec.FixedEnd - 16) { throw "Step $($Step.Key): the key must take $($rec.FixedEnd - 16) bytes." }
        $out = [byte[]]$orig.Clone()
        [Array]::Copy($floats, 0, $out, 4, 12)
        [Array]::Copy($Step.KeyBytes, 0, $out, 16, $Step.KeyBytes.Length)
        return , $out
    }
    # key in the variable part: [prefix through the NULL bitmap][var count = 1][end offset][key]
    if ($rec.VarColumnCount -gt 1) { throw "Step $($Step.Key): records with $($rec.VarColumnCount) variable columns are not supported." }
    $prefixLength = $rec.FixedEnd + 2 + [int][Math]::Ceiling($rec.ColumnCount / 8.0)
    $out = New-Object 'System.Collections.Generic.List[byte]'
    $prefix = [byte[]](Get-Bytes $orig 0 $prefixLength)
    [Array]::Copy($floats, 0, $prefix, 4, 12)
    if ($Step.KeyBytes.Length -eq 0) {
        # an empty trailing variable column is not stored
        $prefix[0] = $prefix[0] -band 0xDF
        $out.AddRange($prefix)
    } else {
        $prefix[0] = $prefix[0] -bor 0x20
        $out.AddRange($prefix)
        $end = $prefixLength + 4 + $Step.KeyBytes.Length
        if ($end -gt 0x7FFF) { throw "Step $($Step.Key): the key is too long." }
        if ($rec.KeyComplex) { $end = $end -bor 0x8000 }
        $out.AddRange([BitConverter]::GetBytes([uint16]1))
        $out.AddRange([BitConverter]::GetBytes([uint16]$end))
        $out.AddRange($Step.KeyBytes)
    }
    return , $out.ToArray()
}

function ConvertTo-StatsStream($Model) {
    <# Builds the STATS_STREAM for an edit model: patched fixed section, rebuilt histogram item, shifted
       offsets, new lengths and checksum. Returns the bytes plus warnings for the script header. #>
    $D = $Model.Decoded
    $raw = [byte[]]$D.Raw
    $B = [int]$D.BlobOffset
    $kc = $D.Columns[0]
    $warnings = New-Object 'System.Collections.Generic.List[string]'

    # ---- histogram rules
    $steps = $Model.Steps.ToArray()
    $nullSteps = @($steps | Where-Object { $_.IsNull })
    if ($nullSteps.Count -gt 1) { throw 'The histogram can have only one NULL step.' }
    if ($nullSteps.Count -eq 1 -and -not $steps[0].IsNull) { throw 'The NULL step must be the first step.' }
    if ($nullSteps.Count -eq 1 -and -not $kc.IsNullable) { throw "The leading column $($kc.Name) is NOT NULL; it cannot have a NULL step." }
    $keySteps = @($steps | Where-Object { -not $_.IsNull })
    $hadKeys = @($D.Histogram | Where-Object { -not $_.IsNullStep }).Count -gt 0
    if ($hadKeys -and $keySteps.Count -eq 0) { throw 'Keep at least one histogram step with a key.' }
    foreach ($st in $keySteps) { if ($null -eq $st.KeyBytes) { throw 'An inserted step has no RANGE_HI_KEY yet: type a key for it.' } }
    if ($steps.Count -gt 201) { $warnings.Add("The histogram has $($steps.Count) steps; SQL Server builds at most 200 (plus the NULL step).") }
    foreach ($st in $steps) {
        foreach ($f in 'RangeRows', 'EqRows', 'StoredAvg') {
            if ([single]::IsNaN($st.$f) -or [single]::IsInfinity($st.$f) -or $st.$f -lt 0) { throw "Step $($st.Key): $f must be a number >= 0." }
        }
    }
    $previous = $null
    foreach ($st in $keySteps) {
        $sv = Get-StatsKeySortValue $st.KeyBytes $kc
        if ($null -eq $sv) { break }
        if ($null -ne $previous -and $sv -le $previous) { throw "RANGE_HI_KEY values must be in ascending order with no repeats: $($st.Key) comes after a key that is equal or greater." }
        $previous = $sv
    }
    $origKeys = @($D.Histogram | Where-Object { -not $_.IsNullStep } | ForEach-Object { [Convert]::ToBase64String([byte[]]$_.Record.KeyBytes) })
    $newKeys = @($keySteps | ForEach-Object { [Convert]::ToBase64String($_.KeyBytes) })
    $keysChanged = ($origKeys -join '|') -ne ($newKeys -join '|')
    # (the builder's keys come in the server's own order: no warning for them)
    if ($keysChanged -and $kc.SystemTypeId -in 175, 167, 35, 239, 231, 99 -and -not $Model.PSObject.Properties['ServerOrder']) { $warnings.Add('String keys were not checked for collation order; keep them sorted as the column collation sorts.') }

    # ---- histogram item: int64 offset per step (relative to the item), then the records
    $records = @(foreach ($st in $keySteps) { , (New-StatsHistogramRecord $st $raw) })
    $hist = New-Object 'System.Collections.Generic.List[byte]'
    [int64]$pos = 8 * $keySteps.Count
    foreach ($r in $records) { $hist.AddRange([BitConverter]::GetBytes($pos)); $pos += $r.Length }
    foreach ($r in $records) { $hist.AddRange([byte[]]$r) }

    # ---- fixed section (324 bytes)
    $fixed = [byte[]](Get-Bytes $raw $B 324)
    $h = $Model.Header; $o = $Model.OriginalHeader
    $put = { param([int]$At, [byte[]]$Value) [Array]::Copy($Value, 0, $fixed, $At, $Value.Length) }
    if ($h['Updated'] -ne $o['Updated']) { & $put 4 (ConvertTo-SqlDateTimeBytes $h['Updated']) }
    if ($h['Rows'] -ne $o['Rows']) {
        & $put 12 ([BitConverter]::GetBytes([int64]$h['Rows']))
        # the real copy at +184 follows Rows when it matched it
        if ([single]$D.Blob.HistogramRows -eq [single]$o['Rows']) { & $put 184 ([BitConverter]::GetBytes([single]$h['Rows'])) }
    }
    if ($h['Rows Sampled'] -ne $o['Rows Sampled']) { & $put 20 ([BitConverter]::GetBytes([int64]$h['Rows Sampled'])) }
    if ($h['Density'] -ne $o['Density']) { & $put 28 ([BitConverter]::GetBytes([single]$h['Density'])) }
    if ($h['Average key length'] -ne $o['Average key length']) { & $put 180 ([BitConverter]::GetBytes([single]$h['Average key length'])) }
    if ($keySteps.Count -ne $D.Blob.Steps) {
        & $put 164 ([BitConverter]::GetBytes([int32]$keySteps.Count))
        & $put 168 ([BitConverter]::GetBytes([int32]$keySteps.Count))
    }
    $nullEq = [single]0
    if ($nullSteps.Count -eq 1) { $nullEq = [single]$nullSteps[0].EqRows }
    if ($nullEq -ne [single]$D.Blob.NullStepEqRows) { & $put 188 ([BitConverter]::GetBytes($nullEq)) }
    $extDensity = @{}; $extLength = @{}
    foreach ($v in $Model.Vectors) {
        $i = $v.Vector - 1
        if ($v.AllDensity -ne $v.Source.AllDensity) {
            $slot = Get-StatsDensitySlot $v.Vector $D.Blob.VectorCount
            if ($null -ne $slot.Fixed) { & $put (32 + 4 * $slot.Fixed) ([BitConverter]::GetBytes([single]$v.AllDensity)) } else { $extDensity[$slot.Extra] = [single]$v.AllDensity }
        }
        if ($v.ColumnAverageLength -ne $v.Source.ColumnAverageLength) { if ($i -lt 33) { & $put (192 + 4 * $i) ([BitConverter]::GetBytes([single]$v.ColumnAverageLength)) } else { $extLength[$i - 33] = [single]$v.ColumnAverageLength } }
    }

    # ---- variable section: same items in bit order (less any the model drops), histogram replaced, offsets recomputed
    $allItems = @($D.VariableItems)
    $drop = @(); if ($Model.PSObject.Properties['DropBits']) { $drop = @($Model.DropBits) }
    $items = @($allItems | Where-Object { [int]$_.Bit -notin $drop })
    # a string index the source stream lacks (an empty statistic, or one loaded without it) is added in bit order
    $added = $Model.PSObject.Properties['ReplaceItems'] -and $Model.ReplaceItems.ContainsKey(1) -and -not @($items | Where-Object { [int]$_.Bit -eq 1 }).Count
    if ($added) { $items = @(@($items) + [pscustomobject]@{ Bit = 1; RelativeOffset = 0; StreamOffset = 0; Length = 0 } | Sort-Object { [int]$_.Bit }) }
    $varBase = 332 + 8 * ($items.Count + 1)
    $newData = @()
    foreach ($it in $items) {
        $data = [byte[]]@(); if ($it.Length) { $data = [byte[]](Get-Bytes $raw $it.StreamOffset $it.Length) }
        switch ([int]$it.Bit) {
            0 { $data = $hist.ToArray() }
            1 {
                if ($Model.PSObject.Properties['ReplaceItems'] -and $Model.ReplaceItems.ContainsKey(1)) { $data = [byte[]]$Model.ReplaceItems[1] }
                elseif ($keysChanged) { $warnings.Add('The string index (trie) used for LIKE estimates was not rebuilt; it still describes the original keys.') }
            }
            4 { if ($h['Unfiltered Rows'] -ne $o['Unfiltered Rows']) { $data = [BitConverter]::GetBytes([int64]$h['Unfiltered Rows']) } }
            7 { if ($h['Pages sampled'] -ne $o['Pages sampled']) { $data = [BitConverter]::GetBytes([int64]$h['Pages sampled']) } }
            10 { if ($h['Persisted sample percent'] -ne $o['Persisted sample percent']) { $data = [BitConverter]::GetBytes([double]$h['Persisted sample percent']) } }
            8 { foreach ($k in $extDensity.Keys) { [Array]::Copy([BitConverter]::GetBytes($extDensity[$k]), 0, $data, 4 * $k, 4) } }
            9 { foreach ($k in $extLength.Keys) { [Array]::Copy([BitConverter]::GetBytes($extLength[$k]), 0, $data, 4 * $k, 4) } }
        }
        $newData += , $data
    }
    $offsets = New-Object 'System.Collections.Generic.List[int64]'
    [int64]$pos = 0
    foreach ($data in $newData) { $offsets.Add($pos); $pos += $data.Length }
    $offsets.Add($pos)
    for ($k = 0; $k -lt $items.Count; $k++) {
        if ([int]$items[$k].Bit -eq 5) {
            # distinct value synopsis: one int64 per vector, relative to the variable section start
            $shift = $offsets[$k] - $items[$k].RelativeOffset
            if ($shift -ne 0) {
                $data = [byte[]]$newData[$k].Clone()
                for ($v = 0; $v -lt $D.Blob.VectorCount; $v++) { [Array]::Copy([BitConverter]::GetBytes([BitConverter]::ToInt64($data, 8 * $v) + $shift), 0, $data, 8 * $v, 8) }
                $newData[$k] = $data
            }
        }
    }
    $oldVarEnd = 332 + 8 * ($allItems.Count + 1) + $(if ($allItems.Count) { $allItems[$allItems.Count - 1].RelativeOffset + $allItems[$allItems.Count - 1].Length } else { 0 })
    $trailer = [byte[]]@()
    if ($B + $oldVarEnd -lt $B + $D.Header.BlobLength) { $trailer = [byte[]](Get-Bytes $raw ($B + $oldVarEnd) ($D.Header.BlobLength - $oldVarEnd)) }

    # ---- assemble, then lengths and checksum
    $out = New-Object 'System.Collections.Generic.List[byte]'
    $out.AddRange([byte[]](Get-Bytes $raw 0 $B))
    $out.AddRange($fixed)
    if ($drop.Count -gt 0 -or $added) {
        # presence bitmask of the items kept
        [uint64]$mask = 0
        foreach ($it in $items) { $mask = $mask -bor [uint64][Math]::Pow(2, [int]$it.Bit) }
        $out.AddRange([BitConverter]::GetBytes($mask))
    } else { $out.AddRange([byte[]](Get-Bytes $raw ($B + 324) 8)) }
    foreach ($x in $offsets) { $out.AddRange([BitConverter]::GetBytes([int64]$x)) }
    foreach ($data in $newData) { $out.AddRange([byte[]]$data) }
    $out.AddRange($trailer)
    $bytes = $out.ToArray()
    [Array]::Copy([BitConverter]::GetBytes([int64]$bytes.Length), 0, $bytes, 24, 8)
    [Array]::Copy([BitConverter]::GetBytes([int64]($bytes.Length - $B)), 0, $bytes, 32, 8)
    [Array]::Copy([BitConverter]::GetBytes((Get-StatsStreamCrc $bytes)), 0, $bytes, 16, 4)
    return [pscustomobject]@{ Bytes = $bytes; Warnings = $warnings.ToArray() }
}

function Test-StatsStreamMatchesModel([byte[]]$Bytes, $Model) {
    # Decodes the new stream again and lists every value that differs from the model (empty = good).
    $D = $Model.Decoded
    $names = @($D.Columns | ForEach-Object { $_.Name })
    $n = ConvertFrom-StatsStream -Bytes $Bytes -Names $names -Label 'edited'
    $bad = New-Object 'System.Collections.Generic.List[string]'
    if (-not $n.Header.ChecksumValid) { $bad.Add('checksum') }
    foreach ($w in $n.Warnings) { $bad.Add("decoder warning: $w") }
    $m = $n.Blob
    if ([int64]$m.Rows -ne $Model.Header['Rows']) { $bad.Add('Rows') }
    if ([int64]$m.RowsSampled -ne $Model.Header['Rows Sampled']) { $bad.Add('Rows Sampled') }
    if ((Format-SqlValue $m.Updated 61) -ne (Format-SqlValue ([System.Data.SqlTypes.SqlDateTime]::new($Model.Header['Updated'])).Value 61)) { $bad.Add('Updated') }
    $steps = @($n.Histogram)
    if ($steps.Count -ne $Model.Steps.ToArray().Count) { $bad.Add("step count $($steps.Count) <> $($Model.Steps.ToArray().Count)") }
    else {
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $a = $steps[$i]; $e = $Model.Steps[$i]
            if ($a.IsNullStep -ne $e.IsNull -or $a.EqRows -ne $e.EqRows -or $a.RangeRows -ne $e.RangeRows) { $bad.Add("step $($i + 1) values") }
            elseif (-not $a.IsNullStep -and ([Convert]::ToBase64String([byte[]]$a.Record.KeyBytes) -ne [Convert]::ToBase64String($e.KeyBytes) -or $a.Record.AvgRangeRows -ne $e.StoredAvg)) { $bad.Add("step $($i + 1) key or average") }
        }
    }
    foreach ($v in $Model.Vectors) {
        $x = $n.DensityVector[$v.Vector - 1]
        if ($x.AllDensity -ne $v.AllDensity -or $x.ColumnAverageLength -ne $v.ColumnAverageLength) { $bad.Add("density vector $($v.Vector)") }
    }
    return , $bad.ToArray()
}

function New-StatsUpdateScript {
    <# T-SQL that loads the edited statistics, with an optional block that restores the original stream. #>
    param($Model, [byte[]]$Bytes, [string]$Database, [string]$Table, [string]$Statistics, [bool]$NoRecompute,
        [bool]$OriginalNoRecompute, [bool]$IncludeRestore, [string[]]$Changes, [string[]]$Warnings)
    $q = { param([string]$Name) '[' + $Name.Replace(']', ']]') + ']' }
    $hex = { param([byte[]]$b) '0x' + [BitConverter]::ToString($b).Replace('-', '') }
    $L = New-Object 'System.Collections.Generic.List[string]'
    $L.Add('/*')
    $L.Add("  Edited statistics generated by Decode-StatsStream.ps1 on $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm', $script:Inv))")
    $L.Add("  Source: $($Model.Decoded.Label)")
    $L.Add('')
    $L.Add('  STATS_STREAM is undocumented and unsupported. Load edited statistics only on a test')
    $L.Add('  or non-production copy unless you know exactly why. The stream holds histogram key')
    $L.Add('  values, which are real data: be careful where you paste or store this script.')
    $L.Add('')
    $L.Add('  Changes:')
    $shown = @($Changes | Select-Object -First 60)
    foreach ($c in $shown) { $L.Add("    - $($c.Replace('*/', '* /'))") }
    if ($Changes.Count -gt $shown.Count) { $L.Add("    ... and $($Changes.Count - $shown.Count) more") }
    if ($Warnings) {
        $L.Add('')
        $L.Add('  Notes:')
        foreach ($w in $Warnings) { $L.Add("    - $w") }
    }
    if ($NoRecompute) {
        $L.Add('')
        $L.Add('  NORECOMPUTE keeps automatic statistics updates from replacing the edited statistics.')
    }
    $L.Add('*/')
    if ($Database) { $L.Add("USE $(& $q $Database);"); $L.Add('GO') }
    $L.Add("UPDATE STATISTICS $Table ($(& $q $Statistics))")
    $L.Add("WITH STATS_STREAM = $(& $hex $Bytes)$(if ($NoRecompute) { ', NORECOMPUTE' });")
    $L.Add('GO')
    if ($IncludeRestore) {
        $L.Add('')
        $L.Add('/* ---- To restore the original statistics, run:')
        $L.Add("UPDATE STATISTICS $Table ($(& $q $Statistics))")
        $L.Add("WITH STATS_STREAM = $(& $hex ([byte[]]$Model.Decoded.Raw))$(if ($OriginalNoRecompute) { ', NORECOMPUTE' });")
        $L.Add('---- */')
    }
    return ($L -join "`r`n") + "`r`n"
}

#endregion

#region ---------------------------------------------------------------- report

function Format-AsciiTable {
    param([object[]]$Rows, [string[]]$Columns, [string[]]$Headers, [string[]]$RightAlign = @())
    if (-not $Headers) { $Headers = $Columns }
    $w = @()
    for ($i = 0; $i -lt $Columns.Count; $i++) { $w += $Headers[$i].Length }
    $cells = @()
    foreach ($r in $Rows) {
        $line = @()
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $v = $r.($Columns[$i])
            if ($null -eq $v) { $v = '' }
            $v = ([string]$v) -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t'
            if ($v.Length -gt $w[$i]) { $w[$i] = $v.Length }
            $line += $v
        }
        $cells += , $line
    }
    $sep = '+' + (($w | ForEach-Object { '-' * ($_ + 2) }) -join '+') + '+'
    $out = New-Object 'System.Collections.Generic.List[string]'
    $out.Add($sep)
    $out.Add('| ' + ((0..($Columns.Count - 1) | ForEach-Object { $Headers[$_].PadRight($w[$_]) }) -join ' | ') + ' |')
    $out.Add($sep)
    foreach ($line in $cells) {
        $parts = for ($i = 0; $i -lt $Columns.Count; $i++) {
            if ($RightAlign -contains $Columns[$i]) { $line[$i].PadLeft($w[$i]) } else { $line[$i].PadRight($w[$i]) }
        }
        $out.Add('| ' + ($parts -join ' | ') + ' |')
    }
    $out.Add($sep)
    return $out.ToArray()
}

function Format-KeyValueTable([System.Collections.IDictionary]$Pairs) {
    $rows = foreach ($k in $Pairs.Keys) { [pscustomobject]@{ Field = $k; Value = $Pairs[$k] } }
    return Format-AsciiTable -Rows $rows -Columns Field, Value
}

function New-Section([string]$Title) {
    return @('', ('=' * 100), "  $Title", ('=' * 100))
}

function Format-TraceFlag2388Section($D) {
    $out = @()
    $out += New-Section 'DBCC SHOW_STATISTICS WITH TRACE FLAG 2388 (rebuilt from the stream)'
    $cols = 'Updated', 'Table Cardinality', 'Snapshot Ctr', 'Steps', 'Density', 'Rows Above', 'Rows Below',
    'Squared Variance Error', 'Inserts Since Last Update', 'Deletes Since Last Update', 'Leading column Type'
    $rows = foreach ($r in $D.TraceFlag2388) {
        $o = [ordered]@{}
        foreach ($c in $cols) {
            $v = $r.$c
            if ($null -eq $v) { $o[$c] = 'NULL' }
            elseif ($v -is [datetime]) { $o[$c] = Format-SqlValue $v 61 }
            elseif ($v -is [double]) { $o[$c] = $v.ToString('R', $script:Inv) }
            else { $o[$c] = [string]$v }
        }
        [pscustomobject]$o
    }
    $out += Format-AsciiTable -Rows $rows -Columns $cols -RightAlign 'Table Cardinality', 'Snapshot Ctr', 'Steps', 'Density', 'Rows Above', 'Rows Below', 'Squared Variance Error', 'Inserts Since Last Update', 'Deletes Since Last Update'
    if ($D.Blob -and $D.Blob.VectorCount -gt 0) {
        if ($null -ne $D.CurrentSnapshotCtr) {
            $out += 'Row 1 Snapshot Ctr read from sys.sysobjvalues.value over the DAC (it is not stored in the stream).'
        } else {
            $out += 'Row 1 Snapshot Ctr is NOT stored in the stream (it lives in sys.sysobjvalues.value): the row count is shown as an estimate. Use -UseDac for the exact value.'
        }
    }
    return , $out
}

function Format-DataCheckSection($Check) {
    # Summary, findings and the worst ranges. Step numbers and counts only: key values stay in the histogram section.
    $out = @()
    $out += New-Section 'DATA CHECK: HISTOGRAM AGAINST THE TABLE'
    $out += Format-KeyValueTable $Check.Summary
    if ($Check.Findings.Count -gt 0) { $out += ''; $out += @($Check.Findings | ForEach-Object { "* $_" }) }
    $bad = @($Check.Steps | Where-Object { $_.Result -in 'Good', 'Fair', 'Poor', 'Partial' } |
            Sort-Object { [Math]::Max([double]$_.EqQError, [double]$_.RangeQError) } -Descending | Select-Object -First 25)
    if ($bad.Count -gt 0) {
        $out += ''
        $out += 'Ranges that differ most (largest EQ_ROWS or RANGE_ROWS q-error first; step numbers as in the histogram):'
        $rows = foreach ($r in $bad) {
            [pscustomobject]@{
                Step = $(if ($null -ne $r.Step) { $r.Step } else { '' }); Kind = $r.Kind; Result = $r.Result
                'EQ stats' = Format-Float $r.StatsEqRows; 'EQ table' = $r.TableEqRows; 'EQ q' = $r.EqQError
                'RANGE stats' = Format-Float $r.StatsRangeRows; 'RANGE table' = $r.TableRangeRows; 'RANGE q' = $r.RangeQError
                'DISTINCT stats' = Format-Float $r.StatsDistinct; 'DISTINCT table' = $r.TableDistinct; 'DISTINCT q' = $r.DistinctQError
                'Max rows per value' = $r.MaxRowsPerValue
            }
        }
        $cols = 'Step', 'Kind', 'Result', 'EQ stats', 'EQ table', 'EQ q', 'RANGE stats', 'RANGE table', 'RANGE q', 'DISTINCT stats', 'DISTINCT table', 'DISTINCT q', 'Max rows per value'
        $out += Format-AsciiTable -Rows $rows -Columns $cols -RightAlign (@($cols | Select-Object -Skip 3) + 'Step')
    }
    return , $out
}

function Format-StatsReport($D, $Info) {
    $L = New-Object 'System.Collections.Generic.List[string]'
    $h = $D.Header
    $L.Add('#' * 100)
    $L.Add("  STATS_STREAM decode: $($D.Label)")
    $L.Add('#' * 100)
    if ($Info) {
        $p = [ordered]@{}
        foreach ($k in $Info.Keys) { $p[$k] = $Info[$k] }
        $L.AddRange([string[]](Format-KeyValueTable $p))
    }

    $L.AddRange([string[]](New-Section 'STATS_STREAM HEADER (40 bytes)'))
    $crc = 'VALID'
    if (-not $h.ChecksumValid) { $crc = 'INVALID (calculated 0x{0:X8})' -f $h.CalculatedChecksum }
    $L.AddRange([string[]](Format-KeyValueTable ([ordered]@{
                    'Stream version'          = $h.StreamVersion
                    'Number of stats columns' = $h.NumberOfColumns
                    'Checksum'                = ('0x{0:X8}  {1}' -f $h.Checksum, $crc)
                    'STATS_STREAM length'     = "$($h.StreamLength) (actual $($h.ActualLength))"
                    'Stats blob length'       = $h.BlobLength
                    'Reserved (8-15, 20-23)'  = "$($h.Reserved8), $($h.Reserved20)"
                })))

    $L.AddRange([string[]](New-Section 'STATS COLUMNS (24 bytes each)'))
    $crow = $D.Columns | ForEach-Object {
        [pscustomobject]@{
            '#' = $_.Ordinal; Name = $_.Name; Type = $_.TypeName; SysType = $_.SystemTypeId; UserType = $_.UserTypeId
            MaxLen = $_.MaxLength; Prec = $_.Precision; Scale = $_.Scale; Nullable = $_.IsNullable
            Flags = ('0x{0:X2}' -f $_.Flags); CollationId = $(if ($_.CollationId) { '0x{0:X8}' -f $_.CollationId } else { '' })
            Collation = $_.Collation; CodePage = $(if ($_.CodePage) { $_.CodePage } else { '' })
        }
    }
    $L.AddRange([string[]](Format-AsciiTable -Rows $crow -Columns '#', Name, Type, SysType, UserType, MaxLen, Prec, Scale, Nullable, Flags, CollationId, Collation, CodePage -RightAlign '#', SysType, UserType, MaxLen, Prec, Scale))

    foreach ($w in $D.Warnings) { $L.Add("WARNING: $w") }
    if (-not $D.Blob) {
        $L.AddRange([string[]](Format-TraceFlag2388Section $D))
        return $L.ToArray()
    }
    $m = $D.Blob

    $L.AddRange([string[]](New-Section 'STATS BLOB - FIXED SECTION (324 bytes)'))
    $pct = ''
    if ($m.Rows -gt 0) { $pct = [string]::Format($script:Inv, ' ({0:0.##}% {1})', (100.0 * $m.RowsSampled / $m.Rows), $(if ($m.Rows -eq $m.RowsSampled) { 'FULLSCAN' } else { 'SAMPLED' })) }
    $stepsTotal = $m.Steps
    if ($m.NullStepEqRows -gt 0) { $stepsTotal++ }
    $L.AddRange([string[]](Format-KeyValueTable ([ordered]@{
                    'Blob version'                             = $m.BlobVersion
                    'Updated'                                  = (Format-SqlValue $m.Updated 61)
                    'Rows'                                     = $m.Rows
                    'Rows sampled'                             = "$($m.RowsSampled)$pct"
                    'Density (pre-2008, not used)'             = (Format-Float $m.Density)
                    'Histogram steps (stored / DBCC Steps)'    = "$($m.Steps) / $stepsTotal"
                    'Histogram steps (second copy)'            = $m.Steps2
                    'Vector count'                             = $m.VectorCount
                    'Histogram record fixed-data length'       = $m.HistogramFixedLength
                    'Average key length'                       = (Format-Float $m.AverageKeyLength)
                    'Rows (real copy)'                         = (Format-Float $m.HistogramRows)
                    'NULL step EQ_ROWS'                        = (Format-Float $m.NullStepEqRows)
                    'Variable section bitmask'                 = ('0x{0:X16}' -f $m.PresenceBitmask)
                })))

    $L.AddRange([string[]](New-Section 'STATS BLOB - VARIABLE SECTION ITEMS'))
    $L.AddRange([string[]](Format-AsciiTable -Rows $D.VariableItems -Columns Bit, Name, RelativeOffset, StreamOffset, Length -RightAlign Bit, RelativeOffset, StreamOffset, Length))
    $sv = [ordered]@{}
    if ($null -ne $D.UnfilteredRows) { $sv['Unfiltered rows'] = $D.UnfilteredRows }
    if ($null -ne $D.PagesSampled) { $sv['Pages sampled'] = $D.PagesSampled }
    if ($null -ne $D.PersistedSamplePercent) { $sv['Persisted sample percent'] = $D.PersistedSamplePercent.ToString('R', $script:Inv) }
    if ($D.ColumnstorePageCounts.Count -gt 0) { $sv['Columnstore pages per column'] = (($D.ColumnstorePageCounts | ForEach-Object { "$($_.ColumnId): $($_.Pages)" }) -join ', ') }
    if ($null -ne $D.StreamingStatisticsFlags) { $sv['Streaming statistics flags'] = ('0x{0:X8}' -f $D.StreamingStatisticsFlags) }
    if ($D.StringIndex) { $sv['String index'] = 'YES' } else { $sv['String index'] = 'NO' }
    if ($D.LeadingColumnType) { $sv['Leading column type (derived from history)'] = $D.LeadingColumnType }
    $L.AddRange([string[]](Format-KeyValueTable $sv))

    $L.AddRange([string[]](New-Section 'DENSITY VECTOR'))
    $dvr = $D.DensityVector | ForEach-Object { [pscustomobject]@{ Vector = $_.Vector; 'All density' = (Format-Float $_.AllDensity); 'Average Length' = (Format-Float $_.AverageLength); 'Column avg length (stored)' = (Format-Float $_.ColumnAverageLength); Columns = $_.Columns } }
    $L.AddRange([string[]](Format-AsciiTable -Rows $dvr -Columns Vector, 'All density', 'Average Length', 'Column avg length (stored)', Columns -RightAlign Vector, 'All density', 'Average Length', 'Column avg length (stored)'))
    $nonZero = @(0..32 | Where-Object { $_ -ge $m.VectorCount -and ($m.Densities[$_] -ne 0 -or $m.AverageLengths[$_] -ne 0) })
    if ($nonZero.Count -gt 0) { $L.Add("NOTE: fixed slots beyond the vector count are not zero: $($nonZero -join ', ')") }

    $L.AddRange([string[]](New-Section "HISTOGRAM ($($D.Histogram.Count) steps, key column $($D.Columns[0].Name) $($D.Columns[0].TypeName))"))
    $kc = $D.Columns[0]
    $hr = $D.Histogram | ForEach-Object {
        $k = 'NULL'
        if (-not $_.IsNullStep) { $k = Format-SqlValue $_.RangeHiKey $kc.SystemTypeId $kc.Scale }
        $_.RangeHiKeyText = $k
        [pscustomobject]@{
            Step = $_.Step; RANGE_HI_KEY = $k; RANGE_ROWS = (Format-Float $_.RangeRows); EQ_ROWS = (Format-Float $_.EqRows)
            DISTINCT_RANGE_ROWS = (Format-Float $_.DistinctRangeRows); AVG_RANGE_ROWS = (Format-Float $_.AvgRangeRows)
            RecOffset = $_.RecordOffset; RecLen = $_.RecordLength
            Note = $(if ($null -ne $_.StoredAvgRangeRows -and $_.StoredAvgRangeRows -ne $_.AvgRangeRows) { "stored AVG_RANGE_ROWS $(Format-Float $_.StoredAvgRangeRows)" } else { '' })
        }
    }
    if ($hr) {
        $hc = 'Step', 'RANGE_HI_KEY', 'RANGE_ROWS', 'EQ_ROWS', 'DISTINCT_RANGE_ROWS', 'AVG_RANGE_ROWS', 'RecOffset', 'RecLen'
        if (@($hr | Where-Object { $_.Note }).Count -gt 0) { $hc += 'Note' }
        $L.AddRange([string[]](Format-AsciiTable -Rows $hr -Columns $hc -RightAlign Step, RANGE_ROWS, EQ_ROWS, DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS, RecOffset, RecLen))
        $first = $D.Histogram | Where-Object { -not $_.IsNullStep } | Select-Object -First 1
        if ($first) {
            $r = $first.Record
            $L.Add(("Step record format: status A 0x{0:X2}, status B 0x{1:X2}, fixed-data end {2}, columns {3}, NULL bitmap 0x{4:X2}, variable columns {5}" -f $r.StatusA, $r.StatusB, $r.FixedEnd, $r.ColumnCount, $r.NullBitmap, $r.VarColumnCount))
        }
    } else { $L.Add('(no histogram)') }

    if ($D.UpdateHistory.Count -gt 0) {
        $hist = $D.UpdateHistory
        $L.AddRange([string[]](New-Section "UPDATE HISTORY - raw records ($($hist.Count) x $($hist[0].RecordSize) bytes, newest first, current update not included)"))
        $rows = $hist | ForEach-Object {
            [pscustomobject]@{
                Record = $_.Index; Updated = (Format-SqlValue $_.Updated 61)
                'Table Cardinality' = $_.TableCardinality.ToString('R', $script:Inv); 'Snapshot Ctr' = $_.SnapshotCtr; Steps = $_.Steps
                Density = $_.Density.ToString('R', $script:Inv)
                'Next: Rows Above' = $_.RowsAbove.ToString('R', $script:Inv); 'Next: Rows Below' = $_.RowsBelow.ToString('R', $script:Inv)
                'Next: Inserts' = $_.InsertsSinceLastUpdate.ToString('R', $script:Inv); 'Next: Deletes' = $_.DeletesSinceLastUpdate.ToString('R', $script:Inv)
                'Next: Squared Variance Error' = $_.SquaredVarianceError.ToString('R', $script:Inv)
            }
        }
        $c = 'Record', 'Updated', 'Table Cardinality', 'Snapshot Ctr', 'Steps', 'Density', 'Next: Rows Above', 'Next: Rows Below', 'Next: Inserts', 'Next: Deletes', 'Next: Squared Variance Error'
        $L.AddRange([string[]](Format-AsciiTable -Rows $rows -Columns $c -RightAlign Record, 'Snapshot Ctr', Steps))
        $L.Add('"Next:" columns were measured by the update that followed the record (newer record, or the current statistics for record 0).')
    }

    $L.AddRange([string[]](Format-TraceFlag2388Section $D))

    if ($D.StringIndex) {
        $si = $D.StringIndex
        $L.AddRange([string[]](New-Section 'STRING INDEX (trie / string summary)'))
        $L.AddRange([string[]](Format-KeyValueTable ([ordered]@{
                        'Strings sampled (incl. NULL)'      = $si.StringsSampled
                        'NULL values in sample'             = $si.NullsInSample
                        'Distinct strings (NULL counts 1)'  = $si.DistinctStrings
                        'Sum of node counts'                = $si.CountSum
                        'Compressed string length (chars)'  = $si.CompressedLength
                        'Node count'                        = $si.NodeCount
                        'Trie marker, format version'       = ('0x{0:X2}, {1}' -f $si.PresentMarker, $si.Version)
                        'Full prefix / suffix (chars)'      = "$($si.FullPrefix) / $($si.FullSuffix)"
                        'Unused (+25)'                      = $si.Unused25
                        'Trailer'                           = (ConvertTo-Hex $si.Trailer)
                    })))
        $cs = $si.CompressedString
        if ($cs.Length -gt 2000) { $cs = $cs.Substring(0, 2000) + "... ($($si.CompressedString.Length) chars)" }
        $L.Add("Compressed string: '$cs'")
        $L.Add('')
        $L.Add('Trie (pre-order; [n] = sampled strings ending at this node; segment shown in quotes):')
        $max = $si.Nodes.Count
        if ($MaxStringIndexNodes -gt 0 -and $max -gt $MaxStringIndexNodes) { $max = $MaxStringIndexNodes }
        for ($i = 0; $i -lt $max; $i++) {
            $nd = $si.Nodes[$i]
            $cnt = ''
            if ($nd.Count -gt 0) { $cnt = " [$($nd.Count)]  => '$($nd.Text)'" }
            $L.Add(('{0}{1}''{2}''{3}' -f ('  ' * $nd.Depth), $(if ($nd.HasChildren) { '+ ' } else { '- ' }), $nd.Segment, $cnt))
        }
        if ($max -lt $si.Nodes.Count) { $L.Add("... $($si.Nodes.Count - $max) more nodes (use -MaxStringIndexNodes 0 to print all)") }
    }

    if ($D.SampledScanDump.Count -gt 0) {
        $L.AddRange([string[]](New-Section 'DISTINCT VALUE SYNOPSIS (k smallest hash values per vector, heap order)'))
        $sr = $D.SampledScanDump | ForEach-Object {
            [pscustomobject]@{
                Vector = $_.Vector; Offset = $_.Offset; Count = $_.Count; Sum = $_.Sum.ToString('G10', $script:Inv); Min = $(if ($_.Count) { $_.Min.ToString('G10', $script:Inv) }); Max = $(if ($_.Count) { $_.Max.ToString('G10', $script:Inv) })
                'Distinct in sample' = $(if ($null -ne $_.DistinctInSample) { [Math]::Round($_.DistinctInSample).ToString('N0', $script:Inv) })
            }
        }
        $L.AddRange([string[]](Format-AsciiTable -Rows $sr -Columns Vector, Offset, Count, Sum, Min, Max, 'Distinct in sample' -RightAlign Vector, Offset, Count, Sum, Min, Max, 'Distinct in sample'))
        $L.Add('Distinct in sample: exact when Count is below 1024, otherwise the k-minimum-values estimate (Count - 1) / Max.')
        foreach ($v in $D.SampledScanDump) {
            $n = $v.Count
            if ($MaxSampledScanValues -gt 0 -and $n -gt $MaxSampledScanValues) { $n = $MaxSampledScanValues }
            if ($n -gt 0) {
                $vals = ($v.Values[0..($n - 1)] | ForEach-Object { $_.ToString('G10', $script:Inv) }) -join ', '
                if ($n -lt $v.Count) { $vals += ", ... ($($v.Count - $n) more)" }
                $L.Add("Vector $($v.Vector): $vals")
            }
        }
    }

    if ($D.UnknownItems.Count -gt 0) {
        $L.AddRange([string[]](New-Section 'UNKNOWN VARIABLE ITEMS'))
        $L.AddRange([string[]](Format-AsciiTable -Rows $D.UnknownItems -Columns Bit, Length, Hex))
    }

    if ($IncludeHexDump) {
        $L.AddRange([string[]](New-Section 'LAYOUT MAP'))
        $lr = $D.Layout | ForEach-Object { [pscustomobject]@{ Offset = $_.Offset; Hex = ('0x{0:X4}' -f $_.Offset); Length = $_.Length; Field = $_.Field; Value = $_.Value } }
        $L.AddRange([string[]](Format-AsciiTable -Rows $lr -Columns Offset, Hex, Length, Field, Value -RightAlign Offset, Length))
        $L.AddRange([string[]](New-Section 'HEX DUMP'))
        $b = $D.Raw
        for ($o = 0; $o -lt $b.Length; $o += 16) {
            $n = [Math]::Min(16, $b.Length - $o)
            $chunk = Get-Bytes $b $o $n
            $hex = ([BitConverter]::ToString($chunk).Replace('-', ' ')).PadRight(47)
            $asc = -join ($chunk | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
            $L.Add(('{0:X8}  {1}  {2}' -f $o, $hex, $asc))
        }
    }
    return $L.ToArray()
}

#endregion

#region ---------------------------------------------------------------- server access

function Invoke-Query($Connection, [string]$Sql, [hashtable]$Parameters = @{}) {
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 120
    foreach ($k in $Parameters.Keys) { $null = $cmd.Parameters.AddWithValue($k, $Parameters[$k]) }
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $ds = New-Object System.Data.DataSet
    $null = $da.Fill($ds)
    return , $ds.Tables
}

function Read-ResultSets($Connection, [string]$Sql, [hashtable]$Parameters = @{}) {
    <# Typed reader (GetValue, falling back to GetSqlValue for overflow/UDT values). #>
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 120
    foreach ($k in $Parameters.Keys) { $null = $cmd.Parameters.AddWithValue($k, $Parameters[$k]) }
    $r = $cmd.ExecuteReader()
    $sets = @()
    try {
        do {
            $rows = @()
            while ($r.Read()) {
                $o = [ordered]@{}
                for ($i = 0; $i -lt $r.FieldCount; $i++) {
                    $v = $null
                    if ($r.GetDataTypeName($i) -match 'hierarchyid|geometry|geography') {
                        # CLR types: compare the serialized bytes
                        if ($r.IsDBNull($i)) { $v = [DBNull]::Value } else { $v = $r.GetSqlBytes($i).Value }
                        $o[$r.GetName($i)] = $v
                        continue
                    }
                    try { $v = $r.GetValue($i) }
                    catch {
                        try { $v = $r.GetSqlValue($i) } catch { try { $v = $r.GetSqlBytes($i) } catch { $v = '<unreadable>' } }
                    }
                    $o[$r.GetName($i)] = $v
                }
                $rows += [pscustomobject]$o
            }
            $sets += , $rows
        } while ($r.NextResult())
    } finally { $r.Close() }
    return , $sets
}

function Get-StatsTargets($Connection, [string]$TableName, [string[]]$StatNames) {
    $t = Invoke-Query $Connection @'
SELECT o.object_id, s.name AS schema_name, o.name AS table_name
FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.object_id = OBJECT_ID(@t)
'@ @{ '@t' = $TableName }
    if ($t[0].Rows.Count -eq 0) { throw "Table '$TableName' not found in database '$($Connection.Database)'." }
    $obj = $t[0].Rows[0]
    $st = Invoke-Query $Connection @'
SELECT s.*, sp.last_updated AS sp_last_updated, sp.rows AS sp_rows, sp.rows_sampled AS sp_rows_sampled,
       sp.steps AS sp_steps, sp.unfiltered_rows AS sp_unfiltered_rows, sp.modification_counter AS sp_modification_counter,
       i.type_desc AS index_type
FROM sys.stats s
OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
LEFT JOIN sys.indexes i ON i.object_id = s.object_id AND i.index_id = s.stats_id
WHERE s.object_id = @id
ORDER BY s.stats_id
'@ @{ '@id' = [int]$obj.object_id }
    $rows = @($st[0].Rows)
    if ($StatNames) {
        $sel = @()
        foreach ($n in $StatNames) {
            $m = @($rows | Where-Object { $_.name -eq $n })
            if ($m.Count -eq 0) { Write-Warning "Statistics '$n' not found on $TableName."; continue }
            $sel += $m
        }
        $rows = $sel
    }
    [pscustomobject]@{ ObjectId = [int]$obj.object_id; Schema = [string]$obj.schema_name; Table = [string]$obj.table_name; Stats = $rows }
}

function Get-StatsColumnNames($Connection, [int]$ObjectId, [int]$StatsId, [int]$Count) {
    # sys.stats_columns lists an index's columns in index_column_id (definition) order; the stream follows key_ordinal
    $q = Invoke-Query $Connection @'
SELECT c.name FROM sys.stats_columns sc
JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
LEFT JOIN sys.index_columns ic ON ic.object_id = sc.object_id AND ic.index_id = sc.stats_id AND ic.column_id = sc.column_id AND ic.key_ordinal > 0
WHERE sc.object_id = @o AND sc.stats_id = @s ORDER BY COALESCE(ic.key_ordinal, sc.stats_column_id);
SELECT c.name FROM sys.index_columns ic
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
WHERE ic.object_id = @o AND i.type = 1 AND ic.key_ordinal > 0 ORDER BY ic.key_ordinal;
'@ @{ '@o' = $ObjectId; '@s' = $StatsId }
    $names = @($q[0].Rows | ForEach-Object { [string]$_.name })
    if ($names.Count -lt $Count) {
        # nonclustered index statistics carry the clustering key as trailing columns
        foreach ($k in @($q[1].Rows | ForEach-Object { [string]$_.name })) {
            if ($names.Count -ge $Count) { break }
            if ($names -notcontains $k) { $names += $k }
        }
    }
    return , $names
}

function Get-CollationInfo($Connection, [int[]]$Ids) {
    $script:CollationInfo = @{}
    $ids = @($Ids | Where-Object { $_ -ne 0 } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return }
    $list = ($ids | ForEach-Object { [string]$_ }) -join ','
    $q = Invoke-Query $Connection ("SELECT id, name, cp FROM (SELECT CAST(COLLATIONPROPERTY(name,'CollationId') AS int) id, name, CAST(COLLATIONPROPERTY(name,'CodePage') AS int) cp FROM sys.fn_helpcollations()) x WHERE id IN ($list)")
    foreach ($r in $q[0].Rows) {
        if (-not $script:CollationInfo.ContainsKey([int]$r.id)) { $script:CollationInfo[[int]$r.id] = @{ Name = [string]$r.name; CodePage = [int]$r.cp } }
    }
}

function Get-ColumnIdsFromStream([byte[]]$Bytes) {
    $n = [BitConverter]::ToInt32($Bytes, 4)
    $ids = @()
    for ($i = 0; $i -lt $n; $i++) {
        $ids += [BitConverter]::ToInt32($Bytes, 40 + 24 * $i + 16)
        # sql_variant keys carry their own collation inside each value
    }
    return , $ids
}

function Get-CurrentSnapshotCtr($DacConnection, [int]$ObjectId, [int]$StatsId) {
    <#
      Snapshot Ctr of the current statistics (leading column modification counter when they
      were updated) is not in the stream: it is stored next to the blob, in
      sys.sysobjvalues.value (valclass 60), which is only readable over the DAC.
    #>
    if ($null -eq $DacConnection) { return $null }
    try {
        $q = Invoke-Query $DacConnection 'SELECT TOP (1) CAST(value AS bigint) AS v FROM sys.sysobjvalues WHERE valclass = 60 AND objid = @o AND subobjid = @s ORDER BY valnum' @{ '@o' = $ObjectId; '@s' = $StatsId }
        if ($q[0].Rows.Count -eq 0 -or $q[0].Rows[0].v -is [DBNull]) { return $null }
        return [int64]$q[0].Rows[0].v
    } catch { return $null }
}

function Get-TraceFlag2388FromServer($Connection, [string]$QualifiedTable, [string[]]$StatNames) {
    <#
      Runs DBCC SHOW_STATISTICS under trace flag 2388 for every statistic of the table inside a
      single session-level TRACEON/TRACEOFF pair (each pair writes two lines to the ERRORLOG).
      Session-level DBCC TRACEON requires sysadmin; without it the comparison is skipped.
    #>
    $res = @{ Rows = @{}; Error = $null }
    try { $null = Read-ResultSets $Connection 'DBCC TRACEON(2388) WITH NO_INFOMSGS' }
    catch { $res.Error = "DBCC TRACEON(2388) failed: $($_.Exception.Message)"; return $res }
    try {
        $sql = @'
DECLARE @cmd nvarchar(max) = N'DBCC SHOW_STATISTICS(' + QUOTENAME(@t, '''') + N', ' + QUOTENAME(@s) + N') WITH NO_INFOMSGS';
EXEC sys.sp_executesql @cmd;
'@
        foreach ($s in $StatNames) {
            try { $res.Rows[$s] = @((Read-ResultSets $Connection $sql @{ '@t' = $QualifiedTable; '@s' = $s })[0]) } catch { }
        }
    } finally {
        try { $null = Read-ResultSets $Connection 'DBCC TRACEOFF(2388) WITH NO_INFOMSGS' } catch { }
    }
    return $res
}

function Test-StatsAgainstServer($D, $Connection, [string]$QualifiedTable, [string]$StatName, $Tf2388) {
    $sql = @'
DECLARE @cmd nvarchar(max) = N'DBCC SHOW_STATISTICS(' + QUOTENAME(@t, '''') + N', ' + QUOTENAME(@s) + N') WITH STAT_HEADER, DENSITY_VECTOR, HISTOGRAM, NO_INFOMSGS';
EXEC sys.sp_executesql @cmd;
'@
    $sets = Read-ResultSets $Connection $sql @{ '@t' = $QualifiedTable; '@s' = $StatName }
    $checks = New-Object 'System.Collections.Generic.List[object]'
    function Add-Check([string]$Item, $Expected, $Actual, [bool]$Ok) {
        $checks.Add([pscustomobject]@{ Check = $Item; Server = [string]$Expected; Decoded = [string]$Actual; Result = $(if ($Ok) { 'OK' } else { 'MISMATCH' }) })
    }
    function Test-Float($a, $b) {
        if ($null -eq $a -or $a -is [DBNull]) { return $null -eq $b }
        $x = [double]$a; $y = [double]$b
        return [Math]::Abs($x - $y) -le [Math]::Max(1e-6, [Math]::Abs($x) * 1e-6)
    }
    $m = $D.Blob
    $hdr = @($sets[0])[0]
    if ($hdr -and $m -and -not ($hdr.Rows -is [DBNull])) {
        $stepsTotal = $m.Steps; if ($m.NullStepEqRows -gt 0) { $stepsTotal++ }
        Add-Check 'Header: Rows' $hdr.Rows $m.Rows ([int64]$hdr.Rows -eq $m.Rows)
        Add-Check 'Header: Rows Sampled' $hdr.'Rows Sampled' $m.RowsSampled ([int64]$hdr.'Rows Sampled' -eq $m.RowsSampled)
        Add-Check 'Header: Steps' $hdr.Steps $stepsTotal ([int]$hdr.Steps -eq $stepsTotal)
        Add-Check 'Header: Density' $hdr.Density (Format-Float $m.Density) (Test-Float $hdr.Density $m.Density)
        Add-Check 'Header: Average key length' $hdr.'Average key length' (Format-Float $m.AverageKeyLength) (Test-Float $hdr.'Average key length' $m.AverageKeyLength)
        $si = 'NO'; if ($D.StringIndex) { $si = 'YES' }
        Add-Check 'Header: String Index' $hdr.'String Index' $si (([string]$hdr.'String Index').Trim() -eq $si)
        $upd = $hdr.Updated
        if ($upd -is [datetime]) {
            Add-Check 'Header: Updated (minute)' $upd.ToString('yyyy-MM-dd HH:mm') $m.Updated.ToString('yyyy-MM-dd HH:mm') ($upd.ToString('yyyy-MM-dd HH:mm') -eq $m.Updated.ToString('yyyy-MM-dd HH:mm'))
        }
        if ($hdr.PSObject.Properties['Unfiltered Rows'] -and $null -ne $D.UnfilteredRows) {
            Add-Check 'Header: Unfiltered Rows' $hdr.'Unfiltered Rows' $D.UnfilteredRows ([int64]$hdr.'Unfiltered Rows' -eq $D.UnfilteredRows)
        }
        if ($hdr.PSObject.Properties['Persisted Sample Percent'] -and $null -ne $D.PersistedSamplePercent) {
            Add-Check 'Header: Persisted Sample Percent' $hdr.'Persisted Sample Percent' $D.PersistedSamplePercent (Test-Float $hdr.'Persisted Sample Percent' $D.PersistedSamplePercent)
        }
    }
    $dv = @($sets[1])
    for ($i = 0; $i -lt $dv.Count; $i++) {
        $dec = $D.DensityVector | Where-Object { $_.Vector -eq $i + 1 }
        $ok = $dec -and (Test-Float $dv[$i].'All density' $dec.AllDensity) -and (Test-Float $dv[$i].'Average Length' $dec.AverageLength)
        Add-Check "Density vector $($i + 1)" ([string]::Format($script:Inv, '{0} / {1}', $dv[$i].'All density', $dv[$i].'Average Length')) $(if ($dec) { '{0} / {1}' -f (Format-Float $dec.AllDensity), (Format-Float $dec.AverageLength) }) $ok
    }
    $hs = @($sets[2])
    $hd = @($D.Histogram)
    Add-Check 'Histogram: step count' $hs.Count $hd.Count ($hs.Count -eq $hd.Count)
    $bad = 0
    for ($i = 0; $i -lt [Math]::Min($hs.Count, $hd.Count); $i++) {
        # (PowerShell names are case-insensitive: keep step variables distinct from $D)
        $srvStep = $hs[$i]; $decStep = $hd[$i]
        $ks = Get-CanonicalValue $srvStep.RANGE_HI_KEY
        $kd = 'NULL'; if (-not $decStep.IsNullStep) { $kd = Get-CanonicalValue $decStep.RangeHiKey }
        # hierarchyid may come back from the server as bytes or as SqlHierarchyId
        if ($D.Columns[0].SystemTypeId -eq 240 -and -not $decStep.IsNullStep -and $ks.StartsWith('0x')) { $kd = Get-CanonicalValue $decStep.Record.KeyBytes }
        $ok = ($ks -eq $kd) -and (Test-Float $srvStep.RANGE_ROWS $decStep.RangeRows) -and (Test-Float $srvStep.EQ_ROWS $decStep.EqRows) -and
        (Test-Float $srvStep.AVG_RANGE_ROWS $decStep.AvgRangeRows) -and
        ([Math]::Abs([double]$srvStep.DISTINCT_RANGE_ROWS - [double]$decStep.DistinctRangeRows) -le [Math]::Max(0.5, [double]$srvStep.DISTINCT_RANGE_ROWS * 1e-5))
        if (-not $ok) {
            $bad++
            if ($bad -le 20) {
                Add-Check "Histogram step $($i + 1)" ([string]::Format($script:Inv, '{0} | {1} | {2} | {3} | {4}', $ks, $srvStep.RANGE_ROWS, $srvStep.EQ_ROWS, $srvStep.DISTINCT_RANGE_ROWS, $srvStep.AVG_RANGE_ROWS)) ([string]::Format($script:Inv, '{0} | {1} | {2} | {3} | {4}', $kd, $decStep.RangeRows, $decStep.EqRows, $decStep.DistinctRangeRows, $decStep.AvgRangeRows)) $false
            }
        }
    }
    Add-Check 'Histogram: all steps (key, RANGE_ROWS, EQ_ROWS, DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS)' "$($hs.Count) steps" "$bad mismatching" ($bad -eq 0)

    # ---- trace flag 2388 result set (fetched once per table by Get-TraceFlag2388FromServer)
    $tf = $null
    if ($null -eq $Tf2388) { }
    elseif ($Tf2388.Error) {
        $checks.Add([pscustomobject]@{ Check = 'Trace flag 2388 view'; Server = 'not run'; Decoded = $Tf2388.Error; Result = 'SKIPPED' })
    } elseif ($Tf2388.Rows.ContainsKey($StatName)) { $tf = @($Tf2388.Rows[$StatName]) }
    if ($null -ne $tf) {
        $mine = @($D.TraceFlag2388)
        Add-Check 'TF 2388: row count' $tf.Count $mine.Count ($tf.Count -eq $mine.Count)
        $tfBad = 0
        $num = 'Table Cardinality', 'Snapshot Ctr', 'Steps', 'Density', 'Rows Above', 'Rows Below', 'Squared Variance Error', 'Inserts Since Last Update', 'Deletes Since Last Update'
        for ($i = 0; $i -lt [Math]::Min($tf.Count, $mine.Count); $i++) {
            $srvRow = $tf[$i]; $decRow = $mine[$i]
            $diff = @()
            $su = $srvRow.Updated; $du = $decRow.Updated
            if ($su -is [DBNull] -or $null -eq $su) { if ($null -ne $du) { $diff += 'Updated' } }
            elseif ($su -is [datetime]) { if ((Get-CanonicalValue $su) -ne (Get-CanonicalValue $du)) { $diff += 'Updated' } }
            elseif ($null -eq $du -or ([datetime]::Parse([string]$su, $script:Inv)).ToString('yyyyMMddHHmm') -ne $du.ToString('yyyyMMddHHmm')) { $diff += 'Updated' }
            foreach ($c in $num) {
                $sv = $srvRow.$c; $dv = $decRow.$c
                if ($sv -is [DBNull]) { $sv = $null }
                if ($null -eq $sv -or $null -eq $dv) { if (($null -eq $sv) -ne ($null -eq $dv)) { $diff += $c } }
                elseif (-not (Test-Float $sv $dv)) { $diff += $c }
            }
            $sl = $srvRow.'Leading column Type'; if ($sl -is [DBNull]) { $sl = $null }
            if ([string]$sl -ne [string]$decRow.'Leading column Type') { $diff += 'Leading column Type' }
            if ($i -eq 0 -and $diff -contains 'Snapshot Ctr' -and $null -eq $D.CurrentSnapshotCtr) {
                # not stored in the stream; only exact with -UseDac
                $checks.Add([pscustomobject]@{ Check = 'TF 2388: row 1 Snapshot Ctr (estimate, not in stream)'; Server = (Get-CanonicalValue $srvRow.'Snapshot Ctr'); Decoded = (Get-CanonicalValue $decRow.'Snapshot Ctr'); Result = 'INFO' })
                $diff = @($diff | Where-Object { $_ -ne 'Snapshot Ctr' })
            }
            if ($diff.Count -gt 0) {
                $tfBad++
                if ($tfBad -le 10) {
                    $fmt = { param($r) ($diff | ForEach-Object { "$_=" + (Get-CanonicalValue $r.$_) }) -join '; ' }
                    Add-Check "TF 2388: row $($i + 1)" (& $fmt $srvRow) (& $fmt $decRow) $false
                }
            }
        }
        Add-Check 'TF 2388: all rows and columns' "$($tf.Count) rows" "$tfBad mismatching" ($tfBad -eq 0)
    }
    return , $checks.ToArray()
}

function Test-DataCheckKeyType($Column) {
    # Key types the data check binds as a parameter of the column's own type (not sql_variant or CLR types other than hierarchyid).
    if ($Column.SystemTypeId -eq 240) { return $Column.UserTypeId -eq 128 }
    return $Column.SystemTypeId -in 48, 52, 56, 127, 104, 59, 62, 60, 122, 106, 108, 40, 41, 42, 43, 61, 58, 36, 175, 167, 239, 231, 173, 165, 189
}

function Add-DataCheckKey($Command, [string]$Name, $Column, $Step) {
    <#
      Binds a histogram key as a parameter of the column's own type and returns the T-SQL expression that reads it.
      The comparison then runs in the column's type and collation, as the histogram was built: no conversion of the
      column (the seek stays a seek) and no round trip through a string.
    #>
    $v = $Step.RangeHiKey
    $p = $Command.Parameters.Add($Name, [Data.SqlDbType]::Int)
    $expr = $Name
    switch ($Column.SystemTypeId) {
        48 { $p.SqlDbType = 'TinyInt'; $p.Value = $v }
        52 { $p.SqlDbType = 'SmallInt'; $p.Value = $v }
        56 { $p.Value = $v }
        127 { $p.SqlDbType = 'BigInt'; $p.Value = $v }
        104 { $p.SqlDbType = 'Bit'; $p.Value = $v }
        59 { $p.SqlDbType = 'Real'; $p.Value = $v }
        62 { $p.SqlDbType = $(if ($v -is [single]) { 'Real' } else { 'Float' }); $p.Value = $v }
        60 { $p.SqlDbType = 'Money'; $p.Value = [decimal]::Parse($v, $script:Inv) }
        122 { $p.SqlDbType = 'SmallMoney'; $p.Value = [decimal]::Parse($v, $script:Inv) }
        { $_ -in 106, 108 } { $p.SqlDbType = 'Decimal'; $p.Precision = $Column.Precision; $p.Scale = $Column.Scale; $p.SqlValue = [Data.SqlTypes.SqlDecimal]::Parse($v) }
        40 { $p.SqlDbType = 'Date'; $p.Value = $v }
        41 { $p.SqlDbType = 'Time'; $p.Scale = $Column.Scale; $p.Value = $v }
        42 { $p.SqlDbType = 'DateTime2'; $p.Scale = $Column.Scale; $p.Value = $v }
        43 { $p.SqlDbType = 'DateTimeOffset'; $p.Scale = $Column.Scale; $p.Value = $v }
        61 {
            # from the stored days and 1/300 s ticks, so nothing is rounded on the way
            $k = $Step.Record.KeyBytes
            $p.SqlDbType = 'DateTime'; $p.SqlValue = [Data.SqlTypes.SqlDateTime]::new([BitConverter]::ToInt32($k, 4), [BitConverter]::ToInt32($k, 0))
        }
        58 { $p.SqlDbType = 'SmallDateTime'; $p.Value = $v }
        36 { $p.SqlDbType = 'UniqueIdentifier'; $p.Value = $v }
        { $_ -in 175, 167 } {
            # sent as Unicode and converted on the server in the column's collation, so in its code page
            $p.SqlDbType = 'NVarChar'; $p.Size = -1; $p.Value = $v
            $len = $(if ($Column.MaxLength -eq -1) { 'max' } else { [string]$Column.MaxLength })
            if ($Column.Collation -match '^\w+$') { $expr = "CAST($Name COLLATE $($Column.Collation) AS varchar($len))" } else { $expr = "CAST($Name AS varchar($len))" }
        }
        { $_ -in 239, 231 } { $p.SqlDbType = 'NVarChar'; $p.Size = $(if ($Column.MaxLength -eq -1) { -1 } else { [int]($Column.MaxLength / 2) }); $p.Value = $v }
        { $_ -in 173, 165, 189 } { $p.SqlDbType = 'VarBinary'; $p.Size = $(if ($Column.MaxLength -eq -1) { -1 } else { $Column.MaxLength }); $p.Value = [byte[]]$v }
        240 { $p.SqlDbType = 'VarBinary'; $p.Size = -1; $p.Value = [byte[]]$Step.Record.KeyBytes; $expr = "CAST($Name AS hierarchyid)" }
    }
    return $expr
}

function Invoke-DataCheckQuery($Ctx, $Lo, $Hi, [switch]$Nulls, [long]$Cap) {
    <#
      One seek on the chosen index for the range (Lo, Hi]. The rows arrive in key order, so GROUP BY is a stream
      aggregate: one pass gives EQ_ROWS (the group equal to Hi), RANGE_ROWS, DISTINCT_RANGE_ROWS and the largest
      group inside the range. TOP (@cap) bounds the rows a step can read; KEEPFIXED PLAN keeps the compile from
      triggering an automatic update of the statistics being checked.
    #>
    $cmd = $Ctx.Connection.CreateCommand()
    $cmd.CommandTimeout = $Ctx.Timeout
    $null = $cmd.Parameters.Add('@cap', [Data.SqlDbType]::BigInt)
    $cmd.Parameters['@cap'].Value = $Cap
    $col = $Ctx.ColumnSql
    $from = "$($Ctx.TableSql) AS t WITH (INDEX($($Ctx.IndexSql)), FORCESEEK)"
    if ($Nulls) {
        $cmd.CommandText = "SELECT COUNT_BIG(*) AS eq_rows, CAST(0 AS bigint) AS range_rows, 0 AS distinct_rows, CAST(0 AS bigint) AS max_value_rows, COUNT_BIG(*) AS rows_read " +
        "FROM (SELECT TOP (@cap) t.$col FROM $from WHERE t.$col IS NULL) AS x OPTION (KEEPFIXED PLAN, MAXDOP 1);"
    } else {
        $where = @(); $eq = '0'
        if ($Lo) { $where += "t.$col > " + (Add-DataCheckKey $cmd '@lo' $Ctx.Column $Lo) }
        if ($Hi) {
            $h = Add-DataCheckKey $cmd '@hi' $Ctx.Column $Hi
            $where += "t.$col <= $h"
            $eq = "CASE WHEN x.$col = $h THEN 1 ELSE 0 END"
        }
        $cmd.CommandText = @"
SELECT ISNULL(SUM(CASE WHEN g.k = 1 THEN g.c END), 0) AS eq_rows, ISNULL(SUM(CASE WHEN g.k = 0 THEN g.c END), 0) AS range_rows,
       COUNT(CASE WHEN g.k = 0 THEN 1 END) AS distinct_rows, ISNULL(MAX(CASE WHEN g.k = 0 THEN g.c END), 0) AS max_value_rows,
       ISNULL(SUM(g.c), 0) AS rows_read
FROM (SELECT $eq AS k, COUNT_BIG(*) AS c
      FROM (SELECT TOP (@cap) t.$col FROM $from WHERE $($where -join ' AND ') ORDER BY t.$col) AS x
      GROUP BY x.$col) AS g
OPTION (KEEPFIXED PLAN, MAXDOP 1);
"@
    }
    $r = $cmd.ExecuteReader()
    try {
        $null = $r.Read()
        return @{
            Eq = [int64]$r['eq_rows']; Range = [int64]$r['range_rows']; Distinct = [int64]$r['distinct_rows']
            MaxValue = [int64]$r['max_value_rows']; Read = [int64]$r['rows_read']; Truncated = $false
        }
    } finally { $r.Close() }
}

function Get-DataCheckQError($Stats, $Table) {
    # q-error: how many times the estimate is off, either way; both sides floored at 1 row, as estimates are.
    $e = [Math]::Max([double]$Stats, 1.0); $a = [Math]::Max([double]$Table, 1.0)
    return [Math]::Round([Math]::Max($e / $a, $a / $e), 2)
}

function Test-DataCheckExact($Stats, $Table) {
    # stored counts are real (float32): exact within its precision
    $s = [double]$Stats; $t = [double]$Table
    return [Math]::Abs($s - $t) -le [Math]::Max(0.5, $t * 1e-5)
}

function Format-Invariant([string]$Format) {
    return [string]::Format($script:Inv, $Format, [object[]]$args)
}

function New-DataCheckResult([string]$Reason) {
    $r = [pscustomobject]@{ Result = 'Skipped'; Summary = [ordered]@{}; Findings = New-Object 'System.Collections.Generic.List[string]'; Steps = New-Object 'System.Collections.Generic.List[object]' }
    if ($Reason) { $r.Summary['Result'] = 'Skipped'; $r.Summary['Reason'] = $Reason; $r.Findings.Add("Not checked: $Reason") }
    return $r
}

function Test-StatsAgainstData {
    <#
      Checks the histogram against the table data. The table is read only through a rowstore index whose first key
      is the statistics' leading column (the smallest one), with one seek per step, under READ UNCOMMITTED,
      LOCK_TIMEOUT 1000, MAXDOP 1 and KEEPFIXED PLAN, within a page budget. Above the budget it becomes a spot
      check: the NULL step, both ends of the histogram, then steps at random, as long as their estimated pages fit.
      Results carry step numbers and counts, not key values.
    #>
    param($D, $Connection, [int]$ObjectId, $Stat, [string]$QualifiedTable, [long]$PageBudget = 100000, [int]$TimeoutSeconds = 60, [int]$StepDelay = 0)
    $started = [DateTime]::Now
    $col = $D.Columns[0]
    $real = @($D.Histogram | Where-Object { -not $_.IsNullStep })
    $nullStep = @($D.Histogram | Where-Object { $_.IsNullStep }) | Select-Object -First 1
    $reason = $null
    if ($Stat.has_filter) { $reason = 'filtered statistics are not checked yet.' }
    elseif ($Stat.Table.Columns.Contains('is_incremental') -and $Stat.is_incremental -eq $true) { $reason = 'incremental statistics are not checked yet.' }
    elseif (-not $D.Blob -or ($real.Count -eq 0 -and -not $nullStep)) { $reason = 'the statistics have no histogram.' }
    elseif (-not (Test-DataCheckKeyType $col)) { $reason = "keys of type $($col.TypeName) are not supported by the data check." }
    if ($reason) { return New-DataCheckResult $reason }

    # the histogram column: an index's first key (key_ordinal 1, not stats_column_id 1, which follows index_column_id)
    $q = Invoke-Query $Connection @'
DECLARE @c int = (SELECT TOP (1) sc.column_id FROM sys.stats_columns sc
                  LEFT JOIN sys.index_columns ic ON ic.object_id = sc.object_id AND ic.index_id = sc.stats_id AND ic.column_id = sc.column_id AND ic.key_ordinal > 0
                  WHERE sc.object_id = @o AND sc.stats_id = @s ORDER BY COALESCE(ic.key_ordinal, sc.stats_column_id));
SELECT o.type, c.name AS column_name, c.is_nullable,
       CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.tables t WHERE t.object_id = o.object_id AND t.is_memory_optimized = 1) THEN 1 ELSE 0 END AS bit) AS memory_optimized
FROM sys.objects o
JOIN sys.columns c ON c.object_id = o.object_id AND c.column_id = @c
WHERE o.object_id = @o;
SELECT TOP (1) i.name, i.type_desc, SUM(p.rows) AS rows, SUM(au.data_pages) AS pages
FROM sys.index_columns ic
JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
JOIN sys.partitions p ON p.object_id = i.object_id AND p.index_id = i.index_id
JOIN sys.allocation_units au ON au.container_id = p.partition_id AND au.type = 1
WHERE ic.object_id = @o AND ic.column_id = @c AND ic.key_ordinal = 1
  AND i.type IN (1, 2) AND i.is_disabled = 0 AND i.is_hypothetical = 0 AND i.has_filter = 0
GROUP BY i.index_id, i.name, i.type_desc
ORDER BY SUM(au.data_pages), i.index_id;
'@ @{ '@o' = $ObjectId; '@s' = [int]$Stat.stats_id }
    $meta = @($q[0].Rows)[0]
    $ix = @($q[1].Rows)[0]
    if (-not $meta) { $reason = 'the leading column of the statistics was not found.' }
    elseif (([string]$meta.type).Trim() -ne 'U') { $reason = 'only tables are checked (not indexed views).' }
    elseif ($meta.memory_optimized) { $reason = 'memory-optimized tables are not checked (they do not support READ UNCOMMITTED).' }
    elseif (-not $ix) { $reason = "no enabled, unfiltered rowstore index has [$($meta.column_name)] as its first key column; the check only reads through such an index." }
    if ($reason) { return New-DataCheckResult $reason }

    $result = New-DataCheckResult
    $summary = $result.Summary; $findings = $result.Findings
    $indexRows = [double]$ix.rows; $indexPages = [double]$ix.pages
    $rowsPerPage = [Math]::Max(1.0, $indexRows / [Math]::Max(1.0, $indexPages))
    $full = $indexPages -le $PageBudget
    $quote = { param([string]$Name) '[' + $Name.Replace(']', ']]') + ']' }
    $ctx = @{
        Connection = $Connection; Timeout = $TimeoutSeconds; Column = $col; TableSql = $QualifiedTable
        ColumnSql = (& $quote ([string]$meta.column_name)); IndexSql = (& $quote ([string]$ix.name))
    }

    # ranges to count: the NULL rows, every step (previous key, key], and the rows above the last key
    $work = New-Object 'System.Collections.Generic.List[object]'
    if ($meta.is_nullable) {
        $work.Add(@{ Kind = 'NULL step'; Step = $(if ($nullStep) { $nullStep.Step }); Nulls = $true
                Eq = $(if ($nullStep) { $nullStep.EqRows } else { [single]0 }); Range = [single]0; Distinct = [single]0; Avg = $null })
    }
    for ($i = 0; $i -lt $real.Count; $i++) {
        $s = $real[$i]
        $work.Add(@{ Kind = 'Step'; Step = $s.Step; Lo = $(if ($i -gt 0) { $real[$i - 1] }); Hi = $s; Eq = $s.EqRows; Range = $s.RangeRows; Distinct = $s.DistinctRangeRows; Avg = $s.AvgRangeRows })
    }
    if ($real.Count -gt 0) { $work.Add(@{ Kind = 'Above last step'; Step = $null; Lo = $real[$real.Count - 1]; Eq = [single]0; Range = [single]0; Distinct = [single]0; Avg = $null }) }

    $order = @(0..($work.Count - 1))
    if (-not $full) {
        # spot check: NULL rows and both ends first (where ascending and descending keys show), then steps at random
        $stepIdx = @($order | Where-Object { $work[$_].Kind -eq 'Step' })
        $first = @($order | Where-Object { $work[$_].Kind -ne 'Step' })
        if ($stepIdx.Count -gt 0) { $first += $stepIdx[$stepIdx.Count - 1]; if ($stepIdx.Count -gt 1) { $first += $stepIdx[0] } }
        $rng = New-Object Random ([int]$Stat.stats_id)
        $order = $first + @($stepIdx | Where-Object { $_ -notin $first } | Sort-Object { $rng.Next() })
    }

    $outcome = @{}
    $spent = 0.0; $errors = 0; $lastError = $null
    $session = $Connection.CreateCommand()
    $session.CommandText = 'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED; SET LOCK_TIMEOUT 1000;'
    $null = $session.ExecuteNonQuery()
    try {
        foreach ($i in $order) {
            $w = $work[$i]
            $remaining = $PageBudget - $spent
            $cost = ([double]$w.Eq + [double]$w.Range) / $rowsPerPage
            if ($errors -ge 3 -or $remaining -le 0 -or (-not $full -and $cost -gt $remaining)) { continue }
            $cap = [int64][Math]::Max(1, [Math]::Floor($remaining * $rowsPerPage))
            try {
                $c = Invoke-DataCheckQuery $ctx $w.Lo $w.Hi -Nulls:([bool]$w.Nulls) -Cap $cap
                $c.Truncated = $c.Read -ge $cap
                $outcome[$i] = $c
                $spent += $c.Read / $rowsPerPage
                $errors = 0
            } catch {
                $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
                $errors++; $lastError = $e.Message; $outcome[$i] = @{ Error = $e.Message }
            }
            if ($StepDelay -gt 0) { Start-Sleep -Milliseconds $StepDelay }
        }
    } finally {
        $session.CommandText = 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SET LOCK_TIMEOUT -1;'
        try { $null = $session.ExecuteNonQuery() } catch { }
    }
    $updatedDuring = $false
    try {
        $after = (Invoke-Query $Connection 'SELECT last_updated FROM sys.dm_db_stats_properties(@o, @s)' @{ '@o' = $ObjectId; '@s' = [int]$Stat.stats_id })[0].Rows[0].last_updated
        $updatedDuring = $after -is [datetime] -and $Stat.sp_last_updated -is [datetime] -and $after -ne $Stat.sp_last_updated
    } catch { }

    # ---- per range results
    $statsRows = [double]$D.Blob.Rows
    $minRows = [Math]::Max(10.0, $statsRows * 0.001)
    $fullscan = $D.Blob.RowsSampled -ge $D.Blob.Rows
    $mods = $Stat.sp_modification_counter
    if ($mods -is [DBNull]) { $mods = $null }
    $expectExact = $fullscan -and $null -ne $mods -and $mods -eq 0
    $label = { param($Row) if ($Row.Kind -eq 'Step') { "step $($Row.Step)" } elseif ($Row.Kind -eq 'NULL step') { 'the NULL step' } else { 'the range above the last step' } }
    $worst = @{ Eq = $null; Range = $null; Distinct = $null }
    $rated = $null; $skew = @(); $tableTotal = [int64]0
    for ($i = 0; $i -lt $work.Count; $i++) {
        $w = $work[$i]; $o = $outcome[$i]
        $row = [pscustomobject][ordered]@{
            Step = $w.Step; Kind = $w.Kind; Result = ''; StatsEqRows = $w.Eq; TableEqRows = $null; EqQError = $null
            StatsRangeRows = $w.Range; TableRangeRows = $null; RangeQError = $null; StatsDistinct = $w.Distinct; TableDistinct = $null; DistinctQError = $null
            AvgRangeRows = $w.Avg; MaxRowsPerValue = $null; Note = ''
        }
        if (-not $o) { $row.Result = 'Not checked'; $row.Note = $(if ($errors -ge 3) { 'stopped after repeated errors' } else { 'outside the page budget' }) }
        elseif ($o.Error) { $row.Result = 'Error'; $row.Note = $o.Error }
        else {
            $row.TableEqRows = $o.Eq; $row.TableRangeRows = $o.Range; $row.TableDistinct = $o.Distinct
            $row.EqQError = Get-DataCheckQError $w.Eq $o.Eq
            $row.RangeQError = Get-DataCheckQError $w.Range $o.Range
            $row.DistinctQError = Get-DataCheckQError $w.Distinct $o.Distinct
            if ($w.Kind -eq 'Step') { $row.MaxRowsPerValue = $o.MaxValue }
            $tableTotal += $o.Eq + $o.Range
            $qe = [Math]::Max($row.EqQError, $row.RangeQError)
            if ($o.Truncated) { $row.Result = 'Partial'; $row.Note = 'stopped at the page budget: the table counts are lower bounds' }
            elseif ((Test-DataCheckExact $w.Eq $o.Eq) -and (Test-DataCheckExact $w.Range $o.Range) -and (Test-DataCheckExact $w.Distinct $o.Distinct)) { $row.Result = 'Exact' }
            elseif ($qe -le 2) { $row.Result = 'Good' } elseif ($qe -le 10) { $row.Result = 'Fair' } else { $row.Result = 'Poor' }
            if ($w.Kind -eq 'Step' -and $o.MaxValue -ge 10 -and $o.MaxValue -ge 10 * [Math]::Max(1.0, [double]$w.Avg)) {
                $row.Note = Format-Invariant 'a value inside the step has {0:N0} rows; AVG_RANGE_ROWS is {1}' $o.MaxValue (Format-Float $w.Avg)
                $skew += $row
            }
            if (-not $o.Truncated) {
                foreach ($k in 'Eq', 'Range', 'Distinct') {
                    if ($null -eq $worst[$k] -or $row."$($k)QError" -gt $worst[$k]."$($k)QError") { $worst[$k] = $row }
                }
                $big = [Math]::Max([double]$w.Eq + [double]$w.Range, [double]($o.Eq + $o.Range))
                if ($big -ge $minRows -and ($null -eq $rated -or $qe -gt $rated)) { $rated = $qe }
            }
        }
        $result.Steps.Add($row)
    }

    # ---- summary
    $rows = $result.Steps.ToArray()
    $count ={ param([string]$R) @($rows | Where-Object { $_.Result -eq $R }).Count }
    $checked = @($rows | Where-Object { $_.Result -in 'Exact', 'Good', 'Fair', 'Poor', 'Partial' })
    $notChecked = & $count 'Not checked'
    $partial = & $count 'Partial'
    $failed = & $count 'Error'
    $differ = @($checked | Where-Object { $_.Result -ne 'Exact' }).Count
    if ($checked.Count -eq 0) { $result.Result = 'Not checked' }
    elseif ($expectExact) { $result.Result = $(if ($differ -eq 0) { 'Exact match' } else { 'Differs' }) }
    elseif ($null -eq $rated -or $rated -le 2) { $result.Result = 'Good' } elseif ($rated -le 10) { $result.Result = 'Fair' } else { $result.Result = 'Poor' }

    $summary['Result'] = $result.Result
    $summary['Index read'] = Format-Invariant '{0} ({1}): {2:N0} leaf pages, {3:N0} rows' $ix.name $ix.type_desc $indexPages $indexRows
    $summary['Coverage'] = $(if ($notChecked + $failed -eq 0) { "every range: $($real.Count) steps" + $(if ($meta.is_nullable) { ', NULL rows' } else { '' }) + ' and rows above the last step' }
        else { Format-Invariant "spot check: $($rows.Count - $notChecked - $failed) of $($rows.Count) ranges (page budget {0:N0} pages)" $PageBudget })
    $summary['Pages read (estimated)'] = Format-Invariant '{0:N0}' ([Math]::Ceiling($spent))
    $summary['Duration'] = Format-Invariant '{0:0.0} s' ([DateTime]::Now - $started).TotalSeconds
    $summary['Sample'] = $(if ($fullscan) { Format-Invariant 'FULLSCAN ({0:N0} rows)' $D.Blob.Rows } else { Format-Invariant '{0:0.##}% ({1:N0} of {2:N0} rows)' (100.0 * $D.Blob.RowsSampled / [Math]::Max(1, $D.Blob.Rows)) $D.Blob.RowsSampled $D.Blob.Rows })
    $modPct = $(if ($null -ne $mods -and $statsRows -gt 0) { 100.0 * $mods / $statsRows } else { $null })
    $summary['Modifications since the update'] = $(if ($null -eq $mods) { 'unknown' } else { Format-Invariant '{0:N0} ({1:0.##}% of the rows)' $mods $modPct })
    if ($notChecked + $failed + $partial -eq 0) { $summary['Rows in the table now'] = Format-Invariant '{0:N0} (statistics: {1:N0})' $tableTotal $D.Blob.Rows }
    $above = $rows | Where-Object { $_.Kind -eq 'Above last step' -and $null -ne $_.TableRangeRows }
    if ($above) { $summary['Rows above the last step'] = Format-Invariant '{0:N0} (leading column type: {1})' $above.TableRangeRows $D.LeadingColumnType }
    foreach ($k in @(@('Eq', 'EQ_ROWS', 'StatsEqRows', 'TableEqRows'), @('Range', 'RANGE_ROWS', 'StatsRangeRows', 'TableRangeRows'), @('Distinct', 'DISTINCT_RANGE_ROWS', 'StatsDistinct', 'TableDistinct'))) {
        $r = $worst[$k[0]]
        if ($r) { $summary["Worst $($k[1]) q-error"] = Format-Invariant '{0} at {1} (statistics {2}, table {3:N0})' $r."$($k[0])QError" (& $label $r) (Format-Float $r.($k[2])) $r.($k[3]) }
    }
    $summary['Ranges by result'] = (@('Exact', 'Good', 'Fair', 'Poor', 'Partial', 'Error', 'Not checked') | ForEach-Object { $n = & $count $_; if ($n) { "$_ $n" } }) -join ', '
    $summary['Steps hiding a frequent value'] = $skew.Count
    if ($updatedDuring) { $summary['Statistics updated during the check'] = 'yes' }

    # ---- findings
    $pctText = $(if ($null -ne $modPct) { Format-Invariant '{0:0.##}%' $modPct } else { '' })
    if ($checked.Count -gt 0) {
        if ($expectExact) {
            if ($differ -eq 0) { $findings.Add('FULLSCAN statistics with no modifications since the update: every range read matches the table exactly.') }
            else {
                $text = "These are FULLSCAN statistics with no modifications since the update, so every range should match the table exactly, but $differ range(s) do not. " +
                'The statistics were probably loaded with UPDATE STATISTICS ... WITH STATS_STREAM, or rows changed while the check ran (it reads under READ UNCOMMITTED).'
                if ($Stat.no_recompute -eq $true) { $text += ' NORECOMPUTE is on, as it often is for statistics loaded from an edited stream.' }
                $findings.Add($text)
            }
        } elseif ($null -eq $mods) {
            $findings.Add('The modification counter is not available, so differences can be sampling error or data changes.')
        } elseif ($mods -eq 0) {
            $findings.Add("No rows changed since the update: the differences are sampling error, from a sample of $($summary['Sample']).")
            if ($result.Result -in 'Fair', 'Poor') {
                $advice = 'A higher sample rate (UPDATE STATISTICS ... WITH SAMPLE n PERCENT, or FULLSCAN) brings the histogram closer to the data'
                if ($D.PersistedSamplePercent) { $advice += (Format-Invariant '; the persisted sample percent is {0:0.##}%, raise it' $D.PersistedSamplePercent) }
                else { $advice += '; add PERSIST_SAMPLE_PERCENT = ON so automatic updates keep that rate' }
                $findings.Add("$advice.")
            } else { $findings.Add('The sample rate is enough for this histogram.') }
        } elseif ($fullscan) {
            $findings.Add((Format-Invariant "FULLSCAN statistics are exact when built, so the differences come from the {0:N0} modifications since the update ($pctText of the rows), not from sampling." $mods))
        } else {
            $findings.Add((Format-Invariant "The differences mix sampling error and {0:N0} modifications since the update ($pctText of the rows). Update the statistics and check again to tell them apart." $mods))
        }
    }
    # rows outside the histogram's ends: new keys after the update (ascending/descending key), or keys the sample missed
    $changed = $null -eq $mods -or $mods -gt 0
    if ($above -and $above.TableRangeRows -gt 0) {
        if ($changed) { $findings.Add((Format-Invariant '{0:N0} rows are above the last step, where the histogram has no data (ascending key). Leading column type: {1}.' $above.TableRangeRows $D.LeadingColumnType)) }
        else { $findings.Add((Format-Invariant '{0:N0} rows are above the last step: keys the sample missed, as no rows changed since the update.' $above.TableRangeRows)) }
    }
    $firstStep = $rows | Where-Object { $_.Kind -eq 'Step' } | Select-Object -First 1
    if ($firstStep -and $null -ne $firstStep.TableRangeRows -and $firstStep.StatsRangeRows -eq 0 -and $firstStep.TableRangeRows -gt 0) {
        if ($changed) { $findings.Add((Format-Invariant '{0:N0} rows are below the first step''s key, where the histogram has none (descending key).' $firstStep.TableRangeRows)) }
        else { $findings.Add((Format-Invariant '{0:N0} rows are below the first step''s key: keys the sample missed, as no rows changed since the update.' $firstStep.TableRangeRows)) }
    }
    if ($skew.Count -gt 0) {
        $top = $skew | Sort-Object { $_.MaxRowsPerValue / [Math]::Max(1.0, [double]$_.AvgRangeRows) } -Descending | Select-Object -First 1
        $findings.Add((Format-Invariant ('{0} step(s) hide a value with at least 10 times AVG_RANGE_ROWS (largest: {1:N0} rows at step {2}, AVG_RANGE_ROWS {3}). ' +
                    'Equality predicates on such a value are estimated at AVG_RANGE_ROWS.') $skew.Count $top.MaxRowsPerValue $top.Step (Format-Float $top.AvgRangeRows)))
    }
    if ($partial -gt 0) { $findings.Add("$partial range(s) stopped at the page budget; their table counts are lower bounds.") }
    if ($notChecked -gt 0 -and $errors -lt 3) {
        $findings.Add((Format-Invariant '{0} range(s) were not read: the index has {1:N0} leaf pages and the page budget is {2:N0}. Raise the budget to check every step.' $notChecked $indexPages $PageBudget))
    }
    if ($failed -gt 0) { $findings.Add("$failed range(s) failed: $lastError") }
    if ($updatedDuring) { $findings.Add('The statistics were updated by another session while the check ran; the comparison uses the stream read before the check.') }
    return $result
}

#endregion

#region ---------------------------------------------------------------- statistics builder

# The numeric core of the builder (reading the column's values, the histogram algorithms and the scorer) is C#: the
# loops run over every distinct value, which PowerShell would take minutes to do on large columns.
$script:BuilderCode = @'
using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlTypes;

namespace SQLStatsXRay.Builder {
 // One profile entry: an exact value, or a run of neighbouring light values merged to bound memory.
 // Key and Raw are the entry's last value; Rows, Distinct, SumSq, Units and Ones cover every value in it.
 // Units are the sampling units the value was seen in (pages for a page sample, rows otherwise); Ones are the values
 // seen in a single unit. Counting pages, not rows, keeps values repeated within a page from looking common.
 public sealed class Entry {
  public object Key, Raw;
  public double Rows, LastRows, Distinct, SumSq, Units, Ones, Bytes;
 }

 // A histogram step as the optimizer reads it.
 public sealed class Step {
  public object Key, Raw;
  public double Eq, Range, Distinct, Avg;
 }

 public sealed class Score {
  public double EqMax, EqP95, EqGeoMean, EqP95ByRows, RangeMax, RangeP95, RangeGeoMean, ValuesOver10, ValuesAbove, Values;
  public double WorkloadP95 = double.NaN, WorkloadGeoMean = double.NaN, WorkloadMax = double.NaN;
 }

 // Predicates on the column, read from Query Store plans: equality values and ranges (null = open end), with weights.
 public sealed class Workload {
  public List<object> EqValues = new List<object>();
  public List<double> EqWeights = new List<double>();
  public List<object> Lo = new List<object>(), Hi = new List<object>();
  public List<bool> LoInclusive = new List<bool>(), HiInclusive = new List<bool>();
  public List<double> RangeWeights = new List<double>();
  public void AddEquality(object v, double w) { EqValues.Add(v); EqWeights.Add(w); }
  public void AddRange(object lo, bool loIncl, object hi, bool hiIncl, double w) { Lo.Add(lo); LoInclusive.Add(loIncl); Hi.Add(hi); HiInclusive.Add(hiIncl); RangeWeights.Add(w); }
  public int Count { get { return EqValues.Count + Lo.Count; } }
 }

 // What a pilot sample says about the table: rows per page and how much the column's values cluster by page
 // (intraclass correlation of value ranks; design effect = how many sampled rows are worth one random row).
 public sealed class PilotStats {
  public double Pages, Rows, Nulls, RowsPerPage, Icc, DesignEffect = 1, Distinct;
 }

 public sealed class Profile {
  public List<Entry> Entries = new List<Entry>();
  public double NullRows, ReadRows, NonNullRows;
  public int MaxEntries = 100000;
  public bool Compacted;
  // Text columns: SQL Server's collation decides the order, so keys are the values' positions in the server's order
  // (the rows arrive sorted); values from elsewhere get a position from the server too. TextEncoding counts their bytes.
  public bool TextKeys;
  public System.Text.Encoding TextEncoding;
  // the string index, fed with the rows as they arrive (in collation order, before light values are merged)
  public TrieBuilder Trie;
  double mergeLimit, seq;

  // Values in SQL Server's order: SqlDecimal, SqlGuid and SqlBinary compare as SQL Server does.
  public static object Sortable(object v) {
   if (v == null || v is DBNull) return null;
   if (v is byte || v is short || v is int || v is long) return Convert.ToInt64(v);
   if (v is bool) return (bool)v ? 1L : 0L;
   if (v is float || v is double) return Convert.ToDouble(v);
   if (v is decimal) return new SqlDecimal((decimal)v);
   if (v is SqlMoney) return ((SqlMoney)v).ToSqlDecimal();
   if (v is SqlDecimal || v is SqlGuid || v is SqlBinary) return v;
   if (v is string) return SqlDecimal.Parse((string)v);
   if (v is DateTime || v is DateTimeOffset || v is TimeSpan) return v;
   if (v is Guid) return new SqlGuid((Guid)v);
   if (v is byte[]) return new SqlBinary((byte[])v);
   throw new NotSupportedException("Keys of type " + v.GetType().Name + " are not supported by the builder.");
  }
  public static int Compare(object a, object b) { return ((IComparable)a).CompareTo(b); }

  // Reads (value, rows[, pages]) in key order, the NULL group included.
  public void Read(IDataReader r) {
   bool pages = r.FieldCount > 2;
   while (r.Read()) {
    double n = Convert.ToDouble(r.GetValue(1));
    ReadRows += n;
    if (r.IsDBNull(0)) { NullRows += n; if (Trie != null) Trie.AddNulls(n); continue; }
    object raw;
    try { raw = r.GetValue(0); }
    catch (OverflowException) { raw = r.GetType().GetMethod("GetSqlValue", new[] { typeof(int) }).Invoke(r, new object[] { 0 }); }
    if (Trie != null) Trie.AddValue(raw, n);
    Add(raw, n, pages ? Convert.ToDouble(r.GetValue(2)) : n);
   }
  }

  public void Add(object raw, double n, double units) {
   var e = new Entry();
   e.Key = TextKeys ? (object)(seq++) : Sortable(raw); e.Raw = raw; e.Rows = n; e.LastRows = n; e.Distinct = 1; e.SumSq = n * n; e.Units = units; e.Ones = units == 1 ? 1 : 0;
   byte[] b = raw as byte[]; string s = raw as string;
   e.Bytes = b != null ? b.Length * n : (s != null && TextEncoding != null ? TextEncoding.GetByteCount(s) * n : 0);
   Entries.Add(e);
   NonNullRows += n;
   if (Entries.Count >= 2 * MaxEntries) Compact();
  }

  // Merges neighbouring light entries until about MaxEntries remain. The first entry (the minimum, which must be a
  // step key of its own) and values with many rows stay exact.
  void Compact() {
   if (mergeLimit <= 0) mergeLimit = NonNullRows / MaxEntries;
   while (Entries.Count > MaxEntries * 3 / 2) {
    var kept = new List<Entry>(Entries.Count);
    kept.Add(Entries[0]);
    int i = 1;
    while (i < Entries.Count) {
     Entry a = Entries[i];
     if (i + 1 < Entries.Count - 1 && a.Rows + Entries[i + 1].Rows <= mergeLimit) {
      Entry b = Entries[i + 1];
      var m = new Entry();
      m.Key = b.Key; m.Raw = b.Raw; m.LastRows = b.LastRows; m.Rows = a.Rows + b.Rows; m.Distinct = a.Distinct + b.Distinct;
      m.SumSq = a.SumSq + b.SumSq; m.Units = a.Units + b.Units; m.Ones = a.Ones + b.Ones; m.Bytes = a.Bytes + b.Bytes;
      kept.Add(m); i += 2; Compacted = true;
     } else { kept.Add(a); i++; }
    }
    bool progress = kept.Count < Entries.Count;
    Entries = kept;
    if (!progress || Entries.Count > MaxEntries * 3 / 2) mergeLimit *= 2;
   }
  }

  public double DistinctValues() { double d = 0; foreach (var e in Entries) d += e.Distinct; return d; }
  public double ValuesSeenOnce() { double d = 0; foreach (var e in Entries) d += e.Ones; return d; }
  public double SampleUnits() { double d = 0; foreach (var e in Entries) d += e.Units; return d; }
  public double DataBytes() { double d = 0; foreach (var e in Entries) d += e.Bytes; return d; }

  // Last entry whose key is below the value (or equal, when orEqual); -1 when none.
  public int IndexBelow(object key, bool orEqual) {
   int lo = 0, hi = Entries.Count - 1, found = -1;
   while (lo <= hi) {
    int mid = (lo + hi) / 2, c = Compare(Entries[mid].Key, key);
    if (c < 0 || (orEqual && c == 0)) { found = mid; lo = mid + 1; } else hi = mid - 1;
   }
   return found;
  }
  public int IndexOf(object key) { int i = IndexBelow(key, true); return i >= 0 && Compare(Entries[i].Key, key) == 0 ? i : -1; }

  // An exactly counted value at its place in the order (the true minimum or maximum, a workload value): inserted when
  // the sample missed it, its count corrected when the sample saw it. Rows are in sample units (exact / scale).
  public void InsertExact(object raw, double rows) { InsertExact(raw, Sortable(raw), rows); }
  public void InsertExact(object raw, object key, double rows) {
   int i = IndexBelow(key, true);
   if (i >= 0 && Compare(Entries[i].Key, key) == 0) {
    var x = Entries[i];
    if (x.Distinct == 1) { NonNullRows += rows - x.Rows; x.Rows = rows; x.LastRows = rows; x.SumSq = rows * rows; }
    return;
   }
   var e = new Entry();
   e.Key = key; e.Raw = raw; e.Rows = rows; e.LastRows = rows; e.Distinct = 1; e.SumSq = rows * rows; e.Units = 1; e.Ones = 1;
   Entries.Insert(i + 1, e);
   NonNullRows += rows;
  }
 }

 sealed class KeyComparer : IComparer<object> { public int Compare(object a, object b) { return Profile.Compare(a, b); } }

 public sealed class TrieNode { public int Off, Len; public double Count; public TrieNode Child, Sibling; }

 // The string index (trie) SQL Server keeps for LIKE estimates, built the way CTrieOnDisk builds it (SQL Server 2025,
 // reverse engineered; see STATS_STREAM-format.md): every row in collation order, a deterministic acceptance rate,
 // radix insertion comparing one character at a time in the column's collation (Rank: equal characters share a rank),
 // segments reusing the leftmost exact match in the character buffer, and the 0x50000 cost budget with its rebuild.
 public sealed class TrieBuilder {
  public bool EightBit; public int[] Rank; public System.Text.Encoding Encoding;
  public double Nulls, Count, Distinct, Cost = 0x30;
  public TrieNode Root = new TrieNode();
  public int Nodes = 1;
  char[] buf = new char[4096]; public int BufLen;
  double ax = 1, ay = 1, acc;                  // acceptance: x rows out of every y, evenly spaced
  TrieNode last;
  char[] sample = new char[80]; int sampleLen; object sampleSrc;
  const double Limit = 0x50000;

  public TrieBuilder(bool eightBit, int[] rank, System.Text.Encoding encoding) { EightBit = eightBit; Rank = rank; Encoding = encoding; SetAcceptance(1, 1); }
  public void SetAcceptance(double x, double y) { ax = x; ay = y; acc = y - x; }

  // InitialiseStringAcceptanceRate(R, 20): R is the estimated number of rows the statistics read.
  public void Initialise(double r) {
   if (r == 0 || r == -1) { SetAcceptance(1, 20); return; }
   double x = Math.Min(EightBit ? 2824 : 2409, (double)((uint)((ulong)(long)r & 0xFFFFFFFF) / 20u) + 10);
   SetAcceptance(Math.Min(x, r), r);
  }

  bool Accept() { acc += ax; if (acc >= ay) { acc -= ay; return true; } return false; }

  public void AddNulls(double n) { for (double k = 0; k < n; k++) { if (Accept()) { if (Nulls == 0) Distinct++; Count++; Nulls++; } last = null; } }

  // n rows of one value (rows equal under the collation arrive together, the first one not "same")
  public void AddValue(object raw, double n) {
   string s = raw as string;
   if (s == null) return;
   char[] u;
   if (EightBit) { var b = Encoding.GetBytes(s); u = new char[b.Length]; for (int k = 0; k < b.Length; k++) u[k] = (char)b[k]; }
   else u = s.ToCharArray();
   for (double k = 0; k < n; k++) InsertString(u, u.Length, k > 0);
  }

  void SampleString(char[] s, int n) {
   if (ReferenceEquals(s, sampleSrc) && s != sample) return;    // the same value's rows: already copied
   if (n > 80) { Array.Copy(s, 0, sample, 0, 40); Array.Copy(s, n - 40, sample, 40, 40); sampleLen = 80; }
   else { Array.Copy(s, 0, sample, 0, n); sampleLen = n; }
   sampleSrc = s;
  }

  void InsertString(char[] s, int n, bool same) {
   if (!Accept()) { SampleString(s, n); last = null; return; }
   if (same && last != null) { last.Count++; Count++; return; }
   if (!same) SampleString(s, n);
   // (a duplicate after a rejected row inserts the previous row's bytes: the sample buffer)
   var t = new char[sampleLen]; Array.Copy(sample, t, sampleLen);
   if (InsertSuffix(Root, t, 0, t.Length)) { Count++; return; }
   Rebuild(t, t.Length);
  }

  bool Need(double cost) { if (Cost + cost >= Limit) return false; Cost += cost; return true; }

  bool InsertSuffix(TrieNode node, char[] s, int i, int n) {
   while (true) {
    int rem = n - i;
    if (rem == 0) { if (node.Count == 0) Distinct++; node.Count++; last = node; return true; }
    int m; TrieNode after;
    TrieNode c = FindChild(node, s, i, n, out m, out after);
    if (m == 0) { bool ok = AddNewChild(node, after, s, i, n); Distinct++; return ok; }
    if (m == rem) {
     if (c.Len == m) { if (c.Count == 0) Distinct++; c.Count++; last = c; return true; }
     if (!Need(0x30)) return false;
     Split(c, m, 1); Distinct++; last = c; return true;
    }
    if (m < c.Len) { if (!Need(0x30)) return false; Split(c, m, 0); }
    node = c; i += m;
   }
  }

  void Split(TrieNode c, int m, double count) {
   var t = new TrieNode(); t.Off = c.Off + m; t.Len = c.Len - m; t.Count = c.Count; t.Child = c.Child;
   c.Len = m; c.Child = t; c.Count = count; Nodes++;
  }

  // The child sharing a first character with s[i..], and how many characters match; or where a new child goes.
  TrieNode FindChild(TrieNode node, char[] s, int i, int n, out int m, out TrieNode after) {
   after = null; m = 0;
   for (var c = node.Child; c != null; c = c.Sibling) {
    int k = 0;
    while (k < c.Len && i + k < n && Rank[buf[c.Off + k]] == Rank[s[i + k]]) k++;
    if (k > 0) { m = k; return c; }
    if (Rank[s[i]] < Rank[buf[c.Off]]) return null;
    after = c;
   }
   return null;
  }

  bool AddNewChild(TrieNode parent, TrieNode after, char[] s, int i, int n) {
   int len = n - i, off = Find(s, i, len);
   if (off < 0) {
    if (!Need(EightBit ? len : 2 * len)) return false;
    if (BufLen + len > buf.Length) Array.Resize(ref buf, Math.Max(buf.Length * 2, BufLen + len));
    Array.Copy(s, i, buf, BufLen, len); off = BufLen; BufLen += len;
   }
   if (!Need(0x30)) return false;
   var nd = new TrieNode(); nd.Off = off; nd.Len = len; nd.Count = 1; Nodes++;
   if (after == null) { nd.Sibling = parent.Child; parent.Child = nd; } else { nd.Sibling = after.Sibling; after.Sibling = nd; }
   last = nd;
   return true;
  }

  // the leftmost exact occurrence of the segment in the buffer (a binary match), or -1
  int Find(char[] s, int i, int len) {
   for (int p = 0; p + len <= BufLen; p++) {
    if (buf[p] != s[i]) continue;
    int k = 1; while (k < len && buf[p + k] == s[i + k]) k++;
    if (k == len) return p;
   }
   return -1;
  }

  // Over budget: every string so far is sampled again into a new trie at distinct / (2 x count), and later rows are
  // accepted half as often (or less).
  void Rebuild(char[] t, int tn) {
   var nw = new TrieBuilder(EightBit, Rank, Encoding);
   nw.SetAcceptance(Distinct, 2 * Count);
   for (double k = 0; k < Nulls; k++) nw.AddNulls(1);
   InsertRecursively(Root, new char[0], nw);
   // the string that overflowed goes in last, its character count passed where bytes are expected: n-types keep only
   // the first half (SQL Server's behaviour, kept so the trie matches)
   int len = EightBit ? tn : tn / 2;
   var h = new char[len]; Array.Copy(t, h, len);
   nw.InsertString(h, len, false);
   buf = nw.buf; BufLen = nw.BufLen; Root = nw.Root; Nodes = nw.Nodes; Nulls = nw.Nulls; Count = nw.Count; Distinct = nw.Distinct; Cost = nw.Cost;
   last = null;
   ay *= Math.Floor(2 * Count / Distinct);
  }

  void InsertRecursively(TrieNode node, char[] prefix, TrieBuilder nw) {
   var s = new char[prefix.Length + node.Len];
   Array.Copy(prefix, s, prefix.Length); Array.Copy(buf, node.Off, s, prefix.Length, node.Len);
   bool same = false;
   for (double k = 0; k < node.Count; k++) { nw.InsertString(s, s.Length, same); same = true; }
   for (var c = node.Child; c != null; c = c.Sibling) InsertRecursively(c, s, nw);
  }

  // The variable item: 0xFF, header, character buffer, nodes in pre-order, and the unused trailing byte.
  public byte[] ToBytes() {
   var o = new List<byte>();
   o.Add(0xFF);
   foreach (double v in new double[] { 1, Nulls, Count, Distinct, 40, 40, 0, 0, BufLen }) o.AddRange(BitConverter.GetBytes((int)v));
   for (int k = 0; k < BufLen; k++) { if (EightBit) o.Add((byte)buf[k]); else o.AddRange(BitConverter.GetBytes((ushort)buf[k])); }
   o.AddRange(BitConverter.GetBytes(Nodes));
   int written = 0;
   Write(Root, false, o, ref written);
   // the loader rebuilds the tree from the node flags alone: they must describe exactly the node count
   if (written != Nodes) throw new InvalidOperationException("Trie node count " + Nodes + " but " + written + " nodes written.");
   o.Add(0);
   return o.ToArray();
  }

  // SQL Server's import checks (CTrieInMemCore::FValidate) plus what its loader assumes without checking: the node flags,
  // read as it reads them (children while 0x80 says a sibling follows), describe exactly the node count. Null = valid.
  public static string Check(byte[] d, bool eightBit) {
   try {
    if (d.Length < 41 || d[0] != 0xFF || BitConverter.ToInt32(d, 1) != 1) return "marker or version";
    uint nulls = BitConverter.ToUInt32(d, 5), sampled = BitConverter.ToUInt32(d, 9), distinct = BitConverter.ToUInt32(d, 13), bufLen = BitConverter.ToUInt32(d, 33);
    if (nulls > sampled || distinct > sampled) return "NULLs or distinct above the strings sampled";
    if (bufLen > 0x44F73) return "character buffer too long";
    int p = 37 + (int)bufLen * (eightBit ? 1 : 2);
    int nodeCount = BitConverter.ToInt32(d, p); p += 4;
    if (nodeCount < 1 || nodeCount > 65536) return "node count";
    double sum = 0; int read = 0;
    ReadNode(d, ref p, bufLen, ref sum, ref read);   // the root, then its subtree
    if (read != nodeCount) return "the node flags describe " + read + " nodes, the count says " + nodeCount;
    if (p != d.Length - 1) return "bytes after the nodes";
    if (sampled != nulls + sum) return "strings sampled <> NULLs + occurrences";
    return null;
   } catch (Exception e) { return "unreadable: " + e.Message; }
  }

  static bool ReadNode(byte[] d, ref int p, uint bufLen, ref double sum, ref int read) {
   byte info = d[p];
   uint reference = BitConverter.ToUInt32(d, p + 1); p += 5;
   uint count = (uint)(info & 0x0F);
   if ((info & 0x20) != 0) { count = BitConverter.ToUInt32(d, p); p += 4; } else if ((info & 0x10) != 0) { count = d[p]; p += 1; }
   uint off = reference >> 8, len = reference & 0xFF;
   if (off > bufLen || off + len > bufLen) throw new InvalidOperationException("segment outside the buffer");
   sum += count; read++;
   if (read > 65536) throw new InvalidOperationException("too many nodes");
   if ((info & 0x40) != 0) { while (ReadNode(d, ref p, bufLen, ref sum, ref read)) { } }
   return (info & 0x80) != 0;
  }

  void Write(TrieNode node, bool sibling, List<byte> o, ref int written) {
   uint count = (uint)node.Count;
   byte info = (byte)((node.Child != null ? 0x40 : 0) | (sibling ? 0x80 : 0));
   if (count < 16) info |= (byte)count; else if (count < 256) info |= 0x10; else info |= 0x20;
   o.Add(info);
   o.AddRange(BitConverter.GetBytes((uint)((node.Off << 8) | node.Len)));
   if (count >= 16 && count < 256) o.Add((byte)count); else if (count >= 256) o.AddRange(BitConverter.GetBytes(count));
   written++;
   for (var c = node.Child; c != null; c = c.Sibling) Write(c, c.Sibling != null, o, ref written);
  }
 }
 public static class Pilot {
  // Page of a row from the first 6 bytes of %%physloc%% (page id, file id).
  public static long PageOf(object v) {
   var b = v as byte[];
   if (b == null || b.Length < 6) return 0;
   return (long)BitConverter.ToUInt32(b, 0) | ((long)BitConverter.ToUInt16(b, 4) << 32);
  }

  // Rows of (page, value): rows per page and the intraclass correlation of the values' ranks between pages.
  public static PilotStats Analyze(IDataReader r, bool text) {
   var pages = new List<long>(); var keys = new List<object>();
   var ps = new PilotStats();
   while (r.Read()) {
    if (r.IsDBNull(1)) { ps.Nulls++; continue; }
    object raw;
    try { raw = r.GetValue(1); } catch (OverflowException) { raw = r.GetType().GetMethod("GetSqlValue", new[] { typeof(int) }).Invoke(r, new object[] { 1 }); }
    // text: any consistent order serves the rank correlation, so the string's own ordering is enough here
    pages.Add(PageOf(r.GetValue(0))); keys.Add(text ? (object)Convert.ToString(raw) : Profile.Sortable(raw));
   }
   var rank = new SortedDictionary<object, double>(new KeyComparer());
   foreach (var key in keys) if (!rank.ContainsKey(key)) rank.Add(key, 0);
   double next = 0; var ordered = new List<object>(rank.Keys);
   foreach (var key in ordered) rank[key] = next++;
   ps.Distinct = rank.Count;
   var byPage = new Dictionary<long, double[]>();   // rows, sum of ranks, sum of squared ranks
   for (int i = 0; i < keys.Count; i++) {
    double[] a;
    if (!byPage.TryGetValue(pages[i], out a)) { a = new double[3]; byPage.Add(pages[i], a); }
    double x = rank[keys[i]]; a[0]++; a[1] += x; a[2] += x * x;
   }
   double N = keys.Count, k = byPage.Count;
   ps.Pages = k; ps.Rows = N + ps.Nulls; ps.RowsPerPage = k > 0 ? ps.Rows / k : 0;
   if (k < 2 || N <= k) return ps;
   double grand = 0; foreach (var a in byPage.Values) grand += a[1];
   grand /= N;
   double ssb = 0, ssw = 0, sumSq = 0;
   foreach (var a in byPage.Values) { double m = a[1] / a[0]; ssb += a[0] * (m - grand) * (m - grand); ssw += a[2] - a[0] * m * m; sumSq += a[0] * a[0]; }
   double msb = ssb / (k - 1), msw = ssw / (N - k), m0 = (N - sumSq / N) / (k - 1);
   double den = msb + (m0 - 1) * msw;
   ps.Icc = den > 0 ? Math.Max(0, Math.Min(1, (msb - msw) / den)) : (msb > 0 ? 1 : 0);
   ps.DesignEffect = Math.Max(1, 1 + (N / k - 1) * ps.Icc);
   return ps;
  }
 }

 public sealed class Candidate {
  public string Name; public List<int> Keys; public List<Step> Steps; public Score Score; public double Seconds;
 }

 public static class Histogram {
  // Every algorithm's candidate, built and scored in parallel (the profile is only read).
  public static Candidate[] BuildAll(Profile p, string[] names, int max, Workload w, double share, double scale, double nullEq, int ranges, int seed) {
   var result = new Candidate[names.Length];
   System.Threading.Tasks.Parallel.For(0, names.Length, delegate (int i) {
    var sw = System.Diagnostics.Stopwatch.StartNew();
    List<int> keys;
    switch (names[i]) {
     case "EqualRows": keys = EqualRows(p, max); break;
     case "MaxDiff": keys = MaxDiff(p, max); break;
     case "FrequentFirst": keys = FrequentFirst(p, max); break;
     case "VOptimal": keys = VOptimal(p, max); break;
     case "Workload": keys = Workload(p, max, w, share); break;
     default: throw new ArgumentException("Unknown algorithm " + names[i]);
    }
    var c = new Candidate();
    c.Name = names[i]; c.Keys = keys; c.Steps = FromPositions(p, keys, scale);
    c.Score = Evaluate(p, c.Steps, nullEq, scale, ranges, seed);
    EvaluateWorkload(p, c.Steps, scale, w, c.Score);
    c.Seconds = sw.Elapsed.TotalSeconds;
    result[i] = c;
   });
   return result;
  }

  // Haas-Stokes Duj1: distinct values of N rows from a sample of n rows with d distinct values, f1 of them seen once.
  public static double EstimateDistinct(double n, double d, double f1, double N) {
   if (n <= 0 || d <= 0) return 0;
   if (N <= n) return d;
   double den = n - f1 + f1 * n / N;
   double est = den > 0 ? n * d / den : d;
   return Math.Max(d, Math.Min(est, N));
  }

  // Steps for sorted key positions. Each step's range holds the entries after the previous key and the key entry's
  // other values; counts are scaled by Scale, distinct values estimated (from sampling units) when the profile is a sample.
  public static List<Step> FromPositions(Profile p, IList<int> keys, double scale) {
   var steps = new List<Step>(keys.Count);
   int prev = -1;
   foreach (int k in keys) {
    double r = 0, d = 0, u = 0, ones = 0;
    for (int i = prev + 1; i < k; i++) { var e = p.Entries[i]; r += e.Rows; d += e.Distinct; u += e.Units; ones += e.Ones; }
    var ke = p.Entries[k];
    // the key's own value is not in the range: take out its rows, and its units and single-unit count as best known
    double keyUnits = ke.Distinct == 1 ? ke.Units : Math.Min(ke.Units, ke.LastRows);
    r += ke.Rows - ke.LastRows; d += ke.Distinct - 1; u += ke.Units - keyUnits; ones += Math.Max(0, ke.Ones - (keyUnits == 1 ? 1 : 0));
    var s = new Step();
    s.Key = ke.Key; s.Raw = ke.Raw; s.Eq = ke.LastRows * scale; s.Range = r * scale;
    s.Distinct = scale > 1 ? EstimateDistinct(u, d, ones, u * scale) : d;
    s.Avg = s.Distinct > 0 ? s.Range / s.Distinct : 1;
    steps.Add(s);
    prev = k;
   }
   return steps;
  }

  static List<int> Finish(Profile p, SortedSet<int> set, int max) {
   int n = p.Entries.Count;
   set.Add(0); set.Add(n - 1);
   var keys = new List<int>(set);
   while (keys.Count > max) keys.RemoveAt(keys.Count - 2);
   return Fill(p, keys, max);
  }

  // Every step is used: while fewer than Max, split the step with the most RANGE_ROWS where its range rows reach half.
  // (SQL Server often stops well short of 200 steps; a step costs a few bytes and no measurable compile time.)
  public static List<int> Fill(Profile p, List<int> keys, int max) {
   while (keys.Count < max) {
    int best = -1; double bestRows = 0;
    for (int s = 1; s < keys.Count; s++) {
     if (keys[s] - keys[s - 1] < 2) continue;
     double r = 0; for (int i = keys[s - 1] + 1; i < keys[s]; i++) r += p.Entries[i].Rows;
     if (r > bestRows) { bestRows = r; best = s; }
    }
    if (best < 0) break;
    double acc = 0; int at = keys[best - 1] + 1;
    for (int i = keys[best - 1] + 1; i < keys[best]; i++) { acc += p.Entries[i].Rows; at = i; if (acc >= bestRows / 2) break; }
    keys.Insert(best, at);
   }
   return keys;
  }
  static List<int> All(int n) { var k = new List<int>(n); for (int i = 0; i < n; i++) k.Add(i); return k; }

  // Equal rows per step.
  public static List<int> EqualRows(Profile p, int max) {
   int n = p.Entries.Count;
   if (n <= max) return All(n);
   double total = 0; for (int i = 1; i < n; i++) total += p.Entries[i].Rows;
   // a key each time the running total crosses the next multiple of the target (no remainder lost)
   double target = total / (max - 1), acc = 0, next = target;
   var set = new SortedSet<int>();
   for (int i = 1; i < n; i++) { acc += p.Entries[i].Rows; if (acc >= next) { set.Add(i); while (next <= acc) next += target; } }
   return Finish(p, set, max);
  }

  // Keys where the rows change most against both neighbours (close to SQL Server's own approach).
  public static List<int> MaxDiff(Profile p, int max) {
   int n = p.Entries.Count;
   if (n <= max) return All(n);
   // sorted with Array.Sort on (negated score, position) arrays: no comparer delegate over every entry
   var idx = new int[n - 2]; var neg = new double[n - 2];
   for (int i = 1; i < n - 1; i++) {
    double r = p.Entries[i].LastRows;
    neg[i - 1] = -(Math.Abs(r - p.Entries[i - 1].Rows) + Math.Abs(r - p.Entries[i + 1].Rows));
    idx[i - 1] = i;
   }
   Array.Sort(neg, idx);
   var set = new SortedSet<int>();
   for (int i = 0; i < idx.Length && set.Count < max - 2; i++) set.Add(idx[i]);
   return Finish(p, set, max);
  }

  // The values heavier than an average step become keys (EQ_ROWS exact for them); the rest by equal rows.
  public static List<int> FrequentFirst(Profile p, int max) {
   int n = p.Entries.Count;
   if (n <= max) return All(n);
   double total = 0; for (int i = 1; i < n; i++) total += p.Entries[i].Rows;
   double avgStep = total / (max - 1);
   var heavy = new List<int>();
   for (int i = 1; i < n - 1; i++) if (p.Entries[i].LastRows >= avgStep) heavy.Add(i);
   heavy.Sort(delegate (int a, int b) { return p.Entries[b].LastRows.CompareTo(p.Entries[a].LastRows); });
   var set = new SortedSet<int>();
   double heavyRows = 0;
   for (int i = 0; i < heavy.Count && set.Count < max - 2; i++) { set.Add(heavy[i]); heavyRows += p.Entries[heavy[i]].LastRows; }
   int budget = max - 2 - set.Count;
   if (budget > 0) {
    double target = (total - heavyRows) / (budget + 1), acc = 0, next = target;
    for (int i = 1; i < n - 1 && set.Count < max - 2; i++) {
     if (set.Contains(i)) { acc += p.Entries[i].Rows - p.Entries[i].LastRows; continue; }
     acc += p.Entries[i].Rows;
     if (acc >= next) { set.Add(i); while (next <= acc) next += target; }
    }
   }
   return Finish(p, set, max);
  }

  // Steps where the queries filter: their equality values become keys, and the edges of their ranges become the keys
  // just before and at the end of each range (so the range is whole steps). About Share of the steps go to the workload,
  // heaviest first; least variance places the rest.
  public static List<int> Workload(Profile p, int max, Workload w, double share) {
   int n = p.Entries.Count;
   if (n <= max) return All(n);
   var items = new List<KeyValuePair<double, int>>();
   for (int i = 0; i < w.EqValues.Count; i++) { int x = p.IndexOf(w.EqValues[i]); if (x > 0) items.Add(new KeyValuePair<double, int>(w.EqWeights[i], x)); }
   for (int i = 0; i < w.Lo.Count; i++) {
    if (w.Lo[i] != null) { int x = p.IndexBelow(w.Lo[i], !w.LoInclusive[i]); if (x > 0) items.Add(new KeyValuePair<double, int>(w.RangeWeights[i], x)); }
    if (w.Hi[i] != null) { int x = p.IndexBelow(w.Hi[i], w.HiInclusive[i]); if (x > 0) items.Add(new KeyValuePair<double, int>(w.RangeWeights[i], x)); }
   }
   items.Sort(delegate (KeyValuePair<double, int> a, KeyValuePair<double, int> b) { return b.Key.CompareTo(a.Key); });
   var required = new bool[n]; int budget = (int)((max - 2) * share), used = 0;
   foreach (var it in items) { if (used >= budget) break; if (it.Value < n - 1 && !required[it.Value]) { required[it.Value] = true; used++; } }
   return VOptimal(p, max, required);
  }

  public static List<int> VOptimal(Profile p, int max) { return VOptimal(p, max, null); }

  // Least variance inside the steps (greedy v-optimal): start with one step per entry and merge the neighbouring pair
  // whose merge adds the least squared error between each value's rows and the step's AVG_RANGE_ROWS. Required keys
  // are never merged away.
  public static List<int> VOptimal(Profile p, int max, bool[] required) {
   int n = p.Entries.Count;
   if (n <= max) return All(n);
   var R = new double[n + 1]; var D = new double[n + 1]; var S = new double[n + 1];
   for (int i = 0; i < n; i++) { var e = p.Entries[i]; R[i + 1] = R[i] + e.Rows; D[i + 1] = D[i] + e.Distinct; S[i + 1] = S[i] + e.SumSq; }
   var start = new int[n]; var next = new int[n]; var prevStep = new int[n]; var version = new int[n]; var alive = new bool[n];
   for (int i = 0; i < n; i++) { start[i] = i; next[i] = i + 1 < n ? i + 1 : -1; prevStep[i] = i - 1; alive[i] = true; }
   Func<int, int, double> sse = delegate (int from, int key) {
    var ke = p.Entries[key];
    double r = R[key] - R[from] + ke.Rows - ke.LastRows, d = D[key] - D[from] + ke.Distinct - 1, s = S[key] - S[from] + ke.SumSq - ke.LastRows * ke.LastRows;
    return d > 0 ? Math.Max(0, s - r * r / d) : 0;
   };
   var heap = new List<Pair>();   // a min-heap of structs: no allocation per queued pair
   Action<int> push = delegate (int a) {
    int b = next[a];
    if (a <= 0 || b < 0 || (required != null && required[a])) return;
    heap.Add(new Pair(sse(start[a], b) - sse(start[a], a) - sse(start[b], b), a, b, version[a], version[b]));
    int c = heap.Count - 1;
    while (c > 0) { int up = (c - 1) / 2; if (heap[up].Cost <= heap[c].Cost) break; var t = heap[up]; heap[up] = heap[c]; heap[c] = t; c = up; }
   };
   Func<Pair> pop = delegate {
    var top = heap[0]; var last = heap[heap.Count - 1]; heap.RemoveAt(heap.Count - 1);
    if (heap.Count > 0) {
     heap[0] = last; int c = 0;
     while (true) {
      int l = 2 * c + 1, r = l + 1, m = c;
      if (l < heap.Count && heap[l].Cost < heap[m].Cost) m = l;
      if (r < heap.Count && heap[r].Cost < heap[m].Cost) m = r;
      if (m == c) break;
      var t = heap[m]; heap[m] = heap[c]; heap[c] = t; c = m;
     }
    }
    return top;
   };
   for (int i = 1; i < n; i++) push(i);
   int count = n;
   while (count > max && heap.Count > 0) {
    var h = pop();
    int a = h.A, b = h.B;
    if (!alive[a] || !alive[b] || next[a] != b || version[a] != h.VA || version[b] != h.VB) continue;
    // step a joins step b: b's range now starts where a's did
    start[b] = start[a]; alive[a] = false; count--;
    int pa = prevStep[a];
    next[pa] = b; prevStep[b] = pa;
    // only b's range changed: its pairs are queued again; pa's own range (and its pair with its previous step) is unchanged
    version[b]++;
    push(pa); push(b);
   }
   var keys = new List<int>();
   for (int i = 0; i >= 0; i = next[i]) keys.Add(i);
   return keys;
  }

  // Scores a histogram against the profile with the optimizer's equality rule (measured on SQL Server 2025): EQ_ROWS for
  // a value that is a step key, AVG_RANGE_ROWS for a value inside a step. Values above the last step are counted apart and
  // estimated at 1 row. Ranges: random ranges of profile entries, summed from the per-value estimates.
  // Estimate of one value: EQ_ROWS on a step key, AVG_RANGE_ROWS inside a step, 1 above the last step.
  public static double EstimateValue(IList<Step> steps, object key) {
   int lo = 0, hi = steps.Count - 1, s = steps.Count;
   while (lo <= hi) { int mid = (lo + hi) / 2; if (Profile.Compare(steps[mid].Key, key) >= 0) { s = mid; hi = mid - 1; } else lo = mid + 1; }
   if (s == steps.Count) return 1;
   return Profile.Compare(steps[s].Key, key) == 0 ? steps[s].Eq : steps[s].Avg;
  }

  // Per entry: the estimate of its last value and of each of its other values, and running sums of estimated and
  // actual rows (ranges are differences of these sums).
  static void Estimates(Profile p, IList<Step> steps, double scale, double[] estLast, double[] estInner, double[] pe, double[] pa, Score score) {
   int s = 0;
   for (int i = 0; i < p.Entries.Count; i++) {
    var e = p.Entries[i];
    while (s < steps.Count && Profile.Compare(steps[s].Key, e.Key) < 0) s++;
    if (s == steps.Count) { estLast[i] = 1; estInner[i] = 1; if (score != null) score.ValuesAbove += e.Distinct; }
    else if (Profile.Compare(steps[s].Key, e.Key) == 0) { estLast[i] = steps[s].Eq; estInner[i] = steps[s].Avg; }
    else { estLast[i] = steps[s].Avg; estInner[i] = steps[s].Avg; }
    pe[i + 1] = pe[i] + estLast[i] + estInner[i] * (e.Distinct - 1);
    pa[i + 1] = pa[i] + e.Rows * scale;
   }
  }

  public static Score Evaluate(Profile p, IList<Step> steps, double nullEq, double scale, int ranges, int seed) {
   int n = p.Entries.Count;
   // flat arrays (q-error, weight in values, weight in rows): no allocation per value
   var qs = new List<double>(n + 1); var ws = new List<double>(n + 1); var rs = new List<double>(n + 1);
   var estLast = new double[n]; var estInner = new double[n]; var pe = new double[n + 1]; var pa = new double[n + 1];
   var score = new Score();
   Estimates(p, steps, scale, estLast, estInner, pe, pa, score);
   for (int i = 0; i < n; i++) {
    var e = p.Entries[i];
    double actLast = e.LastRows * scale;
    qs.Add(QError(estLast[i], actLast)); ws.Add(1); rs.Add(actLast);
    double inner = e.Distinct - 1;
    if (inner > 0) {
     double actInner = (e.Rows - e.LastRows) / inner * scale;
     qs.Add(QError(estInner[i], actInner)); ws.Add(inner); rs.Add(actInner * inner);
    }
   }
   if (p.NullRows > 0 || nullEq > 0) { qs.Add(QError(nullEq, p.NullRows * scale)); ws.Add(1); rs.Add(p.NullRows * scale); }
   double[] q = qs.ToArray(), wv = ws.ToArray(), rv = rs.ToArray();
   double w = 0, lg = 0;
   for (int i = 0; i < q.Length; i++) { w += wv[i]; lg += wv[i] * Math.Log(q[i]); if (q[i] > score.EqMax) score.EqMax = q[i]; if (q[i] > 10) score.ValuesOver10 += wv[i]; }
   score.Values = w;
   score.EqGeoMean = w > 0 ? Math.Exp(lg / w) : 1;
   score.EqP95 = Percentile(q, wv, 0.95);
   score.EqP95ByRows = Percentile(q, rv, 0.95);
   var rq = new double[n > 0 ? ranges : 0];
   var rnd = new Random(seed);
   double rl = 0;
   for (int k = 0; k < rq.Length; k++) {
    int a = rnd.Next(n), b = rnd.Next(n);
    if (a > b) { int t = a; a = b; b = t; }
    rq[k] = QError(pe[b + 1] - pe[a], pa[b + 1] - pa[a]);
    rl += Math.Log(rq[k]); if (rq[k] > score.RangeMax) score.RangeMax = rq[k];
   }
   score.RangeGeoMean = rq.Length > 0 ? Math.Exp(rl / rq.Length) : 1;
   score.RangeP95 = Percentile(rq, null, 0.95);
   return score;
  }

  // The workload's own predicates, weighted by executions: equality values and ranges, estimate against the profile.
  public static void EvaluateWorkload(Profile p, IList<Step> steps, double scale, Workload w, Score score) {
   int n = p.Entries.Count;
   if (w == null || w.Count == 0 || n == 0) return;
   var estLast = new double[n]; var estInner = new double[n]; var pe = new double[n + 1]; var pa = new double[n + 1];
   Estimates(p, steps, scale, estLast, estInner, pe, pa, null);
   var qs = new List<double>(); var ws = new List<double>();
   for (int i = 0; i < w.EqValues.Count; i++) {
    int x = p.IndexOf(w.EqValues[i]);
    double est = x >= 0 ? estLast[x] : EstimateValue(steps, w.EqValues[i]);
    double act = x >= 0 ? p.Entries[x].LastRows * scale : 0;
    qs.Add(QError(est, act)); ws.Add(w.EqWeights[i]);
   }
   for (int i = 0; i < w.Lo.Count; i++) {
    int from = w.Lo[i] == null ? 0 : p.IndexBelow(w.Lo[i], !w.LoInclusive[i]) + 1;
    int to = w.Hi[i] == null ? n - 1 : p.IndexBelow(w.Hi[i], w.HiInclusive[i]);
    double est = to >= from ? pe[to + 1] - pe[from] : 0, act = to >= from ? pa[to + 1] - pa[from] : 0;
    qs.Add(QError(est, act)); ws.Add(w.RangeWeights[i]);
   }
   double[] q = qs.ToArray(), wv = ws.ToArray();
   double tw = 0, lg = 0, mx = 0;
   for (int i = 0; i < q.Length; i++) { tw += wv[i]; lg += wv[i] * Math.Log(q[i]); if (q[i] > mx) mx = q[i]; }
   score.WorkloadGeoMean = tw > 0 ? Math.Exp(lg / tw) : 1;
   score.WorkloadP95 = Percentile(q, wv, 0.95);
   score.WorkloadMax = mx;
  }

  public static double QError(double est, double act) {
   double e = Math.Max(est, 1), a = Math.Max(act, 1);
   return Math.Max(e / a, a / e);
  }

  // Weighted percentile (weights null = 1 each): sorts copies of the arrays.
  static double Percentile(double[] values, double[] weights, double p) {
   if (values.Length == 0) return 1;
   var v = (double[])values.Clone();
   var w = weights == null ? null : (double[])weights.Clone();
   if (w != null) Array.Sort(v, w); else Array.Sort(v);
   double total = 0; if (w != null) { foreach (var x in w) total += x; } else total = v.Length;
   double acc = 0;
   for (int i = 0; i < v.Length; i++) { acc += w != null ? w[i] : 1; if (acc >= p * total) return v[i]; }
   return v[v.Length - 1];
  }

  struct Pair {
   public double Cost; public int A, B, VA, VB;
   public Pair(double cost, int a, int b, int va, int vb) { Cost = cost; A = a; B = b; VA = va; VB = vb; }
  }
 }
}
'@

function Initialize-StatsBuilder {
    if ('SQLStatsXRay.Builder.Profile' -as [type]) { return }
    # SqlTypes implement IXmlSerializable, so System.Xml is referenced too
    $refs = @([Data.IDataReader].Assembly.Location, [Data.SqlTypes.SqlDecimal].Assembly.Location, [Xml.Serialization.IXmlSerializable].Assembly.Location) | Select-Object -Unique
    Add-Type -TypeDefinition $script:BuilderCode -ReferencedAssemblies $refs
}

# Key types the builder supports: numbers, dates and times, uniqueidentifier, binary, and char / varchar / nchar / nvarchar
# (ordered by the server in the column's collation). Not sql_variant, CLR types, rowversion, text or ntext.
$script:BuildKeyTypes = 48, 52, 56, 127, 104, 59, 62, 60, 122, 106, 108, 40, 41, 42, 43, 61, 58, 36, 173, 165, 175, 167, 239, 231
$script:BuildTextTypes = 175, 167, 239, 231

function Get-StatsBuildTarget($Connection, [string]$TableName, [string]$StatName, [string]$ColumnName) {
    <# The table, its column and, for an existing statistics object, the object (one column only in v1). #>
    $t = Get-StatsTargets $Connection $TableName $(if ($StatName) { @($StatName) } else { $null })
    $qualified = '[' + $t.Schema.Replace(']', ']]') + '].[' + $t.Table.Replace(']', ']]') + ']'
    $stat = $null
    if ($StatName) {
        $stat = @($t.Stats)[0]
        if (-not $stat) { throw "Statistics '$StatName' not found on $qualified." }
        $cols = @((Invoke-Query $Connection 'SELECT c.name FROM sys.stats_columns sc JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id WHERE sc.object_id = @o AND sc.stats_id = @s' @{ '@o' = $t.ObjectId; '@s' = [int]$stat.stats_id })[0].Rows)
        if ($cols.Count -ne 1) { throw "'$StatName' has $($cols.Count) columns; the builder handles statistics on one column." }
        if ($ColumnName -and $ColumnName -ne [string]$cols[0].name) { throw "'$StatName' is on column [$($cols[0].name)], not [$ColumnName]." }
        $ColumnName = [string]$cols[0].name
        if ($stat.has_filter) { throw 'Filtered statistics are not supported by the builder yet.' }
        if ($stat.Table.Columns.Contains('is_incremental') -and $stat.is_incremental -eq $true) { throw 'Incremental statistics are not supported by the builder yet.' }
        if ($stat.index_type -isnot [DBNull] -and $stat.index_type) {
            Write-Warning "'$StatName' belongs to an index: the next rebuild of that index replaces a built histogram with a FULLSCAN one."
        }
    }
    if (-not $ColumnName) { throw 'Give -Column for a new statistics object, or -Statistics for an existing one.' }
    $c = @((Invoke-Query $Connection @'
SELECT c.name, c.column_id, c.system_type_id, c.user_type_id, TYPE_NAME(c.system_type_id) AS type_name, c.max_length, c.precision, c.scale,
       c.collation_name, CAST(COLLATIONPROPERTY(c.collation_name, 'CodePage') AS int) AS code_page, c.is_nullable, c.is_computed, o.type AS object_type
FROM sys.columns c JOIN sys.objects o ON o.object_id = c.object_id WHERE c.object_id = @o AND c.name = @c
'@ @{ '@o' = $t.ObjectId; '@c' = $ColumnName })[0].Rows)[0]
    if (-not $c) { throw "Column [$ColumnName] not found on $qualified." }
    if (([string]$c.object_type).Trim() -ne 'U') { throw 'The builder works on tables (not views).' }
    if ([int]$c.system_type_id -notin $script:BuildKeyTypes) { throw "Columns of type $($c.type_name) are not supported by the builder yet (numbers, dates and times, uniqueidentifier, binary and character columns)." }
    $type = [string]$c.type_name
    switch ($type) {
        { $_ -in 'decimal', 'numeric' } { $type += "($($c.precision),$($c.scale))" }
        { $_ -in 'datetime2', 'time', 'datetimeoffset' } { $type += "($($c.scale))" }
        { $_ -in 'binary', 'varbinary' } { $type += $(if ([int]$c.max_length -eq -1) { '(max)' } else { "($($c.max_length))" }) }
        'float' { if ([int]$c.max_length -eq 4) { $type = 'real' } }
        { $_ -in 'char', 'varchar' } { $type += $(if ([int]$c.max_length -eq -1) { '(max)' } else { "($($c.max_length))" }) }
        { $_ -in 'nchar', 'nvarchar' } { $type += $(if ([int]$c.max_length -eq -1) { '(max)' } else { "($([int]$c.max_length / 2))" }) }
    }
    $isText = [int]$c.system_type_id -in $script:BuildTextTypes
    # temporary copies of the column (template, ranks) keep its collation
    $typeFull = $(if ($isText) { "$type COLLATE $($c.collation_name)" } else { $type })
    $size = (Invoke-Query $Connection @'
SELECT SUM(p.rows) AS rows, SUM(au.data_pages) AS pages FROM sys.partitions p
JOIN sys.allocation_units au ON au.container_id = p.partition_id AND au.type = 1
WHERE p.object_id = @o AND p.index_id IN (0, 1)
'@ @{ '@o' = $t.ObjectId })[0].Rows[0]
    [pscustomobject]@{
        ObjectId = $t.ObjectId; Table = $qualified; SchemaName = $t.Schema; TableName = $t.Table; Stat = $stat; StatName = $(if ($stat) { [string]$stat.name } else { $null })
        Column = [string]$c.name; ColumnSql = '[' + ([string]$c.name).Replace(']', ']]') + ']'; ColumnType = $type; ColumnTypeFull = $typeFull; SystemTypeId = [int]$c.system_type_id
        IsText = $isText; Collation = $(if ($isText) { [string]$c.collation_name } else { '' }); CodePage = $(if ($isText -and [int]$c.system_type_id -in 175, 167) { [int]$c.code_page } else { 0 })
        IsNullable = [bool]$c.is_nullable; Rows = [int64]$(if ($size.rows -is [DBNull]) { 0 } else { $size.rows }); Pages = [int64]$(if ($size.pages -is [DBNull]) { 0 } else { $size.pages })
    }
}

function Get-SqlServerSamplePlan([int64]$Rows, [int64]$Pages, [string]$Sample) {
    <#
      SQL Server's sample size, from CStatMan::ComputeSample in the SQL Server 2025 engine: base table pages; under 1,024
      pages (8 MB) everything; SAMPLE p PERCENT or n ROWS at least 1,024 pages; the default
      trunc(pages * 15 * trunc(rows ^ 0.55) / rows) + 1024 pages. Never more than the table.
    #>
    $s = $Sample.Trim()
    $full = @{ Percent = 100.0; Pages = $Pages; Full = $true; Rule = '' }
    if ($s -match '^(?i)FULLSCAN$') { $full.Rule = 'FULLSCAN'; return $full }
    if ($Pages -lt 1024 -or $Rows -le 0) { $full.Rule = 'under 1,024 pages: read in full'; return $full }
    if ($s -match '^(?i)DEFAULT$') {
        $target = [Math]::Truncate($Pages * (15 * [Math]::Truncate([Math]::Pow($Rows, 0.55))) / $Rows) + 1024
        $rule = 'default: pages x 15 x rows^0.55 / rows + 1,024'
    } elseif ($s -match '^(?i)(\d+(?:\.\d+)?)\s*PERCENT$') {
        $p = [double]::Parse($Matches[1], $script:Inv)
        if ($p -le 0 -or $p -gt 100) { throw 'The sample percent must be above 0 and at most 100.' }
        $target = [Math]::Max(1024, [Math]::Truncate($Pages * $p / 100)); $rule = "SAMPLE $($Matches[1]) PERCENT (at least 1,024 pages)"
    } elseif ($s -match '^(?i)(\d+)\s*ROWS$') {
        $target = [Math]::Max(1024, [Math]::Truncate($Pages * [double]$Matches[1] / $Rows)); $rule = "SAMPLE $($Matches[1]) ROWS (at least 1,024 pages)"
    } else { throw "-Sample takes Default, FULLSCAN, '<n> PERCENT' or '<n> ROWS', not '$Sample'." }
    if ($target -ge $Pages) { $full.Rule = "$rule = the whole table"; return $full }
    return @{ Percent = 100.0 * $target / $Pages; Pages = [int64]$target; Full = $false; Rule = $rule }
}

function Read-StatsBuildProfile($Connection, $Target, $Plan, [int]$Seed, [int]$TimeoutSeconds) {
    <#
      The column's (value, rows) pairs in key order, from the whole table or a TABLESAMPLE of its pages. A sample reads
      the base table (INDEX(0): heap or clustered index) as SQL Server does; through an index on the column the
      sampled pages would hold runs of neighbouring values. It also returns how many pages each value was seen on
      (%%physloc%%, undocumented), for the distinct value estimate.
    #>
    $c = $Target.ColumnSql
    if ($Plan.Full) { $sql = "SELECT $c, COUNT_BIG(*) FROM $($Target.Table) GROUP BY $c ORDER BY $c OPTION (KEEPFIXED PLAN, MAXDOP 1);" }
    else {
        # the adaptive sampler may read the leaf pages of the column's own index instead (sorted runs of keys)
        $path = $(if ($Plan.Path -and $Plan.Path -ne 'table') { '[' + $Plan.Path.Replace(']', ']]') + ']' } else { '0' })
        $sql = "SELECT $c, COUNT_BIG(*), COUNT(DISTINCT SUBSTRING(%%physloc%%, 1, 6)) FROM $($Target.Table) TABLESAMPLE SYSTEM (" +
        $Plan.Percent.ToString('0.######', $script:Inv) + " PERCENT) REPEATABLE ($Seed) WITH (INDEX($path)) GROUP BY $c ORDER BY $c OPTION (KEEPFIXED PLAN, MAXDOP 1);"
    }
    $cmd = $Connection.CreateCommand()
    $cmd.CommandTimeout = $TimeoutSeconds
    $cmd.CommandText = $sql
    $session = $Connection.CreateCommand()
    $session.CommandText = 'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED; SET LOCK_TIMEOUT 1000;'
    $null = $session.ExecuteNonQuery()
    $profile = New-StatsBuildProfile $Target $Connection $Plan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = $cmd.ExecuteReader()
        try { $profile.Read($r) } finally { $r.Close() }
    } finally {
        $session.CommandText = 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SET LOCK_TIMEOUT -1;'
        try { $null = $session.ExecuteNonQuery() } catch { }
    }
    return [pscustomobject]@{ Profile = $profile; Seconds = $sw.Elapsed.TotalSeconds }
}

function Get-StatsBuildTemplate($Connection, $Target) {
    <#
      A decoded stream whose step records fit the column: the existing statistics object's own stream, or one from a
      throwaway one-row statistic on a temporary table of the same type (nothing is created in the user's database).
    #>
    if ($Target.Stat) {
        $q = Read-ResultSets $Connection @'
DECLARE @cmd nvarchar(max) = N'DBCC SHOW_STATISTICS(' + QUOTENAME(@t, '''') + N', ' + QUOTENAME(@s) + N') WITH STATS_STREAM, NO_INFOMSGS';
EXEC sys.sp_executesql @cmd;
'@ @{ '@t' = $Target.Table; '@s' = $Target.StatName }
        $bytes = [byte[]](@($q[0])[0].Stats_Stream)
        $d = ConvertFrom-StatsStream -Bytes $bytes -Names @($Target.Column) -Label "$($Target.Table).[$($Target.StatName)]"
        if ($d.Header.NumberOfColumns -gt 1) {
            # nonclustered index statistics carry the clustering key too (more density vectors, a longer average key)
            throw "'$($Target.StatName)' holds $($d.Header.NumberOfColumns) columns in its stream (a nonclustered index also carries the clustering key). The builder writes one-column statistics: use -Column $($Target.Column) to build a new statistics object."
        }
        if (@($d.Histogram | Where-Object { -not $_.IsNullStep }).Count -gt 0) { return $d }
        # an empty or NULL-only statistic has no step record to copy: fall back to a temporary one
    }
    $null = Invoke-Query $Connection (@"
IF OBJECT_ID('tempdb..#xray_template') IS NOT NULL DROP TABLE #xray_template;
CREATE TABLE #xray_template (c $($Target.ColumnTypeFull) $(if ($Target.IsNullable) { 'NULL' } else { 'NOT NULL' }));
INSERT #xray_template (c) SELECT TOP (1) $($Target.ColumnSql) FROM $($Target.Table) WITH (READUNCOMMITTED) WHERE $($Target.ColumnSql) IS NOT NULL;
CREATE STATISTICS s ON #xray_template (c) WITH FULLSCAN;
"@)
    try {
        $q = Read-ResultSets $Connection "DBCC SHOW_STATISTICS('tempdb..#xray_template', s) WITH STATS_STREAM, NO_INFOMSGS"
        $bytes = [byte[]](@($q[0])[0].Stats_Stream)
    } finally { try { $null = Invoke-Query $Connection 'DROP TABLE #xray_template;' } catch { } }
    $d = ConvertFrom-StatsStream -Bytes $bytes -Names @($Target.Column) -Label 'template'
    if (@($d.Histogram | Where-Object { -not $_.IsNullStep }).Count -eq 0) { throw "The column has no values to build a histogram from." }
    return $d
}

function New-StatsBuildStream($Template, $Steps, $Built) {
    <#
      The STATS_STREAM for built steps, through the editor's encoder: the template's record layout, the new steps,
      header and density, the update history and distinct value synopsis left out (they describe another build).
    #>
    $model = New-StatsEditModel $Template
    $col = $Template.Columns[0]
    $tpl = @($model.Steps | Where-Object { -not $_.IsNull })[0]
    $fixed = $(if ($tpl.Template.Record.FixedEnd -gt 16) { $tpl.Template.Record.FixedEnd - 16 } else { 0 })
    $model.Steps.Clear()
    if ($Built.NullRows -gt 0) {
        $model.Steps.Add([pscustomobject]@{ IsNull = $true; Key = 'NULL'; KeyBytes = [byte[]]@(); RangeRows = [single]0; EqRows = [single]$Built.NullRows; StoredAvg = [single]1; Source = $null; Template = $tpl.Template })
    }
    foreach ($s in $Steps) {
        $text = Format-SqlValue $s.Raw $col.SystemTypeId $col.Scale
        $bytes = ConvertTo-SqlKeyBytes $text $col $fixed
        # the key must decode back to the same value, in SQL Server's order
        $back = ConvertFrom-SqlBytes -Data $bytes -SystemTypeId $col.SystemTypeId -UserTypeId $col.UserTypeId -MaxLength $col.MaxLength -Precision $col.Precision -Scale $col.Scale -CollationId $col.CollationId
        $same = $(if ($col.SystemTypeId -in $script:BuildTextTypes) { [string]$back -ceq [string]$s.Raw } else { [SQLStatsXRay.Builder.Profile]::Compare([SQLStatsXRay.Builder.Profile]::Sortable($back), $s.Key) -eq 0 })
        if (-not $same) { throw "Key $text does not round-trip through the stream format." }
        $st = New-StatsEditStep $null $col $tpl
        $st.Key = $text; $st.KeyBytes = $bytes
        $st.EqRows = [single]$s.Eq; $st.RangeRows = [single]$s.Range; $st.StoredAvg = [single]$s.Avg
        $model.Steps.Add($st)
    }
    $h = $model.Header
    $h['Updated'] = $Built.Updated
    $h['Rows'] = [int64]$Built.Rows
    $h['Rows Sampled'] = [int64]$Built.RowsSampled
    $h['Average key length'] = [single]$Built.AverageLength
    if ($h.Contains('Unfiltered Rows')) { $h['Unfiltered Rows'] = [int64]$Built.Rows }
    $model.Vectors[0].AllDensity = [single]$Built.AllDensity
    $model.Vectors[0].ColumnAverageLength = [single]$Built.AverageLength
    $model | Add-Member ServerOrder $true
    $notes = New-Object 'System.Collections.Generic.List[string]'
    # the string index (bit 1) of the template describes other strings: replaced by the one built from the rows read,
    # (added when the template has none), or left out for UTF-8 and double-byte code pages
    $drop = @(3, 5, 7)
    if ($Built.Trie) {
        $problem = [SQLStatsXRay.Builder.TrieBuilder]::Check([byte[]]$Built.Trie, ($col.SystemTypeId -in 175, 167))
        if ($problem) { throw "The built string index is not valid ($problem)." }
        $model | Add-Member ReplaceItems @{ 1 = [byte[]]$Built.Trie }
    } else {
        $drop += 1
        if ($col.SystemTypeId -in $script:BuildTextTypes) { $notes.Add('No string index: LIKE estimates on this statistic fall back to SQL Server''s guesses (UTF-8 and double-byte code pages are not supported by it).') }
    }
    $model | Add-Member DropBits $drop
    $out = ConvertTo-StatsStream $model
    $problems = @(Test-StatsStreamMatchesModel $out.Bytes $model)
    if ($problems) { throw "The built stream does not decode back to the histogram: $($problems -join ', ')." }
    return [pscustomobject]@{ Bytes = $out.Bytes; Warnings = @($out.Warnings) + $notes.ToArray(); Model = $model }
}

function Get-StatsBuildCharRanks($Connection, $Target) {
    <#
      The trie compares one character at a time in the column's collation: each possible character (the 256 bytes of a
      char/varchar code page, or the 65,536 UTF-16 code units) ranked by the server, equal characters sharing a rank.
      Cached per type family and collation.
    #>
    $wide = $Target.SystemTypeId -in 239, 231
    $cacheKey = "$wide|$($Target.Collation)"
    if (-not $script:CharRankCache) { $script:CharRankCache = @{} }
    if ($script:CharRankCache.ContainsKey($cacheKey)) { return , $script:CharRankCache[$cacheKey] }
    $coll = $Target.Collation
    if ($coll -notmatch '^\w+$') { throw "Unexpected collation name '$coll'." }
    if ($wide) {
        $sql = @"
WITH n AS (SELECT TOP (65536) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS u FROM sys.all_columns a CROSS JOIN sys.all_columns b)
SELECT u, DENSE_RANK() OVER (ORDER BY CAST(CAST(u % 256 AS binary(1)) + CAST(u / 256 AS binary(1)) AS nvarchar(1)) COLLATE $coll) AS r FROM n;
"@
    } else {
        # each byte as the Unicode character the column's code page gives it, converted back on the server in the collation
        $enc = [Text.Encoding]::GetEncoding($Target.CodePage)
        $values = (0..255 | ForEach-Object { "($_, NCHAR($([int]$enc.GetString([byte[]]@([byte]$_))[0])))" }) -join ', '
        $sql = "SELECT b AS u, DENSE_RANK() OVER (ORDER BY CAST(c COLLATE $coll AS varchar(1))) AS r FROM (VALUES $values) v(b, c);"
    }
    $rank = New-Object 'int[]' $(if ($wide) { 65536 } else { 256 })
    foreach ($r in (Invoke-Query $Connection $sql)[0].Rows) { $rank[[int]$r.u] = [int]$r.r }
    $script:CharRankCache[$cacheKey] = $rank
    return , $rank
}

function New-StatsBuildProfile($Target, $Connection, $Plan) {
    <#
      A profile for the column; text keys are ranked by the server (see SQLStatsXRay.Builder.Profile.TextKeys). Character
      columns also get the string index builder, which sees the rows as SQL Server's does: R is the estimated number of
      rows read (the table's rows for a full scan, sampled pages x rows per page otherwise). No string index for UTF-8
      collations (SQL Server builds none) or double-byte code pages (characters split across bytes).
    #>
    $p = New-Object SQLStatsXRay.Builder.Profile
    if ($Target.IsText) {
        $p.TextKeys = $true
        $wide = $Target.SystemTypeId -in 239, 231
        $p.TextEncoding = $(if ($wide) { [Text.Encoding]::Unicode } else { try { [Text.Encoding]::GetEncoding($Target.CodePage) } catch { [Text.Encoding]::GetEncoding(1252) } })
        if ($Connection -and $Plan -and ($wide -or $Target.CodePage -notin 65001, 932, 936, 949, 950, 1361)) {
            $p.Trie = New-Object SQLStatsXRay.Builder.TrieBuilder ((-not $wide), (Get-StatsBuildCharRanks $Connection $Target), $p.TextEncoding)
            $p.Trie.Initialise($(if ($Plan.Full) { [double]$Target.Rows } else { [Math]::Round([double]$Plan.Pages * $Target.Rows / [Math]::Max(1, $Target.Pages)) }))
        }
    }
    return , $p
}

function Get-StatsBuildRanks($Connection, $Target, $Profile, [object[]]$Values) {
    <#
      Positions of outside values (the current histogram's keys, Query Store values, the true minimum and maximum) among a
      text profile's keys, in the column's collation: the profile key itself when equal, otherwise a fraction between the
      two keys around it (values in the same gap get distinct fractions in their own order, equal values the same one).
      One sort on the server of the profile's keys and the values together.
    #>
    $result = New-Object 'double[]' $Values.Count
    if ($Values.Count -eq 0) { return , $result }
    $keys = New-Object Data.DataTable; $null = $keys.Columns.Add('ord', [double]); $null = $keys.Columns.Add('v', [string])
    foreach ($e in $Profile.Entries) { $null = $keys.Rows.Add([double]$e.Key, [string]$e.Raw) }
    $ext = New-Object Data.DataTable; $null = $ext.Columns.Add('i', [int]); $null = $ext.Columns.Add('v', [string])
    for ($i = 0; $i -lt $Values.Count; $i++) { $null = $ext.Rows.Add($i, [string]$Values[$i]) }
    $type = $Target.ColumnTypeFull
    $null = Invoke-Query $Connection "DROP TABLE IF EXISTS #xray_keys; DROP TABLE IF EXISTS #xray_ext; CREATE TABLE #xray_keys (ord float NOT NULL, v $type NOT NULL); CREATE TABLE #xray_ext (i int NOT NULL, v $type NOT NULL);"
    try {
        foreach ($pair in @(@('#xray_keys', $keys), @('#xray_ext', $ext))) {
            $bulk = New-Object Data.SqlClient.SqlBulkCopy $Connection
            $bulk.DestinationTableName = $pair[0]; $bulk.BulkCopyTimeout = 0
            $bulk.WriteToServer($pair[1]); $bulk.Close()
        }
        $q = Invoke-Query $Connection @'
WITH u AS (
    SELECT v, ord, NULL AS i, 0 AS src FROM #xray_keys
    UNION ALL SELECT v, NULL, i, 1 FROM #xray_ext
), w AS (
    -- the last profile key at or before each value (keys sort before equal values)
    SELECT i, v, MAX(ord) OVER (ORDER BY v, src ROWS UNBOUNDED PRECEDING) AS ord_le FROM u
), x AS (
    SELECT w.i, w.v, w.ord_le, CASE WHEN k.v = w.v THEN 1 ELSE 0 END AS eq
    FROM w LEFT JOIN #xray_keys k ON k.ord = w.ord_le WHERE w.i IS NOT NULL
)
SELECT i, ord_le, eq,
       DENSE_RANK() OVER (PARTITION BY ISNULL(ord_le, -1), eq ORDER BY v) AS j,
       COUNT(*) OVER (PARTITION BY ISNULL(ord_le, -1), eq) AS n
FROM x;
'@
        foreach ($r in $q[0].Rows) {
            $base = $(if ($r.ord_le -is [DBNull]) { -1.0 } else { [double]$r.ord_le })
            # n bounds the dense rank, so the fraction stays inside the gap
            $result[[int]$r.i] = $(if ([int]$r.eq -eq 1) { $base } else { $base + [double]$r.j / ([double]$r.n + 1) })
        }
    } finally { try { $null = Invoke-Query $Connection 'DROP TABLE IF EXISTS #xray_keys; DROP TABLE IF EXISTS #xray_ext;' } catch { } }
    return , $result
}

function Get-StatsBuildIndex($Connection, [int]$ObjectId, [string]$ColumnName) {
    # The smallest enabled, unfiltered rowstore index whose first key is the column (as the data check picks it).
    @((Invoke-Query $Connection @'
SELECT TOP (1) i.name, SUM(p.rows) AS rows, SUM(au.data_pages) AS pages
FROM sys.index_columns ic
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
JOIN sys.partitions p ON p.object_id = i.object_id AND p.index_id = i.index_id
JOIN sys.allocation_units au ON au.container_id = p.partition_id AND au.type = 1
WHERE ic.object_id = @o AND c.name = @c AND ic.key_ordinal = 1 AND i.type IN (1, 2) AND i.is_disabled = 0 AND i.is_hypothetical = 0 AND i.has_filter = 0
GROUP BY i.index_id, i.name ORDER BY SUM(au.data_pages), i.index_id;
'@ @{ '@o' = $ObjectId; '@c' = $ColumnName })[0].Rows)[0]
}

function Get-StatsBuildWorkload($Connection, [string]$SchemaName, [string]$TableName, $Columns, [int]$MaxPlans = 500) {
    <#
      Predicates on the table's columns from Query Store: the plans that reference the table (heaviest 500 by
      executions), their seek keys and comparison predicates against constants or parameters (compiled values only),
      weighted by the plan's executions, and the statistics each plan used. Returns one entry per column plus the
      statistics usage. Values are converted to the column's type on the server.
    #>
    $result = @{ Status = ''; Plans = 0; Executions = 0; StatsUsage = @{}; Columns = @{} }
    foreach ($c in $Columns) { $result.Columns[$c.Name] = [pscustomobject]@{ Workload = (New-Object SQLStatsXRay.Builder.Workload); Equality = 0; Ranges = 0; Unread = 0; EqWeight = 0.0; RangeWeight = 0.0; Plans = 0 } }
    try { $state = [string](Invoke-Query $Connection 'SELECT actual_state_desc FROM sys.database_query_store_options')[0].Rows[0].actual_state_desc }
    catch { $result.Status = "Query Store not readable: $($_.Exception.Message)"; return $result }
    if ($state -eq 'OFF' -or -not $state) { $result.Status = 'Query Store is off in this database.'; return $result }
    $like = { param([string]$s) $s.Replace('[', '[[]').Replace('%', '[%]').Replace('_', '[_]') }
    $tableAttr = '[' + $TableName.Replace(']', ']]') + ']'
    $schemaAttr = '[' + $SchemaName.Replace(']', ']]') + ']'
    $plans = @((Invoke-Query $Connection @'
SELECT TOP (@n) p.plan_id, p.query_plan, x.executions
FROM (SELECT plan_id, SUM(count_executions) AS executions FROM sys.query_store_runtime_stats GROUP BY plan_id) x
JOIN sys.query_store_plan p ON p.plan_id = x.plan_id
WHERE p.query_plan LIKE @pattern
ORDER BY x.executions DESC;
'@ @{ '@n' = $MaxPlans; '@pattern' = '%Table="' + (& $like $tableAttr) + '"%' })[0].Rows)
    $result.Plans = $plans.Count
    $result.Status = "Query Store $($state.ToLower()): $($plans.Count) plan(s) reference the table."
    $ns = 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'
    $flip = @{ LT = 'GT'; LE = 'GE'; GT = 'LT'; GE = 'LE'; EQ = 'EQ' }
    $pending = New-Object 'System.Collections.Generic.List[object]'   # value texts to convert: column, kind, text(s), weight
    $isOurs = {
        param($ref, [string]$col)
        # showplan writes Table="[T]" with brackets and Column="c" without
        $ref.GetAttribute('Table') -eq $tableAttr -and $ref.GetAttribute('Column') -eq $col -and (-not $ref.GetAttribute('Schema') -or $ref.GetAttribute('Schema') -eq $schemaAttr)
    }
    foreach ($row in $plans) {
        $w = [double]$row.executions
        $result.Executions += $w
        try { $x = [xml][string]$row.query_plan } catch { continue }
        $m = New-Object Xml.XmlNamespaceManager $x.NameTable; $m.AddNamespace('p', $ns)
        $params = @{}
        foreach ($pr in $x.SelectNodes('//p:ParameterList/p:ColumnReference', $m)) { $params[$pr.GetAttribute('Column')] = $pr.GetAttribute('ParameterCompiledValue') }
        # a value from a scalar operator: a constant, or a parameter with its compiled value
        $valueOf = {
            param($op)
            $const = $op.SelectSingleNode('.//p:Const', $m)
            if ($const) { return $const.GetAttribute('ConstValue') }
            foreach ($ref in $op.SelectNodes('.//p:Identifier/p:ColumnReference', $m)) {
                $n = $ref.GetAttribute('Column')
                if ($n.StartsWith('@') -and $params.ContainsKey($n) -and $params[$n]) { return $params[$n] }
            }
            return $null
        }
        foreach ($st in $x.SelectNodes('//p:OptimizerStatsUsage/p:StatisticsInfo', $m)) {
            if ($st.GetAttribute('Table') -eq $tableAttr -and (-not $st.GetAttribute('Schema') -or $st.GetAttribute('Schema') -eq $schemaAttr)) {
                $sn = $st.GetAttribute('Statistics').Trim('[', ']')
                $result.StatsUsage[$sn] = [double]$result.StatsUsage[$sn] + $w
            }
        }
        foreach ($c in $Columns) {
            $info = $result.Columns[$c.Name]; $seen = $false
            # seeks: Prefix EQ, StartRange / EndRange of the same SeekKeys
            foreach ($sk in $x.SelectNodes('//p:SeekKeys', $m)) {
                $lo = $null; $hi = $null; $loIncl = $true; $hiIncl = $true; $hasRange = $false
                foreach ($part in $sk.ChildNodes) {
                    $refs = @($part.SelectNodes('p:RangeColumns/p:ColumnReference', $m))
                    for ($i = 0; $i -lt $refs.Count; $i++) {
                        if (-not (& $isOurs $refs[$i] $c.Name)) { continue }
                        $seen = $true
                        $op = @($part.SelectNodes('p:RangeExpressions/p:ScalarOperator', $m))[$i]
                        $v = $(if ($op) { & $valueOf $op } else { $null })
                        $scan = $part.GetAttribute('ScanType')
                        if ($part.LocalName -eq 'Prefix' -and $scan -eq 'EQ') {
                            $info.EqWeight += $w
                            if ($null -ne $v) { $pending.Add(@($c.Name, 'eq', $v, $w)) } else { $info.Unread++ }
                        } elseif ($part.LocalName -eq 'StartRange') { $hasRange = $true; $lo = $v; $loIncl = $scan -eq 'GE'; if ($null -eq $v) { $info.Unread++ } }
                        elseif ($part.LocalName -eq 'EndRange') { $hasRange = $true; $hi = $v; $hiIncl = $scan -eq 'LE'; if ($null -eq $v) { $info.Unread++ } }
                    }
                }
                if ($hasRange) {
                    $info.RangeWeight += $w
                    if ($null -ne $lo -or $null -ne $hi) { $pending.Add(@($c.Name, 'range', @($lo, $loIncl, $hi, $hiIncl), $w)) }
                }
            }
            # residual and filter predicates: column <op> constant or parameter
            foreach ($cmp in $x.SelectNodes('//p:Compare', $m)) {
                $op = $cmp.GetAttribute('CompareOp')
                if (-not $flip.ContainsKey($op)) { continue }
                $sides = @($cmp.SelectNodes('p:ScalarOperator', $m))
                if ($sides.Count -ne 2) { continue }
                $mine = { param($s) foreach ($r in $s.SelectNodes('.//p:Identifier/p:ColumnReference', $m)) { if (& $isOurs $r $c.Name) { return $true } }; return $false }
                if (& $mine $sides[0]) { $other = $sides[1] } elseif (& $mine $sides[1]) { $other = $sides[0]; $op = $flip[$op] } else { continue }
                if ($other.SelectSingleNode('.//p:Identifier/p:ColumnReference[not(starts-with(@Column, "@"))]', $m)) { continue }   # column against column (a join)
                $seen = $true
                $v = & $valueOf $other
                if ($op -eq 'EQ') { $info.EqWeight += $w } else { $info.RangeWeight += $w }
                if ($null -eq $v) { $info.Unread++; continue }
                switch ($op) {
                    'EQ' { $pending.Add(@($c.Name, 'eq', $v, $w)) }
                    'GT' { $pending.Add(@($c.Name, 'range', @($v, $false, $null, $true), $w)) }
                    'GE' { $pending.Add(@($c.Name, 'range', @($v, $true, $null, $true), $w)) }
                    'LT' { $pending.Add(@($c.Name, 'range', @($null, $true, $v, $false), $w)) }
                    'LE' { $pending.Add(@($c.Name, 'range', @($null, $true, $v, $true), $w)) }
                }
            }
            if ($seen) { $info.Plans++ }
        }
    }
    if ($pending.Count -eq 0) { return $result }
    # values as text from the plans ((42), N'x', '2025-01-01', {guid'...'}) converted to the column's type on the server
    $clean = {
        param([string]$s)
        if ($null -eq $s) { return $null }
        $t = $s.Trim()
        while ($t.StartsWith('(') -and $t.EndsWith(')')) { $t = $t.Substring(1, $t.Length - 2).Trim() }
        if ($t -match "^\{guid'(.*)'\}$") { return $Matches[1] }
        if ($t -match "^N?'(.*)'$") { return $Matches[1].Replace("''", "'") }
        return $t
    }
    $texts = New-Object 'System.Collections.Generic.List[object]'   # column, text
    foreach ($p in $pending) {
        if ($p[1] -eq 'eq') { $texts.Add(@($p[0], (& $clean $p[2]))) }
        else { foreach ($v in @($p[2][0], $p[2][2])) { if ($null -ne $v) { $texts.Add(@($p[0], (& $clean $v))) } } }
    }
    $typed = @{}
    $byColumn = $texts | Group-Object { $_[0] }
    foreach ($g in $byColumn) {
        $col = $Columns | Where-Object { $_.Name -eq $g.Name } | Select-Object -First 1
        $style = $(if ($col.SystemTypeId -in 173, 165) { ', 1' } else { '' })
        $distinctTexts = @($g.Group | ForEach-Object { $_[1] } | Select-Object -Unique)
        for ($i = 0; $i -lt $distinctTexts.Count; $i += 500) {
            $chunk = @($distinctTexts[$i..([Math]::Min($i + 499, $distinctTexts.Count - 1))])
            $values = ($chunk | ForEach-Object -Begin { $k = 0 } -Process { "($k, N'" + ([string]$_).Replace("'", "''") + "')"; $k++ }) -join ', '
            $cmd = $Connection.CreateCommand()
            $cmd.CommandText = "SELECT v.i, TRY_CONVERT($($col.ColumnType), v.s$style) FROM (VALUES $values) v(i, s);"
            $r = $cmd.ExecuteReader()
            try {
                while ($r.Read()) {
                    if ($r.IsDBNull(1)) { continue }
                    $raw = $(try { $r.GetValue(1) } catch { $r.GetSqlValue(1) })
                    # text values stay strings: the server ranks them against the profile in the column's collation later
                    $typed["$($g.Name)|$($chunk[[int]$r.GetValue(0)])"] = $(if ($col.IsText) { [string]$raw } else { [SQLStatsXRay.Builder.Profile]::Sortable($raw) })
                }
            } finally { $r.Close() }
        }
    }
    $get = { param([string]$col, $text) if ($null -eq $text) { return $null }; $typed["$col|$(& $clean $text)"] }
    foreach ($p in $pending) {
        $info = $result.Columns[$p[0]]
        if ($p[1] -eq 'eq') {
            $v = & $get $p[0] $p[2]
            if ($null -eq $v) { $info.Unread++ } else { $info.Workload.AddEquality($v, $p[3]); $info.Equality++ }
        } else {
            $lo = & $get $p[0] $p[2][0]; $hi = & $get $p[0] $p[2][2]
            if (($null -ne $p[2][0] -and $null -eq $lo) -or ($null -ne $p[2][2] -and $null -eq $hi)) { $info.Unread++; continue }
            $info.Workload.AddRange($lo, [bool]$p[2][1], $hi, [bool]$p[2][3], $p[3]); $info.Ranges++
        }
    }
    return $result
}

function Get-AdaptiveSamplePlan($Connection, $Target, [string]$Sample, [int]$Seed, [int]$TimeoutSeconds, [double]$Limit = 4, [switch]$TableOnly) {
    <#
      Our sampler. A pilot of about 64 random pages measures rows per page and how much the column's values cluster by
      page (design effect). The target is the same number of *useful* rows as SQL Server's sample, so: pages = rows x
      design effect / rows per page. The column's own index is read instead when its leaf (sorted runs of keys, denser)
      costs fewer pages. A full read stays a full read; a pilot under 8 pages falls back to SQL Server's plan.
    #>
    $base = Get-SqlServerSamplePlan $Target.Rows $Target.Pages $Sample
    $base.Sampler = 'Adaptive'; $base.Path = 'table'; $base.BasePages = $base.Pages
    if ($base.Full) { return $base }
    $pilotPct = [Math]::Min(100.0, [Math]::Max(0.0001, 100.0 * 64 / [Math]::Max(1, $Target.Pages)))
    $cmd = $Connection.CreateCommand()
    $cmd.CommandTimeout = $TimeoutSeconds
    $cmd.CommandText = "SELECT SUBSTRING(%%physloc%%, 1, 6), $($Target.ColumnSql) FROM $($Target.Table) TABLESAMPLE SYSTEM (" + $pilotPct.ToString('0.######', $script:Inv) +
    " PERCENT) REPEATABLE ($($Seed + 7919)) WITH (INDEX(0)) OPTION (KEEPFIXED PLAN, MAXDOP 1);"
    $r = $cmd.ExecuteReader()
    try { $pilot = [SQLStatsXRay.Builder.Pilot]::Analyze($r, [bool]$Target.IsText) } finally { $r.Close() }
    $base.Pilot = $pilot
    if ($pilot.Pages -lt 8 -or $pilot.RowsPerPage -le 0) { $base.Rule += '; pilot too small, SQL Server''s size kept'; return $base }
    # useful rows SQL Server's sample would hold, then the pages that give as many here
    $targetRows = $base.Pages * $Target.Rows / [Math]::Max(1, $Target.Pages)
    # Base table pages only. Sampling the leaf of the column's own index (denser, sorted runs) gave the best distinct
    # count and ranges overall, but leaves key ranges unseen between sampled pages: next to a value spanning many pages,
    # a step's range then shows one distinct value and every unseen value gets its rows (DataCheckLab.dbo.Big: 115,076x).
    $tablePages = [int64][Math]::Ceiling($targetRows * $pilot.DesignEffect / $pilot.RowsPerPage)
    $capped = $Limit -gt 0 -and $tablePages -gt $base.Pages * $Limit
    if ($capped) { $tablePages = [int64][Math]::Ceiling($base.Pages * $Limit) }
    $choice = @{ Path = 'table'; Pages = $tablePages; PathPages = $Target.Pages }
    $base.Path = $choice.Path; $base.PathPages = $choice.PathPages
    $base.Rule = Format-Invariant 'pilot {0:N0} pages: {1:0.#} rows/page (table average {2:0.#}), design effect {3:0.##}; {4:N0} useful rows as SQL Server would read{5}' `
        $pilot.Pages $pilot.RowsPerPage ($Target.Rows / [Math]::Max(1, $Target.Pages)) $pilot.DesignEffect ([Math]::Round($targetRows)) $(if ($capped) { Format-Invariant '; capped at {0}x SQL Server''s sample' $Limit } else { '' })
    if ($choice.Pages -ge $choice.PathPages) { $base.Full = $true; $base.Percent = 100.0; $base.Pages = $choice.PathPages; $base.Rule += '; the whole path is needed: full read'; return $base }
    $base.Full = $false; $base.Pages = [int64][Math]::Max(1, $choice.Pages)
    $base.Percent = 100.0 * $base.Pages / $choice.PathPages
    return $base
}

function Read-StatsBuildShared($Connection, $Target, $Columns, $Plan, [int]$Seed, [int]$TimeoutSeconds) {
    <#
      The profiles of several columns. A sample is read ONCE: its rows (and pages) are copied into a #temp table, then
      each column is grouped there, on the server; SQL Server samples the table again for every statistics object. A
      full scan reads each column on its own, grouped on the server through the narrowest index that has it (copying a
      whole table into tempdb would cost more than it saves).
    #>
    $cols = @($Columns)
    $session = $Connection.CreateCommand()
    $session.CommandTimeout = $TimeoutSeconds
    $session.CommandText = 'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED; SET LOCK_TIMEOUT 1000;'
    $null = $session.ExecuteNonQuery()
    $profiles = @{}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Plan.Full) {
            foreach ($c in $cols) { $profiles[$c.Column] = (Read-StatsBuildProfile $Connection $c $Plan $Seed $TimeoutSeconds).Profile }
        } else {
            $list = (0..($cols.Count - 1) | ForEach-Object { "$($cols[$_].ColumnSql) AS c$_" }) -join ', '
            $session.CommandText = "DROP TABLE IF EXISTS #xray_sample; SELECT SUBSTRING(%%physloc%%, 1, 6) AS pg, $list INTO #xray_sample FROM $($Target.Table) TABLESAMPLE SYSTEM (" +
            $Plan.Percent.ToString('0.######', $script:Inv) + " PERCENT) REPEATABLE ($Seed) WITH (INDEX(0)) OPTION (KEEPFIXED PLAN, MAXDOP 1);"
            $null = $session.ExecuteNonQuery()
            for ($i = 0; $i -lt $cols.Count; $i++) {
                $cmd = $Connection.CreateCommand(); $cmd.CommandTimeout = $TimeoutSeconds
                $cmd.CommandText = "SELECT c$i, COUNT_BIG(*), COUNT(DISTINCT pg) FROM #xray_sample GROUP BY c$i ORDER BY c$i OPTION (MAXDOP 1);"
                $p = New-StatsBuildProfile $cols[$i] $Connection $Plan
                $r = $cmd.ExecuteReader()
                try { $p.Read($r) } finally { $r.Close() }
                $profiles[$cols[$i].Column] = $p
            }
        }
    } finally {
        $session.CommandText = 'DROP TABLE IF EXISTS #xray_sample; SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SET LOCK_TIMEOUT -1;'
        try { $null = $session.ExecuteNonQuery() } catch { }
    }
    return [pscustomobject]@{ Profiles = $profiles; Seconds = $sw.Elapsed.TotalSeconds }
}

function Invoke-StatsBuildRefine($Connection, $Target, $Column, $Steps, [string]$IndexName, [int]$TimeoutSeconds) {
    # Two-phase: each step key's EQ_ROWS counted exactly with one seek on the column's index.
    $n = 0
    foreach ($s in $Steps) {
        $cmd = $Connection.CreateCommand(); $cmd.CommandTimeout = $TimeoutSeconds
        $keyText = Format-SqlValue $s.Raw $Column.SystemTypeId $Column.Scale
        $fake = [pscustomobject]@{ RangeHiKey = $(if ($Column.SystemTypeId -in 60, 122, 106, 108) { $keyText } else { $s.Raw }); Record = [pscustomobject]@{ KeyBytes = $null } }
        if ($Column.SystemTypeId -eq 61) { $fake.Record.KeyBytes = ConvertTo-SqlDateTimeBytes ([datetime]$s.Raw) }
        $expr = Add-DataCheckKey $cmd '@k' $Column $fake
        $cmd.CommandText = "SELECT COUNT_BIG(*) FROM $($Target.Table) WITH (INDEX([$($IndexName.Replace(']', ']]'))]), FORCESEEK) WHERE $($Target.ColumnSql) = $expr OPTION (KEEPFIXED PLAN, MAXDOP 1);"
        $s.Eq = [double]$cmd.ExecuteScalar(); $n++
    }
    return $n
}

function Invoke-StatsBuildColumn {
    <#
      The histogram of one statistics object from a profile already read: candidates from every algorithm (Workload when
      the workload has values), the current statistics scored on the same data, the best one by the objective (the
      workload when it has values, ranges when the workload filters mostly by range, equality otherwise), the adaptive
      sampler's exact EQ_ROWS, and the stream.
    #>
    param($Connection, $Target, $Template, $Profile, $Plan, [double]$TableRows, [string[]]$Algorithms, $WorkloadInfo, [int]$Seed, [int]$TimeoutSeconds)
    $p = $Profile
    if ($p.Entries.Count -eq 0) { throw "No values read from [$($Target.Column)]: the table is empty or the column is all NULL." }
    $scale = $(if ($Plan.Full -or $p.ReadRows -le 0) { 1.0 } else { $TableRows / $p.ReadRows })
    $col = $Template.Columns[0]
    $refined = 0; $index = $null; $refinedWorkload = 0; $isText = [bool]$Target.IsText
    $mmValues = @()
    if ($Plan.Sampler -eq 'Adaptive' -and -not $Plan.Full) {
        # the true minimum and maximum, with exact counts, when an index makes them cheap (the first step must be the minimum)
        $ix = Get-StatsBuildIndex $Connection $Target.ObjectId $Target.Column
        if ($ix) {
            $index = [string]$ix.name
            $mm = @((Read-ResultSets $Connection "SELECT MIN($($Target.ColumnSql)) AS lo, MAX($($Target.ColumnSql)) AS hi FROM $($Target.Table) WITH (INDEX([$($index.Replace(']', ']]'))])) OPTION (KEEPFIXED PLAN, MAXDOP 1);")[0])[0]
            $mmValues = @(@($mm.lo, $mm.hi) | Where-Object { $_ -isnot [DBNull] -and $null -ne $_ })
        }
    }
    $wq = $(if ($WorkloadInfo -and $WorkloadInfo.Workload.Count -gt 0) { $WorkloadInfo.Workload } else { $null })
    $currentKeys = @()
    if ($Target.Stat -and $Template.Label -ne 'template') { $currentKeys = @($Template.Histogram | Where-Object { -not $_.IsNullStep } | ForEach-Object { $_.RangeHiKey }) }
    # sort keys of outside values: the value itself, or for text its position among the profile's keys in the column's
    # collation (ranked once, on the server, before any value is inserted)
    $rank = New-Object 'System.Collections.Generic.Dictionary[string,double]' ([StringComparer]::Ordinal)
    if ($isText) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $outside = @($mmValues) + @($currentKeys) + $(if ($wq) { @($wq.EqValues) + @($wq.Lo) + @($wq.Hi) } else { @() })
        $texts = @($outside | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Where-Object { $seen.Add($_) })
        $ranks = Get-StatsBuildRanks $Connection $Target $p $texts
        for ($i = 0; $i -lt $texts.Count; $i++) { $rank[$texts[$i]] = $ranks[$i] }
    }
    $keyOf = { param($v) if ($null -eq $v) { return $null }; if ($isText) { return $rank[[string]$v] }; return [SQLStatsXRay.Builder.Profile]::Sortable($v) }
    if ($index) {
        foreach ($v in $mmValues) {
            $one = New-Object 'System.Collections.Generic.List[SQLStatsXRay.Builder.Step]'
            $st = New-Object SQLStatsXRay.Builder.Step; $st.Raw = $v; $st.Key = & $keyOf $v; $one.Add($st)
            $null = Invoke-StatsBuildRefine $Connection $Target $col $one $index $TimeoutSeconds
            $p.InsertExact($v, $st.Key, $st.Eq / $scale)
        }
        # the workload's equality values, heaviest first (up to 200 seeks): a sample rarely holds light values
        if ($wq -and $wq.EqValues.Count -gt 0) {
            $order = @(0..($wq.EqValues.Count - 1) | Sort-Object { $wq.EqWeights[$_] } -Descending | Select-Object -First 200)
            $one = New-Object 'System.Collections.Generic.List[SQLStatsXRay.Builder.Step]'
            # workload values are kept sortable (SqlGuid, SqlBinary, SqlDecimal); back to plain values for the seeks and keys
            $values = @($order | ForEach-Object { $v = $wq.EqValues[$_]; if ($v -is [Data.SqlTypes.SqlGuid] -or $v -is [Data.SqlTypes.SqlBinary]) { $v.Value } else { $v } })
            foreach ($v in $values) { $st = New-Object SQLStatsXRay.Builder.Step; $st.Raw = $v; $st.Key = & $keyOf $wq.EqValues[$order[$one.Count]]; $one.Add($st) }
            $null = Invoke-StatsBuildRefine $Connection $Target $col $one $index $TimeoutSeconds
            foreach ($st in $one) { if ($st.Eq -gt 0) { $p.InsertExact($st.Raw, $st.Key, $st.Eq / $scale) } }
            $refinedWorkload = $one.Count
        }
    }
    $workload = $wq
    if ($wq -and $isText) {
        # the same predicates, with ranked keys
        $workload = New-Object SQLStatsXRay.Builder.Workload
        for ($i = 0; $i -lt $wq.EqValues.Count; $i++) { $workload.AddEquality((& $keyOf $wq.EqValues[$i]), $wq.EqWeights[$i]) }
        for ($i = 0; $i -lt $wq.Lo.Count; $i++) { $workload.AddRange((& $keyOf $wq.Lo[$i]), $wq.LoInclusive[$i], (& $keyOf $wq.Hi[$i]), $wq.HiInclusive[$i], $wq.RangeWeights[$i]) }
    }
    $objective = $(if ($workload) { 'workload' } elseif ($WorkloadInfo -and $WorkloadInfo.RangeWeight -gt $WorkloadInfo.EqWeight) { 'ranges' } else { 'equality' })
    $names = @($Algorithms | Where-Object { $_ -ne 'Workload' -or $workload })
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    # every algorithm at once, in parallel (C#)
    foreach ($x in [SQLStatsXRay.Builder.Histogram]::BuildAll($p, [string[]]$names, 200, $workload, 0.5, $scale, $p.NullRows * $scale, 1000, $Seed)) {
        $candidates.Add([pscustomobject]@{ Name = $x.Name; Steps = $x.Steps; NullEq = $p.NullRows * $scale; Score = $x.Score; Seconds = $x.Seconds; Current = $false })
    }
    $current = $null
    if ($currentKeys.Count -gt 0) {
        $cs = New-Object 'System.Collections.Generic.List[SQLStatsXRay.Builder.Step]'
        foreach ($h in @($Template.Histogram | Where-Object { -not $_.IsNullStep })) {
            $x = New-Object SQLStatsXRay.Builder.Step
            $x.Key = & $keyOf $h.RangeHiKey; $x.Eq = $h.EqRows; $x.Range = $h.RangeRows; $x.Distinct = $h.DistinctRangeRows; $x.Avg = $h.AvgRangeRows
            $cs.Add($x)
        }
        $nullEq = [double]$Template.Blob.NullStepEqRows
        $score = [SQLStatsXRay.Builder.Histogram]::Evaluate($p, $cs, $nullEq, $scale, 1000, $Seed)
        [SQLStatsXRay.Builder.Histogram]::EvaluateWorkload($p, $cs, $scale, $workload, $score)
        $current = [pscustomobject]@{ Name = 'SQL Server (current)'; Steps = $cs; NullEq = $nullEq; Score = $score; Seconds = 0; Current = $true }
    }
    $best = switch ($objective) {
        'workload' { $candidates | Sort-Object { $_.Score.WorkloadP95 }, { $_.Score.WorkloadGeoMean }, { $_.Score.EqP95 } | Select-Object -First 1 }
        'ranges' { $candidates | Sort-Object { $_.Score.RangeP95 }, { $_.Score.RangeGeoMean }, { $_.Score.EqP95 } | Select-Object -First 1 }
        default { $candidates | Sort-Object { $_.Score.EqP95 }, { $_.Score.RangeGeoMean } | Select-Object -First 1 }
    }
    if ($index) { $refined = Invoke-StatsBuildRefine $Connection $Target $col $best.Steps $index $TimeoutSeconds }

    $distinct = $p.DistinctValues()
    if (-not $Plan.Full) { $distinct = [SQLStatsXRay.Builder.Histogram]::EstimateDistinct($p.SampleUnits(), $distinct, $p.ValuesSeenOnce(), $p.SampleUnits() * $scale) }
    # variable-length keys (varbinary, varchar, nvarchar): their average bytes; fixed ones: the record's key size
    $keyLength = $(if ($Target.SystemTypeId -in 165, 167, 231) { $p.DataBytes() / [Math]::Max(1, $p.ReadRows) } else {
            $rec = @($Template.Histogram | Where-Object { -not $_.IsNullStep })[0].Record
            [double]($rec.FixedEnd - 16) * $p.NonNullRows / [Math]::Max(1, $p.ReadRows) })
    $now = [datetime](Invoke-Query $Connection 'SELECT GETDATE() AS d')[0].Rows[0].d
    $built = [pscustomobject]@{
        Updated = $now; Rows = [Math]::Round($TableRows); RowsSampled = $p.ReadRows; NullRows = $p.NullRows * $scale
        AllDensity = 1.0 / [Math]::Max(1, $distinct + $(if ($p.NullRows -gt 0) { 1 } else { 0 })); AverageLength = $keyLength
        Trie = $(if ($p.Trie) { , $p.Trie.ToBytes() } else { $null })
    }
    $stream = New-StatsBuildStream $Template $best.Steps $built
    [pscustomobject]@{
        Target = $Target; Template = $Template; Plan = $Plan; Profile = $p; Scale = $scale; TableRows = $TableRows; Distinct = $distinct
        Candidates = $candidates.ToArray(); Current = $current; Best = $best; Objective = $objective; Workload = $WorkloadInfo; Refined = $refined; RefinedWorkload = $refinedWorkload; RefineIndex = $index; Stream = $stream
    }
}

function New-StatsBuildScript([string]$Database, $Items, [bool]$NoRecompute) {
    <# One script for one or more built statistics: a header, then CREATE or UPDATE per statistic, then the restore block. #>
    $q = { param([string]$Name) '[' + $Name.Replace(']', ']]') + ']' }
    $hex = { param([byte[]]$b) '0x' + [BitConverter]::ToString($b).Replace('-', '') }
    $L = New-Object 'System.Collections.Generic.List[string]'
    $L.Add('/*')
    $L.Add("  Statistics built by the SQLStatsXRay statistics builder (beta) on $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm', $script:Inv)), database $Database")
    foreach ($it in $Items) { $L.Add(''); foreach ($n in $it.Notes) { $L.Add("  $n") } }
    $L.Add('')
    $L.Add('  STATS_STREAM is undocumented and unsupported. Load built statistics on a test copy first.')
    $L.Add('  The stream holds histogram key values, which are real data: be careful where you paste or store this script.')
    $L.Add('')
    $L.Add('  Recommended: add NORECOMPUTE. Without it, the first automatic update after enough modifications')
    $L.Add('  replaces this histogram with SQL Server''s own. With it, the statistics never update by themselves:')
    $L.Add('  rebuild them when the data changes, and exclude them from maintenance jobs that update statistics.')
    $L.Add('*/')
    if ($Database) { $L.Add("USE $(& $q $Database);"); $L.Add('GO') }
    foreach ($it in $Items) {
        if ($it.IsNew) { $L.Add("CREATE STATISTICS $(& $q $it.StatName) ON $($it.Target.Table) ($(& $q $it.Target.Column))") }
        else { $L.Add("UPDATE STATISTICS $($it.Target.Table) ($(& $q $it.StatName))") }
        $L.Add("WITH STATS_STREAM = $(& $hex $it.Bytes)$(if ($NoRecompute) { ', NORECOMPUTE' });")
        $L.Add('GO')
    }
    $restore = @($Items | Where-Object { -not $_.IsNew -and $_.Original })
    if ($restore) {
        $L.Add('')
        $L.Add('/* ---- To restore the statistics as they were, run:')
        foreach ($it in $restore) {
            $L.Add("UPDATE STATISTICS $($it.Target.Table) ($(& $q $it.StatName))")
            $L.Add("WITH STATS_STREAM = $(& $hex $it.Original)$(if ($it.Target.Stat.no_recompute) { ', NORECOMPUTE' });")
        }
        $L.Add('---- */')
    }
    return ($L -join "`r`n") + "`r`n"
}

function Get-StatsBuildNotes($C, [string]$StatName) {
    $p = $C.Plan
    $sample = $(if ($p.Full) { "full read ($($p.Rule))" } else {
            Format-Invariant '{0} sampler: {1:0.###}% of {2:N0} pages of {3} ({4})' $(if ($p.Sampler -eq 'Adaptive') { 'adaptive' } else { 'SQL Server' }) $p.Percent $(if ($p.PathPages) { $p.PathPages } else { $C.Target.Pages }) $(if ($p.Path -and $p.Path -ne 'table') { "index [$($p.Path)]" } else { 'the table' }) $p.Rule })
    @(
        "[$StatName] on column [$($C.Target.Column)]: algorithm $($C.Best.Name), objective $($C.Objective)$(if ($C.Refined) { ", EQ_ROWS counted exactly for $($C.Refined) keys" })"
        "  Sample: $sample"
        (Format-Invariant '  Score: equality p95 {0:0.##}, worst {1:0.##}; ranges geometric mean {2:0.###}{3}' $C.Best.Score.EqP95 $C.Best.Score.EqMax $C.Best.Score.RangeGeoMean $(if (-not [double]::IsNaN($C.Best.Score.WorkloadP95)) { Format-Invariant '; workload p95 {0:0.##}' $C.Best.Score.WorkloadP95 } else { '' }))
    )
}

function Invoke-StatsBuild {
    <#
      Builds a histogram for one column: reads the column's values (every row, SQL Server's sample or the adaptive
      sample), reads the Query Store workload on the column, runs the histogram algorithms, scores every candidate and
      the current statistics against the rows read, and writes the script that loads the best candidate. Nothing is
      changed on the server.
    #>
    param($Connection, [string]$Database, [string]$TableName, [string]$StatName, [string]$ColumnName, [string]$Sample = 'Default',
        [string]$Sampler = 'SqlServer', [string[]]$Algorithms, [string]$NewStatName, [bool]$NoRecompute, [int]$Seed = 1, [int]$TimeoutSeconds = 0, [bool]$UseWorkload = $true, [double]$AdaptiveLimit = 4)
    Initialize-StatsBuilder
    if (-not $Algorithms) { $Algorithms = 'EqualRows', 'MaxDiff', 'FrequentFirst', 'VOptimal', 'Workload' }
    $target = Get-StatsBuildTarget $Connection $TableName $StatName $ColumnName
    $template = Get-StatsBuildTemplate $Connection $target
    $plan = $(if ($Sampler -eq 'Adaptive') { Get-AdaptiveSamplePlan $Connection $target $Sample $Seed $TimeoutSeconds $AdaptiveLimit } else { $x = Get-SqlServerSamplePlan $target.Rows $target.Pages $Sample; $x.Sampler = 'SqlServer'; $x })
    $read = Read-StatsBuildProfile $Connection $target $plan $Seed $TimeoutSeconds
    $tableRows = $(if ($plan.Full) { $read.Profile.ReadRows } else { [double]$target.Rows })
    $wl = $null; $wlStatus = 'not read'
    if ($UseWorkload) {
        $w = Get-StatsBuildWorkload $Connection $target.SchemaName $target.TableName @([pscustomobject]@{ Name = $target.Column; ColumnType = $target.ColumnType; SystemTypeId = $target.SystemTypeId; IsText = $target.IsText })
        $wl = $w.Columns[$target.Column]; $wlStatus = $w.Status
    }
    $c = Invoke-StatsBuildColumn $Connection $target $template $read.Profile $plan $tableRows $Algorithms $wl $Seed $TimeoutSeconds
    $isNew = -not $target.Stat
    $statName = $(if ($isNew) { $(if ($NewStatName) { $NewStatName } else { "xray_$($target.Column)" }) } else { $target.StatName })
    $item = [pscustomobject]@{ Target = $target; Bytes = $c.Stream.Bytes; StatName = $statName; IsNew = $isNew; Original = $(if ($c.Current) { [byte[]]$template.Raw }); Notes = (Get-StatsBuildNotes $c $statName) }
    $c | Add-Member ReadSeconds $read.Seconds
    $c | Add-Member WorkloadStatus $wlStatus
    $c | Add-Member StatName $statName
    $c | Add-Member IsNew $isNew
    $c | Add-Member Script (New-StatsBuildScript $Database @($item) $NoRecompute)
    return $c
}

function Invoke-StatsBuildTable {
    <#
      Builds every statistics object of a table the builder supports from ONE read of the table (SQL Server reads it
      once per statistics object): the whole table, or one sample of its base pages. Each column's profile serves every
      statistics object on that column.
    #>
    param($Connection, [string]$Database, [string]$TableName, [string]$Sample = 'Default', [string]$Sampler = 'SqlServer', [string[]]$Algorithms,
        [bool]$NoRecompute, [int]$Seed = 1, [int]$TimeoutSeconds = 0, [bool]$UseWorkload = $true, [double]$AdaptiveLimit = 4)
    Initialize-StatsBuilder
    if (-not $Algorithms) { $Algorithms = 'EqualRows', 'MaxDiff', 'FrequentFirst', 'VOptimal', 'Workload' }
    $all = Get-StatsTargets $Connection $TableName $null
    $eligible = New-Object 'System.Collections.Generic.List[object]'; $skipped = New-Object 'System.Collections.Generic.List[object]'
    foreach ($st in $all.Stats) {
        $name = [string]$st.name
        try {
            $t = Get-StatsBuildTarget $Connection $TableName $name $null 3>$null
            $tpl = Get-StatsBuildTemplate $Connection $t
            if ($tpl.Label -eq 'template') { throw 'the statistics are empty (no histogram to replace).' }
            $eligible.Add([pscustomobject]@{ Name = $name; Target = $t; Template = $tpl })
        } catch { $skipped.Add([pscustomobject]@{ Name = $name; Reason = $_.Exception.Message }) }
    }
    if ($eligible.Count -eq 0) { throw "No statistics object on $TableName can be built: $(($skipped | ForEach-Object { "$($_.Name): $($_.Reason)" }) -join ' | ')" }
    $first = $eligible[0].Target
    $columns = @($eligible | ForEach-Object { $_.Target } | Group-Object Column | ForEach-Object { $_.Group[0] })
    if ($Sampler -eq 'Adaptive') {
        # one shared sample of base pages: the largest size any column needs
        $plans = @($columns | ForEach-Object { Get-AdaptiveSamplePlan $Connection $_ $Sample $Seed $TimeoutSeconds $AdaptiveLimit -TableOnly })
        $plan = $plans | Sort-Object { $_.Pages } -Descending | Select-Object -First 1
        $plan.Rule = "largest of the columns' needs; " + $plan.Rule
    } else { $plan = Get-SqlServerSamplePlan $first.Rows $first.Pages $Sample; $plan.Sampler = 'SqlServer' }
    $read = Read-StatsBuildShared $Connection $first $columns $plan $Seed $TimeoutSeconds
    $anyProfile = @($read.Profiles.Values)[0]
    $tableRows = $(if ($plan.Full) { $anyProfile.ReadRows } else { [double]$first.Rows })
    $w = $null
    if ($UseWorkload) { $w = Get-StatsBuildWorkload $Connection $first.SchemaName $first.TableName @($columns | ForEach-Object { [pscustomobject]@{ Name = $_.Column; ColumnType = $_.ColumnType; SystemTypeId = $_.SystemTypeId; IsText = $_.IsText } }) }
    $results = New-Object 'System.Collections.Generic.List[object]'; $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $eligible) {
        try {
            $c = Invoke-StatsBuildColumn $Connection $e.Target $e.Template $read.Profiles[$e.Target.Column] $plan $tableRows $Algorithms $(if ($w) { $w.Columns[$e.Target.Column] }) $Seed $TimeoutSeconds
            $c | Add-Member StatName $e.Name
            $c | Add-Member Usage $(if ($w -and $w.StatsUsage.ContainsKey($e.Name)) { $w.StatsUsage[$e.Name] } else { 0 })
            $results.Add($c)
            $items.Add([pscustomobject]@{ Target = $e.Target; Bytes = $c.Stream.Bytes; StatName = $e.Name; IsNew = $false; Original = [byte[]]$e.Template.Raw; Notes = (Get-StatsBuildNotes $c $e.Name) })
        } catch { $skipped.Add([pscustomobject]@{ Name = $e.Name; Reason = $_.Exception.Message }) }
    }
    [pscustomobject]@{
        Table = $first.Table; Target = $first; Plan = $plan; ReadSeconds = $read.Seconds; TableRows = $tableRows; RowsRead = $anyProfile.ReadRows; Columns = $columns.Count
        Results = $results.ToArray(); Skipped = $skipped.ToArray(); WorkloadStatus = $(if ($w) { $w.Status } else { 'not read' })
        Script = $(if ($items.Count) { New-StatsBuildScript $Database $items.ToArray() $NoRecompute } else { '' })
    }
}

function Format-StatsBuildSample($Plan, $Target) {
    if ($Plan.Full) { return "every row ($($Plan.Rule))" }
    $of = $(if ($Plan.Path -and $Plan.Path -ne 'table') { "leaf pages of index [$($Plan.Path)]" } else { 'table pages' })
    Format-Invariant '{0} sampler: {1:0.###}% of {2:N0} {3} = {4:N0} pages{5}; {6}' $(if ($Plan.Sampler -eq 'Adaptive') { 'Adaptive' } else { 'SQL Server' }) $Plan.Percent `
        $(if ($Plan.PathPages) { $Plan.PathPages } else { $Target.Pages }) $of $Plan.Pages $(if ($Plan.Sampler -eq 'Adaptive') { Format-Invariant " (SQL Server would read {0:N0})" $Plan.BasePages } else { '' }) $Plan.Rule
}

function Format-StatsBuildCandidates($C) {
    $hasWorkload = @(@($C.Current) + @($C.Candidates) | Where-Object { $_ -and -not [double]::IsNaN($_.Score.WorkloadP95) }).Count -gt 0
    $rows = foreach ($x in @($C.Current) + @($C.Candidates) | Where-Object { $_ }) {
        $s = $x.Score
        $o = [ordered]@{
            Candidate = $x.Name + $(if ($x -eq $C.Best) { '  <- best' } else { '' }); Steps = @($x.Steps).Count + $(if ($x.NullEq -gt 0) { 1 } else { 0 })
            'Eq p95' = Format-Invariant '{0:0.##}' $s.EqP95; 'Eq worst' = Format-Invariant '{0:0.##}' $s.EqMax; 'Eq geo mean' = Format-Invariant '{0:0.###}' $s.EqGeoMean
            'Eq p95 by rows' = Format-Invariant '{0:0.##}' $s.EqP95ByRows; 'Values >10x' = Format-Invariant '{0:N0}' $s.ValuesOver10
            'Range p95' = Format-Invariant '{0:0.##}' $s.RangeP95; 'Range geo mean' = Format-Invariant '{0:0.###}' $s.RangeGeoMean
        }
        if ($hasWorkload) { $o['Workload p95'] = Format-Invariant '{0:0.##}' $s.WorkloadP95; $o['Workload geo mean'] = Format-Invariant '{0:0.###}' $s.WorkloadGeoMean }
        [pscustomobject]$o
    }
    $cols = @($rows[0].PSObject.Properties.Name)
    return , (Format-AsciiTable -Rows $rows -Columns $cols -RightAlign ($cols | Select-Object -Skip 1))
}

function Get-StatsBuildVerdict($C) {
    <#
      The built histogram against SQL Server's current statistics, on the measure the best one was chosen by:
      Better, Same (within 5%), Worse, or New (nothing to compare with). Any other measure that gets more than 25%
      worse is named, so a win on equality cannot hide a loss on ranges.
    #>
    $measures = [ordered]@{ equality = @('EqP95', 'equality estimates'); ranges = @('RangeP95', 'range estimates'); workload = @('WorkloadP95', 'the workload''s estimates') }
    $m = $measures[$C.Objective]
    $built = $C.Best.Score.($m[0])
    if (-not $C.Current) {
        return [pscustomobject]@{ Level = 'New'; Short = 'New'; Text = Format-Invariant 'New statistics: nothing to compare with. 95% of {0} are within {1:0.##}x of the real count.' $m[1] $built }
    }
    $now = $C.Current.Score.($m[0])
    $level = $(if ($built -le $now / 1.05) { 'Better' } elseif ($built -le $now * 1.05) { 'Same' } else { 'Worse' })
    $worse = foreach ($k in $measures.Keys) {
        if ($k -eq $C.Objective) { continue }
        $x = $measures[$k]; $nb = $C.Best.Score.($x[0]); $nc = $C.Current.Score.($x[0])
        if (-not [double]::IsNaN($nb) -and -not [double]::IsNaN($nc) -and $nb -gt $nc * 1.25) { Format-Invariant '{0} get worse ({1:0.##}x -> {2:0.##}x)' $x[1] $nc $nb }
    }
    $text = switch ($level) {
        'Better' { Format-Invariant 'Better than the current statistics: {0} at the 95th percentile go from {1:0.##}x off to {2:0.##}x.' $m[1] $now $built }
        'Same' { Format-Invariant 'About as good as the current statistics ({0} at the 95th percentile: {1:0.##}x now, {2:0.##}x built); loading it gains little.' $m[1] $now $built }
        default { Format-Invariant 'Not better than the current statistics: {0} at the 95th percentile go from {1:0.##}x off to {2:0.##}x. Loading it is not recommended.' $m[1] $now $built }
    }
    if ($worse) { $text += ' But ' + (@($worse) -join ' and ') + '.' }
    if (-not $C.Plan.Full) { $text += ' Measured against the sample.' }
    [pscustomobject]@{ Level = $level; Short = $level + $(if ($worse -and $level -ne 'Worse') { ' (but worse on some)' } else { '' }); Text = $text }
}

function Format-StatsBuildComparison($C) {
    # The chosen histogram next to SQL Server's current statistics, in words.
    $hasWorkload = @(@($C.Current) + @($C.Best) | Where-Object { $_ -and -not [double]::IsNaN($_.Score.WorkloadP95) }).Count -gt 0
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $add = {
        param([string]$Label, [string]$Property, [string]$Format)
        $o = [ordered]@{ Measure = $Label }
        if ($C.Current) { $o['Now (SQL Server)'] = Format-Invariant $Format $C.Current.Score.$Property }
        $o["Built ($($C.Best.Name))"] = Format-Invariant $Format $C.Best.Score.$Property
        $rows.Add([pscustomobject]$o)
    }
    & $add 'Equality: 95% of values within' EqP95 '{0:0.##}x'
    & $add 'Equality: worst value' EqMax '{0:0.##}x'
    & $add 'Equality: values off by more than 10x' ValuesOver10 '{0:N0}'
    & $add 'Ranges: 95% of ranges within' RangeP95 '{0:0.##}x'
    if ($hasWorkload) { & $add 'Workload: 95% of executions within' WorkloadP95 '{0:0.##}x' }
    $o = [ordered]@{ Measure = 'Histogram steps' }
    foreach ($x in @($C.Current) + @($C.Best) | Where-Object { $_ }) { $o[$(if ($x.Current) { 'Now (SQL Server)' } else { "Built ($($C.Best.Name))" })] = Format-Invariant '{0:N0}' (@($x.Steps).Count + $(if ($x.NullEq -gt 0) { 1 } else { 0 })) }
    $rows.Add([pscustomobject]$o)
    $cols = @($rows[0].PSObject.Properties.Name)
    return , (Format-AsciiTable -Rows $rows -Columns $cols -RightAlign ($cols | Select-Object -Skip 1))
}

function Format-StatsBuildWorkload($W, [string]$Status) {
    if (-not $W) { return "Query Store: $Status" }
    Format-Invariant 'Query Store: {0} {1} plan(s) filter on the column; {2:N0} equality value(s) and {3:N0} range(s) read, {4:N0} predicate(s) without a usable value (variables, expressions). Equality weight {5:N0}, range weight {6:N0} (executions).' `
        $Status $W.Plans $W.Equality $W.Ranges $W.Unread $W.EqWeight $W.RangeWeight
}

function Format-StatsBuildReport($B, [switch]$ShowCandidates) {
    # The verdict first, then the chosen histogram next to the current statistics; every candidate only on request.
    $t = $B.Target
    $out = @()
    $out += New-Section "STATISTICS BUILDER (BETA): $($t.Table).$('[' + $t.Column + ']') ($($t.ColumnType))"
    # the verdict, wrapped at 130 characters
    $line = ''
    foreach ($word in ((Get-StatsBuildVerdict $B).Text -split ' ')) {
        if ($line -and $line.Length + 1 + $word.Length -gt 130) { $out += $line; $line = $word } else { $line = ($line + ' ' + $word).TrimStart() }
    }
    $out += $line
    $out += ''
    $info = [ordered]@{
        'Target'          = $(if ($B.IsNew) { "new statistics [$($B.StatName)]" } else { "existing statistics [$($B.StatName)]" })
        'Sample'          = Format-StatsBuildSample $B.Plan $t
        'Rows read'       = Format-Invariant '{0:N0} of {1:N0}, {2:N0} NULL ({3:0.0} s)' $B.Profile.ReadRows $B.TableRows $B.Profile.NullRows $B.ReadSeconds
        'Distinct values' = Format-Invariant '{0:N0}{1}' $B.Distinct $(if ($B.Plan.Full) { '' } else { ' (estimated from the sample)' })
        'Histogram'       = "$($B.Best.Name), the best of $(@($B.Candidates).Count) algorithm(s) on $(switch ($B.Objective) { 'workload' { 'the Query Store workload''s estimates' } 'ranges' { 'range estimates (the workload filters mostly by range)' } default { 'equality estimates per distinct value' } })"
    }
    if ($B.Refined) { $info['Exact counts'] = "EQ_ROWS of the $($B.Refined) step keys counted with seeks on [$($B.RefineIndex)]; true minimum and maximum added$(if ($B.RefinedWorkload) { "; $($B.RefinedWorkload) workload values counted before choosing the steps" })" }
    if ($B.Profile.Compacted) { $info['Memory'] = 'light values merged to bound memory: scores inside merged runs are approximate' }
    $out += Format-KeyValueTable $info
    $out += Format-StatsBuildWorkload $B.Workload $B.WorkloadStatus
    $out += ''
    $out += 'Estimate accuracy against the rows read: how many times an estimate is off from the real count (1x = exact).'
    $out += Format-StatsBuildComparison $B
    if (-not $B.Plan.Full) {
        $out += 'These scores are measured against the sample, not the table. They favour histograms that underestimate distinct values (each value'
        $out += 'the sample saw looks at least "scale" rows big), which can make SQL Server''s current statistics look better than they are.'
        $out += 'For a verdict, score the loaded statistics against a full scan (-Statistics <name> -Build -Sample FULLSCAN).'
    }
    if ($ShowCandidates) {
        $out += ''
        $out += 'Every algorithm tried, scored by q-error (1 = exact); equality per distinct value, ranges over 1,000 random ranges, workload by executions:'
        $out += Format-StatsBuildCandidates $B
    } elseif (@($B.Candidates).Count -gt 1) {
        $out += "Also tried: $((@($B.Candidates | Where-Object { $_ -ne $B.Best } | ForEach-Object Name)) -join ', ') (-ShowCandidates lists their scores)."
    }
    foreach ($w in $B.Stream.Warnings) { $out += "Note: $w" }
    $out += "The script $(if ($B.IsNew) { 'creates' } else { 'updates' }) [$($B.StatName)] with the $($B.Best.Name) histogram. Nothing was changed on the server; NORECOMPUTE is recommended (see the script)."
    return , $out
}

function Format-StatsBuildTableReport($T, [switch]$ShowCandidates) {
    $out = @()
    $out += New-Section "STATISTICS BUILDER (BETA): every statistics object of $($T.Table), from one read"
    $verdicts = @{}
    foreach ($c in @($T.Results)) { $verdicts[$c.StatName] = Get-StatsBuildVerdict $c }
    if (@($T.Results).Count) {
        $count = { param($l) @($verdicts.Values | Where-Object Level -eq $l).Count }
        $out += Format-Invariant '{0} better than the current statistics, {1} about the same, {2} not better, {3} new. Loading the ones that are not better is not recommended.' (& $count 'Better') (& $count 'Same') (& $count 'Worse') (& $count 'New')
        $out += ''
    }
    $out += Format-KeyValueTable ([ordered]@{
            'Sample'     = Format-StatsBuildSample $T.Plan $T.Target
            'Rows read'  = Format-Invariant '{0:N0} of {1:N0}, {2} column(s), one read ({3:0.0} s); SQL Server reads the table once per statistics object' $T.RowsRead $T.TableRows $T.Columns $T.ReadSeconds
            'Built'      = "$(@($T.Results).Count) statistics object(s)"
            'Skipped'    = "$(@($T.Skipped).Count)"
            'Workload'   = $T.WorkloadStatus
        })
    if (@($T.Results).Count) {
        $rows = foreach ($c in $T.Results) {
            [pscustomobject]@{
                Statistics = $c.StatName; Column = $c.Target.Column; Verdict = $verdicts[$c.StatName].Short; Algorithm = $c.Best.Name; 'Chosen on' = $c.Objective
                'Equality now' = $(if ($c.Current) { Format-Invariant '{0:0.##}x' $c.Current.Score.EqP95 } else { '' }); 'Equality built' = Format-Invariant '{0:0.##}x' $c.Best.Score.EqP95
                'Ranges now' = $(if ($c.Current) { Format-Invariant '{0:0.##}x' $c.Current.Score.RangeP95 } else { '' }); 'Ranges built' = Format-Invariant '{0:0.##}x' $c.Best.Score.RangeP95
                'Used by (executions)' = Format-Invariant '{0:N0}' $c.Usage
            }
        }
        $out += ''
        $out += 'Estimate accuracy against the rows read: 95% of values (equality) or of random ranges are within this many times the real count (1x = exact).'
        $out += Format-AsciiTable -Rows $rows -Columns Statistics, Column, Verdict, Algorithm, 'Chosen on', 'Equality now', 'Equality built', 'Ranges now', 'Ranges built', 'Used by (executions)' -RightAlign 'Equality now', 'Equality built', 'Ranges now', 'Ranges built', 'Used by (executions)'
        if (-not $T.Plan.Full) { $out += 'Measured against the sample, not the table: for a verdict, score the loaded statistics with -Sample FULLSCAN.' }
        foreach ($c in @($T.Results)) {
            if ($verdicts[$c.StatName].Level -ne 'New') { $out += "  [$($c.StatName)]: $($verdicts[$c.StatName].Text)" }
        }
        if ($ShowCandidates) {
            foreach ($c in @($T.Results)) {
                $out += ''
                $out += "[$($c.StatName)]: every algorithm tried, scored by q-error (1 = exact):"
                $out += Format-StatsBuildCandidates $c
            }
        } else { $out += 'Every algorithm''s scores: -ShowCandidates.' }
    }
    if (@($T.Skipped).Count) {
        $out += ''
        $out += 'Skipped:'
        $out += @($T.Skipped | ForEach-Object { "  $($_.Name): $($_.Reason)" })
    }
    $out += 'Nothing was changed on the server; the script updates the statistics built (NORECOMPUTE is recommended, see the script).'
    return , $out
}

#endregion

#region ---------------------------------------------------------------- windows forms app

# Native dark chrome, the same skin as the Security Review app (SQLSecReview.Forms.NativeTheme.cs):
# dark title bar, dark scroll bars, and painted borders, combo boxes, tabs, group boxes and progress bars.
$script:GuiNativeTheme = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;
using System.Windows.Forms;
namespace StatsStreamDecoder.Appearance {
 public sealed class MenuColors : ProfessionalColorTable {
  readonly Color back, surface, hover, border;
  public MenuColors(bool dark) {
   UseSystemColors=false;
   back=dark?Color.FromArgb(32,36,43):Color.FromArgb(246,248,251);
   surface=dark?Color.FromArgb(41,47,56):Color.White;
   hover=dark?Color.FromArgb(64,101,143):Color.FromArgb(214,228,245);
   border=dark?Color.FromArgb(70,81,95):Color.FromArgb(203,211,222);
  }
  public override Color MenuStripGradientBegin{get{return back;}}
  public override Color MenuStripGradientEnd{get{return back;}}
  public override Color StatusStripGradientBegin{get{return back;}}
  public override Color StatusStripGradientEnd{get{return back;}}
  public override Color ToolStripGradientBegin{get{return back;}}
  public override Color ToolStripGradientMiddle{get{return back;}}
  public override Color ToolStripGradientEnd{get{return back;}}
  public override Color ToolStripBorder{get{return border;}}
  public override Color ToolStripDropDownBackground{get{return surface;}}
  public override Color ImageMarginGradientBegin{get{return surface;}}
  public override Color ImageMarginGradientMiddle{get{return surface;}}
  public override Color ImageMarginGradientEnd{get{return surface;}}
  public override Color MenuBorder{get{return border;}}
  public override Color MenuItemBorder{get{return hover;}}
  public override Color MenuItemSelected{get{return hover;}}
  public override Color MenuItemSelectedGradientBegin{get{return hover;}}
  public override Color MenuItemSelectedGradientEnd{get{return hover;}}
  public override Color MenuItemPressedGradientBegin{get{return surface;}}
  public override Color MenuItemPressedGradientMiddle{get{return surface;}}
  public override Color MenuItemPressedGradientEnd{get{return surface;}}
  public override Color SeparatorDark{get{return border;}}
  public override Color SeparatorLight{get{return border;}}
  public override Color CheckBackground{get{return hover;}}
  public override Color CheckSelectedBackground{get{return hover;}}
  public override Color CheckPressedBackground{get{return hover;}}
  public override Color ButtonSelectedHighlight{get{return hover;}}
  public override Color ButtonSelectedBorder{get{return hover;}}
 }
 public sealed class Skin : NativeWindow {
  static readonly ConditionalWeakTable<Control,Skin> skins=new ConditionalWeakTable<Control,Skin>();
  readonly Control control; bool dark; readonly Timer animation;
  [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left,Top,Right,Bottom; }
  [StructLayout(LayoutKind.Sequential)] struct ComboInfo { public int Size; public Rect Item,Button; public int State; public IntPtr Combo,Edit,List; }
  [DllImport("user32.dll")] static extern bool GetComboBoxInfo(IntPtr h,ref ComboInfo info);
  static readonly Color Background=Color.FromArgb(32,36,43), Surface=Color.FromArgb(41,47,56), Border=Color.FromArgb(70,81,95), Accent=Color.FromArgb(145,201,255);
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h,int attribute,ref int value,int size);
  [DllImport("uxtheme.dll",CharSet=CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h,string app,string sub);
  [DllImport("user32.dll")] static extern IntPtr GetWindowDC(IntPtr h);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h,IntPtr dc);
  [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr h,IntPtr rect,IntPtr region,uint flags);
  Skin(Control c) {
   control=c;c.HandleCreated+=delegate{Attach();};c.HandleDestroyed+=delegate{ReleaseHandle();};
   c.GotFocus+=delegate{Refresh();};c.LostFocus+=delegate{Refresh();};
   if(c is ProgressBar){animation=new Timer();animation.Interval=80;animation.Tick+=delegate{if(dark&&c.Visible&&((ProgressBar)c).Style==ProgressBarStyle.Marquee)c.Invalidate();};animation.Start();}
   c.Disposed+=delegate{if(animation!=null)animation.Dispose();ReleaseHandle();};
  }
  public static void Apply(Control c,bool value) {var s=skins.GetValue(c,x=>new Skin(x));s.dark=value;if(c.IsHandleCreated)s.Attach();}
  void Attach(){if(Handle!=control.Handle)AssignHandle(control.Handle);NativeTheme();Refresh();}
  void NativeTheme(){
   if(control is Form){int on=dark?1:0;DwmSetWindowAttribute(Handle,20,ref on,4);int bg=dark?0x002B2420:-1,fg=dark?0x00F0EAE6:-1;DwmSetWindowAttribute(Handle,35,ref bg,4);DwmSetWindowAttribute(Handle,36,ref fg,4);}
   else {SetWindowTheme(Handle,dark?"DarkMode_Explorer":null,null);if(control is ComboBox){var info=new ComboInfo();info.Size=Marshal.SizeOf(typeof(ComboInfo));if(GetComboBoxInfo(Handle,ref info)){if(info.List!=IntPtr.Zero)SetWindowTheme(info.List,dark?"DarkMode_Explorer":null,null);if(info.Edit!=IntPtr.Zero)SetWindowTheme(info.Edit,dark?"DarkMode_Explorer":null,null);}}}
  }
  void Refresh(){if(Handle!=IntPtr.Zero){control.Invalidate();RedrawWindow(Handle,IntPtr.Zero,IntPtr.Zero,0x401);}}
  bool HasBorder(){return (control is TextBoxBase && ((TextBoxBase)control).BorderStyle!=BorderStyle.None)||(control is Panel && ((Panel)control).BorderStyle!=BorderStyle.None)||(control is ListBox && ((ListBox)control).BorderStyle!=BorderStyle.None)||control is UpDownBase||control is ComboBox||control is DataGridView;}
  protected override void WndProc(ref Message m){
   base.WndProc(ref m);
   if(!dark||control.IsDisposed)return;
   if(m.Msg==0x85 && HasBorder()) {IntPtr dc=GetWindowDC(Handle);if(dc!=IntPtr.Zero){try{using(var g=Graphics.FromHdc(dc))PaintBorder(g,new Rectangle(0,0,control.Width,control.Height));}finally{ReleaseDC(Handle,dc);}}}
   if(m.Msg==0xF || m.Msg==0x318 || m.Msg==0x317 || (control is ProgressBar && (m.Msg==0x402 || m.Msg==0x403 || m.Msg==0x405 || m.Msg==0x406))){
    using(var g=(m.Msg==0x318 || m.Msg==0x317) && m.WParam!=IntPtr.Zero?Graphics.FromHdc(m.WParam):Graphics.FromHwnd(Handle)){PaintClient(g);if(m.Msg==0x317 && HasBorder())PaintBorder(g,new Rectangle(0,0,control.Width,control.Height));}
   }
  }
  void PaintBorder(Graphics g,Rectangle r){if(r.Width<4||r.Height<4)return;using(var p=new Pen(control.ContainsFocus?Accent:Border)){g.DrawRectangle(p,r.X,r.Y,r.Width-1,r.Height-1);g.DrawRectangle(p,r.X+1,r.Y+1,r.Width-3,r.Height-3);}}
  void Arrow(Graphics g,Rectangle r,bool up){using(var b=new SolidBrush(Surface))g.FillRectangle(b,r);int x=r.X+r.Width/2,y=r.Y+r.Height/2;using(var b=new SolidBrush(control.Enabled?Color.FromArgb(230,234,240):Color.Gray))g.FillPolygon(b,up?new[]{new Point(x-3,y+2),new Point(x+3,y+2),new Point(x,y-2)}:new[]{new Point(x-3,y-2),new Point(x+3,y-2),new Point(x,y+2)});}
  void PaintClient(Graphics g){
   var tabs=control as TabControl;
   if(tabs!=null){PaintTabs(g,tabs);return;}
   var r=control.ClientRectangle;var progress=control as ProgressBar;
   var group=control as GroupBox;
   if(group!=null){
    var saved=g.Save();
    foreach(Control child in group.Controls)if(child.Visible)g.ExcludeClip(child.Bounds);
    using(var b=new SolidBrush(Background))g.FillRectangle(b,r);
    int top=group.Font.Height/2;
    using(var p=new Pen(Border))g.DrawRectangle(p,0,top,Math.Max(0,r.Width-1),Math.Max(0,r.Height-top-1));
    var size=TextRenderer.MeasureText(group.Text,group.Font);
    using(var b=new SolidBrush(Background))g.FillRectangle(b,7,0,size.Width+4,size.Height);
    TextRenderer.DrawText(g,group.Text,group.Font,new Point(9,0),group.ForeColor,Background);
    g.Restore(saved);
    return;
   }
   if(progress!=null){using(var b=new SolidBrush(Surface))g.FillRectangle(b,r);int w=r.Width;
    if(progress.Style==ProgressBarStyle.Marquee){int span=Math.Max(20,w/5);int x=(int)((Environment.TickCount&int.MaxValue)/12%(Math.Max(1,w+span)))-span;using(var b=new SolidBrush(Accent))g.FillRectangle(b,x,2,span,Math.Max(0,r.Height-4));}
    else {int fill=(int)(w*(progress.Value-progress.Minimum)/(double)Math.Max(1,progress.Maximum-progress.Minimum));using(var b=new SolidBrush(Accent))g.FillRectangle(b,0,2,fill,Math.Max(0,r.Height-4));}PaintBorder(g,r);return;
   }
   var combo=control as ComboBox;
   if(combo!=null){int width=SystemInformation.VerticalScrollBarWidth+3;
    if(combo.DropDownStyle==ComboBoxStyle.DropDownList){
     using(var b=new SolidBrush(Surface))g.FillRectangle(b,r);
     var text=new Rectangle(4,2,Math.Max(0,r.Width-width-6),Math.Max(0,r.Height-4));
     TextRenderer.DrawText(g,combo.Text,combo.Font,text,combo.Enabled?combo.ForeColor:Color.Gray,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);
     if(combo.Focused)ControlPaint.DrawFocusRectangle(g,text,combo.ForeColor,Surface);
    }
    Arrow(g,new Rectangle(Math.Max(0,r.Width-width),0,width,r.Height),false);PaintBorder(g,r);
   }
   if(control.GetType().Name=="UpDownButtons"){Arrow(g,new Rectangle(0,0,r.Width,r.Height/2),true);Arrow(g,new Rectangle(0,r.Height/2,r.Width,r.Height-r.Height/2),false);}
   if(control is UpDownBase)PaintBorder(g,r);
  }
  void PaintTabs(Graphics g,TabControl tabs){
   var saved=g.Save();
   try {
    g.ExcludeClip(tabs.DisplayRectangle);
    using(var b=new SolidBrush(Background))g.FillRectangle(b,tabs.ClientRectangle);
    var page=tabs.DisplayRectangle;page.Inflate(1,1);
    using(var p=new Pen(Border))g.DrawRectangle(p,page.X,page.Y,Math.Max(0,page.Width-1),Math.Max(0,page.Height-1));
    for(int i=0;i<tabs.TabCount;i++){
     var r=tabs.GetTabRect(i);bool selected=i==tabs.SelectedIndex;
     using(var b=new SolidBrush(selected?Color.FromArgb(52,61,73):Background))g.FillRectangle(b,r);
     using(var p=new Pen(Border))g.DrawRectangle(p,r.X,r.Y,Math.Max(0,r.Width-1),Math.Max(0,r.Height-1));
     var text=r;text.Inflate(-4,-2);
     TextRenderer.DrawText(g,tabs.TabPages[i].Text,tabs.Font,text,tabs.ForeColor,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.PreserveGraphicsClipping);
     if(selected&&tabs.Focused){var focus=r;focus.Inflate(-3,-3);ControlPaint.DrawFocusRectangle(g,focus,tabs.ForeColor,Background);}
    }
   } finally {g.Restore(saved);}
  }
 }
 public static class Cue {
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h,int msg,IntPtr w,string l);
  public static void Set(TextBox box,string text){SendMessage(box.Handle,0x1501,(IntPtr)1,text);}
 }
}
'@

$script:AppVersion = '1.0.0'
$script:AppProjectUrl = 'https://github.com/mcflyamorim/SQLStatsXRay'

function Write-GuiStartup([string]$Text) {
    # Startup progress in the console behind the window (same format as SQLSecReview): seconds since the
    # process started, so a slow start shows where the time goes.
    if (-not $script:GuiStartedAt) { return }
    Write-Host ('[{0,5:n1} s] {1}' -f ([DateTime]::Now - $script:GuiStartedAt).TotalSeconds, $Text)
}

function Get-GuiSettingsPath([switch]$Legacy) {
    # the app was called Decode-StatsStream before SQLStatsXRay; its settings are read once if no new file exists
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $(if ($Legacy) { 'Decode-StatsStream\settings.json' } else { 'SQLStatsXRay\settings.json' })
}

function Get-GuiDefaultSettings {
    return [ordered]@{
        Theme = 'Dark'; ServerInstance = ''; Servers = @(); SqlAuthentication = $false; Login = ''; TrustServerCertificate = $true
        Validate = $true; UseDac = $false; HexDump = $false; FullPrecision = $false; StringIndexNodes = 300; SampledScanValues = 20; TrieOrientation = 'LeftToRight'
        CheckPageBudget = 100000; CheckTimeout = 60; CheckStepDelay = 0
    }
}

function Read-GuiSettings {
    $settings = Get-GuiDefaultSettings
    try {
        $path = Get-GuiSettingsPath
        if (-not (Test-Path -LiteralPath $path)) { $path = Get-GuiSettingsPath -Legacy }
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($prop in $saved.PSObject.Properties) { if ($settings.Contains($prop.Name)) { $settings[$prop.Name] = $prop.Value } }
    } catch { }
    $settings.Servers = @($settings.Servers | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if ($settings.Theme -notin 'Light', 'Dark') { $settings.Theme = 'Dark' }
    if ($settings.TrieOrientation -notin 'TopDown', 'LeftToRight') { $settings.TrieOrientation = 'LeftToRight' }
    foreach ($k in 'StringIndexNodes', 'SampledScanValues') { $settings[$k] = [int][Math]::Min([Math]::Max(0, [int]$settings[$k]), 1000000) }
    $settings.CheckPageBudget = [long][Math]::Min([Math]::Max(1, [long]$settings.CheckPageBudget), 1000000000)
    $settings.CheckTimeout = [int][Math]::Min([Math]::Max(1, [int]$settings.CheckTimeout), 3600)
    $settings.CheckStepDelay = [int][Math]::Min([Math]::Max(0, [int]$settings.CheckStepDelay), 60000)
    return $settings
}

function Save-GuiSettings {
    # The password is never saved.
    $settings = $script:App.Settings
    $settings.Theme = $script:GuiTheme
    try {
        $path = Get-GuiSettingsPath
        $null = [IO.Directory]::CreateDirectory((Split-Path $path -Parent))
        [IO.File]::WriteAllText($path, ($settings | ConvertTo-Json))
    } catch { }
}

function Get-GuiPalette {
    # Same palette as the Security Review app.
    if ($script:GuiTheme -eq 'Dark') { $hex = '20242B', '292F38', 'E6EAF0', '343D49', '40658F', 'FFFFFF', '46515F', '91C9FF', 'B7C7DA' }
    else { $hex = 'F6F8FB', 'FFFFFF', '202833', 'F2F5F9', '264B78', 'FFFFFF', 'CBD3DE', '0F707D', '536273' }
    $keys = 'Background', 'Surface', 'Text', 'Alternate', 'Selection', 'SelectionText', 'Border', 'Link', 'Muted'
    $p = @{}
    for ($i = 0; $i -lt $keys.Count; $i++) { $p[$keys[$i]] = [Drawing.ColorTranslator]::FromHtml('#' + $hex[$i]) }
    return $p
}

function Get-GuiResultColor([string]$Result) {
    # Validation results (Test-StatsAgainstServer) in the Security Review status colors, and the data check ratings.
    if ($script:GuiTheme -eq 'Dark') { $map = @{ OK = '7CD6AE'; MISMATCH = 'FF9696'; INFO = '91C9FF'; SKIPPED = 'BCC5D0'; WARN = 'F2C46D' } }
    else { $map = @{ OK = '207A5C'; MISMATCH = 'B83939'; INFO = '2D69AA'; SKIPPED = '646E7A'; WARN = '9A6700' } }
    $alias = @{ 'Exact' = 'OK'; 'Exact match' = 'OK'; 'Good' = 'OK'; 'Fair' = 'WARN'; 'Poor' = 'MISMATCH'; 'Differs' = 'MISMATCH'; 'Error' = 'MISMATCH'; 'Partial' = 'SKIPPED'; 'Not checked' = 'SKIPPED'; 'Skipped' = 'SKIPPED' }
    if ($Result -and $alias.ContainsKey($Result)) { $Result = $alias[$Result] }
    if ($Result -and $map.ContainsKey($Result)) { return [Drawing.ColorTranslator]::FromHtml('#' + $map[$Result]) }
    return (Get-GuiPalette).Text
}

function Get-GuiScale {
    $f = $script:App.Form
    if ($f) { return $f.DeviceDpi / 96.0 }
    return 1.0
}

function New-GuiGlyphImage([int]$Code) {
    # Menu and toolbar icons drawn from the Windows icon font, in the theme's text color.
    if (-not $script:GuiGlyphFont) {
        $installed = (New-Object Drawing.Text.InstalledFontCollection).Families | ForEach-Object Name
        $script:GuiGlyphFont = @('Segoe Fluent Icons', 'Segoe MDL2 Assets' | Where-Object { $_ -in $installed })[0]
        if (-not $script:GuiGlyphFont) { $script:GuiGlyphFont = '-' }
    }
    if ($script:GuiGlyphFont -eq '-') { return $null }
    $size = [int][Math]::Round(16 * (Get-GuiScale))
    $bmp = New-Object Drawing.Bitmap $size, $size
    $gr = [Drawing.Graphics]::FromImage($bmp)
    $font = New-Object Drawing.Font $script:GuiGlyphFont, ([single]($size * 0.8)), ([Drawing.GraphicsUnit]::Pixel)
    $brush = New-Object Drawing.SolidBrush (Get-GuiPalette).Text
    $format = New-Object Drawing.StringFormat
    $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
    try {
        $gr.TextRenderingHint = 'AntiAliasGridFit'
        $gr.DrawString([string][char]$Code, $font, $brush, (New-Object Drawing.RectangleF 0, 1, $size, $size), $format)
    } finally { $gr.Dispose(); $font.Dispose(); $brush.Dispose(); $format.Dispose() }
    return $bmp
}

function Set-GuiToolStripTheme([Windows.Forms.ToolStrip]$Strip) {
    $p = Get-GuiPalette
    $dark = $script:GuiTheme -eq 'Dark'
    $renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer (New-Object StatsStreamDecoder.Appearance.MenuColors $dark)
    $renderer.RoundedEdges = $false
    $Strip.Renderer = $renderer; $Strip.BackColor = $p.Background; $Strip.ForeColor = $p.Text
    $icon = [int][Math]::Round(16 * (Get-GuiScale))
    $Strip.ImageScalingSize = New-Object Drawing.Size $icon, $icon
    # ToolStrip items are not child controls, so walk them here.
    $pending = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($item in $Strip.Items) { $pending.Enqueue($item) }
    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        $item.ForeColor = $p.Text
        if ($item.PSObject.Properties['GuiGlyph']) { $item.Image = New-GuiGlyphImage $item.GuiGlyph }
        if ($item -is [Windows.Forms.ToolStripControlHost]) {
            $item.Control.BackColor = $p.Surface; $item.Control.ForeColor = $p.Text
            [StatsStreamDecoder.Appearance.Skin]::Apply($item.Control, $dark)
        }
        if ($item -is [Windows.Forms.ToolStripDropDownItem]) {
            $item.DropDown.Renderer = $renderer; $item.DropDown.BackColor = $p.Surface; $item.DropDown.ForeColor = $p.Text
            $item.DropDown.ImageScalingSize = $Strip.ImageScalingSize
            foreach ($child in $item.DropDownItems) { $pending.Enqueue($child) }
        }
    }
}

function Set-GuiControlTheme($Control) {
    $p = Get-GuiPalette
    $dark = $script:GuiTheme -eq 'Dark'
    $Control.BackColor = $p.Background; $Control.ForeColor = $p.Text
    if ($Control -is [Windows.Forms.TextBoxBase] -or $Control -is [Windows.Forms.ListControl] -or $Control -is [Windows.Forms.UpDownBase]) { $Control.BackColor = $p.Surface }
    switch ($Control.Tag) {
        'Muted' { $Control.ForeColor = $p.Muted }
        'StatusOn' { $Control.ForeColor = Get-GuiResultColor 'OK' }
        'Warn' { $Control.ForeColor = Get-GuiResultColor 'Fair' }
        'StatusOff' { $Control.ForeColor = $p.Muted }
        'Card' { $Control.BackColor = $p.Surface }
    }
    if ($Control.Parent -and $Control.Parent.Tag -eq 'Card' -and $Control -is [Windows.Forms.Label]) { $Control.BackColor = $p.Surface }
    if ($Control -is [Windows.Forms.LinkLabel]) { $Control.LinkColor = $p.Link; $Control.ActiveLinkColor = $p.Link; $Control.VisitedLinkColor = $p.Link }
    if ($Control -is [Windows.Forms.ToolStrip]) { Set-GuiToolStripTheme $Control }
    if ($Control -is [Windows.Forms.Button]) {
        # Flat buttons; the focused one gets a thicker border in the link color.
        $Control.UseVisualStyleBackColor = $false; $Control.FlatStyle = 'Flat'
        $Control.FlatAppearance.BorderColor = $(if ($Control.Focused) { $p.Link } else { $p.Border })
        $Control.FlatAppearance.BorderSize = $(if ($Control.Focused) { 2 } else { 1 })
        $Control.BackColor = $p.Surface
        if ($Control.Tag -eq 'Primary') { $Control.BackColor = $p.Selection; $Control.ForeColor = $p.SelectionText }
        if (-not $Control.PSObject.Properties['GuiThemeHooked']) {
            $Control | Add-Member NoteProperty GuiThemeHooked $true
            $Control.Add_GotFocus({ param($s, $e) $s.FlatAppearance.BorderColor = (Get-GuiPalette).Link; $s.FlatAppearance.BorderSize = 2 })
            $Control.Add_LostFocus({ param($s, $e) $s.FlatAppearance.BorderColor = (Get-GuiPalette).Border; $s.FlatAppearance.BorderSize = 1 })
            $Control.Add_Paint({
                    param($s, $e)
                    if (-not $s.Enabled -and $script:GuiTheme -eq 'Dark') {
                        $area = $s.ClientRectangle; $area.Inflate(-2, -2)
                        $brush = New-Object Drawing.SolidBrush (Get-GuiPalette).Surface
                        try {
                            $e.Graphics.FillRectangle($brush, $area)
                            [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $s.Text, $s.Font, $area, [Drawing.Color]::FromArgb(155, 165, 180),
                                ([Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
                        } finally { $brush.Dispose() }
                    }
                })
        }
    }
    if ($Control -is [Windows.Forms.ListBox] -and -not ($Control -is [Windows.Forms.CheckedListBox])) {
        # Owner drawn, so the selection uses the theme colors and a disabled list keeps the dark surface.
        $Control.DrawMode = 'OwnerDrawFixed'; $Control.ItemHeight = $Control.Font.Height + 4
        if (-not $Control.PSObject.Properties['GuiThemeHooked']) {
            $Control | Add-Member NoteProperty GuiThemeHooked $true
            $Control.Add_DrawItem({
                    param($s, $e)
                    if ($e.Index -lt 0) { return }
                    $pal = Get-GuiPalette
                    $selected = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
                    $brush = New-Object Drawing.SolidBrush $(if ($selected) { $pal.Selection } else { $pal.Surface })
                    try {
                        $e.Graphics.FillRectangle($brush, $e.Bounds)
                        $color = $(if (-not $s.Enabled) { $pal.Muted } elseif ($selected) { $pal.SelectionText } else { $pal.Text })
                        $text = $e.Bounds; $text.X += 4; $text.Width -= 4
                        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $s.GetItemText($s.Items[$e.Index]), $s.Font, $text, $color,
                            ([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis -bor [Windows.Forms.TextFormatFlags]::NoPrefix))
                    } finally { $brush.Dispose() }
                })
        }
    }
    if ($Control -is [Windows.Forms.ComboBox]) {
        $Control.FlatStyle = 'Flat'; $Control.DrawMode = 'OwnerDrawFixed'
        if (-not $Control.PSObject.Properties['GuiThemeHooked']) {
            $Control | Add-Member NoteProperty GuiThemeHooked $true
            $Control.Add_DrawItem({
                    param($s, $e)
                    $pal = Get-GuiPalette
                    $selected = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
                    $brush = New-Object Drawing.SolidBrush $(if ($selected) { $pal.Selection } else { $pal.Surface })
                    try {
                        $e.Graphics.FillRectangle($brush, $e.Bounds)
                        $text = if ($e.Index -ge 0) { $s.GetItemText($s.Items[$e.Index]) } else { $s.Text }
                        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $s.Font, $e.Bounds, $(if ($selected) { $pal.SelectionText } else { $pal.Text }),
                            ([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis))
                        $e.DrawFocusRectangle()
                    } finally { $brush.Dispose() }
                })
        }
    }
    if ($Control -is [Windows.Forms.DataGridView]) {
        $Control.BackgroundColor = $p.Surface; $Control.GridColor = $p.Border; $Control.EnableHeadersVisualStyles = $false
        $Control.ColumnHeadersBorderStyle = 'Single'; $Control.RowHeadersBorderStyle = 'Single'
        foreach ($style in @($Control.DefaultCellStyle, $Control.RowsDefaultCellStyle, $Control.ColumnHeadersDefaultCellStyle, $Control.RowHeadersDefaultCellStyle)) {
            $style.BackColor = $p.Surface; $style.ForeColor = $p.Text; $style.SelectionBackColor = $p.Selection; $style.SelectionForeColor = $p.SelectionText
        }
        $Control.AlternatingRowsDefaultCellStyle.BackColor = $p.Alternate; $Control.AlternatingRowsDefaultCellStyle.ForeColor = $p.Text
        if (-not $Control.PSObject.Properties['GuiThemeHooked']) {
            $Control | Add-Member NoteProperty GuiThemeHooked $true
            $Control.Add_CellFormatting({
                    param($s, $e)
                    if ($e.ColumnIndex -ge 0 -and $s.Columns[$e.ColumnIndex].Name -eq 'Result') { $e.CellStyle.ForeColor = Get-GuiResultColor ([string]$e.Value) }
                })
        }
    }
    if ($Control -is [Windows.Forms.TabControl]) {
        # Reserve room for the captions at the current DPI.
        $Control.DrawMode = 'Normal'; $Control.SizeMode = 'Fixed'
        $width = 64
        foreach ($page in $Control.TabPages) { $width = [Math]::Max($width, [Windows.Forms.TextRenderer]::MeasureText($page.Text, $Control.Font).Width + 20) }
        $Control.ItemSize = New-Object Drawing.Size ($width, ($Control.Font.Height + 10))
    }
    foreach ($child in $Control.Controls) { Set-GuiControlTheme $child }
    [StatsStreamDecoder.Appearance.Skin]::Apply($Control, $dark)
    $Control.Invalidate()
}

function Set-GuiTheme([string]$Theme) {
    $script:GuiTheme = $Theme
    foreach ($window in @([Windows.Forms.Application]::OpenForms)) { Set-GuiControlTheme $window }
    Save-GuiSettings
}

function New-GuiControl([string]$Type, [hashtable]$Property = @{}) {
    $c = New-Object "Windows.Forms.$Type"
    # Properties that change how the others apply go first (Value needs Maximum, Height needs Multiline).
    $first = 'Multiline', 'IntegralHeight', 'DropDownStyle', 'Minimum', 'Maximum'
    $keys = @($first | Where-Object { $Property.ContainsKey($_) }) + @($Property.Keys | Where-Object { $_ -notin $first })
    foreach ($k in $keys) { $c.$k = $Property[$k] }
    return $c
}

function New-GuiMenuItem([string]$Text, [int]$Glyph = 0, [string]$Shortcut, [scriptblock]$OnClick, [switch]$Button) {
    # A menu item, or with -Button a toolbar button; Glyph is a Segoe icon font code point.
    if ($Button) { $item = New-Object Windows.Forms.ToolStripButton $Text; $item.DisplayStyle = 'ImageAndText' }
    else { $item = New-Object Windows.Forms.ToolStripMenuItem $Text }
    if ($Glyph) { $item | Add-Member NoteProperty GuiGlyph $Glyph }
    if ($Shortcut) { $item.ShortcutKeys = $Shortcut }
    if ($OnClick) { $item.Add_Click($OnClick) }
    return $item
}

function Add-GuiRow($Table, [string]$Label, $Control) {
    # One label + control row (or one control spanning both columns).
    $row = $Table.RowCount
    $Table.RowCount++
    $null = $Table.RowStyles.Add((New-Object Windows.Forms.RowStyle 'AutoSize'))
    if ($Label) {
        $l = New-GuiControl Label @{ Text = $Label; AutoSize = $true; Anchor = 'Left'; Margin = (New-Object Windows.Forms.Padding 3, 6, 10, 3) }
        $Table.Controls.Add($l, 0, $row)
        $Table.Controls.Add($Control, 1, $row)
    } else {
        $Table.Controls.Add($Control, 0, $row)
        $Table.SetColumnSpan($Control, $Table.ColumnCount)
    }
}

function Add-GuiStackRow($Table, $Control, [string]$SizeType = 'AutoSize', [single]$Size = 0) {
    # One control per row in a single-column layout; Percent rows share the free height.
    $row = $Table.RowCount
    $Table.RowCount++
    $null = $Table.RowStyles.Add($(if ($SizeType -eq 'Percent') { New-Object Windows.Forms.RowStyle 'Percent', $Size } else { New-Object Windows.Forms.RowStyle 'AutoSize' }))
    $Table.Controls.Add($Control, 0, $row)
}

function New-GuiHeading([string]$Text, [int]$Top = 12) {
    return New-GuiControl Label @{ Text = $Text; AutoSize = $true; Font = (New-Object Drawing.Font 'Segoe UI', 10, ([Drawing.FontStyle]::Bold)); Margin = (New-Object Windows.Forms.Padding 3, $Top, 3, 4) }
}

function ConvertTo-GuiSecureString([string]$Text) {
    $s = New-Object Security.SecureString
    foreach ($ch in $Text.ToCharArray()) { $s.AppendChar($ch) }
    $s.MakeReadOnly()
    return $s
}

function Get-GuiServerList($Conn, [string]$DatabaseName, [string]$Sql, [hashtable]$Parameters = @{}) {
    # Short metadata lookups for the pickers; never wait on locks (same rule as the collect script).
    $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $csb['Data Source'] = $Conn.Server
    if ($DatabaseName) { $csb['Initial Catalog'] = $DatabaseName }
    $csb['Application Name'] = 'SQLStatsXRay'
    $csb['Connect Timeout'] = 10
    if ($Conn.Trust) { $csb['Encrypt'] = $true; $csb['TrustServerCertificate'] = $true }
    if (-not $Conn.SqlAuth) { $csb['Integrated Security'] = $true }
    $cn = New-Object System.Data.SqlClient.SqlConnection $csb.ConnectionString
    if ($Conn.SqlAuth) { $cn.Credential = New-Object System.Data.SqlClient.SqlCredential ($Conn.Login, $Conn.Password) }
    [Windows.Forms.Cursor]::Current = [Windows.Forms.Cursors]::WaitCursor
    try {
        $cn.Open()
        $t = Invoke-Query $cn ("SET LOCK_TIMEOUT 2000; SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;`n" + $Sql) $Parameters
        return , [string[]]@($t[0].Rows | ForEach-Object { [string]$_[0] })
    } finally {
        $cn.Close()
        [Windows.Forms.Cursor]::Current = [Windows.Forms.Cursors]::Default
    }
}

function Set-GuiComboItems($Combo, [string[]]$Items) {
    $keep = $Combo.Text
    $script:App.Loading = $true
    try {
        $Combo.BeginUpdate()
        $Combo.Items.Clear()
        if ($Items) { $Combo.Items.AddRange([object[]]$Items) }
        $Combo.EndUpdate()
        $Combo.AutoCompleteCustomSource.Clear()
        if ($Items) { $Combo.AutoCompleteCustomSource.AddRange($Items) }
        $Combo.Text = $keep
    } finally { $script:App.Loading = $false }
}

function Set-GuiConnected($Conn, [string[]]$Databases) {
    # $Conn = $null disconnects. The browse controls only work with a connection.
    $g = $script:App
    $g.Conn = $Conn
    $on = [bool]$Conn
    Set-GuiComboItems $g.Database $(if ($on) { $Databases } else { @() })
    $g.Loading = $true; $g.Database.SelectedIndex = -1; $g.Loading = $false
    $g.AllTables = @()
    Update-GuiTableFilter
    $g.Stats.Items.Clear(); Set-GuiStatsAll $false; $g.StatsCount.Text = ''
    foreach ($c in $g.Database, $g.TableFilter, $g.Tables, $g.Stats, $g.StatsAll) { $c.Enabled = $on }
    if ($on) {
        $g.ConnTitle.Text = $Conn.Server
        $g.ConnDetail.Text = $(if ($Conn.SqlAuth) { "SQL Server login $($Conn.Login)" } else { 'Windows authentication' }) + $(if ($Conn.Trust) { ', trusted certificate' } else { '' })
        $g.ConnDot.Tag = 'StatusOn'
        $g.ConnStatus.Text = "Connected: $($Conn.Server)"
        Set-GuiStatus "Connected to $($Conn.Server): $(@($Databases).Count) databases. Pick a database."
    } else {
        $g.ConnTitle.Text = 'Not connected'
        $g.ConnDetail.Text = 'Connect to browse databases, tables and statistics, or paste a STATS_STREAM.'
        $g.ConnDot.Tag = 'StatusOff'
        $g.ConnStatus.Text = 'Not connected'
    }
    $g.ConnDot.ForeColor = $(if ($on) { Get-GuiResultColor 'OK' } else { (Get-GuiPalette).Muted })
    Update-GuiCommandState
}

function Update-GuiTableFilter {
    # The table list shows the names that contain the search text (brackets ignored, any case).
    $g = $script:App
    $all = @($g.AllTables)
    $text = $g.TableFilter.Text.Trim().Replace('[', '').Replace(']', '')
    $shown = $all
    if ($text) { $shown = @($all | Where-Object { $_.Plain.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
    $keep = [string]$g.Tables.SelectedItem
    $g.Loading = $true
    try {
        $g.Tables.BeginUpdate()
        $g.Tables.Items.Clear()
        if ($shown) { $g.Tables.Items.AddRange([object[]]@($shown | ForEach-Object Name)) }
        $g.Tables.EndUpdate()
        if ($keep) { $g.Tables.SelectedIndex = $g.Tables.Items.IndexOf($keep) }
    } finally { $g.Loading = $false }
    $g.TablesCount.Text = $(if (-not $all) { '' } elseif ($text) { "$($shown.Count) of $($all.Count)" } else { "$($all.Count)" })
    if ($keep -and $g.Tables.SelectedIndex -lt 0) { $g.Stats.Items.Clear(); Set-GuiStatsAll $false; $g.StatsCount.Text = '' }
    Update-GuiCommandState
}

function Invoke-GuiBrowse([string]$Level) {
    # Level: Tables (database picked) or Stats (table picked); the database list comes from the Connect dialog.
    $g = $script:App
    if (-not $g.Conn) { return }
    try {
        switch ($Level) {
            'Tables' {
                $db = $g.Database.Text.Trim()
                if (-not $db) { return }
                $list = Get-GuiServerList $g.Conn $db @'
SELECT QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name)
FROM sys.objects o
WHERE o.type IN ('U', 'V') AND EXISTS (SELECT 1 FROM sys.stats s WHERE s.object_id = o.object_id)
ORDER BY 1
'@
                $g.AllTables = @($list | ForEach-Object { [pscustomobject]@{ Name = $_; Plain = $_.Replace('[', '').Replace(']', '') } })
                $g.Tables.ClearSelected()
                $g.Stats.Items.Clear(); Set-GuiStatsAll $false; $g.StatsCount.Text = ''
                Update-GuiTableFilter
                Set-GuiStatus "${db}: $($list.Count) tables and indexed views with statistics."
            }
            'Stats' {
                $table = [string]$g.Tables.SelectedItem
                $g.Stats.Items.Clear(); Set-GuiStatsAll $false; $g.StatsCount.Text = ''
                if (-not $table) { return }
                $list = Get-GuiServerList $g.Conn $g.Database.Text.Trim() 'SELECT name FROM sys.stats WHERE object_id = OBJECT_ID(@t) ORDER BY stats_id' @{ '@t' = $table }
                if ($list) { $g.Stats.Items.AddRange([object[]]$list) }
                $g.StatsCount.Text = "$($list.Count)"
                Set-GuiStatus "${table}: $($list.Count) statistics objects. Check some, or none for all, then Decode (F5)."
            }
        }
    } catch {
        Set-GuiStatus 'The server request failed.'
        Show-GuiMessage $_.Exception.Message 'Error'
    }
    Update-GuiCommandState
}

function Set-GuiStatsAll([bool]$Checked) {
    # Sets the "Check all" box without re-checking the list (the list drives it, not the other way).
    $g = $script:App
    $g.StatsSync = $true
    try { $g.StatsAll.Checked = $Checked } finally { $g.StatsSync = $false }
}

function Show-GuiMessage([string]$Text, [string]$Icon = 'Information') {
    # Owned by the dialog in front, when there is one.
    $owner = [Windows.Forms.Form]::ActiveForm
    if (-not $owner) { $owner = $script:App.Form }
    $null = [Windows.Forms.MessageBox]::Show($owner, $Text, 'SQLStatsXRay', 'OK', $Icon)
}

function Set-GuiStatus([string]$Text) { $script:App.Status.Text = $Text }

function Update-GuiCommandState {
    # Commands follow the connection, the table selection and a running decode.
    $g = $script:App
    if (-not $g.Run) { return }
    $busy = [bool]$g.Job
    $on = [bool]$g.Conn
    $g.Inputs.Enabled = -not $busy
    foreach ($c in $g.Commands.Connect + $g.Commands.Paste + $g.Commands.Open + $g.Commands.Settings) { $c.Enabled = -not $busy }
    foreach ($c in $g.Commands.Disconnect) { $c.Enabled = $on -and -not $busy }
    $g.Run.Enabled = $busy -or ($on -and $g.Tables.SelectedIndex -ge 0)
    $g.Run.Text = $(if ($busy) { 'Cancel  (Esc)' } else { 'Decode  (F5)' })
    $g.Progress.Visible = $busy
    $current = Get-GuiCurrentResult
    $g.CheckData.Enabled = -not $busy -and $on -and $current -and $current.PSObject.Properties['Target']
    foreach ($c in $g.Commands.Build) { $c.Enabled = -not $busy -and $on -and $g.Tables.SelectedIndex -ge 0 }
    $s = $g.Settings
    $g.DecodeHint.Text = 'Validation {0}, DAC {1}. Change in Settings (Ctrl+,).' -f $(if ($s.Validate) { 'on' } else { 'off' }), $(if ($s.UseDac) { 'on' } else { 'off' })
}

function Get-GuiDecodeParameters([hashtable]$Offline) {
    # Returns the script parameters for the background run, or $null after telling the user what is missing.
    # $Offline holds StatsStream or InputFile (+ ColumnNames, CodePage) from the paste dialog.
    $g = $script:App
    $s = $g.Settings
    $p = @{
        GuiRun               = $true
        IncludeHexDump       = [bool]$s.HexDump
        FullPrecision        = [bool]$s.FullPrecision
        MaxStringIndexNodes  = [int]$s.StringIndexNodes
        MaxSampledScanValues = [int]$s.SampledScanValues
    }
    if ($Offline) {
        foreach ($k in $Offline.Keys) { $p[$k] = $Offline[$k] }
        return $p
    }
    if (-not $g.Conn) { Show-GuiMessage 'Connect to a server first (Ctrl+N), or paste a STATS_STREAM (Ctrl+Shift+V).' 'Warning'; return $null }
    $table = [string]$g.Tables.SelectedItem
    if (-not $g.Database.Text.Trim() -or -not $table) { Show-GuiMessage 'Pick a database and a table first.' 'Warning'; return $null }
    $p.ServerInstance = $g.Conn.Server
    $p.Database = $g.Database.Text.Trim()
    $p.Table = $table
    $checked = @($g.Stats.CheckedItems | ForEach-Object { [string]$_ })
    if ($checked) { $p.Statistics = [string[]]$checked }
    if ($g.Conn.SqlAuth) { $p.Credential = New-Object Management.Automation.PSCredential ($g.Conn.Login, $g.Conn.Password) }
    $p.TrustServerCertificate = [bool]$g.Conn.Trust
    $p.Validate = [bool]$s.Validate
    $p.UseDac = [bool]$s.UseDac
    return $p
}

function Start-GuiDecode([hashtable]$Offline) {
    $g = $script:App
    if ($g.Job) { return }
    $p = Get-GuiDecodeParameters $Offline
    if (-not $p) { return }
    $pending = Get-GuiPendingEdits
    if ($pending -and [Windows.Forms.MessageBox]::Show($g.Form, "$($pending.Count) statistics object(s) have edits that a new decode will discard. Continue?", 'SQLStatsXRay', 'YesNo', 'Warning') -ne 'Yes') { return }
    $g.ReportName = $(if ($p.Database) { 'StatsStream_' + ("$($p.Database)_$($p.Table)" -replace '[\[\]\\/:*?"<>|\s]', '') } else { 'StatsStream_report' })
    Start-GuiJob $p 'Decoding'
}

function Start-GuiJob([hashtable]$Parameters, [string]$Activity, $Check, $Build) {
    # The script runs in its own runspace so the window stays responsive and can cancel it.
    $g = $script:App
    $ps = [PowerShell]::Create()
    $ps.Runspace = [RunspaceFactory]::CreateRunspace()
    $ps.Runspace.Open()
    $null = $ps.AddCommand($script:DecoderPath).AddParameters($Parameters)
    $g.Job = @{ PowerShell = $ps; Async = $ps.BeginInvoke(); Started = [DateTime]::Now; FullPrecision = [bool]$Parameters.FullPrecision; Activity = $Activity; Check = $Check; Build = $Build }
    Update-GuiCommandState
    Set-GuiStatus "$Activity..."
    $g.Timer.Start()
}

function Start-GuiDataCheck {
    # Checks the selected statistics object's histogram against its table (opt-in: it reads the table through an index).
    $g = $script:App
    if ($g.Job) { return }
    $D = Get-GuiCurrentResult
    if (-not $D -or -not $D.PSObject.Properties['Target']) { Show-GuiMessage 'The data check needs statistics decoded from a server. Connect (Ctrl+N), decode a table (F5), then pick a statistics object.' 'Warning'; return }
    if (-not $g.Conn -or $g.Conn.Server -ne $D.Target.Server) { Show-GuiMessage "Connect to $($D.Target.Server) to check these statistics against their table." 'Warning'; return }
    if (Get-GuiPendingEdits) { Set-GuiStatus 'The data check reads the statistics as stored on the server, not your edits.' }
    $s = $g.Settings
    $p = @{
        GuiRun = $true; ServerInstance = $g.Conn.Server; Database = $D.Target.Database; Table = $D.Target.Table; Statistics = [string[]]@($D.Target.Statistics)
        VerifyData = $true; VerifyPageBudget = [long]$s.CheckPageBudget; VerifyTimeout = [int]$s.CheckTimeout; VerifyStepDelay = [int]$s.CheckStepDelay
        FullPrecision = [bool]$s.FullPrecision; TrustServerCertificate = [bool]$g.Conn.Trust
    }
    if ($g.Conn.SqlAuth) { $p.Credential = New-Object Management.Automation.PSCredential ($g.Conn.Login, $g.Conn.Password) }
    Start-GuiJob $p "Checking $($D.Target.Statistics) against the table" @{ Index = $g.Picker.SelectedIndex; Result = $D }
}

function Complete-GuiDataCheck($Job, $Result, [string[]]$Notes) {
    $g = $script:App
    $D = $Job.Check.Result
    $new = @($Result.Objects) | Select-Object -First 1
    if (-not $new -or -not $new.PSObject.Properties['DataCheck']) { Set-GuiStatus 'Data check failed.'; Show-GuiMessage ((@('The data check returned no result.') + $Notes) -join [Environment]::NewLine) 'Error'; return }
    $check = $new.DataCheck
    if ($D.Blob -and $new.Blob -and $D.Blob.Updated -ne $new.Blob.Updated) {
        # compared with the statistics as they are now, which differ from the decoded ones shown in the other tabs
        $check.Findings.Insert(0, 'The statistics were updated on the server after this decode: the check used the current statistics. Decode again (F5) to see them.')
    }
    $D | Add-Member DataCheck $check -Force
    $lines = @('', ('#' * 100), "  Data check: $($new.Label)", ('#' * 100)) + [string[]](Format-DataCheckSection $check)
    $g.Report.AppendText((@($Notes) + $lines) -join [Environment]::NewLine)
    $g.HasReport = $true
    if ($g.Picker.SelectedIndex -eq $Job.Check.Index) { Show-GuiDataCheck $D; $g.Tabs.SelectedTab = $g.CheckPage }
    $detail = $(if ($check.Summary['Coverage']) { 'Read ' + $check.Summary['Coverage'] } else { 'Not checked: ' + $check.Summary['Reason'] })
    Set-GuiStatus ('Data check of {0}: {1}. {2}' -f $D.Target.Statistics, $check.Result, $detail.TrimEnd('.') + '.')
}

function Show-GuiDataCheck($D) {
    $g = $script:App
    $check = $null
    if ($D -and $D.PSObject.Properties['DataCheck']) { $check = $D.DataCheck }
    $summary = @(); $steps = @()
    if ($check) {
        $summary = foreach ($k in $check.Summary.Keys) { [pscustomobject]@{ Field = $k; Value = [string]$check.Summary[$k]; Result = $(if ($k -eq 'Result') { [string]$check.Summary[$k] }) } }
        $steps = $check.Steps.ToArray()
        $g.CheckFindings.Text = ($check.Findings | ForEach-Object { [char]0x2022 + ' ' + $_ }) -join ([Environment]::NewLine + [Environment]::NewLine)
    } else {
        $g.CheckFindings.Text = $(if ($D -and $D.PSObject.Properties['Target']) { 'Not checked yet. Check against the table (F6) reads the table through an index and compares every step with the real counts.' }
            elseif ($D) { 'The data check needs statistics decoded from a server.' } else { '' })
    }
    $grid = $g.Grids.CheckSummary
    Set-GuiGrid $grid $summary Field, Value, Result
    $grid.Columns['Result'].Visible = $false
    Set-GuiGrid $g.Grids.CheckSteps $steps Step, Kind, Result, StatsEqRows, TableEqRows, EqQError, StatsRangeRows, TableRangeRows, RangeQError,
    StatsDistinct, TableDistinct, DistinctQError, AvgRangeRows, MaxRowsPerValue, Note
    # the summary gets the room its rows and columns need; the findings and the ranges take the rest
    $outer = $g.CheckSplits[0]; $inner = $g.CheckSplits[1]
    if ($summary) {
        $w = $grid.Columns.GetColumnsWidth('Visible') + [Windows.Forms.SystemInformation]::VerticalScrollBarWidth + 4
        $h = $grid.ColumnHeadersHeight + $grid.Rows.GetRowsHeight('Visible') + [Windows.Forms.SystemInformation]::HorizontalScrollBarHeight + 4
        try { $inner.SplitterDistance = [int][Math]::Max(120, [Math]::Min($w, $inner.Width - 240)) } catch { }
        try { $outer.SplitterDistance = [int][Math]::Max(80, [Math]::Min($h, $outer.Height * 0.55)) } catch { }
    }
    Update-GuiCommandState
}

function Stop-GuiDecode {
    $job = $script:App.Job
    if ($job) { $null = $job.PowerShell.BeginStop($null, $null); Set-GuiStatus 'Cancelling...' }
}

function Complete-GuiDecode {
    $g = $script:App
    $job = $g.Job
    $g.Job = $null
    $g.Timer.Stop()
    $ps = $job.PowerShell
    $result = $null; $failure = $null
    try { $result = @($ps.EndInvoke($job.Async)) | Where-Object { $_.PSObject.Properties['Lines'] } | Select-Object -Last 1 }
    catch {
        $e = $_.Exception
        if ($e.InnerException) { $e = $e.InnerException }
        $failure = $e
    }
    $notes = @($ps.Streams.Warning | ForEach-Object { "WARNING: $($_.Message)" }) + @($ps.Streams.Error | ForEach-Object { "ERROR: $($_.Exception.Message)" })
    $ps.Runspace.Dispose(); $ps.Dispose()
    Update-GuiCommandState
    $seconds = ([DateTime]::Now - $job.Started).TotalSeconds

    if ($failure -is [Management.Automation.PipelineStoppedException]) { Set-GuiStatus 'Cancelled.'; return }
    if ($failure -or -not $result) {
        $message = $(if ($failure) { $failure.Message } else { 'The decoder returned no result.' })
        Set-GuiStatus $(if ($job.Check) { 'Data check failed.' } else { 'Decode failed.' })
        Show-GuiMessage (@($message) + $notes -join [Environment]::NewLine) 'Error'
        return
    }
    if ($job.Check) { Complete-GuiDataCheck $job $result $notes; return }
    if ($job.Build) { Complete-GuiBuild $job $result $notes; return }

    $g.Results = @($result.Objects)
    $g.HasReport = $true
    $g.FullPrecisionRun = $job.FullPrecision
    $g.Report.Text = (@($notes) + @($result.Lines)) -join [Environment]::NewLine
    $g.Report.SelectionStart = 0; $g.Report.ScrollToCaret()
    $g.Loading = $true
    $g.Picker.Items.Clear()
    foreach ($d in $g.Results) {
        $name = $d.Label
        if ($d.PSObject.Properties['ServerInfo']) { $name = $d.ServerInfo['Statistics'] }
        $null = $g.Picker.Items.Add($name)
    }
    $g.Loading = $false
    if ($g.Picker.Items.Count -gt 0) { $g.Picker.SelectedIndex = 0 } else { Show-GuiResult $null }

    $status = '{0} statistics object(s) decoded in {1:0.0} s.' -f $g.Results.Count, $seconds
    $validated = @($g.Results | Where-Object { $_.PSObject.Properties['Validation'] })
    if ($validated) {
        $bad = @($validated | Where-Object { @($_.Validation | Where-Object { $_.Result -eq 'MISMATCH' }).Count -gt 0 }).Count
        $status += $(if ($bad -eq 0) { ' Validation passed.' } else { " Validation FAILED on $bad object(s)." })
    }
    if ($notes) { $status += " $($notes.Count) warning(s), see the report." }
    Set-GuiStatus $status
}

function Show-GuiBuildDialog {
    <#
      The statistics builder's options: what to build (the statistics object shown, a new one on a column, or every
      statistics object of the table from one read), the sampler and sample, the algorithms, the Query Store workload
      and NORECOMPUTE (recommended, not checked). The build runs in the background; the app only writes the script.
    #>
    $g = $script:App
    if ($g.Job) { return }
    if (-not $g.Conn) { Show-GuiMessage 'Connect to a server first (Ctrl+N).' 'Warning'; return }
    $table = [string]$g.Tables.SelectedItem
    $database = $g.Database.Text.Trim()
    if (-not $table -or -not $database) { Show-GuiMessage 'Pick a database and a table first.' 'Warning'; return }
    $types = ($script:BuildKeyTypes | ForEach-Object { [string]$_ }) -join ', '
    try { $columns = Get-GuiServerList $g.Conn $database "SELECT c.name FROM sys.columns c WHERE c.object_id = OBJECT_ID(@t) AND c.system_type_id IN ($types) ORDER BY c.column_id" @{ '@t' = $table } }
    catch { Show-GuiMessage "Could not read the table's columns: $($_.Exception.Message)" 'Error'; return }
    $current = Get-GuiCurrentResult
    $stat = $(if ($current -and $current.PSObject.Properties['Target'] -and $current.Target.Table -eq $table -and $current.Target.Database -eq $database) { [string]$current.Target.Statistics })
    $sc = Get-GuiScale
    $d = New-GuiDialog "Build statistics (beta): $table"
    $noteWidth = [int](620 * $sc)
    $note = { param([string]$Text) New-GuiControl Label @{ Text = $Text; AutoSize = $true; Tag = 'Muted'; MaximumSize = (New-Object Drawing.Size $noteWidth, 0); Margin = (New-Object Windows.Forms.Padding 3, 0, 3, 8) } }
    $beta = New-GuiControl Label @{ Text = 'Beta: the statistics builder is still being developed. Check its scripts on a test copy before production.'; AutoSize = $true; Tag = 'Warn'; MaximumSize = (New-Object Drawing.Size $noteWidth, 0); Margin = (New-Object Windows.Forms.Padding 3, 4, 3, 4) }
    Add-GuiRow $d.Layout '' $beta
    Add-GuiRow $d.Layout '' (New-GuiHeading 'What to build' 2)
    $rStat = New-GuiControl RadioButton @{ AutoSize = $true; Text = $(if ($stat) { "The statistics object shown: [$stat]" } else { 'The statistics object shown (decode one first)' }); Enabled = [bool]$stat; Checked = [bool]$stat }
    $rColumn = New-GuiControl RadioButton @{ AutoSize = $true; Text = 'A new statistics object on a column'; Checked = -not $stat; Enabled = $columns.Count -gt 0 }
    $rAll = New-GuiControl RadioButton @{ AutoSize = $true; Text = 'Every statistics object of the table, from one read' }
    foreach ($r in $rStat, $rColumn, $rAll) { Add-GuiRow $d.Layout '' $r }
    $column = New-GuiControl ComboBox @{ DropDownStyle = 'DropDownList'; Width = [int](260 * $sc) }
    $null = $column.Items.AddRange([object[]]$columns)
    if ($columns.Count) { $column.SelectedIndex = 0 }
    Add-GuiRow $d.Layout 'Column' $column
    $name = New-GuiControl TextBox @{ Width = [int](260 * $sc); Text = $(if ($columns.Count) { "xray_$($columns[0])" } else { '' }) }
    Add-GuiRow $d.Layout 'New statistics name' $name
    Add-GuiRow $d.Layout '' (& $note 'One-column statistics on numbers, dates and times, uniqueidentifier, binary and character columns (char, varchar, nchar, nvarchar; ordered by the server in the column''s collation). Nonclustered index statistics also carry the clustering key and are skipped.')

    Add-GuiRow $d.Layout '' (New-GuiHeading 'Sample')
    $sampler = New-GuiControl ComboBox @{ DropDownStyle = 'DropDownList'; Width = [int](260 * $sc) }
    $null = $sampler.Items.AddRange([object[]]@('SQL Server', 'Adaptive')); $sampler.SelectedIndex = 0
    Add-GuiRow $d.Layout 'Sampler' $sampler
    $sample = New-GuiControl ComboBox @{ DropDownStyle = 'DropDown'; Width = [int](260 * $sc) }
    $null = $sample.Items.AddRange([object[]]@('Default', 'FULLSCAN', '5 PERCENT', '10 PERCENT', '25 PERCENT', '100000 ROWS')); $sample.Text = 'Default'
    Add-GuiRow $d.Layout 'Sample size' $sample
    $limit = New-GuiControl NumericUpDown @{ Minimum = 0; Maximum = 100; DecimalPlaces = 1; Increment = 1; Value = 4; Width = [int](110 * $sc) }
    Add-GuiRow $d.Layout 'Adaptive limit' $limit
    Add-GuiRow $d.Layout '' (& $note ('SQL Server reads the pages SQL Server would (its default size is reverse engineered). Adaptive measures a pilot of about 64 pages and reads as many useful rows, ' +
            'more when values cluster by page (up to the limit, as a multiple of SQL Server''s sample; 0 = no limit), and with an index on the column counts each step key exactly. ' +
            'Sizes: Default, FULLSCAN, <n> PERCENT or <n> ROWS.'))

    Add-GuiRow $d.Layout '' (New-GuiHeading 'Histogram')
    $algos = New-GuiControl FlowLayoutPanel @{ AutoSize = $true; WrapContents = $true; MaximumSize = (New-Object Drawing.Size $noteWidth, 0) }
    $boxes = @{}
    foreach ($a in 'EqualRows', 'MaxDiff', 'FrequentFirst', 'VOptimal', 'Workload') { $boxes[$a] = New-GuiControl CheckBox @{ Text = $a; AutoSize = $true; Checked = $true }; $algos.Controls.Add($boxes[$a]) }
    Add-GuiRow $d.Layout 'Algorithms' $algos
    $workload = New-GuiControl CheckBox @{ Text = 'Use the Query Store workload (predicate values and executions)'; AutoSize = $true; Checked = $true }
    Add-GuiRow $d.Layout '' $workload
    Add-GuiRow $d.Layout '' (& $note 'Every candidate is scored by q-error against the rows read, and the best one is written. With workload values, the best is the one that estimates the workload''s own predicates best.')

    Add-GuiRow $d.Layout '' (New-GuiHeading 'Script')
    $norecompute = New-GuiControl CheckBox @{ Text = 'NORECOMPUTE (recommended)'; AutoSize = $true; Checked = $false }
    Add-GuiRow $d.Layout '' $norecompute
    Add-GuiRow $d.Layout '' (& $note ('Without it, the first automatic update after enough modifications replaces the built histogram with SQL Server''s own. With it, the statistics never update by ' +
            'themselves: rebuild them when the data changes, and keep them out of maintenance jobs. Nothing is changed on the server: the app writes the script.'))
    $buttons = Add-GuiDialogButtons $d 'Build'
    $buttons.Ok.DialogResult = 'OK'
    $g.Dlg = @{ Column = $column; Name = $name; Sampler = $sampler; Limit = $limit; ByColumn = $rColumn }
    $column.Add_SelectedIndexChanged({ $x = $script:App.Dlg; $x.Name.Text = "xray_$($x.Column.SelectedItem)" })
    # the column and the name only apply to a new statistics object; the limit only to the adaptive sampler
    $toggle = { $x = $script:App.Dlg; $x.Column.Enabled = $x.ByColumn.Checked; $x.Name.Enabled = $x.ByColumn.Checked; $x.Limit.Enabled = $x.Sampler.SelectedIndex -eq 1 }
    foreach ($r in $rStat, $rColumn, $rAll) { $r.Add_CheckedChanged($toggle) }
    $sampler.Add_SelectedIndexChanged($toggle)
    & $toggle
    try { $result = $d.Form.ShowDialog($g.Form) }
    finally { $g.Dlg = $null; $d.Form.Dispose() }
    if ($result -ne 'OK') { return }

    $algorithms = @($boxes.Keys | Where-Object { $boxes[$_].Checked })
    if (-not $algorithms) { Show-GuiMessage 'Choose at least one algorithm.' 'Warning'; return }
    $p = @{
        GuiRun = $true; ServerInstance = $g.Conn.Server; Database = $database; Table = $table; Build = $true; Sample = $sample.Text.Trim()
        Sampler = $(if ($sampler.SelectedIndex -eq 1) { 'Adaptive' } else { 'SqlServer' }); AdaptiveLimit = [double]$limit.Value; Algorithm = [string[]]$algorithms
        NoWorkload = -not $workload.Checked; NoRecompute = $norecompute.Checked; TrustServerCertificate = [bool]$g.Conn.Trust
    }
    if ($rStat.Checked) { $p.Statistics = [string[]]@($stat); $what = "[$stat]" }
    elseif ($rColumn.Checked) {
        if (-not $column.SelectedItem) { Show-GuiMessage 'Choose a column.' 'Warning'; return }
        $p.Column = [string]$column.SelectedItem; $p.NewStatisticsName = $name.Text.Trim(); $what = "a new statistics object on [$($column.SelectedItem)]"
    } else { $p.AllStatistics = $true; $what = "every statistics object of $table" }
    if ($g.Conn.SqlAuth) { $p.Credential = New-Object Management.Automation.PSCredential ($g.Conn.Login, $g.Conn.Password) }
    Start-GuiJob $p "Building $what" $null @{ Table = $table; Database = $database; All = [bool]$p.AllStatistics }
}

function Complete-GuiBuild($Job, $Result, [string[]]$Notes) {
    $g = $script:App
    $b = @($Result.Objects) | Select-Object -First 1
    if (-not $b -or -not $b.Script) { Set-GuiStatus 'Build failed.'; Show-GuiMessage ((@('The builder returned no script.') + $Notes) -join [Environment]::NewLine) 'Error'; return }
    $g.Report.AppendText(([Environment]::NewLine + ((@($Notes) + @($Result.Lines | Where-Object { $_ -notlike 'Script written to*' })) -join [Environment]::NewLine)))
    $g.HasReport = $true
    $summary = $(if ($Job.Build.All) {
            $levels = @($b.Results | ForEach-Object { (Get-StatsBuildVerdict $_).Level })
            "$(@($b.Results).Count) statistics object(s) built from one read ($(@($levels | Where-Object { $_ -eq 'Better' }).Count) better than now), $(@($b.Skipped).Count) skipped"
        } else { "[$($b.StatName)]: $($b.Best.Name), $(switch ((Get-StatsBuildVerdict $b).Level) { 'Better' { 'better than now' } 'Same' { 'about the same as now' } 'Worse' { 'not better than now' } default { 'new' } })" })
    Set-GuiStatus "Statistics built: $summary. Nothing was changed on the server."
    Show-GuiBuildResult $b $Result.Lines $Job.Build
}

function Show-GuiBuildResult($B, [string[]]$Lines, $Info) {
    # The builder's report and script; Show histogram opens a single build in the result tabs.
    $g = $script:App
    $dlg = New-GuiControl Form @{
        Text = "Statistics builder (beta): $($Info.Table)"; StartPosition = 'CenterParent'; Font = $g.Form.Font
        Size = (New-Object Drawing.Size 1180, 760); MinimumSize = (New-Object Drawing.Size 760, 480); ShowInTaskbar = $false
    }
    if ($g.Icon) { $dlg.Icon = $g.Icon }
    $tabs = New-GuiControl TabControl @{ Dock = 'Fill' }
    $mono = New-Object Drawing.Font 'Consolas', 9.75
    $pages = @{}
    # the report without the script (the background run appends it after a SCRIPT heading; it has its own tab)
    $summary = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in @($Lines)) {
        if ($l -eq '  SCRIPT') { if ($summary.Count -gt 1) { $summary.RemoveRange($summary.Count - 2, 2) }; break }
        if ($l -like 'Script written to*') { continue }
        $summary.Add(($l -replace '\(-ShowCandidates lists their scores\)', '(scores in the All algorithms tab)' -replace '^Every algorithm''s scores: -ShowCandidates\.$', 'Every algorithm''s scores: the All algorithms tab.'))
    }
    $summaryText = ($summary.ToArray() -join [Environment]::NewLine).Trim()
    # every candidate's scores, which the summary leaves out
    $all = New-Object 'System.Collections.Generic.List[string]'
    $all.Add('Every algorithm tried, scored by q-error (1 = exact) against the rows read; equality per distinct value, ranges over 1,000 random ranges, workload by executions.')
    foreach ($c in $(if ($Info.All) { @($B.Results) } else { @($B) })) {
        $all.Add('')
        if ($Info.All) { $all.Add("[$($c.StatName)] ($($c.Target.Column)), chosen on $($c.Objective):") } else { $all.Add("Chosen on $($c.Objective):") }
        $all.AddRange([string[]](Format-StatsBuildCandidates $c))
    }
    foreach ($t in @(@('Summary', $summaryText), @('All algorithms', ($all.ToArray() -join [Environment]::NewLine)), @('Script', [string]$B.Script))) {
        $page = New-GuiControl TabPage @{ Text = $t[0]; Padding = (New-Object Windows.Forms.Padding 4) }
        $box = New-GuiControl TextBox @{ Dock = 'Fill'; ReadOnly = $true; Multiline = $true; WordWrap = $false; ScrollBars = 'Both'; MaxLength = 0; Font = $mono; BorderStyle = 'None'; Text = $t[1] }
        $page.Controls.Add($box); $tabs.TabPages.Add($page); $pages[$t[0]] = $box
    }
    $buttons = New-GuiControl FlowLayoutPanel @{ AutoSize = $true; Dock = 'Bottom'; FlowDirection = 'RightToLeft'; Padding = (New-Object Windows.Forms.Padding 6) }
    $close = New-GuiControl Button @{ Text = 'Close'; AutoSize = $true; DialogResult = 'Cancel' }
    $copy = New-GuiControl Button @{ Text = 'Copy script'; AutoSize = $true }
    $save = New-GuiControl Button @{ Text = 'Save script as...'; AutoSize = $true; Tag = 'Primary' }
    $show = New-GuiControl Button @{ Text = 'Show histogram'; AutoSize = $true; Visible = -not $Info.All }
    $note = New-GuiControl Label @{ Text = 'The app only writes the script; run it yourself, on a test copy first. It holds key values: handle it as customer data.'; AutoSize = $true; Tag = 'Muted'; Margin = (New-Object Windows.Forms.Padding 3, 9, 16, 3) }
    $buttons.Controls.AddRange(@($close, $copy, $save, $show, $note))
    $dlg.Controls.Add($tabs); $dlg.Controls.Add($buttons)
    $dlg.CancelButton = $close
    $g.Dialog = @{ Form = $dlg; Build = $B; Info = $Info; Script = $pages.Script }
    $copy.Add_Click({ [Windows.Forms.Clipboard]::SetText($script:App.Dialog.Script.Text); Set-GuiStatus 'Script copied to the clipboard.' })
    $save.Add_Click({
            $state = $script:App.Dialog
            $sfd = New-Object Windows.Forms.SaveFileDialog
            $sfd.Filter = 'SQL scripts|*.sql|All files|*.*'
            $sfd.FileName = 'BuildStats_' + ("$($state.Info.Database)_$($state.Info.Table)" -replace '[\[\]\\/:*?"<>|\s]', '') + '.sql'
            if ($sfd.ShowDialog($state.Form) -eq 'OK') {
                [IO.File]::WriteAllText($sfd.FileName, $state.Script.Text, (New-Object Text.UTF8Encoding $true))
                Set-GuiStatus "Script saved to $($sfd.FileName)."
            }
            $sfd.Dispose()
        })
    $show.Add_Click({
            # the built stream, decoded like any other, as a new entry of the statistics picker
            $app = $script:App; $state = $app.Dialog; $b = $state.Build
            $d = ConvertFrom-StatsStream -Bytes ([byte[]]$b.Stream.Bytes) -Names @($b.Target.Column) -Label "built: [$($b.StatName)] ($($b.Best.Name))"
            $app.Results = @($app.Results) + $d
            $null = $app.Picker.Items.Add("built: $($b.StatName) ($($b.Best.Name))")
            $app.Picker.SelectedIndex = $app.Picker.Items.Count - 1
            $app.Tabs.SelectedIndex = 2
            $state.Form.Close()
        })
    $dlg.Add_Load({ param($s, $e) Set-GuiControlTheme $s })
    try { $null = $dlg.ShowDialog($g.Form) }
    finally { $dlg.Dispose(); $g.Dialog = $null }
}

function Set-GuiGrid($Grid, $Rows, [string[]]$Columns) {
    # Typed columns, so sorting is numeric and floats use the report's precision.
    $Rows = @($Rows | Where-Object { $null -ne $_ })
    $Grid.SuspendLayout()
    $Grid.Rows.Clear(); $Grid.Columns.Clear()
    $types = @{}
    foreach ($c in $Columns) {
        $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c; $col.HeaderText = $c; $col.SortMode = 'Automatic'
        $found = @($Rows | ForEach-Object { $_.$c } | Where-Object { $null -ne $_ -and $_ -isnot [DBNull] } | ForEach-Object { $_.GetType() } | Select-Object -Unique)
        $t = [string]
        if ($found.Count -eq 1) { $t = $found[0] }
        $code = [int][Type]::GetTypeCode($t)
        if ($code -ge 5 -and $code -le 15) {
            # SByte .. Decimal
            $col.DefaultCellStyle.Alignment = 'MiddleRight'
            if ($t -eq [single]) { $col.DefaultCellStyle.Format = $(if ($script:App.FullPrecisionRun) { 'R' } else { 'G7' }) }
            if ($t -eq [double]) { $col.DefaultCellStyle.Format = $(if ($script:App.FullPrecisionRun) { 'R' } else { 'G15' }) }
            $col.DefaultCellStyle.FormatProvider = $script:Inv
        } elseif ($t -eq [datetime]) {
            $col.DefaultCellStyle.Format = 'yyyy-MM-dd HH:mm:ss.fff'
        } elseif ($t -ne [bool]) { $t = [string] }
        $col.ValueType = $t
        $types[$c] = $t
        $null = $Grid.Columns.Add($col)
    }
    foreach ($r in $Rows) {
        $values = New-Object 'System.Collections.Generic.List[object]'
        foreach ($c in $Columns) {
            $v = $r.$c
            if ($v -is [DBNull]) { $v = $null }
            if ($null -ne $v -and $types[$c] -eq [string]) { $v = [string]$v }
            $values.Add($v)
        }
        $null = $Grid.Rows.Add($values.ToArray())
    }
    $Grid.ResumeLayout()
}

function Get-GuiCurrentResult {
    $g = $script:App
    $i = $g.Picker.SelectedIndex
    if ($i -ge 0 -and $i -lt @($g.Results).Count) { return $g.Results[$i] }
    return $null
}

function Get-GuiHistogramRows($D) {
    # Grid and chart rows for the histogram: from the edit model when there is one; Item links back to it.
    $model = $D.EditModel
    if (-not $model) {
        return @($D.Histogram | ForEach-Object {
                [pscustomobject]@{
                    Step = $_.Step; RANGE_HI_KEY = $_.RangeHiKeyText; RANGE_ROWS = $_.RangeRows; EQ_ROWS = $_.EqRows
                    DISTINCT_RANGE_ROWS = $_.DistinctRangeRows; AVG_RANGE_ROWS = $_.AvgRangeRows; RecOffset = $_.RecordOffset; RecLen = $_.RecordLength; Item = $null
                }
            })
    }
    $steps = $model.Steps.ToArray()
    $rows = for ($i = 0; $i -lt $steps.Count; $i++) {
        $st = $steps[$i]
        $disp = Get-StatsStepDisplay $st.RangeRows $st.StoredAvg
        $offset = $null; $length = $null
        if ($st.Source -and -not $st.IsNull) { $offset = $st.Source.RecordOffset; $length = $st.Source.RecordLength }
        [pscustomobject]@{
            Step = $i + 1; RANGE_HI_KEY = $st.Key; RANGE_ROWS = $st.RangeRows; EQ_ROWS = $st.EqRows
            DISTINCT_RANGE_ROWS = $disp.Distinct; AVG_RANGE_ROWS = $disp.Avg; RecOffset = $offset; RecLen = $length; Item = $st
        }
    }
    return @($rows)
}

function Format-GuiHeaderValue($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss.fff', $script:Inv) }
    if ($Value -is [single] -or $Value -is [double]) { return $Value.ToString('R', $script:Inv) }
    return [string]$Value
}

function ConvertFrom-GuiNumber([string]$Text) {
    # Invariant numbers; a lone decimal comma (pt-BR keyboards) is accepted too.
    $t = $Text.Trim()
    if ($t -match '^[+-]?\d*,\d+$') { $t = $t.Replace(',', '.') }
    return [double]::Parse($t, [Globalization.NumberStyles]::Float, $script:Inv)
}

function ConvertFrom-GuiHeaderValue([string]$Field, [string]$Text, $Current) {
    # Parses a STAT_HEADER value in the type the model keeps; throws a message for the status bar.
    if ($Current -is [datetime]) {
        try { return [datetime]::Parse($Text.Trim(), $script:Inv) } catch { throw "$Field needs a date and time, for example 2026-01-31 13:45:00.000." }
    }
    try { $v = ConvertFrom-GuiNumber $Text } catch { throw "$Field needs a number." }
    if ($v -lt 0) { throw "$Field cannot be negative." }
    if ($Current -is [int64]) {
        if ($v -ne [Math]::Floor($v)) { throw "$Field needs a whole number." }
        return [int64]$v
    }
    if ($Field -eq 'Persisted sample percent' -and $v -gt 100) { throw 'The sample percent cannot be above 100.' }
    if ($Current -is [double]) { return [double]$v }
    return [single]$v
}

function Get-GuiKeyFixedLength($Step) {
    $rec = $Step.Template.Record
    if ($rec.FixedEnd -gt 16) { return $rec.FixedEnd - 16 }
    return 0
}

function Test-GuiKeyEditable($D) {
    # Key types ConvertTo-SqlKeyBytes can encode (not sql_variant, hierarchyid or other CLR types).
    return $D.Columns[0].SystemTypeId -in 48, 52, 56, 127, 104, 59, 62, 60, 122, 106, 108, 40, 41, 42, 43, 61, 58, 36, 175, 167, 35, 239, 231, 99, 173, 165, 189
}

function Show-GuiResult($D) {
    $g = $script:App
    if (-not $D) {
        foreach ($grid in $g.Grids.Values) { $grid.Rows.Clear(); $grid.Columns.Clear() }
        $g.ChartSteps = @(); $g.Chart.Invalidate()
        Show-GuiTrie $null
        $g.CheckFindings.Text = ''
        Set-GuiEditMode
        Update-GuiCommandState
        return
    }
    if (-not $D.PSObject.Properties['EditModel']) { $D | Add-Member EditModel (New-StatsEditModel $D) }
    $model = $D.EditModel
    $g.Loading = $true
    try {
        # header (STAT_HEADER fields the stream carries), then two read-only totals
        $headerRows = @()
        if ($model) {
            foreach ($k in $model.Header.Keys) { $headerRows += [pscustomobject]@{ Field = $k; Value = (Format-GuiHeaderValue $model.Header[$k]); Original = (Format-GuiHeaderValue $model.OriginalHeader[$k]); Tag = $k } }
            $headerRows += [pscustomobject]@{ Field = 'Steps (from the histogram)'; Value = ''; Original = [string]@($D.Histogram).Count; Tag = '#steps' }
            $headerRows += [pscustomobject]@{ Field = 'Histogram rows (RANGE_ROWS + EQ_ROWS)'; Value = ''; Original = ''; Tag = '#total' }
        }
        Set-GuiGrid $g.Grids.Header $headerRows Field, Value, Original
        for ($i = 0; $i -lt $headerRows.Count; $i++) { $g.Grids.Header.Rows[$i].Tag = $headerRows[$i].Tag }

        $hist = Get-GuiHistogramRows $D
        Set-GuiGrid $g.Grids.Histogram $hist Step, RANGE_HI_KEY, RANGE_ROWS, EQ_ROWS, DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS, RecOffset, RecLen
        for ($i = 0; $i -lt $hist.Count; $i++) { $g.Grids.Histogram.Rows[$i].Tag = $hist[$i].Item }
        $g.Grids.Histogram.ClearSelection()
        $g.ChartHover = -1; $g.ChartSelected = -1
        Update-GuiChartSteps $hist

        Show-GuiDensity $D
        Show-GuiTrie $D
        Set-GuiGrid $g.Grids.Columns $D.Columns Ordinal, Name, TypeName, MaxLength, Precision, Scale, IsNullable, Collation, CodePage
        Set-GuiGrid $g.Grids.TraceFlag $D.TraceFlag2388 'Updated', 'Table Cardinality', 'Snapshot Ctr', 'Steps', 'Density', 'Rows Above', 'Rows Below',
        'Squared Variance Error', 'Inserts Since Last Update', 'Deletes Since Last Update', 'Leading column Type'
        $validation = $null
        if ($D.PSObject.Properties['Validation']) { $validation = $D.Validation }
        Set-GuiGrid $g.Grids.Validation $validation Check, Server, Decoded, Result
        Show-GuiDataCheck $D
    } finally { $g.Loading = $false }
    Set-GuiEditMode
}

function Show-GuiDensity($D) {
    $g = $script:App
    $rows = @()
    if ($D.EditModel) {
        [single]$run = 0
        foreach ($v in $D.EditModel.Vectors) {
            if ($null -ne $v.ColumnAverageLength) { $run = [single]($run + $v.ColumnAverageLength) }
            $rows += [pscustomobject]@{ Vector = $v.Vector; 'All density' = $v.AllDensity; 'Average Length' = $run; 'Column avg length (stored)' = $v.ColumnAverageLength; Columns = $v.Columns; Item = $v }
        }
    } else {
        $rows = @($D.DensityVector | ForEach-Object { [pscustomobject]@{ Vector = $_.Vector; 'All density' = $_.AllDensity; 'Average Length' = $_.AverageLength; 'Column avg length (stored)' = $_.ColumnAverageLength; Columns = $_.Columns; Item = $null } })
    }
    Set-GuiGrid $g.Grids.Density $rows Vector, 'All density', 'Average Length', 'Column avg length (stored)', Columns
    for ($i = 0; $i -lt $rows.Count; $i++) { $g.Grids.Density.Rows[$i].Tag = $rows[$i].Item }
}

function Update-GuiChartSteps($Rows) {
    $g = $script:App
    $g.ChartSteps = @($Rows)
    $w = 0
    foreach ($h in $g.ChartSteps) { $w = [Math]::Max($w, [Windows.Forms.TextRenderer]::MeasureText([string]$h.RANGE_HI_KEY, $g.ChartFont).Width) }
    $g.ChartLabelWidth = $w
    $g.Chart.Invalidate()
}

function Set-GuiEditMode {
    # Which cells can be edited; called when the grids are rebuilt or edit mode changes.
    $g = $script:App
    $D = Get-GuiCurrentResult
    $model = $null
    if ($D -and $D.PSObject.Properties['EditModel']) { $model = $D.EditModel }
    $g.EditMode.Enabled = [bool]$model
    $on = $g.EditMode.Checked -and $model
    foreach ($name in 'Header', 'Histogram', 'Density') {
        $grid = $g.Grids[$name]
        $grid.ReadOnly = -not $on
        if (-not $on) { continue }
        foreach ($col in $grid.Columns) {
            $editable = switch ($name) {
                'Header' { $col.Name -eq 'Value' }
                'Histogram' { $col.Name -in 'RANGE_ROWS', 'EQ_ROWS', 'DISTINCT_RANGE_ROWS', 'AVG_RANGE_ROWS' -or ($col.Name -eq 'RANGE_HI_KEY' -and (Test-GuiKeyEditable $D)) }
                'Density' { $col.Name -in 'All density', 'Column avg length (stored)' }
            }
            $col.ReadOnly = -not $editable
        }
        if ($name -eq 'Header') { foreach ($row in $grid.Rows) { if ([string]$row.Tag -like '#*') { $row.ReadOnly = $true } } }
        if ($name -eq 'Histogram') {
            # the NULL step only has EQ_ROWS
            foreach ($row in $grid.Rows) {
                if ($row.Tag -and $row.Tag.IsNull) { foreach ($c in 'RANGE_HI_KEY', 'RANGE_ROWS', 'DISTINCT_RANGE_ROWS', 'AVG_RANGE_ROWS') { $row.Cells[$c].ReadOnly = $true } }
            }
        }
    }
    $g.Grids.Histogram.ContextMenuStrip = $(if ($on) { $g.HistMenu } else { $null })
    Update-GuiEditState
}

function Update-GuiEditState {
    # Change count, buttons and the Header totals; called after every edit.
    $g = $script:App
    $D = Get-GuiCurrentResult
    $model = $null
    if ($D -and $D.PSObject.Properties['EditModel']) { $model = $D.EditModel }
    $count = 0
    if ($model) { $count = (Get-StatsEditChanges $model).Count }
    $g.Generate.Enabled = $count -gt 0
    $g.Discard.Enabled = $count -gt 0
    $g.EditInfo.Text = $(if (-not $model -and $D) { 'empty statistics: nothing to edit' } elseif ($count -eq 1) { '1 change' } elseif ($count) { "$count changes" } else { '' })
    Update-GuiHeaderTotals
}

function Update-GuiHeaderTotals {
    # The read-only totals at the bottom of the Header grid follow the histogram edits.
    $g = $script:App
    $D = Get-GuiCurrentResult
    if (-not $D -or -not $D.EditModel) { return }
    $steps = $D.EditModel.Steps.ToArray()
    [double]$total = 0
    foreach ($st in $steps) { $total += [double]$st.RangeRows + [double]$st.EqRows }
    [double]$orig = 0
    foreach ($st in $D.Histogram) { $orig += [double]$st.RangeRows + [double]$st.EqRows }
    $wasLoading = $g.Loading
    $g.Loading = $true
    try {
        foreach ($row in $g.Grids.Header.Rows) {
            if ($row.Tag -eq '#steps') { $row.Cells['Value'].Value = [string]$steps.Count }
            if ($row.Tag -eq '#total') { $row.Cells['Value'].Value = $total.ToString('#,0.##', $script:Inv); $row.Cells['Original'].Value = $orig.ToString('#,0.##', $script:Inv) }
        }
    } finally { $g.Loading = $wasLoading }
}

function Test-GuiCellValue($Grid, [int]$RowIndex, [string]$Column, [string]$Text) {
    # Returns why the typed value cannot be used, or $null when it can.
    $D = Get-GuiCurrentResult
    $row = $Grid.Rows[$RowIndex]
    try {
        switch ($Grid.Name) {
            'Header' { $null = ConvertFrom-GuiHeaderValue $row.Cells['Field'].Value $Text $D.EditModel.Header[[string]$row.Tag] }
            'Density' {
                try { $v = ConvertFrom-GuiNumber $Text } catch { return "$Column needs a number." }
                if ($v -lt 0) { return "$Column cannot be negative." }
                if ($Column -eq 'All density' -and $v -gt 1) { return 'All density is 1 / distinct values, so it cannot be above 1.' }
            }
            'Histogram' {
                $st = $row.Tag
                if ($Column -eq 'RANGE_HI_KEY') {
                    if ($Text -eq '') { return 'Type a RANGE_HI_KEY value.' }
                    try { $null = ConvertTo-SqlKeyBytes $Text $D.Columns[0] (Get-GuiKeyFixedLength $st) }
                    catch {
                        # .NET parse errors say little; the encoder's own messages say what is wrong
                        if ($_.Exception -is [Management.Automation.MethodInvocationException] -or $_.Exception.InnerException) { return "'$Text' is not a valid $($D.Columns[0].TypeName) value." }
                        return $_.Exception.Message
                    }
                    return $null
                }
                try { $v = ConvertFrom-GuiNumber $Text } catch { return "$Column needs a number." }
                if ($v -lt 0) { return "$Column cannot be negative." }
                if ($Column -eq 'DISTINCT_RANGE_ROWS') {
                    if ($st.RangeRows -gt 0 -and $v -le 0) { return 'DISTINCT_RANGE_ROWS must be above 0 while RANGE_ROWS is above 0.' }
                    if ($v -gt $st.RangeRows) { return 'DISTINCT_RANGE_ROWS cannot be above RANGE_ROWS.' }
                }
                if ($Column -eq 'AVG_RANGE_ROWS' -and $st.RangeRows -gt 0 -and $v -le 0) { return 'AVG_RANGE_ROWS must be above 0 while RANGE_ROWS is above 0.' }
            }
        }
    } catch { return $_.Exception.Message }
    return $null
}

function Get-GuiModelCellValue($Grid, $Row, [string]$Column) {
    # The model's current value for a cell (puts a refused edit back).
    $item = $Row.Tag
    switch ($Grid.Name) {
        'Header' { return Format-GuiHeaderValue (Get-GuiCurrentResult).EditModel.Header[[string]$item] }
        'Density' { if ($Column -eq 'All density') { return $item.AllDensity } else { return $item.ColumnAverageLength } }
        'Histogram' {
            $disp = Get-StatsStepDisplay $item.RangeRows $item.StoredAvg
            switch ($Column) {
                'RANGE_HI_KEY' { return $item.Key }
                'RANGE_ROWS' { return $item.RangeRows }
                'EQ_ROWS' { return $item.EqRows }
                'DISTINCT_RANGE_ROWS' { return $disp.Distinct }
                'AVG_RANGE_ROWS' { return $disp.Avg }
            }
        }
    }
}

function Update-GuiModelFromCell($Grid, [int]$RowIndex, [int]$ColumnIndex) {
    # An edit: check it again (not every commit path raises CellValidating), write it to the model,
    # then refresh the values derived from it. A refused value is replaced by the model's value.
    $g = $script:App
    $D = Get-GuiCurrentResult
    $model = $D.EditModel
    $row = $Grid.Rows[$RowIndex]
    $column = $Grid.Columns[$ColumnIndex].Name
    $cell = $row.Cells[$ColumnIndex]
    $text = $(if ($cell.Value -is [single] -or $cell.Value -is [double]) { $cell.Value.ToString('R', $script:Inv) } else { [string]$cell.Value })
    $problem = Test-GuiCellValue $Grid $RowIndex $column $text
    if ($problem) {
        $g.Loading = $true
        try { $cell.Value = Get-GuiModelCellValue $Grid $row $column } finally { $g.Loading = $false }
        Set-GuiStatus $problem
        [Media.SystemSounds]::Beep.Play()
        return
    }
    $g.Loading = $true
    try {
        switch ($Grid.Name) {
            'Header' {
                $field = [string]$row.Tag
                $model.Header[$field] = ConvertFrom-GuiHeaderValue $field ([string]$cell.Value) $model.Header[$field]
                $cell.Value = Format-GuiHeaderValue $model.Header[$field]
            }
            'Density' {
                $v = $row.Tag
                $value = [single](ConvertFrom-GuiNumber ([string]$cell.Value))
                if ($column -eq 'All density') { $v.AllDensity = $value } else { $v.ColumnAverageLength = $value }
                # Average Length is the running sum of the stored per-column lengths
                [single]$run = 0
                foreach ($r in $Grid.Rows) { if ($r.Tag) { $run = [single]($run + $r.Tag.ColumnAverageLength); $r.Cells['Average Length'].Value = $run } }
            }
            'Histogram' {
                $st = $row.Tag
                $before = Get-StatsStepDisplay $st.RangeRows $st.StoredAvg
                switch ($column) {
                    'RANGE_HI_KEY' {
                        $st.KeyBytes = ConvertTo-SqlKeyBytes ([string]$cell.Value) $D.Columns[0] (Get-GuiKeyFixedLength $st)
                        $st.Key = Format-StatsKey $st.KeyBytes $D.Columns[0]
                        $cell.Value = $st.Key
                    }
                    'EQ_ROWS' { $st.EqRows = [single](ConvertFrom-GuiNumber ([string]$cell.Value)) }
                    'RANGE_ROWS' {
                        # keep DISTINCT_RANGE_ROWS, so AVG_RANGE_ROWS follows the new RANGE_ROWS
                        $st.RangeRows = [single](ConvertFrom-GuiNumber ([string]$cell.Value))
                        $distinct = [Math]::Min([double]$before.Distinct, [double]$st.RangeRows)
                        if ($st.RangeRows -gt 0 -and $distinct -le 0) { $distinct = 1 }
                        $st.StoredAvg = $(if ($st.RangeRows -gt 0) { [single]($st.RangeRows / $distinct) } else { [single]1 })
                    }
                    'DISTINCT_RANGE_ROWS' {
                        $distinct = ConvertFrom-GuiNumber ([string]$cell.Value)
                        $st.StoredAvg = $(if ($st.RangeRows -gt 0 -and $distinct -gt 0) { [single]($st.RangeRows / $distinct) } else { [single]1 })
                    }
                    'AVG_RANGE_ROWS' { $st.StoredAvg = [single](ConvertFrom-GuiNumber ([string]$cell.Value)) }
                }
                $after = Get-StatsStepDisplay $st.RangeRows $st.StoredAvg
                $row.Cells['DISTINCT_RANGE_ROWS'].Value = $after.Distinct
                $row.Cells['AVG_RANGE_ROWS'].Value = $after.Avg
                Update-GuiChartSteps (Get-GuiHistogramRows $D)
            }
        }
    } finally { $g.Loading = $false }
    $Grid.InvalidateRow($RowIndex)
    Update-GuiEditState
}

function Test-GuiCellEdited($Grid, $Row, [string]$Column) {
    # True when the cell differs from the decoded statistics (drawn highlighted).
    $item = $Row.Tag
    if (-not $item) { return $false }
    switch ($Grid.Name) {
        'Header' {
            if ($Column -ne 'Value' -or [string]$item -like '#*') { return $false }
            return [string]$Row.Cells['Value'].Value -ne [string]$Row.Cells['Original'].Value
        }
        'Density' {
            if ($Column -eq 'All density') { return $item.AllDensity -ne $item.Source.AllDensity }
            if ($Column -eq 'Column avg length (stored)') { return $item.ColumnAverageLength -ne $item.Source.ColumnAverageLength }
            return $false
        }
        'Histogram' {
            if (-not $item.Source) { return $Column -ne 'RecOffset' -and $Column -ne 'RecLen' }
            $src = $item.Source
            switch ($Column) {
                'RANGE_HI_KEY' { return -not $item.IsNull -and [Convert]::ToBase64String($item.KeyBytes) -ne [Convert]::ToBase64String([byte[]]$src.Record.KeyBytes) }
                'RANGE_ROWS' { return $item.RangeRows -ne [single]$src.RangeRows }
                'EQ_ROWS' { return $item.EqRows -ne [single]$src.EqRows }
                'DISTINCT_RANGE_ROWS' { return (Get-StatsStepDisplay $item.RangeRows $item.StoredAvg).Distinct -ne [single]$src.DistinctRangeRows }
                'AVG_RANGE_ROWS' { return (Get-StatsStepDisplay $item.RangeRows $item.StoredAvg).Avg -ne [single]$src.AvgRangeRows }
            }
        }
    }
    return $false
}

function Get-GuiEditedColor {
    # Edited cells: an amber tint that keeps the text readable in both themes.
    if ($script:GuiTheme -eq 'Dark') { return [Drawing.ColorTranslator]::FromHtml('#5A4A1E') }
    return [Drawing.ColorTranslator]::FromHtml('#FFF0C2')
}

function Invoke-GuiStepEdit([string]$Action) {
    # Histogram context menu: InsertAbove, InsertBelow, Delete.
    $g = $script:App
    $D = Get-GuiCurrentResult
    $grid = $g.Grids.Histogram
    if (-not $D -or -not $D.EditModel -or -not $grid.CurrentRow) { return }
    $steps = $D.EditModel.Steps
    $current = $grid.CurrentRow.Tag
    $at = $steps.IndexOf($current)
    if ($Action -eq 'Delete') {
        $remove = @($grid.SelectedCells | ForEach-Object { $_.RowIndex } | Select-Object -Unique | ForEach-Object { $grid.Rows[$_].Tag })
        if (-not $remove) { $remove = @($current) }
        $left = @($steps.ToArray() | Where-Object { -not $_.IsNull -and $remove -notcontains $_ })
        if (@($steps.ToArray() | Where-Object { -not $_.IsNull }).Count -gt 0 -and $left.Count -eq 0) { Set-GuiStatus 'Keep at least one histogram step with a key.'; return }
        foreach ($st in $remove) { $null = $steps.Remove($st) }
        $select = [Math]::Min($at, $steps.Count - 1)
    } else {
        if (-not (Test-GuiKeyEditable $D)) { Set-GuiStatus "Steps cannot be inserted: RANGE_HI_KEY is not editable for $($D.Columns[0].TypeName) keys."; return }
        $index = $(if ($Action -eq 'InsertAbove') { $at } else { $at + 1 })
        if ($index -eq 0 -and $steps.Count -gt 0 -and $steps[0].IsNull) { Set-GuiStatus 'The NULL step stays first: insert below it.'; return }
        # the new step copies the record layout of the nearest key step
        $template = @($steps.ToArray() | Where-Object { -not $_.IsNull }) | Sort-Object { [Math]::Abs($steps.IndexOf($_) - $index) } | Select-Object -First 1
        if (-not $template) { Set-GuiStatus 'This histogram has no key step to copy the record layout from.'; return }
        $steps.Insert($index, (New-StatsEditStep $null $D.Columns[0] $template))
        $select = $index
    }
    $first = $grid.FirstDisplayedScrollingRowIndex
    Show-GuiResult $D
    if ($first -ge 0 -and $first -lt $grid.Rows.Count) { $grid.FirstDisplayedScrollingRowIndex = $first }
    if ($select -ge 0 -and $select -lt $grid.Rows.Count) {
        $grid.ClearSelection()
        $grid.CurrentCell = $grid.Rows[$select].Cells['RANGE_HI_KEY']
        if ($Action -ne 'Delete') { Set-GuiStatus 'Type the RANGE_HI_KEY of the new step (keys stay in ascending order).'; $null = $grid.BeginEdit($true) }
    }
}

function Show-GuiScriptDialog {
    # Builds the edited STATS_STREAM, checks it decodes back to the edits, and shows the T-SQL to load it.
    $g = $script:App
    $D = Get-GuiCurrentResult
    if (-not $D -or -not $D.EditModel) { return }
    foreach ($grid in $g.Grids.Values) { $null = $grid.EndEdit() }
    $model = $D.EditModel
    try {
        $built = ConvertTo-StatsStream $model
        $bad = Test-StatsStreamMatchesModel $built.Bytes $model
    } catch { Show-GuiMessage $_.Exception.Message 'Warning'; return }
    if ($bad) { Show-GuiMessage ("The new STATS_STREAM does not decode back to the edited values: $($bad -join ', '). Nothing was generated.") 'Error'; return }
    $changes = Get-StatsEditChanges $model

    $dlg = New-GuiControl Form @{
        Text = 'UPDATE STATISTICS script'; StartPosition = 'CenterParent'; Font = $g.Form.Font
        Size = (New-Object Drawing.Size 1100, 720); MinimumSize = (New-Object Drawing.Size 760, 480); ShowInTaskbar = $false
    }
    if ($g.Icon) { $dlg.Icon = $g.Icon }
    $layout = New-GuiControl TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 2; Padding = (New-Object Windows.Forms.Padding 10) }
    $null = $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'AutoSize'))
    $null = $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    $target = $null
    if ($D.PSObject.Properties['Target']) { $target = $D.Target }
    $fields = [ordered]@{}
    foreach ($f in @(@('Database', 'Database'), @('Table', 'Table (schema.table)'), @('Statistics', 'Statistics'))) {
        $row = $layout.RowCount; $layout.RowCount++
        $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle 'AutoSize'))
        $layout.Controls.Add((New-GuiControl Label @{ Text = $f[1]; AutoSize = $true; Anchor = 'Left'; Margin = (New-Object Windows.Forms.Padding 3, 6, 8, 3) }), 0, $row)
        $box = New-GuiControl TextBox @{ Anchor = 'Left, Right' }
        if ($target) { $box.Text = [string]$target.($f[0]) }
        $layout.Controls.Add($box, 1, $row)
        $fields[$f[0]] = $box
    }
    $options = New-GuiControl FlowLayoutPanel @{ AutoSize = $true; WrapContents = $true; Dock = 'Fill' }
    $noRecompute = New-GuiControl CheckBox @{ Text = 'NORECOMPUTE (stop automatic updates from replacing the edited statistics)'; AutoSize = $true; Checked = $true }
    $restore = New-GuiControl CheckBox @{ Text = 'Add a commented block that restores the original statistics'; AutoSize = $true; Checked = $true }
    $options.Controls.AddRange(@($noRecompute, $restore))
    $row = $layout.RowCount; $layout.RowCount++
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle 'AutoSize'))
    $layout.Controls.Add($options, 0, $row); $layout.SetColumnSpan($options, 2)
    $preview = New-GuiControl RichTextBox @{ Dock = 'Fill'; ReadOnly = $true; WordWrap = $false; DetectUrls = $false; Font = (New-Object Drawing.Font 'Consolas', 9.75) }
    $row = $layout.RowCount; $layout.RowCount++
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle 'Percent', 100))
    $layout.Controls.Add($preview, 0, $row); $layout.SetColumnSpan($preview, 2)
    $buttons = New-GuiControl FlowLayoutPanel @{ AutoSize = $true; Dock = 'Fill'; FlowDirection = 'RightToLeft' }
    $close = New-GuiControl Button @{ Text = 'Close'; AutoSize = $true; DialogResult = 'Cancel' }
    $copy = New-GuiControl Button @{ Text = 'Copy'; AutoSize = $true }
    $save = New-GuiControl Button @{ Text = 'Save as...'; AutoSize = $true; Tag = 'Primary' }
    $note = New-GuiControl Label @{ Text = 'The app only writes the script; run it yourself, on a test copy first.'; AutoSize = $true; Tag = 'Muted'; Margin = (New-Object Windows.Forms.Padding 3, 9, 16, 3) }
    $buttons.Controls.AddRange(@($close, $copy, $save, $note))
    $row = $layout.RowCount; $layout.RowCount++
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle 'AutoSize'))
    $layout.Controls.Add($buttons, 0, $row); $layout.SetColumnSpan($buttons, 2)
    $dlg.Controls.Add($layout)
    $dlg.CancelButton = $close

    # Handlers reach the dialog through $script:App (closures would not see this script's functions).
    $g.Dialog = @{
        Form = $dlg; Model = $model; Bytes = $built.Bytes; Warnings = $built.Warnings; Changes = $changes; Fields = $fields; NoRecompute = $noRecompute
        Restore = $restore; Script = $preview; Save = $save; Copy = $copy; OriginalNoRecompute = $(if ($target) { [bool]$target.NoRecompute } else { $false })
    }
    foreach ($box in $fields.Values) { $box.Add_TextChanged({ Update-GuiScriptPreview }) }
    $noRecompute.Add_CheckedChanged({ Update-GuiScriptPreview })
    $restore.Add_CheckedChanged({ Update-GuiScriptPreview })
    $copy.Add_Click({ [Windows.Forms.Clipboard]::SetText($script:App.Dialog.Script.Text); Set-GuiStatus 'Script copied to the clipboard.' })
    $save.Add_Click({
            $state = $script:App.Dialog
            $sfd = New-Object Windows.Forms.SaveFileDialog
            $sfd.Filter = 'SQL scripts|*.sql|All files|*.*'
            $name = (@($state.Fields.Table.Text, $state.Fields.Statistics.Text) | Where-Object { $_.Trim() }) -join '_' -replace '[\[\]\\/:*?"<>|\s]', ''
            $sfd.FileName = $(if ($name) { "UpdateStats_$name.sql" } else { 'UpdateStats.sql' })
            if ($sfd.ShowDialog($state.Form) -eq 'OK') {
                [IO.File]::WriteAllText($sfd.FileName, $state.Script.Text, (New-Object Text.UTF8Encoding $true))
                Set-GuiStatus "Script saved to $($sfd.FileName)."
            }
            $sfd.Dispose()
        })
    $dlg.Add_Load({ param($s, $e) Set-GuiControlTheme $s })
    Update-GuiScriptPreview
    try { $null = $dlg.ShowDialog($g.Form) }
    finally { $dlg.Dispose(); $g.Dialog = $null }
}

function Update-GuiScriptPreview {
    $state = $script:App.Dialog
    if (-not $state) { return }
    $f = $state.Fields
    $table = $(if ($f.Table.Text.Trim()) { $f.Table.Text.Trim() } else { '<schema.table>' })
    $stat = $(if ($f.Statistics.Text.Trim()) { $f.Statistics.Text.Trim() } else { '<statistics>' })
    $state.Script.Text = New-StatsUpdateScript -Model $state.Model -Bytes $state.Bytes -Database $f.Database.Text.Trim() -Table $table -Statistics $stat `
        -NoRecompute $state.NoRecompute.Checked -OriginalNoRecompute $state.OriginalNoRecompute -IncludeRestore $state.Restore.Checked -Changes $state.Changes -Warnings $state.Warnings
    # Save and Copy stay available without a target: the script then keeps the <schema.table> and <statistics> placeholders.
}

function Reset-GuiEdits {
    $D = Get-GuiCurrentResult
    if (-not $D) { return }
    $D.EditModel = New-StatsEditModel $D
    Show-GuiResult $D
    Set-GuiStatus 'Edits discarded.'
}

function Get-GuiPendingEdits {
    # Statistics objects with edits that have not been discarded (asked before a new decode replaces them).
    return @($script:App.Results | Where-Object { $_.PSObject.Properties['EditModel'] -and $_.EditModel -and (Get-StatsEditChanges $_.EditModel).Count -gt 0 })
}

function Get-GuiSeriesColors {
    # Categorical slots 1 and 2 (blue, orange) of the dataviz reference palette, stepped per theme and
    # validated (CVD separation, contrast >= 3:1) against the chart surface: #FFFFFF light, #292F38 dark.
    if ($script:GuiTheme -eq 'Dark') { $hex = '3987E5', 'D95926' } else { $hex = '2A78D6', 'EB6834' }
    return @($hex | ForEach-Object { [Drawing.ColorTranslator]::FromHtml('#' + $_) })
}

function Format-GuiAxisNumber([double]$Value) {
    $a = [Math]::Abs($Value)
    if ($a -ge 1e9) { return ($Value / 1e9).ToString('0.##', $script:Inv) + 'B' }
    if ($a -ge 1e6) { return ($Value / 1e6).ToString('0.##', $script:Inv) + 'M' }
    if ($a -ge 1e4) { return ($Value / 1e3).ToString('0.##', $script:Inv) + 'K' }
    return $Value.ToString('0.###', $script:Inv)
}

function Get-GuiNiceScale([double]$Max) {
    # About five round ticks (1, 2, 2.5 or 5 x 10^n) from 0 to just above the tallest bar.
    $ticks = New-Object 'System.Collections.Generic.List[double]'
    $raw = [Math]::Max($Max, 1.0) / 5
    $mag = [Math]::Pow(10, [Math]::Floor([Math]::Log10($raw)))
    $norm = $raw / $mag
    $step = $(if ($norm -le 1) { 1 } elseif ($norm -le 2) { 2 } elseif ($norm -le 2.5) { 2.5 } elseif ($norm -le 5) { 5 } else { 10 }) * $mag
    $hi = [Math]::Ceiling([Math]::Max($Max, 1.0) / $step) * $step
    for ($v = 0.0; $v -le $hi + $step / 2; $v += $step) { $ticks.Add($v) }
    return @{ Hi = $hi; Ticks = $ticks }
}

function Get-GuiHistogramLayout {
    # Two panels sharing the step positions: RANGE_ROWS on top, EQ_ROWS below, each with its own
    # y scale so a skew in one never flattens the other. $null when there is no room.
    $g = $script:App
    $steps = @($g.ChartSteps)
    if ($steps.Count -eq 0) { return $null }
    $scale = $g.Chart.DeviceDpi / 96.0
    $font = $g.ChartFont
    $panels = @()
    $labelWidth = 0
    foreach ($field in 'RANGE_ROWS', 'EQ_ROWS') {
        $max = 0.0; $sum = 0.0
        foreach ($st in $steps) { $v = [double]$st.$field; $sum += $v; if ($v -gt $max) { $max = $v } }
        $sc = Get-GuiNiceScale $max
        foreach ($t in $sc.Ticks) { $labelWidth = [Math]::Max($labelWidth, [Windows.Forms.TextRenderer]::MeasureText((Format-GuiAxisNumber $t), $font).Width) }
        $panels += @{ Field = $field; Hi = $sc.Hi; Ticks = $sc.Ticks; Average = $sum / $steps.Count }
    }
    # Both panels use the same left edge, so a step sits at the same x in each.
    $left = $labelWidth + 12 * $scale
    $right = $g.Chart.ClientSize.Width - 14 * $scale
    $title = 26 * $scale; $between = 14 * $scale; $top = 4 * $scale
    $bottom = $font.Height + 14 * $scale
    $plotHeight = ($g.Chart.ClientSize.Height - $top - 2 * $title - $between - $bottom) / 2
    if ($right - $left -lt 40 -or $plotHeight -lt 30) { return $null }
    $y = $top
    foreach ($pn in $panels) {
        $pn.TitleTop = $y
        $pn.Plot = New-Object Drawing.Rectangle ([int]$left), ([int]($y + $title)), ([int]($right - $left)), ([int]$plotHeight)
        $y += $title + $plotHeight + $between
    }
    $first = $panels[0].Plot; $last = $panels[1].Plot
    $all = New-Object Drawing.Rectangle $first.Left, $first.Top, $first.Width, ($last.Bottom - $first.Top)
    return @{ Panels = $panels; Plot = $all; Slot = $all.Width / $steps.Count; Scale = $scale }
}

function Get-GuiChartY($Panel, [double]$Value) {
    $p = $Panel.Plot
    $f = [Math]::Max(0.0, [Math]::Min(1.0, $Value / $Panel.Hi))
    return [single]($p.Bottom - $f * $p.Height)
}

function Get-GuiChartStepAt([Drawing.Point]$Point) {
    # Any point over either panel (or the gap between them) maps to the step in that column.
    $layout = $script:App.ChartLayout
    if (-not $layout) { return -1 }
    $p = $layout.Plot
    if ($Point.X -lt $p.Left -or $Point.X -ge $p.Right -or $Point.Y -lt $p.Top -or $Point.Y -gt $p.Bottom + 4) { return -1 }
    return [Math]::Min(@($script:App.ChartSteps).Count - 1, [int][Math]::Floor(($Point.X - $p.Left) / $layout.Slot))
}

function New-GuiTopRoundedPath([single]$X, [single]$Y, [single]$Width, [single]$Height, [single]$Radius) {
    # Bar shape: rounded data end, square at the baseline.
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $r = [Math]::Min($Radius, [Math]::Min($Width / 2, $Height / 2))
    if ($r -lt 1) { $path.AddRectangle((New-Object Drawing.RectangleF $X, $Y, $Width, $Height)); return $path }
    $d = 2 * $r
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $Width - $d, $Y, $d, $d, 270, 90)
    $path.AddLine($X + $Width, $Y + $r, $X + $Width, $Y + $Height)
    $path.AddLine($X + $Width, $Y + $Height, $X, $Y + $Height)
    $path.CloseFigure()
    return $path
}

function Invoke-GuiHistogramPaint([Drawing.Graphics]$Graphics) {
    # One panel per measure: RANGE_ROWS (rows between keys) and EQ_ROWS (rows equal to the key).
    $g = $script:App
    $pal = Get-GuiPalette
    $Graphics.Clear($pal.Surface)
    $font = $g.ChartFont
    $box = $g.Chart.ClientRectangle
    $steps = @($g.ChartSteps)
    $center = [Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter
    if ($steps.Count -eq 0) {
        $msg = $(if ($g.Results.Count) { 'No histogram for this statistics object.' } else { 'Decode a statistics object to see its histogram.' })
        [Windows.Forms.TextRenderer]::DrawText($Graphics, $msg, $font, $box, $pal.Muted, $center)
        $g.ChartLayout = $null
        return
    }
    $layout = Get-GuiHistogramLayout
    $g.ChartLayout = $layout
    if (-not $layout) { return }
    $s = $layout.Scale; $all = $layout.Plot; $slot = $layout.Slot
    $colors = Get-GuiSeriesColors
    $left = [Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::NoPadding
    $descriptions = @{ RANGE_ROWS = 'rows between the previous key and this key'; EQ_ROWS = 'rows equal to the key (RANGE_HI_KEY)' }
    $brushes = @(); $pens = @()
    try {
        $rangeBrush = New-Object Drawing.SolidBrush $colors[0]; $eqBrush = New-Object Drawing.SolidBrush $colors[1]
        $surfaceBrush = New-Object Drawing.SolidBrush $pal.Surface; $hoverBrush = New-Object Drawing.SolidBrush $pal.Alternate
        $selectBrush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(110, $pal.Selection))
        $gridPen = New-Object Drawing.Pen $pal.Border; $basePen = New-Object Drawing.Pen $pal.Muted
        # Average line: a dashed reference in the text color, so it never reads as another series.
        $avgPen = New-Object Drawing.Pen $pal.Text, ([single](1.5 * $s))
        $avgPen.DashPattern = [single[]]@(4, 3)
        $brushes = $rangeBrush, $eqBrush, $surfaceBrush, $hoverBrush, $selectBrush; $pens = $gridPen, $basePen, $avgPen
        $seriesBrushes = $rangeBrush, $eqBrush

        # bars: <= 24px with a 2px surface gap between neighbors
        $gap = $(if ($slot -ge 6 * $s) { 2 * $s } elseif ($slot -ge 3) { 1 } else { 0 })
        $bw = [Math]::Max(1.0, [Math]::Min(24 * $s, $slot - $gap))
        if ($bw -ge 2) { $bw = [Math]::Floor($bw) }
        $radius = $(if ($bw -ge 8 * $s) { 4 * $s } else { 0 })

        for ($n = 0; $n -lt $layout.Panels.Count; $n++) {
            $pn = $layout.Panels[$n]; $p = $pn.Plot; $brush = $seriesBrushes[$n]

            # title: one series per panel, so the title names it (no legend box)
            $x = [single]$p.Left
            $Graphics.FillRectangle($brush, $x, [single]($pn.TitleTop + 8 * $s), [single](10 * $s), [single](10 * $s))
            $tw = [Windows.Forms.TextRenderer]::MeasureText($pn.Field, $font).Width
            [Windows.Forms.TextRenderer]::DrawText($Graphics, $pn.Field, $font, (New-Object Drawing.Rectangle ([int]($x + 15 * $s)), ([int]$pn.TitleTop), $tw, ([int](26 * $s))), $pal.Text, $left)
            [Windows.Forms.TextRenderer]::DrawText($Graphics, $descriptions[$pn.Field], $font, (New-Object Drawing.Rectangle ([int]($x + 15 * $s + $tw + 10 * $s)), ([int]$pn.TitleTop), 420, ([int](26 * $s))), $pal.Muted, $left)

            # recessive grid and y labels
            foreach ($t in $pn.Ticks) {
                $y = Get-GuiChartY $pn $t
                if ($t -gt 0) { $Graphics.DrawLine($gridPen, [single]$p.Left, $y, [single]$p.Right, $y) }
                $r = New-Object Drawing.Rectangle 0, ([int]($y - 10 * $s)), ([int]($p.Left - 8 * $s)), ([int](20 * $s))
                [Windows.Forms.TextRenderer]::DrawText($Graphics, (Format-GuiAxisNumber $t), $font, $r, $pal.Muted, ([Windows.Forms.TextFormatFlags]::Right -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
            }

            # hover and selection bands behind the bars, in both panels
            foreach ($band in @(@($g.ChartSelected, $selectBrush), @($g.ChartHover, $hoverBrush))) {
                if ($band[0] -ge 0 -and $band[0] -lt $steps.Count) { $Graphics.FillRectangle($band[1], [single]($p.Left + $slot * $band[0]), [single]$p.Top, [single][Math]::Max(1.0, $slot), [single]$p.Height) }
            }

            $Graphics.SmoothingMode = 'AntiAlias'
            for ($i = 0; $i -lt $steps.Count; $i++) {
                $v = [double]$steps[$i].($pn.Field)
                if ($v -le 0) { continue }
                $x0 = [single][Math]::Round($p.Left + $slot * ($i + 0.5) - $bw / 2)
                $yT = Get-GuiChartY $pn $v
                if ($p.Bottom - $yT -lt $s) { $yT = [single]($p.Bottom - $s) }
                $path = New-GuiTopRoundedPath $x0 $yT $bw ([single]($p.Bottom - $yT)) $radius
                $Graphics.FillPath($brush, $path); $path.Dispose()
            }
            $Graphics.SmoothingMode = 'None'
            $Graphics.DrawLine($basePen, [single]$p.Left, [single]$p.Bottom, [single]$p.Right, [single]$p.Bottom)

            # average of this measure over all steps, labeled at the right end
            $ya = Get-GuiChartY $pn $pn.Average
            $Graphics.DrawLine($avgPen, [single]$p.Left, $ya, [single]$p.Right, $ya)
            $avgText = 'avg ' + $pn.Average.ToString('#,0.##', $script:Inv)
            $at = [Windows.Forms.TextRenderer]::MeasureText($avgText, $font)
            $ay = [int][Math]::Max($p.Top, $ya - $at.Height - 2 * $s)
            $ar = New-Object Drawing.Rectangle ([int]($p.Right - $at.Width - 4 * $s)), $ay, ([int]($at.Width + 4 * $s)), $at.Height
            $Graphics.FillRectangle($surfaceBrush, $ar)
            [Windows.Forms.TextRenderer]::DrawText($Graphics, $avgText, $font, $ar, $pal.Text, $center)
        }

        # x labels under the bottom panel: RANGE_HI_KEY on every k-th step so they never collide
        $p = $layout.Panels[$layout.Panels.Count - 1].Plot
        $lw = [int][Math]::Min([Math]::Max($g.ChartLabelWidth, 20), 140 * $s)
        $every = [Math]::Max(1, [int][Math]::Ceiling(($lw + 12 * $s) / $slot))
        for ($i = 0; $i -lt $steps.Count; $i += $every) {
            $cx = $p.Left + $slot * ($i + 0.5)
            $lx = [int][Math]::Max(0.0, [Math]::Min($cx - $lw / 2, $box.Width - $lw))
            $r = New-Object Drawing.Rectangle $lx, ([int]($p.Bottom + 4 * $s)), $lw, ($font.Height + 4)
            [Windows.Forms.TextRenderer]::DrawText($Graphics, [string]$steps[$i].RANGE_HI_KEY, $font, $r, $pal.Muted,
                ([Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis -bor [Windows.Forms.TextFormatFlags]::NoPrefix))
        }

        # hover readout, beside the hovered column at the top of the first panel
        $hi = $g.ChartHover
        if ($hi -ge 0 -and $hi -lt $steps.Count) {
            $st = $steps[$hi]
            $fmt = $(if ($g.FullPrecisionRun) { 'R' } else { 'G7' })
            $key = [string]$st.RANGE_HI_KEY
            if ($key.Length -gt 60) { $key = $key.Substring(0, 57) + '...' }
            # a step without a value (the NULL step's range columns) shows blank instead of failing the paint
            $rows = @(@('Step', [string]$st.Step), @('RANGE_HI_KEY', $key))
            foreach ($field in 'RANGE_ROWS', 'EQ_ROWS', 'DISTINCT_RANGE_ROWS', 'AVG_RANGE_ROWS') {
                $v = $st.$field
                $rows += , @($field, $(if ($v -is [IFormattable]) { $v.ToString($fmt, $script:Inv) } else { [string]$v }))
            }
            $c1 = 0; $c2 = 0
            foreach ($row in $rows) {
                $c1 = [Math]::Max($c1, [Windows.Forms.TextRenderer]::MeasureText($row[0], $font).Width)
                $c2 = [Math]::Max($c2, [Windows.Forms.TextRenderer]::MeasureText($row[1], $font).Width)
            }
            $lh = $font.Height + 2 * $s; $pad = 8 * $s
            $bwid = [int]($c1 + $c2 + 3 * $pad); $bht = [int]($rows.Count * $lh + 2 * $pad)
            $bx = $all.Left + $slot * ($hi + 1) + 8 * $s
            if ($bx + $bwid -gt $box.Width - 4) { $bx = $all.Left + $slot * $hi - 8 * $s - $bwid }
            $bx = [int][Math]::Max(4.0, $bx); $by = [int]($all.Top + 4 * $s)
            $bgBrush = New-Object Drawing.SolidBrush $pal.Background; $brushes += $bgBrush
            $Graphics.FillRectangle($bgBrush, $bx, $by, $bwid, $bht)
            $Graphics.DrawRectangle($gridPen, $bx, $by, $bwid - 1, $bht - 1)
            for ($k = 0; $k -lt $rows.Count; $k++) {
                $ry = [int]($by + $pad + $k * $lh)
                [Windows.Forms.TextRenderer]::DrawText($Graphics, $rows[$k][0], $font, (New-Object Drawing.Rectangle ([int]($bx + $pad)), $ry, $c1, ([int]$lh)), $pal.Muted, $left)
                [Windows.Forms.TextRenderer]::DrawText($Graphics, $rows[$k][1], $font, (New-Object Drawing.Rectangle ([int]($bx + 2 * $pad + $c1)), $ry, $c2, ([int]$lh)), $pal.Text, ($left -bor [Windows.Forms.TextFormatFlags]::NoPrefix))
            }
        }
    } finally {
        foreach ($b in $brushes) { $b.Dispose() }
        foreach ($pn in $pens) { $pn.Dispose() }
    }
}

function Select-GuiHistogramRow([int]$Index) {
    # Chart click -> the same step in the grid (which may be sorted differently).
    $g = $script:App
    $step = $g.ChartSteps[$Index].Step
    $grid = $g.Grids.Histogram
    foreach ($row in $grid.Rows) {
        if ([int]$row.Cells['Step'].Value -eq $step) {
            $grid.ClearSelection()
            $grid.CurrentCell = $row.Cells[0]
            $row.Selected = $true
            break
        }
    }
}

function Get-GuiTrieTree($Si) {
    # Parents and children from the nodes' pre-order depths. A virtual root holds several top-level nodes.
    $nodes = @($Si.Nodes)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Generic.List[int]'
    $shift = 0
    if (@($nodes | Where-Object { $_.Depth -eq 0 }).Count -ne 1) {
        $items.Add([pscustomobject]@{ Node = $null; Parent = -1; Depth = 0; Children = (New-Object 'System.Collections.Generic.List[int]') })
        $stack.Add(0); $shift = 1
    }
    foreach ($nd in $nodes) {
        $d = [int]$nd.Depth + $shift
        while ($stack.Count -gt $d) { $stack.RemoveAt($stack.Count - 1) }
        $parent = $(if ($stack.Count) { $stack[$stack.Count - 1] } else { -1 })
        $i = $items.Count
        $items.Add([pscustomobject]@{ Node = $nd; Parent = $parent; Depth = $(if ($parent -ge 0) { $items[$parent].Depth + 1 } else { 0 }); Children = (New-Object 'System.Collections.Generic.List[int]') })
        if ($parent -ge 0) { $items[$parent].Children.Add($i) }
        $stack.Add($i)
    }
    return , $items.ToArray()
}

function Get-GuiTrieLabel($Item) {
    # The node's segment; leading and trailing spaces are part of the strings, so they show as dots.
    $nd = $Item.Node
    if (-not $nd -or ($Item.Parent -lt 0 -and -not $nd.Segment)) { return '(root)' }
    $s = [string]$nd.Segment
    if ($s -eq '') { return '(empty)' }
    $dot = [string][char]0xB7
    if ($s.Trim(' ') -eq '') { return $dot * $s.Length }
    return ($dot * ($s.Length - $s.TrimStart(' ').Length)) + $s.Trim(' ') + ($dot * ($s.Length - $s.TrimEnd(' ').Length))
}

function Get-GuiTrieLayout($Items, [bool]$LeftToRight) {
    # Tidy tree: each subtree gets the breadth of its widest level of boxes, parents center over their children.
    # Top-down spreads siblings horizontally; left to right stacks them vertically. Units: 96-dpi pixels.
    $n = $Items.Count
    $font = $script:App.TrieFont
    $margin = 16.0; $padX = 8.0
    $labels = New-Object string[] $n; $counts = New-Object string[] $n; $w = New-Object double[] $n
    $bmp = New-Object Drawing.Bitmap 1, 1
    $gr = [Drawing.Graphics]::FromImage($bmp)
    try {
        $gr.TextRenderingHint = 'AntiAlias'
        $boxH = [Math]::Ceiling($font.GetHeight($gr)) + 10.0
        for ($i = 0; $i -lt $n; $i++) {
            $labels[$i] = Get-GuiTrieLabel $Items[$i]
            $nd = $Items[$i].Node
            $counts[$i] = $(if ($nd -and $nd.Count -gt 0) { [string][char]0xD7 + $nd.Count } else { '' })
            $width = $gr.MeasureString($labels[$i], $font).Width + 2 * $padX
            if ($counts[$i]) { $width += $gr.MeasureString($counts[$i], $font).Width + 2 }
            $w[$i] = [Math]::Max(30.0, [Math]::Ceiling($width))
        }
    } finally { $gr.Dispose(); $bmp.Dispose() }
    $gap = $(if ($LeftToRight) { 6.0 } else { 12.0 })
    $levelGap = $(if ($LeftToRight) { 44.0 } else { 34.0 })
    $size = New-Object double[] $n
    for ($i = 0; $i -lt $n; $i++) { $size[$i] = $(if ($LeftToRight) { $boxH } else { $w[$i] }) }
    # breadth of every subtree, children first (they follow their parent in pre-order)
    $sub = New-Object double[] $n
    for ($i = $n - 1; $i -ge 0; $i--) {
        $kids = $Items[$i].Children
        if ($kids.Count) {
            $span = $gap * ($kids.Count - 1)
            foreach ($k in $kids) { $span += $sub[$k] }
            $sub[$i] = [Math]::Max($size[$i], $span)
        } else { $sub[$i] = $size[$i] }
    }
    # where each subtree starts, parents first
    $start = New-Object double[] $n
    $next = $margin
    for ($i = 0; $i -lt $n; $i++) {
        if ($Items[$i].Parent -lt 0) { $start[$i] = $next; $next += $sub[$i] + $gap }
        $kids = $Items[$i].Children
        if ($kids.Count) {
            $span = $gap * ($kids.Count - 1)
            foreach ($k in $kids) { $span += $sub[$k] }
            $b = $start[$i] + ($sub[$i] - $span) / 2
            foreach ($k in $kids) { $start[$k] = $b; $b += $sub[$k] + $gap }
        }
    }
    # box centers: leaves in their slot, parents over their first and last child (kept inside their subtree)
    $center = New-Object double[] $n
    for ($i = $n - 1; $i -ge 0; $i--) {
        $kids = $Items[$i].Children
        if ($kids.Count) {
            $c = ($center[$kids[0]] + $center[$kids[$kids.Count - 1]]) / 2
            $center[$i] = [Math]::Min([Math]::Max($c, $start[$i] + $size[$i] / 2), $start[$i] + $sub[$i] - $size[$i] / 2)
        } else { $center[$i] = $start[$i] + $sub[$i] / 2 }
    }
    $maxDepth = 0
    foreach ($it in $Items) { if ($it.Depth -gt $maxDepth) { $maxDepth = $it.Depth } }
    $levelPos = New-Object double[] ($maxDepth + 1); $levelSize = New-Object double[] ($maxDepth + 1)
    for ($i = 0; $i -lt $n; $i++) {
        $d = $Items[$i].Depth
        $levelSize[$d] = [Math]::Max($levelSize[$d], $(if ($LeftToRight) { $w[$i] } else { $boxH }))
    }
    $pos = $margin
    for ($d = 0; $d -le $maxDepth; $d++) { $levelPos[$d] = $pos; $pos += $levelSize[$d] + $levelGap }
    $rects = New-Object 'System.Drawing.RectangleF[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $d = $Items[$i].Depth
        if ($LeftToRight) { $rects[$i] = New-Object Drawing.RectangleF ([single]$levelPos[$d]), ([single]($center[$i] - $boxH / 2)), ([single]$w[$i]), ([single]$boxH) }
        else { $rects[$i] = New-Object Drawing.RectangleF ([single]($center[$i] - $w[$i] / 2)), ([single]$levelPos[$d]), ([single]$w[$i]), ([single]$boxH) }
    }
    $breadth = $next - $gap + $margin
    $extent = $pos - $levelGap + $margin
    return @{
        Items = $Items; Rects = $rects; Labels = $labels; Counts = $counts; LeftToRight = $LeftToRight; PadX = $padX
        LevelPos = $levelPos; LevelSize = $levelSize; LevelGap = $levelGap
        Width = $(if ($LeftToRight) { $extent } else { $breadth }); Height = $(if ($LeftToRight) { $breadth } else { $extent })
    }
}

function New-GuiRoundedPath([Drawing.RectangleF]$Rect, [single]$Radius) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = 2 * $Radius
    $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90); $p.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90); $p.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Invoke-GuiTrieDraw([Drawing.Graphics]$Graphics, $L, [single]$Zoom, [single]$OffsetX, [single]$OffsetY, [Drawing.RectangleF]$Visible, [int]$Hover) {
    # Draws the layout in its own units, scaled and moved onto the target; only what intersects $Visible.
    $pal = Get-GuiPalette
    $blue = (Get-GuiSeriesColors)[0]
    $font = $script:App.TrieFont
    $s = $pal.Surface
    # complete strings: a light tint of the series blue over the surface
    $tint = [Drawing.Color]::FromArgb([int]($s.R + ($blue.R - $s.R) * 0.22), [int]($s.G + ($blue.G - $s.G) * 0.22), [int]($s.B + ($blue.B - $s.B) * 0.22))
    $onPath = @{}
    for ($i = $Hover; $i -ge 0; $i = $L.Items[$i].Parent) { $onPath[$i] = $true }
    $Graphics.TranslateTransform($OffsetX, $OffsetY); $Graphics.ScaleTransform($Zoom, $Zoom)
    $Graphics.SmoothingMode = 'AntiAlias'; $Graphics.TextRenderingHint = 'AntiAliasGridFit'
    $edgePen = New-Object Drawing.Pen $pal.Border, 1.2; $pathPen = New-Object Drawing.Pen $pal.Link, 2.2
    $nodePen = New-Object Drawing.Pen $pal.Border; $endPen = New-Object Drawing.Pen $blue, 1.4
    $nodeBrush = New-Object Drawing.SolidBrush $pal.Alternate; $endBrush = New-Object Drawing.SolidBrush $tint; $rootBrush = New-Object Drawing.SolidBrush $pal.Background
    $textBrush = New-Object Drawing.SolidBrush $pal.Text; $mutedBrush = New-Object Drawing.SolidBrush $pal.Muted
    $near = New-Object Drawing.StringFormat; $near.LineAlignment = 'Center'; $near.FormatFlags = 'NoWrap'
    $far = New-Object Drawing.StringFormat; $far.LineAlignment = 'Center'; $far.Alignment = 'Far'; $far.FormatFlags = 'NoWrap'
    try {
        $n = $L.Items.Count
        # connectors: plain ones first, the hovered path on top
        foreach ($pass in $false, $true) {
            for ($i = 0; $i -lt $n; $i++) {
                $p = $L.Items[$i].Parent
                if ($p -lt 0 -or $onPath.ContainsKey($i) -ne $pass) { continue }
                $a = $L.Rects[$p]; $b = $L.Rects[$i]
                if (-not [Drawing.RectangleF]::Union($a, $b).IntersectsWith($Visible)) { continue }
                $mid = $L.LevelPos[$L.Items[$p].Depth] + $L.LevelSize[$L.Items[$p].Depth] + $L.LevelGap / 2
                if ($L.LeftToRight) {
                    $y1 = $a.Y + $a.Height / 2; $y2 = $b.Y + $b.Height / 2
                    $pts = @((New-Object Drawing.PointF $a.Right, $y1), (New-Object Drawing.PointF $mid, $y1), (New-Object Drawing.PointF $mid, $y2), (New-Object Drawing.PointF $b.X, $y2))
                } else {
                    $x1 = $a.X + $a.Width / 2; $x2 = $b.X + $b.Width / 2
                    $pts = @((New-Object Drawing.PointF $x1, $a.Bottom), (New-Object Drawing.PointF $x1, $mid), (New-Object Drawing.PointF $x2, $mid), (New-Object Drawing.PointF $x2, $b.Y))
                }
                $Graphics.DrawLines($(if ($pass) { $pathPen } else { $edgePen }), [Drawing.PointF[]]$pts)
            }
        }
        for ($i = 0; $i -lt $n; $i++) {
            $r = $L.Rects[$i]
            if (-not $r.IntersectsWith($Visible)) { continue }
            $isEnd = [bool]$L.Counts[$i]
            $isRoot = $L.Items[$i].Parent -lt 0
            $shape = New-GuiRoundedPath $r 5
            $Graphics.FillPath($(if ($isEnd) { $endBrush } elseif ($isRoot) { $rootBrush } else { $nodeBrush }), $shape)
            $Graphics.DrawPath($(if ($onPath.ContainsKey($i)) { $pathPen } elseif ($isEnd) { $endPen } else { $nodePen }), $shape)
            $shape.Dispose()
            $inner = New-Object Drawing.RectangleF ($r.X + $L.PadX), $r.Y, ($r.Width - 2 * $L.PadX + 2), $r.Height
            $Graphics.DrawString($L.Labels[$i], $font, $(if ($isRoot) { $mutedBrush } else { $textBrush }), $inner, $near)
            if ($isEnd) { $Graphics.DrawString($L.Counts[$i], $font, $mutedBrush, $inner, $far) }
        }
    } finally {
        foreach ($o in $edgePen, $pathPen, $nodePen, $endPen, $nodeBrush, $endBrush, $rootBrush, $textBrush, $mutedBrush, $near, $far) { $o.Dispose() }
        $Graphics.ResetTransform()
    }
}

function Invoke-GuiTriePaint([Drawing.Graphics]$Graphics) {
    $g = $script:App
    $pal = Get-GuiPalette
    $Graphics.Clear($pal.Surface)
    $canvas = $g.TrieCanvas
    $L = $g.TrieLayout
    if (-not $L) {
        [Windows.Forms.TextRenderer]::DrawText($Graphics, $g.TrieMessage, $g.ChartFont, $canvas.ClientRectangle, $pal.Muted,
            ([Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::WordBreak))
        return
    }
    $z = [single]($g.TrieZoom * (Get-GuiScale))
    $sp = $canvas.AutoScrollPosition
    $visible = New-Object Drawing.RectangleF (-$sp.X / $z), (-$sp.Y / $z), ($canvas.ClientSize.Width / $z), ($canvas.ClientSize.Height / $z)
    Invoke-GuiTrieDraw $Graphics $L $z $sp.X $sp.Y $visible $g.TrieHover

    # hover readout beside the mouse, in screen units
    $h = $g.TrieHover
    if ($h -lt 0 -or $h -ge $L.Items.Count) { return }
    $it = $L.Items[$h]; $nd = $it.Node
    if ($it.Parent -lt 0) {
        $rows = @(, @('Root', 'every sampled string starts here'))
    } else {
        $text = [string]$nd.Text
        if ($text.Length -gt 80) { $text = $text.Substring(0, 77) + '...' }
        $rows = @(
            @($(if ($nd.Count -gt 0) { 'String' } else { 'Prefix' }), "'$text'"), @('Segment', "'$($nd.Segment)'")
            @('Strings ending here', [string]$nd.Count), @('Children', [string]$it.Children.Count), @('Depth', [string]$it.Depth)
            @('Node', ('#{0}, flags 0x{1:X2}, segment at char {2} ({3} chars)' -f $nd.Index, $nd.Flags, $nd.SegmentOffset, $nd.SegmentLength))
        )
    }
    $font = $g.ChartFont
    $sc = Get-GuiScale
    $c1 = 0; $c2 = 0
    foreach ($row in $rows) {
        $c1 = [Math]::Max($c1, [Windows.Forms.TextRenderer]::MeasureText($row[0], $font).Width)
        $c2 = [Math]::Max($c2, [Windows.Forms.TextRenderer]::MeasureText($row[1], $font, [Drawing.Size]::Empty, [Windows.Forms.TextFormatFlags]::NoPrefix).Width)
    }
    $lh = $font.Height + 2 * $sc; $pad = 8 * $sc
    $bw = [int]($c1 + $c2 + 3 * $pad); $bh = [int]($rows.Count * $lh + 2 * $pad)
    $m = $g.TrieMouse
    $bx = $m.X + 16 * $sc
    if ($bx + $bw -gt $canvas.ClientSize.Width - 4) { $bx = $m.X - 16 * $sc - $bw }
    $by = $m.Y + 16 * $sc
    if ($by + $bh -gt $canvas.ClientSize.Height - 4) { $by = $m.Y - 16 * $sc - $bh }
    $bx = [int][Math]::Max(4.0, $bx); $by = [int][Math]::Max(4.0, $by)
    $bg = New-Object Drawing.SolidBrush $pal.Background; $border = New-Object Drawing.Pen $pal.Border
    try {
        $Graphics.FillRectangle($bg, $bx, $by, $bw, $bh)
        $Graphics.DrawRectangle($border, $bx, $by, $bw - 1, $bh - 1)
        $left = [Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::NoPadding -bor [Windows.Forms.TextFormatFlags]::NoPrefix
        for ($k = 0; $k -lt $rows.Count; $k++) {
            $ry = [int]($by + $pad + $k * $lh)
            [Windows.Forms.TextRenderer]::DrawText($Graphics, $rows[$k][0], $font, (New-Object Drawing.Rectangle ([int]($bx + $pad)), $ry, $c1, ([int]$lh)), $pal.Muted, $left)
            [Windows.Forms.TextRenderer]::DrawText($Graphics, $rows[$k][1], $font, (New-Object Drawing.Rectangle ([int]($bx + 2 * $pad + $c1)), $ry, ($c2 + 2), ([int]$lh)), $pal.Text, $left)
        }
    } finally { $bg.Dispose(); $border.Dispose() }
}

function Get-GuiTrieNodeAt([Drawing.Point]$Point) {
    $g = $script:App
    $L = $g.TrieLayout
    if (-not $L) { return -1 }
    $z = $g.TrieZoom * (Get-GuiScale)
    $sp = $g.TrieCanvas.AutoScrollPosition
    $x = [single](($Point.X - $sp.X) / $z); $y = [single](($Point.Y - $sp.Y) / $z)
    for ($i = 0; $i -lt $L.Rects.Length; $i++) { if ($L.Rects[$i].Contains($x, $y)) { return $i } }
    return -1
}

function Update-GuiTrieCanvas {
    # Scroll range = the layout at the current zoom.
    $g = $script:App
    $L = $g.TrieLayout
    $z = $g.TrieZoom * (Get-GuiScale)
    $g.TrieCanvas.AutoScrollMinSize = $(if ($L) { New-Object Drawing.Size ([int][Math]::Ceiling($L.Width * $z)), ([int][Math]::Ceiling($L.Height * $z)) } else { [Drawing.Size]::Empty })
    $g.TrieZoomLabel.Text = $(if ($L) { '{0:0}%' -f ($g.TrieZoom * 100) } else { '' })
    $g.TrieCanvas.Invalidate()
}

function Get-GuiTrieFitZoom {
    $g = $script:App
    $L = $g.TrieLayout
    if (-not $L) { return 1.0 }
    $sc = Get-GuiScale
    $c = $g.TrieCanvas.ClientSize
    return [Math]::Max(0.1, [Math]::Min(1.0, [Math]::Min(($c.Width - 4) / ($L.Width * $sc), ($c.Height - 4) / ($L.Height * $sc))))
}

function Set-GuiTrieZoom([double]$Zoom, $Anchor) {
    # Keeps the layout point under $Anchor (the mouse, or the view center) in place.
    $g = $script:App
    if (-not $g.TrieLayout) { return }
    $canvas = $g.TrieCanvas
    if (-not $Anchor) { $Anchor = New-Object Drawing.Point ([int]($canvas.ClientSize.Width / 2)), ([int]($canvas.ClientSize.Height / 2)) }
    $sc = Get-GuiScale
    $old = $g.TrieZoom * $sc
    $sp = $canvas.AutoScrollPosition
    $lx = ($Anchor.X - $sp.X) / $old; $ly = ($Anchor.Y - $sp.Y) / $old
    $g.TrieZoom = [Math]::Min(3.0, [Math]::Max(0.1, $Zoom))
    Update-GuiTrieCanvas
    $new = $g.TrieZoom * $sc
    $canvas.AutoScrollPosition = New-Object Drawing.Point ([int][Math]::Max(0, $lx * $new - $Anchor.X)), ([int][Math]::Max(0, $ly * $new - $Anchor.Y))
    $canvas.Invalidate()
}

function Show-GuiTrie($D) {
    # String index tab for the selected statistics object; layouts are built once per orientation.
    $g = $script:App
    $si = $null
    if ($D -and $D.StringIndex -and @($D.StringIndex.Nodes).Count) { $si = $D.StringIndex }
    $g.TrieHover = -1
    if (-not $si) {
        $g.TrieLayout = $null
        $g.TrieMessage = $(if ($D) { 'No string index: SQL Server keeps one only for statistics whose first column is a string (char, varchar, nchar, nvarchar, text, ntext).' } else { 'Decode a statistics object to see its string index.' })
        $g.TrieSummary.Text = ''
    } else {
        if (-not $D.PSObject.Properties['TrieView']) { $D | Add-Member TrieView @{ Items = (Get-GuiTrieTree $si) } }
        $key = [string]$g.Settings.TrieOrientation
        if (-not $D.TrieView.ContainsKey($key)) { $D.TrieView[$key] = Get-GuiTrieLayout $D.TrieView.Items ($key -eq 'LeftToRight') }
        $g.TrieLayout = $D.TrieView[$key]
        $g.TrieSummary.Text = '{0} nodes, {1} strings sampled ({2} distinct, {3} NULL).' -f $si.NodeCount, $si.StringsSampled, $si.DistinctStrings, $si.NullsInSample
        # start at 100%, or zoomed out a little when that makes the whole tree fit
        $fit = Get-GuiTrieFitZoom
        $g.TrieZoom = $(if ($fit -lt 1 -and $fit -ge 0.6) { $fit } else { 1.0 })
    }
    foreach ($c in $g.TrieTools) { $c.Enabled = [bool]$si }
    Update-GuiTrieCanvas
    # open on the root: centered across a top-down tree, at the top of a left-to-right one
    $x = 0
    if ($g.TrieLayout -and -not $g.TrieLayout.LeftToRight) {
        $root = $g.TrieLayout.Rects[0]
        $x = [int][Math]::Max(0, ($root.X + $root.Width / 2) * $g.TrieZoom * (Get-GuiScale) - $g.TrieCanvas.ClientSize.Width / 2)
    }
    $g.TrieCanvas.AutoScrollPosition = New-Object Drawing.Point $x, 0
}

function Save-GuiTrieImage {
    # The whole tree as a PNG at twice the screen size (less for very large trees), in the current theme.
    $g = $script:App
    $L = $g.TrieLayout
    if (-not $L) { return }
    $z = [Math]::Min(2.0, [Math]::Sqrt(40e6 / ($L.Width * $L.Height)))
    $z = [Math]::Min($z, [Math]::Min(30000 / $L.Width, 30000 / $L.Height))
    $sfd = New-Object Windows.Forms.SaveFileDialog
    $sfd.Filter = 'PNG images|*.png'
    $sfd.FileName = 'StringIndex_' + ($g.Picker.Text -replace ' \(stats_id \d+\)$', '' -replace '[\[\]\\/:*?"<>|\s]', '') + '.png'
    try {
        if ($sfd.ShowDialog($g.Form) -ne 'OK') { return }
        $bmp = New-Object Drawing.Bitmap ([int][Math]::Ceiling($L.Width * $z)), ([int][Math]::Ceiling($L.Height * $z))
        $gr = [Drawing.Graphics]::FromImage($bmp)
        try {
            $gr.Clear((Get-GuiPalette).Surface)
            Invoke-GuiTrieDraw $gr $L ([single]$z) 0 0 (New-Object Drawing.RectangleF 0, 0, ([single]$L.Width), ([single]$L.Height)) -1
            $bmp.Save($sfd.FileName, [Drawing.Imaging.ImageFormat]::Png)
        } finally { $gr.Dispose(); $bmp.Dispose() }
        Set-GuiStatus "String index image saved to $($sfd.FileName)."
    } catch { Show-GuiMessage $_.Exception.Message 'Error' }
    finally { $sfd.Dispose() }
}

function New-GuiTriePage($Page) {
    # String index tab: a toolbar (orientation, zoom, save) over a scrollable, owner-drawn canvas.
    $g = $script:App
    $bar = New-GuiControl FlowLayoutPanel @{ Dock = 'Top'; AutoSize = $true; WrapContents = $true; Margin = (New-Object Windows.Forms.Padding 0) }
    $g.TrieSummary = New-GuiControl Label @{ AutoSize = $true; Margin = (New-Object Windows.Forms.Padding 3, 7, 14, 3) }
    $orientation = New-GuiControl ComboBox @{ DropDownStyle = 'DropDownList'; Width = 140; Margin = (New-Object Windows.Forms.Padding 3, 3, 10, 3) }
    $null = $orientation.Items.AddRange([object[]]@('Top-down', 'Left to right'))
    $orientation.SelectedIndex = $(if ($g.Settings.TrieOrientation -eq 'TopDown') { 0 } else { 1 })
    $buttonPadding = New-Object Windows.Forms.Padding 8, 1, 8, 1
    $zoomOut = New-GuiControl Button @{ Text = [string][char]0x2212; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; MinimumSize = (New-Object Drawing.Size 34, 0); Padding = $buttonPadding }
    $g.TrieZoomLabel = New-GuiControl Label @{ AutoSize = $true; MinimumSize = (New-Object Drawing.Size 46, 0); TextAlign = 'MiddleCenter'; Margin = (New-Object Windows.Forms.Padding 2, 7, 2, 3) }
    $zoomIn = New-GuiControl Button @{ Text = '+'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; MinimumSize = (New-Object Drawing.Size 34, 0); Padding = $buttonPadding }
    $fit = New-GuiControl Button @{ Text = 'Fit'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = $buttonPadding; Margin = (New-Object Windows.Forms.Padding 8, 3, 3, 3) }
    $actual = New-GuiControl Button @{ Text = 'Actual size'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = $buttonPadding }
    $save = New-GuiControl Button @{ Text = 'Save image...'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = $buttonPadding; Margin = (New-Object Windows.Forms.Padding 10, 3, 3, 3) }
    $hint = New-GuiControl Label @{ Text = 'Hover a node for its full string. Ctrl+wheel zooms, drag pans.'; AutoSize = $true; Tag = 'Muted'; Margin = (New-Object Windows.Forms.Padding 12, 7, 3, 3) }
    $bar.Controls.AddRange(@($g.TrieSummary, $orientation, $zoomOut, $g.TrieZoomLabel, $zoomIn, $fit, $actual, $save, $hint))
    $canvas = New-GuiControl Panel @{ Dock = 'Fill'; AutoScroll = $true }
    [Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic, Instance').SetValue($canvas, $true, $null)
    $Page.Controls.Add($canvas)
    $Page.Controls.Add($bar)
    $g.TrieCanvas = $canvas
    $g.TrieTools = @($orientation, $zoomOut, $zoomIn, $fit, $actual, $save)
    $g.TrieZoom = 1.0; $g.TrieHover = -1; $g.TrieMouse = [Drawing.Point]::Empty
    $g.TrieMessage = 'Decode a statistics object to see its string index.'

    $orientation.Add_SelectedIndexChanged({
            param($s, $e)
            $app = $script:App
            $app.Settings.TrieOrientation = $(if ($s.SelectedIndex -eq 1) { 'LeftToRight' } else { 'TopDown' })
            Save-GuiSettings
            Show-GuiTrie (Get-GuiCurrentResult)
        })
    $zoomOut.Add_Click({ Set-GuiTrieZoom ($script:App.TrieZoom / 1.25) })
    $zoomIn.Add_Click({ Set-GuiTrieZoom ($script:App.TrieZoom * 1.25) })
    $fit.Add_Click({ Set-GuiTrieZoom (Get-GuiTrieFitZoom); $script:App.TrieCanvas.AutoScrollPosition = New-Object Drawing.Point 0, 0 })
    $actual.Add_Click({ Set-GuiTrieZoom 1.0 })
    $save.Add_Click({ Save-GuiTrieImage })
    $canvas.Add_Paint({ param($s, $e) Invoke-GuiTriePaint $e.Graphics })
    $canvas.Add_Scroll({ $script:App.TrieCanvas.Invalidate() })
    $canvas.Add_Resize({ $script:App.TrieCanvas.Invalidate() })
    $canvas.Add_MouseDown({
            param($s, $e)
            if ($e.Button -ne 'Left') { return }
            $script:App.TrieDrag = @{ Start = $e.Location; Scroll = (New-Object Drawing.Point (-$s.AutoScrollPosition.X), (-$s.AutoScrollPosition.Y)) }
            $s.Cursor = [Windows.Forms.Cursors]::SizeAll
        })
    $canvas.Add_MouseUp({ param($s, $e) $script:App.TrieDrag = $null; $s.Cursor = [Windows.Forms.Cursors]::Default })
    $canvas.Add_MouseMove({
            param($s, $e)
            $app = $script:App
            $drag = $app.TrieDrag
            if ($drag) {
                $s.AutoScrollPosition = New-Object Drawing.Point ([int]($drag.Scroll.X - ($e.X - $drag.Start.X))), ([int]($drag.Scroll.Y - ($e.Y - $drag.Start.Y)))
                $s.Invalidate()
                return
            }
            $i = Get-GuiTrieNodeAt $e.Location
            $app.TrieMouse = $e.Location
            if ($i -ne $app.TrieHover -or $i -ge 0) { $app.TrieHover = $i; $s.Invalidate() }
        })
    $canvas.Add_MouseLeave({ if ($script:App.TrieHover -ge 0) { $script:App.TrieHover = -1; $script:App.TrieCanvas.Invalidate() } })
    $canvas.Add_MouseWheel({
            # Ctrl+wheel zooms at the mouse, Shift+wheel scrolls sideways; the plain wheel scrolls (Panel default).
            param($s, $e)
            $keys = [Windows.Forms.Control]::ModifierKeys
            if ($keys -band [Windows.Forms.Keys]::Control) {
                if ($e -is [Windows.Forms.HandledMouseEventArgs]) { $e.Handled = $true }
                Set-GuiTrieZoom ($script:App.TrieZoom * $(if ($e.Delta -gt 0) { 1.25 } else { 0.8 })) $e.Location
            } elseif ($keys -band [Windows.Forms.Keys]::Shift) {
                if ($e -is [Windows.Forms.HandledMouseEventArgs]) { $e.Handled = $true }
                $s.AutoScrollPosition = New-Object Drawing.Point ([int](-$s.AutoScrollPosition.X - $e.Delta)), (-$s.AutoScrollPosition.Y)
            }
            $s.Invalidate()
        })
}

function New-GuiDialog([string]$Title) {
    # A fixed dialog that sizes itself to a two-column layout (labels, controls).
    $g = $script:App
    $dlg = New-GuiControl Form @{
        Text = $Title; StartPosition = 'CenterParent'; Font = $g.Form.Font; ShowInTaskbar = $false; MaximizeBox = $false; MinimizeBox = $false
        FormBorderStyle = 'FixedDialog'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'
    }
    if ($g.Icon) { $dlg.Icon = $g.Icon }
    $layout = New-GuiControl TableLayoutPanel @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; ColumnCount = 2; Padding = (New-Object Windows.Forms.Padding 14, 10, 14, 12) }
    $null = $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'AutoSize'))
    $null = $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'AutoSize'))
    $dlg.Controls.Add($layout)
    $dlg.Add_Load({ param($s, $e) Set-GuiControlTheme $s })
    return @{ Form = $dlg; Layout = $layout }
}

function Add-GuiDialogButtons($Dialog, [string]$OkText = 'OK', [switch]$NoCancel) {
    # OK (primary) then Cancel, right aligned. The OK button has no DialogResult: its handler closes the dialog.
    $panel = New-GuiControl FlowLayoutPanel @{ AutoSize = $true; FlowDirection = 'RightToLeft'; WrapContents = $false; Anchor = 'Right'; Margin = (New-Object Windows.Forms.Padding 0, 16, 0, 0) }
    $size = New-Object Drawing.Size ([int](96 * (Get-GuiScale))), 0
    $cancel = $null
    if (-not $NoCancel) {
        $cancel = New-GuiControl Button @{ Text = 'Cancel'; AutoSize = $true; MinimumSize = $size; DialogResult = 'Cancel'; Padding = (New-Object Windows.Forms.Padding 8, 2, 8, 2) }
        $panel.Controls.Add($cancel)
    }
    $ok = New-GuiControl Button @{ Text = $OkText; AutoSize = $true; MinimumSize = $size; Tag = 'Primary'; Padding = (New-Object Windows.Forms.Padding 8, 2, 8, 2) }
    $panel.Controls.Add($ok)
    Add-GuiRow $Dialog.Layout '' $panel
    $Dialog.Form.AcceptButton = $ok
    $Dialog.Form.CancelButton = $(if ($cancel) { $cancel } else { $ok })
    return @{ Panel = $panel; Ok = $ok; Cancel = $cancel }
}

function Show-GuiConnectDialog {
    $g = $script:App
    $s = $g.Settings
    $d = New-GuiDialog 'Connect to SQL Server'
    $w = [int](360 * (Get-GuiScale))
    $server = New-GuiControl ComboBox @{ DropDownStyle = 'DropDown'; Width = $w; MaxDropDownItems = 12 }
    if ($s.Servers) { $server.Items.AddRange([object[]]@($s.Servers)) }
    $server.Text = $(if ($g.Conn) { $g.Conn.Server } else { [string]$s.ServerInstance })
    $auth = New-GuiControl ComboBox @{ DropDownStyle = 'DropDownList'; Width = $w }
    $null = $auth.Items.AddRange([object[]]@('Windows authentication', 'SQL Server authentication'))
    $auth.SelectedIndex = $(if ($s.SqlAuthentication) { 1 } else { 0 })
    $login = New-GuiControl TextBox @{ Width = $w; Text = [string]$s.Login }
    $password = New-GuiControl TextBox @{ Width = $w; UseSystemPasswordChar = $true }
    $trust = New-GuiControl CheckBox @{ Text = 'Trust server certificate'; AutoSize = $true; Checked = [bool]$s.TrustServerCertificate }
    Add-GuiRow $d.Layout 'Server' $server
    Add-GuiRow $d.Layout 'Authentication' $auth
    Add-GuiRow $d.Layout 'Login' $login
    Add-GuiRow $d.Layout 'Password' $password
    Add-GuiRow $d.Layout '' $trust
    $note = New-GuiControl Label @{ Text = 'The app only reads metadata and DBCC SHOW_STATISTICS output. The password is not saved.'; AutoSize = $true; Tag = 'Muted'; MaximumSize = (New-Object Drawing.Size ($w + 120), 0); Margin = (New-Object Windows.Forms.Padding 3, 10, 3, 0) }
    Add-GuiRow $d.Layout '' $note
    $buttons = Add-GuiDialogButtons $d 'Connect'

    # Handlers reach the dialog through $script:App (closures would not see this script's functions).
    $g.Dlg = @{ Form = $d.Form; Server = $server; Auth = $auth; Login = $login; Password = $password; Trust = $trust; Conn = $null; Databases = $null }
    $auth.Add_SelectedIndexChanged({ $x = $script:App.Dlg; $sql = $x.Auth.SelectedIndex -eq 1; $x.Login.Enabled = $sql; $x.Password.Enabled = $sql })
    $login.Enabled = $auth.SelectedIndex -eq 1; $password.Enabled = $auth.SelectedIndex -eq 1
    $buttons.Ok.Add_Click({ Invoke-GuiConnect })
    $d.Form.Add_Shown({
            $x = $script:App.Dlg
            if ($x.Server.Text -and $x.Auth.SelectedIndex -eq 1 -and $x.Login.Text) { $null = $x.Password.Focus() } else { $null = $x.Server.Focus() }
        })
    try { $result = $d.Form.ShowDialog($g.Form) }
    finally { $state = $g.Dlg; $g.Dlg = $null; $d.Form.Dispose() }
    if ($result -eq 'OK' -and $state.Conn) { Set-GuiConnected $state.Conn $state.Databases }
}

function Invoke-GuiConnect {
    # Connect button: the dialog closes only after the database list loads.
    $g = $script:App
    $x = $g.Dlg
    $server = $x.Server.Text.Trim()
    if (-not $server) { Show-GuiMessage 'Enter the SQL Server instance, for example "." or "HOST\INSTANCE".' 'Warning'; return }
    $conn = @{ Server = $server; SqlAuth = $x.Auth.SelectedIndex -eq 1; Login = $x.Login.Text.Trim(); Password = (ConvertTo-GuiSecureString $x.Password.Text); Trust = $x.Trust.Checked }
    if ($conn.SqlAuth -and -not $conn.Login) { Show-GuiMessage 'Enter the login for SQL Server authentication.' 'Warning'; return }
    try { $dbs = Get-GuiServerList $conn '' 'SELECT name FROM sys.databases WHERE state = 0 AND HAS_DBACCESS(name) = 1 ORDER BY name' }
    catch {
        $e = $_.Exception
        if ($e.InnerException) { $e = $e.InnerException }
        Show-GuiMessage ("Could not connect to ${server}." + [Environment]::NewLine + [Environment]::NewLine + $e.Message) 'Error'
        return
    }
    $s = $g.Settings
    $s.ServerInstance = $server; $s.SqlAuthentication = $conn.SqlAuth; $s.Login = $conn.Login; $s.TrustServerCertificate = $conn.Trust
    $s.Servers = @(@($server) + @($s.Servers | Where-Object { $_ -ne $server }) | Select-Object -First 10)
    Save-GuiSettings
    $x.Conn = $conn; $x.Databases = $dbs
    $x.Form.DialogResult = 'OK'
}

function Show-GuiSettingsDialog {
    $g = $script:App
    $s = $g.Settings
    $d = New-GuiDialog 'Settings'
    $sc = Get-GuiScale
    $numberWidth = [int](110 * $sc)
    # every option carries a short explanation under it (muted), indented under its check box
    # wide enough that the dialog stays under ~800 px tall (laptop screens)
    $noteWidth = [int](660 * $sc)
    $note = {
        param([string]$Text, [int]$Indent = 22)
        New-GuiControl Label @{ Text = $Text; AutoSize = $true; Tag = 'Muted'; MaximumSize = (New-Object Drawing.Size $noteWidth, 0); Margin = (New-Object Windows.Forms.Padding $Indent, 0, 3, 8) }
    }
    Add-GuiRow $d.Layout '' (New-GuiHeading 'Appearance' 2)
    $theme = New-GuiControl ComboBox @{ DropDownStyle = 'DropDownList'; Width = [int](160 * $sc) }
    $null = $theme.Items.AddRange([object[]]@('Dark', 'Light'))
    $theme.SelectedItem = $script:GuiTheme
    Add-GuiRow $d.Layout 'Theme' $theme
    Add-GuiRow $d.Layout '' (& $note 'Colors of the window, grids and charts. Saved for your Windows user.' 3)

    Add-GuiRow $d.Layout '' (New-GuiHeading 'Decoding from a server')
    $validate = New-GuiControl CheckBox @{ Text = 'Validate against DBCC SHOW_STATISTICS'; AutoSize = $true; Checked = [bool]$s.Validate }
    Add-GuiRow $d.Layout '' $validate
    Add-GuiRow $d.Layout '' (& $note ('After each decode, runs DBCC SHOW_STATISTICS (STAT_HEADER, DENSITY_VECTOR, HISTOGRAM) and compares every value with the decoded stream: ' +
            'results in the Validation tab and at the end of the report. With a sysadmin login it also compares the trace flag 2388 history, which turns ' +
            'TF 2388 on for the session (two ERRORLOG lines per table). Off: faster, with nothing to compare.'))
    $dac = New-GuiControl CheckBox @{ Text = 'Use the DAC for the exact Snapshot Ctr (sysadmin)'; AutoSize = $true; Checked = [bool]$s.UseDac }
    Add-GuiRow $d.Layout '' $dac
    Add-GuiRow $d.Layout '' (& $note ('Reads the current Snapshot Ctr of the trace flag 2388 history from sys.sysobjvalues, which only the dedicated admin connection ' +
            'can query. Needs sysadmin; the DAC allows one session per instance, and remote DAC is off by default. Off: the Snapshot Ctr is estimated.'))

    Add-GuiRow $d.Layout '' (New-GuiHeading 'Data check (F6)')
    # page budget, query timeout and pause on one row
    $budget = New-GuiControl NumericUpDown @{ Minimum = 1; Maximum = 1000000000; Value = [long]$s.CheckPageBudget; Width = $numberWidth; ThousandsSeparator = $true }
    $timeout = New-GuiControl NumericUpDown @{ Minimum = 1; Maximum = 3600; Value = [int]$s.CheckTimeout; Width = [int](70 * $sc) }
    $delay = New-GuiControl NumericUpDown @{ Minimum = 0; Maximum = 60000; Value = [int]$s.CheckStepDelay; Width = [int](80 * $sc) }
    $checkRow = New-GuiControl FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false; Anchor = 'Left'; Margin = (New-Object Windows.Forms.Padding 0) }
    $checkLabel = { param([string]$Text) New-GuiControl Label @{ Text = $Text; AutoSize = $true; Margin = (New-Object Windows.Forms.Padding 16, 6, 4, 3) } }
    $checkRow.Controls.AddRange(@($budget, (& $checkLabel 'Timeout (s)'), $timeout, (& $checkLabel 'Pause per step (ms)'), $delay))
    Add-GuiRow $d.Layout 'Page budget' $checkRow
    Add-GuiRow $d.Layout '' (& $note ('Leaf pages one check may read (8 KB each; 100,000 is about 780 MB). On a larger index the check reads the NULL rows, both ends of ' +
            'the histogram, then steps at random while they fit. The pause spreads the queries on a busy server.') 3)

    Add-GuiRow $d.Layout '' (New-GuiHeading 'Report')
    $hexDump = New-GuiControl CheckBox @{ Text = 'Include the layout map and a hex dump'; AutoSize = $true; Checked = [bool]$s.HexDump }
    Add-GuiRow $d.Layout '' $hexDump
    Add-GuiRow $d.Layout '' (& $note ('Appends a map of every structure in the stream (offset, length, field) and the whole stream in hex, to check the binary ' +
            'layout byte by byte. Makes the report much longer.'))
    $fullPrecision = New-GuiControl CheckBox @{ Text = 'Full float precision (round-trip values instead of 7 digits)'; AutoSize = $true; Checked = [bool]$s.FullPrecision }
    Add-GuiRow $d.Layout '' $fullPrecision
    Add-GuiRow $d.Layout '' (& $note ('Shows float values (densities, row counts, averages) with every digit, so they round-trip exactly, in the report and the ' +
            'grids. Off: 7 significant digits, as DBCC SHOW_STATISTICS shows them.'))
    $trie = New-GuiControl NumericUpDown @{ Minimum = 0; Maximum = 1000000; Value = [int]$s.StringIndexNodes; Width = $numberWidth; Anchor = 'Left' }
    Add-GuiRow $d.Layout 'String index nodes' $trie
    Add-GuiRow $d.Layout '' (& $note ('Trie nodes the report lists for statistics on a string column; long strings can produce thousands. The String index tab ' +
            'always draws every node. 0 = no limit.') 3)
    $scan = New-GuiControl NumericUpDown @{ Minimum = 0; Maximum = 1000000; Value = [int]$s.SampledScanValues; Width = $numberWidth; Anchor = 'Left' }
    Add-GuiRow $d.Layout 'Synopsis values' $scan
    Add-GuiRow $d.Layout '' (& $note ('Values the report prints per density vector from the distinct value synopsis that sampled updates keep: the smallest ' +
            'hash values seen, which SQL Server uses to estimate distinct counts and to merge statistics. 0 = no limit.') 3)
    Add-GuiRow $d.Layout '' (New-GuiControl Label @{ Text = 'The theme changes at once; the other options apply to the next decode or data check.'; AutoSize = $true; Margin = (New-Object Windows.Forms.Padding 3, 6, 3, 0) })
    $buttons = Add-GuiDialogButtons $d 'OK'
    $defaults = New-GuiControl Button @{ Text = 'Restore defaults'; AutoSize = $true; Padding = (New-Object Windows.Forms.Padding 8, 2, 8, 2); Margin = (New-Object Windows.Forms.Padding 3, 3, 24, 3) }
    $buttons.Panel.Controls.Add($defaults)
    $buttons.Ok.DialogResult = 'OK'
    $g.Dlg = @{ Theme = $theme; Validate = $validate; Dac = $dac; HexDump = $hexDump; FullPrecision = $fullPrecision; Trie = $trie; Scan = $scan; Budget = $budget; Timeout = $timeout; Delay = $delay }
    $defaults.Add_Click({
            $x = $script:App.Dlg
            $def = Get-GuiDefaultSettings
            $x.Theme.SelectedItem = $def.Theme; $x.Validate.Checked = $def.Validate; $x.Dac.Checked = $def.UseDac
            $x.HexDump.Checked = $def.HexDump; $x.FullPrecision.Checked = $def.FullPrecision
            $x.Trie.Value = $def.StringIndexNodes; $x.Scan.Value = $def.SampledScanValues
            $x.Budget.Value = $def.CheckPageBudget; $x.Timeout.Value = $def.CheckTimeout; $x.Delay.Value = $def.CheckStepDelay
        })
    try { $result = $d.Form.ShowDialog($g.Form) }
    finally { $g.Dlg = $null; $d.Form.Dispose() }
    if ($result -ne 'OK') { return }
    $s.Validate = $validate.Checked; $s.UseDac = $dac.Checked; $s.HexDump = $hexDump.Checked; $s.FullPrecision = $fullPrecision.Checked
    $s.StringIndexNodes = [int]$trie.Value; $s.SampledScanValues = [int]$scan.Value
    $s.CheckPageBudget = [long]$budget.Value; $s.CheckTimeout = [int]$timeout.Value; $s.CheckStepDelay = [int]$delay.Value
    if ([string]$theme.SelectedItem -ne $script:GuiTheme) { Set-GuiTheme ([string]$theme.SelectedItem) } else { Save-GuiSettings }
    Update-GuiCommandState
    Set-GuiStatus 'Settings saved. Decode options apply to the next decode.'
}

function Get-GuiStreamHex([string]$Text) {
    # The hex digits of a pasted STATS_STREAM, or $null. With 0x, only that token counts (a copied result row
    # also has Rows and Data Pages); without it, the whole text must be hex.
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '0[xX]([0-9A-Fa-f]+(?:\s*\r?\n\s*[0-9A-Fa-f]+)*)')
    $h = $(if ($m.Success) { $m.Groups[1].Value } else { $Text }) -replace '\s', ''
    if ($h -notmatch '^[0-9A-Fa-f]+$') { return $null }
    return $h
}

function Show-GuiPasteDialog([string]$File) {
    $g = $script:App
    $d = New-GuiDialog 'Decode a STATS_STREAM'
    $sc = Get-GuiScale
    $w = [int](720 * $sc)
    $intro = New-GuiControl Label @{
        Text = 'Paste the output of DBCC SHOW_STATISTICS (...) WITH STATS_STREAM: the hex value, with or without 0x. A copied result row works too.'
        AutoSize = $true; MaximumSize = (New-Object Drawing.Size $w, 0); Margin = (New-Object Windows.Forms.Padding 3, 3, 3, 6)
    }
    Add-GuiRow $d.Layout '' $intro
    $hex = New-GuiControl TextBox @{ Multiline = $true; Width = $w; Height = [int](230 * $sc); ScrollBars = 'Vertical'; MaxLength = 0; Font = (New-Object Drawing.Font 'Consolas', 9.75) }
    Add-GuiRow $d.Layout '' $hex
    $tools = New-GuiControl FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false; Margin = (New-Object Windows.Forms.Padding 0, 4, 0, 8) }
    $fromClipboard = New-GuiControl Button @{ Text = 'Paste from clipboard'; AutoSize = $true; Padding = (New-Object Windows.Forms.Padding 6, 1, 6, 1) }
    $fromFile = New-GuiControl Button @{ Text = 'Load from file...'; AutoSize = $true; Padding = (New-Object Windows.Forms.Padding 6, 1, 6, 1) }
    $info = New-GuiControl Label @{ AutoSize = $true; Tag = 'Muted'; Margin = (New-Object Windows.Forms.Padding 12, 7, 3, 3) }
    $tools.Controls.AddRange(@($fromClipboard, $fromFile, $info))
    Add-GuiRow $d.Layout '' $tools
    $names = New-GuiControl TextBox @{ Width = [int](440 * $sc) }
    Add-GuiRow $d.Layout 'Column names' $names
    $codePage = New-GuiControl NumericUpDown @{ Minimum = 0; Maximum = 65001; Width = [int](110 * $sc); Anchor = 'Left' }
    Add-GuiRow $d.Layout 'Code page' $codePage
    $hint = New-GuiControl Label @{
        Text = "Column names: comma separated, the default is Column1..N. Code page 0 = from the collation. The stream has no server context, so validation doesn't run."
        AutoSize = $true; Tag = 'Muted'; MaximumSize = (New-Object Drawing.Size $w, 0)
    }
    Add-GuiRow $d.Layout '' $hint
    $caution = New-GuiControl Label @{
        Text = 'Histograms carry real data values. Be careful where you paste or store streams and reports from customer databases.'
        AutoSize = $true; Tag = 'Muted'; MaximumSize = (New-Object Drawing.Size $w, 0); Margin = (New-Object Windows.Forms.Padding 3, 8, 3, 3)
    }
    Add-GuiRow $d.Layout '' $caution
    $buttons = Add-GuiDialogButtons $d 'Decode'

    $g.Dlg = @{ Form = $d.Form; Hex = $hex; Info = $info; Names = $names; CodePage = $codePage; Ok = $buttons.Ok; File = $null; FileText = $null; Result = $null }
    $hex.Add_TextChanged({ Update-GuiPasteInfo })
    $fromClipboard.Add_Click({ Import-GuiClipboardStream })
    $fromFile.Add_Click({
            $ofd = New-Object Windows.Forms.OpenFileDialog
            $ofd.Filter = 'STATS_STREAM (hex text or binary)|*.txt;*.hex;*.bin|All files|*.*'
            try { if ($ofd.ShowDialog($script:App.Dlg.Form) -eq 'OK') { Import-GuiStreamFile $ofd.FileName } } finally { $ofd.Dispose() }
        })
    $buttons.Ok.Add_Click({ Complete-GuiPasteDialog })
    if ($File) { Import-GuiStreamFile $File }
    else {
        $clip = $null
        try { if ([Windows.Forms.Clipboard]::ContainsText()) { $clip = [Windows.Forms.Clipboard]::GetText() } } catch { }
        $h = Get-GuiStreamHex $clip
        if ($h -and $h.Length -ge 80) { Import-GuiClipboardStream }
    }
    Update-GuiPasteInfo
    $d.Form.Add_Shown({ $x = $script:App.Dlg; if ($x.Hex.Text) { $null = $x.Ok.Focus() } else { $null = $x.Hex.Focus() } })
    try { $result = $d.Form.ShowDialog($g.Form) }
    finally { $state = $g.Dlg; $g.Dlg = $null; $d.Form.Dispose() }
    if ($result -eq 'OK' -and $state.Result) { Start-GuiDecode $state.Result }
}

function Update-GuiPasteInfo {
    $x = $script:App.Dlg
    $text = $x.Hex.Text
    $h = Get-GuiStreamHex $text
    $problem = $null
    if (-not $text.Trim()) { $message = 'Waiting for a STATS_STREAM.'; $problem = '' }
    elseif (-not $h) { $problem = 'This is not a hex string.' }
    elseif ($h.Length % 2) { $problem = 'The hex string has an odd number of digits.' }
    elseif ($h.Length / 2 -lt 40) { $problem = 'Too short: a STATS_STREAM starts with a 40-byte header.' }
    else {
        $message = '{0:N0} bytes' -f ($h.Length / 2)
        if ($x.File -and $text -ceq $x.FileText) { $message += ' from ' + [IO.Path]::GetFileName($x.File) }
    }
    if ($problem) { $x.Info.Text = $problem; $x.Info.ForeColor = Get-GuiResultColor 'MISMATCH' }
    else { $x.Info.Text = $message; $x.Info.ForeColor = (Get-GuiPalette).Muted }
    $x.Ok.Enabled = $null -eq $problem
}

function Import-GuiClipboardStream {
    $x = $script:App.Dlg
    $text = $null
    try { $text = [Windows.Forms.Clipboard]::GetText() } catch { }
    if (-not $text) { $x.Info.Text = 'The clipboard has no text.'; return }
    $h = Get-GuiStreamHex $text
    $x.File = $null
    $x.Hex.Text = $(if ($h) { '0x' + $h } else { $text })
}

function Import-GuiStreamFile([string]$Path) {
    # Hex text files show as they are; binary files show as hex. The decoder reads the file itself when unchanged.
    $x = $script:App.Dlg
    try { $raw = [IO.File]::ReadAllBytes($Path) } catch { Show-GuiMessage $_.Exception.Message 'Error'; return }
    $text = $null
    try { $text = [Text.Encoding]::ASCII.GetString($raw).Trim() } catch { }
    $plain = $text -and $text -match '^(0x)?[0-9A-Fa-f\s]+$'
    if ($plain) { $shown = $text }
    elseif ($text -and (Get-GuiStreamHex $text) -and $text -match '0[xX]') { $shown = '0x' + (Get-GuiStreamHex $text); $plain = $false }
    else { $shown = '0x' + [BitConverter]::ToString($raw).Replace('-', ''); $plain = $true }
    $x.Hex.Text = $shown
    # Only a plain hex file or a binary one goes to the decoder by path (its -InputFile rules); anything else as text.
    $x.File = $(if ($plain) { $Path } else { $null })
    $x.FileText = $shown
    Update-GuiPasteInfo
}

function Complete-GuiPasteDialog {
    $x = $script:App.Dlg
    $h = Get-GuiStreamHex $x.Hex.Text
    if (-not $h) { return }
    $r = @{}
    if ($x.File -and $x.Hex.Text -ceq $x.FileText) { $r.InputFile = $x.File } else { $r.StatsStream = '0x' + $h }
    $names = @($x.Names.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($names) { $r.ColumnNames = [string[]]$names }
    if ($x.CodePage.Value -gt 0) { $r.CodePage = [int]$x.CodePage.Value }
    $x.Result = $r
    $x.Form.DialogResult = 'OK'
}

function Show-GuiAboutDialog {
    $g = $script:App
    $d = New-GuiDialog 'About SQLStatsXRay'
    $sc = Get-GuiScale
    $w = [int](440 * $sc)
    $logo = New-GuiControl PictureBox @{ Size = (New-Object Drawing.Size ([int](96 * $sc)), ([int](96 * $sc))); SizeMode = 'Zoom'; Margin = (New-Object Windows.Forms.Padding 3, 8, 18, 3) }
    $png = Join-Path (Split-Path -Parent $script:DecoderPath) 'assets\app.png'
    if (Test-Path -LiteralPath $png) { $logo.Image = [Drawing.Image]::FromFile($png) }
    $text = New-GuiControl TableLayoutPanel @{ AutoSize = $true; ColumnCount = 1; Margin = (New-Object Windows.Forms.Padding 0) }
    Add-GuiStackRow $text (New-GuiControl Label @{ Text = 'SQLStatsXRay'; AutoSize = $true; Font = (New-Object Drawing.Font 'Segoe UI', 18, ([Drawing.FontStyle]::Bold)) })
    Add-GuiStackRow $text (New-GuiControl Label @{ Text = "Version $script:AppVersion"; AutoSize = $true; Tag = 'Muted' })
    Add-GuiStackRow $text (New-GuiControl Label @{
            Text = 'Decodes, charts and edits SQL Server statistics from their STATS_STREAM: header, histogram, density vector, string index and update history.'
            AutoSize = $true; MaximumSize = (New-Object Drawing.Size $w, 0); Margin = (New-Object Windows.Forms.Padding 3, 10, 3, 3)
        })
    Add-GuiStackRow $text (New-GuiControl Label @{ Text = 'Created by Fabiano Amorim | @mcflyamorim'; AutoSize = $true; Margin = (New-Object Windows.Forms.Padding 3, 12, 3, 3) })
    $link = New-GuiControl LinkLabel @{ Text = $script:AppProjectUrl; AutoSize = $true }
    Add-GuiStackRow $text $link
    Add-GuiStackRow $text (New-GuiControl Label @{
            Text = 'Builds on the STATS_STREAM research of Andr' + [char]0xE9 + ' Renato Furtado and Joe Chang. STATS_STREAM is undocumented: validate the results before relying on them, and load edited statistics on test copies only.'
            AutoSize = $true; Tag = 'Muted'; MaximumSize = (New-Object Drawing.Size $w, 0); Margin = (New-Object Windows.Forms.Padding 3, 12, 3, 3)
        })
    $d.Layout.RowCount = 1
    $null = $d.Layout.RowStyles.Add((New-Object Windows.Forms.RowStyle 'AutoSize'))
    $d.Layout.Controls.Add($logo, 0, 0)
    $d.Layout.Controls.Add($text, 1, 0)
    $buttons = Add-GuiDialogButtons $d 'Close' -NoCancel
    $buttons.Ok.DialogResult = 'OK'
    $link.Add_LinkClicked({ Open-GuiProjectPage })
    try { $null = $d.Form.ShowDialog($g.Form) }
    finally { if ($logo.Image) { $logo.Image.Dispose() }; $d.Form.Dispose() }
}

function Open-GuiProjectPage {
    try { Start-Process $script:AppProjectUrl } catch { Show-GuiMessage $_.Exception.Message 'Error' }
}

function Invoke-GuiOpenFile {
    $ofd = New-Object Windows.Forms.OpenFileDialog
    $ofd.Filter = 'STATS_STREAM (hex text or binary)|*.txt;*.hex;*.bin|All files|*.*'
    $file = $null
    try { if ($ofd.ShowDialog($script:App.Form) -eq 'OK') { $file = $ofd.FileName } } finally { $ofd.Dispose() }
    if ($file) { Show-GuiPasteDialog -File $file }
}

function Save-GuiReport {
    $g = $script:App
    if (-not $g.HasReport) { Show-GuiMessage 'There is no report to save yet.'; return }
    $sfd = New-Object Windows.Forms.SaveFileDialog
    $sfd.Filter = 'Text files|*.txt|All files|*.*'
    $sfd.FileName = $g.ReportName + '.txt'
    try {
        if ($sfd.ShowDialog($g.Form) -eq 'OK') {
            [IO.File]::WriteAllText($sfd.FileName, $g.Report.Text, (New-Object Text.UTF8Encoding $true))
            Set-GuiStatus "Report saved to $($sfd.FileName)."
        }
    } finally { $sfd.Dispose() }
}

function Copy-GuiReport {
    $g = $script:App
    if (-not $g.HasReport) { Show-GuiMessage 'There is no report to copy yet.'; return }
    [Windows.Forms.Clipboard]::SetText($g.Report.Text)
    Set-GuiStatus 'Report copied to the clipboard.'
}

function New-GuiListHeader([string]$Title) {
    # A section title with a count on the right.
    $panel = New-GuiControl TableLayoutPanel @{ Dock = 'Fill'; AutoSize = $true; ColumnCount = 2; Margin = (New-Object Windows.Forms.Padding 0) }
    $null = $panel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    $null = $panel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'AutoSize'))
    $count = New-GuiControl Label @{ AutoSize = $true; Tag = 'Muted'; Anchor = 'Right'; Margin = (New-Object Windows.Forms.Padding 3, 10, 3, 4) }
    $panel.Controls.Add((New-GuiHeading $Title 10), 0, 0)
    $panel.Controls.Add($count, 1, 0)
    return @{ Panel = $panel; Count = $count }
}

function Show-DecoderWindow {
    Write-GuiStartup "Starting SQLStatsXRay $script:AppVersion..."
    Write-GuiStartup 'Loading Windows Forms...'
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'The app needs an STA thread. Run it with powershell.exe -STA, or use SQLStatsXRay.cmd.'
    }
    try { [Windows.Forms.Application]::EnableVisualStyles() } catch { }
    if (-not ('StatsStreamDecoder.Appearance.Skin' -as [type])) {
        Write-GuiStartup 'Compiling the theme helpers (C#)...'
        $refs = @([Windows.Forms.Control].Assembly.Location, [Windows.Forms.Message].Assembly.Location, [Drawing.Graphics].Assembly.Location,
            [Drawing.Color].Assembly.Location, [ComponentModel.Component].Assembly.Location)
        $refs += @(Get-ChildItem -LiteralPath (Split-Path ([Windows.Forms.Control].Assembly.Location) -Parent) -Filter 'System.Private.Windows*.dll' | ForEach-Object FullName)
        Add-Type -TypeDefinition $script:GuiNativeTheme -ReferencedAssemblies @($refs | Select-Object -Unique)
    }

    Write-GuiStartup "Reading settings ($(Get-GuiSettingsPath))..."
    $settings = Read-GuiSettings
    $script:GuiTheme = [string]$settings.Theme
    $script:App = @{
        Settings = $settings; Grids = [ordered]@{}; Results = @(); Loading = $false; Conn = $null; AllTables = @(); HasReport = $false; ReportName = 'StatsStream_report'
        Commands = @{ Connect = @(); Disconnect = @(); Paste = @(); Open = @(); Settings = @() }
    }
    $g = $script:App

    Write-GuiStartup 'Building the main window (menu, toolbar, server browser and result tabs)...'
    $form = New-GuiControl Form @{
        Text = 'SQLStatsXRay'; StartPosition = 'CenterScreen'; KeyPreview = $true
        Font = (New-Object Drawing.Font 'Segoe UI', 10); Size = (New-Object Drawing.Size 1360, 860); MinimumSize = (New-Object Drawing.Size 1000, 640)
    }
    $g.Form = $form
    try { $g.Icon = New-Object Drawing.Icon (Join-Path (Split-Path -Parent $script:DecoderPath) 'assets\app.ico'); $form.Icon = $g.Icon } catch { }
    $sc = Get-GuiScale

    # ---- menu (Segoe icon font glyphs: E703 connect, E711 cancel, E77F paste, E8E5 open, E74E save, E8C8 copy, E713 settings, E774 globe, E946 info)
    $menu = New-Object Windows.Forms.MenuStrip
    $fileMenu = New-Object Windows.Forms.ToolStripMenuItem '&File'
    $mConnect = New-GuiMenuItem '&Connect...' 0xE703 'Control, N' { Show-GuiConnectDialog }
    $mDisconnect = New-GuiMenuItem '&Disconnect' 0xE711 '' { Set-GuiConnected $null; Set-GuiStatus 'Disconnected.' }
    $mPaste = New-GuiMenuItem '&Paste STATS_STREAM...' 0xE77F 'Control, Shift, V' { Show-GuiPasteDialog }
    $mOpen = New-GuiMenuItem '&Open STATS_STREAM file...' 0xE8E5 'Control, O' { Invoke-GuiOpenFile }
    $mSave = New-GuiMenuItem '&Save report as...' 0xE74E 'Control, S' { Save-GuiReport }
    $mCopy = New-GuiMenuItem '&Copy report' 0xE8C8 'Control, Shift, C' { Copy-GuiReport }
    $mExit = New-GuiMenuItem 'E&xit' 0 '' { $script:App.Form.Close() }
    $null = $fileMenu.DropDownItems.AddRange([Windows.Forms.ToolStripItem[]]@($mConnect, $mDisconnect, (New-Object Windows.Forms.ToolStripSeparator), $mPaste, $mOpen,
            (New-Object Windows.Forms.ToolStripSeparator), $mSave, $mCopy, (New-Object Windows.Forms.ToolStripSeparator), $mExit))
    $toolsMenu = New-Object Windows.Forms.ToolStripMenuItem '&Tools'
    $mSettings = New-GuiMenuItem '&Settings...' 0xE713 'Control, Oemcomma' { Show-GuiSettingsDialog }
    $mSettings.ShortcutKeyDisplayString = 'Ctrl+,'
    $mBuild = New-GuiMenuItem '&Build statistics (beta)...' 0xE9D9 'Control, B' { Show-GuiBuildDialog }
    $null = $toolsMenu.DropDownItems.AddRange([Windows.Forms.ToolStripItem[]]@($mBuild, (New-Object Windows.Forms.ToolStripSeparator), $mSettings))
    $helpMenu = New-Object Windows.Forms.ToolStripMenuItem '&Help'
    $mProject = New-GuiMenuItem 'SQLStatsXRay on &GitHub' 0xE774 '' { Open-GuiProjectPage }
    $mAbout = New-GuiMenuItem '&About SQLStatsXRay' 0xE946 '' { Show-GuiAboutDialog }
    $null = $helpMenu.DropDownItems.AddRange([Windows.Forms.ToolStripItem[]]@($mProject, (New-Object Windows.Forms.ToolStripSeparator), $mAbout))
    $null = $menu.Items.AddRange([Windows.Forms.ToolStripItem[]]@($fileMenu, $toolsMenu, $helpMenu))

    # ---- toolbar
    $toolbar = New-Object Windows.Forms.ToolStrip
    $toolbar.GripStyle = 'Hidden'; $toolbar.Padding = New-Object Windows.Forms.Padding 6, 3, 6, 3
    $tConnect = New-GuiMenuItem 'Connect' 0xE703 '' { Show-GuiConnectDialog } -Button
    $tConnect.ToolTipText = 'Connect to a SQL Server instance (Ctrl+N)'
    $tDisconnect = New-GuiMenuItem 'Disconnect' 0xE711 '' { Set-GuiConnected $null; Set-GuiStatus 'Disconnected.' } -Button
    $tPaste = New-GuiMenuItem 'Paste STATS_STREAM' 0xE77F '' { Show-GuiPasteDialog } -Button
    $tPaste.ToolTipText = 'Decode a STATS_STREAM from the clipboard (Ctrl+Shift+V)'
    $tOpen = New-GuiMenuItem 'Open file' 0xE8E5 '' { Invoke-GuiOpenFile } -Button
    $tOpen.ToolTipText = 'Decode a STATS_STREAM saved as hex text or binary (Ctrl+O)'
    $tSettings = New-GuiMenuItem 'Settings' 0xE713 '' { Show-GuiSettingsDialog } -Button
    $tSettings.ToolTipText = 'Theme, validation, DAC and report options (Ctrl+,)'
    $tSettings.Alignment = 'Right'
    $null = $toolbar.Items.AddRange([Windows.Forms.ToolStripItem[]]@($tConnect, $tDisconnect, (New-Object Windows.Forms.ToolStripSeparator), $tPaste, $tOpen, $tSettings))
    $g.Commands = @{ Connect = @($mConnect, $tConnect); Disconnect = @($mDisconnect, $tDisconnect); Paste = @($mPaste, $tPaste); Open = @($mOpen, $tOpen); Settings = @($mSettings, $tSettings) }

    # ---- status bar
    $statusStrip = New-Object Windows.Forms.StatusStrip
    $statusStrip.SizingGrip = $false
    $g.Status = New-Object Windows.Forms.ToolStripStatusLabel 'Ready.'
    $g.Status.Spring = $true; $g.Status.TextAlign = 'MiddleLeft'
    $g.Progress = New-Object Windows.Forms.ToolStripProgressBar
    $g.Progress.Style = 'Marquee'; $g.Progress.Visible = $false; $g.Progress.Size = New-Object Drawing.Size 160, 16
    $g.ConnStatus = New-Object Windows.Forms.ToolStripStatusLabel 'Not connected'
    $g.ConnStatus.Margin = New-Object Windows.Forms.Padding 12, 3, 4, 2
    $null = $statusStrip.Items.AddRange([Windows.Forms.ToolStripItem[]]@($g.Status, $g.Progress, $g.ConnStatus))

    $split = New-GuiControl SplitContainer @{ Dock = 'Fill'; FixedPanel = 'Panel1'; SplitterWidth = 6 }

    # ---- left: connection and the server browser (disabled until connected)
    $left = New-GuiControl TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; Padding = (New-Object Windows.Forms.Padding 10, 10, 6, 0) }
    $null = $left.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    $g.Inputs = $left

    $card = New-GuiControl TableLayoutPanel @{ Dock = 'Fill'; AutoSize = $true; ColumnCount = 2; RowCount = 2; Tag = 'Card'; Padding = (New-Object Windows.Forms.Padding 8, 8, 8, 8); Margin = (New-Object Windows.Forms.Padding 3, 0, 3, 4) }
    $null = $card.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'AutoSize'))
    $null = $card.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    $null = $card.RowStyles.Add((New-Object Windows.Forms.RowStyle 'AutoSize'))
    $null = $card.RowStyles.Add((New-Object Windows.Forms.RowStyle 'AutoSize'))
    $g.ConnDot = New-GuiControl Label @{ Text = [string][char]0x25CF; AutoSize = $true; Tag = 'StatusOff'; Font = (New-Object Drawing.Font 'Segoe UI', 11); Margin = (New-Object Windows.Forms.Padding 0, 0, 4, 0) }
    $g.ConnTitle = New-GuiControl Label @{ Text = 'Not connected'; AutoSize = $true; Font = (New-Object Drawing.Font 'Segoe UI', 10, ([Drawing.FontStyle]::Bold)); MaximumSize = (New-Object Drawing.Size ([int](310 * $sc)), 0); Margin = (New-Object Windows.Forms.Padding 0, 2, 0, 0) }
    $g.ConnDetail = New-GuiControl Label @{ AutoSize = $true; Tag = 'Muted'; MaximumSize = (New-Object Drawing.Size ([int](310 * $sc)), 0); Margin = (New-Object Windows.Forms.Padding 0, 2, 0, 0) }
    $card.Controls.Add($g.ConnDot, 0, 0)
    $card.Controls.Add($g.ConnTitle, 1, 0)
    $card.Controls.Add($g.ConnDetail, 1, 1)
    Add-GuiStackRow $left $card

    Add-GuiStackRow $left (New-GuiHeading 'Database' 10)
    # a drop-down list: the dark skin paints it, enabled or not (an editable combo turns white when disabled)
    $g.Database = New-GuiControl ComboBox @{ DropDownStyle = 'DropDownList'; Dock = 'Fill'; MaxDropDownItems = 20 }
    Add-GuiStackRow $left $g.Database

    $tablesHeader = New-GuiListHeader 'Tables'
    $g.TablesCount = $tablesHeader.Count
    Add-GuiStackRow $left $tablesHeader.Panel
    $g.TableFilter = New-GuiControl TextBox @{ Dock = 'Fill' }
    Add-GuiStackRow $left $g.TableFilter
    $g.Tables = New-GuiControl ListBox @{ Dock = 'Fill'; IntegralHeight = $false; HorizontalScrollbar = $true }
    Add-GuiStackRow $left $g.Tables 'Percent' 60

    $statsHeader = New-GuiListHeader 'Statistics'
    $g.StatsCount = $statsHeader.Count
    Add-GuiStackRow $left $statsHeader.Panel
    $g.Stats = New-GuiControl CheckedListBox @{ Dock = 'Fill'; CheckOnClick = $true; IntegralHeight = $false }
    Add-GuiStackRow $left $g.Stats 'Percent' 40
    $statsRow = New-GuiControl FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false; Margin = (New-Object Windows.Forms.Padding 0, 2, 0, 0) }
    $g.StatsAll = New-GuiControl CheckBox @{ Text = 'Check all'; AutoSize = $true }
    $statsHint = New-GuiControl Label @{ Text = '(none checked also decodes all)'; AutoSize = $true; Tag = 'Muted'; Margin = (New-Object Windows.Forms.Padding 8, 5, 3, 3) }
    $statsRow.Controls.AddRange(@($g.StatsAll, $statsHint))
    Add-GuiStackRow $left $statsRow

    # The run button stays outside the browser panel, so it remains enabled to cancel.
    $runPanel = New-GuiControl TableLayoutPanel @{ Dock = 'Bottom'; AutoSize = $true; ColumnCount = 1; Padding = (New-Object Windows.Forms.Padding 10, 6, 6, 10) }
    $null = $runPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    $g.Run = New-GuiControl Button @{ Text = 'Decode  (F5)'; Anchor = 'Left, Right'; Height = [int](40 * $sc); Tag = 'Primary'; Font = (New-Object Drawing.Font 'Segoe UI', 10, ([Drawing.FontStyle]::Bold)) }
    $g.DecodeHint = New-GuiControl Label @{ AutoSize = $true; Tag = 'Muted'; Margin = (New-Object Windows.Forms.Padding 3, 6, 3, 0) }
    Add-GuiStackRow $runPanel $g.Run
    Add-GuiStackRow $runPanel $g.DecodeHint
    $split.Panel1.Controls.Add($left)
    $split.Panel1.Controls.Add($runPanel)

    # ---- right: results
    $right = New-GuiControl TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 2; Padding = (New-Object Windows.Forms.Padding 4, 8, 8, 4) }
    $null = $right.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    $null = $right.RowStyles.Add((New-Object Windows.Forms.RowStyle 'AutoSize'))
    $null = $right.RowStyles.Add((New-Object Windows.Forms.RowStyle 'Percent', 100))
    $pickerRow = New-GuiControl FlowLayoutPanel @{ AutoSize = $true; WrapContents = $true; Dock = 'Fill'; Margin = (New-Object Windows.Forms.Padding 0, 0, 0, 4) }
    $pickerLabel = New-GuiControl Label @{ Text = 'Statistics object'; AutoSize = $true; Margin = (New-Object Windows.Forms.Padding 3, 7, 6, 3) }
    $g.Picker = New-GuiControl ComboBox @{ DropDownStyle = 'DropDownList'; Width = 380 }
    # editing: Header, Histogram and Density vector grids, then a script that loads the edited stream
    $g.EditMode = New-GuiControl CheckBox @{ Text = 'Edit statistics'; AutoSize = $true; Enabled = $false; Margin = (New-Object Windows.Forms.Padding 18, 6, 3, 3) }
    $g.Generate = New-GuiControl Button @{ Text = 'Generate script...'; AutoSize = $true; Enabled = $false; Tag = 'Primary'; Margin = (New-Object Windows.Forms.Padding 10, 2, 3, 2) }
    $g.Discard = New-GuiControl Button @{ Text = 'Discard edits'; AutoSize = $true; Enabled = $false; Margin = (New-Object Windows.Forms.Padding 6, 2, 3, 2) }
    $g.EditInfo = New-GuiControl Label @{ AutoSize = $true; Tag = 'Muted'; Margin = (New-Object Windows.Forms.Padding 8, 7, 3, 3) }
    $g.BuildButton = New-GuiControl Button @{ Text = 'Build statistics (beta)...'; AutoSize = $true; Enabled = $false; Margin = (New-Object Windows.Forms.Padding 18, 2, 3, 2) }
    $g.BuildButton.Add_Click({ Show-GuiBuildDialog })
    $g.Commands.Build = @($mBuild, $g.BuildButton)
    $pickerRow.Controls.AddRange(@($pickerLabel, $g.Picker, $g.EditMode, $g.Generate, $g.Discard, $g.BuildButton, $g.EditInfo))
    $right.Controls.Add($pickerRow, 0, 0)

    $g.ChartFont = New-Object Drawing.Font 'Segoe UI', 9
    $g.TrieFont = New-Object Drawing.Font 'Segoe UI', 9
    $g.ChartSteps = @(); $g.ChartHover = -1; $g.ChartSelected = -1; $g.ChartLabelWidth = 0
    $tabs = New-GuiControl TabControl @{ Dock = 'Fill' }
    $reportPage = New-GuiControl TabPage @{ Text = 'Report'; Padding = (New-Object Windows.Forms.Padding 4) }
    $g.Report = New-GuiControl RichTextBox @{ Dock = 'Fill'; ReadOnly = $true; WordWrap = $false; DetectUrls = $false; Font = (New-Object Drawing.Font 'Consolas', 9.75); BorderStyle = 'None' }
    $g.Report.Text = @(
        "SQLStatsXRay $script:AppVersion"
        ''
        'Decode statistics from a server:'
        '  1. Connect (Ctrl+N).'
        '  2. Pick a database and a table; type part of a name to search the tables.'
        '  3. Check statistics (none checked decodes all), then Decode (F5).'
        ''
        'Decode a STATS_STREAM you already have:'
        '  Paste STATS_STREAM (Ctrl+Shift+V), or Open file (Ctrl+O).'
        ''
        'Validation, DAC, report and theme options are in Settings (Ctrl+,).'
        ''
        'Histograms carry real data values. Be careful where you paste or store reports from customer databases.'
    ) -join [Environment]::NewLine
    $reportPage.Controls.Add($g.Report)
    $tabs.TabPages.Add($reportPage)
    foreach ($t in @(@('Header', 'Header'), @('Histogram', 'Histogram'), @('Density', 'Density vector'), @('StringIndex', 'String index'), @('Columns', 'Columns'), @('TraceFlag', 'TF 2388'), @('Validation', 'Validation'))) {
        $page = New-GuiControl TabPage @{ Text = $t[1]; Padding = (New-Object Windows.Forms.Padding 4) }
        if ($t[0] -eq 'StringIndex') { New-GuiTriePage $page; $tabs.TabPages.Add($page); continue }
        $grid = New-GuiControl DataGridView @{
            Name = $t[0]; Dock = 'Fill'; ReadOnly = $true; AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; RowHeadersVisible = $false
            AutoSizeColumnsMode = 'AllCells'; ClipboardCopyMode = 'EnableWithAutoHeaderText'; BorderStyle = 'None'; EditMode = 'EditOnKeystrokeOrF2'
        }
        if ($t[0] -eq 'Histogram') {
            # Chart first, grid below; the splitter keeps its proportion when the window resizes.
            $histSplit = New-GuiControl SplitContainer @{ Dock = 'Fill'; Orientation = 'Horizontal'; SplitterWidth = 6 }
            $chartBar = New-GuiControl FlowLayoutPanel @{ Dock = 'Top'; AutoSize = $true; WrapContents = $false; Margin = (New-Object Windows.Forms.Padding 0) }
            $chartHint = New-GuiControl Label @{ Text = 'Hover a bar for its values; click it to select the step in the grid.'; AutoSize = $true; Tag = 'Muted'; Margin = (New-Object Windows.Forms.Padding 3, 3, 3, 6) }
            $chartBar.Controls.Add($chartHint)
            $g.Chart = New-GuiControl PictureBox @{ Dock = 'Fill' }
            $histSplit.Panel1.Controls.Add($g.Chart)
            $histSplit.Panel1.Controls.Add($chartBar)
            $histSplit.Panel2.Controls.Add($grid)
            $page.Controls.Add($histSplit)
            $g.HistSplit = $histSplit
            $g.HistRatio = 0.62
        } else { $page.Controls.Add($grid) }
        $tabs.TabPages.Add($page)
        $g.Grids[$t[0]] = $grid
    }

    # ---- data check: the button and a note, then summary | findings, then one row per range
    $g.CheckPage = New-GuiControl TabPage @{ Text = 'Data check'; Padding = (New-Object Windows.Forms.Padding 4) }
    $checkBar = New-GuiControl FlowLayoutPanel @{ Dock = 'Top'; AutoSize = $true; WrapContents = $false; Margin = (New-Object Windows.Forms.Padding 0) }
    $g.CheckData = New-GuiControl Button @{ Text = 'Check against the table  (F6)'; AutoSize = $true; Tag = 'Primary'; Enabled = $false; Padding = (New-Object Windows.Forms.Padding 8, 2, 8, 2); Margin = (New-Object Windows.Forms.Padding 3, 3, 3, 6) }
    $checkHint = New-GuiControl Label @{
        AutoSize = $true; Tag = 'Muted'; Margin = (New-Object Windows.Forms.Padding 10, 9, 3, 6)
        Text = 'One index seek per step, within the page budget (Settings). Shows step numbers and counts, not key values.'
    }
    $checkBar.Controls.AddRange(@($g.CheckData, $checkHint))
    $checkSplit = New-GuiControl SplitContainer @{ Dock = 'Fill'; Orientation = 'Horizontal'; SplitterWidth = 6 }
    $topSplit = New-GuiControl SplitContainer @{ Dock = 'Fill'; SplitterWidth = 6 }
    foreach ($name in 'CheckSummary', 'CheckSteps') {
        $g.Grids[$name] = New-GuiControl DataGridView @{
            Name = $name; Dock = 'Fill'; ReadOnly = $true; AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; RowHeadersVisible = $false
            AutoSizeColumnsMode = 'AllCells'; ClipboardCopyMode = 'EnableWithAutoHeaderText'; BorderStyle = 'None'
        }
    }
    $g.CheckFindings = New-GuiControl TextBox @{ Dock = 'Fill'; ReadOnly = $true; Multiline = $true; WordWrap = $true; ScrollBars = 'Vertical'; BorderStyle = 'None' }
    $topSplit.Panel1.Controls.Add($g.Grids.CheckSummary)
    $topSplit.Panel2.Controls.Add($g.CheckFindings)
    $checkSplit.Panel1.Controls.Add($topSplit)
    $checkSplit.Panel2.Controls.Add($g.Grids.CheckSteps)
    $g.CheckPage.Controls.Add($checkSplit)
    $g.CheckPage.Controls.Add($checkBar)
    $tabs.TabPages.Add($g.CheckPage)
    $g.CheckSplits = @($checkSplit, $topSplit)
    $g.Tabs = $tabs
    $right.Controls.Add($tabs, 0, 1)
    $split.Panel2.Controls.Add($right)
    $g.HistMenu = New-Object Windows.Forms.ContextMenuStrip
    foreach ($item in @(@('Insert step above', 'InsertAbove'), @('Insert step below', 'InsertBelow'), @('Delete selected steps', 'Delete'))) {
        $menuItem = New-Object Windows.Forms.ToolStripMenuItem $item[0]
        $menuItem.Tag = $item[1]
        $menuItem.Add_Click({ param($s, $e) Invoke-GuiStepEdit $s.Tag })
        $null = $g.HistMenu.Items.Add($menuItem)
    }
    $g.HistMenu.Add_Opening({ Set-GuiToolStripTheme $script:App.HistMenu })

    $form.Controls.Add($split)
    $form.Controls.Add($statusStrip)
    $form.Controls.Add($toolbar)
    $form.Controls.Add($menu)
    $form.MainMenuStrip = $menu

    # ---- events
    $g.Timer = New-Object Windows.Forms.Timer
    $g.Timer.Interval = 150
    $g.Timer.Add_Tick({
            $job = $script:App.Job
            if (-not $job) { $script:App.Timer.Stop(); return }
            if ($job.Async.IsCompleted) { Complete-GuiDecode }
            else { Set-GuiStatus ('{0}... {1:0} s' -f $job.Activity, ([DateTime]::Now - $job.Started).TotalSeconds) }
        })
    $g.Run.Add_Click({ if ($script:App.Job) { Stop-GuiDecode } else { Start-GuiDecode } })
    $g.Database.Add_SelectedIndexChanged({ if (-not $script:App.Loading) { Invoke-GuiBrowse Tables } })
    $g.TableFilter.Add_TextChanged({ Update-GuiTableFilter })
    $g.TableFilter.Add_KeyDown({
            # Down or Enter moves to the (first) match, so a search is a few keys away from a table.
            param($s, $e)
            $list = $script:App.Tables
            if ($e.KeyCode -in 'Down', 'Enter' -and $list.Items.Count -gt 0) {
                $e.SuppressKeyPress = $true
                if ($list.SelectedIndex -lt 0) { $list.SelectedIndex = 0 }
                if ($e.KeyCode -eq 'Down') { $null = $list.Focus() }
            }
        })
    $g.Tables.Add_SelectedIndexChanged({ if (-not $script:App.Loading) { Invoke-GuiBrowse Stats } })
    $g.Tables.Add_DoubleClick({ if ($script:App.Tables.SelectedIndex -ge 0 -and -not $script:App.Job) { Start-GuiDecode } })
    $g.Picker.Add_SelectedIndexChanged({
            $app = $script:App
            if ($app.Loading -or $app.Picker.SelectedIndex -lt 0) { return }
            Show-GuiResult $app.Results[$app.Picker.SelectedIndex]
        })
    $g.StatsAll.Add_CheckedChanged({
            $app = $script:App
            if ($app.StatsSync) { return }
            $app.StatsSync = $true
            try { for ($i = 0; $i -lt $app.Stats.Items.Count; $i++) { $app.Stats.SetItemChecked($i, $app.StatsAll.Checked) } }
            finally { $app.StatsSync = $false }
        })
    $g.Stats.Add_ItemCheck({
            # ItemCheck fires before the change: count with the new value.
            param($s, $e)
            if ($script:App.StatsSync) { return }
            $n = $s.CheckedItems.Count
            if ($e.NewValue -eq 'Checked' -and $e.CurrentValue -ne 'Checked') { $n++ }
            if ($e.NewValue -ne 'Checked' -and $e.CurrentValue -eq 'Checked') { $n-- }
            Set-GuiStatsAll ($s.Items.Count -gt 0 -and $n -eq $s.Items.Count)
        })
    $g.EditMode.Add_CheckedChanged({
            foreach ($grid in $script:App.Grids.Values) { $null = $grid.EndEdit() }
            Set-GuiEditMode
            if ($script:App.EditMode.Checked) { Set-GuiStatus 'Edit mode: change values in the Header, Histogram and Density vector tabs; right-click the histogram grid to insert or delete steps.' }
        })
    $g.Generate.Add_Click({ Show-GuiScriptDialog })
    $g.Discard.Add_Click({
            if ([Windows.Forms.MessageBox]::Show($script:App.Form, 'Discard the edits of this statistics object?', 'SQLStatsXRay', 'YesNo', 'Question') -eq 'Yes') { Reset-GuiEdits }
        })
    foreach ($grid in @($g.Grids.Header, $g.Grids.Histogram, $g.Grids.Density)) {
        $grid.Add_CellParsing({
                # numbers typed with the invariant or a decimal comma, stored in the column's type
                param($s, $e)
                $type = $s.Columns[$e.ColumnIndex].ValueType
                if ($type -in [single], [double]) {
                    try { $e.Value = (ConvertFrom-GuiNumber ([string]$e.Value)) -as $type; $e.ParsingApplied = $true } catch { }
                }
            })
        $grid.Add_DataError({
                param($s, $e)
                $e.ThrowException = $false
                Set-GuiStatus "Not a valid value for $($s.Columns[$e.ColumnIndex].Name)."
                [Media.SystemSounds]::Beep.Play()
            })
        $grid.Add_CellValidating({
                param($s, $e)
                if ($script:App.Loading -or -not $s.IsCurrentCellInEditMode) { return }
                $problem = Test-GuiCellValue $s $e.RowIndex $s.Columns[$e.ColumnIndex].Name ([string]$e.FormattedValue)
                if ($problem) { $e.Cancel = $true; Set-GuiStatus $problem; [Media.SystemSounds]::Beep.Play() }
            })
        $grid.Add_CellValueChanged({
                param($s, $e)
                if ($script:App.Loading -or $e.RowIndex -lt 0) { return }
                try { Update-GuiModelFromCell $s $e.RowIndex $e.ColumnIndex }
                catch { Set-GuiStatus $_.Exception.Message }
            })
        $grid.Add_CellFormatting({
                param($s, $e)
                if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
                if (Test-GuiCellEdited $s $s.Rows[$e.RowIndex] $s.Columns[$e.ColumnIndex].Name) { $e.CellStyle.BackColor = Get-GuiEditedColor }
            })
    }
    $g.Chart.Add_Paint({ param($s, $e) Invoke-GuiHistogramPaint $e.Graphics })
    $g.Chart.Add_Resize({ $script:App.Chart.Invalidate() })
    $g.Chart.Add_MouseMove({
            param($s, $e)
            $i = Get-GuiChartStepAt $e.Location
            if ($i -ne $script:App.ChartHover) { $script:App.ChartHover = $i; $s.Invalidate() }
        })
    $g.Chart.Add_MouseLeave({ if ($script:App.ChartHover -ge 0) { $script:App.ChartHover = -1; $script:App.Chart.Invalidate() } })
    $g.Chart.Add_MouseClick({ param($s, $e) $i = Get-GuiChartStepAt $e.Location; if ($i -ge 0) { Select-GuiHistogramRow $i } })
    $g.Grids.Histogram.Add_SelectionChanged({
            # Grid selection -> highlight the step in the chart (Step n is chart index n - 1).
            param($s, $e)
            $i = -1
            if ($s.SelectedCells.Count -gt 0) { $i = [int]$s.Rows[$s.SelectedCells[0].RowIndex].Cells['Step'].Value - 1 }
            if ($i -ne $script:App.ChartSelected) { $script:App.ChartSelected = $i; $script:App.Chart.Invalidate() }
        })
    $g.HistSplit.Add_SizeChanged({
            param($s, $e)
            try { $s.SplitterDistance = [int][Math]::Min([Math]::Max(60, ($s.Height - $s.SplitterWidth) * $script:App.HistRatio), [Math]::Max(60, $s.Height - $s.SplitterWidth - 60)) } catch { }
        })
    $g.HistSplit.Add_SplitterMoved({ param($s, $e) if ($s.Height -gt 0) { $script:App.HistRatio = $s.SplitterDistance / [double]($s.Height - $s.SplitterWidth) } })
    $g.CheckData.Add_Click({ Start-GuiDataCheck })
    $g.Grids.CheckSummary.Add_CellFormatting({
            # the Result row's value in its rating color
            param($s, $e)
            if ($e.RowIndex -ge 0 -and $s.Columns[$e.ColumnIndex].Name -eq 'Value' -and [string]$s.Rows[$e.RowIndex].Cells['Field'].Value -eq 'Result') {
                $e.CellStyle.ForeColor = Get-GuiResultColor ([string]$e.Value)
            }
        })
    $form.Add_KeyDown({
            param($s, $e)
            $app = $script:App
            if ($e.KeyCode -eq 'F5' -and -not $app.Job) {
                $e.Handled = $true
                if ($app.Conn -and $app.Tables.SelectedIndex -ge 0) { Start-GuiDecode }
                elseif ($app.Conn) { Set-GuiStatus 'Pick a table first.' }
                else { Set-GuiStatus 'Connect to a server first (Ctrl+N), or paste a STATS_STREAM (Ctrl+Shift+V).' }
            }
            if ($e.KeyCode -eq 'F6' -and -not $app.Job) { $e.Handled = $true; Start-GuiDataCheck }
            if ($e.KeyCode -eq 'Escape' -and $app.Job) { $e.Handled = $true; Stop-GuiDecode }
        })
    $form.Add_Load({
            param($s, $e)
            $s.SuspendLayout()
            $split = $s.Controls | Where-Object { $_ -is [Windows.Forms.SplitContainer] }
            $split.SplitterDistance = [int](380 * $s.DeviceDpi / 96.0)
            Write-GuiStartup "Applying the $($script:GuiTheme.ToLower()) theme..."
            Set-GuiControlTheme $s
            $s.ResumeLayout()
            [StatsStreamDecoder.Appearance.Cue]::Set($script:App.TableFilter, 'Search tables')
        })
    $form.Add_FormClosing({
            $app = $script:App
            if ($app.Job) {
                $app.Timer.Stop()
                # Do not wait for a running query; the runspace ends with it.
                try { $null = $app.Job.PowerShell.BeginStop($null, $null) } catch { }
                $app.Job = $null
            }
            Save-GuiSettings
        })

    $form.Add_Shown({ Write-GuiStartup 'SQLStatsXRay is open. Keep this console window open: closing it closes the application.' })

    Set-GuiConnected $null
    Set-GuiStatus 'Connect to a server (Ctrl+N), or paste a STATS_STREAM (Ctrl+Shift+V).'
    Write-GuiStartup 'Opening the window...'
    try { $null = $form.ShowDialog() }
    finally { $g.Timer.Dispose(); $form.Dispose() }
}

#endregion

#region ---------------------------------------------------------------- entry point

if ($PSCmdlet.ParameterSetName -eq 'Gui') {
    $script:DecoderPath = $PSCommandPath
    # progress timestamps count from the process start, so they include PowerShell's own startup
    try { $script:GuiStartedAt = [Diagnostics.Process]::GetCurrentProcess().StartTime } catch { $script:GuiStartedAt = [DateTime]::Now }
    Show-DecoderWindow
    return
}

$allLines = New-Object 'System.Collections.Generic.List[string]'
$objects = @()
$buildReport = $GuiRun -or -not $PassThru

if ($PSCmdlet.ParameterSetName -in 'Hex', 'File') {
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $path = (Resolve-Path $InputFile).Path
        $raw = [IO.File]::ReadAllBytes($path)
        $text = $null
        try { $text = [Text.Encoding]::ASCII.GetString($raw).Trim() } catch { }
        if ($text -and $text -match '^(0x)?[0-9A-Fa-f\s]+$') { $bytes = ConvertFrom-HexString $text } else { $bytes = $raw }
        $label = $path
    } else {
        $bytes = ConvertFrom-HexString $StatsStream
        $label = 'STATS_STREAM from parameter'
    }
    $script:CollationInfo = @{}
    $d = ConvertFrom-StatsStream -Bytes $bytes -Names $ColumnNames -Label $label
    $objects += $d
    if ($buildReport) { $allLines.AddRange([string[]](Format-StatsReport $d $null)) }
} else {
    if ($PSCmdlet.ParameterSetName -eq 'ConnStr') {
        $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $ConnectionString
        $csb['Initial Catalog'] = $Database
    } else {
        $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $csb['Data Source'] = $ServerInstance
        $csb['Initial Catalog'] = $Database
        $csb['Application Name'] = 'SQLStatsXRay'
        if ($TrustServerCertificate) { $csb['Encrypt'] = $true; $csb['TrustServerCertificate'] = $true }
        if (-not $Credential) { $csb['Integrated Security'] = $true }
    }
    $cn = New-Object System.Data.SqlClient.SqlConnection $csb.ConnectionString
    if ($PSCmdlet.ParameterSetName -eq 'Server' -and $Credential) {
        $pw = $Credential.Password.Copy(); $pw.MakeReadOnly()
        $cn.Credential = New-Object System.Data.SqlClient.SqlCredential ($Credential.UserName, $pw)
    }
    $cn.Open()
    $dac = $null
    if ($UseDac) {
        $dcsb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $csb.ConnectionString
        $dcsb['Data Source'] = 'admin:' + $ServerInstance
        $dcsb['Pooling'] = $false
        $dac = New-Object System.Data.SqlClient.SqlConnection $dcsb.ConnectionString
        if ($Credential) { $dac.Credential = $cn.Credential }
        try { $dac.Open() }
        catch { Write-Warning "DAC connection failed ($($_.Exception.Message)); Snapshot Ctr will be estimated."; $dac = $null }
    }
    try {
        $ver = (Invoke-Query $cn "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) v, @@SERVERNAME s")[0].Rows[0]
        if ($Build) {
            if (@($Statistics).Count -gt 1) { throw '-Build takes one statistics object (or -AllStatistics).' }
            if ($AllStatistics) {
                $b = Invoke-StatsBuildTable -Connection $cn -Database $Database -TableName $Table -Sample $Sample -Sampler $Sampler -Algorithms $Algorithm `
                    -NoRecompute ([bool]$NoRecompute) -Seed $Seed -TimeoutSeconds 0 -UseWorkload (-not $NoWorkload) -AdaptiveLimit $AdaptiveLimit
            } else {
                $b = Invoke-StatsBuild -Connection $cn -Database $Database -TableName $Table -StatName $(if ($Statistics) { $Statistics[0] }) -ColumnName $Column -Sample $Sample `
                    -Sampler $Sampler -Algorithms $Algorithm -NewStatName $NewStatisticsName -NoRecompute ([bool]$NoRecompute) -Seed $Seed -TimeoutSeconds 0 -UseWorkload (-not $NoWorkload) -AdaptiveLimit $AdaptiveLimit
            }
            $objects += $b
            if ($OutputScript) {
                [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputScript), $b.Script, (New-Object Text.UTF8Encoding $true))
            }
            if ($buildReport) {
                $allLines.AddRange([string[]]$(if ($AllStatistics) { Format-StatsBuildTableReport $b -ShowCandidates:$ShowCandidates } else { Format-StatsBuildReport $b -ShowCandidates:$ShowCandidates }))
                if ($OutputScript) { $allLines.Add("Script written to $([IO.Path]::GetFullPath($OutputScript)).") }
                else { $allLines.AddRange([string[]](New-Section 'SCRIPT')); $allLines.AddRange([string[]]($b.Script -split "`r`n")) }
            }
            $target = [pscustomobject]@{ Schema = ''; Table = ''; Stats = @() }
        } else { $target = Get-StatsTargets $cn $Table $Statistics }
        $qualified = '[' + $target.Schema.Replace(']', ']]') + '].[' + $target.Table.Replace(']', ']]') + ']'
        $tf2388 = $null
        if ($Validate) { $tf2388 = Get-TraceFlag2388FromServer $cn $qualified @($target.Stats | ForEach-Object { [string]$_.name }) }
        foreach ($st in $target.Stats) {
            $statName = [string]$st.name
            $q = Read-ResultSets $cn @'
DECLARE @cmd nvarchar(max) = N'DBCC SHOW_STATISTICS(' + QUOTENAME(@t, '''') + N', ' + QUOTENAME(@s) + N') WITH STATS_STREAM, NO_INFOMSGS';
EXEC sys.sp_executesql @cmd;
'@ @{ '@t' = $qualified; '@s' = $statName }
            $bytes = [byte[]](@($q[0])[0].Stats_Stream)
            Get-CollationInfo $cn (Get-ColumnIdsFromStream $bytes)
            $names = Get-StatsColumnNames $cn $target.ObjectId ([int]$st.stats_id) ([BitConverter]::ToInt32($bytes, 4))
            $d = ConvertFrom-StatsStream -Bytes $bytes -Names $names -Label "[$($ver.s)].[$Database].$qualified.[$statName]"
            Resolve-PendingValues $d $cn
            $d.CurrentSnapshotCtr = Get-CurrentSnapshotCtr $dac $target.ObjectId ([int]$st.stats_id)
            $d.TraceFlag2388 = Get-TraceFlag2388View $d

            $info = [ordered]@{
                'Server'            = "$($ver.s) (SQL Server $($ver.v))"
                'Database'          = $Database
                'Table'             = $qualified
                'Statistics'        = "$statName (stats_id $($st.stats_id))"
                'Kind'              = $(if ($st.index_type -is [DBNull] -or -not $st.index_type) { 'column statistics' } else { "index statistics ($($st.index_type))" })
                'Auto created'      = $st.auto_created
                'User created'      = $st.user_created
                'No recompute'      = $st.no_recompute
                'Incremental'       = $st.is_incremental
                'Filter'            = $(if ($st.has_filter) { $st.filter_definition } else { '' })
                'Modification ctr'  = $st.sp_modification_counter
            }
            if ($st.Table.Columns.Contains('auto_drop')) { $info['Auto drop'] = $st.auto_drop }
            if ($st.Table.Columns.Contains('has_persisted_sample')) { $info['Has persisted sample'] = $st.has_persisted_sample }
            $d | Add-Member ServerInfo $info
            # Where an edited copy of these statistics would be loaded back (the app's script generator).
            $d | Add-Member Target ([pscustomobject]@{ Server = [string]$csb['Data Source']; Database = $Database; Table = $qualified; Statistics = $statName; NoRecompute = [bool]$st.no_recompute })

            if ($Validate) {
                $checks = Test-StatsAgainstServer $d $cn $qualified $statName $tf2388
                $d | Add-Member Validation $checks
            }
            if ($VerifyData) {
                try { $check = Test-StatsAgainstData -D $d -Connection $cn -ObjectId $target.ObjectId -Stat $st -QualifiedTable $qualified -PageBudget $VerifyPageBudget -TimeoutSeconds $VerifyTimeout -StepDelay $VerifyStepDelay }
                catch { $check = New-DataCheckResult "the check failed: $($_.Exception.Message)" }
                $d | Add-Member DataCheck $check
            }
            $objects += $d
            if ($buildReport) {
                $allLines.AddRange([string[]](Format-StatsReport $d $info))
                if ($Validate) {
                    $allLines.AddRange([string[]](New-Section 'VALIDATION AGAINST DBCC SHOW_STATISTICS'))
                    $allLines.AddRange([string[]](Format-AsciiTable -Rows $d.Validation -Columns Check, Server, Decoded, Result))
                    $nbad = @($d.Validation | Where-Object { $_.Result -eq 'MISMATCH' }).Count
                    $allLines.Add($(if ($nbad -eq 0) { 'VALIDATION PASSED' } else { "VALIDATION FAILED: $nbad check(s)" }))
                }
                if ($VerifyData) { $allLines.AddRange([string[]](Format-DataCheckSection $d.DataCheck)) }
                $allLines.Add('')
            }
        }
    } finally {
        $cn.Close()
        if ($dac) { $dac.Close() }
    }
}

if ($OutputFile) {
    [IO.File]::WriteAllLines([IO.Path]::GetFullPath($OutputFile), $allLines.ToArray(), (New-Object Text.UTF8Encoding $true))
}
if ($GuiRun) { [pscustomobject]@{ Objects = $objects; Lines = $allLines.ToArray() } }
elseif ($PassThru) { $objects } else { $allLines.ToArray() }

#endregion
