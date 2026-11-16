<p align="center"><img src="media/logo-400.png" width="160" alt="AI Companion logo: an open book under a guiding spark"></p>

# AI Companion for World of Warcraft: Forever

An add-on that saves a snapshot of your character (gear, bags, quests, professions, location, auction prices) to a file on your PC, so an AI assistant can act as your playing companion: what to do next, what to do with each item, what to buy. The advice then shows up in the game, in item tooltips.

It is built for **WoW: Forever** only (client interface 16001). It is not tested on Classic or retail.

> Early version, shared between friends. Expect rough edges.

## What you get

| | Add-on alone | Add-on + your own AI companion |
|---|---|---|
| Character snapshots saved to disk | Yes | Yes |
| Auction price check, with prices in item tooltips | Yes | Yes |
| Rule-based item advice in tooltips (sell, keep, bank, mail to another character, equip) | Yes | Yes |
| Advice specific to you: quests, recipes, vendors, upgrades, "craft this now" | No | Yes |
| A dashboard page for all your characters | No | Yes |
| In-game panel with your plan, steps that tick themselves as you play | Items tab only | Yes |

Nothing is sent anywhere by the add-on. The game does not let add-ons use the network. Your snapshots stay on your PC until you share them with an AI assistant. Data you share is processed by your chosen AI service. Keep snapshots and personal plans outside this public repository.

## Install

1. Close the game.
2. Download this repository (Code, then Download ZIP) and unzip it.
3. Find the `_forever_` folder inside your game folder. On Windows it is usually `C:\Program Files (x86)\World of Warcraft\_forever_`.
4. Copy the `AICompanion` folder from inside `AddOns` into `_forever_\Interface\AddOns`. That's the only folder you install.
5. Start the game. On the character screen, open AddOns and check that "AI Companion" is ticked.
6. Log in and type `/aic save`. The screen reloads for a second. That writes your first snapshot.

If you use an AI assistant with local file and command access, it creates a second folder, `AICompanion_Data`, the first time it writes advice for you. That folder holds your own advice, shopping lists and plan. Restart the game once when your companion asks, and tick "AI Companion Data" too.

When you update later, replace only the `AICompanion` folder. Never replace or delete `AICompanion_Data`.

## Use it with an AI companion

Choose the AI assistant you prefer. The add-on saves the same snapshots and reads the same advice files regardless of provider; it needs no provider setting or API key. Claude and Codex are two options, and other assistants can use the same workflow if they have the required tools.

For advice in tooltips, the in-game plan panel and a dashboard, your assistant needs local file and command access on the game computer. It reads your saved snapshots, researches Forever sources, and uses the tools in `companion/` to write your private plan and data add-on. An assistant without local tools can give advice in chat from a summary you paste with `/aic copy`.

The table above describes the features available with a companion that has local tools. Give your assistant the skill first, then use the setup section for your chosen assistant below.

### Give your assistant the skill

Everything your assistant needs is in the `companion` folder. `companion/SKILL.md` holds the rules, the steps of each session and the file formats, and the tools it uses sit beside it. Copying that folder is the whole install.

**If your assistant supports skills** (it can load a `SKILL.md` on its own):

1. Make a copy of the `companion` folder and name the copy `wow-forever-companion`.
2. Add it as a skill:
   - **Claude desktop app:** zip the `wow-forever-companion` folder, then add the zip under Settings, Capabilities, Skills.
   - **Claude Code:** put the folder in the `.claude/skills` folder inside your user folder.
   - **Other assistants:** add it wherever your assistant's help says skills go.
3. Start a chat and mention the game, for example *"refresh my WoW Forever companion"*. The assistant loads the skill by itself.

**If your assistant does not support skills:** attach `companion/SKILL.md` to the chat (or add it as a project file) and say *"Be my WoW Forever companion. Follow the attached SKILL.md."*

When you download a new version of this kit, replace your copy of the folder the same way.

### Claude

