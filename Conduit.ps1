<#
.SYNOPSIS
    Conduit.ps1 - HTTPS file server with browser UI and server-to-server transfer.

.DESCRIPTION
    Same self-contained HTTPS file server (browse / upload /
    download / delete a local directory), plus a second pane that connects to ANOTHER
    instance of this server and transfers files directly between the two.

    Transfers are SERVER-BROKERED: this server pulls/pushes files to the remote over
    HTTPS itself, so there are no browser memory limits and no CORS issues. Transfers
    COPY files (the source copy is kept). Files are chosen with checkboxes and moved
    with the center -> (local to remote) and <- (remote to local) arrows. In-progress
    transfers can be stopped, and the destination's free space is checked first.

    The remote TLS certificate is validated strictly by default; if it fails (e.g. a
    name mismatch when connecting by IP to a wildcard-cert server) the user is prompted
    and may choose to continue, which relaxes validation for that connection only.

    No external dependencies; runs on stock Windows 10/11 or Server 2019/2022 with
    PowerShell 5.1+. Must be run as Administrator.

.PARAMETER RootDirectory
    Directory whose files are served. Created if missing. All file I/O is scoped here.

.PARAMETER Port
    TCP port to listen on (HTTPS). If 0 (default), the first available port from
    the preferred list (5496, 5494, 443) is auto-selected.

.PARAMETER Username
    HTTP Basic Auth username. Default "admin".

.PARAMETER Password
    HTTP Basic Auth password. If empty, a random 12-char alphanumeric password is
    generated and printed to the console at startup.

.EXAMPLE
    .\Conduit.ps1
#>

param(
    [string]$RootDirectory = "C:\cloud\transfer",
    [int]$Port             = 0,     # 0 = auto-select from preferred list (5496, 5494, 443).
    [string]$Username      = "admin",
    [string]$Password      = ""     # If empty, a random 12-char password is generated.
)

$ErrorActionPreference = 'Stop'

# Application ID used for the netsh SSL cert binding (arbitrary but stable GUID).
$AppId  = '{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}'
# $IpPort is set after the port is chosen (see "Port selection" below).

# Compiled helper: a pass-through Stream that counts bytes flowing through it, so
# server-to-server transfers can report live progress. Loaded into the AppDomain
# once here; all runspace-pool threads then share the type. Guarded so re-running
# the script in the same PowerShell session does not fail with "type exists".
if (-not ('ProgressStream' -as [type])) {
Add-Type @"
using System;
using System.IO;
using System.Threading;
public class ProgressStream : Stream {
    private Stream _inner; private long[] _counter;
    public ProgressStream(Stream inner, long[] counter){ _inner = inner; _counter = counter; }
    public override bool CanRead  { get { return _inner.CanRead; } }
    public override bool CanSeek  { get { return _inner.CanSeek; } }
    public override bool CanWrite { get { return _inner.CanWrite; } }
    public override long Length   { get { return _inner.Length; } }
    public override long Position { get { return _inner.Position; } set { _inner.Position = value; } }
    public override void Flush(){ _inner.Flush(); }
    public override int Read(byte[] b, int o, int c){ int n = _inner.Read(b, o, c); if (n > 0) Interlocked.Add(ref _counter[0], (long)n); return n; }
    public override void Write(byte[] b, int o, int c){ _inner.Write(b, o, c); Interlocked.Add(ref _counter[0], (long)c); }
    public override long Seek(long off, SeekOrigin or){ return _inner.Seek(off, or); }
    public override void SetLength(long v){ _inner.SetLength(v); }
    protected override void Dispose(bool disposing){ if (disposing) _inner.Dispose(); base.Dispose(disposing); }
}
"@
}

# ----------------------------------------------------------------------------
# Console / logging helpers (main thread)
# ----------------------------------------------------------------------------

# Build the access URL. For a wildcard cert (CN=*.domain) the server is reached
# at <hostname>.<domain> so the certificate name matches; otherwise plain hostname.
function Get-ServerUrl {
    param([string]$Subject, [int]$Port)
    $hostname = [System.Net.Dns]::GetHostName()
    if ($Subject -match 'CN=([^,]+)') {
        $cn = $matches[1].Trim()
        if ($cn.StartsWith('*.')) {
            return "https://{0}.{1}:{2}" -f $hostname, $cn.Substring(2), $Port
        }
    }
    return "https://{0}:{1}" -f $hostname, $Port
}

function Write-Banner {
    param([string]$Subject, [string]$Thumbprint, [string]$Pass, [string]$Url)

    $line = '=' * 60
    # The URL / username / password are each printed alone on a line at column 0
    # in a bright colour, so they can be triple-clicked and copied cleanly.
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  Conduit is running" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  URL (open in a browser):" -ForegroundColor DarkGray
    Write-Host $Url      -ForegroundColor Green
    Write-Host ""
    Write-Host "  Password (login is password-only):" -ForegroundColor DarkGray
    Write-Host $Pass     -ForegroundColor Yellow
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host ("  Certificate : {0}" -f $Subject)     -ForegroundColor DarkGray
    Write-Host ("  Thumbprint  : {0}" -f $Thumbprint)  -ForegroundColor DarkGray
    Write-Host ("  Root dir    : {0}" -f $RootDirectory) -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  Press Ctrl+C to stop." -ForegroundColor Yellow
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

# ----------------------------------------------------------------------------
# 1. Elevation check
# ----------------------------------------------------------------------------

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "       Administrative rights are required to bind the HTTPS listener and SSL certificate." -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------------------
# 1b. Port selection (prefer 5496, then 5494, then 443)
# ----------------------------------------------------------------------------

function Test-PortAvailable {
    param([int]$p)
    try {
        $inUse = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue
        if ($inUse) { return $false }
    }
    catch { }
    try {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $p)
        $probe.Start(); $probe.Stop()
        return $true
    }
    catch { return $false }
}

if ($Port -eq 0) {
    $preferredPorts = @(5496, 5494, 443)
    $Port = $preferredPorts | Where-Object { Test-PortAvailable $_ } | Select-Object -First 1
    if (-not $Port) {
        Write-Host "ERROR: None of the preferred ports (5496, 5494, 443) are available." -ForegroundColor Red
        exit 1
    }
    Write-Host "Auto-selected available port: $Port"
}
else {
    if (-not (Test-PortAvailable $Port)) {
        Write-Host "ERROR: Port $Port is already in use." -ForegroundColor Red
        exit 1
    }
}

$IpPort = "0.0.0.0:$Port"

# ----------------------------------------------------------------------------
# 2. Password generation (if not supplied)
# ----------------------------------------------------------------------------

