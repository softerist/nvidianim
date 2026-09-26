# =====================================================================
#  cursor-ade-nvidia-nim-patch.ps1
#
#  Cursor ADE patch - NVIDIA NIM edition (Cursor 3.22.7 markers).
#
#  Enables Cursor's built-in local-mode routing (bring-your-own-gateway)
#  and extends the reasoning-effort picker so it also appears for the
#  NVIDIA NIM models served through your own gateway endpoint
#  (z-ai/glm-5.3, z-ai/glm-5.3-flash, deepseek-ai/deepseek-v4.1-flash,
#  moonshotai/kimi-k3). Model ids are matched AFTER prefix stripping
#  (the part after "/" and before "@"), so "z-ai/glm-5.3" matches
#  "glm-5.3". The x-preview-f-free (OpenCode Zen) id stays supported.
#
#  Pair with the endpoint configuration (openAIBaseUrl + nvapi key) -
#  e.g. Setup-CursorNvidiaNim.ps1 from github.com/softerist/nvidianim.
#
#  Usage:
#    One-liner (checks status, applies if needed):
#      irm https://raw.githubusercontent.com/softerist/nvidianim/main/cursor-ade-nvidia-nim-patch.ps1 | iex
#    Or explicitly:
#      powershell -ExecutionPolicy Bypass -File .\cursor-ade-nvidia-nim-patch.ps1 -Action Status
#      powershell -ExecutionPolicy Bypass -File .\cursor-ade-nvidia-nim-patch.ps1 -Action Apply
#      powershell -ExecutionPolicy Bypass -File .\cursor-ade-nvidia-nim-patch.ps1 -Action Restore
#    Default action when none is given: Apply. -AppRoot overrides the
#    Cursor app directory (for testing). -Force skips the running-Cursor
#    guard.
#
#  Close Cursor before Apply/Restore (the script checks). Backups:
#  *.nvidia-nim.bak next to each patched bundle.
# =====================================================================

param(
    [ValidateSet("Status", "Apply", "Restore")]
    [string]$Action = "Apply",
    [string]$AppRoot = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $AppRoot) {
    $AppRoot = Join-Path $env:LOCALAPPDATA "Programs\cursor\resources\app"
}

# guard for Apply/Restore: patching a running Cursor is undone on its exit
if ($Action -ne "Status" -and -not $Force) {
    $running = @(Get-Process -Name "Cursor" -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host ""
        Write-Host "    [!!] Cursor is currently running ($($running.Count) process(es))." -ForegroundColor Yellow
        Write-Host "    [!!] Close it first, or it will overwrite the patch when it exits." -ForegroundColor Yellow
        $ans = Read-Host "    Patch anyway? (y/N)"
        if ($ans -notmatch "^[Yy]") {
            Write-Host "    [XX] Aborted. Close Cursor and re-run." -ForegroundColor Red
            return
        }
    }
}

$workbenchTarget = Join-Path $AppRoot "out\vs\workbench\workbench.glass.main.js"
$agentExecTarget = Join-Path $AppRoot "extensions\cursor-agent-exec\dist\main.js"
$localRuntimeTarget = Join-Path $AppRoot "extensions\cursor-local-agent-runtime\dist\main.js"

# ---- marker: feature flags object (renamed yc -> vl since 3.20-ish) --
$flagsOriginal = (
    'vl={extensionIsDev:!1,developmentTooling:!1,' +
    'enableTraceSpanCollection:!0,enableEmbeddingsModelToggle:!1,' +
    'enableCPPControlTokenToggle:!1,cursorPredictionOptions:!1,' +
    'localMode:!1}}'
)
$flagsPatched = $flagsOriginal.Replace('localMode:!1}}', 'localMode:!0}}')

# ---- marker: reasoning-effort picker gate (renamed q3m -> oJm) ------
$pickerOriginal = 'function oJm(t){return t==="treatment"}'
$pickerPatched = 'function oJm(t){return vl.localMode||t==="treatment"}'

# ---- marker: base model label forced on in local mode ---------------
$labelOriginal = 'P=f===void 0?!1:f,N=S===void 0?"bottom":S,O=HPh();'
$labelPatched = 'P=vl.localMode?!0:f===void 0?!1:f,N=S===void 0?"bottom":S,O=HPh();'

