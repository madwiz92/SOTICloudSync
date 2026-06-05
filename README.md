# Conduit

A self-contained HTTPS file server with a browser UI and direct **server-to-server** file transfer, implemented as a single PowerShell script (`Conduit.ps1`).

It serves a local directory (browse / upload / download / delete) and adds a second pane that connects to **another** instance of this server, letting you copy files directly between the two over HTTPS.

## Features

- **Browser UI** over HTTPS with a **password-only login** — browse, upload, download, and delete files in a served directory.
- **Server-brokered transfers** — the server pulls/pushes files to a remote peer itself, so there are no browser memory limits and no CORS issues. Transfers *copy* files (the source is kept). Chosen with checkboxes and moved with the center → / ← arrows.
- **Live throughput meter** and per-transfer progress.
- **Stop a transfer in progress** — an in-flight transfer can be cancelled in either direction; half-written `.partial` files are cleaned up.
- **Free-space pre-check** — before a transfer starts, the destination volume's free space is verified; the transfer fails fast with a clear message if it won't fit.
- **TLS certificate handling** — the remote certificate is validated strictly by default. If validation fails (e.g. a name mismatch when connecting directly by IP to a wildcard-cert server), the user is prompted and may choose to continue, which relaxes validation for that connection only.
- **DNS fallback for remote connections** — if the Conduit host can't resolve a remote's FQDN via its own DNS, the browser resolves it via DNS-over-HTTPS and retries against the IP (with consent, since an IP can't match a hostname certificate).

## Requirements

- **Windows** (10/11 or Server 2019/2022).
- **PowerShell 7** (`pwsh`).
- Must be run **as Administrator** (required to bind the HTTPS listener and the SSL certificate).
- A certificate in `LocalMachine\My` or `CurrentUser\My` whose Subject or SAN matches one of the configured wildcard patterns.

## Quick deploy (one-liner)

The repo ships an `install.ps1` bootstrapper that self-elevates, ensures PowerShell 7 is installed, downloads the latest `Conduit.ps1`, and runs it. Paste this into **any** PowerShell on the target server (Windows PowerShell 5.1 or 7 — it handles the rest):

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; $i="$env:TEMP\conduit-install.ps1"; iwr https://raw.githubusercontent.com/madwiz92/Conduit/main/install.ps1 -OutFile $i -UseBasicParsing; & $i
```

Install it as an **auto-start scheduled task** (runs as SYSTEM at boot, logs to `%ProgramData%\Conduit\Conduit.log`) by adding `-AsTask`:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; $i="$env:TEMP\conduit-install.ps1"; iwr https://raw.githubusercontent.com/madwiz92/Conduit/main/install.ps1 -OutFile $i -UseBasicParsing; & $i -AsTask
```

### Installer options

`install.ps1` forwards `-RootDirectory`, `-Port`, `-Username`, and `-Password` straight to the server, plus:

| Parameter | Description |
|---|---|
| `-AsTask` | Register + start a scheduled task at boot instead of running in the console. |
| `-NoStart` | Download/install only; don't launch. |
| `-Uninstall` | Remove the scheduled task and install directory. |
| `-Ref <branch\|tag>` | Pull from a specific branch or tag (default `main`). Pin to a tag for stable rollouts. |
| `-InstallDir <path>` | Install location (default `%ProgramData%\Conduit`). |

> For `-AsTask`, supply `-Password` (the task runs head-less, so a server-generated password would never be shown). If you omit it, the installer generates one and prints it once during install.

## Usage (manual)

```powershell
.\Conduit.ps1
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-RootDirectory` | `C:\cloud\transfer` | Directory whose files are served. Created if missing. All file I/O is scoped here. |
| `-Port` | `0` (auto) | TCP port for HTTPS. `0` auto-selects the first free port from `5496, 5494, 443`. |
| `-Username` | `admin` | Ignored — login is password-only (kept for compatibility). |
| `-Password` | *(random)* | The login password. If empty, a random 12-character password is generated and printed at startup. |

On startup the script prints the access URL and password to the console. Open the URL in a browser and paste the password to sign in.
