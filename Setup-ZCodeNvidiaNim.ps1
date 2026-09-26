# =====================================================================
#  Setup-ZCodeNvidiaNim.ps1
#
#  Adds NVIDIA NIM (https://integrate.api.nvidia.com) as a model
#  provider in ZCode Desktop and registers 4 models:
#
#    - z-ai/glm-5.3                    (GLM 5.3,           text)
#    - z-ai/glm-5.3-flash              (GLM 5.3 Flash,     text + image)
#    - deepseek-ai/deepseek-v4.1-flash (DeepSeek V4.1,     text + image)
#    - moonshotai/kimi-k3              (Kimi K3,           text)
#
#  All models get a reasoning-parameter override so that ZCode sends
#  only "reasoning_effort" to NVIDIA's endpoint. Without it every
#  request fails with:
#    400 Validation: Unsupported parameter(s): enable_thinking, reasoning
#
#  USAGE (the only thing you need is your NVIDIA API key, nvapi-...):
#    1. CLOSE ZCode completely.
#    2. Right-click this file -> "Run with PowerShell", or run:
#         powershell -ExecutionPolicy Bypass -File .\Setup-ZCodeNvidiaNim.ps1
#    3. Paste your nvapi-... key when asked.
#    4. Start ZCode -> model picker -> NVIDIA NIM -> pick a model.
#
#  The script is idempotent: re-running it updates the existing setup.
#  Backups of both config files are created next to the originals.
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

$ProviderId  = "nvidia-nim"
$ProviderNm  = "NVIDIA NIM"
$BaseUrl     = "https://integrate.api.nvidia.com/v1"

# Map expression: translate ZCode's reasoning level into the ONE param
# NVIDIA NIM accepts. null -> param omitted entirely (reasoning off).
$ReasoningMap = '{ "reasoning_effort": reasoningLevel == "disabled" || reasoningLevel == "none" ? null : reasoningLevel == "enabled" ? "high" : reasoningLevel }'

$Models = @(
    @{ Id = "z-ai/glm-5.3";                    Name = "GLM 5.3";            Context = 1048576; Output = 128000; Image = $false },
    @{ Id = "z-ai/glm-5.3-flash";              Name = "GLM 5.3 Flash";      Context = 1048576; Output = 128000; Image = $true  },
    @{ Id = "deepseek-ai/deepseek-v4.1-flash"; Name = "DeepSeek V4.1 Flash"; Context = 1048576; Output = $null;  Image = $true  },
    @{ Id = "moonshotai/kimi-k3";              Name = "Kimi K3";             Context = 1048576; Output = $null;  Image = $false }
)

$ModelIds = @($Models | ForEach-Object { $_.Id })

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

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM: a BOM breaks ZCode's JSON parser
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Ensure-Property {
    # adds a property with a default value if it does not exist yet
    param($Object, [string]$Name, $Default)
    if (-not ($Object.PSObject.Properties[$Name])) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Default
    }
}

function New-ModelRule {
    param([string]$ModelId, [int]$ContextWindow)
    [pscustomobject]@{
        modelId    = $ModelId
        config     = [pscustomobject]@{
            properties  = [pscustomobject]@{ contextWindow = $ContextWindow }
            optionSpecs = [pscustomobject]@{
                reasoningLevel = [pscustomobject]@{ map = $ReasoningMap }
            }
        }
        providerId = $ProviderId
    }
}

function New-ModelDef {
    param($M)
    $limit = [ordered]@{ context = [int]$M.Context }
    if ($M.Output) { $limit["output"] = [int]$M.Output }
    $input = @("text"); if ($M.Image) { $input = @("text", "image") }
    [pscustomobject]@{
        name       = $M.Name
        reasoning  = [pscustomobject]@{
            enabled        = $true
            variants       = @("low", "high", "max")
            defaultVariant = "max"
        }
        limit      = [pscustomobject]$limit
        modalities = [pscustomobject]@{
            input  = $input
            output = @("text")
        }
        zcode      = [pscustomobject]@{ modified = $false }
    }
}

