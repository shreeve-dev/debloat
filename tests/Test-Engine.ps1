# Test-Engine.ps1
# Checks that applying and undoing a tweak restores the registry exactly.
# Only touches HKCU\Software\DebloatToolTest and a temporary journal file. Safe to run any time.

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $script:Root 'src\Engine.ps1')
. (Join-Path $script:Root 'src\Apps.ps1')

$script:DataDir = Join-Path ([IO.Path]::GetTempPath()) ("dbt-test-" + [guid]::NewGuid().ToString('N'))
$script:JournalPath = Join-Path $script:DataDir 'journal.json'
$base = 'HKCU\Software\DebloatToolTest'
$failures = 0

function Assert([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  PASS  $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Message" -ForegroundColor Red; $script:failures++ }
}

function Get-Snapshot {
    # Full dump of the test area: every key, value name, kind and data.
    $out = @()
    $stack = @($base)
    while ($stack.Count) {
        $path = $stack[0]; $stack = @($stack | Select-Object -Skip 1)
        $k = Open-RegKey $path
        if (-not $k) { continue }
        try {
            $out += "KEY $path"
            foreach ($n in ($k.GetValueNames() | Sort-Object)) {
                $v = Get-RegValue $path $(if ($n -eq '') { '(Default)' } else { $n })
                $out += "  [$n] $($v.Kind) = $(@($v.Value) -join '|')"
            }
            foreach ($s in ($k.GetSubKeyNames() | Sort-Object)) { $stack += "$path\$s" }
        } finally { $k.Close() }
    }
    $out -join "`n"
}

# Clean slate
$hk = Open-RegKey 'HKCU\Software' -Writable
$hk.DeleteSubKeyTree('DebloatToolTest', $false); $hk.Close()

# Starting state: a mix of kinds, including a value that will be deleted and one that will change type
Set-RegValue "$base\Existing" 'Dword'    'DWord' 7
Set-RegValue "$base\Existing" 'Text'     'String' 'hello'
Set-RegValue "$base\Existing" 'Expand'   'ExpandString' '%SystemRoot%\x'
Set-RegValue "$base\Existing" 'Multi'    'MultiString' @('a', 'b')
Set-RegValue "$base\Existing" 'Bin'      'Binary' '01 02 0A FF'
Set-RegValue "$base\Existing" 'ToDelete' 'DWord' 1
Set-RegValue "$base\Existing" 'KindSwap' 'String' '5'
$before = Get-Snapshot

$tweak = [pscustomobject]@{
    id = 'test.roundtrip'; name = 'Round-trip test'
    registry = @(
        [pscustomobject]@{ path = "$base\Existing"; name = 'Dword'; type = 'DWord'; value = 4294967295 }
        [pscustomobject]@{ path = "$base\Existing"; name = 'Text'; type = 'String'; value = 'changed' }
        [pscustomobject]@{ path = "$base\Existing"; name = 'Expand'; type = 'ExpandString'; value = '%TEMP%\y' }
        [pscustomobject]@{ path = "$base\Existing"; name = 'Multi'; type = 'MultiString'; value = @('z') }
        [pscustomobject]@{ path = "$base\Existing"; name = 'Bin'; type = 'Binary'; value = '00' }
        [pscustomobject]@{ path = "$base\Existing"; name = 'ToDelete'; delete = $true }
        [pscustomobject]@{ path = "$base\Existing"; name = 'KindSwap'; type = 'DWord'; value = 5 }
        [pscustomobject]@{ path = "$base\Existing"; name = 'NewValue'; type = 'QWord'; value = 123456789012 }
        [pscustomobject]@{ path = "$base\New\Deep\Key"; name = '(Default)'; type = 'String'; value = '' }
    )
}

Write-Host 'Status before apply'
Assert ((Get-TweakStatus $tweak).State -eq 'NotApplied') 'tweak reports Not applied'
Assert (@(Get-TweakPlan $tweak).Count -eq 9) 'plan lists 9 changes'

Write-Host 'Apply'
$r = Invoke-Tweak $tweak
Assert ($r.Errors.Count -eq 0) 'no errors'
Assert ($r.Changes -eq 9) '9 changes recorded'
Assert ((Get-TweakStatus $tweak).State -eq 'Applied') 'tweak reports Applied'
Assert (@(Get-TweakPlan $tweak).Count -eq 0) 'plan is empty after apply'
$dw = Get-RegValue "$base\Existing" 'Dword'
Assert ([uint64]$dw.Value -eq 4294967295) '0xFFFFFFFF DWORD written correctly'
Assert (-not (Get-RegValue "$base\Existing" 'ToDelete').Exists) 'value deleted'
Assert ((Get-RegValue "$base\New\Deep\Key" '(Default)').Exists) 'nested new key with (Default) created'

Write-Host 'Second apply is a no-op'
$r2 = Invoke-Tweak $tweak
Assert ($r2.Changes -eq 0 -and $null -eq $r2.Entry) 'nothing changed, nothing journaled'

Write-Host 'Undo'
$errs = @(Undo-JournalEntry $r.Entry.id)
Assert ($errs.Count -eq 0) 'no undo errors'
$after = Get-Snapshot
Assert ($after -eq $before) 'registry identical to the starting state (incl. kinds and deleted keys)'
if ($after -ne $before) { Write-Host "--- before`n$before`n--- after`n$after" }
Assert (-not (Test-RegKey "$base\New")) 'keys created by the tweak were removed'
Assert ((@(Get-Journal) | Where-Object { $_.id -eq $r.Entry.id }).undone -eq $true) 'journal entry marked undone'

Write-Host 'Catalog sanity'
Import-DebloatConfig
$ids = @($script:Catalog | ForEach-Object { $_.id })
Assert ($ids.Count -eq @($ids | Select-Object -Unique).Count) "tweak ids are unique ($($ids.Count) tweaks)"
foreach ($t in $script:Catalog) {
    if ($t.category -notin $script:Categories) { Assert $false "$($t.id) has unknown category '$($t.category)'" }
    if (-not $script:RiskRank.ContainsKey($t.risk)) { Assert $false "$($t.id) has unknown risk '$($t.risk)'" }
    foreach ($reg in (Get-Items $t 'registry')) {
        try { $null = Split-RegPath $reg.path; $null = ConvertFrom-PortableValue $reg.value $reg.type } catch { Assert $false "$($t.id): $($_.Exception.Message)" }
    }
    foreach ($code in @($t.script.apply, $t.script.undo, $t.script.detect, $t.script.snapshot)) {
        if ($code) {
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput((Join-Code $code), [ref]$null, [ref]$errs)
            if ($errs) { Assert $false "$($t.id) script does not parse: $($errs[0].Message)" }
        }
    }
}
foreach ($p in $script:Presets) {
    $n = @(Resolve-PresetTweaks $p).Count
    Assert ($n -gt 0) "preset '$($p.name)' selects $n tweaks"
}

Write-Host 'Install catalog sanity'
. (Join-Path $script:Root 'src\Installer.ps1')
Import-InstallCatalog
$keys = @($script:InstallCatalog.apps | ForEach-Object { Get-InstallKey $_ })
Assert ($keys.Count -eq @($keys | Select-Object -Unique).Count) "install app keys are unique ($($keys.Count) apps)"
foreach ($a in $script:InstallCatalog.apps) {
    if ($a.category -notin @($script:InstallCatalog.categories)) { Assert $false "$($a.name) has unknown category '$($a.category)'" }
    if (-not $a.id -and -not $a.url) { Assert $false "$($a.name) has neither a winget id nor a url" }
}
foreach ($b in $script:InstallCatalog.bundles) {
    $missing = @($b.apps | Where-Object { $keys -notcontains $_ })
    Assert ($missing.Count -eq 0) "bundle '$($b.name)' only lists known apps$(if ($missing) { ': unknown ' + ($missing -join ', ') })"
}

Write-Host 'Custom bundles'
# Use throwaway folders so the tests never read or write your real custom-bundles.json.
$cfg = Join-Path $script:DataDir 'config'
$bdir = Join-Path $script:DataDir 'bundles'
New-Item -ItemType Directory -Force $cfg | Out-Null
Copy-Item (Join-Path $script:Root 'config\install.json') $cfg
Import-InstallCatalog -ConfigDir $cfg -BundleDir $bdir
Assert (@($script:InstallBundles | Where-Object { $_.custom }).Count -eq 0) 'no custom bundles without custom-bundles.json'
Assert ($script:CustomBundlePath -eq (Join-Path $bdir 'custom-bundles.json')) 'custom bundles are kept outside the app folder'
# A file left in config\ by an older version is copied to the new place once.
Copy-Item (Join-Path $script:Root 'config\custom-bundles.example.json') (Join-Path $cfg 'custom-bundles.json')
Import-InstallCatalog -ConfigDir $cfg -BundleDir $bdir
Assert (Test-Path (Join-Path $bdir 'custom-bundles.json')) 'old config\custom-bundles.json is moved to the data folder'
$example = $script:InstallBundles | Where-Object { $_.custom } | Select-Object -First 1
Assert ($example -and $example.name -eq 'My PC') 'example custom bundle loads and is marked as yours'
$missing = @($example.apps | Where-Object { $keys -notcontains $_ })
Assert ($missing.Count -eq 0) "example bundle only lists known apps$(if ($missing) { ': unknown ' + ($missing -join ', ') })"
Save-CustomBundle 'Saved test' @('Google.Chrome')
Assert (@($script:InstallBundles | Where-Object { $_.custom -and $_.name -eq 'Saved test' }).Count -eq 1) 'saving a bundle writes to the data folder and reloads it'
[IO.File]::WriteAllText((Join-Path $bdir 'custom-bundles.json'), '{ not json')
$warn = $null
Import-InstallCatalog -ConfigDir $cfg -BundleDir $bdir -WarningVariable warn -WarningAction SilentlyContinue
Assert ($script:InstallBundles.Count -eq @($script:InstallCatalog.bundles).Count -and $warn) 'broken custom-bundles.json is skipped with a warning'
Copy-Item (Join-Path $script:Root 'config\custom-bundles.example.json') (Join-Path $bdir 'custom-bundles.json') -Force
Import-InstallCatalog -ConfigDir $cfg -BundleDir $bdir

Write-Host 'ISO builder'
. (Join-Path $script:Root 'src\IsoBuilder.ps1')
$iso = [pscustomobject]@{
    IsoPath = 'C:\x.iso'; EditionIndex = 6; EditionName = 'Windows 11 Pro'; Language = 'en-US'; Locale = 'en-US'
    InputLocale = '0409:00000409'; TimeZone = 'Mountain Standard Time'; OutputDir = 'C:\Out'; RemoveApps = $true
    InjectDrivers = $true; PreventEncryption = $false; Unattend = $true; UserName = 'TestUser'; Password = 'p<&>"w'
    ComputerName = 'TEST-PC'; Preset = 'Gaming'; Bundles = @('My PC'); FirstBoot = $true
}
$xmlText = New-UnattendXml $iso
$ok = $true; try { [xml]$doc = $xmlText } catch { $ok = $false }
Assert $ok 'autounattend.xml is well-formed XML (with special characters in the password)'
Assert ($xmlText -notmatch 'DiskConfiguration|InstallTo|WillWipeDisk') 'answer file never selects or wipes a disk'
Assert ($xmlText -notmatch [regex]::Escape('p<&>"w')) 'password is not stored as plain text'
$ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
Assert ((Select-Xml -Xml $doc -XPath '//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine' -Namespace $ns).Node.InnerText -match 'FirstLogon\.ps1') 'first sign-in runs FirstLogon.ps1'
Assert ((Select-Xml -Xml $doc -XPath '//u:LocalAccount/u:Name' -Namespace $ns).Node.InnerText -eq 'TestUser') 'local account name set'
Assert ((Select-Xml -Xml $doc -XPath '//u:ProductKey/u:Key' -Namespace $ns).Node.InnerText -eq 'VK7JG-NPHTM-C97JM-9MPGT-3V66T') 'generic Pro key selects the edition'
$pwNode = (Select-Xml -Xml $doc -XPath '//u:LocalAccount/u:Password/u:Value' -Namespace $ns).Node.InnerText
Assert ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($pwNode)) -eq 'p<&>"wPassword') 'password encoded the way Windows Setup expects'
$iso.Password = ''; $iso.FirstBoot = $false; $iso.EditionName = 'Windows 11 Education'
$xml2 = New-UnattendXml $iso
$ok = $true; try { [xml]$doc2 = $xml2 } catch { $ok = $false }
Assert $ok 'blank-password, no-first-boot variant is well-formed'
Assert ($xml2 -notmatch 'FirstLogonCommands' -and $xml2 -notmatch '<ProductKey>') 'no first-boot command or key when not needed'
$plan = Get-FirstBootApps @('My PC')
Assert ($plan.apps.Count -eq 4 -and @($plan.urls).Count -eq 1) "custom bundle gives $($plan.apps.Count) winget apps and $(@($plan.urls).Count) download page"
Assert (@($plan.apps | Where-Object { $_.noAdmin }).name -contains 'Spotify') 'Spotify is installed without admin rights'
$iso.OutputDir = 'C:\My Folder'
Assert (@(Test-IsoSettings $iso) -match 'spaces').Count 'output path with spaces is rejected'
foreach ($f in 'tools\install.ps1', 'src\Settings.ps1', 'src\Gui.ps1', 'setup\FirstLogon.ps1', 'setup\InstallApps.ps1', 'src\IsoBuildJob.ps1', 'src\IsoBuilder.ps1') {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root $f), [ref]$null, [ref]$errs)
    Assert (-not $errs) "$f parses"
}

