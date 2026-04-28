#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for Clicky on Windows.

.DESCRIPTION
    Builds Clicky as a self-contained single-file app (no .NET runtime needed
    on the target machine) and installs it to %LOCALAPPDATA%\Programs\Clicky.
    Creates Start Menu and Desktop shortcuts, registers Clicky in
    Apps & Features so it can be uninstalled from Settings, and optionally
    adds it to the Run key so it launches on login (default: yes -- Clicky
    is a tray app, the user expects it to be there).

    Runs entirely per-user; no administrator rights required.

.PARAMETER FrameworkDependent
    Produce a smaller framework-dependent build instead of self-contained.
    The target machine must have the .NET 8 Desktop Runtime installed.

.PARAMETER NoAutoStart
    Skip the HKCU Run entry so Clicky doesn't start automatically on login.

.PARAMETER NoLaunch
    Install without launching Clicky at the end.

.EXAMPLE
    .\Install-Clicky.ps1

.EXAMPLE
    .\Install-Clicky.ps1 -FrameworkDependent -NoAutoStart
#>

[CmdletBinding()]
param(
    [switch]$FrameworkDependent,
    [switch]$NoAutoStart,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

# ---------- Paths ----------

$ScriptDirectory         = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRepoRoot         = Resolve-Path (Join-Path $ScriptDirectory '..')
$ProjectFilePath         = Join-Path $WindowsRepoRoot 'Clicky\Clicky.csproj'
$InstallRoot             = Join-Path $env:LOCALAPPDATA 'Programs\Clicky'
$InstalledExePath        = Join-Path $InstallRoot 'Clicky.exe'
$InstalledUninstallerPs1 = Join-Path $InstallRoot 'Uninstall-Clicky.ps1'
$StartMenuProgramsDir    = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$StartMenuShortcutPath   = Join-Path $StartMenuProgramsDir 'Clicky.lnk'
$DesktopShortcutPath     = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Clicky.lnk'
$UninstallRegistryKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Clicky'
$RunRegistryKey          = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# ---------- Helpers ----------

function Write-Step($message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}

function Write-Info($message) {
    Write-Host "    $message" -ForegroundColor Gray
}

function Assert-DotNetSdk {
    Write-Step 'Checking for .NET 8 SDK'
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        throw ".NET 8 SDK not found on PATH. Install it from https://dotnet.microsoft.com/download/dotnet/8.0 and re-run this installer."
    }

    $versions = & dotnet --list-sdks 2>$null
    $hasEight = $versions | Where-Object { $_ -match '^\s*8\.' }
    if (-not $hasEight) {
        throw ".NET 8 SDK not found. `dotnet --list-sdks` showed:`n$($versions -join "`n")`nInstall .NET 8 from https://dotnet.microsoft.com/download/dotnet/8.0 and re-run."
    }

    Write-Info ("Found: " + (($hasEight | Select-Object -First 1).Trim()))
}

function Stop-RunningClicky {
    $running = Get-Process -Name 'Clicky' -ErrorAction SilentlyContinue
    if ($running) {
        Write-Step 'Closing the running Clicky instance'
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }
}

function Invoke-Publish {
    Write-Step 'Building Clicky (this takes a minute on a cold build)'
    $publishTempDirectory = Join-Path $env:TEMP ("ClickyPublish-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $publishTempDirectory | Out-Null

    $publishArgs = @(
        'publish', $ProjectFilePath,
        '-c', 'Release',
        '-r', 'win-x64',
        '-o', $publishTempDirectory,
        '-p:PublishSingleFile=true',
        '-p:IncludeNativeLibrariesForSelfExtract=true',
        '-p:IncludeAllContentForSelfExtract=true',
        '--nologo'
    )
    if ($FrameworkDependent) {
        $publishArgs += '--self-contained'
        $publishArgs += 'false'
        Write-Info 'Framework-dependent build -- end users need the .NET 8 Desktop Runtime.'
    } else {
        $publishArgs += '--self-contained'
        $publishArgs += 'true'
        Write-Info 'Self-contained build -- bundles the .NET runtime. No end-user prerequisites.'
    }

    & dotnet @publishArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed (exit $LASTEXITCODE)."
    }

    return $publishTempDirectory
}

function Copy-ToInstallRoot($publishDir) {
    Write-Step "Installing to $InstallRoot"

    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    }

    # Wipe the old payload so orphaned files from a previous install don't
    # linger. Keep the folder itself so shortcuts / user settings stay put.
    Get-ChildItem -Path $InstallRoot -Force | ForEach-Object {
        try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop }
        catch {
            Write-Warning "Couldn't remove '$($_.FullName)': $($_.Exception.Message). Continuing."
        }
    }

    Copy-Item -Path (Join-Path $publishDir '*') -Destination $InstallRoot -Recurse -Force
    Write-Info ("Installed: " + $InstalledExePath)
}

function New-WindowsShortcut {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$TargetExePath,
        [string]$Description = 'Clicky - hold Ctrl+Alt to talk.'
    )
    $shellComObject = New-Object -ComObject WScript.Shell
    $shortcut = $shellComObject.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath       = $TargetExePath
    $shortcut.WorkingDirectory = Split-Path $TargetExePath
    $shortcut.IconLocation     = "$TargetExePath,0"
    $shortcut.Description      = $Description
    $shortcut.WindowStyle      = 7   # minimized -- Clicky lives in the tray
    $shortcut.Save()
}

