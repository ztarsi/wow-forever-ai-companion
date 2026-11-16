# Automatic companion updates (optional)

Your companion's advice can update itself after you play. When the game saves (`/aic save`, `/reload` or logging out), a small program checks what changed. Only when something should change your advice does it start your chosen AI, within the limits you set.

Watching, comparing snapshots, generating the data add-on and rebuilding the dashboard use local Python, without AI tokens. Only updating the plan uses your chosen AI account.

## Choose your provider

The watcher, change queue, run limits, publishing and schedulers are shared. Each provider has its own CLI command, permissions and output parser in `providers.py`. Existing installations continue to use Claude unless you explicitly switch.

### Claude

- Install Claude Code and sign in once on a supported paid Claude plan (Pro or Max).
- Have a first `plans.json` from your companion; automatic updates maintain that plan.
- Double-click **Install-Windows.cmd** or **Install-Mac.command**. These retain an existing provider choice and default to Claude on a fresh installation.
- Claude keeps its existing Sonnet model default, `claude_cmd` setting and `max_budget_usd_per_run` flag.

### Codex / ChatGPT

- Install a current **Codex CLI** on the game computer and sign in once with `codex login`. The assistant can handle setup; account sign-in is yours. The CLI must support `exec --json --ephemeral --sandbox workspace-write`.
- Have a first private `plans.json` from your companion. Use that same plan when moving from Claude.
- Double-click **Install-Codex-Windows.cmd** or **Install-Codex-Mac.command**. This explicitly selects Codex, then uses the same Python setup and scheduler as Claude.
- Use the normal **Check** script to verify CLI discovery, sign-in, Python, the snapshot and the existing plan. No AI request is made by the check.

