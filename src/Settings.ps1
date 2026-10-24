# Settings.ps1
# The Settings page: common Windows settings as simple choices, and network adapter setup
# (automatic or static IP, DNS servers). Every change is saved to History and can be undone.

#region Windows settings -----------------------------------------------------

function Import-SettingsCatalog {
    [CmdletBinding()]
    param([string]$ConfigDir = (Join-Path $script:Root 'config'))
    $cfg = Get-Content (Join-Path $ConfigDir 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:SettingsCategories = @($cfg.categories)
    $script:SettingsCatalog = @($cfg.settings)
}

# One option of a setting, shaped like a tweak so the engine can check, apply and undo it.
function ConvertTo-OptionTweak($Setting, $Option) {
    $t = [ordered]@{ id = "setting.$($Setting.id)"; name = "$($Setting.name): $($Option.label)" }
    foreach ($p in 'registry', 'script') { if ($Option.PSObject.Properties[$p]) { $t[$p] = $Option.$p } }
    if ($Setting.PSObject.Properties['after']) { $t['after'] = $Setting.after }
    [pscustomobject]$t
}

# The option that matches the PC right now, or $null when none does (a custom value).
function Get-SettingCurrent($Setting) {
    foreach ($o in @($Setting.options)) {
        if ((Get-TweakStatus (ConvertTo-OptionTweak $Setting $o)).State -eq 'Applied') { return $o }
    }
    $null
}

function Set-SettingOption($Setting, $Option) {
    Invoke-Tweak (ConvertTo-OptionTweak $Setting $Option)
}

#endregion
#region Network adapters -----------------------------------------------------

$script:DnsPresets = [ordered]@{
    'Cloudflare' = @('1.1.1.1', '1.0.0.1')
    'Google'     = @('8.8.8.8', '8.8.4.4')
    'Quad9'      = @('9.9.9.9', '149.112.112.112')
}

function Test-IPv4([string]$Text) {
    $Text = "$Text".Trim()
    if ($Text -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($o in $Text.Split('.')) { if ([int]$o -gt 255) { return $false } }
    $true
}

function ConvertTo-IPv4Number([string]$Ip) {
    $n = [uint32]0
    foreach ($o in $Ip.Trim().Split('.')) { $n = [uint32]($n * 256 + [int]$o) }
    $n
}

# Accepts "24", "/24" or "255.255.255.0". Returns the prefix length, or $null when invalid.
function ConvertTo-PrefixLength([string]$Text) {
    $Text = "$Text".Trim().TrimStart('/')
    if ($Text -match '^\d{1,2}$') { $p = [int]$Text; if ($p -ge 1 -and $p -le 32) { return $p } else { return $null } }
    if (-not (Test-IPv4 $Text)) { return $null }
    $bits = [Convert]::ToString([int64](ConvertTo-IPv4Number $Text), 2).PadLeft(32, '0')
    if ($bits -notmatch '^1+0*$') { return $null }
    $bits.TrimEnd('0').Length
}

function ConvertTo-SubnetMask([int]$Prefix) {
    $n = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $Prefix))
    (3, 2, 1, 0 | ForEach-Object { ($n -shr (8 * $_)) -band 255 }) -join '.'
}

