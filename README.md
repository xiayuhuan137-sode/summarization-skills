# Summarization Skills (`ss`)

中文 | [English](README.en.md)

**一份实体，全网共用。** 把本机所有 AI agent 的 skill 目录收拢到一个真源，再用 Windows 目录联接（junction）分发出去——同一批 skill 只存一份，改动一处，所有 agent 同时生效。

One copy of truth. Every agent gets a junction to it. Junction, not symlink, not copy.

## 它解决什么问题

装了 5 个 agent、想要 12 个 skill，就要装 60 遍；改一处得改 60 处；哪天想删一个，还得挨个找。`ss` 把这件事变成：**12 个 skill 在 `~/skills` 里只有一份，每家 agent 目录里只有一条链接。**

## 原理

```
%USERPROFILE%\skills\            <- 真源，唯一放真实文件的地方
├── skills.json                  <- 台账：每个 skill 从哪来、改过什么
├── _rollback\                   <- 自动生成的回退脚本
└── <skill-name>\SKILL.md
%USERPROFILE%\.claude\skills\<skill-name>   -> junction 指向真源
```

junction 不需要管理员权限，Windows 原生透明跟随，进程读它就是读真文件。

## 支持哪些 agent（实测）

| Agent | 读取位置 | 状态 |
| --- | --- | --- |
| Claude Code（终端） | `~\.claude\skills` | ✅ |
| Codex | `~\.codex\skills`（`.system` 除外） | ✅ |
| WorkBuddy | `~\.workbuddy\skills` | ✅ 界面可见 |
| DeepSeek Harness | `~\.dsh\skills`（user，rank 400）／`~\.agents\skills`（rank 500） | ✅ 需新开会话 |
| 豆包 | `…workspace\.user_skills` | ✅ |
| 共享根 | `~\.agents\skills` | ✅ |
| Claude 桌面版 | 云端账号技能，**不读本地目录** | ❌ 链接无效 |

DeepSeek Harness 没有"技能面板"：技能是每个会话启动时注入给模型的目录（`source.kind = skill-catalog`），**链接后必须新开一个会话**才生效。

## 安装

```powershell
git clone https://github.com/xiayuhuan137-sode/summarization-skills.git ~\ss-src
New-Item -ItemType Directory -Force ~\skills | Out-Null
Copy-Item -LiteralPath ~\ss-src\ss -Destination ~\skills\ss -Recurse
pwsh -File ~\skills\ss\scripts\ss.ps1 scan      # 先只读盘点，什么都不改
pwsh -File ~\skills\ss\scripts\ss.ps1 link      # 再铺链接
```

`ss\agents.json` 里是 agent key → 路径模板，`%USERPROFILE%` 运行时展开。换机器、加 agent，只改这一张表。

## 命令

| 命令 | 用途 |
| --- | --- |
| `scan` | 只读盘点：真源 + 各 agent 根，实体/链接/悬空/体积/前置元数据 |
| `doctor` | 只读体检：悬空链接、重复副本、变体分歧、未纳管副本、manifest 缺口 |
| `list` | 技能 × agent 矩阵 |
| `link` | 向所有存在的 agent 根铺 junction（`-DryRun`、`-Agent`） |
| `unlink` | 只摘掉指向真源的链接（`-DryRun`） |
| `add` | 从 GitHub 下 skill 进真源，逐文件校验 git blob SHA，写台账 |
| `migrate` | 把各家实体副本收进真源并换成链接；**默认 dry-run，`-Migrate -Apply` 才动手** |

## 不可协商的规则

- **junction 或者失败。** 绝不降级成复制——复制会把这个工具要消灭的重复重新造出来。
- **`migrate` 默认只是预演。** 改动前先写回退脚本，并且每做完一步就刷盘。
- **内容冲突绝不自动合并。** 同名不同字节 → 两份都留着，报给人决定。
- **先复验再宣布成功。** 跑完 `link` / `migrate` 要再 `scan` 或 `doctor` 确认文件真能穿透链接。

## 限制

- **只支持 Windows**（PowerShell 7 + 目录联接）。macOS/Linux 需要换成 symbolic link，链接层是唯一要改的地方，未实现。
- Claude 桌面版走云端账号技能，本地链接对它无效——不要指望。
- DSH 的技能集是会话级快照，旧会话不会热更新。

## License

MIT
