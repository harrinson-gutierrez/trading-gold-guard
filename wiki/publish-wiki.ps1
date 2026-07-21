# Publishes wiki/*.md to the GitHub wiki (a separate git repo).
# Usage: powershell -ExecutionPolicy Bypass -File wiki\publish-wiki.ps1
#
# PREREQUISITE (one time, manual): GitHub does not create the wiki git repo
# until the first page exists. Open
#   https://github.com/harrinson-gutierrez/trading-gold-guard/wiki
# click "Create the first page", save anything (this script overwrites it).
# Until then, clone/push fail with "Repository not found" even though the
# wiki is enabled.

$WikiRemote = "https://github.com/harrinson-gutierrez/trading-gold-guard.wiki.git"
$Src        = $PSScriptRoot
$Work       = Join-Path $env:TEMP "tgg-wiki"

if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }

git clone $WikiRemote $Work
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Clone failed. If the error is 'Repository not found', create the first"
    Write-Host "wiki page by hand (see the header of this script), then re-run."
    exit 1
}

# Copy every page except this script itself.
Get-ChildItem $Src -Filter *.md | ForEach-Object { Copy-Item $_.FullName $Work -Force }

Push-Location $Work
git add -A
$changes = git status --porcelain
if (-not $changes) {
    Write-Host "Wiki already up to date."
    Pop-Location
    exit 0
}
git commit -m "Update wiki from repo wiki/ folder"
git push
$code = $LASTEXITCODE
Pop-Location

if ($code -ne 0) { Write-Host "Push failed."; exit 1 }
Write-Host "OK: wiki published -> https://github.com/harrinson-gutierrez/trading-gold-guard/wiki"