function Install-Shortcuts {
    Write-Step 'Creating Start Menu and Desktop shortcuts'
    if (-not (Test-Path $StartMenuProgramsDir)) {
        New-Item -ItemType Directory -Force -Path $StartMenuProgramsDir | Out-Null
    }
    New-WindowsShortcut -ShortcutPath $StartMenuShortcutPath -TargetExePath $InstalledExePath
    New-WindowsShortcut -ShortcutPath $DesktopShortcutPath   -TargetExePath $InstalledExePath
    Write-Info ("Start Menu: " + $StartMenuShortcutPath)
    Write-Info ("Desktop:    " + $DesktopShortcutPath)
}

function Install-Uninstaller {
    Write-Step 'Writing uninstaller'
    $uninstallerPs1Body = @'
#Requires -Version 5.1
<#
    Uninstalls Clicky -- removes the install folder, shortcuts, Run key,
    and the Apps & Features entry. Safe to run more than once.
#>
$ErrorActionPreference = 'SilentlyContinue'

Get-Process -Name 'Clicky' | Stop-Process -Force -ErrorAction SilentlyContinue

$InstallRoot           = Join-Path $env:LOCALAPPDATA 'Programs\Clicky'
$StartMenuShortcut     = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Clicky.lnk'
$DesktopShortcut       = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Clicky.lnk'
$UninstallRegistryKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Clicky'
$RunRegistryKey        = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

Remove-Item -Path $StartMenuShortcut -Force
Remove-Item -Path $DesktopShortcut   -Force
Remove-ItemProperty -Path $RunRegistryKey -Name 'Clicky' -ErrorAction SilentlyContinue
Remove-Item -Path $UninstallRegistryKey -Recurse -Force

# Schedule the install folder for deletion on reboot via a helper cmd --
# PowerShell can't remove its own running script, so we spawn cmd to do it
# after this process exits.
if (Test-Path $InstallRoot) {
    $removeCommand = "timeout /t 2 /nobreak > NUL & rmdir /s /q `"$InstallRoot`""
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $removeCommand -WindowStyle Hidden
}

Write-Host 'Clicky has been uninstalled.'
'@

    Set-Content -Path $InstalledUninstallerPs1 -Value $uninstallerPs1Body -Encoding UTF8

    $projectVersion = '1.0.0'
    try {
        $assemblyVersion = (Get-Item $InstalledExePath).VersionInfo.ProductVersion
        if ($assemblyVersion) { $projectVersion = $assemblyVersion }
    } catch { }

    New-Item -Path $UninstallRegistryKey -Force | Out-Null
    $powershellExe = (Get-Command powershell).Source
    $uninstallCommand = ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $powershellExe, $InstalledUninstallerPs1)

    Set-ItemProperty $UninstallRegistryKey -Name 'DisplayName'       -Value 'Clicky'
    Set-ItemProperty $UninstallRegistryKey -Name 'DisplayVersion'    -Value $projectVersion
    Set-ItemProperty $UninstallRegistryKey -Name 'DisplayIcon'       -Value $InstalledExePath
    Set-ItemProperty $UninstallRegistryKey -Name 'Publisher'         -Value 'Clicky'
    Set-ItemProperty $UninstallRegistryKey -Name 'InstallLocation'   -Value $InstallRoot
    Set-ItemProperty $UninstallRegistryKey -Name 'UninstallString'   -Value $uninstallCommand
    Set-ItemProperty $UninstallRegistryKey -Name 'NoModify'          -Value 1     -Type DWord
    Set-ItemProperty $UninstallRegistryKey -Name 'NoRepair'          -Value 1     -Type DWord
    Set-ItemProperty $UninstallRegistryKey -Name 'InstallDate'       -Value (Get-Date -Format 'yyyyMMdd')

    Write-Info 'Registered in Apps & Features (Start > Settings > Apps > Installed apps).'
}

function Register-AutoStartIfRequested {
    if ($NoAutoStart) {
        Write-Step 'Skipping auto-start registration (-NoAutoStart)'
        Remove-ItemProperty -Path $RunRegistryKey -Name 'Clicky' -ErrorAction SilentlyContinue
        return
    }
    Write-Step 'Adding Clicky to login auto-start'
    if (-not (Test-Path $RunRegistryKey)) {
        New-Item -Path $RunRegistryKey -Force | Out-Null
    }
    Set-ItemProperty -Path $RunRegistryKey -Name 'Clicky' -Value ('"{0}"' -f $InstalledExePath)
    Write-Info 'Clicky will now start automatically when you log in.'
    Write-Info 'Use `msconfig` > Startup, or Task Manager > Startup apps, to disable later.'
}

function Start-ClickyIfRequested {
    if ($NoLaunch) { return }
    Write-Step 'Launching Clicky'
    Start-Process -FilePath $InstalledExePath
    Write-Info 'Clicky lives in your system tray -- click the blue dot next to the clock to open it.'
}

# ---------- Main ----------

try {
    Write-Host ''
    Write-Host 'Clicky installer' -ForegroundColor White
    Write-Host '================' -ForegroundColor White

    Assert-DotNetSdk
    Stop-RunningClicky
    $publishDir = Invoke-Publish
    try {
        Copy-ToInstallRoot -publishDir $publishDir
    }
    finally {
        Remove-Item -Path $publishDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Install-Shortcuts
    Install-Uninstaller
    Register-AutoStartIfRequested
    Start-ClickyIfRequested

    Write-Host ''
    Write-Host 'Install complete.' -ForegroundColor Green
    Write-Host 'Hold Ctrl + Alt anywhere to talk. Release to send.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Before Clicky can actually talk to the AI backend, open' -ForegroundColor Yellow
    Write-Host '  windows\Clicky\Services\WorkerConfig.cs' -ForegroundColor Yellow
    Write-Host 'and replace the placeholder Cloudflare Worker URL with your own,' -ForegroundColor Yellow
    Write-Host 'then re-run this installer.' -ForegroundColor Yellow
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Host ('Install failed: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    exit 1
}