You need a Claude subscription and the Claude desktop app on the same computer as the game.

1. Add the skill (above), or attach `companion/SKILL.md` to a new chat in the Claude desktop app.
2. Say: *"Be my WoW Forever companion. My game folder is `<path to your _forever_ folder>`."*
3. Approve the folder access Claude asks for.

Claude reads your snapshot, researches Forever sources, and writes its advice into `AICompanion_Data`. Type `/reload` in the game to see it.

**Optional: automatic updates with Claude.** With Claude Code installed (Pro or Max plan), your advice can update itself after you play, within a daily limit you set. Double-click the standard installer for your system in `companion/auto/`. See [automatic updates](companion/auto/README.md#claude).

### Codex / ChatGPT

#### Codex on the game computer

Use a local Codex app, CLI or IDE session with file and command tools. See [OpenAI's Codex documentation](https://learn.chatgpt.com/docs/learn/best-practices) for setup and access options.

1. Open this repository folder as your Codex project or working directory. Codex reads the root `AGENTS.md`.
2. Start a chat and say:
   *"Be my WoW Forever companion. Read AGENTS.md, companion/SKILL.md and companion/CODEX_GUIDE.md. My game folder is `<path to your _forever_ folder>`. Use `<private folder outside this repository>` for my persistent plans.json. Read my latest snapshots, preserve any existing plans, and write updated advice for the game."*
3. Grant the folder permissions Codex requests. It handles Python setup, snapshot parsing and generation, then writes advice into `AICompanion_Data`. If the data add-on does not exist, it creates it.
4. Type `/reload` when asked, or fully restart and enable "AI Companion Data" when the data add-on is first created or its `.toc` changes.

In-game advice requires local file access on the game computer. A remote Codex checkout does not have your local game files. If local tools are unavailable, use the chat workflow below.

**Optional: automatic updates with Codex.** With a signed-in Codex CLI and an existing private plan, double-click `Install-Codex-Windows.cmd` or `Install-Codex-Mac.command` in `companion/auto/`. It uses the shared watcher and explicitly selects Codex. Account/model access and usage limits apply; ordinary ChatGPT chat cannot run the watcher. See [Codex automation setup](companion/auto/README.md#codex--chatgpt).

#### ChatGPT chat / Projects (advice in chat)

1. Attach `companion/SKILL.md` and `companion/CODEX_GUIDE.md` to a chat, or add them as Project files and instruct ChatGPT to follow them.
2. In the game, type `/aic save`, then `/aic copy`. Paste the summary into chat.
3. Say: *"Be my WoW Forever companion. Follow the attached guides in advice-only mode. Here is my saved character summary. Tell me what to do next, label sources that are unconfirmed for Forever, and tell me what information is missing."*

This gives you advice in chat. Updating tooltips and the in-game panel requires a local assistant with file access. Repeat the save-and-paste step when you want updated advice. [A ChatGPT Project alone does not grant access to a folder on your PC.](https://learn.chatgpt.com/docs/projects)

### Gemini

Setup guide coming soon. Gemini-specific instructions have not been added or verified yet.

### Other AI assistants

Use an assistant with local file access and command execution for the full workflow, or paste `/aic copy` output for advice in chat. Give it the skill (above): `companion/SKILL.md` holds the rules and the snapshot and plan formats. Ask your assistant to follow the same Forever source checks, keep SavedVariables read-only, and preserve your private plans. Provider-specific setup may differ.

### Switching between assistants

Keep your private `plans.json` in one persistent folder outside this repository, and tell the new assistant where it is. Have it read that file and a fresh snapshot before updating advice, preserving all characters and step IDs. Use one assistant at a time. Keep your installed `AICompanion_Data` folder when switching.

## Commands

| Command | What it does |
|---|---|
| `/aic save` | Take a snapshot and reload so it is written to disk. Do this before asking for advice. |
| `/aic ask <question>` | Leave a question for your companion with the next snapshot. |
| `/aic ah` | At an auctioneer: check prices for your bags, bank and shopping list. If you use Auctionator, its prices are used instead and this checks only what Auctionator hasn't seen lately. |
| `/aic ah age <days>` | With Auctionator: how many days its prices count as fresh (default 5). Older than that, the "check prices" button comes back. |
| `/aic sort` | Group your bags by what to do with each item: sell, auction, mail, bank, use, craft, quest, keep. |
| `/aic feedback` | Report a problem or share an idea, in a small window. Also the Feedback button on the panel. Your companion files it on GitHub after your next `/aic save`. `/aic bug <text>` and `/aic idea <text>` do it in one line. |
| `/aic panel` | Open your companion panel: this character's plan, inside the game. Also the book button on the minimap (drag it to move it). |
| `/aic reminder on` / `off` | After `/aic save`, remind me when new advice may be ready, with a "Load new advice" button in the panel. On automatically if you use automatic updates. |
| Key binding | Choose a key for the panel in the game's Key Bindings screen: under AddOns, the line "AI Companion: open or close the panel". |
| `/aic copy` | Show a text summary you can copy and paste. |
| `/aic help` | All commands. |

Logging out also saves a snapshot. Log in to each character once. Opening your bank, a trainer, a vendor, a flight master or a profession window lets the add-on record those too.

## Item tooltips

```
AI Companion: Put in bank                     Nov 14
For Leatherworking 55+.
Auction 7c (2653 listed, 34m ago)          vendor 1c
```

- A date on the right means the advice came from your companion.
- `rule` on the right means the add-on worked it out itself. Rules stay silent when they cannot be sure.
- The auction line appears once you have run a price check.

## Good to know

- WoW: Forever is new. Much of what is written online is about older versions of the game. The companion skill tells your assistant to say so whenever its source is not about Forever. When the game and the advice disagree, the game is right.
- The built-in rules know item categories, not recipes. They will not tell you what to craft.
- The add-on writes its file only on `/reload` or logout. Advice is only as fresh as your last save.
- If you use **Auctionator**, AI Companion reads its prices, so you don't need the "check prices" button. The button only appears when Auctionator's prices are older than 5 days, or Auctionator isn't installed.

## Repository layout

| Path | What |
|---|---|
| `AddOns/AICompanion/` | The add-on: `AICompanion.lua` (snapshots, auction check, tooltips) and `AICompanion_Rules.lua` (built-in advice rules). |
| `AddOns/AICompanion_Data/` | Empty template of the data add-on, used by the tests. Not installed; your companion creates your own copy. |
| `companion/SKILL.md` | The companion skill: rules, the steps of each session, and the file formats, for every assistant. |
| `companion/CLAUDE_GUIDE.md` | Claude-only setup. Points to `SKILL.md`. |
| `AGENTS.md` | Shared entry point for all agents, with common rules and separate provider-specific sections. |
| `companion/CODEX_GUIDE.md` | Optional Codex / ChatGPT setup and starting prompts. Points to `SKILL.md`. |
| `companion/` | Tools the assistant uses: `gen_data.py` (writes the data add-on from a plan file), `build.py` and `template.html` (dashboard), `plans.example.json` (plan file format). |
| `companion/auto/` | Optional automatic updates with Claude Code or Codex CLI: shared checking/publishing, separate provider adapters and Windows/macOS schedulers. |
| `media/` | The logo: `logo.svg` (source), PNGs at 400, 512 and 1024 pixels (400 for CurseForge), and `social-preview.png` (1280 × 640) for GitHub's link preview. Not installed. |
| `FOREVER_INTERFACE` | The game version the add-on supports, set in this one place. `tools/set_interface.py` copies it into the other files. |
| `tests/` | Automated checks: the add-on run inside a stand-in game client. Run on every change. |

## License

MIT. See `LICENSE`.

World of Warcraft is a trademark of Blizzard Entertainment. This project is not affiliated with or endorsed by Blizzard.
