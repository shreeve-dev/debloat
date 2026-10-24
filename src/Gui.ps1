# Gui.ps1
# WPF interface. Controls are built in code from the catalogs; per-item data lives in each control's Tag.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:BrushConv = New-Object System.Windows.Media.BrushConverter
function Brush([string]$Hex) { $script:BrushConv.ConvertFromString($Hex) }

$script:RiskStyle = @{
    safe     = @('Safe', '#1D3A2A', '#62D394')
    moderate = @('Moderate', '#3D3420', '#F2C14E')
    advanced = @('Advanced', '#43242A', '#FF7A85')
}
$script:StateStyle = @{
    Applied    = @('Applied', '#1F3150', '#8CBBFF')
    Partial    = @('Partly applied', '#33294A', '#C9AEFF')
    NotApplied = @('Not applied', '#23272F', '#8A91A3')
    Unknown    = @('-', '#23272F', '#8A91A3')
}
$script:GroupText = [ordered]@{
    Recommended = 'Recommended to remove'
    Optional    = 'Optional - remove only if you never use them'
    Caution     = 'Caution - Xbox and gaming components'
    Other       = 'Other installed apps'
}
$script:Warn = [string][char]0x26A0

#region Small builders -------------------------------------------------------

function New-Text {
    param([string]$Text, [double]$Size = 13, [string]$Color = '#E6E8EE', [string]$Weight = 'Normal', [string]$Margin = '0')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Brush $Color
    $t.FontWeight = $Weight; $t.TextWrapping = 'Wrap'; $t.Margin = $Margin
    $t
}

function New-Badge([string]$Text, [string]$Bg, [string]$Fg) {
    $tb = New-Text $Text 11 $Fg 'SemiBold'
    $tb.TextWrapping = 'NoWrap'
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Brush $Bg; $b.CornerRadius = 4; $b.Padding = '7,2'; $b.Margin = '6,0,0,0'
    $b.VerticalAlignment = 'Top'; $b.Child = $tb
    $b
}

function Set-Badge($Badge, [string[]]$Style) {
    $Badge.Background = Brush $Style[1]
    $Badge.Child.Text = $Style[0]
    $Badge.Child.Foreground = Brush $Style[2]
}

function New-Card($Child, [string]$Margin = '0,0,0,8') {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Brush '#1B1E26'; $b.BorderBrush = Brush '#2A2F3B'; $b.BorderThickness = 1
    $b.CornerRadius = 8; $b.Padding = '14,11'; $b.Margin = $Margin; $b.Child = $Child
    $b
}

function New-Button([string]$Text, $Tag, [string]$Style) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = $Text; $btn.Tag = $Tag
    if ($Style) { $btn.Style = $script:Window.FindResource($Style) }
    else { $btn.Style = $script:Window.FindResource([System.Windows.Controls.Button]) }
    $btn
}

function New-Header([string]$Text) { New-Text $Text 16 '#FFFFFF' 'SemiBold' '2,16,0,8' }