# ------------------------------ intro --------------------------------

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "  ZCode <-> NVIDIA NIM setup" -ForegroundColor Cyan
Write-Host "  Models: GLM 5.3, GLM 5.3 Flash, DeepSeek V4.1 Flash, Kimi K3" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan

# ------------------------- locate config dir -------------------------

Write-Step "Looking for ZCode config"

$v2dir = Join-Path $env:USERPROFILE ".zcode\v2"
$provFile = Join-Path $v2dir "provider_config.json"
$confFile = Join-Path $v2dir "config.json"

if (-not (Test-Path $provFile) -or -not (Test-Path $confFile)) {
    Write-Fail "ZCode config not found in $v2dir"
    Write-Fail "Start ZCode once (so it creates its config), then re-run this script."
    exit 1
}
Write-Ok "Found $v2dir"

# ------------------------ zcode running check ------------------------

Write-Step "Checking that ZCode is closed"

$zcode = @(Get-Process -Name "ZCode" -ErrorAction SilentlyContinue)
if ($zcode.Count -gt 0 -and -not $Force) {
    Write-Warn2 "ZCode is currently running ($($zcode.Count) process(es))."
    Write-Warn2 "If you continue without closing it, ZCode may overwrite these"
    Write-Warn2 "changes with its in-memory settings when it exits."
    $ans = Read-Host "    Close ZCode and continue anyway? (y/N)"
    if ($ans -notmatch "^[Yy]") { Write-Fail "Aborted. Close ZCode and re-run."; exit 1 }
}
elseif ($zcode.Count -eq 0) { Write-Ok "ZCode is not running" }

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

    $verified = $false
    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/models" -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 30
        $available = @($resp.data | ForEach-Object { $_.id })
        $found = @($ModelIds | Where-Object { $available -contains $_ })
        if ($found.Count -eq $ModelIds.Count) {
            Write-Ok "Key works; all 4 models are available on your account"
        } else {
            Write-Warn2 "Key works; but only these of the 4 models were found: $($found -join ', ')"
            Write-Warn2 "(The others may still work - continuing.)"
        }
        $verified = $true
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
            $verified = $true
        }
    }
}

# ------------------------ load provider_config ------------------------

Write-Step "Updating provider_config.json"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

$provRaw = [System.IO.File]::ReadAllText($provFile)
$provBak = "$provFile.before-nvidia-nim-$stamp.bak"
Copy-Item $provFile $provBak

$prov = $provRaw | ConvertFrom-Json

Ensure-Property $prov "config" ([pscustomobject]@{})
Ensure-Property $prov.config "providerOrder" @()
Ensure-Property $prov.config "providerConfigRules" ([pscustomobject]@{})
Ensure-Property $prov.config.providerConfigRules "providerRules" @()
Ensure-Property $prov.config "modelConfigRules" ([pscustomobject]@{})
Ensure-Property $prov.config.modelConfigRules "providerModelRules" @()
Ensure-Property $prov.config.modelConfigRules "manualProviderModelRules" @()

$prov.config.providerOrder          = @($prov.config.providerOrder)
$prov.config.providerConfigRules.providerRules = @($prov.config.providerConfigRules.providerRules)
$prov.config.modelConfigRules.providerModelRules      = @($prov.config.modelConfigRules.providerModelRules)
$prov.config.modelConfigRules.manualProviderModelRules = @($prov.config.modelConfigRules.manualProviderModelRules)

# reuse the 'group' value used by other personal providers in this install
$group = "standard-personal"
foreach ($r in $prov.config.providerConfigRules.providerRules) {
    if ($r.config -and $r.config.group) { $group = $r.config.group; break }
}

# ---- provider rule (replace if exists, else add)
$providerRule = [pscustomobject]@{
    providerId   = $ProviderId
    providerName = $ProviderNm
    config       = [pscustomobject]@{
        group  = $group
        access = [pscustomobject]@{ type = "api-key"; apiKey = $ApiKey }
        api    = [pscustomobject]@{ type = "openai-chat-completions"; baseUrl = $BaseUrl }
        personalModelIds = $ModelIds
        modelOrder       = $ModelIds
    }
}