Write-Host 'Settings catalog'
. (Join-Path $script:Root 'src\Settings.ps1')
Import-SettingsCatalog
$sids = @($script:SettingsCatalog | ForEach-Object { $_.id })
Assert ($sids.Count -eq @($sids | Select-Object -Unique).Count) "setting ids are unique ($($sids.Count) settings)"
foreach ($s in $script:SettingsCatalog) {
    if ($s.category -notin $script:SettingsCategories) { Assert $false "$($s.id) has unknown category '$($s.category)'" }
    $labels = @($s.options | ForEach-Object { $_.label })
    if ($labels.Count -lt 2) { Assert $false "$($s.id) needs at least two options" }
    if ($labels.Count -ne @($labels | Select-Object -Unique).Count) { Assert $false "$($s.id) has duplicate option labels" }
    foreach ($a in (Get-Items $s 'after')) { if ($a -notin 'explorer', 'signout', 'reboot') { Assert $false "$($s.id) has unknown after '$a'" } }
    foreach ($o in @($s.options)) {
        $t = ConvertTo-OptionTweak $s $o
        if (-not @(Get-Items $t 'registry').Count -and -not $t.PSObject.Properties['script']) { Assert $false "$($s.id) / $($o.label) changes nothing" }
        foreach ($reg in (Get-Items $t 'registry')) {
            try { $null = Split-RegPath $reg.path; $null = ConvertFrom-PortableValue $reg.value $reg.type } catch { Assert $false "$($s.id) / $($o.label): $($_.Exception.Message)" }
        }
        if ($t.PSObject.Properties['script']) {
            if (-not $t.script.detect) { Assert $false "$($s.id) / $($o.label): a script option needs detect so the page can show it" }
            foreach ($code in @($t.script.apply, $t.script.undo, $t.script.detect, $t.script.snapshot)) {
                if ($code) {
                    $errs = $null
                    [void][System.Management.Automation.Language.Parser]::ParseInput((Join-Code $code), [ref]$null, [ref]$errs)
                    if ($errs) { Assert $false "$($s.id) / $($o.label) script does not parse: $($errs[0].Message)" }
                }
            }
        }
    }
}
$checked = 0
foreach ($s in $script:SettingsCatalog) { try { $null = Get-SettingCurrent $s; $checked++ } catch { Assert $false "$($s.id): reading its current value failed: $($_.Exception.Message)" } }
Assert ($checked -eq $script:SettingsCatalog.Count) "current value of every setting can be read ($checked)"