# Problems with a target adapter config, in plain words. Empty when it's fine.
function Test-NetTarget($Config) {
    $errs = @()
    if (-not $Config.dhcp) {
        $ipOk = Test-IPv4 $Config.ip
        if (-not $ipOk) { $errs += "'$($Config.ip)' is not a valid IP address." }
        $prefix = $Config.prefix -as [int]
        if (-not $prefix -or $prefix -lt 1 -or $prefix -gt 32) { $errs += 'The subnet mask is not valid.' }
        if ($ipOk -and $prefix -ge 1 -and $prefix -le 30) {
            $ip = [int64](ConvertTo-IPv4Number $Config.ip)
            $size = [int64][math]::Pow(2, 32 - $prefix)
            $net = $ip - ($ip % $size)
            if ($ip -eq $net -or $ip -eq $net + $size - 1) { $errs += "$($Config.ip) is the network or broadcast address of that subnet. Pick another address." }
            if ($Config.gateway) {
                if (-not (Test-IPv4 $Config.gateway)) { $errs += "'$($Config.gateway)' is not a valid gateway address." }
                else {
                    $gw = [int64](ConvertTo-IPv4Number $Config.gateway)
                    if ($gw - ($gw % $size) -ne $net) { $errs += "The gateway $($Config.gateway) is not in the same subnet as $($Config.ip)." }
                    elseif ($gw -eq $ip) { $errs += 'The gateway cannot be the same address as this PC.' }
                }
            }
        }
        $first = [string]$Config.ip
        if ($ipOk -and ($first.StartsWith('127.') -or $first.StartsWith('169.254.') -or [int]$first.Split('.')[0] -ge 224 -or $first.StartsWith('0.'))) {
            $errs += "$($Config.ip) can't be used as a PC's address."
        }
    }
    if ($Config.dnsStatic) {
        $dns = @($Config.dns | Where-Object { "$_".Trim() })
        if (-not $dns.Count) { $errs += 'Enter at least one DNS server.' }
        foreach ($d in $dns) { if (-not (Test-IPv4 $d)) { $errs += "'$d' is not a valid DNS server address." } }
    }
    $errs
}

function Get-DnsPresetName([string[]]$Servers) {
    foreach ($k in $script:DnsPresets.Keys) {
        if ((@($Servers) -join ',') -eq ($script:DnsPresets[$k] -join ',')) { return $k }
    }
    $null
}

function Format-NetConfig($Config) {
    $ip = if ($Config.dhcp) { 'IP automatic (DHCP)' } elseif (-not $Config.ip) { 'IP static, no address set' } else {
        $s = "IP $($Config.ip)/$($Config.prefix)"
        if ($Config.gateway) { $s += ", gateway $($Config.gateway)" } else { $s += ', no gateway' }
        $s
    }
    $dns = if ($Config.dnsStatic) {
        $name = Get-DnsPresetName @($Config.dns)
        "DNS $(@($Config.dns) -join ', ')$(if ($name) { " ($name)" })"
    } else { 'DNS automatic' }
    "$ip; $dns"
}

# Physical adapters only (Ethernet and Wi-Fi), so VPN and virtual adapters are left alone.
function Get-NetAdapterList {
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Not Present' } | Sort-Object Name)
}