$rules = @($prov.config.providerConfigRules.providerRules | Where-Object { $_.providerId -ne $ProviderId })
$rules += $providerRule
$prov.config.providerConfigRules.providerRules = $rules

# ---- provider order (append at the end)
if (@($prov.config.providerOrder) -notcontains $ProviderId) {
    $prov.config.providerOrder = @($prov.config.providerOrder) + $ProviderId
}

# ---- per-model rules (drop old ones for this provider, add fresh)
$modelRules = @($prov.config.modelConfigRules.providerModelRules | Where-Object { $_.providerId -ne $ProviderId })
foreach ($m in $Models) { $modelRules += (New-ModelRule -ModelId $m.Id -ContextWindow $m.Context) }
$prov.config.modelConfigRules.providerModelRules = $modelRules

# --------------------------- load config.json -------------------------

Write-Step "Updating config.json"

$confRaw = [System.IO.File]::ReadAllText($confFile)
$confBak = "$confFile.before-nvidia-nim-$stamp.bak"
Copy-Item $confFile $confBak

$conf = $confRaw | ConvertFrom-Json
Ensure-Property $conf "provider" ([pscustomobject]@{})

$modelsObj = [ordered]@{}
foreach ($m in $Models) { $modelsObj[$m.Id] = New-ModelDef $m }

$nvidiaProvider = [pscustomobject]@{
    name     = $ProviderNm
    kind     = "openai-compatible"
    options  = [pscustomobject]@{
        apiKey         = $ApiKey
        baseURL        = $BaseUrl
        apiKeyRequired = $true
    }
    source   = "custom"
    models   = $modelsObj
}

if ($conf.provider.PSObject.Properties[$ProviderId]) {
    $conf.provider.$ProviderId = $nvidiaProvider
} else {
    $conf.provider | Add-Member -NotePropertyName $ProviderId -NotePropertyValue $nvidiaProvider
}

# ------------------------------ write out -----------------------------

Write-Step "Writing config files"

Write-Utf8NoBom $provFile ($prov | ConvertTo-Json -Depth 100)
Write-Utf8NoBom $confFile ($conf | ConvertTo-Json -Depth 100)

# verify both files still parse; roll back if not
foreach ($pair in @(@($provFile, $provBak), @($confFile, $confBak))) {
    try {
        $null = [System.IO.File]::ReadAllText($pair[0]) | ConvertFrom-Json
    }
    catch {
        Write-Fail "$($pair[0]) no longer parses - restoring backup."
        Copy-Item $pair[1] $pair[0] -Force
        Write-Fail "Backup restored. Please report this: the ZCode config layout may have changed."
        exit 1
    }
}

Write-Ok "provider_config.json updated  (backup: $(Split-Path $provBak -Leaf))"
Write-Ok "config.json updated           (backup: $(Split-Path $confBak -Leaf))"

# ------------------------------ summary -------------------------------

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "  Done! NVIDIA NIM is configured in ZCode." -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Provider : $ProviderNm  (id: $ProviderId)"
Write-Host "  Endpoint : $BaseUrl"
Write-Host ""
Write-Host "  Models registered:"
foreach ($m in $Models) {
    $mod = "text"; if ($m.Image) { $mod = "text + image" }
    Write-Host ("    - {0,-32} {1,-18} {2} ctx" -f $m.Name, $mod, $m.Context)
}
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    1. Start ZCode (restart it if it was left running)."
Write-Host "    2. Open the model picker and choose:"
Write-Host "         NVIDIA NIM  ->  GLM 5.3 / GLM 5.3 Flash /"
Write-Host "                         DeepSeek V4.1 Flash / Kimi K3"
Write-Host "    3. Notes:"
Write-Host "       - DeepSeek V4.1 Flash can be very slow on its first"
Write-Host "         messages (NVIDIA cold-start); it speeds up after."
Write-Host "       - Kimi K3 is registered text-only."
Write-Host ""
