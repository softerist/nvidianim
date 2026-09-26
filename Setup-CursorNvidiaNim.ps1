# =====================================================================
#  Setup-CursorNvidiaNim.ps1
#
#  Points Cursor (the AI code editor) at NVIDIA NIM
#  (https://integrate.api.nvidia.com) and registers 4 models:
#
#    - z-ai/glm-5.3                    (GLM 5.3,           text)
#    - z-ai/glm-5.3-flash              (GLM 5.3 Flash,     text + image)
#    - deepseek-ai/deepseek-v4.1-flash (DeepSeek V4.1,     text + image)
#    - moonshotai/kimi-k3              (Kimi K3,           text)
#
#  It uses Cursor's single "own API key" slot: the OpenAI-compatible
#  base URL override plus your nvapi-... key (encrypted the same way
#  Cursor itself encrypts it). Note this REPLACES whatever custom
#  endpoint/key was configured there before (e.g. OpenCode Zen).
#
#  No extra software needed: the script runs its database step with
#  Cursor's own bundled Node runtime + sqlite module.
#
#  USAGE (the only thing you need is your NVIDIA API key, nvapi-...):
#    1. CLOSE Cursor completely.
#    2. Right-click this file -> "Run with PowerShell", or run:
#         powershell -ExecutionPolicy Bypass -File .\Setup-CursorNvidiaNim.ps1
#    3. Paste your nvapi-... key when asked.
#    4. Start Cursor -> model picker -> pick one of the new models.
#
#  The script is idempotent: re-running it updates the existing setup.
#  A timestamped backup of Cursor's state.vscdb is created first.
#
#  Works on Windows PowerShell 5.1 and PowerShell 7+.
# =====================================================================

