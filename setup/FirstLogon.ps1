# FirstLogon.ps1
# Runs once, as administrator, during the first sign-in on a PC installed from a DebloatTool ISO
# (started by autounattend.xml). Applies your preset, then hands app installs to a visible window.

$root = Split-Path $PSScriptRoot -Parent
Start-Transcript -Path (Join-Path $PSScriptRoot 'firstlogon.log') -Append | Out-Null
try {
    # Windows keeps copies of the answer file, which can contain the account password.
    foreach ($f in 'C:\Windows\Panther\unattend.xml', 'C:\Windows\Panther\Unattend\unattend.xml', 'C:\Windows\Panther\unattend-original.xml') {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }

    $s = Get-Content (Join-Path $PSScriptRoot 'settings.json') -Raw | ConvertFrom-Json

    if ($s.preset) {
        Write-Host "Applying DebloatTool preset: $($s.preset)"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'DebloatTool.ps1') -Preset $s.preset -Apply -SkipRestorePoint
    }

    if (@($s.apps).Count -or @($s.urls).Count) {
        # A scheduled task runs the installs elevated (no admin prompts) in a window you can watch.
        # Its logon trigger restarts the job if the PC reboots before it finishes; the job removes the task when done.
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\InstallApps.ps1`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName 'DebloatTool first-boot apps' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName 'DebloatTool first-boot apps'
        Write-Host 'App install task started.'
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
