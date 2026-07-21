# Compiles the MQL4 EAs (src-mt4/*.mq4) and installs them into the production
# MT4 terminal. Usage: powershell -ExecutionPolicy Bypass -File build.ps1
#
# Production: MetaTrader 4 EXNESS (demo account 73114636). Compiles DIRECTLY in
# the terminal data folder with its MetaEditor (works with the terminal open;
# restart the terminal to load the new .ex4). Twin of build-mt5.ps1.

$Install = "C:\Program Files (x86)\MetaTrader 4 EXNESS"
$Data    = "$env:APPDATA\MetaQuotes\Terminal\2191F4A3D14D7B4B1EBB84F924777883"
$Src     = Join-Path $PSScriptRoot "src-mt4"

$Editor = Join-Path $Install "metaeditor.exe"
if (-not (Test-Path $Editor)) { Write-Host "ERROR: metaeditor.exe not found in $Install"; exit 1 }

$Experts = Join-Path $Data "MQL4\Experts"
if (-not (Test-Path $Experts)) { Write-Host "ERROR: Experts folder not found: $Experts"; exit 1 }
Write-Host "Target: Exness MT4 terminal ($Data)"

$fail = 0
$sources = (Get-ChildItem $Src -Filter *.mq4).Name
if (-not $sources) { Write-Host "FAILED: no .mq4 sources found in $Src"; exit 1 }
foreach ($f in $sources) {
    Copy-Item (Join-Path $Src $f) $Experts -Force
    $target = Join-Path $Experts $f
    $log = [System.IO.Path]::ChangeExtension($target, ".log")
    if (Test-Path $log) { Remove-Item $log -Force }
    & $Editor /compile:"$target" /log | Out-Null
    Write-Host "--- $f ---"
    if (Test-Path $log) {
        # The MT4 MetaEditor writes its log as UTF-16.
        $text = Get-Content $log -Raw -Encoding Unicode
        $text -split "`r?`n" | Where-Object { $_ -match "error|warning|Result" }
        if ($text -notmatch "0 error") { $fail++ }
    } else {
        Write-Host "(no compile log)"
        $fail++
    }
}
if ($fail -gt 0) { Write-Host "$fail EAs FAILED"; exit 1 }
Write-Host "OK: all EAs compiled with 0 errors"
Write-Host "Reminder: restart the Exness MT4 terminal to load the new .ex4 files"