param(
    [string]$ApiKey = "",
    [switch]$SkipKeyCheck,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ----------------------------- constants -----------------------------

$NimUrl = "https://integrate.api.nvidia.com/v1"

$Models = @(
    "z-ai/glm-5.3",
    "z-ai/glm-5.3-flash",
    "deepseek-ai/deepseek-v4.1-flash",
    "moonshotai/kimi-k3"
)

# ----------------------------- helpers -------------------------------

function Write-Step  { param($m) Write-Host ""
                      Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "    [XX] $m" -ForegroundColor Red }

function ConvertFrom-SecurePlain {
    param($Secure)
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# ------------------------------ intro --------------------------------

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "  Cursor <-> NVIDIA NIM setup" -ForegroundColor Cyan
Write-Host "  Models: GLM 5.3, GLM 5.3 Flash, DeepSeek V4.1 Flash, Kimi K3" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan

# --------------------------- locate cursor ---------------------------

Write-Step "Locating Cursor"

$cursorExe = @(
    (Join-Path $env:LOCALAPPDATA "Programs\cursor\Cursor.exe"),
    (Join-Path $env:ProgramFiles  "Cursor\Cursor.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $cursorExe) {
    Write-Fail "Cursor.exe not found (looked in LocalAppData\Programs\cursor and ProgramFiles\Cursor)."
    exit 1
}
$appNm = Join-Path (Split-Path $cursorExe) "resources\app\node_modules"
if (-not (Test-Path (Join-Path $appNm "@vscode\sqlite3"))) {
    Write-Fail "Cursor's bundled sqlite module was not found at:"
    Write-Fail "  $appNm\@vscode\sqlite3"
    Write-Fail "This Cursor version may differ - please report this."
    exit 1
}
Write-Ok "Found $($cursorExe)"

# --------------------------- locate config ---------------------------

Write-Step "Looking for Cursor user data"

$vscdb      = Join-Path $env:APPDATA "Cursor\User\globalStorage\state.vscdb"
$localState = Join-Path $env:APPDATA "Cursor\Local State"

if (-not (Test-Path $vscdb)) {
    Write-Fail "Cursor database not found at $vscdb"
    Write-Fail "Start Cursor once (so it creates its data), then re-run this script."
    exit 1
}
if (-not (Test-Path $localState)) {
    Write-Fail "Cursor 'Local State' not found at $localState"
    Write-Fail "Start Cursor once, open Settings, close it, then re-run this script."
    exit 1
}
Write-Ok "Found $vscdb"

# ------------------------- cursor running check ----------------------

Write-Step "Checking that Cursor is closed"

$cursor = @(Get-Process -Name "Cursor" -ErrorAction SilentlyContinue)
if ($cursor.Count -gt 0 -and -not $Force) {
    Write-Warn2 "Cursor is currently running ($($cursor.Count) process(es))."
    Write-Warn2 "It MUST be closed: it would overwrite these changes when it exits."
    $ans = Read-Host "    Close Cursor and continue anyway? (y/N)"
    if ($ans -notmatch "^[Yy]") { Write-Fail "Aborted. Close Cursor and re-run."; exit 1 }
}
elseif ($cursor.Count -eq 0) { Write-Ok "Cursor is not running" }

# ---------------------------- api key --------------------------------

Write-Step "NVIDIA API key"

$ApiKey = $ApiKey.Trim()

while ($true) {
    if (-not $ApiKey) {
        Write-Host "    Paste your NVIDIA API key (looks like 'nvapi-...')."
        $sec = Read-Host "    API key" -AsSecureString
        $ApiKey = (ConvertFrom-SecurePlain $sec).Trim()
    }
    if ($ApiKey -match "^nvapi-[A-Za-z0-9_\-]{10,}$") { break }
    Write-Fail "That does not look like an NVIDIA key (expected 'nvapi-...' with no spaces)."
    $ApiKey = ""
}

Write-Ok "Key format looks valid"

# --------------------------- live key check ---------------------------

if (-not $SkipKeyCheck) {
    Write-Step "Verifying the key against NVIDIA NIM"

    try {
        $resp = Invoke-RestMethod -Uri "$NimUrl/models" -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 30
        $available = @($resp.data | ForEach-Object { $_.id })
        $found = @($Models | Where-Object { $available -contains $_ })
        if ($found.Count -eq $Models.Count) {
            Write-Ok "Key works; all 4 models are available on your account"
        } else {
            Write-Warn2 "Key works; but only these of the 4 models were found: $($found -join ', ')"
            Write-Warn2 "(The others may still work - continuing.)"
        }
    }
    catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401) {
            Write-Fail "NVIDIA rejected the key (HTTP 401)."
            $ApiKey = ""   # ask again
        }
        else {
            Write-Warn2 "Could not reach NVIDIA to verify the key ($($_.Exception.Message))."
            $ans = Read-Host "    Continue without verification? (y/N)"
            if ($ans -notmatch "^[Yy]") { Write-Fail "Aborted."; exit 1 }
        }
    }
}

# --------------- derive the storage encryption key (DPAPI) ------------

Write-Step "Unlocking Cursor's encryption key"

Add-Type -AssemblyName System.Security

$ls = Get-Content $localState -Raw | ConvertFrom-Json
$wrapped = $ls.os_crypt.encrypted_key
if (-not $wrapped) {
    Write-Fail "No os_crypt.encrypted_key in Local State."
    Write-Fail "Open Cursor once, then close it, and re-run this script."
    exit 1
}
$wrappedBytes = [Convert]::FromBase64String($wrapped)
$prefix = [System.Text.Encoding]::ASCII.GetString($wrappedBytes[0..4])
if ($prefix -ne "DPAPI") {
    Write-Fail "Unexpected key format in Local State ('$prefix')."
    exit 1
}
try {
    $aesKey = [System.Security.Cryptography.ProtectedData]::Unprotect(
        [byte[]]$wrappedBytes[5..($wrappedBytes.Length - 1)],
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}
catch {
    Write-Fail "Could not decrypt Cursor's storage key with DPAPI: $($_.Exception.Message)"
    exit 1
}
if ($aesKey.Length -ne 32) { Write-Fail "Decrypted key is not 32 bytes."; exit 1 }
Write-Ok "Storage key unlocked"

# ------------------------------ backup --------------------------------

Write-Step "Backing up state.vscdb"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$bak = "$vscdb.before-nvidia-nim-$stamp.bak"
Copy-Item $vscdb $bak
Write-Ok "Backup: $(Split-Path $bak -Leaf)"

# --------------------- run the database update ------------------------

# The update runs inside Cursor's own Electron binary in Node mode
# (ELECTRON_RUN_AS_NODE), using Cursor's bundled @vscode/sqlite3 module.
# The payload (unlocked AES key + nvapi key) is passed via env var and
# never written to disk.

$nodeScript = @'
const path = require("path");
const crypto = require("crypto");
const sqlite3 = require(path.join(process.env.CURSOR_NM, "@vscode", "sqlite3"));

function fail(msg) { console.log("RESULTJSON " + JSON.stringify({ ok: false, error: msg })); process.exit(0); }

let p;
try { p = JSON.parse(process.env.NIM_PAYLOAD); } catch (e) { fail("bad payload: " + e.message); }
if (!p || !p.aesKey || !p.apiKey || !p.nimUrl || !Array.isArray(p.models)) fail("incomplete payload");

const aesKey = Buffer.from(p.aesKey, "base64");
if (aesKey.length !== 32) fail("unlocked AES key is not 32 bytes");

const db = new sqlite3.Database(process.env.NIM_DB);

db.serialize(() => {
  db.all("SELECT key FROM ItemTable WHERE key LIKE 'src.vs.platform.reactivestorage%' AND key LIKE '%persistentStorage.applicationUser'", (e, rows) => {
    if (e) return fail("cannot open state.vscdb: " + e.message);
    if (!rows || rows.length === 0) return fail("persistent storage key not found - Cursor version may be incompatible");
    const blobKey = rows[0].key;

    db.get("SELECT value FROM ItemTable WHERE key=?", [blobKey], (e2, row) => {
      if (e2) return fail("cannot read storage blob: " + e2.message);
      let blob;
      try { blob = JSON.parse(row.value); } catch (err) { return fail("storage blob is not valid JSON"); }
      if (!blob || typeof blob !== "object") return fail("storage blob has unexpected shape");

      const oldUrl = blob.openAIBaseUrl || null;
      const oldLocal = Array.isArray(blob.localProviderModelIds) ? blob.localProviderModelIds.slice() : null;

      blob.openAIBaseUrl = p.nimUrl;
      blob.useOpenAIKey = true;

      ["localProviderModelIds", "localProviderAgentModelIds"].forEach((f) => {
        const ids = Array.isArray(blob[f]) ? blob[f] : [];
        p.models.forEach((m) => { if (ids.indexOf(m) < 0) ids.push(m); });
        blob[f] = ids;
      });

      if (!blob.aiSettings || typeof blob.aiSettings !== "object") blob.aiSettings = { modelConfig: {} };
      const uam = Array.isArray(blob.aiSettings.userAddedModels) ? blob.aiSettings.userAddedModels : [];
      p.models.forEach((m) => { if (uam.indexOf(m) < 0) uam.push(m); });
      blob.aiSettings.userAddedModels = uam;

      // If the composer's selected model belonged to the previous custom
      // endpoint, it is orphaned by this swap -> re-point it to GLM 5.3.
      try {
        const comp = blob.aiSettings.modelConfig && blob.aiSettings.modelConfig.composer;
        if (oldUrl && oldUrl !== p.nimUrl && comp && comp.modelName &&
            comp.modelName !== "default" &&
            p.models.indexOf(comp.modelName) < 0 &&
            oldLocal && oldLocal.indexOf(comp.modelName) >= 0) {
          comp.modelName = p.models[0];
          comp.selectedModels = [{ modelId: p.models[0], parameters: [] }];
        }
      } catch (err) {}

      db.run("UPDATE ItemTable SET value=? WHERE key=?", [JSON.stringify(blob), blobKey], (e3) => {
        if (e3) return fail("blob write failed: " + e3.message);

        // encrypt the nvapi key exactly like Electron safeStorage does:
        // "v10" prefix + AES-256-GCM (12-byte nonce, ciphertext+tag)
        const nonce = crypto.randomBytes(12);
        const cipher = crypto.createCipheriv("aes-256-gcm", aesKey, nonce);
        const enc = Buffer.concat([Buffer.from("v10"), nonce,
                                   cipher.update(String(p.apiKey), "utf8"),
                                   cipher.final(), cipher.getAuthTag()]);
        const secretVal = JSON.stringify({ type: "Buffer", data: Array.from(enc) });

        db.run("INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
               ["secret://cursorAuth/openAIKey", secretVal], (e4) => {
          if (e4) return fail("key write failed: " + e4.message);

          db.get("SELECT value FROM ItemTable WHERE key=?", ["secret://cursorAuth/openAIKey"], (e5, r5) => {
            if (e5) return fail("verify read failed: " + e5.message);
            let raw;
            try { raw = Buffer.from(JSON.parse(r5.value).data); } catch (err) { return fail("verify: unreadable secret"); }
            if (raw.slice(0, 3).toString("utf8") !== "v10") return fail("verify: bad prefix");
            try {
              const body = raw.slice(15);
              const d = crypto.createDecipheriv("aes-256-gcm", aesKey, raw.slice(3, 15));
              d.setAuthTag(body.slice(body.length - 16));
              const plain = Buffer.concat([d.update(body.slice(0, body.length - 16)), d.final()]).toString("utf8");
              if (plain !== String(p.apiKey)) return fail("verify: round-trip mismatch");
            } catch (err) { return fail("verify: decrypt failed (" + err.message + ")"); }

            console.log("RESULTJSON " + JSON.stringify({ ok: true, blobKey: blobKey, oldUrl: oldUrl }));
            db.close();
          });
        });
      });
    });
  });
});
'@

$jsFile = Join-Path $env:TEMP "nim-cursor-setup-$PID.js"
[System.IO.File]::WriteAllText($jsFile, $nodeScript, (New-Object System.Text.UTF8Encoding($false)))

Write-Step "Applying NVIDIA NIM configuration to Cursor"

$payload = @{
    aesKey = [Convert]::ToBase64String($aesKey)
    apiKey = $ApiKey
    nimUrl = $NimUrl
    models = $Models
} | ConvertTo-Json -Depth 4

$env:ELECTRON_RUN_AS_NODE = "1"
$env:CURSOR_NM = $appNm
$env:NIM_DB = $vscdb
$env:NIM_PAYLOAD = $payload

# Cursor.exe is a GUI-subsystem binary: capture output via file redirects
$stdoutFile = Join-Path $env:TEMP "nim-cursor-out-$PID.txt"
$stderrFile = Join-Path $env:TEMP "nim-cursor-err-$PID.txt"
$proc = Start-Process -FilePath $cursorExe -ArgumentList "`"$jsFile`"" -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
$exitCode = $proc.ExitCode
$raw = @(Get-Content $stdoutFile -ErrorAction SilentlyContinue) + @(Get-Content $stderrFile -ErrorAction SilentlyContinue)
Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue

Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
Remove-Item Env:\CURSOR_NM        -ErrorAction SilentlyContinue
Remove-Item Env:\NIM_DB           -ErrorAction SilentlyContinue
Remove-Item Env:\NIM_PAYLOAD      -ErrorAction SilentlyContinue
Remove-Item $jsFile -Force -ErrorAction SilentlyContinue

$resultLine = $raw | Where-Object { $_ -is [string] -and $_ -match "^\s*RESULTJSON " } | Select-Object -Last 1
if (-not $resultLine) {
    Write-Fail "The update step produced no result (exit code $exitCode). Raw output:"
    $raw | ForEach-Object { Write-Host "    $_" }
    Write-Fail "state.vscdb was NOT modified (backup untouched)."
    exit 1
}

$result = ($resultLine -replace "^\s*RESULTJSON ", "") | ConvertFrom-Json
if (-not $result.ok) {
    Write-Fail "Update failed: $($result.error)"
    Write-Fail "state.vscdb may be partially written - restore with:"
    Write-Fail "  Copy-Item '$bak' '$vscdb' -Force   (with Cursor closed)"
    exit 1
}

Write-Ok "Base URL set to $NimUrl"
if ($result.oldUrl -and $result.oldUrl -ne $NimUrl) {
    Write-Warn2 "This replaced the previous custom endpoint: $($result.oldUrl)"
}
Write-Ok "4 models registered + API key encrypted and verified"

# ------------------------------ summary -------------------------------

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "  Done! NVIDIA NIM is configured in Cursor." -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Endpoint : $NimUrl"
Write-Host ""
Write-Host "  Models registered:"
Write-Host "    - GLM 5.3               (text)"
Write-Host "    - GLM 5.3 Flash         (text + image)"
Write-Host "    - DeepSeek V4.1 Flash   (text + image)"
Write-Host "    - Kimi K3               (text)"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    1. Start Cursor (restart it if it was left running)."
Write-Host "    2. Open the model picker and pick one of the new models."
Write-Host "    3. Notes:"
Write-Host "       - Cursor's Tab autocomplete uses Cursor's own models;"
Write-Host "         these custom models apply to chat/agent/cmd-K."
Write-Host "       - NVIDIA NIM models 'think' by default; you can set a"
Write-Host "         reasoning_effort parameter per model in Cursor's"
Write-Host "         model settings if you want control."
Write-Host "       - DeepSeek V4.1 Flash can be very slow on its first"
Write-Host "         messages (NVIDIA cold-start); it speeds up after."
Write-Host ""