# ---- marker: per-model reasoning parameter (agent-exec + local-runtime)
# Model matcher function (identical text in both extension bundles).
$reasoningOriginal = (
    'function _(e){const t=function(e){let t=e.trim().toLowerCase();' +
    'const r=t.lastIndexOf("/");-1!==r&&(t=t.slice(r+1));' +
    'const n=t.indexOf("@");return-1!==n&&(t=t.slice(0,n)),t}(e);' +
    'if(/^gpt-5(?:\.\d+)?$/u.test(t))return b}'
)
# NIM clause appended before the closing brace. Ids are matched after
# prefix stripping: z-ai/glm-5.3 -> glm-5.3, moonshotai/kimi-k3 -> kimi-k3.
$nimClause = (
    ';if(/^(?:x-preview-f-free|glm-5\.3(?:-flash)?|' +
    'deepseek-v4\.1-flash|kimi-k3)$/u.test(t))return{' +
    'param:"reasoning_effort",values:["low","medium","high","max"],' +
    'defaultValue:"high"}}'
)
$reasoningPatched = $reasoningOriginal.Substring(0, $reasoningOriginal.Length - 1) + $nimClause

$patches = @(
    [pscustomobject]@{
        Name = "Local gateway and reasoning picker"
        Target = $workbenchTarget
        Replacements = @(
            [pscustomobject]@{ Original = $flagsOriginal;  Patched = $flagsPatched },
            [pscustomobject]@{ Original = $pickerOriginal; Patched = $pickerPatched },
            [pscustomobject]@{ Original = $labelOriginal;  Patched = $labelPatched }
        )
    }
    [pscustomobject]@{
        Name = "Agent-exec reasoning (NIM models)"
        Target = $agentExecTarget
        Replacements = @(
            [pscustomobject]@{ Original = $reasoningOriginal; Patched = $reasoningPatched }
        )
    }
    [pscustomobject]@{
        Name = "Local-runtime reasoning (NIM models)"
        Target = $localRuntimeTarget
        Replacements = @(
            [pscustomobject]@{ Original = $reasoningOriginal; Patched = $reasoningPatched }
        )
    }
)

# ------------------------- state machinery ---------------------------

function Get-LiteralCount {
    param(
        [string]$Text,
        [string]$Needle
    )

    $count = 0
    $offset = 0
    while (($index = $Text.IndexOf(
        $Needle,
        $offset,
        [StringComparison]::Ordinal
    )) -ge 0) {
        $count++
        $offset = $index + $Needle.Length
    }
    return $count
}

function Get-FilePatchState {
    param(
        [string]$Text,
        [object[]]$Replacements,
        [string]$Name
    )

    $states = foreach ($replacement in $Replacements) {
        $originalCount = Get-LiteralCount `
            -Text $Text `
            -Needle $replacement.Original
        $patchedCount = Get-LiteralCount `
            -Text $Text `
            -Needle $replacement.Patched

        if ($originalCount -eq 1 -and $patchedCount -eq 0) {
            "Original"
            continue
        }
        if ($originalCount -eq 0 -and $patchedCount -eq 1) {
            "Patched"
            continue
        }

        throw (
            "Unsupported Cursor state for $Name. " +
            "Original markers: $originalCount. " +
            "Patched markers: $patchedCount. " +
            "(A Cursor update may have changed the bundle - " +
            "markers need a refresh.)"
        )
    }

    $uniqueStates = @($states | Select-Object -Unique)
    if ($uniqueStates.Count -eq 1) {
        return $uniqueStates[0]
    }
    if ($uniqueStates -contains "Original" -and
        $uniqueStates -contains "Patched") {
        return "Partial"
    }

    if ($states.Count -eq 0) {
        return "Original"
    }

    throw "Unsupported aggregate Cursor state for $Name."
}

