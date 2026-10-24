# IsoBuildJob.ps1
# Runs an ISO build in its own window (started by the ISO Builder page). Needs administrator rights.
param([Parameter(Mandatory)][string]$SettingsPath)

$Host.UI.RawUI.WindowTitle = 'DebloatTool - Building your Windows ISO'
$script:Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $script:Root 'src\Engine.ps1')
. (Join-Path $script:Root 'src\Apps.ps1')
. (Join-Path $script:Root 'src\Installer.ps1')
. (Join-Path $script:Root 'src\IsoBuilder.ps1')
Import-DebloatConfig
Import-InstallCatalog

$s = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
Remove-Item -LiteralPath $SettingsPath -Force   # it can contain the account password

Write-Host 'Building a custom Windows ISO. This usually takes 15-40 minutes.' -ForegroundColor Cyan
Write-Host "Source: $($s.IsoPath)"
Write-Host "Edition: $($s.EditionName)"
$sw = [Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{ ok = $false; iso = $null; error = $null; minutes = 0 }
try {
    $result.iso = Invoke-IsoBuild $s
    $result.ok = $true
} catch {
    $result.error = $_.Exception.Message
    Write-Host ''
    Write-Host "Build failed: $($result.error)" -ForegroundColor Red
}
$result.minutes = [math]::Round($sw.Elapsed.TotalMinutes, 1)
if ($s.DoneFile) { Set-Content -LiteralPath $s.DoneFile -Value (ConvertTo-Json $result) -Encoding UTF8 }
Write-Host ''
if (-not $s.NoPause) { Read-Host 'Press Enter to close this window' }
