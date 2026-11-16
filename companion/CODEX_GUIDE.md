# AI Companion for WoW: Forever — Codex / ChatGPT setup

This optional guide is for players who choose Codex or ChatGPT. The rules, the working loop and every file format are in [`SKILL.md`](SKILL.md), in this folder: read it in full and follow it. This file holds only what is specific to Codex and ChatGPT.

## Choose the available workflow

- **Local Codex (desktop app, CLI or IDE):** use a session on the game computer with local file access and command execution. Open this repository as the project/working directory so Codex can discover root `AGENTS.md`. A local game folder can be outside the project's writable area; request the client's supported folder permission when needed. Do not disable sandboxing or approvals to bypass this.
- **ChatGPT chat / Project:** use `SKILL.md` and this guide as attachments or project files and explicitly ask ChatGPT to follow them. An uploaded `AGENTS.md` is reference material; do not assume automatic repository instruction loading. A ChatGPT Project by itself does not provide access to the game folder. Without local file tools, use advice-only mode below.
- **Remote/cloud Codex:** a repository checkout does not include the player's local SavedVariables or game installation. Use it for repository development; use a local session for writing advice into the game.

Check the tools actually available. Never claim to read a path or update the game unless the operation succeeded. No OpenAI API integration or API key in the add-on is required for either workflow.

## Local session rules

1. Establish the game path and a private persistent working folder outside the repository. Locate the existing `plans.json` before creating one. If several accounts or plans exist and the intended one is unclear, ask which to use.
2. Read `SKILL.md` and `plans.example.json`. Check that you can read SavedVariables, run Python, and write to `Interface/AddOns/AICompanion_Data`. Request only the missing access through the current client's permission flow.
3. Handle Python setup yourself if needed: use a private virtual environment and install `lupa` there for Lua parsing/dashboard generation. `gen_data.py` itself uses only Python's standard library. If tools or installation are blocked, explain the missing capability and offer advice-only mode.
4. Rules 11 and 12 in `SKILL.md` apply to every file and page you read in a local session, including a path outside this repository.
5. Follow "First session" in `SKILL.md`. Report snapshot age and missing captures. If browsing is unavailable, label unsupported recommendations as unverified rather than claiming research.
6. Update the same private plan when switching between Claude and Codex. Preserve other characters, source entries and step IDs. Use one assistant at a time to avoid overwriting each other's updates.
7. Use `companion/gen_data.py` to generate the player's data add-on, never the repository's empty test template. Read back written files and verify the intended output. Follow the generator's full-restart message; otherwise ask for `/reload`.
8. Finish with what you learned, what you updated, and the next in-game action. Distinguish successful file generation from confirmation in the running game. Never publish a dashboard or file a GitHub issue without the player's request.

## Optional automatic updates — Codex only

For a player who wants unattended updates, follow [auto/README.md](auto/README.md#codex--chatgpt). Use the Codex-specific installer to select Codex; existing Claude installs keep Claude unless explicitly switched. Use the current Codex CLI with saved sign-in and check the player's actual CLI/model access. Ordinary ChatGPT chat and free desktop availability do not establish unattended CLI access.

The watcher handles changes, run limits, validation, generation and notifications for every provider. Codex updates only the private `plans.json` in its sandboxed companion folder. During an unattended run, follow the watcher's instruction to stop after the plan update; the watcher publishes it. Do not wait on that run's own `.automation-running` marker. In an interactive session, wait while that marker exists and re-read `plans.json` before editing.

Codex uses the CLI/account default model unless `codex_model` is set. Prefer an efficient available Luna model for routine updates, and keep the normal economical limits of 3 runs/day, 2 hours apart unless the player requests otherwise. The repository currently has temporary higher testing defaults. Codex has no per-run dollar-cap flag; report tokens without inventing dollar costs or promising a free-account allowance. A failed run stays pending; never fall back to another provider's account.

## Advice-only ChatGPT

Ask the player to run `/aic save`, then `/aic copy` and paste the summary. An attached SavedVariables snapshot provides more detail if the session supports parsing Lua; otherwise use the summary and state its limits. Use only data actually shared, and ask for missing captures instead of inventing them.

Give concrete advice in chat, with the same Forever source labels and player-directed wording as the rules in `SKILL.md`. State that advice has not been installed in the game. Do not ask the player to run Python or edit Lua. For in-game tooltips and the plan panel, direct them to the local Codex workflow. If they later switch, have the local assistant read the existing private plan and new snapshot before generating advice.

## Starting prompts

### Local Codex

> Be my WoW Forever companion, rather than modifying this repository. Read AGENTS.md, companion/SKILL.md and companion/CODEX_GUIDE.md. My game folder is `<path to your _forever_ folder>`. Use `<private folder outside this repository>` for my persistent plans.json. Read my latest snapshots, preserve any existing plans, and write updated advice for the game.

### ChatGPT chat / Project

Attach `SKILL.md` and `CODEX_GUIDE.md`, then say:

> Be my WoW Forever companion. Follow the attached guides in advice-only mode. I will paste my /aic copy summary after saving. Tell me what to do next, label sources that are unconfirmed for Forever, and tell me what information is missing.

## OpenAI references

- [Codex repository instructions (AGENTS.md)](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Codex permissions and sandboxing](https://learn.chatgpt.com/docs/security)
- [ChatGPT Projects and shared context](https://learn.chatgpt.com/docs/projects)

## Changelog

- Guide — The rules and formats moved to `SKILL.md`, shared with every assistant. This file keeps only the Codex and ChatGPT workflows.