Write-Host 'Settings: change and undo'
$setting = [pscustomobject]@{
    id = 'test.choice'; name = 'Test choice'; category = 'Test'; description = ''
    options = @(
        [pscustomobject]@{ label = 'A'; registry = @([pscustomobject]@{ path = "$base\Setting"; name = 'Choice'; type = 'DWord'; value = 1 }) }
        [pscustomobject]@{ label = 'B'; registry = @([pscustomobject]@{ path = "$base\Setting"; name = 'Choice'; type = 'DWord'; value = 2 }) }
    )
}
Assert ($null -eq (Get-SettingCurrent $setting)) 'no option is current before any change'
$ra = Set-SettingOption $setting $setting.options[0]
Assert ((Get-SettingCurrent $setting).label -eq 'A') 'choosing A makes A current'
$rb = Set-SettingOption $setting $setting.options[1]
Assert ((Get-SettingCurrent $setting).label -eq 'B') 'choosing B makes B current'
Assert ($rb.Entry.name -eq 'Test choice: B') 'History entry names the setting and option'
[void](Undo-JournalEntry $rb.Entry.id)
Assert ((Get-SettingCurrent $setting).label -eq 'A') 'undoing B goes back to A'
[void](Undo-JournalEntry $ra.Entry.id)
Assert (-not (Test-RegKey "$base\Setting")) 'undoing A removes what it created'

