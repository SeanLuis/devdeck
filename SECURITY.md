# Security

DevDeck can stop processes, delete caches and run maintenance commands, so security reports are taken seriously.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository.

Include what you found, how to reproduce it and the version or commit. You should get a reply within a week.

## What is in scope

- Any way to make DevDeck act on a process, file or path the user did not approve, including through text that reaches the AI copilot (prompt injection through process names, command lines, file paths or agent transcripts).
- Leaks of secrets: the API key, remembered environment variables, or unredacted command lines sent to a model.
- Privilege or sandbox issues in how commands are launched.

## How DevDeck limits risk

- System processes, other users' processes and DevDeck itself are never touched.
- Actions proposed by the AI only run after the user approves them, and are validated against the live state first.
- The copilot's CLI engines run with no tools, no MCP servers and no persisted session.
- Data sent to a model is redacted: home paths, tokens, keys and credentials in URLs are masked; environment variables are never sent.
- Secrets are stored in `~/Library/Application Support/DevDeck/` with `600` permissions.