This runs **Codex CLI using its saved authentication**. It does not drive an open ChatGPT conversation. Ordinary ChatGPT chat without local command tools cannot run the watcher. Model and CLI availability depend on the account and client; free desktop access does not guarantee access to the same model in the CLI. See [OpenAI's non-interactive CLI guide](https://learn.chatgpt.com/docs/non-interactive-mode) and [availability](https://learn.chatgpt.com/docs/pricing).

Codex uses its configured CLI/account model by default. For frequent updates, try the efficient Luna model if your CLI account offers it; set `codex_model` only to a model your account can use. No paid-only model is forced, and a failed or rate-limited run stays pending rather than switching to another provider. API-key authentication is billed separately from ChatGPT plans.

**Codex has no dollar-cap flag equivalent to Claude's.** The shared daily count, minimum gap and 20-minute process timeout apply, but `max_budget_usd_per_run` applies only to Claude. Codex reports token usage when supplied; dollar cost is shown as unavailable, never as free or $0.

### Gemini and other providers

Gemini support is coming later. No Gemini CLI is launched and no provider is silently substituted. To add a provider, implement its discovery, command and output decoder in `providers.py`, add it to the registry, and test it with a fake CLI. The scheduling and gameplay-change logic do not need another copy.

## Install, check or remove

You need Python 3; on Windows, tick "Add python.exe to PATH" during installation. Choose an installer above. It creates a private Python environment, installs `lupa`, starts the watcher and displays a checklist. A `FIX` line describes what is missing.

- **Windows:** if "Windows protected your PC" appears, choose **More info → Run anyway** only for the script you downloaded from this repository.
- **Mac:** if macOS blocks the script, use **System Settings → Privacy & Security → Open Anyway** for that script.

Double-click **Check-Windows.cmd** or **Check-Mac.command** to inspect the selected provider. **Uninstall-Windows.cmd** or **Uninstall-Mac.command** stops the watcher and preserves settings, plans and logs.

Ask your companion to switch providers when needed. It can run `python aic_auto.py provider claude` or `python aic_auto.py provider codex` with the installer's Python. Switching preserves both providers' settings, the plan, queued changes and usage history. It refuses to switch while an update holds the watcher lock. Only one provider runs at a time.

## What starts an update

- a level-up or a new level range
- quests picked up, finished or ready to turn in
- a new zone
- new talent points
- bags nearly full
- gear that needs repair or new gear
- profession milestones
- opening your bank, a profession window, a new trainer or vendor
- a question left with `/aic ask`

The first check records a baseline without an AI call. An unchanged save or return to a known zone starts nothing. The dashboard rebuilds locally on saves and after successful plan updates.

When an update finishes, you get a notification on your computer. If the data add-on or its `.toc` needs a full game restart, the notification says so. In the game, about 2 minutes after `/aic save`, the add-on also reminds you in chat, and the panel shows a **Load new advice** button: click it (or type `/reload`) to see the new advice. The game can only load new advice on a reload or login. Turn the in-game reminder off with `/aic reminder off`.

## Limits and settings

Current defaults are **50 updates/day and 5 minutes apart**, temporarily for testing. Normal intended limits are **3/day and 2 hours apart**; set those lower values for economical use. Web research is enabled only for a new zone or level range.

When a limit is reached, changes wait for the next allowed time. Failed runs count toward the daily allowance and retain their pending changes.

Settings, state and logs are stored outside the repository and game:

- **Windows:** `%APPDATA%\AICompanion\auto`
- **Mac:** `~/Library/Application Support/AICompanion/auto`

| Setting | Default | Applies to |
|---|---|---|
| `provider` | `claude` | Explicit choice: `claude` or `codex` |
| `max_runs_per_day` | 50 while testing (normally 3) | Shared daily run limit across providers |
| `min_gap_hours` | 0.083 (5 minutes) while testing (normally 2) | Shared gap across providers |
| `model` | `sonnet` | Existing Claude model setting only |
| `codex_model` | null | Codex model override; null uses the CLI/account default |
| `claude_cmd`, `codex_cmd` | discovered | Provider executable as an argument list |
| `max_budget_usd_per_run` | 0.75 | Claude only; unsupported by Codex |
| `enabled` | true | Pauses the watcher when false |
| `companion_dir` | Documents/AI Companion | Private persistent folder containing `plans.json` |
| `game_dir`, `account` | discovered | Game and account folders |

Do not copy a Claude model name into `codex_model`. Selecting Codex never interprets the legacy `model: sonnet` setting as an OpenAI model.

## Choosing a cost-effective model

See [model quality and economical use](MODEL_QUALITY.md) for the five-model synthetic check, measured results, limits of the comparison and the opt-in evaluator. Haiku and Luna are candidates for routine updates; existing defaults are preserved.

## Usage report

Ask your companion to run `python aic_auto.py report` using the installer's Python. It shows daily runs, failures, tokens, available cost estimates, provider counts and averages over the last seven active days. Older entries without a provider label are treated as Claude entries. Cached input is counted once.

On a subscription, Claude's dollar figure is an estimated usage value, not an additional charge. Codex dollar figures are unavailable. API-key usage follows the provider's separate API billing. Run limits do not guarantee how many updates a free or paid account will allow.

## How it works

- **Watching:** macOS uses a launch agent watching the save folder, plus a 30-minute retry interval. Windows uses Task Scheduler every five minutes while you are signed in.
- **Checking:** OS-neutral `core.py` compares snapshots, queues meaningful changes and applies the shared limits without starting AI.
- **Planning:** the selected adapter runs its CLI in the private companion folder with a compact change list. The prompt uses the shared gameplay rules in `companion/SKILL.md`; provider setup stays in each provider's own guide. The assistant updates only `plans.json`.
- **Publishing:** Python validates the plan, checks that existing characters remain, generates into a staging folder with the installed add-on interface and existing data `.toc`, then installs and reads back the generated files byte-for-byte. Invalid plans or failed AI runs restore the previous plan and retain pending changes.
- **Coordination:** `.automation-running` stays present through planning and publication so interactive companions can wait. The unattended run itself must not wait on its own marker.
- **Permissions:** Codex uses `workspace-write` in the companion folder, with no game-directory write grant, no approval prompts, and terminal network access disabled. Its built-in search is enabled only for research-triggering changes. Claude retains its tool allowlist, including Python execution; that allowlist is not a strict filesystem sandbox.
- **Logs:** run records and `last_result.txt` live in `logs/` beside `config.json`. They can contain private character information; keep them local.

The provider tests use stand-in CLIs without calling an AI. Both OS scheduler paths and both provider adapters are exercised by the automation CI jobs. Live Codex/game validation still needs a local trial.
