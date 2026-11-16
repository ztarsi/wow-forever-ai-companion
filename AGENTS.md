# Instructions for all AI agents

This is a shared entry point for every agent working with this repository. The common rules below apply to all agents. Provider-specific sections apply only to the named provider; they do not change another provider's workflow or instructions.

## Common rules — all agents

- Establish whether the user wants repository development or gameplay assistance. If the task is unclear, clarify before writing files.
- For repository development, the existing technical conventions, Forever API constraints, architecture and required checks are recorded in [CLAUDE.md](CLAUDE.md). Follow those repository conventions; Claude-specific tools or setup instructions apply only to Claude.
- For gameplay assistance, follow [companion/SKILL.md](companion/SKILL.md): the rules, working loop and file formats every assistant shares. Your provider's guide below adds only what is specific to it. Do not change add-on source while helping a player.
- Keep character/account data, snapshots, generated dashboards and private plans outside this repository. The checked-in data add-on stays an empty test template.
- Automatic updates share `companion/auto/core.py` and the OS schedulers. Keep provider-specific discovery, commands, permissions and result parsing in `companion/auto/providers.py`; select a provider explicitly and never silently fall back to another account.
- Preserve each provider's guide and workflow. Shared gameplay rules go in `companion/SKILL.md` only, never copied into a provider guide; provider-specific setup goes in that provider's guide without changing another provider's.
- Run `python3 -m unittest discover -s tests -v` (requires `lupa`) before every commit, including documentation changes. Report stand-in-client checks separately from real-game validation.

## Claude only

- Follow [CLAUDE.md](CLAUDE.md) for Claude's repository instructions.
- For gameplay assistance, follow [companion/SKILL.md](companion/SKILL.md) and the Claude setup in [companion/CLAUDE_GUIDE.md](companion/CLAUDE_GUIDE.md).

## Codex / ChatGPT only

- For repository development, use the common repository conventions above and the tools available in your Codex session.
- For gameplay assistance, follow [companion/SKILL.md](companion/SKILL.md) and [companion/CODEX_GUIDE.md](companion/CODEX_GUIDE.md). The guide covers local Codex and advice-only ChatGPT workflows.
- Codex/ChatGPT-specific permissions, setup and prompts in that guide apply only to Codex/ChatGPT.

## Gemini only

- Gemini-specific setup and companion guidance are coming soon; see the Gemini placeholder in [README.md](README.md#gemini).
- For repository development, follow the common repository conventions above. Do not assume the Codex/ChatGPT setup applies to Gemini or claim that a Gemini companion workflow has been verified.

## Other AI agents

- Follow the common rules and `companion/SKILL.md`, plus your provider's guide when one is available.
- If no provider guide exists, establish the available tools and required gameplay/file-format context before writing advice. Do not automatically adopt another provider's setup or claim support that has not been verified.
