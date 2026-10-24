# Installer.ps1
# App installs, updates and uninstalls through winget. Jobs run in their own window as the normal
# (non-admin) user, because some apps refuse to install elevated. winget asks for admin itself when needed.

$script:CustomBundlePath = $null

function Import-InstallCatalog {
    [CmdletBinding()]
    param(
        [string]$ConfigDir = (Join-Path $script:Root 'config'),
        [string]$BundleDir = $script:DataDir
    )
    $script:InstallCatalog = Get-Content (Join-Path $ConfigDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    # Your own bundles live in %LOCALAPPDATA%\DebloatTool\custom-bundles.json, outside the app folder,
    # so they survive updates and fresh downloads. config\custom-bundles.example.json shows the format.
    $script:CustomBundlePath = Join-Path $BundleDir 'custom-bundles.json'
    $legacy = Join-Path $ConfigDir 'custom-bundles.json'
    if (-not (Test-Path $script:CustomBundlePath) -and (Test-Path $legacy)) {
        # Older versions kept the file in config\. Copy it over once; the old file is left alone.
        try {
            New-Item -ItemType Directory -Force $BundleDir | Out-Null
            Copy-Item -LiteralPath $legacy -Destination $script:CustomBundlePath
        } catch {
            Write-Warning "Could not move $legacy to ${BundleDir}: $($_.Exception.Message)"
        }
    }
    $script:InstallBundles = @($script:InstallCatalog.bundles)
    # A broken file is skipped, not fatal.
    if (Test-Path $script:CustomBundlePath) {
        try {
            $custom = Get-Content $script:CustomBundlePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($b in @($custom.bundles)) { if ($b -and $b.name) { $b | Add-Member -NotePropertyName custom -NotePropertyValue $true -Force; $script:InstallBundles += $b } }
        } catch {
            Write-Warning "Skipped $($script:CustomBundlePath): $($_.Exception.Message)"
        }
    }
}

# winget id when there is one, otherwise the display name (website-only apps).
function Get-InstallKey($App) { if ($App.id) { $App.id } else { $App.name } }

function Test-Winget { [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) }

function Get-ArpNames {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($p in $paths) {
        Get-ItemProperty $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object { [string]$_.DisplayName }
    }
}

# Installed and upgradable winget ids, plus installed-program names for apps winget can't match.
function Get-InstallInventory {
    $installed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $upgrades  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (Test-Winget) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dbt-winget-" + [guid]::NewGuid().ToString('N') + '.json')
        winget export -o $tmp --source winget --accept-source-agreements --disable-interactivity | Out-Null
        if (Test-Path $tmp) {
            $j = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($src in @($j.Sources)) { foreach ($p in @($src.Packages)) { if ($p) { [void]$installed.Add($p.PackageIdentifier) } } }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        $lines = @(winget upgrade --source winget --accept-source-agreements --disable-interactivity)
        foreach ($app in @($script:InstallCatalog.apps)) {
            if ($app.id -and ($lines -match ('\s' + [regex]::Escape($app.id) + '\s'))) { [void]$upgrades.Add($app.id) }
        }
    }
    $arp = @(Get-ArpNames)
    foreach ($app in @($script:InstallCatalog.apps)) {
        $byWinget = $app.id -and $installed.Contains($app.id)
        $byName = $false
        if ($app.arp) { foreach ($n in $arp) { if ($n -like $app.arp) { $byName = $true; break } } }
        [pscustomobject]@{
            Key         = Get-InstallKey $app
            App         = $app
            Installed   = ($byWinget -or $byName)
            Update      = ($app.id -and $upgrades.Contains($app.id))
            WebsiteOnly = (-not $app.id)
        }
    }
}

function ConvertTo-PsLiteral([string]$Text) { "'" + ($Text -replace "'", "''") + "'" }

# Starts a winget job in its own window. Returns the path of a file that appears when the job finishes.
function Start-WingetJob {
    param([ValidateSet('install', 'upgrade', 'uninstall')][string]$Operation, [object[]]$Apps)
    $jobs = Join-Path $script:DataDir 'jobs'
    if (-not (Test-Path $jobs)) { New-Item -ItemType Directory -Path $jobs -Force | Out-Null }
    Get-ChildItem $jobs -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ps1  = Join-Path $jobs "$Operation-$stamp.ps1"
    $cmd  = Join-Path $jobs "$Operation-$stamp.cmd"
    $done = Join-Path $jobs "$Operation-$stamp.done"

    $verb = @{ install = 'Installing'; upgrade = 'Updating'; uninstall = 'Uninstalling' }[$Operation]
    $flags = '--exact --source winget --accept-source-agreements --disable-interactivity'
    if ($Operation -ne 'uninstall') { $flags += ' --accept-package-agreements' }

    $list = ($Apps | ForEach-Object { "    @{ id = $(ConvertTo-PsLiteral $_.id); name = $(ConvertTo-PsLiteral $_.name) }" }) -join "`r`n"
    $script = @"
`$Host.UI.RawUI.WindowTitle = 'DebloatTool - $verb apps'
`$apps = @(
$list
)
`$results = @()
foreach (`$a in `$apps) {
    Write-Host ''
    Write-Host ("==> $verb {0}  ({1})" -f `$a.name, `$a.id) -ForegroundColor Cyan
    winget $Operation --id `$a.id $flags
    `$code = `$LASTEXITCODE
    `$status = if (`$code -eq 0) { 'OK' } else { 'Failed (winget code ' + `$code + ')' }
    `$results += [pscustomobject]@{ App = `$a.name; Result = `$status }
}
Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
`$results | Format-Table -AutoSize | Out-String | Write-Host
Set-Content -LiteralPath $(ConvertTo-PsLiteral $done) -Value 'done'
Read-Host 'Finished. Press Enter to close this window'
"@
    [IO.File]::WriteAllText($ps1, $script, (New-Object System.Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText($cmd, "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1`"`r`n")
    # Launching through Explorer runs the job as the normal user even when this tool is elevated.
    Start-Process explorer.exe -ArgumentList "`"$cmd`""
    $done
}

# Website-only apps (e.g. NVIDIA App): open the official page in the user's normal browser.
function Open-AppWebsite($App) {
    Start-Process explorer.exe -ArgumentList "`"$($App.url)`""
}

function Save-CustomBundle([string]$Name, [string[]]$Keys) {
    $existing = @()
    if (Test-Path $script:CustomBundlePath) { $existing = @((Get-Content $script:CustomBundlePath -Raw -Encoding UTF8 | ConvertFrom-Json).bundles | Where-Object { $_ -and $_.name -ne $Name }) }
    $all = @($existing) + [pscustomobject]@{ name = $Name; description = 'Your saved selection.'; apps = @($Keys) }
    $json = ConvertTo-Json -InputObject ([pscustomobject]@{ bundles = @($all) }) -Depth 5
    New-Item -ItemType Directory -Force (Split-Path $script:CustomBundlePath -Parent) | Out-Null
    [IO.File]::WriteAllText($script:CustomBundlePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Import-InstallCatalog -BundleDir (Split-Path $script:CustomBundlePath -Parent)
}