Write-Host 'Network checks (no changes are made)'
Assert ((ConvertTo-PrefixLength '255.255.255.0') -eq 24 -and (ConvertTo-PrefixLength '/16') -eq 16 -and (ConvertTo-PrefixLength '8') -eq 8) 'subnet masks and prefixes are understood'
Assert ($null -eq (ConvertTo-PrefixLength '255.0.255.0') -and $null -eq (ConvertTo-PrefixLength '33') -and $null -eq (ConvertTo-PrefixLength 'abc')) 'bad subnet masks are rejected'
Assert ((ConvertTo-SubnetMask 24) -eq '255.255.255.0' -and (ConvertTo-SubnetMask 32) -eq '255.255.255.255' -and (ConvertTo-SubnetMask 20) -eq '255.255.240.0') 'prefix to subnet mask'
$net = [pscustomobject]@{ dhcp = $false; ip = '192.168.0.50'; prefix = 24; gateway = '192.168.0.1'; dnsStatic = $true; dns = @('1.1.1.1', '1.0.0.1') }
Assert (@(Test-NetTarget $net).Count -eq 0) 'a normal static setup passes'
Assert ((Format-NetConfig $net) -match 'Cloudflare') 'DNS presets are recognised'
$bad = @(
    @{ ip = '192.168.0.300' }, @{ ip = '192.168.0.0' }, @{ ip = '192.168.0.255' }, @{ gateway = '192.168.1.1' },
    @{ gateway = '192.168.0.50' }, @{ prefix = 0 }, @{ dns = @() }, @{ dns = @('8.8.8') }, @{ ip = '127.0.0.5'; gateway = '127.0.0.1' }
)
foreach ($b in $bad) {
    $c = $net.PSObject.Copy()
    foreach ($k in $b.Keys) { $c.$k = $b[$k] }
    Assert (@(Test-NetTarget $c).Count -gt 0) "rejected: $(($b.GetEnumerator() | ForEach-Object { "$($_.Key)=$(@($_.Value) -join ',')" }) -join ' ')"
}
Assert (@(Test-NetTarget ([pscustomobject]@{ dhcp = $true; dnsStatic = $false; dns = @() })).Count -eq 0) 'automatic IP and DNS always pass'
foreach ($a in @(Get-NetAdapterList)) {
    $cfg = Get-NetAdapterConfig $a
    Assert ($cfg.guid -and $cfg.name) "reads adapter '$($cfg.name)': $(Format-NetConfig $cfg)"
}

# Clean up
$hk = Open-RegKey 'HKCU\Software' -Writable
$hk.DeleteSubKeyTree('DebloatToolTest', $false); $hk.Close()
Remove-Item -Recurse -Force $script:DataDir -ErrorAction SilentlyContinue

Write-Host ''
if ($failures) { Write-Host "$failures test(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed.' -ForegroundColor Green
