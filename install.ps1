<#
.SYNOPSIS
    Bootstrap installer for Conduit (Conduit.ps1).

.DESCRIPTION
    One-command deployment. This installer:
      1. Self-elevates to Administrator (re-launches via UAC if needed). If a local
         PowerShell 7 already exists, elevation targets it so you land directly in
         an elevated pwsh 7 session.
      2. Ensures it is running under PowerShell 7: it scans for a locally installed
         pwsh (PATH, the App Paths registry, and the usual install directories) and
         re-launches itself under it. Only if none is found does it download/install
         PowerShell 7 - via winget, falling back to Microsoft's official MSI installer.
      3. Downloads the latest Conduit.ps1 from GitHub to a stable path.
      4. Either runs the server now, or registers a scheduled task that starts it at
         boot (running as SYSTEM, highest privileges, output logged to a file).

    Safe to launch from Windows PowerShell 5.1 or PowerShell 7.

.PARAMETER Ref
    Git branch or tag to download from. Default 'main'. Pin to a tag for stable rollouts.

.PARAMETER InstallDir
    Where the script (and task log) live. Default "$env:ProgramData\Conduit".

.PARAMETER AsTask
    Register + start a scheduled task (SYSTEM, at startup) instead of running in this console.

.PARAMETER NoStart
    Download/install only; don't run the server or start the task.

.PARAMETER Uninstall
    Remove the scheduled task and the install directory, then exit.

.PARAMETER RootDirectory
    Passed through to Conduit.ps1 (directory whose files are served).

.PARAMETER Port
    Passed through to Conduit.ps1 (HTTPS port; omit for auto-select).

.PARAMETER Username
    Passed through to Conduit.ps1 (Basic-auth username).

.PARAMETER Password
    Passed through to Conduit.ps1 (Basic-auth password). For -AsTask, if
    omitted the installer generates one and prints it (a task runs head-less, so a
    password the server would otherwise print to the console would be lost).

.EXAMPLE
    # Run interactively (ensures pwsh 7, downloads, starts the server in this window):
    Set-ExecutionPolicy Bypass -Scope Process -Force; $i="$env:TEMP\conduit-install.ps1"; iwr https://raw.githubusercontent.com/madwiz92/Conduit/main/install.ps1 -OutFile $i -UseBasicParsing; & $i

.EXAMPLE
    # Install as an auto-start scheduled task:
    Set-ExecutionPolicy Bypass -Scope Process -Force; $i="$env:TEMP\conduit-install.ps1"; iwr https://raw.githubusercontent.com/madwiz92/Conduit/main/install.ps1 -OutFile $i -UseBasicParsing; & $i -AsTask
#>
[CmdletBinding()]
param(
    [string]$Ref          = 'main',
    [string]$InstallDir   = "$env:ProgramData\Conduit",
    [switch]$AsTask,
    [switch]$NoStart,
    [switch]$Uninstall,
    [string]$RootDirectory,
    [int]   $Port,
    [string]$Username,
    [string]$Password
)

$ErrorActionPreference = 'Stop'

$Repo       = 'madwiz92/Conduit'
$ScriptName = 'Conduit.ps1'
$RawUrl     = "https://raw.githubusercontent.com/$Repo/$Ref/$ScriptName"
$Target     = Join-Path $InstallDir $ScriptName
$LogFile    = Join-Path $InstallDir 'Conduit.log'
$TaskName   = 'Conduit'

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }

# Locate an installed PowerShell 7+ (pwsh) without downloading anything.
# Checks, in order: PATH, the App Paths registry entry, and common install dirs.
# Returns the full path to pwsh.exe, or $null if none is found.
function Get-PwshPath {
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    foreach ($hive in 'HKLM:', 'HKCU:') {
        $rk = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe"
        try {
            $p = (Get-ItemProperty -Path $rk -ErrorAction Stop).'(default)'
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        } catch { }
    }

    $roots = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $roots += (Join-Path $base 'PowerShell') }
    }
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell') }
    foreach ($r in ($roots | Where-Object { Test-Path -LiteralPath $_ })) {
        $exe = Get-ChildItem -Path $r -Recurse -Filter pwsh.exe -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    return $null
}

