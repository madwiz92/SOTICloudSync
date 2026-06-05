<#
.SYNOPSIS
    Bootstrap installer for SOTICloudSync (WebFileServerSync.ps1).

.DESCRIPTION
    One-command deployment. This installer:
      1. Self-elevates to Administrator (re-launches via UAC if needed).
      2. Downloads the latest WebFileServerSync.ps1 from GitHub to a stable path.
      3. Ensures PowerShell 7 (pwsh) is installed - via winget, falling back to
         Microsoft's official MSI installer.
      4. Either runs the server now, or registers a scheduled task that starts it
         at boot (running as SYSTEM, highest privileges, output logged to a file).

    Safe to launch from Windows PowerShell 5.1 or PowerShell 7 - the installer
    itself is 5.1-compatible and only the file server requires pwsh 7.

.PARAMETER Ref
    Git branch or tag to download from. Default 'main'. Pin to a tag for stable rollouts.

.PARAMETER InstallDir
    Where the script (and task log) live. Default "$env:ProgramData\SOTICloudSync".

.PARAMETER AsTask
    Register + start a scheduled task (SYSTEM, at startup) instead of running in this console.

.PARAMETER NoStart
    Download/install only; don't run the server or start the task.

.PARAMETER Uninstall
    Remove the scheduled task and the install directory, then exit.

.PARAMETER RootDirectory
    Passed through to WebFileServerSync.ps1 (directory whose files are served).

.PARAMETER Port
    Passed through to WebFileServerSync.ps1 (HTTPS port; omit for auto-select).

.PARAMETER Username
    Passed through to WebFileServerSync.ps1 (Basic-auth username).

.PARAMETER Password
    Passed through to WebFileServerSync.ps1 (Basic-auth password). For -AsTask, if
    omitted the installer generates one and prints it (a task runs head-less, so a
    password the server would otherwise print to the console would be lost).

.EXAMPLE
    # Run interactively (downloads, ensures pwsh 7, starts the server in this window):
    Set-ExecutionPolicy Bypass -Scope Process -Force; $i="$env:TEMP\soticloudsync-install.ps1"; iwr https://raw.githubusercontent.com/madwiz92/SOTICloudSync/main/install.ps1 -OutFile $i -UseBasicParsing; & $i

.EXAMPLE
    # Install as an auto-start scheduled task:
    Set-ExecutionPolicy Bypass -Scope Process -Force; $i="$env:TEMP\soticloudsync-install.ps1"; iwr https://raw.githubusercontent.com/madwiz92/SOTICloudSync/main/install.ps1 -OutFile $i -UseBasicParsing; & $i -AsTask
#>
[CmdletBinding()]
param(
    [string]$Ref          = 'main',
    [string]$InstallDir   = "$env:ProgramData\SOTICloudSync",
    [switch]$AsTask,
    [switch]$NoStart,
    [switch]$Uninstall,
    [string]$RootDirectory,
    [int]   $Port,
    [string]$Username,
    [string]$Password
)

$ErrorActionPreference = 'Stop'

$Repo       = 'madwiz92/SOTICloudSync'
$ScriptName = 'WebFileServerSync.ps1'
$RawUrl     = "https://raw.githubusercontent.com/$Repo/$Ref/$ScriptName"
$Target     = Join-Path $InstallDir $ScriptName
$LogFile    = Join-Path $InstallDir 'SOTICloudSync.log'
$TaskName   = 'SOTICloudSync'

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# 1. Ensure Administrator - re-launch elevated (same host + same args) if not.
# ---------------------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if (-not $PSCommandPath) {
        throw "Run the installer from a downloaded file (not piped to iex) so it can self-elevate. See the one-liner in the README."
    }
    Write-Step "Elevating to Administrator (UAC)..."
    $hostExe = (Get-Process -Id $PID).Path        # powershell.exe or pwsh.exe
    $relaunch = New-Object System.Collections.Generic.List[string]
    $relaunch.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)))
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value.IsPresent) { $relaunch.Add("-$($kv.Key)") }
        } else {
            $relaunch.Add("-$($kv.Key)"); $relaunch.Add(('"{0}"' -f $kv.Value))
        }
    }
    Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $relaunch
    return
}

