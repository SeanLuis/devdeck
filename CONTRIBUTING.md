# Contributing to DevDeck

Thanks for wanting to help. DevDeck is a small native macOS app with no dependencies, so getting started takes a couple of minutes.

## Setup

```bash
git clone https://github.com/SeanLuis/devdeck.git
cd devdeck
swift build
swift test
```

You need macOS 14 or later and Xcode 16 or later. To run your build as a real app (menu bar, island, notifications):

```bash
./scripts/bundle.sh && open ~/Applications/DevDeck.app
```

## Checking your change

You rarely need to click through the app. These commands cover most of it:

```bash
.build/debug/DevDeck --dump                                  # what the classifier sees on your Mac
.build/debug/DevDeck --snapshot out --demo                   # every screen as PNG, with made-up data
.build/debug/DevDeck --snapshot out --demo --only agents --height 2000 --lang en --light
.build/debug/DevDeck --usage-dump                            # agent tokens, sessions and accounts
```

`--demo` renders a fictional machine. Use it for any screenshot you attach to an issue or pull request, so nothing from your own Mac (project names, e-mails, paths) ends up public.

## Where things live

- `Sources/DevDeckCore` has no UI and is covered by tests: process scanning, classification, ports, caches, rules, agent usage, AI clients. Logic goes here.
- `Sources/DevDeck` is the SwiftUI app.
- `Tests/DevDeckCoreTests` uses Swift Testing.

## Ground rules

- **Safety first.** Never touch system processes. Anything that kills, deletes or restarts must be validated against the live snapshot, and anything the AI proposes must go through an approval card.
- **Keep it light.** The app should stay around 100 MB of memory and near-idle CPU. Read files incrementally; do not load transcripts into memory.
- **Sober design.** Neutral colours; colour only carries meaning (amber, red, green). Native macOS controls. No emojis in the interface.
- **No dependencies** unless there is a very good reason.
- **Privacy.** Nothing leaves the Mac except what the user sends to the copilot, and that is redacted.

## Strings and translations

The interface is written in Spanish and translated to English and Portuguese.

1. Write the text in Spanish inside `L("…")`. Use `%@` placeholders and pass strings: `L("Cerrar %@", name)`.
2. Add the English and Portuguese versions to `Sources/DevDeckCore/L10n+English.swift` and `L10n+Portuguese.swift`, keyed by the Spanish text.
3. `swift test` fails if a string has no translation or a translation changes the placeholders.

Do not put `L()` in a `static let`: it would freeze the language. Text sent to the AI model as instructions is not translated.

Adding a language means adding a case to `AppLanguage` and one more table.

## Adding support for another AI agent

1. Teach `Classifier.agentName` to recognize its processes.
2. Add it to `AgentUsageScanner.known`.
3. If it logs token usage locally, add a reader: JSONL transcripts go next to the Claude Code and Codex parsers in `AgentUsage.swift`; databases and JSON files go in `AgentUsageExternal.swift`. Readers must be incremental and read-only.

## Pull requests

- One change per pull request, with a short description of what and why.
- Add or update tests for logic in `DevDeckCore`.
- Run `swift test` before pushing.
- For interface changes, attach `--demo` screenshots.

## Reporting bugs

Open an issue with your macOS version, what you expected and what happened. The output of `--dump` helps a lot for attribution bugs, but read it first and remove anything private.

Security issues: see [SECURITY.md](SECURITY.md).