function Get-NetAdapterConfig($Adapter) {
    $i = $Adapter.ifIndex
    $ipif = Get-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $addr = Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    $gw = Get-NetRoute -InterfaceIndex $i -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1
    $dns = @((Get-DnsClientServerAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    # Windows keeps manually set DNS servers in NameServer; servers from DHCP live elsewhere.
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($Adapter.InterfaceGuid)"
    $ns = [string](Get-ItemProperty -Path $key -Name NameServer -ErrorAction SilentlyContinue).NameServer
    [pscustomobject]@{
        guid        = [string]$Adapter.InterfaceGuid
        name        = [string]$Adapter.Name
        description = [string]$Adapter.InterfaceDescription
        status      = [string]$Adapter.Status
        dhcp        = ([string]$ipif.Dhcp -eq 'Enabled')
        ip          = [string]$addr.IPAddress
        prefix      = $(if ($addr) { [int]$addr.PrefixLength } else { $null })
        gateway     = [string]$gw.NextHop
        dnsStatic   = [bool]$ns.Trim()
        dns         = @($dns)
    }
}

function Find-NetAdapter([string]$Guid) {
    $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $Guid } | Select-Object -First 1
    if (-not $a) { throw "The network adapter was not found (it may have been removed)." }
    $a
}

# Puts an adapter's IPv4 setup into the given state (same shape as Get-NetAdapterConfig).
function Set-NetAdapterConfig($Config) {
    $adapter = Find-NetAdapter $Config.guid
    $i = $adapter.ifIndex
    $now = Get-NetAdapterConfig $adapter
    $sameIp = if ($Config.dhcp) { $now.dhcp } else {
        -not $now.dhcp -and $now.ip -eq $Config.ip -and $now.prefix -eq [int]$Config.prefix -and $now.gateway -eq [string]$Config.gateway
    }
    # Leave the address alone when only DNS changes, so the connection never drops for nothing.
    if (-not $sameIp) {
        Get-NetRoute -InterfaceIndex $i -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        if ($Config.dhcp) {
            Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { [string]$_.PrefixOrigin -eq 'Manual' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
        } else {
            Set-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
            Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            $p = @{ InterfaceIndex = $i; AddressFamily = 'IPv4'; IPAddress = $Config.ip; PrefixLength = [int]$Config.prefix }
            if ($Config.gateway) { $p.DefaultGateway = $Config.gateway }
            New-NetIPAddress @p -ErrorAction Stop | Out-Null
        }
    }
    $dns = @($Config.dns | Where-Object { "$_".Trim() })
    if ($Config.dnsStatic -and $dns.Count) { Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses $dns -ErrorAction Stop }
    else { Set-DnsClientServerAddress -InterfaceIndex $i -ResetServerAddresses -ErrorAction Stop }
}

# Changes an adapter and records it in History. If the change fails halfway, the old setup is put back.
function Invoke-NetAdapterChange($Target) {
    $errs = @(Test-NetTarget $Target)
    if ($errs.Count) { throw ($errs -join ' ') }
    $adapter = Find-NetAdapter $Target.guid
    $prior = Get-NetAdapterConfig $adapter
    try {
        Set-NetAdapterConfig $Target
    } catch {
        $why = $_.Exception.Message
        try { Set-NetAdapterConfig $prior } catch { }
        throw "Could not change $($adapter.Name): $why The previous settings were put back."
    }
    $change = [pscustomobject]@{ kind = 'netadapter'; name = $adapter.Name; prior = $prior; target = $Target }
    $entry = New-JournalEntry 'setting.network' "Network: $($adapter.Name) - $(Format-NetConfig $Target)" @($change) @()
    Add-JournalEntry $entry
    $entry
}

#endregion
#region PC name and domain ---------------------------------------------------

# Problems with a new PC name, in plain words. Empty when it's fine.
function Test-ComputerNameText([string]$Name) {
    $Name = "$Name".Trim()
    if (-not $Name) { return @('Enter a name.') }
    $errs = @()
    if ($Name.Length -gt 15) { $errs += 'PC names can be at most 15 characters.' }
    if ($Name -notmatch '^[A-Za-z0-9-]+$') { $errs += 'Use only letters, numbers and hyphens (no spaces).' }
    elseif ($Name -match '^\d+$') { $errs += 'A PC name cannot be only numbers.' }
    elseif ($Name.StartsWith('-') -or $Name.EndsWith('-')) { $errs += 'A PC name cannot start or end with a hyphen.' }
    $errs
}

function Test-WorkgroupText([string]$Name) {
    $Name = "$Name".Trim()
    if (-not $Name) { return @('Enter a workgroup name.') }
    $errs = @()
    if ($Name.Length -gt 15) { $errs += 'Workgroup names can be at most 15 characters.' }
    if ($Name -match '[\\/:*?"<>|.,;=+\[\]]') { $errs += 'The workgroup name has characters Windows does not allow.' }
    $errs
}

function Test-DomainText([string]$Name) {
    $Name = "$Name".Trim()
    if ($Name -notmatch '^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$') {
        return @("'$Name' is not a valid domain name (for example corp.example.com).")
    }
    @()
}

function Get-ComputerIdentity {
    $cs = Get-CimInstance Win32_ComputerSystem
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
    $active = [string](Get-ItemProperty "$key\ActiveComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $pending = [string](Get-ItemProperty "$key\ComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if (-not $active) { $active = $env:COMPUTERNAME }
    $caption = [string](Get-CimInstance Win32_OperatingSystem).Caption
    [pscustomobject]@{
        Name        = $active
        PendingName = $(if ($pending -and $pending -ne $active) { $pending } else { $null })
        InDomain    = [bool]$cs.PartOfDomain
        Domain      = $(if ($cs.PartOfDomain) { [string]$cs.Domain } else { $null })
        Workgroup   = $(if (-not $cs.PartOfDomain) { [string]$cs.Workgroup } else { $null })
        CanJoin     = $caption -notmatch 'Home'
        Edition     = $caption
    }
}

# Renames the PC (takes effect after a restart). Going back to the current name just cancels
# a pending rename, which Rename-Computer refuses to do.
function Set-PcName([string]$Name) {
    $Name = $Name.Trim()
    $id = Get-ComputerIdentity
    if ($Name -eq $id.Name) {
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -Value $Name -ErrorAction Stop
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'NV Hostname' -Value $Name -ErrorAction Stop
    } else {
        Rename-Computer -NewName $Name -Force -ErrorAction Stop -WarningAction SilentlyContinue
    }
}

function Set-ComputerNameRecorded([string]$NewName) {
    $errs = @(Test-ComputerNameText $NewName)
    if ($errs.Count) { throw ($errs -join ' ') }
    $id = Get-ComputerIdentity
    $prior = $(if ($id.PendingName) { $id.PendingName } else { $id.Name })
    if ($prior -eq $NewName.Trim()) { throw "This PC is already called $prior." }
    if ($id.InDomain) { throw 'This PC is in a domain. Rename it while joining or leaving the domain, so the domain account is renamed too.' }
    Set-PcName $NewName
    $change = [pscustomobject]@{ kind = 'computername'; name = 'PC name'; prior = $prior }
    $entry = New-JournalEntry 'setting.computername' "PC name: $prior -> $($NewName.Trim()) (after restart)" @($change) @()
    Add-JournalEntry $entry
    $entry
}

function Set-WorkgroupRecorded([string]$Workgroup) {
    $errs = @(Test-WorkgroupText $Workgroup)
    if ($errs.Count) { throw ($errs -join ' ') }
    $id = Get-ComputerIdentity
    if ($id.InDomain) { throw 'This PC is in a domain. Use "Leave domain" to move it to a workgroup.' }
    if ($id.Workgroup -eq $Workgroup.Trim()) { throw "This PC is already in the $($id.Workgroup) workgroup." }
    Add-Computer -WorkgroupName $Workgroup.Trim() -Force -ErrorAction Stop -WarningAction SilentlyContinue
    $change = [pscustomobject]@{ kind = 'workgroup'; name = 'Workgroup'; prior = $id.Workgroup }
    $entry = New-JournalEntry 'setting.workgroup' "Workgroup: $($id.Workgroup) -> $($Workgroup.Trim()) (after restart)" @($change) @()
    Add-JournalEntry $entry
    $entry
}

# Domain join and leave need a domain account, so they can't be undone from History.
# They are logged as notes only (no undo button). Returns a short summary for the log.
function Add-DomainJoin([string]$Domain, [pscredential]$Credential, [string]$OUPath, [string]$NewName) {
    $errs = @(Test-DomainText $Domain)
    if ($NewName) { $errs += @(Test-ComputerNameText $NewName) }
    if ($errs.Count) { throw ($errs -join ' ') }
    $id = Get-ComputerIdentity
    if (-not $id.CanJoin) { throw "$($id.Edition) cannot join a domain. Windows Pro or higher is needed." }
    if ($id.InDomain) { throw "This PC is already in the $($id.Domain) domain. Leave it first." }
    $p = @{ DomainName = $Domain.Trim(); Credential = $Credential; Force = $true; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if ($OUPath) { $p.OUPath = $OUPath.Trim() }
    if ($NewName -and $NewName.Trim() -ne $id.Name) { $p.NewName = $NewName.Trim() }
    Add-Computer @p
    "Joined $($Domain.Trim())$(if ($p.NewName) { " as $($p.NewName)" }). Restart to finish."
}

function Remove-DomainJoin([string]$Workgroup, [pscredential]$Credential) {
    $errs = @(Test-WorkgroupText $Workgroup)
    if ($errs.Count) { throw ($errs -join ' ') }
    $id = Get-ComputerIdentity
    if (-not $id.InDomain) { throw 'This PC is not in a domain.' }
    $p = @{ WorkgroupName = $Workgroup.Trim(); Force = $true; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if ($Credential) { $p.UnjoinDomainCredential = $Credential }
    Remove-Computer @p
    "Left $($id.Domain) and joined the $($Workgroup.Trim()) workgroup. Restart to finish. Sign in with a local account afterwards."
}

#endregion
