# DebloatTool one-line installer.
#
#   irm https://shreeve.dev/win | iex
#
# The release workflow fills in the version and the SHA-256 of that release's zip, then
# publishes this file next to the zip. It downloads the zip, checks the hash, unpacks it to
# %LOCALAPPDATA%\DebloatTool\app\<version> and opens DebloatTool (which asks for admin rights).
# Nothing is changed on your PC until you review and apply tweaks in the app.
#
# Want to read it first? Open the URL in a browser, or download the release zip by hand
# from https://github.com/shreeve-dev/debloat/releases and run Run.bat.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on

    $version = '__VERSION__'
    $sha256  = '__SHA256__'
    $repo    = 'shreeve-dev/debloat'

    if ($version -like '__*') {
        Write-Host 'This is the unreleased template. Use the installer from a GitHub release instead.' -ForegroundColor Red
        return
    }
    if ($PSVersionTable.PSEdition -eq 'Core' -or [Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Host 'DebloatTool runs on Windows. Starting it with Windows PowerShell 5.1.' -ForegroundColor Yellow
    }

    # Windows PowerShell 5.1 can default to old TLS versions that GitHub refuses.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $base   = Join-Path $env:LOCALAPPDATA 'DebloatTool\app'
    $target = Join-Path $base $version
    $zip    = Join-Path ([IO.Path]::GetTempPath()) "debloattool-$version.zip"
    $url    = "https://github.com/$repo/releases/download/$version/debloattool-$version.zip"

    try {
        Write-Host "Downloading DebloatTool $version..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($actual -ne $sha256) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Write-Host 'The download does not match the expected SHA-256 hash, so it was deleted and nothing was run.' -ForegroundColor Red
            Write-Host "  expected $sha256"
            Write-Host "  got      $actual"
            return
        }

        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        New-Item -ItemType Directory -Force $target | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File

        # Remove older versions. Your settings, undo history and bundles are kept: they live in
        # %LOCALAPPDATA%\DebloatTool, not in the app folder.
        Get-ChildItem -LiteralPath $base -Directory | Where-Object { $_.Name -ne $version } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

        $entry = Join-Path $target 'DebloatTool.ps1'
        if (-not (Test-Path -LiteralPath $entry)) { throw "DebloatTool.ps1 is missing from the download." }
        Write-Host 'Opening DebloatTool. Accept the admin prompt to continue.' -ForegroundColor Cyan
        try {
            Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ErrorAction Stop `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$entry`"")
        } catch {
            Write-Host "The admin prompt was cancelled. To open it later, run: $(Join-Path $target 'Run.bat')" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "DebloatTool could not be installed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
