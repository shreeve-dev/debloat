# InstallApps.ps1
# Installs the apps from your chosen bundles on a freshly installed PC, then removes its own scheduled task.
# Safe to run again: apps that are already installed are skipped.

$Host.UI.RawUI.WindowTitle = 'DebloatTool - setting up your apps'
$root = Split-Path $PSScriptRoot -Parent
Start-Transcript -Path (Join-Path $PSScriptRoot 'apps.log') -Append | Out-Null
$s = Get-Content (Join-Path $PSScriptRoot 'settings.json') -Raw | ConvertFrom-Json

Write-Host ''
Write-Host '  DebloatTool is installing your apps. Leave this window open.' -ForegroundColor Cyan
Write-Host ''

# 1. Internet
Write-Host 'Waiting for an internet connection...'
$online = $false
for ($i = 0; $i -lt 180; $i++) {
    try {
        $r = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5
        if ($r.Content -match 'Microsoft Connect Test') { $online = $true; break }
    } catch { }
    Start-Sleep -Seconds 5
}
if (-not $online) {
    Write-Host 'No internet after 15 minutes. Connect to a network and sign out and back in - this will run again.' -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    Read-Host 'Press Enter to close'
    exit 1
}

# 2. winget (on a brand-new install it can take a few minutes to register)
Write-Host 'Waiting for winget...'
for ($i = 0; $i -lt 60; $i++) {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { break }
    if ($i -eq 0) {
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { }
    }
    Start-Sleep -Seconds 5
}
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'winget is not available yet. Update "App Installer" from the Microsoft Store, then sign out and back in.' -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    Read-Host 'Press Enter to close'
    exit 1
}
winget source update --disable-interactivity | Out-Null

# 3. Apps
$results = @()
$flags = @('--exact', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
foreach ($a in @($s.apps | Where-Object { -not $_.noAdmin })) {
    winget list --id $a.id --exact --source winget --disable-interactivity | Out-Null
    if ($LASTEXITCODE -eq 0) { $results += [pscustomobject]@{ App = $a.name; Result = 'Already installed' }; continue }
    Write-Host ''
    Write-Host "==> Installing $($a.name)" -ForegroundColor Cyan
    winget install --id $a.id @flags
    $results += [pscustomobject]@{ App = $a.name; Result = $(if ($LASTEXITCODE -eq 0) { 'OK' } else { "Failed (code $LASTEXITCODE)" }) }
}

# Some apps (e.g. Spotify) refuse to install as administrator: install those in a normal window.
$noAdmin = @($s.apps | Where-Object { $_.noAdmin })
if ($noAdmin.Count) {
    for ($i = 0; $i -lt 60 -and -not (Get-Process explorer -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 2 }
    $script:Root = $root
    . (Join-Path $root 'src\Engine.ps1')
    . (Join-Path $root 'src\Installer.ps1')
    $null = Start-WingetJob 'install' $noAdmin
    foreach ($a in $noAdmin) { $results += [pscustomobject]@{ App = $a.name; Result = 'Installing in a separate window' } }
}

# 4. Apps that aren't in winget: open their download pages in your normal browser
foreach ($u in @($s.urls)) {
    Start-Process explorer.exe -ArgumentList "`"$($u.url)`""
    $results += [pscustomobject]@{ App = $u.name; Result = 'Download page opened' }
}

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

Unregister-ScheduledTask -TaskName 'DebloatTool first-boot apps' -Confirm:$false -ErrorAction SilentlyContinue
Write-Host 'All done. Some changes (mouse, menus) apply after you sign out and back in once.' -ForegroundColor Green
Write-Host "DebloatTool is in $root - run Run.bat there any time. Logs: $PSScriptRoot"
Stop-Transcript | Out-Null
Read-Host 'Press Enter to close'
