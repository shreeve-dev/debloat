# Engine.ps1
# Loads the catalogs, checks tweak status, applies tweaks and undoes them exactly.
# Before any change, the current value is saved to a journal so undo restores what was really there.

$script:DataDir     = Join-Path $env:LOCALAPPDATA 'DebloatTool'
$script:JournalPath = Join-Path $script:DataDir 'journal.json'
$script:LogSink     = $null
$script:RiskRank    = @{ safe = 0; moderate = 1; advanced = 2 }

function Write-Log([string]$Message) {
    if ($script:LogSink) { & $script:LogSink $Message } else { Write-Host $Message }
}

#region Config ---------------------------------------------------------------

function Import-DebloatConfig {
    param([string]$ConfigDir = (Join-Path $script:Root 'config'))
    $t = Get-Content (Join-Path $ConfigDir 'tweaks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Categories = @($t.categories)
    $script:Catalog    = @($t.tweaks)
    $script:Actions    = @($t.actions)
    $script:Presets    = @((Get-Content (Join-Path $ConfigDir 'presets.json') -Raw -Encoding UTF8 | ConvertFrom-Json).presets)
    $script:AppCatalog = Get-Content (Join-Path $ConfigDir 'apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-TweakById([string]$Id) {
    $script:Catalog | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function Get-Preset([string]$Name) {
    $script:Presets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

# Returns the tweaks a preset selects: id patterns (wildcards allowed), minus excludes, capped by maxRisk.
function Resolve-PresetTweaks($Preset) {
    $max = if ($Preset.maxRisk) { $script:RiskRank[$Preset.maxRisk] } else { 2 }
    foreach ($t in $script:Catalog) {
        if ($script:RiskRank[$t.risk] -gt $max) { continue }
        $excluded = $false
        foreach ($x in @($Preset.exclude)) { if ($x -and $t.id -like $x) { $excluded = $true } }
        if ($excluded) { continue }
        foreach ($pattern in @($Preset.tweaks)) { if ($t.id -like $pattern) { $t; break } }
    }
}

function Get-Items($Object, [string]$Property) {
    if ($Object.PSObject.Properties[$Property]) { @($Object.$Property | Where-Object { $null -ne $_ }) } else { @() }
}

#endregion
#region Registry -------------------------------------------------------------

$script:HiveMap = @{
    HKLM = 'LocalMachine'; HKEY_LOCAL_MACHINE = 'LocalMachine'
    HKCU = 'CurrentUser';  HKEY_CURRENT_USER  = 'CurrentUser'
    HKCR = 'ClassesRoot';  HKEY_CLASSES_ROOT  = 'ClassesRoot'
    HKU  = 'Users';        HKEY_USERS         = 'Users'
}

function Split-RegPath([string]$Path) {
    $p = $Path -replace '^Registry::', ''
    $i = $p.IndexOf('\')
    if ($i -lt 0) { $hive = $p; $sub = '' } else { $hive = $p.Substring(0, $i); $sub = $p.Substring($i + 1) }
    $hive = $hive.TrimEnd(':')
    if (-not $script:HiveMap.ContainsKey($hive)) { throw "Unknown registry hive in '$Path'" }
    return $script:HiveMap[$hive], $sub.TrimEnd('\')
}

function Open-RegKey {
    param([string]$Path, [switch]$Writable, [switch]$Create)
    $hive, $sub = Split-RegPath $Path
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$hive, [Microsoft.Win32.RegistryView]::Registry64)
    if ($Create) { return $base.CreateSubKey($sub, $true) }
    return $base.OpenSubKey($sub, [bool]$Writable)
}

function Test-RegKey([string]$Path) {
    try { $k = Open-RegKey $Path } catch { return $false }
    if ($k) { $k.Close(); return $true }
    return $false
}

function Get-ValueName([string]$Name) { if ($Name -eq '(Default)') { '' } else { $Name } }

# Registry data -> JSON-friendly form (DWORD/QWORD unsigned, binary as hex text).
function ConvertTo-PortableValue($Value, [string]$Kind) {
    switch ($Kind) {
        'DWord'       { return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Value), 0) }
        'QWord'       { return [BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$Value), 0) }
        'Binary'      { return ((@($Value) | ForEach-Object { ([byte]$_).ToString('X2') }) -join ' ') }
        'MultiString' { return ,([string[]]@($Value)) }
        default       { return [string]$Value }
    }
}

# JSON-friendly form -> what RegistryKey.SetValue expects.
function ConvertFrom-PortableValue($Value, [string]$Kind) {
    switch ($Kind) {
        'DWord'  { return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Value), 0) }
        'QWord'  { return [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$Value), 0) }
        'Binary' {
            $hex = ([string]$Value) -replace '[^0-9A-Fa-f]', ''
            $bytes = New-Object byte[] ($hex.Length / 2)
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
            return ,$bytes
        }
        'MultiString' { return ,([string[]]@($Value)) }
        default       { return [string]$Value }
    }
}