function Update-UI {
    $script:Window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Show-Message([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    if ($script:SmokeDir) { return 'Yes' }
    [string][System.Windows.MessageBox]::Show($script:Window, $Text, 'DebloatTool', $Buttons, $Icon)
}

#endregion
#region Navigation and log ---------------------------------------------------

$script:Panels = 'Dashboard', 'Tweaks', 'Settings', 'Install', 'Apps', 'Startup', 'Maintenance', 'Iso', 'History'

function Show-Panel([string]$Name) {
    foreach ($p in $script:Panels) {
        $script:UI["Panel$p"].Visibility = $(if ($p -eq $Name) { 'Visible' } else { 'Collapsed' })
    }
    if (-not $script:UI["Nav$Name"].IsChecked) { $script:UI["Nav$Name"].IsChecked = $true }
    $script:UI.ActionBar.Visibility = $(if ($Name -in 'Dashboard', 'Tweaks', 'Apps') { 'Visible' } else { 'Collapsed' })
    # The install list asks winget what is installed, which takes a few seconds, so load it on first visit.
    if ($Name -eq 'Install' -and -not $script:InstallLoaded) { Update-UI; Build-InstallList }
    # The Settings page checks every setting's current value, so it is also built on first visit.
    if ($Name -eq 'Settings' -and -not $script:SettingsLoaded) { Update-UI; Build-SettingsList }
    if ($Name -eq 'Iso' -and -not $script:IsoEditionsFor -and $script:IsAdmin -and $script:UI.IsoPath.Text) { Update-UI; Read-IsoEditions }
}

function Set-Busy([bool]$Busy) {
    $script:UI.ApplyBtn.IsEnabled = -not $Busy
    foreach ($p in $script:Panels) { $script:UI["Nav$p"].IsEnabled = -not $Busy }
    $script:Window.Cursor = $(if ($Busy) { [System.Windows.Input.Cursors]::Wait } else { $null })
    Update-UI
}

#endregion
#region Tweaks page ----------------------------------------------------------

function New-TweakCard($Tweak) {
    $dock = New-Object System.Windows.Controls.DockPanel

    $badges = New-Object System.Windows.Controls.StackPanel
    $badges.Orientation = 'Horizontal'; $badges.VerticalAlignment = 'Top'; $badges.Margin = '12,0,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($badges, 'Right')
    $r = $script:RiskStyle[$Tweak.risk]
    [void]$badges.Children.Add((New-Badge $r[0] $r[1] $r[2]))
    $state = New-Badge '...' '#23272F' '#8A91A3'
    [void]$badges.Children.Add($state)
    [void]$dock.Children.Add($badges)

    $content = New-Object System.Windows.Controls.StackPanel
    [void]$content.Children.Add((New-Text $Tweak.name 14 '#F2F4F8' 'SemiBold'))
    [void]$content.Children.Add((New-Text $Tweak.description 12.5 '#9AA1B2' 'Normal' '0,3,0,0'))
    if ($Tweak.note) { [void]$content.Children.Add((New-Text "$script:Warn  $($Tweak.note)" 12 '#E8B949' 'Normal' '0,5,0,0')) }
    $after = @(Get-Items $Tweak 'after' | ForEach-Object { $script:AfterText[$_] })
    if ($after) { [void]$content.Children.Add((New-Text "Takes effect after $($after -join ' / ')" 11.5 '#6F7790' 'Normal' '0,4,0,0')) }

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $content; $cb.Tag = $Tweak.id; $cb.VerticalContentAlignment = 'Top'
    $cb.Add_Click({ Update-SelectionSummary })
    [void]$dock.Children.Add($cb)

    $card = New-Card $dock
    $script:TweakChecks[$Tweak.id] = $cb
    $script:TweakCards[$Tweak.id]  = $card
    $script:TweakBadges[$Tweak.id] = $state
    $card
}

function Build-TweakList {
    $list = $script:UI.TweakList
    $list.Children.Clear()
    $script:TweakChecks = @{}; $script:TweakCards = @{}; $script:TweakBadges = @{}; $script:CategoryHeaders = @{}
    foreach ($cat in $script:Categories) {
        $items = @($script:Catalog | Where-Object { $_.category -eq $cat })
        if (-not $items.Count) { continue }
        $h = New-Header $cat
        [void]$list.Children.Add($h)
        $script:CategoryHeaders[$cat] = $h
        foreach ($t in $items) { [void]$list.Children.Add((New-TweakCard $t)) }
    }
}

function Update-TweakStatuses {
    Write-Log 'Checking which tweaks are already applied...'
    $script:TweakState = @{}
    foreach ($t in $script:Catalog) {
        $s = (Get-TweakStatus $t).State
        $script:TweakState[$t.id] = $s
        Set-Badge $script:TweakBadges[$t.id] $script:StateStyle[$s]
    }
    $applied = @($script:TweakState.Values | Where-Object { $_ -eq 'Applied' }).Count
    Write-Log "Status check done: $applied of $($script:Catalog.Count) tweaks already applied."
    Update-TweakFilter
}

function Update-TweakFilter {
    $q = $script:UI.TweakSearch.Text.Trim()
    $hide = [bool]$script:UI.HideApplied.IsChecked
    $visibleCats = @{}
    foreach ($t in $script:Catalog) {
        $show = $true
        if ($q) {
            $hay = "$($t.name) $($t.description) $($t.category) $($t.id)"
            if ($hay.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $show = $false }
        }
        if ($hide -and $script:TweakState[$t.id] -eq 'Applied') { $show = $false }
        $script:TweakCards[$t.id].Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
        if ($show) { $visibleCats[$t.category] = $true }
    }
    foreach ($c in @($script:CategoryHeaders.Keys)) {
        $script:CategoryHeaders[$c].Visibility = $(if ($visibleCats[$c]) { 'Visible' } else { 'Collapsed' })
    }
}

function Build-PresetButtons {
    $script:UI.PresetBar.Children.Clear()
    [void]$script:UI.PresetBar.Children.Add((New-Text 'Presets:' 13 '#8A91A3' 'Normal' '0,7,10,0'))
    foreach ($p in $script:Presets) {
        $b = New-Button $p.name $p.name
        $b.ToolTip = $p.description
        $b.Margin = '0,0,8,6'
        $b.Add_Click({ param($s, $e) Select-Preset $s.Tag })
        [void]$script:UI.PresetBar.Children.Add($b)
    }
}

function Select-Preset([string]$Name) {
    $p = Get-Preset $Name
    if (-not $p) { return }
    $ids = @(Resolve-PresetTweaks $p | ForEach-Object { $_.id })
    foreach ($id in @($script:TweakChecks.Keys)) {
        $script:TweakChecks[$id].IsChecked = (($ids -contains $id) -and $script:TweakState[$id] -ne 'Applied')
    }
    foreach ($cb in @($script:AppChecks.Values)) {
        $cb.IsChecked = ($p.apps -eq 'recommended' -and $cb.Tag.Group -eq 'Recommended')
    }
    Update-SelectionSummary
    $n = @($ids | Where-Object { $script:TweakState[$_] -ne 'Applied' }).Count
    Write-Log "Preset '$Name' selected: $n tweak(s) to apply ($($ids.Count - $n) already applied)."
    Show-Panel 'Tweaks'
}

function Get-SelectedTweaks { @($script:Catalog | Where-Object { $script:TweakChecks[$_.id].IsChecked }) }
function Get-SelectedApps { @($script:AppInventory | Where-Object { $script:AppChecks[$_.Name] -and $script:AppChecks[$_.Name].IsChecked }) }

function Update-SelectionSummary {
    $t = @(Get-SelectedTweaks).Count
    $a = @(Get-SelectedApps).Count
    $script:UI.SelectionSummary.Text = "$t tweak(s) and $a app(s) selected"
}

#endregion
#region Apps page ------------------------------------------------------------

function Build-AppList {
    Write-Log 'Reading installed Store apps...'
    $script:AppInventory = @(Get-AppInventory)
    $list = $script:UI.AppList
    $list.Children.Clear()
    $script:AppChecks = @{}
    foreach ($g in $script:GroupText.Keys) {
        $apps = @($script:AppInventory | Where-Object { $_.Group -eq $g })
        if (-not $apps.Count) { continue }
        [void]$list.Children.Add((New-Header "$($script:GroupText[$g]) ($($apps.Count))"))
        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($a in $apps) {
            $content = New-Object System.Windows.Controls.StackPanel
            [void]$content.Children.Add((New-Text $a.Label 13.5 '#F2F4F8' 'SemiBold'))
            [void]$content.Children.Add((New-Text $a.Name 11.5 '#6F7790' 'Normal' '0,2,0,0'))
            if ($a.Note) { [void]$content.Children.Add((New-Text $a.Note 11.5 '#E8B949' 'Normal' '0,4,0,0')) }
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $content; $cb.Tag = $a; $cb.VerticalContentAlignment = 'Top'
            $cb.Add_Click({ Update-SelectionSummary })
            $script:AppChecks[$a.Name] = $cb
            $card = New-Card $cb '0,0,8,8'
            $card.Width = 290
            [void]$wrap.Children.Add($card)
        }
        [void]$list.Children.Add($wrap)
    }
    if (-not $script:AppInventory.Count) { [void]$list.Children.Add((New-Text 'No removable Store apps found.' 13 '#8A91A3')) }
    Write-Log "Found $($script:AppInventory.Count) removable app(s)."
    Update-SelectionSummary
}

#endregion
#region Install page ---------------------------------------------------------

$script:InstallLoaded = $false

function Build-InstallBundles {
    $bar = $script:UI.InstallBundles
    $bar.Children.Clear()
    [void]$bar.Children.Add((New-Text 'Bundles:' 13 '#8A91A3' 'Normal' '0,7,10,0'))
    foreach ($b in $script:InstallBundles) {
        $btn = New-Button $b.name $b.name
        $btn.ToolTip = $b.description
        $btn.Margin = '0,0,8,6'
        $btn.Add_Click({ param($s, $e) Select-InstallBundle $s.Tag })
        [void]$bar.Children.Add($btn)
    }
}

function New-InstallCard($Item) {
    $app = $Item.App
    $content = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.WrapPanel
    $name = New-Text $app.name 13.5 '#F2F4F8' 'SemiBold'
    $name.Margin = '0,0,2,2'
    [void]$title.Children.Add($name)
    if ($Item.Installed) { [void]$title.Children.Add((New-Badge 'Installed' '#1D3A2A' '#62D394')) }
    if ($Item.Update) { [void]$title.Children.Add((New-Badge 'Update available' '#3D3420' '#F2C14E')) }
    if ($Item.WebsiteOnly) { [void]$title.Children.Add((New-Badge 'Website' '#23272F' '#8A91A3')) }
    [void]$content.Children.Add($title)
    [void]$content.Children.Add((New-Text $app.description 12 '#9AA1B2' 'Normal' '0,3,0,0'))

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $content; $cb.Tag = $Item; $cb.VerticalContentAlignment = 'Top'
    $script:InstallChecks[$Item.Key] = $cb
    $card = New-Card $cb '0,0,8,8'
    $card.Width = 300
    $card.ToolTip = $(if ($app.id) { "winget id: $($app.id)" } else { $app.url })
    $script:InstallCards[$Item.Key] = $card
    $card
}

function Build-InstallList {
    $previous = @()
    if ($script:InstallChecks) { $previous = @($script:InstallChecks.Keys | Where-Object { $script:InstallChecks[$_].IsChecked }) }
    $script:UI.InstallStatus.Text = 'Checking what is installed...'
    Write-Log 'Checking installed apps with winget...'
    Set-Busy $true
    try { $script:InstallInventory = @(Get-InstallInventory) } finally { Set-Busy $false }

    $list = $script:UI.InstallList
    $list.Children.Clear()
    $script:InstallChecks = @{}; $script:InstallCards = @{}; $script:InstallHeaders = @{}
    foreach ($cat in @($script:InstallCatalog.categories)) {
        $items = @($script:InstallInventory | Where-Object { $_.App.category -eq $cat })
        if (-not $items.Count) { continue }
        $h = New-Header $cat
        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($it in $items) {
            $card = New-InstallCard $it
            if ($previous -contains $it.Key) { $script:InstallChecks[$it.Key].IsChecked = $true }
            [void]$wrap.Children.Add($card)
        }
        [void]$list.Children.Add($h)
        [void]$list.Children.Add($wrap)
        $script:InstallHeaders[$cat] = @($h, $wrap)
    }

    $installed = @($script:InstallInventory | Where-Object { $_.Installed }).Count
    $updates = @($script:InstallInventory | Where-Object { $_.Update }).Count
    $status = "$installed of $($script:InstallInventory.Count) apps installed  -  $updates update(s) available"
    if (-not (Test-Winget)) { $status = 'winget was not found. Install or update "App Installer" from the Microsoft Store to install apps.' }
    $script:UI.InstallStatus.Text = $status
    Write-Log $status
    $script:InstallLoaded = $true
    Update-InstallFilter
}

function Update-InstallFilter {
    if (-not $script:InstallLoaded) { return }
    $q = $script:UI.InstallSearch.Text.Trim()
    $hideInstalled = [bool]$script:UI.InstallHideInstalled.IsChecked
    $onlyUpdates = [bool]$script:UI.InstallOnlyUpdates.IsChecked
    $visible = @{}
    foreach ($it in $script:InstallInventory) {
        $show = $true
        if ($q) {
            $hay = "$($it.App.name) $($it.App.description) $($it.App.category) $($it.App.id)"
            if ($hay.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $show = $false }
        }
        if ($hideInstalled -and $it.Installed) { $show = $false }
        if ($onlyUpdates -and -not $it.Update) { $show = $false }
        $script:InstallCards[$it.Key].Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
        if ($show) { $visible[$it.App.category] = $true }
    }
    foreach ($c in @($script:InstallHeaders.Keys)) {
        $v = $(if ($visible[$c]) { 'Visible' } else { 'Collapsed' })
        foreach ($el in $script:InstallHeaders[$c]) { $el.Visibility = $v }
    }
}

function Select-InstallBundle([string]$Name) {
    $b = $script:InstallBundles | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $b) { return }
    $keys = @($b.apps)
    foreach ($k in @($script:InstallChecks.Keys)) { $script:InstallChecks[$k].IsChecked = ($keys -contains $k) }
    $sel = @($script:InstallInventory | Where-Object { $keys -contains $_.Key })
    $have = @($sel | Where-Object { $_.Installed }).Count
    Write-Log "Bundle '$Name' selected: $($sel.Count) app(s), $have already installed."
}

function Get-SelectedInstall { @($script:InstallInventory | Where-Object { $script:InstallChecks[$_.Key].IsChecked }) }

function Invoke-InstallOperation([string]$Operation) {
    $sel = @(Get-SelectedInstall)
    if (-not $sel.Count) { [void](Show-Message 'Tick some apps or pick a bundle first.'); return }
    if (-not (Test-Winget)) { [void](Show-Message 'winget was not found. Install or update "App Installer" from the Microsoft Store first.' 'OK' 'Warning'); return }

    $web = @(); $notes = @()
    switch ($Operation) {
        'install' {
            $todo = @($sel | Where-Object { -not $_.WebsiteOnly -and -not $_.Installed })
            $web = @($sel | Where-Object { $_.WebsiteOnly -and -not $_.Installed })
            $skip = @($sel | Where-Object { $_.Installed })
            if ($skip.Count) { $notes += "Already installed, skipped: $(($skip | ForEach-Object { $_.App.name }) -join ', ')" }
            $verb = 'Install'
        }
        'upgrade' {
            $todo = @($sel | Where-Object { $_.Update })
            $skip = @($sel | Where-Object { -not $_.Update })
            if ($skip.Count) { $notes += "No update available, skipped: $(($skip | ForEach-Object { $_.App.name }) -join ', ')" }
            $verb = 'Update'
        }
        'uninstall' {
            $todo = @($sel | Where-Object { -not $_.WebsiteOnly -and $_.Installed })
            $manual = @($sel | Where-Object { $_.WebsiteOnly -and $_.Installed })
            if ($manual.Count) { $notes += "Uninstall these from Settings > Apps instead: $(($manual | ForEach-Object { $_.App.name }) -join ', ')" }
            $verb = 'Uninstall'
        }
    }
    if (-not $todo.Count -and -not $web.Count) {
        [void](Show-Message ("Nothing to do.`n`n" + ($notes -join "`n")))
        return
    }

    $msg = ''
    if ($todo.Count) { $msg += "$verb $($todo.Count) app(s) with winget:`n  " + (($todo | ForEach-Object { $_.App.name }) -join "`n  ") + "`n`n" }
    if ($web.Count) { $msg += "Open the download page for:`n  " + (($web | ForEach-Object { $_.App.name }) -join "`n  ") + "`n`n" }
    if ($notes.Count) { $msg += ($notes -join "`n") + "`n`n" }
    $msg += 'A separate window shows progress. Continue?'
    $icon = $(if ($Operation -eq 'uninstall') { 'Warning' } else { 'Question' })
    if ((Show-Message $msg 'YesNo' $icon) -ne 'Yes') { Write-Log 'Cancelled.'; return }

    foreach ($w in $web) { Open-AppWebsite $w.App; Write-Log "Opened download page: $($w.App.name)" }
    if ($todo.Count) {
        $done = Start-WingetJob $Operation @($todo | ForEach-Object { $_.App })
        Write-Log "$verb started for $($todo.Count) app(s) in a separate window. This page refreshes when it finishes."
        Start-JobWatch $done
    }
}

# Background jobs (installs, ISO builds) write a marker file when they finish; a timer watches for it.
$script:JobWatches = @{}

function Start-JobWatch([string]$DoneFile, [string]$Kind = 'install') {
    $script:JobWatches[$DoneFile] = $Kind
    if (-not $script:JobTimer) {
        $script:JobTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:JobTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:JobTimer.Add_Tick({
            foreach ($f in @($script:JobWatches.Keys)) {
                if (Test-Path -LiteralPath $f) {
                    $kind = $script:JobWatches[$f]
                    $script:JobWatches.Remove($f)
                    Complete-JobWatch $kind $f
                }
            }
            if ($script:JobWatches.Count -eq 0) { $script:JobTimer.Stop() }
        })
    }
    $script:JobTimer.Start()
}

function Complete-JobWatch([string]$Kind, [string]$File) {
    switch ($Kind) {
        'install' { Write-Log 'App job finished. Refreshing install status...'; Build-InstallList }
        'adk'     { Write-Log 'ADK install finished.'; Update-IsoToolStatus }
        'iso'     { Complete-IsoBuild $File }
    }
}

function Save-InstallBundle {
    $keys = @(Get-SelectedInstall | ForEach-Object { $_.Key })
    if (-not $keys.Count) { [void](Show-Message 'Tick the apps you want in the bundle first.'); return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("Name for a bundle of these $($keys.Count) apps (saved in %LOCALAPPDATA%\DebloatTool\custom-bundles.json):", 'Save bundle', 'My apps')
    if (-not $name.Trim()) { return }
    Save-CustomBundle $name.Trim() $keys
    Build-InstallBundles
    Build-IsoBundleChecks
    Write-Log "Saved bundle '$($name.Trim())' with $($keys.Count) app(s)."
}

#endregion
#region ISO Builder page -----------------------------------------------------

function New-Radio([string]$Text, $Tag, [string]$Group, [bool]$Checked) {
    $r = New-Object System.Windows.Controls.RadioButton
    $r.Content = $Text; $r.Tag = $Tag; $r.GroupName = $Group; $r.IsChecked = $Checked
    $r.Foreground = Brush '#E6E8EE'; $r.Margin = '0,0,18,6'; $r.Cursor = 'Hand'
    $r
}

function Initialize-IsoPage {
    $script:UI.IsoUser.Text = $env:USERNAME
    $script:UI.IsoComputer.Text = $env:COMPUTERNAME
    $script:UI.IsoOutput.Text = Join-Path $env:USERPROFILE 'DebloatTool-ISO'
    $iso = Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads') -Filter '*.iso' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'win' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($iso) { $script:UI.IsoPath.Text = $iso.FullName }
    $script:UI.IsoInfo.Text = $(if ($iso) { 'Found an ISO in your Downloads folder. Click Browse to pick a different one.' } else { 'Download the official Windows 11 ISO ("Download Windows 11 Disk Image") from Microsoft, then pick it here.' })

    $script:UI.IsoPresets.Children.Clear()
    [void]$script:UI.IsoPresets.Children.Add((New-Radio 'None' '' 'isopreset' $false))
    foreach ($p in $script:Presets) { [void]$script:UI.IsoPresets.Children.Add((New-Radio $p.name $p.name 'isopreset' ($p.name -eq 'Gaming'))) }

    Build-IsoBundleChecks
    Update-IsoToolStatus
    $script:IsoEditionsFor = $null
}

function Build-IsoBundleChecks {
    $checked = @()
    foreach ($c in $script:UI.IsoBundles.Children) { if ($c.IsChecked) { $checked += $c.Tag } }
    if (-not $script:UI.IsoBundles.Children.Count) {
        # First visit: tick your own bundles if you have any, otherwise the basics.
        $checked = @($script:InstallBundles | Where-Object { $_.custom } | ForEach-Object { $_.name })
        if (-not $checked.Count) { $checked = @('Fresh install essentials') }
    }
    $script:UI.IsoBundles.Children.Clear()
    foreach ($b in $script:InstallBundles) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($b.name) ($(@($b.apps).Count))"; $cb.Tag = $b.name; $cb.ToolTip = $b.description
        $cb.Margin = '0,0,18,6'; $cb.IsChecked = ($checked -contains $b.name)
        [void]$script:UI.IsoBundles.Children.Add($cb)
    }
}

function Update-IsoToolStatus {
    $p = Get-OscdimgPath
    if ($p) {
        $script:UI.IsoToolStatus.Text = 'ISO tool ready (oscdimg from the Windows ADK).'
        $script:UI.IsoInstallAdk.Visibility = 'Collapsed'
    } else {
        $script:UI.IsoToolStatus.Text = 'Needs Microsoft''s free ISO tool (oscdimg, part of the Windows ADK Deployment Tools, about 100 MB). Click Install, it takes a minute or two.'
        $script:UI.IsoInstallAdk.Visibility = 'Visible'
    }
}

function Read-IsoEditions {
    $path = $script:UI.IsoPath.Text.Trim('"', ' ')
    $script:UI.IsoEditions.Children.Clear()
    $script:IsoEditionList = @()
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { $script:UI.IsoInfo.Text = 'ISO file not found.'; return }
    if (-not $script:IsAdmin) { $script:UI.IsoInfo.Text = 'Reading the ISO needs administrator rights. Restart DebloatTool as administrator.'; return }
    $script:UI.IsoInfo.Text = 'Reading editions from the ISO...'
    Set-Busy $true
    try {
        $script:IsoEditionList = @(Get-IsoEditions $path)
        $script:IsoEditionsFor = $path
    } catch {
        $script:UI.IsoInfo.Text = "Could not read the ISO: $($_.Exception.Message)"
        return
    } finally { Set-Busy $false }
    $first = $script:IsoEditionList | Select-Object -First 1
    $script:UI.IsoInfo.Text = "Windows build $($first.Build), language $($first.Language). Pick the edition to install (Pro matches your current PC):"
    $pick = ($script:IsoEditionList | Where-Object { $_.Name -eq 'Windows 11 Pro' } | Select-Object -First 1)
    if (-not $pick) { $pick = $first }
    foreach ($e in $script:IsoEditionList) {
        [void]$script:UI.IsoEditions.Children.Add((New-Radio $e.Name $e 'edition' ($e.Index -eq $pick.Index)))
    }
    Write-Log "ISO has $($script:IsoEditionList.Count) edition(s)."
}

function Get-IsoSettingsFromUi {
    $edition = $script:UI.IsoEditions.Children | Where-Object { $_.IsChecked } | Select-Object -First 1
    $preset = $script:UI.IsoPresets.Children | Where-Object { $_.IsChecked } | Select-Object -First 1
    $bundles = @($script:UI.IsoBundles.Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    $unattend = [bool]$script:UI.OptUnattend.IsChecked
    $presetName = $(if ($preset) { [string]$preset.Tag } else { '' })
    $inputLocale = '0409:00000409'
    try { $inputLocale = @((Get-WinUserLanguageList)[0].InputMethodTips)[0] } catch { }
    [pscustomobject]@{
        IsoPath           = $script:UI.IsoPath.Text.Trim('"', ' ')
        EditionIndex      = $(if ($edition) { $edition.Tag.Index } else { $null })
        EditionName       = $(if ($edition) { $edition.Tag.Name } else { $null })
        Language          = $(if ($edition) { $edition.Tag.Language } else { 'en-US' })
        Locale            = (Get-Culture).Name
        InputLocale       = $inputLocale
        TimeZone          = (Get-TimeZone).Id
        OutputDir         = $script:UI.IsoOutput.Text.Trim('"', ' ').TrimEnd('\')
        RemoveApps        = [bool]$script:UI.OptRemoveApps.IsChecked
        InjectDrivers     = [bool]$script:UI.OptDrivers.IsChecked
        IncludeGraphics   = [bool]$script:UI.OptGraphics.IsChecked
        PreventEncryption = [bool]$script:UI.OptEncryption.IsChecked
        Unattend          = $unattend
        UserName          = $script:UI.IsoUser.Text.Trim()
        Password          = $script:UI.IsoPassword.Password
        ComputerName      = $script:UI.IsoComputer.Text.Trim()
        Preset            = $presetName
        Bundles           = $bundles
        FirstBoot         = ($unattend -and ($presetName -or $bundles.Count))
        DoneFile          = $null
    }
}

function Start-IsoBuild {
    if ($script:IsoEditionsFor -ne $script:UI.IsoPath.Text.Trim('"', ' ')) { Read-IsoEditions }
    $s = Get-IsoSettingsFromUi
    $problems = @(Test-IsoSettings $s)
    if ($problems.Count) { [void](Show-Message ("Fix these first:`n`n- " + ($problems -join "`n- ")) 'OK' 'Warning'); return }

    $summary = @(
        "Edition: $($s.EditionName)"
        "Remove bloat apps: $(if ($s.RemoveApps) { 'yes' } else { 'no' })"
        "Add this PC's drivers: $(if ($s.InjectDrivers) { if ($s.IncludeGraphics) { 'yes, including graphics' } else { 'yes (graphics left out)' } } else { 'no' })"
        "Skip setup screens: $(if ($s.Unattend) { "yes - local admin account '$($s.UserName)', PC name $($s.ComputerName)" } else { 'no' })"
        "First sign-in preset: $(if ($s.Preset -and $s.Unattend) { $s.Preset } else { 'none' })"
        "Install bundles: $(if ($s.Bundles.Count -and $s.Unattend) { $s.Bundles -join ', ' } else { 'none' })"
        "Save to: $($s.OutputDir)"
    ) -join "`n"
    if (-not $s.Unattend -and ($s.Preset -or $s.Bundles.Count)) { $summary += "`n`nNote: the first sign-in preset and apps need step 3 (skip setup screens) turned on, so they will be skipped." }
    $summary += "`n`nThis takes 15-40 minutes in a separate window and needs about $($script:IsoMinFreeGB) GB of temporary space. Start now?"
    if ((Show-Message $summary 'YesNo' 'Question') -ne 'Yes') { return }

    $jobs = Join-Path $script:DataDir 'jobs'
    if (-not (Test-Path $jobs)) { New-Item -ItemType Directory -Path $jobs -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $s.DoneFile = Join-Path $jobs "iso-$stamp.done"
    $settingsPath = Join-Path $jobs "iso-$stamp.json"
    if (-not (Test-Path $s.OutputDir)) { New-Item -ItemType Directory -Path $s.OutputDir -Force | Out-Null }
    [IO.File]::WriteAllText($settingsPath, (ConvertTo-Json $s -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $script:Root 'src\IsoBuildJob.ps1')`"", '-SettingsPath', "`"$settingsPath`""
    $script:UI.IsoBuildBtn.IsEnabled = $false
    $script:UI.IsoBuildStatus.Text = "Building... follow progress in the other window. Started $(Get-Date -Format 'HH:mm')."
    Write-Log 'ISO build started in a separate window.'
    Start-JobWatch $s.DoneFile 'iso'
}

function Complete-IsoBuild([string]$File) {
    $script:UI.IsoBuildBtn.IsEnabled = $true
    $r = $null
    try { $r = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json } catch { }
    if ($r -and $r.ok) {
        $script:UI.IsoBuildStatus.Text = "Done in $($r.minutes) min: $($r.iso). Write it to a USB stick (16 GB or larger) with Rufus. Choose GPT and leave Rufus' own Windows customisation options unticked."
        Write-Log "ISO ready: $($r.iso)"
    } else {
        $err = $(if ($r) { $r.error } else { 'unknown error' })
        $script:UI.IsoBuildStatus.Text = "Build failed: $err"
        Write-Log "ISO build failed: $err"
    }
}

#endregion
#region Startup page ---------------------------------------------------------

function Build-StartupList {
    $list = $script:UI.StartupList
    $list.Children.Clear()
    $items = @(Get-StartupItems | Sort-Object @{ Expression = { -not $_.Enabled } }, Name)
    foreach ($it in $items) {
        $dock = New-Object System.Windows.Controls.DockPanel
        $label = $(if ($it.Enabled) { 'Disable' } else { 'Enable' })
        $btn = New-Button $label $it
        $btn.Margin = '12,0,0,0'; $btn.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        $btn.Add_Click({ param($s, $e) Switch-StartupItem $s.Tag })
        [void]$dock.Children.Add($btn)

        $stack = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.StackPanel
        $title.Orientation = 'Horizontal'
        [void]$title.Children.Add((New-Text $it.Name 14 '#F2F4F8' 'SemiBold'))
        if ($it.Enabled) { [void]$title.Children.Add((New-Badge 'Enabled' '#1D3A2A' '#62D394')) }
        else { [void]$title.Children.Add((New-Badge 'Disabled' '#23272F' '#8A91A3')) }
        [void]$stack.Children.Add($title)
        $cmd = $it.Command
        if ($cmd.Length -gt 160) { $cmd = $cmd.Substring(0, 157) + '...' }
        [void]$stack.Children.Add((New-Text $cmd 11.5 '#9AA1B2' 'Normal' '0,3,0,0'))
        [void]$stack.Children.Add((New-Text $it.Location 11.5 '#6F7790' 'Normal' '0,2,0,0'))
        [void]$dock.Children.Add($stack)
        [void]$list.Children.Add((New-Card $dock))
    }
    if (-not $items.Count) { [void]$list.Children.Add((New-Text 'No startup programs found.' 13 '#8A91A3')) }
    $script:StartupItems = $items
}

function Switch-StartupItem($Item) {
    $enable = -not $Item.Enabled
    try {
        $r = Set-StartupItemEnabled $Item $enable
        foreach ($e in $r.Errors) { Write-Log "  ! $e" }
        Write-Log ("{0} at startup: {1}" -f $(if ($enable) { 'Enabled' } else { 'Disabled' }), $Item.Name)
    } catch { Write-Log "  ! $($_.Exception.Message)" }
    Build-StartupList
    Build-HistoryList
    Update-Dashboard
}

#endregion
#region Settings page --------------------------------------------------------

function New-Pill([string]$Text, [string]$Group, [bool]$Checked, $Tag) {
    $r = New-Object System.Windows.Controls.RadioButton
    $r.Content = $Text; $r.GroupName = $Group; $r.IsChecked = $Checked; $r.Tag = $Tag
    $r.Style = $script:Window.FindResource('Pill')
    $r
}

function New-Field([string]$Label, [string]$Value, [double]$Width = 150) {
    $s = New-Object System.Windows.Controls.StackPanel
    $s.Margin = '0,0,10,6'
    [void]$s.Children.Add((New-Text $Label 11.5 '#8A91A3' 'Normal' '0,0,0,3'))
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = $Value; $tb.Width = $Width
    [void]$s.Children.Add($tb)
    @($s, $tb)
}

function Build-SettingsList {
    $list = $script:UI.SettingsList
    $list.Children.Clear()
    $script:SettingCards = @{}; $script:SettingHeaders = @{}
    Set-Busy $true
    try {
        $h = New-Header 'PC name & domain'
        $script:IdPanel = New-Object System.Windows.Controls.StackPanel
        [void]$list.Children.Add($h)
        [void]$list.Children.Add($script:IdPanel)
        $script:SettingHeaders['PC name & domain'] = @($h, $script:IdPanel)
        Build-IdentitySection

        $h = New-Header 'Network'
        $script:NetPanel = New-Object System.Windows.Controls.StackPanel
        [void]$list.Children.Add($h)
        [void]$list.Children.Add($script:NetPanel)
        $script:SettingHeaders['Network'] = @($h, $script:NetPanel)
        Build-NetworkSection

        # Sound: the device list, then the Sound settings from the catalog under the same header.
        $h = New-Header 'Sound'
        $soundPanel = New-Object System.Windows.Controls.StackPanel
        $script:SoundDevPanel = New-Object System.Windows.Controls.StackPanel
        [void]$soundPanel.Children.Add($script:SoundDevPanel)
        Build-SoundSection
        foreach ($s in @($script:SettingsCatalog | Where-Object { $_.category -eq 'Sound' })) { [void]$soundPanel.Children.Add((New-SettingCard $s)) }
        [void]$list.Children.Add($h)
        [void]$list.Children.Add($soundPanel)
        $script:SettingHeaders['Sound'] = @($h, $soundPanel)

        foreach ($cat in $script:SettingsCategories) {
            if ($cat -eq 'Sound') { continue }
            $items = @($script:SettingsCatalog | Where-Object { $_.category -eq $cat })
            if (-not $items.Count) { continue }
            $h = New-Header $cat
            $panel = New-Object System.Windows.Controls.StackPanel
            foreach ($s in $items) { [void]$panel.Children.Add((New-SettingCard $s)) }
            [void]$list.Children.Add($h)
            [void]$list.Children.Add($panel)
            $script:SettingHeaders[$cat] = @($h, $panel)
        }
    } finally { Set-Busy $false }
    $script:SettingsLoaded = $true
    Update-SettingsFilter
}

function New-SettingCard($Setting) {
    $stack = New-Object System.Windows.Controls.StackPanel
    [void]$stack.Children.Add((New-Text $Setting.name 14 '#F2F4F8' 'SemiBold'))
    [void]$stack.Children.Add((New-Text $Setting.description 12.5 '#9AA1B2' 'Normal' '0,3,0,8'))
    $pills = New-Object System.Windows.Controls.WrapPanel
    $refs = @{}
    foreach ($o in @($Setting.options)) {
        $p = New-Pill $o.label "set-$($Setting.id)" $false ([pscustomobject]@{ Setting = $Setting; Option = $o })
        $p.Add_Click({ param($s, $e) Invoke-SettingClick $s.Tag.Setting $s.Tag.Option })
        $refs[$o.label] = $p
        [void]$pills.Children.Add($p)
    }
    [void]$stack.Children.Add($pills)
    $note = New-Text '' 11.5 '#6F7790' 'Normal' '0,2,0,0'
    [void]$stack.Children.Add($note)
    $card = New-Card $stack
    $script:SettingCards[$Setting.id] = [pscustomobject]@{ Card = $card; Setting = $Setting; Pills = $refs; Note = $note; Current = $null }
    Update-SettingCard $Setting
    $card
}

function Update-SettingCard($Setting) {
    $c = $script:SettingCards[$Setting.id]
    $cur = $null
    try { $cur = Get-SettingCurrent $Setting } catch { }
    $c.Current = $(if ($cur) { $cur.label } else { $null })
    foreach ($k in @($c.Pills.Keys)) { $c.Pills[$k].IsChecked = ($k -eq $c.Current) }
    $after = @(Get-Items $Setting 'after' | ForEach-Object { $script:AfterText[$_] })
    $parts = @()
    if (-not $c.Current) { $parts += 'Set to something else right now.' }
    if ($after) { $parts += "Takes effect after $($after -join ' / ')." }
    $c.Note.Text = $parts -join ' '
    $c.Note.Visibility = $(if ($parts) { 'Visible' } else { 'Collapsed' })
}

function Invoke-SettingClick($Setting, $Option) {
    $c = $script:SettingCards[$Setting.id]
    if ($c.Current -eq $Option.label) { return }
    if (-not $script:IsAdmin) {
        [void](Show-Message 'Changing settings needs administrator rights. Close DebloatTool and open it again with Run.bat.')
        Update-SettingCard $Setting
        return
    }
    Write-Log "Setting: $($Setting.name) -> $($Option.label)"
    Set-Busy $true
    try {
        $r = Set-SettingOption $Setting $Option
        foreach ($e in $r.Errors) { Write-Log "  ! $e" }
        if (-not $r.Errors.Count) { Write-Log '  done (saved to History)' }
    } catch { Write-Log "  ! $($_.Exception.Message)" }
    finally { Set-Busy $false }
    Update-SettingCard $Setting
    $after = @(Get-Items $Setting 'after')
    if ($after -contains 'explorer') {
        if ((Show-Message 'This change needs File Explorer and the taskbar to restart. Restart them now? Open Explorer windows will close.' 'YesNo' 'Question') -eq 'Yes') {
            Restart-Explorer; Write-Log 'File Explorer restarted.'
        }
    }
}

function Update-SettingsFilter {
    if (-not $script:SettingsLoaded) { return }
    $q = $script:UI.SettingsSearch.Text.Trim()
    $visible = @{}
    foreach ($c in $script:SettingCards.Values) {
        $hay = "$($c.Setting.name) $($c.Setting.description) $($c.Setting.category) $(@($c.Setting.options | ForEach-Object { $_.label }) -join ' ')"
        $show = (-not $q) -or $hay.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
        $c.Card.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
        if ($show) { $visible[$c.Setting.category] = $true }
    }
    $netWords = 'Network IP address DNS gateway subnet static DHCP Ethernet Wi-Fi adapter'
    $visible['Network'] = (-not $q) -or $netWords.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
    $idWords = 'PC name computer name rename hostname domain join workgroup Active Directory sysdm'
    $visible['PC name & domain'] = (-not $q) -or $idWords.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
    $soundWords = 'Sound audio speakers headphones headset microphone mic playback recording output input default device disable turn off HDMI'
    $soundDev = (-not $q) -or $soundWords.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
    if ($script:SoundDevPanel) { $script:SoundDevPanel.Visibility = $(if ($soundDev) { 'Visible' } else { 'Collapsed' }) }
    $visible['Sound'] = $visible['Sound'] -or $soundDev
    foreach ($k in @($script:SettingHeaders.Keys)) {
        $v = $(if ($visible[$k]) { 'Visible' } else { 'Collapsed' })
        foreach ($el in $script:SettingHeaders[$k]) { $el.Visibility = $v }
    }
}

function Build-IdentitySection {
    $panel = $script:IdPanel
    $panel.Children.Clear()
    try { $id = Get-ComputerIdentity }
    catch { [void]$panel.Children.Add((New-Card (New-Text "Could not read the PC name: $($_.Exception.Message)" 12.5 '#FF7A85'))); return }
    $ctl = @{ Id = $id }
    $script:IdCtl = $ctl
    $stack = New-Object System.Windows.Controls.StackPanel

    $now = "Now: $($id.Name), $(if ($id.InDomain) { "domain $($id.Domain)" } else { "workgroup $($id.Workgroup)" })"
    [void]$stack.Children.Add((New-Text $now 14 '#F2F4F8' 'SemiBold'))
    if ($id.PendingName) { [void]$stack.Children.Add((New-Text "Renames to $($id.PendingName) after a restart." 12.5 '#F2C14E' 'Normal' '0,3,0,0')) }
    [void]$stack.Children.Add((New-Text 'Like the Computer Name tab in System Properties. Every change here takes effect after a restart.' 12.5 '#9AA1B2' 'Normal' '0,3,0,10'))

    # Rename
    [void]$stack.Children.Add((New-Text 'PC name' 12.5 '#C9CEDA' 'SemiBold' '0,0,0,4'))
    $row = New-Object System.Windows.Controls.WrapPanel
    $f = New-Field 'New name (up to 15 letters, numbers, hyphens)' $(if ($id.PendingName) { $id.PendingName } else { $id.Name }) 220
    $ctl.Name = $f[1]
    [void]$row.Children.Add($f[0])
    $rename = New-Button 'Rename' $null
    $rename.VerticalAlignment = 'Bottom'; $rename.Margin = '0,0,8,6'
    $rename.IsEnabled = -not $id.InDomain
    $rename.Add_Click({ Invoke-IdentityRename })
    [void]$row.Children.Add($rename)
    [void]$stack.Children.Add($row)
    if ($id.InDomain) { [void]$stack.Children.Add((New-Text 'In a domain, rename while joining or leaving so the domain account changes too.' 11.5 '#6F7790' 'Normal' '0,0,0,6')) }

    # Workgroup or domain
    [void]$stack.Children.Add((New-Text 'Member of' 12.5 '#C9CEDA' 'SemiBold' '0,6,0,4'))
    $pills = New-Object System.Windows.Controls.WrapPanel
    $ctl.WgPill = New-Pill 'Workgroup' 'id-member' (-not $id.InDomain) $null
    $ctl.DomPill = New-Pill 'Domain' 'id-member' $id.InDomain $null
    foreach ($p in $ctl.WgPill, $ctl.DomPill) { $p.Add_Click({ Update-IdentityFields }); [void]$pills.Children.Add($p) }
    [void]$stack.Children.Add($pills)

    $wg = New-Object System.Windows.Controls.WrapPanel
    $f = New-Field 'Workgroup name' $(if ($id.Workgroup) { $id.Workgroup } else { 'WORKGROUP' })
    $ctl.Workgroup = $f[1]
    [void]$wg.Children.Add($f[0])
    $wgBtn = New-Button $(if ($id.InDomain) { 'Leave domain and join workgroup' } else { 'Join workgroup' }) $null
    $wgBtn.VerticalAlignment = 'Bottom'; $wgBtn.Margin = '0,0,8,6'
    $wgBtn.Add_Click({ Invoke-IdentityWorkgroup })
    [void]$wg.Children.Add($wgBtn)
    $ctl.WgFields = $wg
    [void]$stack.Children.Add($wg)

    $dom = New-Object System.Windows.Controls.StackPanel
    $dRow = New-Object System.Windows.Controls.WrapPanel
    $f = New-Field 'Domain (for example corp.example.com)' $(if ($id.Domain) { $id.Domain } else { '' }) 240
    $ctl.Domain = $f[1]
    [void]$dRow.Children.Add($f[0])
    $f = New-Field 'OU (optional, for example OU=PCs,DC=corp,DC=example,DC=com)' '' 340
    $ctl.OU = $f[1]
    [void]$dRow.Children.Add($f[0])
    $domBtn = New-Button 'Join domain' $null 'AccentBtn'
    $domBtn.VerticalAlignment = 'Bottom'; $domBtn.Margin = '0,0,8,6'
    $domBtn.IsEnabled = $id.CanJoin -and -not $id.InDomain
    $domBtn.Add_Click({ Invoke-IdentityDomain })
    [void]$dRow.Children.Add($domBtn)
    [void]$dom.Children.Add($dRow)
    $hint = $(if (-not $id.CanJoin) { "$($id.Edition) can't join a domain. Windows Pro or higher is needed." }
              elseif ($id.InDomain) { "Already in $($id.Domain). To change domains, leave it first (pick Workgroup)." }
              else { "You'll be asked for a domain account that is allowed to add PCs. If the name above is different, the PC is renamed as it joins. This can't be undone from History." })
    [void]$dom.Children.Add((New-Text $hint 11.5 '#6F7790' 'Normal' '0,0,0,4'))
    $ctl.DomFields = $dom
    [void]$stack.Children.Add($dom)

    [void]$panel.Children.Add((New-Card $stack))
    Update-IdentityFields
}

function Update-IdentityFields {
    $ctl = $script:IdCtl
    if (-not $ctl) { return }
    $ctl.WgFields.Visibility = $(if ($ctl.WgPill.IsChecked) { 'Visible' } else { 'Collapsed' })
    $ctl.DomFields.Visibility = $(if ($ctl.DomPill.IsChecked) { 'Visible' } else { 'Collapsed' })
}

function Confirm-IdentityRestart([string]$Summary) {
    Write-Log "  $Summary"
    if ((Show-Message "$Summary`n`nRestart now to finish? Save your work in other apps first." 'YesNo' 'Question') -eq 'Yes' -and -not $script:SmokeDir) {
        Restart-Computer -Force
    }
}

function Invoke-IdentityRename {
    if (-not $script:IsAdmin) { [void](Show-Message 'Renaming the PC needs administrator rights.'); return }
    $name = $script:IdCtl.Name.Text.Trim()
    $errs = @(Test-ComputerNameText $name)
    if ($errs.Count) { [void](Show-Message ($errs -join "`n") 'OK' 'Warning'); return }
    if ((Show-Message "Rename this PC to $name? It takes effect after a restart." 'YesNo' 'Question') -ne 'Yes') { return }
    Write-Log "PC name -> $name"
    $ok = $false
    Set-Busy $true
    try { [void](Set-ComputerNameRecorded $name); $ok = $true } catch { Write-Log "  ! $($_.Exception.Message)"; [void](Show-Message $_.Exception.Message 'OK' 'Warning') }
    finally { Set-Busy $false }
    Build-IdentitySection
    if ($ok) { Confirm-IdentityRestart "The PC will be called $name after a restart (saved to History)." }
}

function Invoke-IdentityWorkgroup {
    if (-not $script:IsAdmin) { [void](Show-Message 'This needs administrator rights.'); return }
    $id = $script:IdCtl.Id
    $wg = $script:IdCtl.Workgroup.Text.Trim()
    $errs = @(Test-WorkgroupText $wg)
    if ($errs.Count) { [void](Show-Message ($errs -join "`n") 'OK' 'Warning'); return }
    $summary = $null
    if ($id.InDomain) {
        $msg = "Leave the $($id.Domain) domain and join the $wg workgroup?`n`nDomain accounts will no longer be able to sign in to this PC. Make sure you know the password of a local administrator account first. You'll be asked for a domain account (Cancel to try without one)."
        if ((Show-Message $msg 'YesNo' 'Warning') -ne 'Yes') { return }
        $cred = $null
        try { $cred = Get-Credential -Message "Domain account that can remove PCs from $($id.Domain)" } catch { }
        Write-Log "Leaving $($id.Domain) -> workgroup $wg"
        Set-Busy $true
        try { $summary = Remove-DomainJoin $wg $cred } catch { Write-Log "  ! $($_.Exception.Message)"; [void](Show-Message $_.Exception.Message 'OK' 'Warning') }
        finally { Set-Busy $false }
    } else {
        if ((Show-Message "Move this PC to the $wg workgroup? It takes effect after a restart." 'YesNo' 'Question') -ne 'Yes') { return }
        Write-Log "Workgroup -> $wg"
        Set-Busy $true
        try { [void](Set-WorkgroupRecorded $wg); $summary = "The PC joins the $wg workgroup after a restart (saved to History)." }
        catch { Write-Log "  ! $($_.Exception.Message)"; [void](Show-Message $_.Exception.Message 'OK' 'Warning') }
        finally { Set-Busy $false }
    }
    Build-IdentitySection
    if ($summary) { Confirm-IdentityRestart $summary }
}

function Invoke-IdentityDomain {
    if (-not $script:IsAdmin) { [void](Show-Message 'Joining a domain needs administrator rights.'); return }
    $ctl = $script:IdCtl
    $domain = $ctl.Domain.Text.Trim()
    $name = $ctl.Name.Text.Trim()
    $errs = @(Test-DomainText $domain) + @(Test-ComputerNameText $name)
    if ($errs.Count) { [void](Show-Message ($errs -join "`n") 'OK' 'Warning'); return }
    $as = $(if ($name -ne $ctl.Id.Name) { " as $name" } else { '' })
    if ((Show-Message "Join this PC to $domain$as?`n`nThis PC must be able to reach the domain's DNS and a domain controller. This can't be undone from History; to undo it, leave the domain here." 'YesNo' 'Question') -ne 'Yes') { return }
    $cred = $null
    try { $cred = Get-Credential -Message "Domain account that can add PCs to $domain (DOMAIN\user)" } catch { }
    if (-not $cred) { Write-Log 'Join domain cancelled.'; return }
    Write-Log "Joining $domain$as"
    $summary = $null
    Set-Busy $true
    try { $summary = Add-DomainJoin $domain $cred $ctl.OU.Text $name } catch { Write-Log "  ! $($_.Exception.Message)"; [void](Show-Message $_.Exception.Message 'OK' 'Warning') }
    finally { Set-Busy $false }
    Build-IdentitySection
    if ($summary) { Confirm-IdentityRestart $summary }
}

function Build-NetworkSection {
    $panel = $script:NetPanel
    $panel.Children.Clear()
    $script:NetControls = @()
    $adapters = @(Get-NetAdapterList)
    if (-not $adapters.Count) { [void]$panel.Children.Add((New-Text 'No network adapters found.' 13 '#8A91A3')); return }
    foreach ($a in $adapters) {
        try { [void]$panel.Children.Add((New-NetAdapterCard $a)) }
        catch { [void]$panel.Children.Add((New-Card (New-Text "$($a.Name): could not read its settings ($($_.Exception.Message))" 12.5 '#FF7A85'))) }
    }
}

function New-NetAdapterCard($Adapter) {
    $cfg = Get-NetAdapterConfig $Adapter
    $g = "net-$($cfg.guid)"
    $ctl = @{ Config = $cfg }
    $stack = New-Object System.Windows.Controls.StackPanel

    $title = New-Object System.Windows.Controls.WrapPanel
    $name = New-Text $cfg.name 14 '#F2F4F8' 'SemiBold'
    [void]$title.Children.Add($name)
    $up = $cfg.status -eq 'Up'
    [void]$title.Children.Add($(if ($up) { New-Badge 'Connected' '#1D3A2A' '#62D394' } else { New-Badge $cfg.status '#23272F' '#8A91A3' }))
    [void]$stack.Children.Add($title)
    [void]$stack.Children.Add((New-Text $cfg.description 12 '#8A91A3' 'Normal' '0,2,0,0'))
    $now = Format-NetConfig $cfg
    if ($cfg.dhcp -and $cfg.ip) { $now += "  (got $($cfg.ip)/$($cfg.prefix)$(if ($cfg.gateway) { ", gateway $($cfg.gateway)" }))" }
    if (-not $cfg.dnsStatic -and @($cfg.dns).Count) { $now += "  (DNS in use: $(@($cfg.dns) -join ', '))" }
    [void]$stack.Children.Add((New-Text "Now: $now" 12.5 '#9AA1B2' 'Normal' '0,4,0,10'))

    # IP address
    [void]$stack.Children.Add((New-Text 'IP address' 12.5 '#C9CEDA' 'SemiBold' '0,0,0,4'))
    $ipPills = New-Object System.Windows.Controls.WrapPanel
    $ctl.IpAuto = New-Pill 'Automatic (DHCP)' "$g-ip" $cfg.dhcp $null
    $ctl.IpStatic = New-Pill 'Static' "$g-ip" (-not $cfg.dhcp) $null
    [void]$ipPills.Children.Add($ctl.IpAuto); [void]$ipPills.Children.Add($ctl.IpStatic)
    [void]$stack.Children.Add($ipPills)
    $ipFields = New-Object System.Windows.Controls.WrapPanel
    $ipFields.Margin = '0,2,0,6'
    $f1 = New-Field 'IP address' $cfg.ip; $ctl.Ip = $f1[1]
    $mask = $(if ($cfg.prefix) { ConvertTo-SubnetMask $cfg.prefix } else { '255.255.255.0' })
    $f2 = New-Field 'Subnet mask' $mask; $ctl.Mask = $f2[1]
    $f3 = New-Field 'Gateway (router)' $cfg.gateway; $ctl.Gw = $f3[1]
    foreach ($f in $f1, $f2, $f3) { [void]$ipFields.Children.Add($f[0]) }
    $ctl.IpFields = $ipFields
    [void]$stack.Children.Add($ipFields)

    # DNS
    [void]$stack.Children.Add((New-Text 'DNS servers' 12.5 '#C9CEDA' 'SemiBold' '0,4,0,4'))
    $preset = $(if ($cfg.dnsStatic) { Get-DnsPresetName @($cfg.dns) } else { $null })
    $dnsPills = New-Object System.Windows.Controls.WrapPanel
    $ctl.DnsAuto = New-Pill 'Automatic' "$g-dns" (-not $cfg.dnsStatic) $null
    [void]$dnsPills.Children.Add($ctl.DnsAuto)
    $ctl.DnsPresets = @{}
    foreach ($k in $script:DnsPresets.Keys) {
        $p = New-Pill "$k ($($script:DnsPresets[$k][0]))" "$g-dns" ($preset -eq $k) $k
        $ctl.DnsPresets[$k] = $p
        [void]$dnsPills.Children.Add($p)
    }
    $ctl.DnsCustom = New-Pill 'Custom' "$g-dns" ($cfg.dnsStatic -and -not $preset) $null
    [void]$dnsPills.Children.Add($ctl.DnsCustom)
    [void]$stack.Children.Add($dnsPills)
    $dnsFields = New-Object System.Windows.Controls.WrapPanel
    $dnsFields.Margin = '0,2,0,6'
    $cur = @($cfg.dns)
    $d1 = New-Field 'Preferred DNS' $(if ($cfg.dnsStatic -and $cur.Count -ge 1) { $cur[0] } else { '' }); $ctl.Dns1 = $d1[1]
    $d2 = New-Field 'Alternate DNS' $(if ($cfg.dnsStatic -and $cur.Count -ge 2) { $cur[1] } else { '' }); $ctl.Dns2 = $d2[1]
    [void]$dnsFields.Children.Add($d1[0]); [void]$dnsFields.Children.Add($d2[0])
    $ctl.DnsFields = $dnsFields
    [void]$stack.Children.Add($dnsFields)

    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,6,0,0'
    $apply = New-Button 'Apply' $ctl 'AccentBtn'
    $apply.Add_Click({ param($s, $e) Invoke-NetApply $s.Tag })
    [void]$bar.Children.Add($apply)
    [void]$bar.Children.Add((New-Text 'You get 30 seconds to keep the change, otherwise it is undone.' 11.5 '#6F7790' 'Normal' '6,8,0,0'))
    [void]$stack.Children.Add($bar)

    foreach ($p in @($ctl.IpAuto, $ctl.IpStatic, $ctl.DnsAuto, $ctl.DnsCustom) + @($ctl.DnsPresets.Values)) {
        $p.Add_Click({ Update-NetFieldState })
    }
    $script:NetControls = @($script:NetControls | Where-Object { $_.Config.guid -ne $cfg.guid }) + $ctl
    Update-NetFieldState
    New-Card $stack
}

function Update-NetFieldState {
    foreach ($ctl in @($script:NetControls)) {
        if (-not $ctl) { continue }
        $ctl.IpFields.IsEnabled = [bool]$ctl.IpStatic.IsChecked
        $ctl.DnsFields.IsEnabled = [bool]$ctl.DnsCustom.IsChecked
        $ctl.IpFields.Opacity = $(if ($ctl.IpFields.IsEnabled) { 1 } else { 0.45 })
        $ctl.DnsFields.Opacity = $(if ($ctl.DnsFields.IsEnabled) { 1 } else { 0.45 })
    }
}

function Get-NetTargetFromUi($Ctl) {
    $cfg = $Ctl.Config
    $dhcp = [bool]$Ctl.IpAuto.IsChecked
    $dns = @()
    $dnsStatic = -not $Ctl.DnsAuto.IsChecked
    if ($Ctl.DnsCustom.IsChecked) { $dns = @($Ctl.Dns1.Text.Trim(), $Ctl.Dns2.Text.Trim() | Where-Object { $_ }) }
    else { foreach ($k in @($Ctl.DnsPresets.Keys)) { if ($Ctl.DnsPresets[$k].IsChecked) { $dns = @($script:DnsPresets[$k]) } } }
    [pscustomobject]@{
        guid = $cfg.guid; name = $cfg.name; description = $cfg.description; status = $cfg.status
        dhcp = $dhcp
        ip = $(if ($dhcp) { '' } else { $Ctl.Ip.Text.Trim() })
        prefix = $(if ($dhcp) { $null } else { ConvertTo-PrefixLength $Ctl.Mask.Text })
        gateway = $(if ($dhcp) { '' } else { $Ctl.Gw.Text.Trim() })
        dnsStatic = $dnsStatic
        dns = @($dns)
    }
}

function Invoke-NetApply($Ctl) {
    if (-not $script:IsAdmin) { [void](Show-Message 'Changing network settings needs administrator rights.'); return }
    $target = Get-NetTargetFromUi $Ctl
    $errs = @(Test-NetTarget $target)
    if ($errs.Count) { [void](Show-Message ($errs -join "`n") 'OK' 'Warning'); return }
    $from = Format-NetConfig $Ctl.Config
    $to = Format-NetConfig $target
    if ($from -eq $to) { Write-Log "$($target.name): nothing to change."; return }
    $msg = "Change $($target.name)?`n`nNow:  $from`nNew:  $to`n`nThe connection can drop for a few seconds. After the change you have 30 seconds to keep it; otherwise it is undone automatically."
    if ((Show-Message $msg 'YesNo' 'Question') -ne 'Yes') { return }
    Write-Log "Network: $($target.name) -> $to"
    $entry = $null
    Set-Busy $true
    try { $entry = Invoke-NetAdapterChange $target; Write-Log '  done (saved to History)' }
    catch { Write-Log "  ! $($_.Exception.Message)"; [void](Show-Message $_.Exception.Message 'OK' 'Warning') }
    finally { Set-Busy $false }
    if ($entry) {
        if (Show-KeepDialog 30 "Keep the new settings for $($target.name)?") { Write-Log '  kept' }
        else {
            Write-Log '  reverting...'
            Set-Busy $true
            try {
                $uerrs = @(Undo-JournalEntry $entry.id)
                foreach ($er in $uerrs) { Write-Log "  ! $er" }
                if (-not $uerrs.Count) { Write-Log '  previous settings restored' }
            } finally { Set-Busy $false }
        }
    }
    Build-NetworkSection
}

# "Keep these settings?" with a countdown. Anything but Keep (timeout, Revert, closing) reverts.
function Show-KeepDialog([int]$Seconds, [string]$Text) {
    if ($script:SmokeDir) { return $true }
    $w = New-Object System.Windows.Window
    $w.Title = 'DebloatTool'; $w.SizeToContent = 'WidthAndHeight'; $w.ResizeMode = 'NoResize'
    $w.Owner = $script:Window; $w.WindowStartupLocation = 'CenterOwner'
    $w.Background = Brush '#14161C'
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = '22'; $stack.MinWidth = 380
    [void]$stack.Children.Add((New-Text $Text 15 '#FFFFFF' 'SemiBold' '0,0,0,6'))
    $script:KeepLeft = $Seconds
    $script:KeepLabel = New-Text "Reverting in $Seconds seconds." 12.5 '#9AA1B2' 'Normal' '0,0,0,16'
    [void]$stack.Children.Add($script:KeepLabel)
    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.HorizontalAlignment = 'Right'
    $revert = New-Button 'Revert' $null
    $revert.Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
    $keep = New-Button 'Keep changes' $null 'AccentBtn'
    $keep.Margin = '0'
    $keep.Add_Click({ param($s, $e) $script:KeepResult = $true; [System.Windows.Window]::GetWindow($s).Close() })
    [void]$bar.Children.Add($revert); [void]$bar.Children.Add($keep)
    [void]$stack.Children.Add($bar)
    $w.Content = $stack
    $script:KeepResult = $false
    $script:KeepWindow = $w
    $script:KeepTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:KeepTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:KeepTimer.Add_Tick({
        $script:KeepLeft--
        $script:KeepLabel.Text = "Reverting in $($script:KeepLeft) seconds."
        if ($script:KeepLeft -le 0) { $script:KeepTimer.Stop(); $script:KeepWindow.Close() }
    })
    $w.Add_Closed({ $script:KeepTimer.Stop() })
    $script:KeepTimer.Start()
    [void]$w.ShowDialog()
    $script:KeepResult
}

function Build-SoundSection {
    $panel = $script:SoundDevPanel
    $panel.Children.Clear()
    $devices = @()
    try { $devices = @(Get-AudioDeviceList) }
    catch { [void]$panel.Children.Add((New-Card (New-Text "Could not read the sound devices: $($_.Exception.Message)" 12.5 '#FF7A85'))); return }
    foreach ($flow in 'Playback', 'Recording') {
        $items = @($devices | Where-Object { $_.flow -eq $flow })
        [void]$panel.Children.Add((New-Text "$flow devices" 12.5 '#C9CEDA' 'SemiBold' '2,2,0,6'))
        if (-not $items.Count) { [void]$panel.Children.Add((New-Text "No $($flow.ToLower()) devices found." 12.5 '#8A91A3' 'Normal' '2,0,0,8')); continue }
        foreach ($d in $items) { [void]$panel.Children.Add((New-AudioDeviceCard $d)) }
    }
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,0,0,10'
    $refresh = New-Button 'Refresh devices' $null
    $refresh.Add_Click({ Build-SoundSection })
    $classic = New-Button 'Open the classic Sound panel' $null
    $classic.Add_Click({ Start-Process control.exe 'mmsys.cpl' })
    [void]$bar.Children.Add($refresh); [void]$bar.Children.Add($classic)
    [void]$bar.Children.Add((New-Text 'Sample rate, exclusive mode and enhancements are in the classic Sound panel.' 11.5 '#6F7790' 'Normal' '6,8,0,0'))
    [void]$panel.Children.Add($bar)
}

function New-AudioDeviceCard($Device) {
    $stack = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.WrapPanel
    [void]$title.Children.Add((New-Text $Device.name 14 '#F2F4F8' 'SemiBold'))
    if ($Device.isDefault) { [void]$title.Children.Add((New-Badge 'Default' '#1D3A2A' '#62D394')) }
    if ($Device.isCallsDefault) { [void]$title.Children.Add((New-Badge 'Default for calls' '#1F2D44' '#7FB2FF')) }
    if ($Device.state -eq 'Off') { [void]$title.Children.Add((New-Badge 'Turned off' '#3A2326' '#FF7A85')) }
    if ($Device.state -eq 'Unplugged') { [void]$title.Children.Add((New-Badge 'Unplugged' '#23272F' '#8A91A3')) }
    [void]$stack.Children.Add($title)
    if ($Device.iface) { [void]$stack.Children.Add((New-Text $Device.iface 12 '#8A91A3' 'Normal' '0,2,0,0')) }

    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,8,0,0'
    $active = $Device.state -eq 'Active'
    $b1 = New-Button 'Make default' $Device
    $b1.IsEnabled = $active -and -not $Device.isDefault
    $b1.Add_Click({ param($s, $e) Invoke-AudioDefault $s.Tag 'audio' })
    $b2 = New-Button 'Default for calls' $Device
    $b2.IsEnabled = $active -and -not $Device.isCallsDefault
    $b2.Add_Click({ param($s, $e) Invoke-AudioDefault $s.Tag 'calls' })
    $b3 = New-Button $(if ($Device.state -eq 'Off') { 'Turn on' } else { 'Turn off' }) $Device
    $b3.Add_Click({ param($s, $e) Invoke-AudioToggle $s.Tag })
    foreach ($b in $b1, $b2, $b3) { [void]$bar.Children.Add($b) }
    [void]$stack.Children.Add($bar)
    New-Card $stack
}

function Invoke-AudioToggle($Device) {
    if (-not $script:IsAdmin) { [void](Show-Message 'Turning sound devices on or off needs administrator rights.'); return }
    $on = $Device.state -eq 'Off'
    if (-not $on) {
        $warn = $(if ($Device.isDefault -or $Device.isCallsDefault) { "`n`nIt's a default device, so Windows switches to another $($Device.flow.ToLower()) device, if there is one." } else { '' })
        $msg = "Turn off $($Device.display)?`n`nWindows and apps won't see it until you turn it on again here or in the Sound panel.$warn"
        if ((Show-Message $msg 'YesNo' 'Question') -ne 'Yes') { return }
    }
    Write-Log "Sound: $($Device.display) -> $(if ($on) { 'on' } else { 'off' })"
    Set-Busy $true
    try { [void](Set-AudioDeviceRecorded $Device $on); Write-Log '  done (saved to History)' }
    catch { Write-Log "  ! $($_.Exception.Message)"; [void](Show-Message $_.Exception.Message 'OK' 'Warning') }
    finally { Set-Busy $false }
    Build-SoundSection
}

function Invoke-AudioDefault($Device, [string]$For) {
    Write-Log "Sound: default $($Device.flow.ToLower()) device$(if ($For -eq 'calls') { ' for calls' }) -> $($Device.display)"
    Set-Busy $true
    try { [void](Set-AudioDefaultRecorded $Device $For); Write-Log '  done (saved to History)' }
    catch { Write-Log "  ! $($_.Exception.Message)"; [void](Show-Message $_.Exception.Message 'OK' 'Warning') }
    finally { Set-Busy $false }
    Build-SoundSection
}

#endregion
#region Maintenance page -----------------------------------------------------

function Build-MaintenanceList {
    $list = $script:UI.MaintList
    $list.Children.Clear()
    foreach ($a in $script:Actions) {
        $dock = New-Object System.Windows.Controls.DockPanel
        $btn = New-Button 'Run' $a
        $btn.Margin = '12,0,0,0'; $btn.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        $btn.Add_Click({ param($s, $e) Invoke-GuiAction $s.Tag })
        [void]$dock.Children.Add($btn)
        $stack = New-Object System.Windows.Controls.StackPanel
        [void]$stack.Children.Add((New-Text $a.name 14 '#F2F4F8' 'SemiBold'))
        [void]$stack.Children.Add((New-Text $a.description 12.5 '#9AA1B2' 'Normal' '0,3,0,0'))
        if ($a.external) { [void]$stack.Children.Add((New-Text 'Opens in a separate window' 11.5 '#6F7790' 'Normal' '0,3,0,0')) }
        [void]$dock.Children.Add($stack)
        [void]$list.Children.Add((New-Card $dock))
    }
}

function Invoke-GuiAction($Action) {
    Write-Log "Running: $($Action.name)..."
    Set-Busy $true
    try {
        $out = Invoke-MaintenanceAction $Action
        if ($out) { Write-Log "  $out" }
    } catch { Write-Log "  ! $($_.Exception.Message)" }
    finally { Set-Busy $false }
}

#endregion
#region History page ---------------------------------------------------------

function Build-HistoryList {
    $list = $script:UI.HistoryList
    $list.Children.Clear()
    $entries = @(Get-Journal)
    [array]::Reverse($entries)
    $open = @($entries | Where-Object { -not $_.undone }).Count
    $script:UI.HistoryInfo.Text = "Every change this tool makes is saved with the value it replaced, so undo restores your PC exactly as it was. $open change set(s) can be undone. History file: $script:JournalPath"
    $script:UI.UndoAllBtn.IsEnabled = ($open -gt 0)
    foreach ($e in $entries) {
        $dock = New-Object System.Windows.Controls.DockPanel
        if ($e.undone) {
            $right = New-Badge 'Undone' '#23272F' '#8A91A3'
            $right.VerticalAlignment = 'Center'
        } else {
            $right = New-Button 'Undo' $e.id
            $right.Margin = '12,0,0,0'; $right.VerticalAlignment = 'Center'
            $right.Add_Click({ param($s, $ev) Invoke-GuiUndo @($s.Tag) })
        }
        [System.Windows.Controls.DockPanel]::SetDock($right, 'Right')
        [void]$dock.Children.Add($right)

        $stack = New-Object System.Windows.Controls.StackPanel
        $color = $(if ($e.undone) { '#8A91A3' } else { '#F2F4F8' })
        [void]$stack.Children.Add((New-Text $e.name 14 $color 'SemiBold'))
        $when = ([datetime]$e.time).ToString('ddd d MMM yyyy, HH:mm')
        $n = @($e.changes).Count
        [void]$stack.Children.Add((New-Text "$when  -  $n change(s)" 11.5 '#6F7790' 'Normal' '0,2,0,0'))
        foreach ($c in @($e.changes)) {
            $line = switch ($c.kind) {
                'registry' { "Registry  $($c.path)\$($c.name)  (was $(if ($c.existed) { Format-PortableValue $c.value $c.type } else { 'not set' }))" }
                'service'  { "Service   $($c.name)  (was $($c.prior))" }
                'task'     { "Task      $($c.path)$($c.name)  (was $($c.prior))" }
                'script'   { "Ran       $($c.describe)" }
                'appx'     { "Removed   $($c.label)  ($($c.name))" }
                'netadapter'   { "Network   $($c.name)  (was $(Format-NetConfig $c.prior))" }
                'computername' { "PC name   (was $($c.prior))" }
                'workgroup'    { "Workgroup (was $($c.prior))" }
                'audiodevice'  { "Sound     $($c.name)  (was $(if ($c.prior) { 'on' } else { 'off' }))" }
                'audiodefault' { "Sound     default $($c.flow.ToLower()) device  (was $($c.priorName))" }
            }
            $tb = New-Text $line 11.5 '#9AA1B2' 'Normal' '0,2,0,0'
            $tb.FontFamily = 'Consolas'
            [void]$stack.Children.Add($tb)
        }
        foreach ($err in @($e.errors)) { if ($err) { [void]$stack.Children.Add((New-Text "! $err" 11.5 '#FF7A85' 'Normal' '0,2,0,0')) } }
        [void]$dock.Children.Add($stack)
        [void]$list.Children.Add((New-Card $dock))
    }
    if (-not $entries.Count) { [void]$list.Children.Add((New-Text 'Nothing has been changed yet.' 13 '#8A91A3')) }
}

function Invoke-GuiUndo([string[]]$Ids) {
    Set-Busy $true
    try {
        foreach ($id in $Ids) {
            $entry = @(Get-Journal) | Where-Object { $_.id -eq $id } | Select-Object -First 1
            Write-Log "Undoing: $($entry.name)"
            try {
                $errs = @(Undo-JournalEntry $id)
                foreach ($er in $errs) { Write-Log "  ! $er" }
                if (-not $errs.Count) { Write-Log '  restored' }
            } catch { Write-Log "  ! $($_.Exception.Message)" }
        }
    } finally { Set-Busy $false }
    Update-Everything
}

#endregion
#region Dashboard ------------------------------------------------------------

function New-StatCard([string]$Value, [string]$Label, [string]$Color) {
    $s = New-Object System.Windows.Controls.StackPanel
    [void]$s.Children.Add((New-Text $Value 28 $Color 'Bold'))
    [void]$s.Children.Add((New-Text $Label 12.5 '#9AA1B2' 'Normal' '0,2,0,0'))
    $c = New-Card $s '0,0,12,12'
    $c.Width = 210; $c.Padding = '16,14'
    $c
}

function Update-Dashboard {
    $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $script:UI.DashInfo.Text = "$($os.ProductName -replace 'Windows 10', 'Windows 11') $($os.DisplayVersion) (build $($os.CurrentBuild).$($os.UBR))  -  signed in as $env:USERNAME on $env:COMPUTERNAME"

    $stats = $script:UI.DashStats
    $stats.Children.Clear()
    $applied = @($script:TweakState.Values | Where-Object { $_ -eq 'Applied' }).Count
    $bloat = @($script:AppInventory | Where-Object { $_.Group -eq 'Recommended' }).Count
    $startupOn = @($script:StartupItems | Where-Object { $_.Enabled }).Count
    $open = @(Get-Journal | Where-Object { -not $_.undone }).Count
    [void]$stats.Children.Add((New-StatCard "$applied / $($script:Catalog.Count)" 'tweaks already applied' '#8CBBFF'))
    [void]$stats.Children.Add((New-StatCard "$bloat" 'recommended-to-remove apps installed' $(if ($bloat) { '#F2C14E' } else { '#62D394' })))
    [void]$stats.Children.Add((New-StatCard "$startupOn" 'programs start with Windows' '#E6E8EE'))
    [void]$stats.Children.Add((New-StatCard "$open" 'change sets you can undo' '#C9AEFF'))

    $presets = $script:UI.DashPresets
    $presets.Children.Clear()
    foreach ($p in $script:Presets) {
        $ids = @(Resolve-PresetTweaks $p | ForEach-Object { $_.id })
        $todo = @($ids | Where-Object { $script:TweakState[$_] -ne 'Applied' }).Count
        $s = New-Object System.Windows.Controls.StackPanel
        [void]$s.Children.Add((New-Text $p.name 15 '#FFFFFF' 'SemiBold'))
        [void]$s.Children.Add((New-Text $p.description 12.5 '#9AA1B2' 'Normal' '0,4,0,8'))
        $appsText = $(if ($p.apps -eq 'recommended') { ' + removes recommended apps' } else { '' })
        [void]$s.Children.Add((New-Text "$todo tweak(s) to apply$appsText" 12 '#8CBBFF' 'Normal' '0,0,0,10'))
        $b = New-Button 'Select this preset' $p.name 'AccentBtn'
        $b.HorizontalAlignment = 'Left'
        $b.Add_Click({ param($sn, $e) Select-Preset $sn.Tag })
        [void]$s.Children.Add($b)
        $c = New-Card $s '0,0,12,12'
        $c.Width = 300; $c.Padding = '16,14'
        [void]$presets.Children.Add($c)
    }
}

#endregion
#region Review and apply -----------------------------------------------------

function Show-PlanDialog([string]$Text, [int]$Count) {
    if ($script:SmokeDir) { return $false }
    $w = New-Object System.Windows.Window
    $w.Title = 'Review changes'; $w.Width = 900; $w.Height = 640
    $w.Owner = $script:Window; $w.WindowStartupLocation = 'CenterOwner'
    $w.Background = Brush '#14161C'

    $dock = New-Object System.Windows.Controls.DockPanel
    $dock.Margin = '20'
    $head = New-Text 'Review changes' 20 '#FFFFFF' 'SemiBold' '0,0,0,4'
    [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')
    [void]$dock.Children.Add($head)
    $sub = New-Text 'This is exactly what will change. Every item is saved to History first so it can be undone.' 12.5 '#9AA1B2' 'Normal' '0,0,0,12'
    [System.Windows.Controls.DockPanel]::SetDock($sub, 'Top')
    [void]$dock.Children.Add($sub)

    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.HorizontalAlignment = 'Right'; $bar.Margin = '0,14,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($bar, 'Bottom')
    $cancel = New-Button 'Cancel' $null
    $cancel.Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
    $apply = New-Button "Apply $Count change set(s)" $null 'AccentBtn'
    $apply.Margin = '0'
    $apply.IsEnabled = ($Count -gt 0)
    $apply.Add_Click({ param($s, $e) $script:PlanAccepted = $true; [System.Windows.Window]::GetWindow($s).Close() })
    [void]$bar.Children.Add($cancel)
    [void]$bar.Children.Add($apply)
    [void]$dock.Children.Add($bar)

    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $Text; $box.IsReadOnly = $true; $box.FontFamily = 'Consolas'; $box.FontSize = 12.5
    $box.VerticalScrollBarVisibility = 'Auto'; $box.HorizontalScrollBarVisibility = 'Auto'
    $box.Background = Brush '#0E1014'; $box.Foreground = Brush '#D5DAE5'; $box.BorderBrush = Brush '#2A2F3B'; $box.Padding = '12'
    [void]$dock.Children.Add($box)

    $w.Content = $dock
    $script:PlanAccepted = $false
    [void]$w.ShowDialog()
    $script:PlanAccepted
}

function Invoke-ApplySelection {
    $tweaks = @(Get-SelectedTweaks)
    $apps = @(Get-SelectedApps)
    if (-not $tweaks.Count -and -not $apps.Count) {
        [void](Show-Message 'Nothing is selected yet. Pick a preset or tick some tweaks or apps first.')
        return
    }
    $deprov = [bool]$script:UI.AppDeprovision.IsChecked
    $todo = @($tweaks | Where-Object { @(Get-TweakPlan $_).Count -gt 0 })
    $text = Get-PlanText -Tweaks $tweaks -Apps $apps -Deprovision:$deprov
    if (-not (Show-PlanDialog $text ($todo.Count + $apps.Count))) { Write-Log 'Review closed - nothing changed.'; return }

    Set-Busy $true
    $after = @{}
    try {
        if ($script:UI.RestorePointCheck.IsChecked) {
            Write-Log 'Creating a restore point (this can take a minute)...'
            Update-UI
            $ok, $msg = New-SafetyRestorePoint
            Write-Log "  $msg"
            if (-not $ok) {
                $answer = Show-Message "$msg`n`nContinue without a restore point? Your changes can still be undone from History." 'YesNo' 'Warning'
                if ($answer -ne 'Yes') { Write-Log 'Stopped - nothing changed.'; return }
            }
        }
        foreach ($t in $todo) {
            Write-Log "Applying: $($t.name)"
            $r = Invoke-Tweak $t
            foreach ($e in $r.Errors) { Write-Log "  ! $e" }
            Write-Log "  $($r.Changes) change(s) made"
            foreach ($a in (Get-Items $t 'after')) { $after[$a] = $true }
        }
        foreach ($a in $apps) {
            Write-Log "Removing app: $($a.Label)"
            try {
                $errs = @(Remove-App $a -Deprovision:$deprov)
                foreach ($e in $errs) { Write-Log "  ! $e" }
                Write-Log '  removed'
            } catch { Write-Log "  ! $($_.Exception.Message)" }
        }
        Write-Log 'Done.'
    } finally { Set-Busy $false }

    Update-Everything
    if ($after.explorer) {
        if ((Show-Message 'Some changes need File Explorer and the taskbar to restart. Restart them now? Open Explorer windows will close.' 'YesNo' 'Question') -eq 'Yes') {
            Restart-Explorer
            Write-Log 'File Explorer restarted.'
        }
    }
    if ($after.reboot) { [void](Show-Message 'Some changes take effect after you restart the PC.') }
    elseif ($after.signout) { [void](Show-Message 'Some changes take effect after you sign out and back in.') }
}

#endregion
#region Startup and wiring ---------------------------------------------------

function Update-Everything {
    Update-TweakStatuses
    foreach ($id in @($script:TweakChecks.Keys)) {
        if ($script:TweakState[$id] -eq 'Applied') { $script:TweakChecks[$id].IsChecked = $false }
    }
    Build-AppList
    Build-StartupList
    Build-HistoryList
    Update-Dashboard
    Update-SelectionSummary
}

function Initialize-GuiData {
    Set-Busy $true
    try {
        Build-TweakList
        Build-PresetButtons
        Build-InstallBundles
        $script:InstallChecks = @{}
        Initialize-IsoPage
        Build-MaintenanceList
        $script:AppChecks = @{}
        Update-Everything
    } finally { Set-Busy $false }
}

function Save-WindowPng([string]$Path) {
    $root = $script:Window.Content
    $w = [int]$root.ActualWidth; $h = [int]$root.ActualHeight
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [System.IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Close() }
}

# Renders every page to PNG and saves a sample review text, then closes. Used for testing.
function Invoke-SmokeTest {
    if (-not (Test-Path $script:SmokeDir)) { New-Item -ItemType Directory -Path $script:SmokeDir | Out-Null }
    Select-Preset 'Gaming'
    $text = Get-PlanText -Tweaks (Get-SelectedTweaks) -Apps (Get-SelectedApps)
    [System.IO.File]::WriteAllText((Join-Path $script:SmokeDir 'preview-gaming.txt'), $text)
    Show-Panel 'Install'
    Select-InstallBundle (@($script:InstallBundles)[0].name)
    foreach ($p in $script:Panels) {
        Show-Panel $p
        $script:Window.UpdateLayout()
        Update-UI
        Save-WindowPng (Join-Path $script:SmokeDir "$p.png")
    }
    $script:Window.Close()
}

function Show-DebloatGui {
    param([string]$SmokeDir)
    $script:SmokeDir = $SmokeDir
    $xaml = Get-Content (Join-Path $script:Root 'ui\MainWindow.xaml') -Raw -Encoding UTF8
    $script:Window = [Windows.Markup.XamlReader]::Parse($xaml)

    $script:UI = @{}
    $names = @('AdminText', 'DashInfo', 'DashStats', 'DashPresets', 'PresetBar', 'SelectNoneBtn', 'HideApplied', 'TweakSearch',
        'TweakList', 'AppSelectRecommended', 'AppSelectNone', 'AppRefresh', 'AppDeprovision', 'AppList', 'StartupRefresh',
        'StartupList', 'MaintList', 'HistoryInfo', 'UndoAllBtn', 'HistoryRefresh', 'HistoryList', 'ActionBar', 'ApplyBtn',
        'RestorePointCheck', 'SelectionSummary', 'LogBox', 'InstallBundles', 'InstallBtn', 'UpgradeBtn', 'UninstallBtn',
        'InstallClear', 'InstallRefresh', 'SaveBundleBtn', 'InstallOnlyUpdates', 'InstallHideInstalled', 'InstallSearch',
        'InstallStatus', 'InstallList', 'IsoPath', 'IsoBrowse', 'IsoDownload', 'IsoInfo', 'IsoEditions', 'OptRemoveApps',
        'OptDrivers', 'OptGraphics', 'OptEncryption', 'OptUnattend', 'UnattendFields', 'IsoUser', 'IsoPassword', 'IsoComputer', 'IsoPresets',
        'IsoBundles', 'IsoOutput', 'IsoOutputBrowse', 'IsoInstallAdk', 'IsoToolStatus', 'IsoBuildBtn', 'IsoOpenFolder',
        'IsoGetRufus', 'IsoBuildStatus', 'SettingsRefresh', 'SettingsSearch', 'SettingsList')
    foreach ($p in $script:Panels) { $names += "Nav$p"; $names += "Panel$p" }
    foreach ($n in $names) {
        $script:UI[$n] = $script:Window.FindName($n)
        if (-not $script:UI[$n]) { throw "UI element '$n' not found in MainWindow.xaml" }
    }

    $script:LogSink = {
        param($m)
        $script:UI.LogBox.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $m) + "`r`n")
        $script:UI.LogBox.ScrollToEnd()
        Update-UI
    }

    $script:UI.AdminText.Text = $(if ($script:IsAdmin) { 'Running as administrator.' } else { 'Not running as administrator: you can browse, but most changes need admin rights.' })

    foreach ($p in $script:Panels) {
        $nav = $script:UI["Nav$p"]
        $nav.Tag = $p
        $nav.Add_Checked({ param($s, $e) Show-Panel $s.Tag })
    }
    $script:UI.TweakSearch.Add_TextChanged({ Update-TweakFilter })
    $script:UI.HideApplied.Add_Click({ Update-TweakFilter })
    $script:UI.SelectNoneBtn.Add_Click({
        foreach ($cb in @($script:TweakChecks.Values)) { $cb.IsChecked = $false }
        Update-SelectionSummary
    })
    $script:UI.AppSelectRecommended.Add_Click({
        foreach ($cb in @($script:AppChecks.Values)) { $cb.IsChecked = ($cb.Tag.Group -eq 'Recommended') }
        Update-SelectionSummary
    })
    $script:UI.AppSelectNone.Add_Click({
        foreach ($cb in @($script:AppChecks.Values)) { $cb.IsChecked = $false }
        Update-SelectionSummary
    })
    $script:UI.AppRefresh.Add_Click({ Build-AppList })
    $script:UI.StartupRefresh.Add_Click({ Build-StartupList })
    $script:UI.HistoryRefresh.Add_Click({ Build-HistoryList })
    $script:UI.UndoAllBtn.Add_Click({
        $ids = @(Get-Journal | Where-Object { -not $_.undone } | ForEach-Object { $_.id })
        if (-not $ids.Count) { return }
        [array]::Reverse($ids)
        if ((Show-Message "Undo all $($ids.Count) change set(s), newest first?" 'YesNo' 'Warning') -eq 'Yes') { Invoke-GuiUndo $ids }
    })
    $script:UI.ApplyBtn.Add_Click({ Invoke-ApplySelection })
    $script:UI.InstallBtn.Add_Click({ Invoke-InstallOperation 'install' })
    $script:UI.UpgradeBtn.Add_Click({ Invoke-InstallOperation 'upgrade' })
    $script:UI.UninstallBtn.Add_Click({ Invoke-InstallOperation 'uninstall' })
    $script:UI.InstallRefresh.Add_Click({ Build-InstallList })
    $script:UI.SaveBundleBtn.Add_Click({ Save-InstallBundle })
    $script:UI.InstallClear.Add_Click({ foreach ($cb in @($script:InstallChecks.Values)) { $cb.IsChecked = $false } })
    $script:UI.InstallSearch.Add_TextChanged({ Update-InstallFilter })
    $script:UI.SettingsSearch.Add_TextChanged({ Update-SettingsFilter })
    $script:UI.SettingsRefresh.Add_Click({ Build-SettingsList })
    $script:UI.InstallHideInstalled.Add_Click({ Update-InstallFilter })
    $script:UI.InstallOnlyUpdates.Add_Click({ Update-InstallFilter })
    $script:UI.IsoBrowse.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Windows ISO (*.iso)|*.iso'
        $dlg.InitialDirectory = Join-Path $env:USERPROFILE 'Downloads'
        if ($dlg.ShowDialog($script:Window)) { $script:UI.IsoPath.Text = $dlg.FileName; Read-IsoEditions }
    })
    $script:UI.IsoPath.Add_LostFocus({ if ($script:UI.IsoPath.Text -and $script:IsoEditionsFor -ne $script:UI.IsoPath.Text.Trim('"', ' ')) { Read-IsoEditions } })
    $script:UI.IsoDownload.Add_Click({ Start-Process explorer.exe -ArgumentList '"https://www.microsoft.com/software-download/windows11"' })
    $script:UI.IsoGetRufus.Add_Click({ Start-Process explorer.exe -ArgumentList '"https://rufus.ie/"' })
    $script:UI.IsoOutputBrowse.Add_Click({
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Folder for the finished ISO (needs about 35 GB free while building)'
        if ($dlg.ShowDialog() -eq 'OK') { $script:UI.IsoOutput.Text = $dlg.SelectedPath }
    })
    $script:UI.IsoOpenFolder.Add_Click({
        $d = $script:UI.IsoOutput.Text
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList "`"$d`""
    })
    $script:UI.IsoInstallAdk.Add_Click({
        if ((Show-Message 'Install the Windows ADK Deployment Tools from Microsoft (through winget)? Only the part needed to create ISO files is installed.' 'YesNo' 'Question') -ne 'Yes') { return }
        $done = Start-AdkInstallJob
        $script:UI.IsoToolStatus.Text = 'Installing in a separate window...'
        Start-JobWatch $done 'adk'
    })
    $script:UI.OptUnattend.Add_Click({ $script:UI.UnattendFields.IsEnabled = [bool]$script:UI.OptUnattend.IsChecked })
    $script:UI.OptDrivers.Add_Click({ $script:UI.OptGraphics.IsEnabled = [bool]$script:UI.OptDrivers.IsChecked })
    $script:UI.IsoBuildBtn.Add_Click({ Start-IsoBuild })

    $script:Window.Add_ContentRendered({
        Write-Log 'DebloatTool started.'
        Initialize-GuiData
        if ($script:SmokeDir) { Invoke-SmokeTest }
    })
    [void]$script:Window.ShowDialog()
}

#endregion
