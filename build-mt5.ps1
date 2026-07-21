# Compiles the MQL5 EAs (src-mt5/*.mq5) and installs them into the production
# MT5 terminal. Usage: powershell -ExecutionPolicy Bypass -File build-mt5.ps1
#
# Production: MetaTrader 5 EXNESS (Trial account 198622897 @ Exness-MT5Trial11).
# Compiles DIRECTLY in the Exness terminal data folder with its MetaEditor
# (works with the terminal open; restart the terminal to load the new .ex5).
# If the Exness install is missing, falls back to the portable MT5Lab
# (%LOCALAPPDATA%\Programs\MT5Lab) used for backtests.

$ExnessInstall = "C:\Program Files\MetaTrader 5 EXNESS"
$ExnessData    = "$env:APPDATA\MetaQuotes\Terminal\53785E099C927DB68A545C249CDBCE06"
$Src           = Join-Path $PSScriptRoot "src-mt5"

if (Test-Path (Join-Path $ExnessInstall "MetaEditor64.exe")) {
    $Editor = Join-Path $ExnessInstall "MetaEditor64.exe"
    $MQL5   = Join-Path $ExnessData "MQL5"
    Write-Host "Target: Exness terminal ($ExnessData)"
} else {
    # Fallback: portable lab MT5 (mt5setup.exe /auto /path:...MT5Lab - path without spaces)
    $MT5 = "$env:LOCALAPPDATA\Programs\MT5Lab"
    if (-not (Test-Path (Join-Path $MT5 "MetaEditor64.exe"))) { $MT5 = Join-Path $PSScriptRoot "lab\mt5" }
    $Editor = Join-Path $MT5 "MetaEditor64.exe"
    $MQL5   = Join-Path $MT5 "MQL5"
    if (-not (Test-Path $Editor)) {
        Write-Host "ERROR: MetaEditor64.exe not found (no Exness, MT5Lab or lab\mt5)"
        exit 1
    }
    Write-Host "Target: portable MT5Lab ($MT5)"
}

$Experts = Join-Path $MQL5 "Experts"
if (-not (Test-Path $Experts)) { New-Item -ItemType Directory -Force $Experts | Out-Null }

$fail = 0
$sources = (Get-ChildItem $Src -Filter *.mq5).Name
if (-not $sources) { Write-Host "FAILED: no .mq5 sources found in $Src"; exit 1 }
foreach ($f in $sources) {
    Copy-Item (Join-Path $Src $f) $Experts -Force
    $target = Join-Path $Experts $f
    $log = [System.IO.Path]::ChangeExtension($target, ".log")
    if (Test-Path $log) { Remove-Item $log -Force }
    & $Editor /compile:"$target" /include:"$MQL5" /log | Out-Null
    Write-Host "--- $f ---"
    if (Test-Path $log) {
        Get-Content $log | Where-Object { $_ -match "error|warning|Result" }
        if ((Get-Content $log -Raw) -notmatch "\b0 errors\b") { $fail++ }
    } else {
        Write-Host "(no compile log)"
        $fail++
    }
}
if ($fail -gt 0) { Write-Host "$fail EAs FAILED"; exit 1 }
Write-Host "OK: all EAs compiled with 0 errors"
Write-Host "Reminder: restart the Exness terminal to load the new .ex5 files"
