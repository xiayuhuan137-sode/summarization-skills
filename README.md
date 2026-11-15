# Summarization Skills (`ss`)

中文 | [English](README.en.md)

**一份实体，全网共用。** 把本机所有 AI agent 的 skill 目录收拢到一个真源，再用 Windows 目录联接（junction）分发出去——同一批 skill 只存一份，改动一处，所有 agent 同时生效。

**One copy of truth. Every agent gets a junction to it.** `ss` collects every AI agent's skill directory into a single source of truth, then distributes it with Windows directory junctions — the same skill set stored exactly once, and one edit visible to every agent.

---

## 它解决什么问题 / The problem

装了 5 个 agent、想要 12 个 skill，就要装 60 遍；改一处得改 60 处；想删一个，还得挨个找。`ss` 把这件事变成：**12 个 skill 在 `~/skills` 里只有一份，每家 agent 目录里只有一条链接。**

Five agents × twelve skills means sixty installs, sixty copies, sixty places to edit. `ss` turns that into twelve real folders in one place and one junction per agent.

---

## 原理 / How it works

```
%USERPROFILE%\skills\            <- 真源，唯一放真实文件的地方
├── skills.json                  <- 台账：每个 skill 从哪来、改过什么
├── _rollback\                   <- 自动生成的回退脚本
└── <skill-name>\SKILL.md
%USERPROFILE%\.claude\skills\<skill-name>   -> junction 指向真源
```

junction 不需要管理员权限，Windows 原生透明跟随，进程读它就是读真文件。

A junction needs no administrator rights and is followed transparently by Windows, so any process reading it is reading the real file.

---

## 支持哪些 agent（实测）/ Verified support

| Agent | 读取位置 / Reads from | 状态 / Status |
| --- | --- | --- |
| Claude Code（终端） | `~\.claude\skills` | ✅ |
| Codex | `~\.codex\skills`（`.system` 除外） | ✅ |
| WorkBuddy | `~\.workbuddy\skills` | ✅ 界面可见 / visible in its UI |
| DeepSeek Harness | `~\.dsh\skills`（rank 400）／`~\.agents\skills`（rank 500） | ✅ 需新开会话 / requires a new conversation |
| 豆包 / Doubao | `…workspace\.user_skills` | ✅ |
| 共享根 / shared root | `~\.agents\skills` | ✅ |
| Claude 桌面版 / Claude Desktop | 云端账号技能，**不读本地目录** / cloud account skills, **ignores local folders** | ❌ 链接无效 / junction has no effect |

DeepSeek Harness 没有"技能面板"：技能是每个会话启动时注入给模型的目录（`source.kind = skill-catalog`），所以**链接后必须新开一个会话**；只是刷新页面或重启应用都不行。

DeepSeek Harness has no skills panel at all: skills are injected into each conversation as a catalog at session start, so a conversation opened **before** linking keeps the old set. Start a new conversation — refreshing or restarting the app is not enough.

---

## 安装 / Install

```powershell
git clone https://github.com/xiayuhuan137-sode/summarization-skills.git ~\ss-src
New-Item -ItemType Directory -Force ~\skills | Out-Null
Copy-Item -LiteralPath ~\ss-src\ss -Destination ~\skills\ss -Recurse
pwsh -File ~\skills\ss\scripts\ss.ps1 scan      # 先只读盘点，什么都不改 / read-only, changes nothing
pwsh -File ~\skills\ss\scripts\ss.ps1 link      # 再铺链接 / create the junctions
```

`ss\agents.json` 是 agent key → 路径模板的映射，`%USERPROFILE%` 运行时展开。换机器、加 agent，只改这一张表。

`ss\agents.json` maps agent key → path template; `%USERPROFILE%` is expanded at runtime. A new machine or a new agent is one line in that file.

---

## 命令 / Commands

| 命令 / Command | 用途 / Purpose |
| --- | --- |
| `scan` | 只读盘点：真源 + 各 agent 根，实体/链接/悬空/体积/前置元数据 — read-only inventory of the source and every agent root |
| `doctor` | 只读体检：悬空链接、重复副本、变体分歧、未纳管副本、manifest 缺口 — read-only health report |
| `list` | 技能 × agent 矩阵 — skill × agent matrix |
| `link` | 向所有存在的 agent 根铺 junction（`-DryRun`、`-Agent`）— junction into every existing agent root |
| `unlink` | 只摘掉指向真源的链接（`-DryRun`）— remove junctions pointing into the source |
| `add` | 从 GitHub 下 skill 进真源，逐文件校验 git blob SHA，写台账 — download from GitHub, verify every file by git blob SHA, record in the manifest |
| `migrate` | 把各家实体副本收进真源并换成链接；**默认 dry-run，`-Apply` 才动手** — move real copies in, replace with junctions; **dry run unless `-Apply`** |

---

## 不可协商的规则 / Non-negotiable rules

- **junction 或者失败 / junction or fail.** 绝不降级成复制——复制会把这个工具要消灭的重复重新造出来。Never fall back to copying: a copy recreates exactly the duplication this tool exists to remove.
- **`migrate` 默认只是预演 / dry-run by default.** 改动前先写回退脚本，并且每做完一步就刷盘。Write the rollback script before touching anything, and flush it after every single operation.
- **内容冲突绝不自动合并 / never auto-merge a conflict.** 同名不同字节 → 两份都留着，报给人决定。Same name, different bytes → keep both, report it, let the human decide.
- **先复验再宣布成功 / verify before claiming success.** 跑完 `link` / `migrate` 要再 `scan` 或 `doctor` 确认文件真能穿透链接。Re-run `scan` or `doctor` and confirm files really resolve through the links.

---

## 限制 / Limitations

- **只支持 Windows / Windows only**（PowerShell 7 + 目录联接）。macOS/Linux 需要换成 symbolic link，链接层是唯一要改的地方，未实现。macOS/Linux would need symbolic links; the link layer is the only part that must change. Not implemented.
- **Claude 桌面版走云端账号技能**，本地链接对它无效 / Claude Desktop uses cloud account skills, so local junctions do not apply.
- **DSH 的技能集是会话级快照**，旧会话不会热更新 / DSH snapshots its skill set per session; an open conversation will not pick up changes.

---

## License

MIT
