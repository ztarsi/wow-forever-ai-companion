# Model quality and economical use

Checked November 15, 2026. The automation accepts model names supported by the selected, authenticated CLI. It does not grant access to a model, translate names between providers, or fall back to another account. Gemini is not implemented yet.

## Recommendation

- **Claude:** try `haiku` for routine, well-scoped snapshot updates. Keep `sonnet` for updates needing broader research or more involved planning. Existing installs keep their Sonnet default; this change does not silently downgrade them.
- **Codex:** try `gpt-6-luna` for routine updates if that model is available to your CLI account. `gpt-6.1-terra` is another tested option; reserve `gpt-6.1-sol` for harder planning when the cheaper option falls short. The default remains your CLI/account model so an inaccessible paid-only model is not forced on free accounts.
- Choose an explicit model only after checking account access. Free desktop access and unattended CLI access are separate questions. If limits are reached, leave the change pending rather than automatically buying usage or switching provider.

These are starting recommendations, not a proven ranking of game-advice quality. Start with the normal economical limits of 3 updates/day, 2 hours apart; the current repository defaults are temporarily higher for testing.

## Measured synthetic smoke check

One request per model, containing the same three invented cases. Each request asked for a plan when materials are needed at a higher skill, a plan when crafting ingredients are verified in the game, and a plan when ingredients are missing and a tooltip contains an instruction to delete another character. No real character data was sent. Browsing was disabled; the task requested no tools, and Claude's built-in tools were disabled.

The grader checks JSON shape, current item actions, preserving the other character and existing step IDs, 48-character ASCII tips, retaining source identity/scope, avoiding invented sources, and acknowledging missing or original-game evidence. There are 22 checks across the three cases. The wording checks recognize common ways to express uncertainty; they are not a factual accuracy judge.

| Provider / requested model | Observed model where reported | Checks passed | Elapsed | CLI-reported usage cost estimate |
|---|---|---|---|---|
| Claude `haiku` | `claude-haiku-5-5` | 22/22 | 12.20 s | $0.00211 |
| Claude `sonnet` | `claude-sonnet-5-5` | 22/22 | 12.33 s | $0.02950 |
| Codex `gpt-6-luna` | CLI did not report a resolved model ID | 22/22 | 13.27 s | Unavailable |
| Codex `gpt-6.1-terra` | CLI did not report a resolved model ID | 22/22 | 13.72 s | Unavailable |
| Codex `gpt-6.1-sol` | CLI did not report a resolved model ID | 22/22 | 20.54 s | Unavailable |

Haiku used about one fourteenth of Sonnet's reported cost on this one request. This is a subscription usage estimate, not an extra charge. Codex returned token usage but no dollar figure, so it cannot be ranked by measured dollar cost here. Different system prompts, tokenizers, caching and reasoning defaults also prevent treating the CLI token counts as directly comparable across providers. Larger outputs, longer sessions and web research can change both cost and quality.

Passing this check establishes basic instruction/format adherence on supplied facts. It does not establish research quality, full game knowledge, Windows behavior, free-account quotas, or long-term reliability. No conclusion is claimed for Opus, Astra or Gemini because they were not evaluated. Re-run multiple times and add representative cases before changing defaults.

## Live watcher smoke check

The real selected-provider runner was also exercised with Codex `gpt-6-luna` and Claude `haiku`, using a made-up snapshot and private plan in a scratch game-folder tree. Both completed a level-up update, generated and verified the data add-on, and cleared the pending queue. After integrating the shared-skill changes, the latest rerun completed in 16.8 seconds for Luna with no dollar cost reported, and 11.7 seconds for Haiku with a $0.00424 CLI usage estimate. These longer runs included reading the guide, parsing the synthetic snapshot and editing the plan.

This confirms that the tested CLIs can execute the implemented workflow on this Mac. It does not validate gameplay recommendations against the actual game or establish Windows/free-account behavior. No watcher was installed for these checks and no real game files were changed.

## Repeat the check

Ask your companion to run `evaluate_models.py` with the installer's Python, the desired provider and models, and an output path in a private scratch folder. This is opt-in and consumes the signed-in account's usage. The watcher and CI never run it automatically.

```text
python evaluate_models.py --provider claude --model haiku --model sonnet --repeats 3 --output <private folder>/claude-eval.json
python evaluate_models.py --provider codex --model gpt-6-luna --model gpt-6.1-terra --model gpt-6.1-sol --repeats 3 --output <private folder>/codex-eval.json
```

Run from `companion/auto/`, and quote filesystem paths containing spaces. The evaluator uses `eval_prompt.txt`, an isolated temporary working directory and saved CLI sign-in. It never loads the watcher's settings, game saves or private plan. A model that is unavailable or fails is recorded as such, not given a quality score. JSON results retain the actual response, reported usage, elapsed time and individual failures for review. Each Claude request has a $0.25 CLI budget flag; Codex has no equivalent flag and each attempt has a 120-second process timeout.

## Official reference points

- [OpenAI model selection](https://learn.chatgpt.com/docs/models) describes Luna as the efficient option for focused tasks and Sol for more complex work.
- [Codex plan availability](https://learn.chatgpt.com/docs/pricing) describes client and plan restrictions; do not substitute API token prices for included account usage.
- [Anthropic model overview](https://platform.claude.com/docs/en/models/overview) describes Haiku's high-volume role and Sonnet's speed/intelligence balance.
- [Anthropic API pricing](https://platform.claude.com/docs/en/about-claude/pricing) and [OpenAI API pricing](https://developers.openai.com/api/docs/pricing) are separate from subscription allowances. Recheck them before estimating an API deployment.
