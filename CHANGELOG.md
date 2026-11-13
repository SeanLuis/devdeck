# Changelog

## 0.1.4

- Settings reorganized into sections (General, AI, Island and launcher, Game mode, Notifications, Monitoring, Projects, Updates, Data), one at a time
- History: a summary per minute kept for seven days, with memory and swap over time, who was using memory at any minute, and the moments memory reached its limit
- Leak detection: processes whose memory only grows are flagged, with a recommendation to restart them

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
