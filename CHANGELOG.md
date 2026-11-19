# Changelog

## 0.1.11

- The limits of the account in use come from Claude Code itself: it hands them to its status line each time it draws it, and DevDeck keeps them on the way and then draws your usual status line. No request to Anthropic, so the menu bar and the automatic switch follow the account in use at once. Settings → AI; can be turned off, and the status line goes back as it was
- The account in use is read every three minutes while the agent works, and every minute and a half only while it climbs near the switch line. Reading it every minute and a half all the time ran into Anthropic's limit of about 30 readings an hour, and the menu bar and the automatic switch were left with an old figure
- After a "too many requests" answer DevDeck waits what the server asks (at least five minutes) and reads more slowly for the next hour; "Update" never asks twice within a minute
- The limits no longer get mixed between accounts. The status line does not say whose figures it shows: a session left open across a switch kept drawing the previous account's 5-hour and 7-day figures under the new account's name. Each reading now goes to the account whose week it is, and two sessions of one account no longer overwrite each other with an older figure
- DevDeck checks with Anthropic whose login each saved token is (once per renewal), as claude-swap does. A saved account that holds another account's login is marked "holds another account's login", shows no figures and is never switched to; a switch also files the login in use under the account it really belongs to
- The login expiry shown is the login's own (`refreshTokenExpiresAt`), not the access token's, and it appears a week ahead for DevDeck's own accounts too; a login past it is marked expired without spending a renewal
- `--accounts-dump --verify` prints, for each saved account, its login expiry and whether its token is its own
- "Update and restart" no longer spins forever: the window says what it is doing (downloading, checking the signature, installing, restarting), a stalled download fails with a message after a while, and the new version opens only once the old one has really quit (before, if quitting took more than a second, the old version stayed open and the update seemed to do nothing)
- Sidebar: the update card has room above it, its text no longer wraps, and in a short window the sections scroll instead of pushing the title and the bottom panel out of sight

## 0.1.10

- The menu bar panel shows the agent account in use with its 5-hour and 7-day windows, and a selector to change to another saved account
- Settings → Menu bar: choose what shows beside the icon (memory, agent account) and which sections the panel has
- Closing DevDeck's window or pressing ⌘Q leaves it in the menu bar without a Dock icon; "Quit DevDeck" in the panel ends it. Can be turned off
- Saved Claude Code logins no longer expire after switching: DevDeck never renews the login Claude Code holds (even while its config is being rewritten), renews the incoming account before switching so a running session cannot overwrite it, and treats a login as expired only when Anthropic says so

## 0.1.9

- Gradle and Maven projects: `./gradlew bootRun` is shown and remembered as typed, with the port its app opens; Gradle's shared daemon is no longer taken for a project's server
- Start does not collide: if the command already runs it says so, and if something else holds the port it offers to close it first
- Remembered commands keep only real servers, the newest one per port; agents' one-off commands (git, gh, tail…) are no longer kept
- Automatic account switching picks the saved account with the most room in its 5-hour window; per-model quotas no longer block it, an account that cannot be used is never chosen, and a switch that fails is retried a minute later instead of being reported as done
- Automatic account switching keeps working in low-power game mode, and an account whose last read failed for a moment keeps its recent figures
- Project infrastructure: a `devdeck.json` at the project's root declares its services (command, folder, port, health address) and its compose file. The project page shows which ones run and answer, and brings everything up or down with one button. DevDeck can write the file from the commands it remembers, without their environment
- Sessions: every past Claude Code and Codex session on this Mac, with search over what was said and a button that opens it again in Terminal, in its own folder
- An account per project: choose which saved Claude Code account a folder belongs to; DevDeck puts it in place before opening the agent there and tells when a session starts under another one
- Each project shows its branches and worktrees (which one an agent works in, uncommitted changes, worktrees nobody uses any more with their size and a way to remove them) and the agent sessions that worked there
- Day summary in Usage: per project, what the agents were asked, tokens, estimated cost and commits; copies as text
- Optional Claude Code hooks, off by default: DevDeck hears at once that a session asks for a permission or finishes
- Agents can ask, through `devdeck mcp`, to free a port or restart a server; each request needs your approval in DevDeck
- "Tell me when it resets" on any account window; it arms itself when the account in use runs out
- Command line: `devdeck sessions`, `devdeck branches` and `devdeck today`

## 0.1.8

- A single Claude Code login shows its limits in the menu bar and in the app without saving it as an account first
- The menu bar shows the 5-hour window and the week of the account in use, and marks it when either is close to the limit
- The account in use is read again within a minute and a half while the agent works, and right after a window resets
- The menu bar panel says when each window resets and how old the reading is, with a button to read it again

## 0.1.7

- The menu bar shows how far the agent account in use has gone in its 5-hour window, next to memory
- The menu bar panel lists your Claude Code accounts with their limits and switches between them
- The Advanced section of AI settings opens from its title

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
