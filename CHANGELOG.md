# Changelog

## 0.1.6

- Near the limit, Claude Code can switch by itself to the saved account with the most room (the default, at 90%), only suggest it, or do nothing; any account can be left out
- Add account: opens the agent's own login in the browser and saves the new account when it appears, for Claude Code and Codex
- Codex limits are asked to Codex itself, so they follow the whole plan and not only what ran on this Mac
- The 5-hour window says when it runs out at the current pace; old readings are shown as old, and a window that already reset shows no figure
- Command line: `devdeck status`, `top`, `ports` and `agents`, with `--json`
- `devdeck mcp`: a read-only Model Context Protocol server for coding agents
- Your own recipes in `toolkit.json`
- Homebrew cask
- A walkthrough at the top of the README

## 0.1.5

- The account in use is shown at the top of every page, with a menu to switch
- AI agents is grouped into Activity, Accounts and limits, and Usage; agents that were not used this week no longer take a card
- Memory by source shows the five heaviest sources as ordered layers, with what each one uses now
- License: from this version DevDeck is under the PolyForm Noncommercial License 1.0.0; versions up to 0.1.4 remain MIT
- Accounts: DevDeck keeps several Claude Code logins in its own keychain store and switches between them, with the real limits of each one read from its own account. Accounts managed by claude-swap can be imported without logging in again. Codex logins can be saved and switched too, and DevDeck suggests another account when the one in use is close to its limit
- Budgets: a token ceiling for a project, an agent or everything, or a share of an account's limit, with a notice at 80% and 100%
- A notice when an agent finishes a long turn or stops to ask something
- Each open session shows the last step its agent took
- Estimated cost at API list prices, per agent, model and project (`prices.json` adds or overrides prices)
- Agent leftovers: tool servers, headless browsers and commands that an agent started and left running
- "Start everything" brings up a project's containers and every remembered command that is not running
- Work profiles: save what is running and switch to it later; the plan is shown before anything is started or closed
- Battery and thermal state in the sidebar, with rules for low battery and heat

## 0.1.4

- Settings reorganized into sections (General, AI, Island and launcher, Game mode, Notifications, Monitoring, Projects, Updates, Data), one at a time
- History: a summary per minute kept for seven days, with memory and swap over time, who was using memory at any minute, and the moments memory reached its limit
- Leak detection: processes whose memory only grows are flagged, with a recommendation to restart them
- History keeps one point per minute after a relaunch and reads the right days when the clocks change; leak detection waits for two hours and 600 MB of steady growth before flagging anything

## 0.1.3

- Memory and swap: "Free swap" lets you pick what to close, restart or reopen to get swap back, with an estimate for each
- The swap analysis is now the copilot itself, inline: its plan, its answer and every proposal as a card to approve
- Processes say what they are: browser and Electron helpers are named (tab, extension, GPU, network, audio…) and folded by role; long lists come in pages
- DevDeck shows what it spends on AI itself, apart from your agents' usage
- Separate models for the copilot (Sonnet by default) and for automatic analyses (Haiku)
- Less background work: the hidden launcher and game detection no longer run on every sample

## 0.1.2

- Game mode: detects games and recommends it; pauses (never closes) what you choose, silences notices, hides the island, and shows the controller in the menu bar, Dock and app
- Alerts now come with a recommendation and a button to act on it
- New app icon
- Claude Haiku is the default model for the copilot, and automatic analyses always use it

- DevDeck checks for new versions once a day and tells you, with the release notes. Updating is one click: the download is verified to be signed and notarized before it replaces the app. You can skip a version or turn the check off
- Settings → Updates, with "Check now"

## 0.1.1

- The app is now signed with a Developer ID and notarized by Apple, and runs on Apple silicon and Intel
- Real icons for apps and agents, in colour, grey or as symbols
- The copilot section lists every conversation, and conversations are saved from the first moment
- Reopening the launcher returns to the conversation in progress
- Server-closed alerts only for real servers
- Builds with Xcode 16

## 0.1.0

First public release.

- Overview, memory and swap analysis, load by source, ports, projects, caches, tools, rules and alerts
- AI agents panel: live sessions with subagents, accounts and usage limits, tokens for Claude Code, Codex, Devin, OpenCode and Gemini CLI
- Copilot as a turn-based agent with approval cards, conversation history, and Claude Code, Codex or OpenAI API as engine
- Island with System, Agents, Accounts and Copilot boards; always on, only when needed, or off
- Command launcher with a configurable global shortcut
- English, Spanish and Portuguese
