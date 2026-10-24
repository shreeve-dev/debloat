# IsoBuilder.ps1
# Builds a custom Windows ISO: one edition, bloat apps removed, this PC's drivers added,
# setup screens answered automatically, and DebloatTool set to run on first sign-in.
# Choosing the disk to install to is never automated, so the ISO cannot wipe a drive by itself.

$script:OscdimgPaths = @(
    'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe',
    'C:\Program Files\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
)
$script:IsoMinFreeGB = 35

# Microsoft's published generic install keys. They only pick the edition; your digital licence activates it.
$script:GenericKeys = @{
    'Windows 11 Home'   = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
    'Windows 11 Home N' = '4CPRK-NM3K3-X6XXQ-RXX86-WXCHW'
    'Windows 11 Pro'    = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
    'Windows 11 Pro N'  = '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT'
}

function Get-OscdimgPath {
    foreach ($p in $script:OscdimgPaths) { if (Test-Path -LiteralPath $p) { return $p } }
    $local = Join-Path $script:Root 'tools\oscdimg.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    return $null
}

# Installs only the Deployment Tools part of the Windows ADK (contains oscdimg). Returns a done-marker path.
function Start-AdkInstallJob {
    $jobs = Join-Path $script:DataDir 'jobs'
    if (-not (Test-Path $jobs)) { New-Item -ItemType Directory -Path $jobs -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ps1 = Join-Path $jobs "adk-$stamp.ps1"
    $done = Join-Path $jobs "adk-$stamp.done"
    $script = @"
`$Host.UI.RawUI.WindowTitle = 'DebloatTool - Installing Windows ADK Deployment Tools'
Write-Host 'Installing the Deployment Tools part of the Windows ADK (needed to create ISO files)...' -ForegroundColor Cyan
winget install --id Microsoft.WindowsADK --exact --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity --override '/features OptionId.DeploymentTools /quiet /norestart /ceip off'
Write-Host ("winget finished with code {0}" -f `$LASTEXITCODE)
Set-Content -LiteralPath '$done' -Value 'done'
Read-Host 'Finished. Press Enter to close this window'
"@
    [IO.File]::WriteAllText($ps1, $script, (New-Object System.Text.UTF8Encoding($true)))
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ps1`""
    $done
}

function Get-InstallImagePath([string]$Root) {
    foreach ($n in 'install.wim', 'install.esd') {
        $p = Join-Path $Root "sources\$n"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "This ISO has no sources\install.wim or install.esd - it does not look like a Windows install ISO."
}

# Lists the editions in an ISO. Needs admin (DISM).
function Get-IsoEditions([string]$IsoPath) {
    $img = Mount-DiskImage -ImagePath $IsoPath -Access ReadOnly -StorageType ISO -PassThru -ErrorAction Stop
    try {
        $letter = ($img | Get-Volume).DriveLetter
        $src = Get-InstallImagePath "$($letter):\"
        foreach ($e in (Get-WindowsImage -ImagePath $src -ErrorAction Stop)) {
            $d = Get-WindowsImage -ImagePath $src -Index $e.ImageIndex -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Index    = $e.ImageIndex
                Name     = $e.ImageName
                SizeGB   = [math]::Round($e.ImageSize / 1GB, 1)
                Language = $(if ($d -and $d.Languages) { @($d.Languages)[0] } else { 'en-US' })
                Build    = $(if ($d) { "$($d.Version)" } else { '' })
            }
        }
    } finally {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
    }
}

function Test-IsoSettings($S) {
    $problems = @()
    if (-not $S.IsoPath -or -not (Test-Path -LiteralPath $S.IsoPath)) { $problems += 'Choose a Windows ISO file.' }
    if (-not $S.EditionIndex) { $problems += 'Choose a Windows edition.' }
    if (-not $S.OutputDir) { $problems += 'Choose an output folder.' }
    elseif ($S.OutputDir -match '\s') { $problems += 'The output folder path cannot contain spaces (the ISO tool does not support them).' }
    elseif ($S.OutputDir.StartsWith($script:Root, [StringComparison]::OrdinalIgnoreCase)) { $problems += 'Pick an output folder outside the DebloatTool folder.' }
    else {
        $drive = [IO.Path]::GetPathRoot($S.OutputDir)
        $free = (Get-PSDrive -Name $drive.Substring(0, 1) -ErrorAction SilentlyContinue).Free
        if ($free -and $free -lt ($script:IsoMinFreeGB * 1GB)) { $problems += "Drive $drive needs at least $($script:IsoMinFreeGB) GB free (has $([math]::Round($free / 1GB)) GB)." }
    }
    if ($S.Unattend) {
        if ($S.UserName -notmatch '^[A-Za-z0-9._-]{1,20}$') { $problems += 'Account name: 1-20 letters, numbers, dots, dashes or underscores.' }
        elseif ($S.UserName -in 'Administrator', 'Guest', 'DefaultAccount') { $problems += "'$($S.UserName)' is a reserved Windows account name." }
        if ($S.ComputerName -notmatch '^[A-Za-z0-9-]{1,15}$' -or $S.ComputerName -match '^\d+$') { $problems += 'Computer name: 1-15 letters, numbers or dashes, not only numbers.' }
    }
    if (-not (Get-OscdimgPath)) { $problems += 'The ISO tool (oscdimg from the Windows ADK) is not installed yet.' }
    $problems
}

function ConvertTo-UnattendPassword([string]$Password) {
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Password + 'Password'))
}

function New-UnattendXml($S) {
    $x = { param($v) [Security.SecurityElement]::Escape([string]$v) }
    $arch = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    $key = $script:GenericKeys[$S.EditionName]
    $keyXml = ''
    if ($key) { $keyXml = "<ProductKey><Key>$key</Key><WillShowUI>OnError</WillShowUI></ProductKey>" }
    if ($S.Password) {
        $pw = "<Password><Value>$(ConvertTo-UnattendPassword $S.Password)</Value><PlainText>false</PlainText></Password>"
    } else {
        $pw = '<Password><Value></Value><PlainText>true</PlainText></Password>'
    }
    $user = & $x $S.UserName
    $firstLogon = ''
    if ($S.FirstBoot) {
        $firstLogon = @"
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\DebloatTool\setup\FirstLogon.ps1</CommandLine>
          <Description>DebloatTool first sign-in setup</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
"@
    }
    @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by DebloatTool. Disk selection is intentionally left manual. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" $arch>
      <SetupUILanguage><UILanguage>$(& $x $S.Language)</UILanguage></SetupUILanguage>
      <InputLocale>$(& $x $S.InputLocale)</InputLocale>
      <SystemLocale>$(& $x $S.Locale)</SystemLocale>
      <UILanguage>$(& $x $S.Language)</UILanguage>
      <UserLocale>$(& $x $S.Locale)</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" $arch>
      <UserData>
        $keyXml
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $arch>
      <ComputerName>$(& $x $S.ComputerName)</ComputerName>
      <TimeZone>$(& $x $S.TimeZone)</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $arch>
      <InputLocale>$(& $x $S.InputLocale)</InputLocale>
      <SystemLocale>$(& $x $S.Locale)</SystemLocale>
      <UILanguage>$(& $x $S.Language)</UILanguage>
      <UserLocale>$(& $x $S.Locale)</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $arch>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$user</Name>
            <DisplayName>$user</DisplayName>
            <Group>Administrators</Group>
            $pw
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Username>$user</Username>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        $pw
      </AutoLogon>
$firstLogon    </component>
  </settings>
</unattend>
"@
}

# Turns the chosen bundles into the app lists the first-boot script installs.
function Get-FirstBootApps([string[]]$BundleNames) {
    $keys = @()
    foreach ($n in $BundleNames) {
        $b = $script:InstallBundles | Where-Object { $_.name -eq $n } | Select-Object -First 1
        if ($b) { $keys += @($b.apps) }
    }
    $keys = @($keys | Select-Object -Unique)
    $apps = @(); $urls = @()
    foreach ($a in @($script:InstallCatalog.apps)) {
        if ($keys -notcontains (Get-InstallKey $a)) { continue }
        if ($a.id) { $apps += [pscustomobject]@{ id = $a.id; name = $a.name; noAdmin = [bool]$a.noAdmin } }
        elseif ($a.url) { $urls += [pscustomobject]@{ name = $a.name; url = $a.url } }
    }
    [pscustomobject]@{ apps = $apps; urls = $urls }
}

function Write-Step([string]$Text) {
    $script:IsoStep++
    Write-Host ''
    Write-Host ("[{0:HH:mm:ss}] Step {1}: {2}" -f (Get-Date), $script:IsoStep, $Text) -ForegroundColor Cyan
}

function Invoke-Robocopy([string]$From, [string]$To, [string[]]$Extra = @()) {
    $rcArgs = @($From, $To, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') + $Extra
    & robocopy.exe @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying files from $From failed (robocopy code $LASTEXITCODE)." }
}

function Set-OfflineRegistry([string]$Mount, $S) {
    $hives = @()
    try {
        & reg.exe load 'HKLM\DBT_DEFAULT' (Join-Path $Mount 'Users\Default\NTUSER.DAT') | Out-Null
        if ($LASTEXITCODE -eq 0) { $hives += 'HKLM\DBT_DEFAULT' }
        & reg.exe load 'HKLM\DBT_SOFTWARE' (Join-Path $Mount 'Windows\System32\config\SOFTWARE') | Out-Null
        if ($LASTEXITCODE -eq 0) { $hives += 'HKLM\DBT_SOFTWARE' }
        & reg.exe load 'HKLM\DBT_SYSTEM' (Join-Path $Mount 'Windows\System32\config\SYSTEM') | Out-Null
        if ($LASTEXITCODE -eq 0) { $hives += 'HKLM\DBT_SYSTEM' }

        # Stop promoted apps installing themselves during the first sign-in (before DebloatTool runs).
        $cdm = 'HKLM\DBT_DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        foreach ($v in 'SilentInstalledAppsEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled',
                       'SubscribedContent-338388Enabled', 'SystemPaneSuggestionsEnabled', 'SubscribedContent-310093Enabled') {
            & reg.exe add $cdm /v $v /t REG_DWORD /d 0 /f | Out-Null
        }
        & reg.exe add 'HKLM\DBT_SOFTWARE\Policies\Microsoft\Windows\CloudContent' /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f | Out-Null
        if ($S.PreventEncryption) {
            & reg.exe add 'HKLM\DBT_SYSTEM\ControlSet001\Control\BitLocker' /v PreventDeviceEncryption /t REG_DWORD /d 1 /f | Out-Null
        }
    } finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        foreach ($h in $hives) {
            for ($i = 0; $i -lt 5; $i++) {
                & reg.exe unload $h 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { break }
                Start-Sleep -Seconds 2
            }
        }
    }
}

function Copy-FirstBootFiles([string]$Mount, $S) {
    $dest = Join-Path $Mount 'DebloatTool'
    Invoke-Robocopy $script:Root $dest @('/XD', (Join-Path $script:Root 'tests'), (Join-Path $script:Root '.git'))
    $plan = Get-FirstBootApps @($S.Bundles)
    $settings = [pscustomobject]@{
        preset  = $S.Preset
        apps    = @($plan.apps)
        urls    = @($plan.urls)
        builtAt = (Get-Date).ToString('o')
    }
    $json = ConvertTo-Json -InputObject $settings -Depth 5
    [IO.File]::WriteAllText((Join-Path $dest 'setup\settings.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("  First sign-in: preset '{0}', {1} app(s) to install, {2} download page(s) to open" -f $(if ($S.Preset) { $S.Preset } else { 'none' }), $plan.apps.Count, $plan.urls.Count)
}

function Invoke-IsoBuild($S) {
    $script:IsoStep = 0
    $oscdimg = Get-OscdimgPath
    if (-not $oscdimg) { throw 'oscdimg.exe (Windows ADK Deployment Tools) is not installed.' }

    $work = Join-Path $S.OutputDir 'work'
    $isoDir = Join-Path $work 'iso'
    $mount = Join-Path $work 'mount'
    $drivers = Join-Path $work 'drivers'
    $wim = Join-Path $work 'install.wim'
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $safeEdition = ($S.EditionName -replace '[^A-Za-z0-9]+', '-').Trim('-')
    $outIso = Join-Path $S.OutputDir "$safeEdition-DebloatTool-$stamp.iso"

    Write-Step 'Preparing a clean work folder'
    if (Test-Path -LiteralPath $mount) {
        Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mount } | ForEach-Object { Dismount-WindowsImage -Path $mount -Discard | Out-Null }
    }
    Clear-WindowsCorruptMountPoint -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Path $isoDir, $mount -Force | Out-Null

    Write-Step 'Copying Windows setup files from the ISO'
    $img = Mount-DiskImage -ImagePath $S.IsoPath -Access ReadOnly -StorageType ISO -PassThru
    try {
        $letter = ($img | Get-Volume).DriveLetter
        Invoke-Robocopy "$($letter):\" $isoDir
    } finally { Dismount-DiskImage -ImagePath $S.IsoPath | Out-Null }
    Get-ChildItem -LiteralPath $isoDir -Recurse -File | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }

    Write-Step "Extracting $($S.EditionName)"
    $src = Get-InstallImagePath $isoDir
    Export-WindowsImage -SourceImagePath $src -SourceIndex $S.EditionIndex -DestinationImagePath $wim -CompressionType max | Out-Null
    Remove-Item -LiteralPath $src -Force

    Write-Step 'Opening the Windows image (takes a few minutes)'
    Mount-WindowsImage -ImagePath $wim -Index 1 -Path $mount | Out-Null
    $saved = $false
    try {
        if ($S.RemoveApps) {
            Write-Step 'Removing bloat apps from the image'
            $patterns = @($script:AppCatalog.apps | Where-Object { $_.group -eq 'Recommended' } | ForEach-Object { $_.name })
            foreach ($p in (Get-AppxProvisionedPackage -Path $mount)) {
                if (@($patterns | Where-Object { $p.DisplayName -like $_ }).Count) {
                    try { Remove-AppxProvisionedPackage -Path $mount -PackageName $p.PackageName -ErrorAction Stop | Out-Null; Write-Host "  removed $($p.DisplayName)" }
                    catch { Write-Host "  could not remove $($p.DisplayName): $($_.Exception.Message)" -ForegroundColor Yellow }
                }
            }
        }

        if ($S.InjectDrivers) {
            Write-Step "Exporting this PC's drivers"
            New-Item -ItemType Directory -Path $drivers -Force | Out-Null
            $exported = @(Export-WindowsDriver -Online -Destination $drivers)
            # Keep only drivers that a device in this PC is using right now (skips old versions),
            # and leave graphics drivers out unless asked: they are huge and NVIDIA App / Windows Update install newer ones.
            $inUse = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.InfName -like 'oem*.inf' } | ForEach-Object { $_.InfName.ToLower() } | Select-Object -Unique)
            $gpuProviders = @($exported | Where-Object { $_.ClassName -eq 'Display' } | ForEach-Object { $_.ProviderName } | Select-Object -Unique)
            $keep = @{}
            foreach ($d in $exported) {
                if ($inUse -notcontains ([string]$d.Driver).ToLower()) { continue }
                $isGraphics = ($d.ClassName -eq 'Display') -or ($d.ClassName -eq 'SoftwareComponent' -and $gpuProviders -contains $d.ProviderName)
                if ($isGraphics -and -not $S.IncludeGraphics) { continue }
                $keep[(Split-Path (Split-Path $d.OriginalFileName -Parent) -Leaf)] = $true
            }
            foreach ($dir in (Get-ChildItem -LiteralPath $drivers -Directory)) {
                if (-not $keep.ContainsKey($dir.Name)) { Remove-Item -LiteralPath $dir.FullName -Recurse -Force }
            }
            $mb = [math]::Round(((Get-ChildItem -LiteralPath $drivers -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB)
            Write-Host "  keeping $($keep.Count) of $($exported.Count) driver(s) ($mb MB)$(if (-not $S.IncludeGraphics) { ', graphics drivers left out' })"
            Write-Step 'Adding drivers to the image'
            $added = @(Add-WindowsDriver -Path $mount -Driver $drivers -Recurse -ErrorAction Continue)
            Write-Host "  added $($added.Count) driver(s)"
        }

        Write-Step 'Applying first-sign-in protections to the image'
        Set-OfflineRegistry $mount $S

        if ($S.FirstBoot) {
            Write-Step 'Adding DebloatTool and your first-boot setup'
            Copy-FirstBootFiles $mount $S
        }

        Write-Step 'Saving the image (takes a few minutes)'
        Dismount-WindowsImage -Path $mount -Save | Out-Null
        $saved = $true
    } finally {
        if (-not $saved) {
            Write-Host 'Discarding changes to the image...' -ForegroundColor Yellow
            Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null
        }
    }

    Write-Step 'Compressing the image'
    Export-WindowsImage -SourceImagePath $wim -SourceIndex 1 -DestinationImagePath (Join-Path $isoDir 'sources\install.wim') -CompressionType max | Out-Null

    if ($S.Unattend) {
        Write-Step 'Writing the automatic setup answers (autounattend.xml)'
        $xml = New-UnattendXml $S
        [xml]$xml | Out-Null   # throws if the XML is malformed
        [IO.File]::WriteAllText((Join-Path $isoDir 'autounattend.xml'), $xml, (New-Object System.Text.UTF8Encoding($false)))
    }

    Write-Step 'Creating the ISO file'
    $etfs = Join-Path $isoDir 'boot\etfsboot.com'
    $efi = Join-Path $isoDir 'efi\microsoft\boot\efisys.bin'
    & $oscdimg -m -o -u2 -udfver102 "-bootdata:2#p0,e,b$etfs#pEF,e,b$efi" '-lDBT_WIN11' $isoDir $outIso | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outIso)) { throw "oscdimg failed (code $LASTEXITCODE)." }

    Write-Step 'Cleaning up the work folder'
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

    $size = [math]::Round((Get-Item -LiteralPath $outIso).Length / 1GB, 2)
    Write-Host ''
    Write-Host "ISO ready: $outIso ($size GB)" -ForegroundColor Green
    $outIso
}