# ---------------------------------------------------------------------------
# 2. Uninstall (if requested) and exit.
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Write-Step "Uninstalling..."
    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Step "Removed scheduled task '$TaskName'."
        }
    } catch { Write-Host "  (task removal: $($_.Exception.Message))" -ForegroundColor DarkYellow }
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Step "Removed $InstallDir."
    }
    Write-Step "Done."
    return
}

# ---------------------------------------------------------------------------
# 3. Download the latest script.
# ---------------------------------------------------------------------------
Write-Step "Downloading $ScriptName ($Ref) -> $Target"
[void](New-Item -ItemType Directory -Path $InstallDir -Force)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
Invoke-WebRequest -Uri $RawUrl -OutFile $Target -UseBasicParsing

# ---------------------------------------------------------------------------
# 4. Ensure PowerShell 7.
# ---------------------------------------------------------------------------
function Get-PwshPath {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fixed = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path $fixed) { return $fixed }
    return $null
}
$pwsh = Get-PwshPath
if (-not $pwsh) {
    Write-Step "PowerShell 7 not found - installing..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements
    } else {
        Write-Step "winget unavailable - using Microsoft's official install-powershell.ps1 (MSI)."
        Invoke-Expression "& { $(Invoke-RestMethod https://aka.ms/install-powershell.ps1) } -UseMSI -Quiet"
    }
    $pwsh = Get-PwshPath
    if (-not $pwsh) { throw "PowerShell 7 install did not complete. Install it manually, then re-run." }
}
Write-Step "PowerShell 7: $pwsh"

# ---------------------------------------------------------------------------
# 5. Collect pass-through parameters for WebFileServerSync.ps1.
#    Only forward what the caller explicitly supplied (defaults stay in the script).
# ---------------------------------------------------------------------------
$pass = [ordered]@{}
foreach ($k in 'RootDirectory', 'Port', 'Username', 'Password') {
    if ($PSBoundParameters.ContainsKey($k)) { $pass[$k] = [string]$PSBoundParameters[$k] }
}

if ($NoStart) {
    Write-Step "Installed to $Target. Not starting (-NoStart)."
    return
}

# ---------------------------------------------------------------------------
# 6a. Scheduled-task mode: run as SYSTEM at startup, log to a file.
# ---------------------------------------------------------------------------
if ($AsTask) {
    if (-not $pass.Contains('Password')) {
        $abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
        $pass['Password'] = -join (1..12 | ForEach-Object { $abc[(Get-Random -Maximum $abc.Length)] })
        Write-Host ""
        Write-Host "  Generated password (save this - the task runs head-less): $($pass['Password'])" -ForegroundColor Yellow
        Write-Host ""
    }

    function Quote($s) { "'" + ([string]$s -replace "'", "''") + "'" }
    $inner = "& $(Quote $Target)"
    foreach ($k in $pass.Keys) { $inner += " -$k $(Quote $pass[$k])" }
    $inner += " *>> $(Quote $LogFile)"
    $taskArgument = "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`""

    $action   = New-ScheduledTaskAction -Execute $pwsh -Argument $taskArgument
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $principal= New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                    -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                    -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Step "Registered + started scheduled task '$TaskName'."
    Write-Step "Logs: $LogFile"
    return
}

# ---------------------------------------------------------------------------
# 6b. Interactive mode: run the server in this console (Ctrl+C to stop).
# ---------------------------------------------------------------------------
Write-Step "Starting SOTICloudSync (Ctrl+C to stop)..."
$runArgs = New-Object System.Collections.Generic.List[string]
$runArgs.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Target))
foreach ($k in $pass.Keys) { $runArgs.Add("-$k"); $runArgs.Add($pass[$k]) }
& $pwsh @runArgs
