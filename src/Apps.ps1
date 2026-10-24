# Apps.ps1
# Built-in Store app removal and startup program management. Both go through the undo journal.

#region Store apps -----------------------------------------------------------

function Test-ProtectedApp([string]$Name) {
    foreach ($p in @($script:AppCatalog.protected)) { if ($Name -like $p) { return $true } }
    return $false
}

function Get-AppInventory {
    $installed = @(Get-AppxPackage -PackageTypeFilter Main -ErrorAction SilentlyContinue |
        Where-Object { -not $_.NonRemovable -and $_.SignatureKind -ne 'System' })
    $items = foreach ($p in $installed) {
        if (Test-ProtectedApp $p.Name) { continue }
        $entry = $script:AppCatalog.apps | Where-Object { $p.Name -like $_.name } | Select-Object -First 1
        $label = if ($entry) { $entry.label } else { $p.Name }
        [pscustomobject]@{
            Name            = $p.Name
            Label           = $label
            Group           = $(if ($entry) { $entry.group } else { 'Other' })
            Note            = $(if ($entry) { $entry.note } else { $null })
            Publisher       = ($p.Publisher -replace '^CN=([^,]+).*', '$1')
            PackageFullName = $p.PackageFullName
            FamilyName      = $p.PackageFamilyName
            InstallLocation = $p.InstallLocation
        }
    }
    $order = @{ Recommended = 0; Optional = 1; Caution = 2; Other = 3 }
    $items | Sort-Object @{ Expression = { $order[$_.Group] } }, Label
}

function Remove-App {
    param($App, [switch]$Deprovision)
    $change = [pscustomobject]@{
        kind = 'appx'; name = $App.Name; label = $App.Label
        packageFullName = $App.PackageFullName; familyName = $App.FamilyName
        installLocation = $App.InstallLocation; deprovisioned = $false
    }
    Remove-AppxPackage -Package $App.PackageFullName -ErrorAction Stop
    $errors = @()
    if ($Deprovision) {
        try {
            Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $App.Name } | ForEach-Object {
                Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                $change.deprovisioned = $true
            }
        } catch { $errors += "Could not remove the copy kept for new users: $($_.Exception.Message)" }
    }
    Add-JournalEntry (New-JournalEntry "app:$($App.Name)" "Remove app: $($App.Label)" @($change) $errors)
    $errors
}

# Undo for an app removal: re-register from the files Windows kept, otherwise open its Store page.
function Restore-App($Change) {
    $candidates = @()
    if ($Change.installLocation) { $candidates += $Change.installLocation }
    try {
        $candidates += @(Get-AppxPackage -AllUsers -Name $Change.name -ErrorAction Stop | ForEach-Object { $_.InstallLocation })
    } catch { }
    foreach ($dir in $candidates) {
        $manifest = Join-Path $dir 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
            Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction Stop
            return
        }
    }
    Start-Process "ms-windows-store://pdp/?PFN=$($Change.familyName)"
    throw "Windows no longer has the files for $($Change.label). The Microsoft Store page has been opened so you can reinstall it."
}

#endregion
#region Startup programs -----------------------------------------------------

$script:ApprovedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:StartupSources = @(
    @{ Scope = 'Current user'; Type = 'Registry'; Key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKCU\$script:ApprovedRoot\Run" }
    @{ Scope = 'All users'; Type = 'Registry'; Key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM\$script:ApprovedRoot\Run" }
    @{ Scope = 'All users (32-bit)'; Type = 'Registry'; Key = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM\$script:ApprovedRoot\Run32" }
    @{ Scope = 'Current user'; Type = 'Startup folder'; Folder = [Environment]::GetFolderPath('Startup'); Approved = "HKCU\$script:ApprovedRoot\StartupFolder" }
    @{ Scope = 'All users'; Type = 'Startup folder'; Folder = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM\$script:ApprovedRoot\StartupFolder" }
)

function Get-ShortcutTarget([string]$Path) {
    if ($Path -notlike '*.lnk') { return $Path }
    try {
        if (-not $script:Shell) { $script:Shell = New-Object -ComObject WScript.Shell }
        $s = $script:Shell.CreateShortcut($Path)
        return ("$($s.TargetPath) $($s.Arguments)").Trim()
    } catch { return $Path }
}

function New-StartupItem($Source, [string]$Name, [string]$Command) {
    # Same rule Task Manager uses: an odd first byte in StartupApproved means disabled.
    $state = Get-RegValue $Source.Approved $Name
    $enabled = $true
    if ($state.Exists -and $state.Kind -eq 'Binary' -and $state.Value) {
        $first = [Convert]::ToByte(($state.Value -split ' ')[0], 16)
        $enabled = -not ($first -band 1)
    }
    [pscustomobject]@{
        Name     = $Name
        Command  = $Command
        Location = "$($Source.Scope) - $($Source.Type)"
        Approved = $Source.Approved
        Enabled  = $enabled
    }
}

function Get-StartupItems {
    foreach ($src in $script:StartupSources) {
        if ($src.Type -eq 'Registry') {
            $k = $null
            try { $k = Open-RegKey $src.Key } catch { }
            if (-not $k) { continue }
            try {
                foreach ($n in $k.GetValueNames()) {
                    if (-not $n) { continue }
                    New-StartupItem $src $n ([string]$k.GetValue($n))
                }
            } finally { $k.Close() }
        } else {
            if (-not $src.Folder -or -not (Test-Path -LiteralPath $src.Folder)) { continue }
            Get-ChildItem -LiteralPath $src.Folder -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'desktop.ini' } |
                ForEach-Object { New-StartupItem $src $_.Name (Get-ShortcutTarget $_.FullName) }
        }
    }
}

# Enables or disables a startup item the same way Task Manager does, so nothing is deleted.
function Set-StartupItemEnabled($Item, [bool]$Enabled) {
    if ($Enabled) {
        $value = '02 00 00 00 00 00 00 00 00 00 00 00'
        $verb = 'Enable'
    } else {
        $stamp = ([BitConverter]::GetBytes((Get-Date).ToFileTimeUtc()) | ForEach-Object { $_.ToString('X2') }) -join ' '
        $value = "03 00 00 00 $stamp"
        $verb = 'Disable'
    }
    $tweak = [pscustomobject]@{
        id       = "startup:$($Item.Name)"
        name     = "$verb startup item: $($Item.Name)"
        registry = @([pscustomobject]@{ path = $Item.Approved; name = $Item.Name; type = 'Binary'; value = $value })
    }
    Invoke-Tweak $tweak
}

#endregion