function Get-RegValue([string]$Path, [string]$Name) {
    $result = [pscustomobject]@{ KeyExists = $false; Exists = $false; Kind = $null; Value = $null }
    try { $k = Open-RegKey $Path } catch { return $result }
    if (-not $k) { return $result }
    try {
        $result.KeyExists = $true
        $n = Get-ValueName $Name
        if ($k.GetValueNames() -notcontains $n) { return $result }
        $kind = $k.GetValueKind($n).ToString()
        $raw  = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $result.Exists = $true
        $result.Kind   = $kind
        $result.Value  = ConvertTo-PortableValue $raw $kind
        return $result
    } finally { $k.Close() }
}

function Set-RegValue([string]$Path, [string]$Name, [string]$Kind, $Value) {
    $k = Open-RegKey $Path -Create
    if (-not $k) { throw "Could not open or create $Path" }
    try {
        $data = ConvertFrom-PortableValue $Value $Kind
        $k.SetValue((Get-ValueName $Name), $data, [Microsoft.Win32.RegistryValueKind]$Kind)
    } finally { $k.Close() }
}

function Remove-RegValue([string]$Path, [string]$Name) {
    $k = Open-RegKey $Path -Writable
    if (-not $k) { return }
    try { $k.DeleteValue((Get-ValueName $Name), $false) } finally { $k.Close() }
}

# The highest key in $Path that does not exist yet (so undo can remove keys we created).
function Get-MissingAncestor([string]$Path) {
    $first = ($Path -split '\\')[0]
    $null, $sub = Split-RegPath $Path
    $parts = $sub -split '\\'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $p = $first + '\' + ($parts[0..$i] -join '\')
        if (-not (Test-RegKey $p)) { return $p }
    }
    return $null
}

