# Summarization Skills (`ss`)

[中文](README.md) | English

**One copy of truth. Every agent gets a junction to it.**

`ss` collects every AI agent's skill directory on a Windows machine into a single source of truth, then distributes it with directory junctions. Same skill set on all agents, stored exactly once — edit one file, every agent sees it.

## The problem

Five agents × twelve skills = sixty installs, sixty copies, sixty places to edit. `ss` turns that into twelve real folders in one place and one junction per agent.

## How it works

```
%USERPROFILE%\skills\            <- source of truth, only place with real files
├── skills.json                  <- manifest: where each skill came from
├── _rollback\                   <- generated undo scripts
└── <skill-name>\SKILL.md
%USERPROFILE%\.claude\skills\<skill-name>   -> junction into the source
```

A junction needs no administrator rights and is followed transparently by Windows, including by each agent's own skill scanner.

## Verified support

| Agent | Reads from | Status |
| --- | --- | --- |
| Claude Code (terminal) | `~\.claude\skills` | ✅ |
| Codex | `~\.codex\skills` (except `.system`) | ✅ |
| WorkBuddy | `~\.workbuddy\skills` | ✅ visible in its UI |
| DeepSeek Harness | `~\.dsh\skills` (rank 400) / `~\.agents\skills` (rank 500) | ✅ requires a new conversation |
| Doubao | `…workspace\.user_skills` | ✅ |
| Shared root | `~\.agents\skills` | ✅ |
| Claude Desktop | cloud account skills — **does not read local folders** | ❌ junction has no effect |

DeepSeek Harness has no skills panel: skills are injected into each conversation as a catalog (`source.kind = skill-catalog`) at session start, so a conversation opened **before** linking keeps the old set. Start a new conversation, do not just refresh.

## Install

```powershell
git clone https://github.com/xiayuhuan137-sode/summarization-skills.git ~\ss-src
New-Item -ItemType Directory -Force ~\skills | Out-Null
Copy-Item -LiteralPath ~\ss-src\ss -Destination ~\skills\ss -Recurse
pwsh -File ~\skills\ss\scripts\ss.ps1 scan      # read-only inventory, changes nothing
pwsh -File ~\skills\ss\scripts\ss.ps1 link      # create the junctions
```

`ss\agents.json` maps agent key → path template; `%USERPROFILE%` is expanded at runtime. New machine or new agent: edit that one file.

## Commands

| Command | Purpose |
| --- | --- |
| `scan` | read-only inventory of the source and every agent root: real dirs, junctions, dangling links, sizes, frontmatter |
| `doctor` | read-only health report: dangling links, duplicate copies, divergent variants, unmanaged copies, manifest gaps |
| `list` | skill × agent matrix |
| `link` | junction into every existing agent root (`-DryRun`, `-Agent`) |
| `unlink` | remove junctions pointing into the source (`-DryRun`) |
| `add` | download a skill from GitHub into the source, verify every file by git blob SHA, record it in the manifest |
| `migrate` | move real agent copies into the source and replace them with junctions; **dry run unless `-Apply`** |

## Non-negotiable rules

- **Junction or fail.** Never fall back to copying — a copy recreates exactly the duplication this tool exists to remove.
- **`migrate` is dry-run by default.** Write the rollback script before touching anything, and flush it after every single operation.
- **Never auto-merge a content conflict.** Same name, different bytes → keep both, report it, let the human decide.
- **Verify before claiming success.** Re-run `scan` or `doctor` after `link` / `migrate` and confirm files really resolve through the links.

## Limitations

- **Windows only** (PowerShell 7 + directory junctions). macOS/Linux would need symbolic links; the link layer is the only part that must change. Not implemented.
- Claude Desktop uses cloud account skills, so local junctions do not apply.
- DSH snapshots its skill set per session; an already-open conversation will not pick up changes.

## License

MIT
