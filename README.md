# DebloatTool

A Windows 11 debloat and tuning tool where **every change can be undone exactly**.

Inspired by [Chris Titus Tech's WinUtil](https://github.com/ChrisTitusTech/winutil) (MIT licence). The code here is written from scratch.

## Run it

Open **PowerShell** (Win + X, then *Terminal*) and paste:

```powershell
irm https://shreeve.dev/win | iex
```

That downloads the latest release, checks its SHA-256 hash, unpacks it to `%LOCALAPPDATA%\DebloatTool\app` and opens the app (accept the admin prompt). **Nothing on your PC changes until you pick tweaks, review the list and click Apply**, and changes can be undone from the History page (see *Notes* for the few exceptions).

`shreeve.dev/win` just redirects to `https://github.com/shreeve-dev/debloat/releases/latest/download/install.ps1`. You can use that address instead.

### Before you paste a command from the internet

`irm | iex` runs code straight from a website, with no chance to read it first. That's how WinUtil and similar tools install, but you should know what you're trusting:

- **It always runs the latest release, never unreleased code.** Each release is built and tested by GitHub Actions from a tagged commit.
- **The hash check catches a broken or swapped download, not a bad release.** The installer and its hash come from the same release. If you don't trust the release itself, the hash doesn't help.
- **Want to check first?** Open the URL in a browser to read the installer. Or download `debloattool-<version>.zip` from [Releases](https://github.com/shreeve-dev/debloat/releases), compare it against `SHA256SUMS`, check where it came from with `gh attestation verify debloattool-<version>.zip -R shreeve-dev/debloat`, unzip it and double-click **`Run.bat`**.
- **Make a restore point or backup** before applying *Advanced* tweaks. The app makes a restore point by default, but undo can't bring back everything (see *Notes*).

### From a download

Download the zip from [Releases](https://github.com/shreeve-dev/debloat/releases), unzip it, double-click **`Run.bat`** and accept the admin prompt.

Command line (PowerShell):

```powershell
.\DebloatTool.ps1 -Status                          # which tweaks are applied (no admin needed)
.\DebloatTool.ps1 -Preset Gaming -Preview          # exactly what a preset would change
.\DebloatTool.ps1 -Preset Recommended -Apply       # apply a preset
.\DebloatTool.ps1 -Tweak explorer.*,qol.darkmode -Apply
.\DebloatTool.ps1 -UndoLast                        # undo the most recent change set
.\DebloatTool.ps1 -Bundle "Gaming" -Preview        # which apps in a bundle are installed
.\DebloatTool.ps1 -Bundle "Gaming" -Apply          # install whatever is missing (fresh Windows install)
```

## Adding an app to the installer

Add an entry to `config/install.json`. Find the id with `winget search <name>`.

```json
{ "id": "Publisher.App", "name": "App", "category": "Utilities", "description": "What it is.", "arp": "App*" }
```

`arp` is optional. It's a name pattern matched against Windows' installed-programs list, for apps winget can't detect on its own. For apps that aren't in winget, use `"url"` instead of `"id"`.

## Your own bundles

The bundles in `config/install.json` are generic, so the tool works on any PC. Your own app lists go in `%LOCALAPPDATA%\DebloatTool\custom-bundles.json`, outside the app folder, so they stay on your PC and survive updates. (Older versions kept it in `config\`. It's copied over automatically the first time.) There are two ways to make one:

- In the app, tick the apps you want on **Install apps** and click **Save selection as bundle**.
- Copy `config/custom-bundles.example.json` to `%LOCALAPPDATA%\DebloatTool\custom-bundles.json` and edit it. Each entry in `apps` is a winget id, or the `name` of a download-page app such as `"NVIDIA App"`.

Your bundles show up next to the built-in ones, work with `-Bundle "<name>"`, and are ticked by default on the ISO Builder page. If the file has a mistake, the tool skips it with a warning instead of failing.

## What makes it different

| | |
|---|---|
| **Exact undo** | Before changing anything, the current value is saved, including its type, or the fact that it didn't exist. Undo puts back exactly that, and deletes registry keys the tool created. Services, scheduled tasks, power plans and removed apps work the same way. |
| **Live status** | Every tweak shows *Applied*, *Partly applied* or *Not applied* for your PC right now. |
| **Review first** | Nothing runs until you've seen the full list of registry, service and task changes, with before and after values. |
| **Risk labels** | Each tweak is marked Safe, Moderate or Advanced, with a plain-English warning where it matters. |
| **Presets** | Recommended, Gaming, Privacy, Clean desktop, Everything. A preset only ticks boxes. |
| **Settings** | Rename the PC and join a workgroup or domain (like the Computer Name tab in System Properties). Common Windows settings as simple choices that show what's set now: theme, taskbar, File Explorer, mouse, power plan and sleep, Game Mode, GPU scheduling, Remote Desktop and more. Network adapters can be switched between automatic and static IP, with DNS presets (Cloudflare, Google, Quad9) or your own servers. Network changes revert by themselves after 30 seconds unless you keep them. Sound devices (playback and recording) can be turned off or on and made the default, for audio or for calls, plus call ducking, system sounds, the startup sound and mono audio. Everything goes into History. |
| **Install apps** | 90+ apps through winget, grouped by category, with Installed / Update available badges. Built-in bundles plus your own (see *Your own bundles*). Installs run in their own window as your normal user. Apps winget doesn't carry (NVIDIA App) open their official download page. |
| **ISO Builder** | Turns an official Windows 11 ISO into a self-setting-up installer: one edition, bloat apps removed, this PC's drivers added, no setup screens (local account), and on first sign-in your preset is applied and your bundles are installed. Choosing the disk to install to is always left to you. Needs the Windows ADK Deployment Tools (one-click install) and about 35 GB of temporary space. |
| **Startup manager** | Turns startup programs off the same way Task Manager does. Nothing is deleted. |
| **Restore point** | Created automatically before applying (optional). |

History is stored in `%LOCALAPPDATA%\DebloatTool\journal.json`.

## Project layout

```
DebloatTool.ps1      entry point (GUI + command line)
Run.bat              double-click launcher
config/tweaks.json   the tweak catalog and maintenance actions
config/presets.json  presets
config/apps.json     known Store apps, groups and the protected list
config/settings.json the Settings page (each option uses the tweak format)
src/Engine.ps1       registry/service/task engine, status, plans, undo journal
src/Apps.ps1         Store app removal and startup programs
src/Gui.ps1          WPF interface
ui/MainWindow.xaml   window layout and styles
src/Settings.ps1     Settings page logic: network, PC name, sound devices
src/Installer.ps1    winget installs, updates, uninstalls, bundles
src/IsoBuilder.ps1   custom ISO build (DISM, drivers, autounattend.xml, oscdimg)
src/IsoBuildJob.ps1  runs a build in its own window
setup/               scripts copied into the ISO that run on the new PC's first sign-in
                     (logs end up in C:\DebloatTool\setup\*.log)
tests/Test-Engine.ps1  apply-then-undo round-trip test (only touches HKCU\Software\DebloatToolTest)
tools/install.ps1    one-line installer template (the release workflow fills in the version and hash)
```

## Adding a tweak

Add an entry to `config/tweaks.json`. No code changes are needed.

```json
{
  "id": "qol.example",
  "name": "Short name",
  "category": "Quality of Life",
  "risk": "safe",
  "description": "What it does, in plain words.",
  "note": "Optional warning shown in amber.",
  "after": ["explorer"],
  "registry": [
    { "path": "HKCU\\Software\\...", "name": "Value", "type": "DWord", "value": 1 }
  ],
  "services": [ { "name": "SvcName", "startup": "Disabled", "stop": true } ],
  "tasks":    [ { "path": "\\Microsoft\\Windows\\Folder\\", "name": "TaskName", "state": "Disabled" } ],
  "script":   { "describe": "...", "snapshot": "...", "apply": "...", "undo": "uses $Snapshot", "detect": "returns true/false" }
}
```

- `type`: `String`, `ExpandString`, `DWord`, `QWord`, `Binary` (hex text such as `"00 01 FF"`), or `MultiString`.
- Use `"delete": true` to remove a value instead of setting it.
- Add `"defaultMatches": true` when Windows already behaves like the target if the value is missing.
- `after` can contain `explorer`, `signout` or `reboot`.

Run `tests\Test-Engine.ps1` after editing. It checks the catalog and the undo engine.

## Notes

- Your Windows account should be an administrator. If you elevate with a *different* admin account, "current user" tweaks apply to that account.
- App removal is for the current user by default. "Also remove for new user accounts" deletes Windows' stored copy, and undo cannot bring that copy back. The Microsoft Store can still reinstall the app.

## Licence

MIT. See [LICENSE](LICENSE). Use at your own risk: this tool changes system settings, and you're responsible for what you apply.
