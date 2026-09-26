# NVIDIA NIM for ZCode & Cursor

One-shot installers that wire [NVIDIA NIM](https://build.nvidia.com) (`https://integrate.api.nvidia.com`) into **ZCode Desktop** and **Cursor** as a custom OpenAI-compatible provider, and register four models:

| Model | NVIDIA NIM id | Input |
|---|---|---|
| GLM 5.3 | `z-ai/glm-5.3` | text |
| GLM 5.3 Flash | `z-ai/glm-5.3-flash` | text + image |
| DeepSeek V4.1 Flash | `deepseek-ai/deepseek-v4.1-flash` | text + image |
| Kimi K3 | `moonshotai/kimi-k3` | text |

The only thing you need is an NVIDIA API key (`nvapi-...`, free from [build.nvidia.com](https://build.nvidia.com)). The scripts prompt for it, validate it against NVIDIA's API, back up your existing config, and are safe to re-run.

## Install (copy & paste one line)

**ZCode:**

```powershell
irm https://raw.githubusercontent.com/softerist/nvidianim/main/Setup-ZCodeNvidiaNim.ps1 | iex
```

**Cursor:**

```powershell
irm https://raw.githubusercontent.com/softerist/nvidianim/main/Setup-CursorNvidiaNim.ps1 | iex
```

Or download the `.ps1` file and run it manually:

```powershell
powershell -ExecutionPolicy Bypass -File .\Setup-ZCodeNvidiaNim.ps1
powershell -ExecutionPolicy Bypass -File .\Setup-CursorNvidiaNim.ps1
```

## Before you run

1. **Close the app completely** (ZCode or Cursor respectively) - the script checks and warns, but closing it is what makes the change stick.
2. Have your `nvapi-...` key ready.
3. Windows PowerShell 5.1 or newer (any Windows 10/11 has it).

## What gets changed

**ZCode** (`%USERPROFILE%\.zcode\v2\`):
- `provider_config.json` - adds provider `nvidia-nim` (endpoint, key, model list) and per-model rules. The per-model rules carry a reasoning-level override that makes ZCode send **only** `reasoning_effort` - without it, NVIDIA NIM rejects ZCode's default request style with `400: Unsupported parameter(s): enable_thinking, reasoning`.
- `config.json` - adds the provider with full model definitions (1M context, reasoning variants).

**Cursor** (`%APPDATA%\Cursor\`):
- `User\globalStorage\state.vscdb` - sets the base-URL override, registers the models, and stores your key encrypted exactly the way Cursor stores it. Note: Cursor has a **single** custom-endpoint slot, so this replaces any previously configured endpoint/key (e.g. OpenCode Zen).
- Nothing is installed; Cursor's Tab autocomplete keeps using Cursor's own models - the custom models apply to chat / agent / cmd-K.

**Optional Cursor add-on:** the reasoning-level picker (and Cursor's local-provider UI) for these models is gated behind a hidden feature flag. If you want it, [softerist/cursor](https://github.com/softerist/cursor) hosts `cursor-ade-nvidia-nim-patch.ps1`, which enables that built-in path for this endpoint:

```powershell
irm https://raw.githubusercontent.com/softerist/cursor/main/cursor-ade-nvidia-nim-patch.ps1 | iex
```

It is not required - models work without it, you just don't get the reasoning dropdown.

## Safety

- Timestamped backups are created next to every file before it is modified (`*.before-nvidia-nim-*.bak`).
- Both scripts verify their changes after writing (ZCode re-parses with auto-rollback; Cursor decrypts the stored key back).
- Re-running a script updates the existing setup in place (e.g. to change the API key) - it never duplicates providers, models, or keys. Keep the most recent backup and delete older ones occasionally (the Cursor one is ~85 MB).
- The scripts own the entries they manage: manual tweaks inside the `nvidia-nim` provider / model lists are reset to the script's values on the next run.
- Cursor must be installed for the Cursor script - it reuses Cursor's own bundled Node runtime, so there are no extra dependencies.

## Performance reality check (NVIDIA free tier)

NVIDIA NIM works, but time-to-first-token on large prompts (Cursor/ZCode agent requests are big: long system prompts + many tools) can be slow and varies heavily with time of day. Measured on 2026-09-26 with a realistic agent-sized prompt:

| Model | First token after |
|---|---|
| GLM 5.3 Flash | ~17 s |
| Kimi K3 | ~60 s |
| GLM 5.3 | ~2 min (cold or warm) |
| DeepSeek V4.1 Flash | minutes, sometimes no response at all |

Practical guidance: use **GLM 5.3 Flash** (or Kimi K3 with patience) for interactive work, don't give up on a reply before a couple of minutes, and treat DeepSeek-on-NIM as best-effort. Small prompts answer much faster - the delay scales with prompt size and current NVIDIA capacity. If that latency hurts, add a second, faster BYOK endpoint for interactive work and keep NIM for its large context.

## Notes

- NVIDIA NIM models "think" by default. ZCode exposes reasoning levels (low/high/max) for these models; Cursor sends no reasoning parameters by default but lets you attach a `reasoning_effort` parameter per model in its model settings (or use the optional patch above).
- Kimi K3 is registered text-only.