# Deletes empty keys from $Leaf up to and including $Top. Stops at the first non-empty key.
function Remove-EmptyKeys([string]$Leaf, [string]$Top) {
    $current = $Leaf
    while ($current) {
        $k = $null
        try { $k = Open-RegKey $current } catch { }
        if ($k) {
            $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0)
            $k.Close()
            if (-not $empty) { return }
            $i = $current.LastIndexOf('\')
            $parent = Open-RegKey $current.Substring(0, $i) -Writable
            if ($parent) { try { $parent.DeleteSubKey($current.Substring($i + 1), $false) } finally { $parent.Close() } }
        }
        if ($current -eq $Top) { return }
        $i = $current.LastIndexOf('\')
        if ($i -lt 0) { return }
        $current = $current.Substring(0, $i)
    }
}

function Test-RegValueMatch($Current, $Item) {
    if ($Item.delete) { return -not $Current.Exists }
    # "defaultMatches": Windows already behaves like the target when the value is missing.
    if (-not $Current.Exists) { return [bool]$Item.defaultMatches }
    # A value with the wrong type (e.g. a number where Windows expects text) counts as not applied,
    # because Windows may ignore it. Applying rewrites it with the right type.
    if ($Current.Kind -ne $Item.type) { return $false }
    $target = ConvertTo-PortableValue (ConvertFrom-PortableValue $Item.value $Item.type) $Item.type
    switch ($Item.type) {
        'MultiString' { return ((@($Current.Value) -join "`n") -ceq (@($target) -join "`n")) }
        'DWord'       { return [uint64]$Current.Value -eq [uint64]$target }
        'QWord'       { return [uint64]$Current.Value -eq [uint64]$target }
        default       { return [string]$Current.Value -eq [string]$target }
    }
}

function Format-PortableValue($Value, [string]$Kind) {
    switch ($Kind) {
        'DWord'       { if ([uint64]$Value -gt 65535) { return ('0x{0:X8}' -f [uint64]$Value) } else { return [string]$Value } }
        'QWord'       { return [string]$Value }
        'Binary'      { return "hex($Value)" }
        'MultiString' { return '"' + (@($Value) -join '", "') + '"' }
        default       { return '"' + $Value + '"' }
    }
}

function Format-RegState($State) {
    if (-not $State.Exists) { return '(not set)' }
    Format-PortableValue $State.Value $State.Kind
}

#endregion
#region Services and scheduled tasks ----------------------------------------

function Get-ServiceStartup([string]$Name) {
    $key = "HKLM\SYSTEM\CurrentControlSet\Services\$Name"
    $v = Get-RegValue $key 'Start'
    if (-not $v.Exists) { return $null }
    switch ([int]$v.Value) {
        0 { 'Boot' }
        1 { 'System' }
        2 {
            $d = Get-RegValue $key 'DelayedAutostart'
            if ($d.Exists -and [int]$d.Value -eq 1) { 'AutomaticDelayed' } else { 'Automatic' }
        }
        3 { 'Manual' }
        4 { 'Disabled' }
        default { 'Unknown' }
    }
}

function Set-ServiceStartup([string]$Name, [string]$Startup) {
    $map = @{ Boot = 'boot'; System = 'system'; Automatic = 'auto'; AutomaticDelayed = 'delayed-auto'; Manual = 'demand'; Disabled = 'disabled' }
    if (-not $map.ContainsKey($Startup)) { throw "Unknown startup type '$Startup'" }
    $out = & sc.exe config $Name start= $map[$Startup]
    if ($LASTEXITCODE -ne 0) { throw "sc.exe could not change $Name ($(($out | Where-Object { $_ }) -join ' '))" }
}

function Get-TaskState($Task) {
    $t = Get-ScheduledTask -TaskPath $Task.path -TaskName $Task.name -ErrorAction SilentlyContinue
    if ($t) { [string]$t.State }
}

function Test-TaskStateMatch([string]$Current, [string]$Target) {
    if ($Target -eq 'Disabled') { return $Current -eq 'Disabled' }
    return $Current -ne 'Disabled'
}

function Set-TaskState($Task, [string]$State) {
    if ($State -eq 'Disabled') {
        Disable-ScheduledTask -TaskPath $Task.path -TaskName $Task.name -ErrorAction Stop | Out-Null
    } else {
        Enable-ScheduledTask -TaskPath $Task.path -TaskName $Task.name -ErrorAction Stop | Out-Null
    }
}

#endregion
#region Scripts --------------------------------------------------------------

function Join-Code($Code) { if ($Code -is [array]) { $Code -join "`n" } else { [string]$Code } }

function Invoke-TweakScript($Code, $Snapshot) {
    $sb = [scriptblock]::Create("param(`$Snapshot)`n" + (Join-Code $Code))
    & $sb $Snapshot
}

#endregion
#region Status and plan ------------------------------------------------------

function Get-TweakStatus($Tweak) {
    $checks = 0; $ok = 0
    foreach ($r in (Get-Items $Tweak 'registry')) {
        $checks++
        if (Test-RegValueMatch (Get-RegValue $r.path $r.name) $r) { $ok++ }
    }
    foreach ($s in (Get-Items $Tweak 'services')) {
        $cur = Get-ServiceStartup $s.name
        if ($null -eq $cur) { continue }
        $checks++
        if ($cur -eq $s.startup) { $ok++ }
    }
    foreach ($t in (Get-Items $Tweak 'tasks')) {
        $cur = Get-TaskState $t
        if (-not $cur) { continue }
        $checks++
        if (Test-TaskStateMatch $cur $t.state) { $ok++ }
    }
    if ($Tweak.script -and $Tweak.script.detect) {
        $checks++
        try { if ([bool](Invoke-TweakScript $Tweak.script.detect | Select-Object -Last 1)) { $ok++ } } catch { }
    }
    $state = if ($checks -eq 0) { 'Unknown' } elseif ($ok -eq $checks) { 'Applied' } elseif ($ok -eq 0) { 'NotApplied' } else { 'Partial' }
    [pscustomobject]@{ State = $state; Matched = $ok; Total = $checks }
}

# Lists only the changes that would actually happen for one tweak.
function Get-TweakPlan($Tweak) {
    foreach ($r in (Get-Items $Tweak 'registry')) {
        $cur = Get-RegValue $r.path $r.name
        if (Test-RegValueMatch $cur $r) { continue }
        $to = if ($r.delete) { '(removed)' } else { Format-PortableValue (ConvertTo-PortableValue (ConvertFrom-PortableValue $r.value $r.type) $r.type) $r.type }
        [pscustomobject]@{ Kind = 'Registry'; Target = "$($r.path)\$($r.name)"; From = (Format-RegState $cur); To = $to }
    }
    foreach ($s in (Get-Items $Tweak 'services')) {
        $cur = Get-ServiceStartup $s.name
        if ($null -eq $cur -or $cur -eq $s.startup) { continue }
        [pscustomobject]@{ Kind = 'Service'; Target = $s.name; From = $cur; To = $s.startup }
    }
    foreach ($t in (Get-Items $Tweak 'tasks')) {
        $cur = Get-TaskState $t
        if (-not $cur -or (Test-TaskStateMatch $cur $t.state)) { continue }
        [pscustomobject]@{ Kind = 'Task'; Target = "$($t.path)$($t.name)"; From = $cur; To = $t.state }
    }
    if ($Tweak.script -and $Tweak.script.apply) {
        $done = $false
        if ($Tweak.script.detect) { try { $done = [bool](Invoke-TweakScript $Tweak.script.detect | Select-Object -Last 1) } catch { } }
        if (-not $done) { [pscustomobject]@{ Kind = 'Script'; Target = $Tweak.script.describe; From = ''; To = '' } }
    }
}

$script:AfterText = @{ explorer = 'restarting File Explorer'; signout = 'signing out and back in'; reboot = 'restarting the PC' }

function Get-PlanText {
    param([object[]]$Tweaks, [object[]]$Apps, [switch]$Deprovision)
    $arrow = [string][char]0x2192
    $body = New-Object System.Text.StringBuilder
    $skipped = New-Object System.Collections.Generic.List[string]
    $count = 0
    foreach ($t in @($Tweaks)) {
        if (-not $t) { continue }
        $plan = @(Get-TweakPlan $t)
        if ($plan.Count -eq 0) { $skipped.Add($t.name); continue }
        $count++
        [void]$body.AppendLine(('[{0}] {1}' -f $t.risk.ToUpper(), $t.name))
        foreach ($c in $plan) {
            if ($c.Kind -eq 'Script') {
                [void]$body.AppendLine("    Run       $($c.Target)")
            } else {
                [void]$body.AppendLine(('    {0,-9} {1}' -f $c.Kind, $c.Target))
                [void]$body.AppendLine(('              {0}  {1}  {2}' -f $c.From, $arrow, $c.To))
            }
        }
        $after = @(Get-Items $t 'after' | ForEach-Object { $script:AfterText[$_] })
        if ($after) { [void]$body.AppendLine("    Takes effect after $($after -join ' / ')") }
        [void]$body.AppendLine()
    }
    $out = New-Object System.Text.StringBuilder
    [void]$out.AppendLine("TWEAKS TO APPLY ($count)")
    [void]$out.AppendLine(('=' * 40))
    [void]$out.Append($body.ToString())
    if ($count -eq 0) { [void]$out.AppendLine('    (none)'); [void]$out.AppendLine() }
    $apps = @($Apps | Where-Object { $_ })
    if ($apps.Count) {
        $suffix = if ($Deprovision) { '  - also removed for new user accounts' } else { '  - current user only' }
        [void]$out.AppendLine("APPS TO REMOVE ($($apps.Count))$suffix")
        [void]$out.AppendLine(('=' * 40))
        foreach ($a in $apps) { [void]$out.AppendLine(('    {0}  ({1})' -f $a.Label, $a.Name)) }
        [void]$out.AppendLine()
    }
    if ($skipped.Count) {
        [void]$out.AppendLine("ALREADY APPLIED - SKIPPED ($($skipped.Count))")
        [void]$out.AppendLine(('=' * 40))
        foreach ($s in $skipped) { [void]$out.AppendLine("    $s") }
    }
    $out.ToString()
}

#endregion
#region Journal --------------------------------------------------------------

function Get-Journal {
    if (-not (Test-Path $script:JournalPath)) { return }
    $raw = Get-Content $script:JournalPath -Raw -Encoding UTF8
    if (-not $raw.Trim()) { return }
    @($raw | ConvertFrom-Json) | ForEach-Object { $_ }
}

function Save-Journal([object[]]$Entries) {
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 12
    [System.IO.File]::WriteAllText($script:JournalPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-JournalEntry($Entry) {
    $all = @(Get-Journal) + $Entry
    Save-Journal $all
}

function New-JournalEntry([string]$TweakId, [string]$Name, [object[]]$Changes, [object[]]$Errors) {
    [pscustomobject]@{
        id      = [guid]::NewGuid().ToString()
        time    = (Get-Date).ToString('o')
        tweakId = $TweakId
        name    = $Name
        changes = @($Changes)
        errors  = @($Errors)
        undone  = $false
        undoneAt = $null
    }
}

#endregion
#region Apply and undo -------------------------------------------------------

function Invoke-Tweak($Tweak) {
    $changes = New-Object System.Collections.Generic.List[object]
    $errors  = New-Object System.Collections.Generic.List[string]

    foreach ($r in (Get-Items $Tweak 'registry')) {
        try {
            $cur = Get-RegValue $r.path $r.name
            if (Test-RegValueMatch $cur $r) { continue }
            $changes.Add([pscustomobject]@{
                kind = 'registry'; path = $r.path; name = $r.name
                existed = $cur.Exists; type = $cur.Kind; value = $cur.Value
                createdFrom = (Get-MissingAncestor $r.path)
            })
            if ($r.delete) { Remove-RegValue $r.path $r.name } else { Set-RegValue $r.path $r.name $r.type $r.value }
        } catch { $errors.Add("Registry $($r.path)\$($r.name): $($_.Exception.Message)") }
    }

    foreach ($s in (Get-Items $Tweak 'services')) {
        try {
            $cur = Get-ServiceStartup $s.name
            if ($null -eq $cur -or $cur -eq $s.startup) { continue }
            $changes.Add([pscustomobject]@{ kind = 'service'; name = $s.name; prior = $cur })
            Set-ServiceStartup $s.name $s.startup
            if ($s.startup -eq 'Disabled' -and $s.stop) { Stop-Service -Name $s.name -Force -ErrorAction SilentlyContinue }
        } catch { $errors.Add("Service $($s.name): $($_.Exception.Message)") }
    }

    foreach ($t in (Get-Items $Tweak 'tasks')) {
        try {
            $cur = Get-TaskState $t
            if (-not $cur -or (Test-TaskStateMatch $cur $t.state)) { continue }
            $changes.Add([pscustomobject]@{ kind = 'task'; path = $t.path; name = $t.name; prior = $(if ($cur -eq 'Disabled') { 'Disabled' } else { 'Enabled' }) })
            Set-TaskState $t $t.state
        } catch { $errors.Add("Task $($t.path)$($t.name): $($_.Exception.Message)") }
    }

    if ($Tweak.script -and $Tweak.script.apply) {
        try {
            $done = $false
            if ($Tweak.script.detect) { try { $done = [bool](Invoke-TweakScript $Tweak.script.detect | Select-Object -Last 1) } catch { } }
            if (-not $done) {
                $snap = $null
                if ($Tweak.script.snapshot) { $snap = [string](Invoke-TweakScript $Tweak.script.snapshot | Select-Object -Last 1) }
                $changes.Add([pscustomobject]@{ kind = 'script'; describe = $Tweak.script.describe; snapshot = $snap; undo = (Join-Code $Tweak.script.undo) })
                Invoke-TweakScript $Tweak.script.apply $snap | Out-Null
            }
        } catch { $errors.Add("Script: $($_.Exception.Message)") }
    }

    $entry = $null
    if ($changes.Count -or $errors.Count) {
        $entry = New-JournalEntry $Tweak.id $Tweak.name $changes.ToArray() $errors.ToArray()
        Add-JournalEntry $entry
    }
    [pscustomobject]@{ Changes = $changes.Count; Errors = $errors.ToArray(); Entry = $entry }
}

function Undo-Change($Change) {
    switch ($Change.kind) {
        'registry' {
            if ($Change.existed) {
                Set-RegValue $Change.path $Change.name $Change.type $Change.value
            } else {
                Remove-RegValue $Change.path $Change.name
                if ($Change.createdFrom) { Remove-EmptyKeys $Change.path $Change.createdFrom }
            }
        }
        'service' { Set-ServiceStartup $Change.name $Change.prior }
        'task'    { Set-TaskState $Change $Change.prior }
        'script'  { if ($Change.undo) { Invoke-TweakScript $Change.undo $Change.snapshot | Out-Null } }
        'appx'    { Restore-App $Change }
        'netadapter' { Set-NetAdapterConfig $Change.prior }
        default   { throw "Unknown change kind '$($Change.kind)'" }
    }
}

function Undo-JournalEntry([string]$Id) {
    $all = @(Get-Journal)
    $entry = $all | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $entry) { throw "No history entry with id $Id" }
    if ($entry.undone) { return @() }
    $errors = New-Object System.Collections.Generic.List[string]
    $list = @($entry.changes)
    [array]::Reverse($list)
    foreach ($c in $list) {
        try { Undo-Change $c } catch { $errors.Add("$($c.kind) $($c.path)$($c.name): $($_.Exception.Message)") }
    }
    $entry.undone = $true
    $entry.undoneAt = (Get-Date).ToString('o')
    Save-Journal $all
    $errors.ToArray()
}

#endregion
#region Safety and helpers ---------------------------------------------------

function New-SafetyRestorePoint {
    # Windows allows one restore point per 24 hours by default; lift that briefly, then put it back.
    $key  = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $name = 'SystemRestorePointCreationFrequency'
    $prev = Get-RegValue $key $name
    try {
        Set-RegValue $key $name 'DWord' 0
        Checkpoint-Computer -Description ("DebloatTool " + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
        return $true, 'Restore point created.'
    } catch {
        return $false, "Could not create a restore point: $($_.Exception.Message) System Protection may be turned off for drive C:."
    } finally {
        try { if ($prev.Exists) { Set-RegValue $key $name $prev.Kind $prev.Value } else { Remove-RegValue $key $name } } catch { }
    }
}

function Restart-Explorer {
    # Windows restarts the shell by itself (unelevated). Only start it if that did not happen.
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-Process explorer -ErrorAction SilentlyContinue) { return }
    }
    Start-Process explorer.exe
}

function Invoke-MaintenanceAction($Action) {
    $code = Join-Code $Action.script
    if ($Action.external) {
        $full = "`$Host.UI.RawUI.WindowTitle = 'DebloatTool - $($Action.name)'`n$code`nWrite-Host ''`nWrite-Host 'Done. You can close this window.' -ForegroundColor Green"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
        Start-Process powershell.exe -ArgumentList '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
        return "Started in a new window."
    }
    $out = Invoke-TweakScript $code $null
    (@($out) | ForEach-Object { [string]$_ }) -join "`n"
}

#endregion
