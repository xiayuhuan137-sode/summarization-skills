---
name: ss
description: Summarization Skills（skill 汇总中枢）：把所有 agent（豆包、Claude Code、Codex、WorkBuddy、DeepSeek Harness、Cursor…）的 skill 目录收拢到单一真源并用目录联接分发，让同一批 skill 只存一份。当用户提到 skills 装重了、多个 agent 各装一遍、skill 目录太多、想统一管理/体检/迁移 skill、或要查某个 skill 有没有被某个 agent 看到时使用。
---

# Summarization Skills

One folder is the truth, every agent gets a junction to it. Junction (not symlink, not copy) is the whole mechanism — it needs no admin rights, and Windows follows it transparently, including Doubao's own skill scanner.

## Layout

```
%USERPROFILE%\skills\            <- HUB, the only place real files live
├── skills.json                  <- manifest: where each skill came from
├── _rollback\                   <- generated undo scripts
└── <skill-name>\SKILL.md
%USERPROFILE%\.claude\skills\<skill-name>   -> junction to hub
```

Paths are not hardcoded in the script: `agents.json` (next to `SKILL.md`) maps agent key → path template, and `%USERPROFILE%` etc. are expanded at runtime. To support a new agent, add one line there.

| Key | Root | Notes |
| --- | --- | --- |
| `doubao-user` | `…workspace\.user_skills` | Doubao reads this |
| `doubao-system` | `…workspace\.skills` | **readonly** — app-shipped skills |
| `claude-code` | `~\.claude\skills` | terminal Claude Code |
| `agents-shared` | `~\.agents\skills` | shared root; holds 3 Codex-adapted variants |
| `codex` | `~\.codex\skills` | user skills sit next to `.system` |
| `workbuddy` | `~\.workbuddy\skills` | has a `skill-cloud-sync` sibling — may push local copies to its cloud, unverified |
| `dsh` | `~\.dsh\skills` | DeepSeek Harness user root (rank 400) |
| `dsh-workspace` | `<DSH workspace>\.dsh\skills` | project root (rank 100), only for that one workspace |
| `dsh-workspace-agents` | `<DSH workspace>\.agents\skills` | project root (rank 200) |
| `cursor` / `gemini` | `~\.cursor\skills`, `~\.gemini\skills` | skipped when the root does not exist |

## What each app actually reads (verified on this machine)

- **Claude Code (terminal)** — scans `~\.claude\skills` at start. Junction is followed. Nothing else needed.
- **Codex** — `~\.codex\skills`; `.system` inside it is its own bundled set and must be left alone.
- **WorkBuddy** — `~\.workbuddy\skills`; its UI (专家·技能) lists every entry there, junctions included.
- **DeepSeek Harness (DSH)** — has **no skills panel at all**; skills are injected into each conversation as a catalog message (`source.kind = skill-catalog`) and loaded by the model through a `skill` tool. Root priority, highest first: `<project>\.dsh\skills`(100) → `<project>\.agents\skills`(200) → `customSkillDirs`(300) → `~\.dsh\skills`(400) → `~\.agents\skills`(500) → bundled. `dshHome` = `$DSH_HOME` or `~\.dsh`. **The skill set is a per-session snapshot**: linking while a conversation is open does not update it — the user must start a **new conversation**, not restart or refresh.
- **Claude Desktop (claude.ai shell + Cowork VM)** — reads account/cloud skills, **not** local directories. A junction here has no effect; skills must be added inside that app. Do not promise otherwise.

## Engine

Run every command through the script; do not re-implement the logic by hand.

```powershell
pwsh -File "<this skill>\scripts\ss.ps1" <command> [options]
```

| Command | Purpose | Notes |
| --- | --- | --- |
| `scan` | read-only inventory of hub + every agent root: real dirs, junctions, dangling links, sizes, frontmatter status | safe anytime |
| `doctor` | read-only health report: dangling links, duplicate copies, divergent variants, unmanaged copies, missing/blank frontmatter, hub skills linked nowhere, manifest gaps | safe anytime |
| `list` | hub skills × agent matrix (`link` / `!real` / `-`) | safe anytime |
| `link` | create junctions from hub into every existing agent root | `-DryRun`, `-Agent <key>` |
| `unlink` | remove junctions that point into the hub | `-DryRun` |
| `add` | download a skill from GitHub into the hub, verify every file by git blob SHA, record it in `skills.json` | `-Repo owner/repo -Skill name [-SkillPath p] [-Ref main] [-Force]`; honours `GITHUB_TOKEN` |
| `migrate` | move real agent copies into the hub, replace them with junctions | **dry run by default**; `-Apply` to execute |

`skills.json` is a manifest, not decoration: `origin: github` means the upstream repo/path was actually checked and every file's git blob SHA matched; `local-adapted` means the file differs from upstream and `note` says exactly what was changed.

## Non-negotiable rules

- **Junction or fail.** Never fall back to copying. A copy silently recreates the duplication this skill exists to remove; if linking fails, stop and report the error.
- **`migrate` is dry-run unless `-Apply`.** Show the plan first, then write a rollback script to `_rollback\migrate-<stamp>.ps1` before touching anything, and flush it after **each** operation so a crash still leaves an undo path.
- **Never auto-resolve a content conflict.** Same name, different bytes → leave both, report it, let the user decide. Real case on this machine: `~\.agents\skills` holds a Codex-adapted variant of three skills (canvas-design, frontend-design, web-artifacts-builder) that differs from the hub copy by a single word, so they were deliberately not deduped. `doctor` reports these as INFO `divergent-variant`, never as errors.
- **`readonly_agents` are read-only.** Doubao's `.skills` (system skills that ship with the app) is reported, never linked or moved — an app update would overwrite it.
- **`disabled_agents` are skipped.** A directory that merely exists is not proof the agent is installed. `codex` was disabled until `~\.codex\skills\.system` proved it is live; the list is currently empty, and re-disable before linking anything you have not confirmed in use.
- **User roots before project roots.** For DSH, linking the two workspace-level roots is optional noise; the user root (`~\.dsh\skills`) already covers every workspace.
- **Verify before claiming success.** After `link`/`migrate`, re-run `scan` or `doctor` and confirm files actually resolve through the links. A skill list refresh is not proof — for DSH the only real proof is a **new session** whose catalog lists the names.
- **Never hand-edit `skills.json` with unverified facts.** Use `local-adapted` or `local` and say in `note` exactly what differs.

## Moving the hub

Every junction stores an absolute target, so relocating the hub means unlink → move → update `hub` in `agents.json` → link again. Never move the hub while links exist and leave them dangling.

## Platform

Windows only, verified on PowerShell 7 with directory junctions. macOS/Linux would need symlinks (`New-Item -ItemType SymbolicLink`); the link layer inside `Invoke-Link`, `Invoke-Unlink` and `Invoke-Migrate` is the only part that must change. Not implemented — do not claim it works.
