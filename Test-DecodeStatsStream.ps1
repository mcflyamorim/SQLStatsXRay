#Requires -Version 5.1
<#
.SYNOPSIS
    Decodes every statistics object in one or more databases with Decode-StatsStream.ps1
    -Validate and reports the ones whose decoded values differ from DBCC SHOW_STATISTICS.

.EXAMPLE
    .\Test-DecodeStatsStream.ps1 -ServerInstance "amorim-PF5ZTLCK\SQL2025" -Database StatsStreamLab, Northwind
#>
param(
    [Parameter(Mandatory = $true)] [string]$ServerInstance,
    [Parameter(Mandatory = $true)] [string[]]$Database,
    [switch]$ShowPassed,
    [switch]$UseDac
)

$ErrorActionPreference = 'Stop'
$decoder = Join-Path $PSScriptRoot 'Decode-StatsStream.ps1'
$total = 0; $failed = 0

foreach ($db in $Database) {
    $cn = New-Object System.Data.SqlClient.SqlConnection "Data Source=$ServerInstance;Initial Catalog=$db;Integrated Security=True"
    $cn.Open()
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(name) FROM sys.objects WHERE type IN ('U', 'V') AND is_ms_shipped = 0 AND EXISTS (SELECT 1 FROM sys.stats s WHERE s.object_id = sys.objects.object_id) ORDER BY 1"
    $r = $cmd.ExecuteReader()
    $tables = @(); while ($r.Read()) { $tables += $r.GetString(0) }
    $r.Close(); $cn.Close()

    foreach ($t in $tables) {
        try { $decoded = & $decoder -ServerInstance $ServerInstance -Database $db -Table $t -Validate -PassThru -UseDac:$UseDac }
        catch { $failed++; Write-Output "ERROR [$db].$t : $($_.Exception.Message)"; continue }
        foreach ($d in $decoded) {
            $total++
            $bad = @($d.Validation | Where-Object { $_.Result -eq 'MISMATCH' })
            if ($bad.Count -gt 0 -or -not $d.Header.ChecksumValid) {
                $failed++
                Write-Output "FAIL $($d.Label) (checksum valid: $($d.Header.ChecksumValid))"
                $bad | Select-Object -First 5 | ForEach-Object { Write-Output "     $($_.Check) | server: $($_.Server) | decoded: $($_.Decoded)" }
            } elseif ($ShowPassed) {
                Write-Output "ok   $($d.Label) ($(@($d.Histogram).Count) steps; items $(($d.VariableItems | ForEach-Object { $_.Bit }) -join ','))"
            }
        }
    }
}
Write-Output "Statistics decoded: $total   Failed: $failed"