$isPwsh7 = $PSVersionTable.PSVersion.Major -ge 7

# ---------------------------------------------------------------------------
# 1. Ensure Administrator. Re-launch elevated if needed - targeting a local
#    pwsh 7 when one exists, so we land directly in an elevated PS 7 session.
# ---------------------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if (-not $PSCommandPath) {
        throw "Run the installer from a downloaded file (not piped to iex) so it can self-elevate. See the one-liner in the README."
    }
    Write-Step "Elevating to Administrator (UAC)..."
    $localPwsh = Get-PwshPath
    $hostExe   = if ($localPwsh) { $localPwsh } else { (Get-Process -Id $PID).Path }

    function Quote-Cmd($s) { if ([string]$s -match '[\s"]') { '"' + ([string]$s -replace '"', '\"') + '"' } else { [string]$s } }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Cmd $PSCommandPath)))
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value.IsPresent) { $parts.Add("-$($kv.Key)") }
        } else {
            $parts.Add("-$($kv.Key)"); $parts.Add((Quote-Cmd $kv.Value))
        }
    }
    Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList ($parts.ToArray() -join ' ')
    return
}

# ---------------------------------------------------------------------------
# 2. Uninstall (if requested) and exit. Doesn't need pwsh 7.
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
# 3. Ensure PowerShell 7, then ensure we are actually running under it.
#    Scan for a local pwsh first; download/install only if none is found; then
#    re-launch this installer under pwsh 7 (in the same elevated console).
# ---------------------------------------------------------------------------
if (-not $isPwsh7) {
    $pwsh = Get-PwshPath
    if (-not $pwsh) {
        Write-Step "PowerShell 7 not found locally - installing..."
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements
        } else {
            Write-Step "winget unavailable - using Microsoft's official install-powershell.ps1 (MSI)."
            Invoke-Expression "& { $(Invoke-RestMethod https://aka.ms/install-powershell.ps1) } -UseMSI -Quiet"
        }
        $pwsh = Get-PwshPath
        if (-not $pwsh) { throw "PowerShell 7 install did not complete. Install it manually, then re-run." }
    } else {
        Write-Step "Found local PowerShell 7: $pwsh"
    }

    Write-Step "Re-launching installer under PowerShell 7..."
    $reexec = New-Object System.Collections.Generic.List[string]
    $reexec.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath))
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value.IsPresent) { $reexec.Add("-$($kv.Key)") }
        } else {
            $reexec.Add("-$($kv.Key)"); $reexec.Add([string]$kv.Value)
        }
    }
    $reexecArr = $reexec.ToArray()
    & $pwsh @reexecArr
    exit $LASTEXITCODE
}

# ===========================================================================
# From here on we are guaranteed: Administrator + PowerShell 7.
# ===========================================================================
$pwsh = (Get-Process -Id $PID).Path     # the pwsh 7 we are running under
Write-Step "PowerShell 7: $pwsh"

# ---------------------------------------------------------------------------
# 4. Download the latest script.
# ---------------------------------------------------------------------------
Write-Step "Downloading $ScriptName ($Ref) -> $Target"
[void](New-Item -ItemType Directory -Path $InstallDir -Force)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
Invoke-WebRequest -Uri $RawUrl -OutFile $Target -UseBasicParsing

# ---------------------------------------------------------------------------
# 5. Collect pass-through parameters for Conduit.ps1.
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

    function Quote-Ps($s) { "'" + ([string]$s -replace "'", "''") + "'" }
    $inner = "& $(Quote-Ps $Target)"
    foreach ($k in $pass.Keys) { $inner += " -$k $(Quote-Ps $pass[$k])" }
    $inner += " *>> $(Quote-Ps $LogFile)"
    $taskArgument = "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`""

    $action    = New-ScheduledTaskAction -Execute $pwsh -Argument $taskArgument
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
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
Write-Step "Starting Conduit (Ctrl+C to stop)..."
$runArgs = New-Object System.Collections.Generic.List[string]
$runArgs.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Target))
foreach ($k in $pass.Keys) { $runArgs.Add("-$k"); $runArgs.Add($pass[$k]) }
$runArgsArr = $runArgs.ToArray()
& $pwsh @runArgsArr
