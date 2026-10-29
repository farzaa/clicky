#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot Cloudflare Worker setup for Clicky.

.DESCRIPTION
    Reads API keys from worker/.secrets.local (KEY=VALUE per line, # for
    comments), pushes each non-empty value to Cloudflare as a Worker secret
    via `npx wrangler secret put`, and finishes with `npx wrangler deploy`.
    Logs you into Cloudflare on first run if you are not already authed.

    The first time you run it, a Desktop shortcut "Configure Clicky Worker"
    is created so future runs are one click away.

    Run this script as many times as you want -- it is idempotent. Edit
    .secrets.local, double-click the shortcut, done.

.PARAMETER SkipDeploy
    Push the secrets but skip the final `wrangler deploy`. Useful if you only
    rotated a key and don't need to redeploy.

.PARAMETER NoShortcut
    Don't create or refresh the Desktop shortcut on this run.

.EXAMPLE
    .\Configure-Worker.ps1

.EXAMPLE
    .\Configure-Worker.ps1 -SkipDeploy
#>

[CmdletBinding()]
param(
    [switch]$SkipDeploy,
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'

# ---------- Paths ----------

$ScriptDirectory      = Split-Path -Parent $MyInvocation.MyCommand.Path
$SecretsFilePath      = Join-Path $ScriptDirectory '.secrets.local'
$SecretsExamplePath   = Join-Path $ScriptDirectory '.secrets.local.example'
$BatWrapperPath       = Join-Path $ScriptDirectory 'Configure-Worker.bat'
$DesktopShortcutPath  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Configure Clicky Worker.lnk'

# ---------- Helpers ----------

function Write-Step($message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}

function Write-Info($message) {
    Write-Host "    $message" -ForegroundColor Gray
}

function Write-Warn($message) {
    Write-Host "    $message" -ForegroundColor Yellow
}

function Assert-Node {
    Write-Step 'Checking for Node.js / npx'
    $node = Get-Command node -ErrorAction SilentlyContinue
    $npx  = Get-Command npx  -ErrorAction SilentlyContinue
    if (-not $node -or -not $npx) {
        throw "Node.js (which provides npx) was not found on PATH. Install the LTS build from https://nodejs.org/en/download and re-run this script."
    }
    Write-Info ("node: " + (& node --version))
    Write-Info ("npx:  " + (& npx  --version))
}

function Install-WorkerDependencies {
    Write-Step 'Ensuring worker dependencies are installed'
    $nodeModulesDir = Join-Path $ScriptDirectory 'node_modules'
    if (-not (Test-Path $nodeModulesDir)) {
        Push-Location $ScriptDirectory
        try {
            & npm install
            if ($LASTEXITCODE -ne 0) {
                throw "npm install exited with code $LASTEXITCODE."
            }
        }
        finally {
            Pop-Location
        }
    } else {
        Write-Info 'node_modules already present.'
    }
}

function Read-SecretsFile {
    Write-Step 'Reading .secrets.local'
    if (-not (Test-Path $SecretsFilePath)) {
        if (Test-Path $SecretsExamplePath) {
            Copy-Item $SecretsExamplePath $SecretsFilePath
            Write-Warn "Created .secrets.local from the example template."
            Write-Warn "Edit that file, paste your real API keys, then re-run this script."
            Write-Warn "Opening it in Notepad now..."
            Start-Process notepad.exe $SecretsFilePath
            exit 0
        } else {
            throw "Neither .secrets.local nor .secrets.local.example was found in $ScriptDirectory."
        }
    }

    $secrets = [ordered]@{}
    foreach ($rawLine in Get-Content -LiteralPath $SecretsFilePath) {
        $line = $rawLine.Trim()
        if (-not $line)            { continue }
        if ($line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $name  = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        # Strip surrounding quotes if the user wrapped the value
        if ($value.Length -ge 2 -and (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        )) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $secrets[$name] = $value
    }

    $populated = @($secrets.GetEnumerator() | Where-Object { $_.Value })
    Write-Info ("Found {0} key(s) in .secrets.local; {1} populated, {2} blank." -f $secrets.Count, $populated.Count, ($secrets.Count - $populated.Count))
    if ($populated.Count -eq 0) {
        Write-Warn ".secrets.local has no populated keys. Edit it and re-run."
        Write-Warn $SecretsFilePath
        Start-Process notepad.exe $SecretsFilePath
        exit 0
    }
    return $secrets
}

function Assert-WranglerLogin {
    Write-Step 'Checking Cloudflare login'
    Push-Location $ScriptDirectory
    try {
        $whoami = & npx --yes wrangler whoami 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $whoami -match 'You are not authenticated') {
            Write-Info 'Not logged in -- opening browser for Cloudflare login...'
            & npx --yes wrangler login
            if ($LASTEXITCODE -ne 0) {
                throw "wrangler login exited with code $LASTEXITCODE."
            }
        } else {
            $emailLine = ($whoami -split "`n" | Where-Object { $_ -match 'associated with the email' } | Select-Object -First 1)
            if ($emailLine) {
                Write-Info $emailLine.Trim()
            } else {
                Write-Info 'Already logged into Cloudflare.'
            }
        }
    }
    finally {
        Pop-Location
    }
}

function Set-WorkerSecret {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Value
    )
    Push-Location $ScriptDirectory
    try {
        # Pipe the value to wrangler's stdin so it never lands on the command
        # line (and never shows up in process listings).
        $output = $Value | & npx --yes wrangler secret put $Name 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host $output
            throw "wrangler secret put $Name failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

function Push-AllSecrets {
    param([Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Secrets)
    Write-Step 'Pushing secrets to Cloudflare'
    foreach ($entry in $Secrets.GetEnumerator()) {
        if (-not $entry.Value) {
            Write-Info ("skip {0} (blank in .secrets.local)" -f $entry.Key)
            continue
        }
        Write-Info ("set  {0}" -f $entry.Key)
        Set-WorkerSecret -Name $entry.Key -Value $entry.Value
    }
}

function Invoke-WorkerDeploy {
    if ($SkipDeploy) {
        Write-Step 'Skipping deploy (-SkipDeploy)'
        return
    }
    Write-Step 'Deploying Worker'
    Push-Location $ScriptDirectory
    try {
        & npx --yes wrangler deploy
        if ($LASTEXITCODE -ne 0) {
            throw "wrangler deploy exited with code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

function Ensure-DesktopShortcut {
    if ($NoShortcut) { return }
    if (-not (Test-Path $BatWrapperPath)) { return }
    if (Test-Path $DesktopShortcutPath) {
        # Refresh target/working dir each run so a moved repo still works.
        try {
            $shell = New-Object -ComObject WScript.Shell
            $existing = $shell.CreateShortcut($DesktopShortcutPath)
            if ($existing.TargetPath -eq $BatWrapperPath) {
                return
            }
        } catch { }
    }
    try {
        $shell    = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($DesktopShortcutPath)
        $shortcut.TargetPath       = $BatWrapperPath
        $shortcut.WorkingDirectory = $ScriptDirectory
        $shortcut.IconLocation     = "$env:SystemRoot\System32\SHELL32.dll,316"  # blue gear icon
        $shortcut.Description      = 'Push API keys from .secrets.local to the Clicky Cloudflare Worker.'
        $shortcut.Save()
        Write-Info ("Desktop shortcut: " + $DesktopShortcutPath)
    } catch {
        Write-Warn ("Could not create Desktop shortcut: " + $_.Exception.Message)
    }
}

# ---------- Main ----------

try {
    Write-Host ''
    Write-Host 'Clicky Worker configurator' -ForegroundColor White
    Write-Host '==========================' -ForegroundColor White

    Assert-Node
    Install-WorkerDependencies
    $secrets = Read-SecretsFile
    Assert-WranglerLogin
    Push-AllSecrets -Secrets $secrets
    Invoke-WorkerDeploy
    Ensure-DesktopShortcut

    Write-Host ''
    Write-Host 'Worker configured.' -ForegroundColor Green
    if (-not $SkipDeploy) {
        Write-Host 'Look in the deploy output above for your Worker URL ' -ForegroundColor Green -NoNewline
        Write-Host '(https://clicky-proxy.<your-subdomain>.workers.dev).' -ForegroundColor Green
        Write-Host 'Paste it into windows\Clicky\Services\WorkerConfig.cs and re-run the Clicky installer.' -ForegroundColor Green
    }
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Host ('Configuration failed: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    exit 1
}
