# Working on this repository

This is the AI Companion add-on for **World of Warcraft: Forever** and the tools an assistant uses with it. The owner is a product manager who does not read or write code and does not run commands. Explain outcomes, not code.

## Rules

1. **Forever only.** Client interface 16001. The client uses the modern (Mainline-style) add-on API: `C_Container`, `C_Traits`, `C_AuctionHouse`, `C_TooltipInfo`, `TooltipDataProcessor`. Do not assume a Classic or retail API exists; guard every game call with `pcall` (the `try` helper) and degrade to no output.
   - **Check a function exists before using it** in `tests/forever/api_names.json`: every function, event and key enum an in-game dump of the real client found, from the [ForeverAPI](https://github.com/zmarotrix/ForeverAPI) project (MIT). `tests/test_forever_api.py` fails if the add-on or the stand-in client uses a name Forever lacks. The dump proves a function exists, not how it behaves; behaviour is confirmed only in the real game. Fuller references: ForeverAPI's `docs/` (signatures, per-system pages) and ForeverPlusPlus `docs/forever-api.md` (in-game behaviour notes, including secret values). Refresh the name list after a game patch.
2. **No personal data in the repository.** No character names, account names or numbers, SavedVariables files, or plan files. `AddOns/AICompanion_Data/AICompanion_Data.lua` ships with empty tables.
3. **Version in two places.** `## Version:` in `AddOns/AICompanion/AICompanion.toc` and `local VERSION` in `AICompanion.lua` must match. Bump both on every change to the add-on.
4. **Tooltips stay short.** At most three added lines; advice text at most 48 characters.
5. **Rules stay silent when unsure.** A rule in `AICompanion_Rules.lua` returns nothing unless the snapshot alone proves the advice. Rules are pure functions over the snapshot so they can be run outside the game.
6. **Never snapshot at logout.** Character data is already unloaded at `PLAYER_LOGOUT`. Keep the `worldDataReady` guard.
7. **`ReloadUI()` only directly from the player's own action:** a typed slash command or a click on one of the add-on's buttons. Never from a timer or an event; a timer may only show a reminder that asks the player to reload.
8. **Auction queries** must set the quality filters or they return nothing, run one name at a time, and respect the throttle.
   - **Auctionator** is optional and used only through its public functions (`Auctionator.API.v1`), each call in `pcall`, with the add-on's name as caller. Never read its saved files. Missing functions or errors count as "no Auctionator": the add-on's own check takes over.
9. **Never taint the game's frames.** Add-on frames are children of `UIParent` (or sit on the minimap edge, as minimap buttons do) and are placed by reading a game window's position (`GetRight`, `GetTop`), never anchored to, parented to, or written onto a game window, and nothing hooks the game's bag-opening functions. Touching the bag windows made the game block using items from the bags (issue #15). The stand-in client refuses these patterns, and the add-on records any blocked action in `AICompanionDB.blockedActions`.
10. **Agent-facing documents** (`companion/SKILL.md`, the guides beside it, this file) state rules as rules, with the changelog at the end. Gameplay rules, the working loop and the file formats live only in `companion/SKILL.md`. `CLAUDE_GUIDE.md` and `CODEX_GUIDE.md` point to it and hold only what is specific to that assistant. A test fails if a rule from `SKILL.md` is copied into another file.
11. **Install is one folder.** Only `AddOns/AICompanion` is installed or packaged. `AddOns/AICompanion_Data/` is the template the tests load; on a player's PC `companion/gen_data.py` creates that folder and never replaces the player's data. The data add-on's `## Interface:` follows the installed `AICompanion.toc`, never the game's own version: supporting a new game version is an add-on release (see "Supporting a new Forever version"). `gen_data.py` then updates only that line of the player's data `.toc`. Keep the rest of the `.toc` text in `gen_data.py` identical to the template's (a test checks this). The add-on must work with the data add-on absent.
12. **Automatic updates never spend tokens without cause.** `companion/auto/` starts the AI only when a change should change the advice (`core.changes`, minus `QUIET`) **and** the daily budget allows it. All logic lives in `core.py` and stays OS-neutral; anything OS-specific (scheduling, notifications) goes only in `scheduler_macos.py` or `scheduler_windows.py`. The AI updates the private plan; shared Python code validates and publishes the data add-on. Provider-specific CLI discovery, permissions and result parsing live in `providers.py`. Claude remains the default for existing installs; other providers are explicitly selected. Claude's Python tool allowlist is not a strict filesystem sandbox. Player settings, state and logs live in the per-user folder (`core.home_dir()`), never in the repository or the game folder. `tests/test_auto.py` covers it and GitHub runs it on Windows and macOS.

## Supporting a new Forever version

The supported client interface is set in one place: the `FOREVER_INTERFACE` file at the repository root. `tools/set_interface.py` copies it into every file that states it (both `.toc` files, the stand-in client, `README.md`, this file, `companion/SKILL.md`). A test fails if any of them disagrees. Never edit the number anywhere else.

1. Refresh `tests/forever/api_names.json` from the patched game (rule 1) and fix what the tests then find.
2. Run `python3 tools/set_interface.py <new number>`.
3. Run the tests, then confirm in the real patched game.
4. Bump the add-on version (rule 3) and release. Players' data add-ons follow on the companion's next `gen_data.py` run.

## What needs a game restart

- A new or renamed file, a new folder, or any `.toc` change: full restart.
- An edit to an existing `.lua` file: `/reload`.

## Layout

- `AddOns/AICompanion/AICompanion.lua` — snapshots, window captures (bank, trainer, vendor, flight master, recipes), auction check, tooltips, `/aic` commands.
- `AddOns/AICompanion/AICompanion_Rules.lua` — built-in item advice.
- `AddOns/AICompanion/AICompanion_Panel.lua` — in-game panel and minimap button; reads `AICompanionPlans` from the data add-on.
- `AddOns/AICompanion/Bindings.xml` — the Key Bindings entry for the panel. The client reads it from the folder by itself; it is not listed in the `.toc`.
- `AddOns/AICompanion_Data/` — empty template of the per-player data add-on; on the player's PC it is created and filled by `companion/gen_data.py`.
- `companion/` — the skill (`SKILL.md`: rules, working loop, formats), the per-assistant guides, data generator, dashboard builder and template, example plan. Copying this folder is the whole assistant install.
- `tests/` — stand-in game client, test harness, scenario and rule tests.
- `FOREVER_INTERFACE`, `tools/set_interface.py` — the supported Forever client interface and the script that copies it into every file.
- `companion/auto/` — optional automatic updates with Claude Code or Codex CLI: `aic_auto.py` (commands), `core.py` (change detection, budget, publication, report; OS-neutral), `providers.py` (provider-specific CLI adapters), `scheduler_macos.py` (launch agent), `scheduler_windows.py` (Task Scheduler), double-click installers.

## Checking a change

- Run `python3 -m unittest discover -s tests -v` from the repository root (needs `pip install lupa`). It must pass before every commit. GitHub runs it on every push.
- The tests run the add-on under Lua 5.1 inside a stand-in Forever client (`tests/mock_wow.lua`). They cover login, snapshots (event, periodic, manual, in combat), `/aic save` and reload, the logout guard, the window captures, the auction check (quality filters, throttle, one search at a time, no answer, window closed), tooltips (length, combat, rule and companion advice) and a sweep of every rule message against the 48-character limit. They also fail on any Lua error, stray global, or `ReloadUI()` outside a typed command.
- A behaviour change to the add-on gets a test in `tests/test_addon.py`; a rule change gets one in `tests/test_rules.py`.
- The stand-in client models what the add-on expects of Forever, not the real client. Nothing is verified until it has run in the real game. Say which of the two it is when reporting.

## Open items

- Capture recipe ingredients when a profession window is opened, so rules can say "Craft now". `C_TradeSkillUI.GetRecipeSchematic` exists in Forever.
- Dashboard: use rule advice for items the plan does not cover.