function Get-PatchRecord {
    param([pscustomobject]$Patch)

    if (-not (Test-Path -LiteralPath $Patch.Target -PathType Leaf)) {
        throw "Cursor ADE file not found: $($Patch.Target)"
    }

    $content = [IO.File]::ReadAllText($Patch.Target)
    $state = Get-FilePatchState `
        -Text $content `
        -Replacements $Patch.Replacements `
        -Name $Patch.Name

    return [pscustomobject]@{
        Patch = $Patch
        Content = $content
        State = $state
        Backup = "$($Patch.Target).nvidia-nim.bak"
        Temporary = "$($Patch.Target).nvidia-nim.tmp"
    }
}

function Write-PatchStatus {
    param([object[]]$Records)

    $states = @($Records.State | Select-Object -Unique)
    $overallState = if ($states.Count -eq 1) {
        $states[0]
    } else {
        "Mixed"
    }

    Write-Output "State: $overallState"
    foreach ($record in $Records) {
        $hash = (
            Get-FileHash -Algorithm SHA256 -LiteralPath $record.Patch.Target
        ).Hash
        Write-Output "$($record.Patch.Name): $($record.State)"
        Write-Output "Target: $($record.Patch.Target)"
        Write-Output "SHA256: $hash"
        Write-Output "Backup: $($record.Backup)"
        Write-Output (
            "Backup exists: " +
            (Test-Path -LiteralPath $record.Backup -PathType Leaf)
        )
    }
}

function Write-AtomicText {
    param(
        [string]$Target,
        [string]$Temporary,
        [string]$Content
    )

    [IO.File]::WriteAllText(
        $Temporary,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
    # 3-arg File.Move(overwrite) is .NET Core only - keep PS 5.1 compat
    if (Test-Path -LiteralPath $Target -PathType Leaf) {
        [IO.File]::Delete($Target)
    }
    [IO.File]::Move($Temporary, $Target)
}

# ------------------------------ actions ------------------------------

$records = @($patches | ForEach-Object { Get-PatchRecord -Patch $_ })

switch ($Action) {
    "Status" {
        Write-PatchStatus -Records $records
    }
    "Apply" {
        foreach ($record in $records) {
            if ($record.State -eq "Patched") {
                continue
            }

            if (-not (Test-Path -LiteralPath $record.Backup)) {
                if ($record.State -ne "Original") {
                    throw (
                        "Cannot create an original backup from state " +
                        "$($record.State): $($record.Patch.Name)."
                    )
                }
                Copy-Item `
                    -LiteralPath $record.Patch.Target `
                    -Destination $record.Backup
            }

            $updated = $record.Content
            foreach ($replacement in $record.Patch.Replacements) {
                $updated = $updated.Replace(
                    $replacement.Original,
                    $replacement.Patched
                )
            }
            $updatedState = Get-FilePatchState `
                -Text $updated `
                -Replacements $record.Patch.Replacements `
                -Name $record.Patch.Name
            if ($updatedState -ne "Patched") {
                throw "Patch validation failed for $($record.Patch.Name)."
            }

            Write-AtomicText `
                -Target $record.Patch.Target `
                -Temporary $record.Temporary `
                -Content $updated
        }

        $writtenRecords = @(
            $patches | ForEach-Object { Get-PatchRecord -Patch $_ }
        )
        if (@($writtenRecords.State | Where-Object { $_ -ne "Patched" })) {
            throw "Cursor bundle verification failed after write."
        }
        Write-PatchStatus -Records $writtenRecords
    }
    "Restore" {
        foreach ($record in $records) {
            if (-not (Test-Path -LiteralPath $record.Backup -PathType Leaf)) {
                throw "Backup not found: $($record.Backup)"
            }

            $backupContent = [IO.File]::ReadAllText($record.Backup)
            $backupState = Get-FilePatchState `
                -Text $backupContent `
                -Replacements $record.Patch.Replacements `
                -Name "$($record.Patch.Name) backup"
            if ($backupState -ne "Original") {
                throw "Backup is not original: $($record.Backup)"
            }
        }

        foreach ($record in $records) {
            Copy-Item `
                -LiteralPath $record.Backup `
                -Destination $record.Temporary -Force
            if (Test-Path -LiteralPath $record.Patch.Target -PathType Leaf) {
                [IO.File]::Delete($record.Patch.Target)
            }
            [IO.File]::Move($record.Temporary, $record.Patch.Target)
        }

        $restoredRecords = @(
            $patches | ForEach-Object { Get-PatchRecord -Patch $_ }
        )
        Write-PatchStatus -Records $restoredRecords
    }
}
