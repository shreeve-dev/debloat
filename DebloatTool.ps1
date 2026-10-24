<#
.SYNOPSIS
    DebloatTool - debloat and tune Windows 11, with a full undo history.

.DESCRIPTION
    With no parameters, opens the window (asks for admin rights).
    The command-line switches below let you script it or check things without the window.

.EXAMPLE
    .\DebloatTool.ps1                                  # open the app
    .\DebloatTool.ps1 -Status                          # show which tweaks are applied (no admin needed)
    .\DebloatTool.ps1 -Preset Gaming -Preview          # list exactly what a preset would change
    .\DebloatTool.ps1 -Preset Recommended -Apply       # apply a preset
    .\DebloatTool.ps1 -Tweak explorer.*,qol.darkmode -Apply
    .\DebloatTool.ps1 -UndoLast                        # undo the most recent change set
    .\DebloatTool.ps1 -Bundle "Gaming" -Preview        # which apps in a bundle are installed
    .\DebloatTool.ps1 -Bundle "Gaming" -Apply          # install the missing ones (great after a fresh Windows install)
#>
[CmdletBinding()]
param(
    [string]$Preset,
    [string[]]$Tweak,
    [string]$Bundle,
    [switch]$Apply,
    [switch]$Preview,
    [switch]$Status,
    [switch]$UndoLast,
    [switch]$SkipRestorePoint,
    [switch]$NoElevate,
    [string]$SmokeTest
)

$script:Root = $PSScriptRoot
. (Join-Path $script:Root 'src\Engine.ps1')
. (Join-Path $script:Root 'src\Apps.ps1')
. (Join-Path $script:Root 'src\Installer.ps1')
. (Join-Path $script:Root 'src\IsoBuilder.ps1')
. (Join-Path $script:Root 'src\Settings.ps1')

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$cli = $Status -or $Preview -or $Apply -or $UndoLast
$needsAdmin = $Apply -or $UndoLast -or (-not $cli -and -not $SmokeTest)

if ($needsAdmin -and -not $script:IsAdmin -and -not $NoElevate) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value) { $argList += "-$($kv.Key)" }
        } elseif ($kv.Value -is [array]) {
            $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value -join ',')`""
        } else {
            $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`""
        }
    }
    try {
        if ($cli) {
            Start-Process powershell.exe -Verb RunAs -ArgumentList (@('-NoExit') + $argList) -ErrorAction Stop
        } else {
            Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $argList -ErrorAction Stop
        }
    } catch {
        Write-Host 'DebloatTool needs administrator rights to make changes. The admin prompt was cancelled.' -ForegroundColor Yellow
    }
    return
}

Import-DebloatConfig
Import-InstallCatalog
Import-SettingsCatalog
$Tweak =@($Tweak | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not $cli) {
    . (Join-Path $script:Root 'src\Gui.ps1')
    Show-DebloatGui -SmokeDir $SmokeTest
    return
}

if ($Status) {
    $rows = foreach ($t in $script:Catalog) {
        [pscustomobject]@{ Id = $t.id; Risk = $t.risk; Status = (Get-TweakStatus $t).State; Name = $t.name }
    }
    $rows | Format-Table -AutoSize
    $applied = @($rows | Where-Object { $_.Status -eq 'Applied' }).Count
    Write-Host "$applied of $($rows.Count) tweaks applied."
    return
}

if ($UndoLast) {
    $last = @(Get-Journal | Where-Object { -not $_.undone }) | Select-Object -Last 1
    if (-not $last) { Write-Host 'Nothing to undo.'; return }
    Write-Host "Undoing: $($last.name)"
    $errs = @(Undo-JournalEntry $last.id)
    foreach ($e in $errs) { Write-Host "  ! $e" -ForegroundColor Yellow }
    if (-not $errs.Count) { Write-Host '  restored' -ForegroundColor Green }
    return
}

# -Bundle: show or install the apps in an install bundle
if ($Bundle) {
    $b = $script:InstallBundles | Where-Object { $_.name -eq $Bundle } | Select-Object -First 1
    if (-not $b) { throw "Unknown bundle '$Bundle'. Choose from: $(($script:InstallBundles | ForEach-Object { $_.name }) -join ', ')" }
    $inv = @(Get-InstallInventory | Where-Object { @($b.apps) -contains $_.Key })
    Write-Host "BUNDLE: $($b.name)"
    foreach ($i in $inv) {
        $state = if ($i.Installed) { 'installed' } elseif ($i.WebsiteOnly) { 'website download' } else { 'will install' }
        Write-Host ('    {0,-32} {1}' -f $i.App.name, $state)
    }
    if ($Apply) {
        foreach ($i in @($inv | Where-Object { $_.WebsiteOnly -and -not $_.Installed })) { Open-AppWebsite $i.App }
        $todo = @($inv | Where-Object { -not $_.WebsiteOnly -and -not $_.Installed } | ForEach-Object { $_.App })
        if ($todo.Count) { $null = Start-WingetJob 'install' $todo; Write-Host "Installing $($todo.Count) app(s) in a separate window." -ForegroundColor Green }
        else { Write-Host 'Everything in this bundle is already installed.' -ForegroundColor Green }
    }
    if (-not $Preset -and -not $Tweak.Count) { return }
}

# -Preview / -Apply
$selected = New-Object System.Collections.Generic.List[object]
$apps = @()
if ($Preset) {
    $p = Get-Preset $Preset
    if (-not $p) { throw "Unknown preset '$Preset'. Choose from: $(($script:Presets | ForEach-Object { $_.name }) -join ', ')" }
    foreach ($t in (Resolve-PresetTweaks $p)) { $selected.Add($t) }
    if ($p.apps -eq 'recommended') { $apps = @(Get-AppInventory | Where-Object { $_.Group -eq 'Recommended' }) }
}
foreach ($pattern in $Tweak) {
    $hits = @($script:Catalog | Where-Object { $_.id -like $pattern })
    if (-not $hits.Count) { Write-Host "No tweak matches '$pattern'" -ForegroundColor Yellow }
    foreach ($t in $hits) { if (-not ($selected | Where-Object { $_.id -eq $t.id })) { $selected.Add($t) } }
}
if (-not $selected.Count -and -not $apps.Count) { Write-Host 'Nothing selected. Use -Preset and/or -Tweak.'; return }

Write-Host (Get-PlanText -Tweaks $selected.ToArray() -Apps $apps)
if ($Preview) { return }

if (-not $SkipRestorePoint) {
    Write-Host 'Creating a restore point...'
    $ok, $msg = New-SafetyRestorePoint
    Write-Host "  $msg"
}
foreach ($t in $selected) {
    if (-not @(Get-TweakPlan $t).Count) { continue }
    Write-Host "Applying: $($t.name)"
    $r = Invoke-Tweak $t
    foreach ($e in $r.Errors) { Write-Host "  ! $e" -ForegroundColor Yellow }
    Write-Host "  $($r.Changes) change(s)"
}
foreach ($a in $apps) {
    Write-Host "Removing app: $($a.Label)"
    try { Remove-App $a | ForEach-Object { Write-Host "  ! $_" -ForegroundColor Yellow } } catch { Write-Host "  ! $($_.Exception.Message)" -ForegroundColor Yellow }
}
Write-Host 'Done. Use -UndoLast or the History page to undo.' -ForegroundColor Green
