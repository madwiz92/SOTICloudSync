# Folder Support — Implementation Plan

Status: **approved, not yet built**. Scope: full folder navigation, per-file recursion
for transfers. This document is build-ready; work it top to bottom.

## Locked decisions
1. **Folder sizes in listings:** omit (render `—`). No recursive stat per row.
2. **Empty folders:** preserve them across zip download, upload, and transfer.
3. **Long paths (>260 chars):** supported (see Appendix A).
4. **Symlinks / junctions:** skipped during all recursion (no follow).
5. **Endpoint migration:** drop `/files/<name>`; move to `/download?path=` (files),
   `/zip?path=` (folders), `/delete?path=` (files + folders). All instances run the
   same build, so both broker and peer speak the new endpoints.

---

## 0. Foundation: path safety v2 (do first — this is the security boundary)
Replace the flatten-to-filename logic in `Resolve-SafePath` with a nesting-aware,
escape-proof resolver. Every client-supplied path (list, download, zip, upload,
delete, transfer, and each entry inside a folder op) must pass through it.

Rules:
- Accept a relative path with nested segments; normalize `/`→`\`, trim leading sep.
- **Reject** any `..` segment, rooted/absolute paths, drive-relative (`C:foo`), UNC.
- Resolve with `[IO.Path]::GetFullPath(Join-Path $root $rel)`.
- **Boundary check fix:** compare against `$rootFull.TrimEnd('\') + '\'` (and allow
  `== $rootFull`). Today's bare `StartsWith($rootFull)` wrongly accepts `C:\cloudX`
  for root `C:\cloud`; this closes that.
- Return the normalized full path (callers add the `\\?\` long-path prefix at I/O time
  — Appendix A).

Reused everywhere ⇒ zip-slip is covered as long as nothing bypasses it.

Add a recursion helper that **skips reparse points** (decision 4) and avoids cycles:
enumerate with .NET (`Directory.EnumerateFileSystemEntries`) and skip any entry whose
attributes include `ReparsePoint`.

---

## 1. Listing + navigation
- **`/list`** gains `path` (relative dir, `''`=root); returns
  `{ name, type:'file'|'dir', size, modified }`. Dirs first, then files, alpha.
  Dir rows carry **no size** (decision 1).
- **`/remote/list`** forwards `path` to the remote `/list`.
- **`/listtree?path=`** (new): recursive file list (relative paths + sizes) for the
  subtree, skipping reparse points. Powers pull enumeration + transfer byte totals.
- Frontend:
  - Per-pane current path: `localPath`, `remotePath` (persist `remotePath` in
    sessionStorage so refresh/reconnect keeps location).
  - `renderTable` renders dir rows (folder icon → navigate on click) vs file rows.
  - **Breadcrumb bar** per pane (`Root / sub / deep`, each clickable).
  - `loadLocal`/`loadRemote` send the current `path`.

## 2. Download (migrate off /files)
- **`/download?path=<rel>`** (new) streams a single file. Replaces `/files/<name>`
  GET. Query param sidesteps slash-in-route issues.
- **`/zip?path=<reldir>`** (new) streams a folder as zip:
  - `SendChunked=$true`, `application/zip`, `Content-Disposition: filename="<folder>.zip"`.
  - `ZipArchive` (Create) over `$resp.OutputStream`, **store/`NoCompression`**; entries
    named relative to the selected folder. ZIP64 auto. Wrap output in `ProgressStream`.
  - **Empty subfolders** → add explicit directory entries (decision 2).
  - Mid-stream error can only abort (headers already sent).
- Remove the `/files/` route entirely (decision 5); update all row links.

## 3. Upload a folder
- Frontend: add **"Upload folder"** (hidden `<input webkitdirectory>`). Send each file
  with its `webkitRelativePath` as the multipart filename; send destination dir via
  **`X-Dest-Path`** header (= current pane path). Empty dirs: send a sentinel/marker or
  a follow-up "create dirs" call so empties survive (decision 2).
- Server `Save-MultipartFiles`: drop `GetFileName`; join `X-Dest-Path` + the file's
  relative path, resolve via v2, **create parent dirs**, write (existing `.partial`
  write + abort-cleanup preserved). Same flow through `/remote/upload`.

## 4. Delete (migrate + recursive)
- **`/delete?path=`** (new) handles files and dirs (`Remove-Item -Recurse`), path-safe.
  Replaces the `/files/<name>` DELETE. UI confirms "Delete folder and all contents?".

## 5. Transfer folders (per-file recursion)
Extend `/remote/transfer`:
- Body gains **`path`** (source dir) and **`destPath`** (destination dir); `names` may
  include folders.
- **Work list:** for each selected name under `path`: file → one item; folder → recurse
  (skipping reparse points) into `(sourceRel → destRel)` pairs where
  `destRel = destPath + nameRelativeToSelection`. Capture **empty dirs** to recreate.
- **Enumeration:** push walks the local tree; pull uses **`/listtree`**. Both feed the
  **total-bytes** figure → existing **free-space pre-check** (remote `/diskinfo` push,
  local drive pull).
- Reuse as-is: `ProgressStream` counter + `baseDone`; `entry.file` shows current
  relative path; **cancel** via `CancellationToken` + `cancelled` (checked between the
  now-many files); per-file `.partial` cleanup.
- Push writes to remote `/upload` with `X-Dest-Path`; pull writes locally via v2.
  Empty dirs created explicitly on the destination first.
- Broker calls migrate to the new endpoints (`/download?path=`, `/delete?path=`).

## 6. Build order
1. Path-safety v2 + recursion-skip helper (+ manual traversal/zip-slip tests).
2. Listing w/ type + `path`; `/remote/list` forward; `/listtree`; navigation UI + breadcrumbs.
3. `/download?path=` + `/zip?path=`; remove `/files/`; update links + broker pull.
4. Folder upload (webkitdirectory → nested write, empty-dir handling).
5. `/delete?path=`; migrate broker delete.
6. Recursive transfer (work list, totals, progress/cancel, empty dirs).
7. Hardening: long paths (Appendix A), reparse-point audit, README.

---

## Appendix A — Long-path (>260) support
- Apply the extended-length prefix to the **resolved absolute path** at I/O time:
  `\\?\C:\...` for local, `\\?\UNC\server\share\...` for UNC. The path must already be
  fully normalized with backslashes (v2 resolver guarantees this — `\\?\` disables
  normalization, so feed it only normalized paths).
- Use .NET APIs that honor it: `FileStream`, `Directory.CreateDirectory`,
  `Directory.EnumerateFileSystemEntries`. Prefer these over `Get-ChildItem`/`Join-Path`
  cmdlets in the hot paths to avoid cmdlet-level length limits.
- Centralize as a helper (e.g. `ConvertTo-LongPath`) used by every filesystem call in
  the folder code.

## Appendix B — Security checklist
- v2 resolver on every client path (incl. each file inside a folder op) — traversal + zip-slip.
- Separator-boundary fix (`C:\cloud` vs `C:\cloudX`).
- Skip reparse points in all recursion (no escape, no cycles).
- Zip entry names are relative; never leak absolute paths.
- Recursive delete strictly within root; confirm in UI.

## Appendix C — Notes / accepted behavior
- Name collisions overwrite (existing `Move-Item -Force` behavior); document.
- Cancelled transfer may leave empty destination dirs — acceptable.
- Folder sizes are not shown (decision 1); a lazy per-folder size endpoint could be
  added later if wanted.