if ([string]::IsNullOrEmpty($Password)) {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $Password = -join (1..12 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
}

# ----------------------------------------------------------------------------
# 3. Ensure root directory exists
# ----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $RootDirectory -PathType Container)) {
    try {
        New-Item -ItemType Directory -Path $RootDirectory -Force | Out-Null
        Write-Host "Created root directory: $RootDirectory"
    }
    catch {
        Write-Host "ERROR: Could not create root directory '$RootDirectory': $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
$RootFull = [System.IO.Path]::GetFullPath($RootDirectory)

# ----------------------------------------------------------------------------
# 4. Certificate selection (match wildcard, valid, farthest expiry auto-picked)
# ----------------------------------------------------------------------------

$wildcardPatterns = @('*.mobicontrol.cloud', '*.mobicontrolcloud.com')

function Get-CertSanText {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $san = $Cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
    if ($san) { return $san.Format($true) }
    return ''
}

function Test-CertMatches {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $haystack = "$($Cert.Subject)`n$(Get-CertSanText -Cert $Cert)"
    foreach ($pat in $wildcardPatterns) {
        if ($haystack -match [regex]::Escape($pat)) { return $true }
    }
    return $false
}

Write-Host "Searching certificate stores for a matching wildcard certificate..."
$now = Get-Date
$candidates = New-Object System.Collections.ArrayList
foreach ($storePath in @('Cert:\LocalMachine\My', 'Cert:\CurrentUser\My')) {
    try {
        Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue | ForEach-Object {
            if ((Test-CertMatches -Cert $_) -and $_.NotBefore -le $now -and $_.NotAfter -ge $now) {
                [void]$candidates.Add([pscustomobject]@{
                    Store      = $storePath
                    Thumbprint = $_.Thumbprint
                    Subject    = $_.Subject
                    Expires    = $_.NotAfter
                    Cert       = $_
                })
            }
        }
    }
    catch {
        Write-Host "  (Could not read $storePath : $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

if ($candidates.Count -eq 0) {
    Write-Host "ERROR: No valid (unexpired) certificate found whose Subject or SAN matches:" -ForegroundColor Red
    foreach ($p in $wildcardPatterns) { Write-Host "         $p" -ForegroundColor Red }
    Write-Host "       Install a matching wildcard certificate into LocalMachine\My or CurrentUser\My and retry." -ForegroundColor Red
    exit 1
}

$candidates = @($candidates | Sort-Object -Property Expires -Descending)

if ($candidates.Count -gt 1) {
    Write-Host "Multiple valid matching certificates found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("  {0}  {1}  [{2}]  expires {3}" -f $candidates[$i].Thumbprint, $candidates[$i].Subject, $candidates[$i].Store, $candidates[$i].Expires.ToString('yyyy-MM-dd'))
    }
}

$selectedCert = $candidates[0]
Write-Host "Selected certificate (farthest expiry):" -ForegroundColor Green
Write-Host ("  {0}  {1}  [{2}]  expires {3}" -f $selectedCert.Thumbprint, $selectedCert.Subject, $selectedCert.Store, $selectedCert.Expires.ToString('yyyy-MM-dd'))

if (-not $selectedCert.Cert.HasPrivateKey) {
    Write-Host "WARNING: Selected certificate has no accessible private key. TLS will likely fail." -ForegroundColor Yellow
}

# ----------------------------------------------------------------------------
# 5. Bind the certificate to the port via netsh
# ----------------------------------------------------------------------------

function Set-SslBinding {
    param([string]$Thumbprint)
    $existing = netsh http show sslcert ipport=$IpPort 2>$null | Out-String
    if ($existing -match [regex]::Escape($IpPort)) {
        Write-Host "Existing SSL binding found on $IpPort - removing it first..."
        netsh http delete sslcert ipport=$IpPort 2>&1 | Out-Null
    }
    Write-Host "Binding certificate $Thumbprint to $IpPort ..."
    $add = netsh http add sslcert ipport=$IpPort certhash=$Thumbprint appid="$AppId" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "netsh failed to bind the certificate:`n$add"
    }
}

function Remove-SslBinding {
    try { netsh http delete sslcert ipport=$IpPort 2>&1 | Out-Null } catch { }
}

try {
    Set-SslBinding -Thumbprint $selectedCert.Thumbprint
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------------------
# 5b. Windows Firewall rule (only ever touch the dedicated port 5496)
# ----------------------------------------------------------------------------

$FirewallManagedPort = 5496
$FirewallRuleName    = "Conduit-5496"
$FirewallRuleCreated = $false

function Test-FirewallPortOpen {
    param([int]$p)
    try {
        $r = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction Stop |
             Where-Object { ($_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq $p }
        return [bool]$r
    }
    catch {
        $check = netsh advfirewall firewall show rule name="$FirewallRuleName" 2>$null | Out-String
        return ($check -match [regex]::Escape($FirewallRuleName))
    }
}

function Remove-FirewallRule {
    param([string]$name)
    try { Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue } catch { }
    try { netsh advfirewall firewall delete rule name="$name" 2>&1 | Out-Null } catch { }
}

if ($Port -eq $FirewallManagedPort) {
    Write-Host "Checking Windows Firewall for an inbound rule on TCP $Port (this can take a moment)..."
    if (Test-FirewallPortOpen -p $Port) {
        Write-Host "Inbound TCP $Port is already allowed by an existing firewall rule - leaving it untouched." -ForegroundColor Green
    }
    else {
        Write-Host "Firewall rule not found, creating..." -ForegroundColor Yellow
        try {
            New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null
            $FirewallRuleCreated = $true
            Write-Host "Added inbound firewall rule '$FirewallRuleName' (TCP $Port)." -ForegroundColor Green
        }
        catch {
            netsh advfirewall firewall add rule name="$FirewallRuleName" dir=in action=allow protocol=TCP localport=$Port 2>&1 | Out-Null
            $FirewallRuleCreated = $true
            Write-Host "Added inbound firewall rule '$FirewallRuleName' (TCP $Port, via netsh)." -ForegroundColor Green
        }
    }
}
else {
    Write-Host "Port $Port is not the managed firewall port ($FirewallManagedPort) - firewall left untouched."
}

# ----------------------------------------------------------------------------
# 6. Embedded web UI (single-quoted here-string => no PowerShell interpolation)
# ----------------------------------------------------------------------------

$IndexHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Conduit</title>
<style>
  * { box-sizing: border-box; }
  body { margin: 0; font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
         background: #f4f6f9; color: #1f2933; }
  header { background: #1f2933; color: #fff; padding: 14px 24px; display: flex;
           align-items: center; justify-content: space-between; box-shadow: 0 2px 6px rgba(0,0,0,.2); }
  header .title { font-size: 20px; font-weight: 600; display: flex; align-items: center; gap: 12px; }
  header .hostname { font-size: 13px; font-weight: 600; color: #cbd2d9; background: #3b4754;
                     padding: 4px 12px; border-radius: 999px; letter-spacing: .5px; }
  .netmeter { display: flex; align-items: center; gap: 10px; }
  #netGraph { background: #161d24; border-radius: 4px; }
  .wrap { display: flex; gap: 16px; padding: 24px; flex-wrap: wrap; align-items: stretch; }
  .panel { background: #fff; border-radius: 8px; box-shadow: 0 1px 4px rgba(0,0,0,.08);
           flex: 1 1 380px; min-width: 300px; display: flex; flex-direction: column; }
  .panel h2 { margin: 0; padding: 12px 16px; font-size: 15px; border-bottom: 1px solid #e4e7eb;
              display: flex; align-items: center; justify-content: space-between; gap: 10px;
              min-height: 60px; }
  .panel h2 .left { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
  .panel h2 .acts { white-space: nowrap; }
  .panel h2 .acts button { margin-left: 6px; }
  .panel .body { padding: 14px 16px; flex: 1; }
  .meta { font-size: 12px; color: #616e7c; font-weight: 400; }
  .hostname2 { color: #1f2933; font-weight: 600; }
  code { background: #eef1f4; color: #1f2933; padding: 2px 6px; border-radius: 4px;
         font-family: Consolas, Menlo, monospace; font-size: 12px; }
  button { cursor: pointer; border: none; border-radius: 5px; padding: 7px 12px; font-size: 13px; }
  button:disabled { opacity: .45; cursor: not-allowed; }
  .btn { background: #3b82f6; color: #fff; }
  .btn:hover:not(:disabled) { background: #2563eb; }
  .btn-light { background: #e4e7eb; color: #1f2933; }
  .btn-light:hover:not(:disabled) { background: #cbd2d9; }
  .btn-danger { background: #ef4444; color: #fff; }
  .btn-danger:hover:not(:disabled) { background: #dc2626; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 7px 6px; border-bottom: 1px solid #eef1f4; }
  th { color: #616e7c; font-weight: 600; }
  td.actions, th.actions { text-align: right; white-space: nowrap; }
  td.chk, th.chk { width: 26px; text-align: center; }
  .empty { color: #9aa5b1; text-align: center; padding: 28px 12px; }
  .progress { height: 8px; background: #e4e7eb; border-radius: 5px; overflow: hidden;
              margin-bottom: 12px; display: none; }
  .progress > div { height: 100%; width: 0; background: #3b82f6; transition: width .15s; }
  .msg { margin-top: 10px; font-size: 13px; min-height: 16px; }
  .msg.ok { color: #057a55; }
  .msg.err { color: #dc2626; }
  /* center transfer arrows */
  .arrows { flex: 0 0 64px; display: flex; flex-direction: column; gap: 12px;
            align-items: center; justify-content: center; }
  .arrowbtn { font-size: 20px; width: 52px; height: 46px; line-height: 1; }
  .arrows .label { font-size: 10px; color: #9aa5b1; text-align: center; }
  .xfermsg { font-size: 11px; color: #616e7c; text-align: center; max-width: 64px; }
  @media (max-width: 920px) {
    .arrows { flex-basis: 100%; flex-direction: row; }
  }
  .modal-bg { position: fixed; inset: 0; background: rgba(0,0,0,.5); display: none;
              align-items: center; justify-content: center; }
  .modal { background: #fff; border-radius: 8px; padding: 24px; width: 360px; box-shadow: 0 8px 30px rgba(0,0,0,.3); }
  .modal h3 { margin: 0 0 14px; }
  .modal input { width: 100%; padding: 8px; margin-bottom: 10px; border: 1px solid #cbd2d9;
                 border-radius: 5px; font-size: 14px; }
  .modal .hint { font-size: 12px; color: #616e7c; margin-bottom: 10px; }
</style>
</head>
<body>
<header>
  <div class="title">&#128193; Conduit <span class="hostname" id="host"></span></div>
  <div class="netmeter">
    <span class="meta" id="netLabel" style="color:#9aa5b1; min-width:64px; text-align:right">idle</span>
    <canvas id="netGraph" width="120" height="28" title="Network throughput"></canvas>
  </div>
</header>

<div class="wrap">
  <!-- ===== LOCAL pane ===== -->
  <div class="panel">
    <h2>
      <span class="left">Local: <span class="hostname2" id="localHost"></span>
        <span class="meta" id="localSummary"></span>
        <span class="meta">&#128193; <code>__ROOTDIR__</code></span></span>
      <span class="acts">
        <button class="btn" onclick="pickUpload('local')">&#11014; Upload</button>
        <button class="btn-light" onclick="loadLocal()" title="Refresh">&#8634;</button>
      </span>
    </h2>
    <div class="body">
      <div class="progress" id="localProgress"><div id="localBar"></div></div>
      <table>
        <thead><tr>
          <th class="chk"><input type="checkbox" id="localAll" onclick="toggleAll('local')"></th>
          <th>Filename</th><th>Size</th><th>Modified</th><th class="actions"></th>
        </tr></thead>
        <tbody id="localRows"></tbody>
      </table>
      <div class="empty" id="localEmpty" style="display:none">No files yet.</div>
      <div class="msg" id="localMsg"></div>
    </div>
  </div>

  <!-- ===== center arrows ===== -->
  <div class="arrows">
    <button class="btn arrowbtn" id="pushBtn" onclick="transfer('push')"
            title="Copy selected Local files to Remote" disabled>&#8594;</button>
    <button class="btn arrowbtn" id="pullBtn" onclick="transfer('pull')"
            title="Copy selected Remote files to Local" disabled>&#8592;</button>
    <button class="btn-danger arrowbtn" id="cancelBtn" onclick="cancelTransfer()"
            title="Stop the current transfer" style="display:none">&#9632; Stop</button>
    <div class="xfermsg" id="xferMsg"></div>
  </div>

  <!-- ===== REMOTE pane ===== -->
  <div class="panel">
    <h2>
      <span class="left">Remote: <span class="hostname2" id="remoteHost">(not connected)</span>
        <span class="meta" id="remoteSummary"></span></span>
      <span class="acts" id="remoteActions" style="display:none">
        <button class="btn" onclick="pickUpload('remote')">&#11014; Upload</button>
        <button class="btn-light" onclick="loadRemote()" title="Refresh">&#8634;</button>
        <button class="btn-light" onclick="disconnectRemote()">Disconnect</button>
      </span>
      <span class="acts" id="remoteConnectWrap">
        <button class="btn" onclick="connectRemote()">&#43; Add server</button>
      </span>
    </h2>
    <div class="body">
      <div class="empty" id="remoteDisconnected">
        Connect to another Conduit to browse and transfer its files.
      </div>
      <div id="remoteConnected" style="display:none">
        <div class="progress" id="remoteProgress"><div id="remoteBar"></div></div>
        <table>
          <thead><tr>
            <th class="chk"><input type="checkbox" id="remoteAll" onclick="toggleAll('remote')"></th>
            <th>Filename</th><th>Size</th><th>Modified</th><th class="actions"></th>
          </tr></thead>
          <tbody id="remoteRows"></tbody>
        </table>
        <div class="empty" id="remoteEmpty" style="display:none">No files yet.</div>
      </div>
      <div class="msg" id="remoteMsg"></div>
    </div>
  </div>
</div>

<!-- hidden file pickers -->
<input type="file" id="localFile"  multiple style="display:none">
<input type="file" id="remoteFile" multiple style="display:none">

<!-- Sign-in modal (local 401 fallback) -->
<div class="modal-bg" id="loginModal">
  <div class="modal">
    <h3>Sign in</h3>
    <input type="password" id="loginPass" placeholder="Password" autocomplete="current-password">
    <button class="btn" style="width:100%" onclick="submitLogin()">Sign in</button>
    <div class="msg err" id="loginErr"></div>
  </div>
</div>

<!-- Connect-to-server modal -->
<div class="modal-bg" id="connectModal">
  <div class="modal">
    <h3>Connect to a server</h3>
    <div class="hint">Enter the other server's URL and password.</div>
    <input type="text" id="connUrl" placeholder="https://hostname.mobicontrol.cloud:5496">
    <input type="password" id="connPass" placeholder="Password">
    <button class="btn" style="width:100%" onclick="submitConnect()">Connect</button>
    <button class="btn-light" style="width:100%; margin-top:8px" onclick="closeConnect()">Cancel</button>
    <div class="msg err" id="connErr"></div>
  </div>
</div>

<script>
"use strict";
const shortName = h => (h || '').split('.')[0].toUpperCase();
document.getElementById('host').textContent = shortName(location.hostname);
document.getElementById('localHost').textContent = shortName(location.hostname);

// ----- helpers -------------------------------------------------------------
function fmtSize(n) {
  if (n == null) return '';
  if (n < 1024) return n + ' B';
  const u = ['KB','MB','GB','TB']; let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return n.toFixed(1) + ' ' + u[i];
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function escapeJs(s) { return String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'"); }

// ----- network speed meter (Steam-style bar graph) -------------------------
// netReport(cumulativeBytes) is called repeatedly during an active transfer/
// upload with the running byte total; it derives an instantaneous speed. The
// graph ticks on a fixed interval and decays to idle when nothing is flowing.
const meter = { samples: new Array(48).fill(0), speed: 0, lastBytes: 0, lastTime: 0, lastUpdate: 0 };
function netReset() { meter.lastBytes = 0; meter.lastTime = performance.now(); }
function netReport(cum) {
  const t = performance.now();
  if (!meter.lastTime) { meter.lastTime = t; meter.lastBytes = cum; return; }
  const dt = (t - meter.lastTime) / 1000;
  if (dt >= 0.2) {
    let db = cum - meter.lastBytes; if (db < 0) db = 0;
    meter.speed = db / dt;
    meter.lastBytes = cum; meter.lastTime = t; meter.lastUpdate = t;
  }
}
function drawMeter() {
  const t = performance.now();
  if (t - meter.lastUpdate > 800) meter.speed = 0;     // decay to idle
  meter.samples.push(meter.speed); meter.samples.shift();
  document.getElementById('netLabel').textContent = meter.speed > 0 ? (fmtSize(meter.speed) + '/s') : 'idle';
  const cv = document.getElementById('netGraph'); if (!cv || !cv.getContext) return;
  const g = cv.getContext('2d'); g.clearRect(0, 0, cv.width, cv.height);
  const max = Math.max(65536, ...meter.samples);       // adaptive vertical scale
  const n = meter.samples.length, bw = cv.width / n;
  for (let i = 0; i < n; i++) {
    const h = Math.round((meter.samples[i] / max) * (cv.height - 2));
    g.fillStyle = meter.samples[i] > 0 ? '#34d399' : '#243038';
    g.fillRect(i * bw, cv.height - Math.max(1, h), Math.max(1, bw - 1), Math.max(1, h));
  }
}
setInterval(drawMeter, 250);

// ----- local auth (Basic) --------------------------------------------------
function authHeader() {
  const a = sessionStorage.getItem('auth');
  return a ? { 'Authorization': a } : {};
}
let loginResolve = null;
function promptLogin() {
  document.getElementById('loginErr').textContent = '';
  document.getElementById('loginModal').style.display = 'flex';
  document.getElementById('loginPass').focus();
  return new Promise(resolve => { loginResolve = resolve; });
}
function submitLogin() {
  // Password-only: the server ignores the username, so send a fixed placeholder.
  const p = document.getElementById('loginPass').value;
  sessionStorage.setItem('auth', 'Basic ' + btoa('admin:' + p));
  document.getElementById('loginModal').style.display = 'none';
  if (loginResolve) { const r = loginResolve; loginResolve = null; r(); }
}
async function apiFetch(url, opts) {
  opts = opts || {};
  opts.headers = Object.assign({}, opts.headers || {}, authHeader());
  let res = await fetch(url, opts);
  if (res.status === 401) {
    await promptLogin();
    opts.headers = Object.assign({}, opts.headers || {}, authHeader());
    res = await fetch(url, opts);
  }
  return res;
}

// ----- remote connection state --------------------------------------------
function remoteCreds() {
  return {
    url: sessionStorage.getItem('remoteUrl'),
    password: sessionStorage.getItem('remotePass'),
    insecure: sessionStorage.getItem('remoteInsecure') === '1'
  };
}
function remoteConnected() { return !!sessionStorage.getItem('remoteUrl'); }

function connectRemote() {
  document.getElementById('connErr').textContent = '';
  document.getElementById('connUrl').value = sessionStorage.getItem('remoteUrl') || 'https://';
  document.getElementById('connPass').value = '';
  document.getElementById('connectModal').style.display = 'flex';
  document.getElementById('connUrl').focus();
}
function closeConnect() { document.getElementById('connectModal').style.display = 'none'; }

// Try /remote/list once. Returns 'ok' | 'cert' (TLS/cert mismatch) | 'fail'.
async function tryRemoteConnect(insecure) {
  const c = remoteCreds();
  try {
    const res = await apiFetch('/remote/list', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: c.url, password: c.password, insecure: insecure })
    });
    if (res.ok) { renderTable('remote', await res.json()); return 'ok'; }
    if (res.status === 526) return 'cert';   // server's cert-error signal
    return 'fail';
  } catch (e) { return 'fail'; }
}

function clearRemoteCreds() {
  sessionStorage.removeItem('remoteUrl');
  sessionStorage.removeItem('remotePass');
  sessionStorage.removeItem('remoteInsecure');
}

async function submitConnect() {
  const url = document.getElementById('connUrl').value.trim().replace(/\/+$/, '');
  const pass = document.getElementById('connPass').value;
  const err = document.getElementById('connErr');
  if (!/^https:\/\//i.test(url)) { err.textContent = 'URL must start with https://'; return; }
  sessionStorage.setItem('remoteUrl', url);
  sessionStorage.setItem('remotePass', pass);
  sessionStorage.removeItem('remoteInsecure');

  let result = await tryRemoteConnect(false);
  if (result === 'cert') {
    const proceed = confirm(
      "The remote server's SSL certificate does not match the address you connected to " +
      "(for example, connecting directly by IP to a server that uses a wildcard certificate).\n\n" +
      "This is expected for direct IP connections. Continue anyway?");
    if (!proceed) { err.textContent = 'Connection cancelled (certificate not accepted).'; clearRemoteCreds(); return; }
    sessionStorage.setItem('remoteInsecure', '1');
    result = await tryRemoteConnect(true);
    if (result !== 'ok') { err.textContent = 'Could not connect even after accepting the certificate.'; clearRemoteCreds(); return; }
  }

  if (result === 'ok') { closeConnect(); setRemoteUi(true); updateArrows(); return; }
  err.textContent = 'Could not connect or authenticate to that server.';
  clearRemoteCreds();
}
function disconnectRemote() {
  sessionStorage.removeItem('remoteUrl'); sessionStorage.removeItem('remotePass'); sessionStorage.removeItem('remoteInsecure');
  document.getElementById('remoteRows').innerHTML = '';
  document.getElementById('remoteHost').textContent = '(not connected)';
  document.getElementById('remoteSummary').textContent = '';
  document.getElementById('remoteMsg').textContent = '';
  setRemoteUi(false);
  updateArrows();
}
function setRemoteUi(connected) {
  document.getElementById('remoteActions').style.display    = connected ? '' : 'none';
  document.getElementById('remoteConnectWrap').style.display = connected ? 'none' : '';
  document.getElementById('remoteDisconnected').style.display = connected ? 'none' : 'block';
  document.getElementById('remoteConnected').style.display    = connected ? 'block' : 'none';
  if (connected) {
    const c = remoteCreds();
    try { document.getElementById('remoteHost').textContent = shortName(new URL(c.url).hostname); } catch (e) {}
  }
}

// ----- rendering a file table ---------------------------------------------
function renderTable(which, files) {
  const tbody = document.getElementById(which + 'Rows');
  tbody.innerHTML = '';
  let total = 0;
  (files || []).forEach(f => {
    if (!f || typeof f.name !== 'string') return;
    total += (f.size || 0);
    const enc = encodeURIComponent(f.name);
    const tr = document.createElement('tr');
    let actions = '';
    if (which === 'local') {
      actions = '<a class="btn-light" style="text-decoration:none;padding:5px 10px;border-radius:5px" href="/files/' + enc + '" download>&#11015;</a> ';
    }
    actions += '<button class="btn-danger" onclick="delFile(\'' + which + '\',\'' + escapeJs(f.name) + '\')">&#128465;</button>';
    tr.innerHTML =
      '<td class="chk"><input type="checkbox" class="sel" data-name="' + escapeHtml(f.name) + '"></td>' +
      '<td>' + escapeHtml(f.name) + '</td>' +
      '<td>' + fmtSize(f.size) + '</td>' +
      '<td>' + (f.modified ? new Date(f.modified).toLocaleString() : '') + '</td>' +
      '<td class="actions">' + actions + '</td>';
    tbody.appendChild(tr);
  });
  const n = tbody.querySelectorAll('tr').length;
  document.getElementById(which + 'Empty').style.display = n ? 'none' : 'block';
  document.getElementById(which + 'Summary').textContent =
    '(' + n + ' file' + (n === 1 ? '' : 's') + ', ' + fmtSize(total) + ')';
  const all = document.getElementById(which + 'All'); if (all) all.checked = false;
}

function selectedNames(which) {
  return [...document.getElementById(which + 'Rows').querySelectorAll('input.sel:checked')]
         .map(cb => cb.dataset.name);
}
function toggleAll(which) {
  const on = document.getElementById(which + 'All').checked;
  document.getElementById(which + 'Rows').querySelectorAll('input.sel').forEach(cb => cb.checked = on);
}

// ----- load listings -------------------------------------------------------
async function loadLocal() {
  try {
    const res = await apiFetch('/list?_=' + Date.now());
    if (!res.ok) return;
    renderTable('local', await res.json());
  } catch (e) { /* 401 handled in apiFetch */ }
}

async function loadRemote() {
  if (!remoteConnected()) { setRemoteUi(false); return false; }
  const c = remoteCreds();
  const msg = document.getElementById('remoteMsg');
  msg.className = 'msg'; msg.textContent = 'Loading...';
  try {
    const res = await apiFetch('/remote/list', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: c.url, password: c.password, insecure: c.insecure })
    });
    if (!res.ok) { msg.className = 'msg err'; msg.textContent = 'Remote error: ' + (await res.text()); return false; }
    renderTable('remote', await res.json());
    msg.textContent = '';
    setRemoteUi(true);
    return true;
  } catch (e) {
    msg.className = 'msg err'; msg.textContent = 'Could not reach remote server.';
    return false;
  }
}

// ----- delete --------------------------------------------------------------
async function delFile(which, name) {
  if (!confirm('Delete "' + name + '" from ' + which + '?')) return;
  try {
    let res;
    if (which === 'local') {
      res = await apiFetch('/files/' + encodeURIComponent(name), { method: 'DELETE' });
    } else {
      const c = remoteCreds();
      res = await apiFetch('/remote/delete', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: c.url, password: c.password, name: name, insecure: c.insecure })
      });
    }
    if (res.status === 204) { which === 'local' ? loadLocal() : loadRemote(); }
    else if (res.status === 404) alert('File not found.');
    else alert('Delete failed (HTTP ' + res.status + ').');
  } catch (e) { /* handled */ }
}

// ----- transfer (server-brokered copy) ------------------------------------
async function transfer(direction) {
  if (!remoteConnected()) { alert('Connect to a remote server first.'); return; }
  const src = direction === 'push' ? 'local' : 'remote';
  const names = selectedNames(src);
  if (names.length === 0) {
    document.getElementById('xferMsg').textContent = 'Select file(s) in ' + src + ' first.';
    return;
  }
  const c = remoteCreds();
  const dest = direction === 'push' ? 'remote' : 'local';
  const prog = document.getElementById(dest + 'Progress'), bar = document.getElementById(dest + 'Bar');
  const push = document.getElementById('pushBtn'), pull = document.getElementById('pullBtn');
  const xm = document.getElementById('xferMsg');

  const cancelBtn = document.getElementById('cancelBtn');
  const jobId = 'job_' + Date.now() + '_' + Math.random().toString(36).slice(2);
  activeJobId = jobId;
  push.disabled = true; pull.disabled = true;
  cancelBtn.style.display = ''; cancelBtn.disabled = false;
  prog.style.display = 'block'; bar.style.width = '0';
  xm.textContent = 'Starting...';
  netReset();
  const timer = setInterval(() => pollXfer(jobId, bar, xm), 400);
  try {
    const res = await apiFetch('/remote/transfer', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: c.url, password: c.password, direction: direction, names: names, jobId: jobId, insecure: c.insecure })
    });
    clearInterval(timer);
    if (!res.ok) {
      // Surface a meaningful reason (e.g. insufficient destination space) when present.
      let m = 'Transfer failed.';
      try { const j = await res.json(); if (j && j.message) m = j.message; } catch (e) {}
      xm.textContent = 'Transfer failed.';
      alert(m);
    }
    else {
      const r = await res.json();
      const ok = (r.ok || []).length, failed = (r.failed || []).length;
      bar.style.width = '100%';
      if (r.cancelled) {
        xm.textContent = 'Stopped (' + ok + ' copied' + (failed ? (', ' + failed + ' failed') : '') + ')';
      } else {
        xm.textContent = ok + ' copied' + (failed ? (', ' + failed + ' failed') : '');
      }
      if (failed) {
        const detail = (r.failed || []).map(f => f.name + ': ' + f.error).join('\n');
        alert('Some transfers failed:\n\n' + detail);
      }
    }
    await loadLocal(); await loadRemote();
  } catch (e) {
    clearInterval(timer); xm.textContent = 'Transfer error.';
  } finally {
    activeJobId = null;
    cancelBtn.style.display = 'none'; cancelBtn.disabled = false;
    setTimeout(() => { prog.style.display = 'none'; bar.style.width = '0'; }, 600);
    updateArrows();
  }
}

// Stop the in-flight transfer. The server aborts the active file and stops before
// starting any further ones; the /remote/transfer response then returns cancelled.
let activeJobId = null;
function cancelTransfer() {
  if (!activeJobId) return;
  const c = remoteCreds();
  document.getElementById('cancelBtn').disabled = true;
  document.getElementById('xferMsg').textContent = 'Stopping...';
  apiFetch('/remote/cancel', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jobId: activeJobId })
  }).catch(() => {});
}

async function pollXfer(jobId, bar, xm) {
  try {
    const res = await apiFetch('/remote/progress?id=' + encodeURIComponent(jobId));
    if (!res.ok) return;
    const p = await res.json();
    if (!p || p.status === 'unknown') return;
    if (p.total > 0) bar.style.width = Math.min(100, (p.done / p.total) * 100).toFixed(1) + '%';
    netReport(p.done);
    const pct = p.total > 0 ? Math.floor(p.done / p.total * 100) : 0;
    xm.textContent = (meter.speed > 0 ? fmtSize(meter.speed) + '/s' : '') + (p.total > 0 ? ' \u00B7 ' + pct + '%' : '');
  } catch (e) { }
}

function updateArrows() {
  const on = remoteConnected();
  document.getElementById('pushBtn').disabled = !on;
  document.getElementById('pullBtn').disabled = !on;
}

// ----- uploads (per pane) --------------------------------------------------
document.getElementById('localFile').addEventListener('change',  e => doUpload('local',  e.target.files));
document.getElementById('remoteFile').addEventListener('change', e => doUpload('remote', e.target.files));

function pickUpload(which) {
  if (which === 'remote' && !remoteConnected()) { alert('Connect to a remote server first.'); return; }
  document.getElementById(which + 'File').click();
}

function doUpload(which, fileList) {
  const files = [...fileList];
  document.getElementById(which + 'File').value = '';
  if (files.length === 0) return;

  const fd = new FormData();
  files.forEach(f => fd.append('file', f, f.name));

  const xhr = new XMLHttpRequest();
  if (which === 'local') {
    xhr.open('POST', '/upload');
  } else {
    xhr.open('POST', '/remote/upload');
    const c = remoteCreds();
    xhr.setRequestHeader('X-Remote-Url',  btoa(c.url));
    xhr.setRequestHeader('X-Remote-Pass', btoa(c.password));
    xhr.setRequestHeader('X-Remote-Insecure', c.insecure ? '1' : '0');
  }
  const auth = sessionStorage.getItem('auth');
  if (auth) xhr.setRequestHeader('Authorization', auth);

  const prog = document.getElementById(which + 'Progress');
  const bar  = document.getElementById(which + 'Bar');
  const msg  = document.getElementById(which + 'Msg');
  prog.style.display = 'block'; bar.style.width = '0';
  msg.className = 'msg'; msg.textContent = '';
  netReset();

  xhr.upload.onprogress = e => {
    if (e.lengthComputable) bar.style.width = ((e.loaded / e.total) * 100).toFixed(1) + '%';
    netReport(e.loaded);
  };
  xhr.onload = () => {
    prog.style.display = 'none';
    if (xhr.status === 401) { promptLogin().then(() => doUpload(which, files)); return; }
    if (xhr.status >= 200 && xhr.status < 300) {
      let saved = [];
      try { saved = JSON.parse(xhr.responseText).saved || []; } catch (e) {}
      msg.className = 'msg ok';
      msg.textContent = 'Uploaded ' + saved.length + ' file' + (saved.length === 1 ? '' : 's') + '.';
      which === 'local' ? loadLocal() : loadRemote();
    } else {
      msg.className = 'msg err';
      msg.textContent = 'Upload failed (HTTP ' + xhr.status + ').';
    }
  };
  xhr.onerror = () => { prog.style.display = 'none'; msg.className = 'msg err'; msg.textContent = 'Upload failed (network error).'; };
  xhr.send(fd);
}

// ----- init ----------------------------------------------------------------
loadLocal();
if (remoteConnected()) { setRemoteUi(true); loadRemote(); } else { setRemoteUi(false); }
updateArrows();
</script>
</body>
</html>
'@

# ----------------------------------------------------------------------------
# 7. Per-request handler (runs in its own runspace for concurrency).
# ----------------------------------------------------------------------------

$RequestHandler = {
    param($ctx, $cfg)

    $req  = $ctx.Request
    $resp = $ctx.Response
    $status = 500

    # --- request logging (console only) ------------------------------------
    function Write-ReqLog {
        param($method, $path, $code, $ip)
        $line = "[{0}] {1} {2} - {3} - {4}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $method, $path, $code, $ip
        Write-Host $line
    }

    # --- response helpers --------------------------------------------------
    function Send-Bytes {
        param($resp, [byte[]]$bytes, [string]$contentType, [int]$code = 200)
        $resp.StatusCode  = $code
        $resp.ContentType = $contentType
        $resp.ContentLength64 = $bytes.Length
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    function Send-Text {
        param($resp, [string]$text, [string]$contentType = 'text/plain', [int]$code = 200)
        Send-Bytes $resp ([System.Text.Encoding]::UTF8.GetBytes($text)) "$contentType; charset=utf-8" $code
    }
    function Send-Json {
        param($resp, $obj, [int]$code = 200)
        $json = $obj | ConvertTo-Json -Depth 6 -Compress
        if ($null -eq $json) { $json = '{}' }
        $resp.AddHeader('Cache-Control', 'no-store')
        Send-Text $resp $json 'application/json' $code
    }
    function Read-BodyText {
        param($req)
        $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    }

    # --- misc helpers ------------------------------------------------------
    # Human-readable byte count for user-facing messages (mirrors the JS fmtSize).
    function Format-Bytes {
        param([long]$n)
        if ($n -lt 1024) { return "$n B" }
        $u = 'KB','MB','GB','TB'; $i = -1; $v = [double]$n
        do { $v /= 1024; $i++ } while ($v -ge 1024 -and $i -lt $u.Length - 1)
        return ('{0:N1} {1}' -f $v, $u[$i])
    }
    # Free space (bytes) on the volume that holds $Path, or $null if undeterminable
    # (e.g. UNC paths). A $null result means "skip the space check", never "block".
    function Get-FreeSpace {
        param([string]$Path)
        try {
            $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
            $di = New-Object System.IO.DriveInfo $root
            return [long]$di.AvailableFreeSpace
        } catch { return $null }
    }
    # Walk an exception chain and decide whether the failure was a TLS/certificate
    # validation error (name mismatch, untrusted CA, expired, etc.).
    function Test-CertError {
        param($ex)
        $e = $ex
        while ($e) {
            if ($e.GetType().FullName -eq 'System.Security.Authentication.AuthenticationException') { return $true }
            $m = [string]$e.Message
            if ($m -match 'certificate' -or $m -match 'SSL' -or $m -match 'RemoteCertificate' -or $m -match 'trust relationship') { return $true }
            $e = $e.InnerException
        }
        return $false
    }

    # --- auth --------------------------------------------------------------
    function Test-Auth {
        param($req, $cfg)
        $h = $req.Headers['Authorization']
        if (-not $h -or -not $h.StartsWith('Basic ', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        try {
            $raw = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($h.Substring(6).Trim()))
        } catch { return $false }
        $idx = $raw.IndexOf(':')
        if ($idx -lt 0) { return $false }
        # Password-only auth: the username is ignored (single shared credential),
        # so the only secret that matters is the password.
        return ($raw.Substring($idx + 1) -ceq $cfg.Password)
    }

    # --- path safety -------------------------------------------------------
    function Resolve-SafePath {
        param($root, $rootFull, $name)
        $name = [System.IO.Path]::GetFileName($name)
        if ([string]::IsNullOrWhiteSpace($name)) { return $null }
        $full = [System.IO.Path]::GetFullPath((Join-Path $root $name))
        if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $full
    }

    # --- streaming multipart/form-data parser ------------------------------
    function Find-Bytes {
        param([byte[]]$buf, [int]$start, [int]$end, [byte[]]$pat)
        # Use native Array.IndexOf to jump straight to each occurrence of the
        # delimiter's first byte, then verify the rest. Far faster than a
        # byte-by-byte PowerShell loop over large file bodies.
        $first = $pat[0]; $pl = $pat.Length; $last = $end - $pl
        $i = $start
        while ($i -le $last) {
            $idx = [Array]::IndexOf($buf, $first, $i, ($last - $i + 1))
            if ($idx -lt 0) { return -1 }
            $j = 1
            while ($j -lt $pl -and $buf[$idx + $j] -eq $pat[$j]) { $j++ }
            if ($j -eq $pl) { return $idx }
            $i = $idx + 1
        }
        return -1
    }
    function Invoke-Refill {
        param($S)
        $rem = $S.End - $S.Start
        if ($rem -gt 0 -and $S.Start -gt 0) { [Array]::Copy($S.Buf, $S.Start, $S.Buf, 0, $rem) }
        $S.Start = 0; $S.End = $rem
        if ($S.End -lt $S.Buf.Length -and -not $S.Eof) {
            $n = $S.Stream.Read($S.Buf, $S.End, $S.Buf.Length - $S.End)
            if ($n -le 0) { $S.Eof = $true } else { $S.End += $n }
        }
    }
    function Read-Line2 {
        param($S)
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            if ($S.Start -ge $S.End) { if ($S.Eof) { break }; Invoke-Refill $S; if ($S.Start -ge $S.End) { break } }
            $b = $S.Buf[$S.Start]; $S.Start++
            if ($b -eq 10) {
                $s = $sb.ToString()
                if ($s.EndsWith("`r")) { $s = $s.Substring(0, $s.Length - 1) }
                return $s
            }
            [void]$sb.Append([char]$b)
        }
        return $sb.ToString()
    }
    function Read-Headers2 {
        param($S)
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            if ($S.Start -ge $S.End) { if ($S.Eof) { break }; Invoke-Refill $S; if ($S.Start -ge $S.End) { break } }
            $b = $S.Buf[$S.Start]; $S.Start++
            [void]$sb.Append([char]$b)
            if ($sb.Length -ge 4) {
                $L = $sb.Length
                if ([int]$sb[$L-1] -eq 10 -and [int]$sb[$L-2] -eq 13 -and [int]$sb[$L-3] -eq 10 -and [int]$sb[$L-4] -eq 13) { break }
            }
        }
        return $sb.ToString()
    }
    function Read-N {
        param($S, [int]$count)
        $out = New-Object byte[] $count; $got = 0
        while ($got -lt $count) {
            if ($S.Start -ge $S.End) { if ($S.Eof) { break }; Invoke-Refill $S; if ($S.Start -ge $S.End) { break } }
            $take = [Math]::Min($count - $got, $S.End - $S.Start)
            [Array]::Copy($S.Buf, $S.Start, $out, $got, $take); $S.Start += $take; $got += $take
        }
        if ($got -lt $count) { return $out[0..($got-1)] }
        return $out
    }
    function Copy-UntilDelim {
        param($S, [byte[]]$delim, [System.IO.Stream]$out)
        $dl = $delim.Length
        while ($true) {
            $idx = Find-Bytes $S.Buf $S.Start $S.End $delim
            if ($idx -ge 0) {
                $out.Write($S.Buf, $S.Start, $idx - $S.Start)
                $S.Start = $idx + $dl
                return $true
            }
            $safeEnd = $S.End - ($dl - 1)
            if ($safeEnd -gt $S.Start) {
                $out.Write($S.Buf, $S.Start, $safeEnd - $S.Start)
                $S.Start = $safeEnd
            }
            if ($S.Eof) { return $false }
            Invoke-Refill $S
        }
    }
    # Parses a multipart body, saving each file part into $DestDir (validated by $DestFull).
    # If the upload is aborted mid-stream (e.g. the pushing peer cancelled the transfer),
    # any half-written .partial files are removed and the error is surfaced - a truncated
    # body is never promoted to its final name.
    function Save-MultipartFiles {
        param($Stream, [string]$Boundary, [string]$DestDir, [string]$DestFull)
        $enc   = [System.Text.Encoding]::UTF8
        $delim = $enc.GetBytes("`r`n--$Boundary")
        $S = @{ Stream = $Stream; Buf = New-Object byte[] 1048576; Start = 0; End = 0; Eof = $false }
        $saved = New-Object System.Collections.ArrayList
        $partials = New-Object System.Collections.ArrayList   # temp files not yet promoted

        try {
            $open = Read-Line2 $S
            if ($open -ne "--$Boundary") { throw "Malformed multipart body (bad opening boundary)." }

            while ($true) {
                $headerText = Read-Headers2 $S
                if ([string]::IsNullOrEmpty($headerText)) { break }

                # Accept both quoted (filename="x") and unquoted (filename=x) forms.
                $fileName = $null
                $rawName  = $null
                if     ($headerText -match 'filename="([^"]*)"')     { $rawName = $matches[1] }
                elseif ($headerText -match 'filename=([^";\r\n]+)')  { $rawName = $matches[1].Trim() }
                if ($null -ne $rawName) {
                    $fileName = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding(28591).GetBytes($rawName))
                }

                if ($fileName) {
                    $safe = Resolve-SafePath $DestDir $DestFull $fileName
                    if ($null -eq $safe) { throw "Rejected unsafe filename: $fileName" }
                    $tmp = "$safe.partial"
                    [void]$partials.Add($tmp)
                    $fs = [System.IO.FileStream]::new($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    $found = $false
                    try { $found = Copy-UntilDelim $S $delim $fs } finally { $fs.Dispose() }
                    # A false result means EOF arrived before the part's closing boundary,
                    # i.e. the body was truncated (peer disconnected) - don't keep it.
                    if (-not $found) { throw "Upload truncated before completion (peer disconnected?): $fileName" }
                    Move-Item -LiteralPath $tmp -Destination $safe -Force
                    [void]$partials.Remove($tmp)
                    [void]$saved.Add([System.IO.Path]::GetFileName($safe))
                }
                else {
                    $null2 = New-Object System.IO.MemoryStream
                    try { [void](Copy-UntilDelim $S $delim $null2) } finally { $null2.Dispose() }
                }

                $sep = Read-N $S 2
                if ($sep.Length -lt 2) { break }
                if ($sep[0] -eq 45 -and $sep[1] -eq 45) { break }   # "--"
            }
            return ,@($saved.ToArray())
        }
        catch {
            foreach ($p in $partials) {
                try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } } catch { }
            }
            throw
        }
    }

    # --- remote (server-to-server) helpers ---------------------------------
    function New-RemoteClient {
        param([string]$Password, [bool]$AllowInsecure)
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        # Strict TLS by default: HttpClientHandler validates the remote certificate.
        # When the user has explicitly accepted a certificate mismatch (e.g. connecting
        # by IP to a wildcard-cert server), $AllowInsecure bypasses validation.
        $handler = [System.Net.Http.HttpClientHandler]::new()
        if ($AllowInsecure) {
            $handler.ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
        }
        $client  = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromHours(12)   # allow very large transfers
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("admin:$Password"))
        $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Basic', $b64)
        return $client
    }
    function Get-RemoteBase {
        param([string]$Url)
        if ([string]::IsNullOrWhiteSpace($Url)) { throw "Remote URL is empty." }
        $u = $Url.Trim().TrimEnd('/')
        if ($u -notmatch '^https://') { throw "Remote URL must start with https://" }
        return $u
    }

    # ----------------------------------------------------------------------
    # Main request dispatch
    # ----------------------------------------------------------------------
    $ip     = $req.RemoteEndPoint.Address.ToString()
    $method = $req.HttpMethod
    $path   = $req.Url.AbsolutePath

    try {
        if (-not (Test-Auth $req $cfg)) {
            $resp.AddHeader('WWW-Authenticate', 'Basic realm="FileServer"')
            Send-Text $resp 'Authentication required.' 'text/plain' 401
            $status = 401
        }
        elseif ($method -eq 'GET' -and $path -eq '/') {
            $rootHtml = $cfg.RootDirectory -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
            $html = $cfg.Html.Replace('__ROOTDIR__', $rootHtml)
            Send-Text $resp $html 'text/html' 200
            $status = 200
        }
        elseif ($method -eq 'GET' -and $path -eq '/list') {
            $items = @(Get-ChildItem -LiteralPath $cfg.RootDirectory -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [pscustomobject]@{ name = $_.Name; size = $_.Length; modified = $_.LastWriteTimeUtc.ToString('o') }
                })
            if ($items.Count -eq 0) { $json = '[]' }
            else {
                $json = ConvertTo-Json -InputObject $items -Depth 5 -Compress
                if (-not $json.StartsWith('[')) { $json = "[$json]" }
            }
            $resp.AddHeader('Cache-Control', 'no-store, no-cache, must-revalidate')
            Send-Text $resp $json 'application/json' 200
            $status = 200
        }
        elseif ($path.StartsWith('/files/')) {
            $name = [System.Uri]::UnescapeDataString($path.Substring('/files/'.Length))
            $safe = Resolve-SafePath $cfg.RootDirectory $cfg.RootFull $name
            if ($method -eq 'GET') {
                if ($null -ne $safe -and (Test-Path -LiteralPath $safe -PathType Leaf)) {
                    $fi = [System.IO.FileInfo]::new($safe)
                    $resp.StatusCode = 200
                    $resp.ContentType = 'application/octet-stream'
                    $resp.ContentLength64 = $fi.Length
                    $resp.AddHeader('Content-Disposition', "attachment; filename=`"$($fi.Name)`"")
                    $fsr = [System.IO.File]::OpenRead($safe)
                    try { $fsr.CopyTo($resp.OutputStream) } finally { $fsr.Dispose() }
                    $status = 200
                } else { Send-Text $resp 'Not found.' 'text/plain' 404; $status = 404 }
            }
            elseif ($method -eq 'DELETE') {
                if ($null -ne $safe -and (Test-Path -LiteralPath $safe -PathType Leaf)) {
                    Remove-Item -LiteralPath $safe -Force
                    $resp.StatusCode = 204; $status = 204
                } else { Send-Text $resp 'Not found.' 'text/plain' 404; $status = 404 }
            }
            else { Send-Text $resp 'Method not allowed.' 'text/plain' 405; $status = 405 }
        }
        elseif ($method -eq 'POST' -and $path -eq '/upload') {
            $ct = $req.ContentType
            if (-not $ct -or $ct -notmatch 'boundary=(.+)$') {
                Send-Text $resp 'Expected multipart/form-data.' 'text/plain' 400; $status = 400
            } else {
                $boundary = $matches[1].Trim().Trim('"')
                $saved = Save-MultipartFiles $req.InputStream $boundary $cfg.RootDirectory $cfg.RootFull
                Send-Json $resp @{ saved = $saved } 200; $status = 200
            }
        }
        elseif ($method -eq 'GET' -and $path -eq '/diskinfo') {
            # Free space on this server's root volume; used by a peer to pre-check a push.
            Send-Json $resp @{ free = (Get-FreeSpace $cfg.RootDirectory) } 200
            $status = 200
        }
        # ===== Remote (server-to-server) endpoints ==========================
        elseif ($method -eq 'POST' -and $path -eq '/remote/list') {
            $body = Read-BodyText $req | ConvertFrom-Json
            $base = Get-RemoteBase $body.url
            $client = New-RemoteClient -Password $body.password -AllowInsecure ([bool]$body.insecure)
            try {
                try {
                    $r = $client.GetAsync("$base/list").GetAwaiter().GetResult()
                } catch {
                    # Distinguish a TLS/certificate failure so the browser can offer to
                    # retry with the mismatch accepted (status 526 = our cert-error signal).
                    if (-not [bool]$body.insecure -and (Test-CertError $_.Exception)) {
                        Send-Json $resp @{ error = 'cert_error'; message = $_.Exception.Message } 526
                        $status = 526
                        return
                    }
                    throw
                }
                $txt = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if (-not $r.IsSuccessStatusCode) {
                    Send-Text $resp ("Remote returned HTTP " + [int]$r.StatusCode) 'text/plain' 502; $status = 502
                } else {
                    $resp.AddHeader('Cache-Control', 'no-store')
                    Send-Text $resp $txt 'application/json' 200; $status = 200
                }
            } finally { $client.Dispose() }
        }
        elseif ($method -eq 'POST' -and $path -eq '/remote/delete') {
            $body = Read-BodyText $req | ConvertFrom-Json
            $base = Get-RemoteBase $body.url
            $client = New-RemoteClient -Password $body.password -AllowInsecure ([bool]$body.insecure)
            try {
                $enc = [System.Uri]::EscapeDataString([System.IO.Path]::GetFileName([string]$body.name))
                $msg = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Delete, "$base/files/$enc")
                $r = $client.SendAsync($msg).GetAwaiter().GetResult()
                if ($r.StatusCode -eq [System.Net.HttpStatusCode]::NoContent) { $resp.StatusCode = 204; $status = 204 }
                elseif ($r.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) { Send-Text $resp 'Not found.' 'text/plain' 404; $status = 404 }
                else { Send-Text $resp ("Remote returned HTTP " + [int]$r.StatusCode) 'text/plain' 502; $status = 502 }
            } finally { $client.Dispose() }
        }
        elseif ($method -eq 'GET' -and $path -eq '/remote/progress') {
            # Live progress poll for an in-flight transfer (keyed by job id).
            $id = $req.QueryString['id']
            $e  = if ($id) { $cfg.Progress[$id] } else { $null }
            if ($null -eq $e) {
                Send-Json $resp @{ status = 'unknown' } 200
            } else {
                $cur = if ($e.counter) { [long]$e.counter[0] } else { [long]0 }
                Send-Json $resp @{ status = $e.status; total = $e.total; done = ($e.baseDone + $cur); file = $e.file; ok = $e.ok; failed = $e.failed } 200
            }
            $status = 200
        }
        elseif ($method -eq 'POST' -and $path -eq '/remote/transfer') {
            $body  = Read-BodyText $req | ConvertFrom-Json
            $base  = Get-RemoteBase $body.url
            $dir   = [string]$body.direction
            $names = @($body.names)
            $jobId = [string]$body.jobId
            $client = New-RemoteClient -Password $body.password -AllowInsecure ([bool]$body.insecure)

            # Work out the total byte count so the browser can show a percentage.
            $total = [long]0
            try {
                if ($dir -eq 'push') {
                    foreach ($name in $names) {
                        $lp = Resolve-SafePath $cfg.RootDirectory $cfg.RootFull $name
                        if ($lp -and (Test-Path -LiteralPath $lp -PathType Leaf)) { $total += ([System.IO.FileInfo]::new($lp)).Length }
                    }
                } else {
                    $lr = $client.GetAsync("$base/list").GetAwaiter().GetResult()
                    if ($lr.IsSuccessStatusCode) {
                        $arr = $lr.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                        $map = @{}; foreach ($f in @($arr)) { $map[[string]$f.name] = [long]$f.size }
                        foreach ($name in $names) { if ($map.ContainsKey([string]$name)) { $total += $map[[string]$name] } }
                    }
                }
            } catch { }

            # Pre-flight: refuse the transfer if the destination volume can't hold it.
            # Destination is the remote server for a push, the local server for a pull.
            # A $null free-space reading (undeterminable) skips the check rather than blocking.
            $destFree = $null
            try {
                if ($dir -eq 'push') {
                    $dr = $client.GetAsync("$base/diskinfo").GetAwaiter().GetResult()
                    if ($dr.IsSuccessStatusCode) {
                        $dj = $dr.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                        if ($null -ne $dj.free) { $destFree = [long]$dj.free }
                    }
                } else {
                    $destFree = Get-FreeSpace $cfg.RootDirectory
                }
            } catch { $destFree = $null }

            if ($null -ne $destFree -and $total -gt 0 -and $total -gt $destFree) {
                $client.Dispose()
                $destName = if ($dir -eq 'push') { 'destination (remote) server' } else { 'local server' }
                Send-Json $resp @{
                    error   = 'insufficient_space'
                    message = ("Not enough free space on the {0}. Need {1}, but only {2} is available." -f $destName, (Format-Bytes $total), (Format-Bytes $destFree))
                    needed  = $total
                    free    = $destFree
                } 507
                $status = 507
                return
            }

            # Register the progress entry and prune anything older than 10 minutes.
            $cutoff = (Get-Date).AddMinutes(-10)
            foreach ($k in @($cfg.Progress.Keys)) {
                if ($cfg.Progress[$k].startedUtc -lt $cutoff) { $cfg.Progress.Remove($k) }
            }
            # $cts lets a concurrent /remote/cancel request abort the in-flight HTTP
            # copy mid-file; $cancelled stops the loop from starting further files.
            $cts = [System.Threading.CancellationTokenSource]::new()
            $entry = @{ total = $total; baseDone = [long]0; counter = $null; file = ''; status = 'running'; ok = 0; failed = 0; startedUtc = (Get-Date); cancelled = $false; cts = $cts }
            if ($jobId) { $cfg.Progress[$jobId] = $entry }

            $ok = New-Object System.Collections.ArrayList
            $failed = New-Object System.Collections.ArrayList
            try {
                foreach ($name in $names) {
                    if ($entry.cancelled) { break }
                    $entry.file = [string]$name
                    $counter = [long[]]::new(1)        # per-file byte counter (updated by ProgressStream)
                    $entry.counter = $counter
                    try {
                        if ($dir -eq 'push') {
                            # local -> remote (copy: source kept)
                            $local = Resolve-SafePath $cfg.RootDirectory $cfg.RootFull $name
                            if ($null -eq $local -or -not (Test-Path -LiteralPath $local -PathType Leaf)) { throw "Local file not found" }
                            $fs = [System.IO.File]::OpenRead($local)
                            $pstream = [ProgressStream]::new($fs, $counter)
                            try {
                                $fname = [System.IO.Path]::GetFileName($local)
                                $content = [System.Net.Http.MultipartFormDataContent]::new()
                                $sc = [System.Net.Http.StreamContent]::new($pstream)
                                $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
                                # .NET Framework's Add(content,name,filename) writes the filename UNQUOTED,
                                # which strict multipart parsers ignore. Set a quoted Content-Disposition
                                # ourselves (embedding the quotes forces them into the header value).
                                $sc.Headers.ContentDisposition = [System.Net.Http.Headers.ContentDispositionHeaderValue]::new('form-data')
                                $sc.Headers.ContentDisposition.Name = '"file"'
                                $sc.Headers.ContentDisposition.FileName = '"' + $fname + '"'
                                $content.Add($sc)
                                $r = $client.PostAsync("$base/upload", $content, $cts.Token).GetAwaiter().GetResult()
                                $txt = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                                if (-not $r.IsSuccessStatusCode) { throw ("Remote upload HTTP " + [int]$r.StatusCode) }
                                # Confirm the remote actually stored the file (guards against silent no-ops).
                                $savedResp = @(($txt | ConvertFrom-Json).saved)
                                if ($savedResp.Count -eq 0) { throw "Remote accepted the request but saved no file (is it running the updated script?)" }
                            } finally { $pstream.Dispose() }
                        }
                        elseif ($dir -eq 'pull') {
                            # remote -> local (copy: source kept)
                            $safe = Resolve-SafePath $cfg.RootDirectory $cfg.RootFull $name
                            if ($null -eq $safe) { throw "Invalid destination name" }
                            $enc = [System.Uri]::EscapeDataString([System.IO.Path]::GetFileName([string]$name))
                            $r = $client.GetAsync("$base/files/$enc", [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
                            if (-not $r.IsSuccessStatusCode) { throw ("Remote download HTTP " + [int]$r.StatusCode) }
                            $tmp = "$safe.partial"
                            $inS  = $r.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                            $outRaw = [System.IO.FileStream]::new($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                            $pout = [ProgressStream]::new($outRaw, $counter)
                            $done2 = $false
                            try {
                                $inS.CopyToAsync($pout, 81920, $cts.Token).GetAwaiter().GetResult()
                                $done2 = $true
                            } finally {
                                $pout.Dispose(); $inS.Dispose()
                                # On any abort (including cancel) drop the half-written .partial file.
                                if (-not $done2 -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
                            }
                            Move-Item -LiteralPath $tmp -Destination $safe -Force
                        }
                        else { throw "Unknown direction" }
                        [void]$ok.Add($name); $entry.ok = $ok.Count
                    }
                    catch {
                        # A cancellation is a user action, not a failure - don't report it as one.
                        if (-not $entry.cancelled) {
                            [void]$failed.Add(@{ name = $name; error = $_.Exception.Message }); $entry.failed = $failed.Count
                        }
                    }
                    finally {
                        $entry.baseDone += [long]$counter[0]
                        $entry.counter = $null
                    }
                    if ($entry.cancelled) { break }
                }
            } finally {
                $client.Dispose()
                $entry.status = if ($entry.cancelled) { 'cancelled' } else { 'done' }
                try { $cts.Dispose() } catch { }
            }
            Send-Json $resp @{ ok = @($ok.ToArray()); failed = @($failed.ToArray()); cancelled = $entry.cancelled } 200
            $status = 200
        }
        elseif ($method -eq 'POST' -and $path -eq '/remote/cancel') {
            # Flag an in-flight transfer (by job id) for cancellation and abort its
            # current HTTP copy. The transfer runspace stops after the active file.
            $body = Read-BodyText $req | ConvertFrom-Json
            $id = [string]$body.jobId
            $e  = if ($id) { $cfg.Progress[$id] } else { $null }
            if ($null -eq $e) {
                Send-Json $resp @{ ok = $false; error = 'unknown job' } 404; $status = 404
            } else {
                $e.cancelled = $true
                try { if ($e.cts) { $e.cts.Cancel() } } catch { }
                Send-Json $resp @{ ok = $true } 200; $status = 200
            }
        }
        elseif ($method -eq 'POST' -and $path -eq '/remote/upload') {
            # Browser -> this server -> remote. Save to a temp dir, then push each file.
            $remUrl  = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($req.Headers['X-Remote-Url']))
            $remPass = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($req.Headers['X-Remote-Pass']))
            $remInsecure = ($req.Headers['X-Remote-Insecure'] -eq '1')
            $base = Get-RemoteBase $remUrl
            $ct = $req.ContentType
            if (-not $ct -or $ct -notmatch 'boundary=(.+)$') {
                Send-Text $resp 'Expected multipart/form-data.' 'text/plain' 400; $status = 400
            } else {
                $boundary = $matches[1].Trim().Trim('"')
                $tempDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("conduit_" + [Guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $tempDir | Out-Null
                $tempFull = [System.IO.Path]::GetFullPath($tempDir)
                $client = New-RemoteClient -Password $remPass -AllowInsecure $remInsecure
                try {
                    $saved = Save-MultipartFiles $req.InputStream $boundary $tempDir $tempFull
                    $pushed = New-Object System.Collections.ArrayList
                    foreach ($n in $saved) {
                        $lp = Join-Path $tempDir $n
                        $fs = [System.IO.File]::OpenRead($lp)
                        try {
                            $content = [System.Net.Http.MultipartFormDataContent]::new()
                            $sc = [System.Net.Http.StreamContent]::new($fs)
                            $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
                            $sc.Headers.ContentDisposition = [System.Net.Http.Headers.ContentDispositionHeaderValue]::new('form-data')
                            $sc.Headers.ContentDisposition.Name = '"file"'
                            $sc.Headers.ContentDisposition.FileName = '"' + $n + '"'
                            $content.Add($sc)
                            $r = $client.PostAsync("$base/upload", $content).GetAwaiter().GetResult()
                            if ($r.IsSuccessStatusCode) { [void]$pushed.Add($n) }
                        } finally { $fs.Dispose() }
                    }
                    Send-Json $resp @{ saved = @($pushed.ToArray()) } 200; $status = 200
                }
                finally {
                    $client.Dispose()
                    try { Remove-Item -LiteralPath $tempDir -Recurse -Force } catch { }
                }
            }
        }
        else {
            Send-Text $resp 'Not found.' 'text/plain' 404; $status = 404
        }
    }
    catch {
        $status = 500
        try { Send-Text $resp ("Server error: " + $_.Exception.Message) 'text/plain' 500 } catch { }
    }
    finally {
        Write-ReqLog $method $path $status $ip
        try { $resp.OutputStream.Close() } catch { }
        try { $resp.Close() } catch { }
    }
}

# ----------------------------------------------------------------------------
# 8. Start the listener and run the accept loop.
# ----------------------------------------------------------------------------

# Shared across runspaces: live progress of in-flight server-to-server transfers,
# keyed by client-supplied job id. The transfer request updates it; concurrent
# /remote/progress poll requests read it.
$Progress = [hashtable]::Synchronized(@{})

$config = @{
    RootDirectory = $RootDirectory
    RootFull      = $RootFull
    Username      = $Username
    Password      = $Password
    Html          = $IndexHtml
    Progress      = $Progress
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("https://+:$Port/")

$pool = [runspacefactory]::CreateRunspacePool(1, 16)
$pool.Open()
$jobs = New-Object System.Collections.ArrayList

function Clear-FinishedJobs {
    param($jobs)
    for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
        if ($jobs[$i].Async.IsCompleted) {
            try { $jobs[$i].PS.EndInvoke($jobs[$i].Async) } catch { }
            $jobs[$i].PS.Dispose()
            $jobs.RemoveAt($i)
        }
    }
}

try {
    $listener.Start()
    $serverUrl = Get-ServerUrl -Subject $selectedCert.Subject -Port $Port
    Write-Banner -Subject $selectedCert.Subject -Thumbprint $selectedCert.Thumbprint -Pass $Password -Url $serverUrl

    while ($listener.IsListening) {
        $ctxTask = $listener.GetContextAsync()
        while (-not ([System.IAsyncResult]$ctxTask).AsyncWaitHandle.WaitOne(200)) {
            Clear-FinishedJobs $jobs
        }
        $context = $ctxTask.GetAwaiter().GetResult()

        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($RequestHandler.ToString()).AddArgument($context).AddArgument($config)
        $async = $ps.BeginInvoke()
        [void]$jobs.Add(@{ PS = $ps; Async = $async })

        Clear-FinishedJobs $jobs
    }
}
catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl+C - fall through to cleanup.
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host "`nShutting down..." -ForegroundColor Yellow
    try { if ($listener.IsListening) { $listener.Stop() } } catch { }
    try { $listener.Close() } catch { }

    foreach ($j in $jobs) {
        try { $j.PS.EndInvoke($j.Async) } catch { }
        try { $j.PS.Dispose() } catch { }
    }
    try { $pool.Close(); $pool.Dispose() } catch { }

    Remove-SslBinding
    if ($FirewallRuleCreated) {
        Remove-FirewallRule -name $FirewallRuleName
        Write-Host "Removed firewall rule '$FirewallRuleName'." -ForegroundColor Yellow
    }
    Write-Host "SSL binding removed. Goodbye." -ForegroundColor Yellow
}
