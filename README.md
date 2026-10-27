# claude-ban-cleanup

> **EN**: A macOS runbook + toolkit for "my Claude account was banned / I'm switching accounts": audit every trace the old account left (Claude Code, third-party launchers, Codex/Orca-style agent tools, browsers), move confirmed residue to a timestamped trash dir (never `rm`), pin all Claude traffic to one fixed egress via a dedicated Surge port + process-level kill-switch, isolate a dedicated Chrome copy for claude.ai, route links by domain through a tiny Swift default-browser, and verify timezone/locale consistency. It only solves the *locally controllable* consistency problems — it does not and cannot defeat server-side risk systems (payment, device fingerprint, IP reputation). ToS compliance is the user's own responsibility.

把一次完整的「老账号清理 → 新账号接管 → 固定出口 → 浏览器隔离 → 一致性核查」实战，整理成可复用的流程与脚本。

**诚实声明**：这套东西只解决**本机可控**的一致性问题。它不能、也不声称能对抗服务端风控（支付方式、设备/行为指纹、IP 信誉、使用习惯都不在本地控制范围）。用不用、怎么用，与服务条款的关系由使用者自行负责。

三条铁律（每个脚本都遵守）：

1. **先审计、再确认、再动手** —— `audit.sh` 出的清单必须逐项确认，`cleanup.sh` 只执行 `confirmed: true` 的项。
2. **绝不打印密钥值** —— OAuth token / API key / cookie / 节点密码，一律只有「存在 / 路径 / 时间 / 数量」。
3. **绝不 rm** —— 一切「删除」都是 `mv` 到 `~/ClaudeBackups/<task>-<时间戳>/` 废纸篓。

## 架构

```
任何来源的链接（终端 ⌘点击 / agent 工具 / 对话里的 artifact）
        │
        ▼
Claude Link Router.app（系统默认浏览器，LSUIElement 后台进程）
        │
        ├── host ∈ claude 系域名 ──▶ claude-browser 启动器
        │                            └─▶ 独立复制的 Chrome + 独立资料目录
        │                                 --proxy-server=http://127.0.0.1:62919
        │                                 （Accept-Language / WebRTC / QUIC 全加固）
        └── 其它 host ──────────────▶ 个人浏览器（一个字节不碰）

Claude Code（原生二进制，~/.local/bin/claude → versions/<ver>）
        │  ~/.claude/settings.json 的 env: HTTP(S)_PROXY → 127.0.0.1:62919
        ▼
Surge：IN-PORT,62919 → 「🤖 Claude」策略组（select，单一固定节点，无直连无自动切换）
       + PROCESS-NAME <claude 版本目录>/ ,REJECT   ← kill-switch：绕过专用口=断网
       + PROCESS-NAME <专用浏览器 .app>/ ,REJECT
       + 域名 / IP-CIDR / ASN 兜底     +  NTP 显式 DIRECT（对时别掐）
```

## 快速开始（严格按序）

```bash
# 0) 克隆进来（作为 Claude Code skill 用）
git clone <this-repo> ~/.claude/skills/claude-ban-cleanup
# 或者放到 .agents/skills/claude-ban-cleanup

# 1) 审计（只读）——生成报告 + manifest 草稿
~/.claude/skills/claude-ban-cleanup/scripts/audit.sh \
    --out audit-$(date +%Y%m%d).md --manifest-out manifest.json

# 2) 逐项确认 manifest.json，把确认的项改成 "confirmed": true
$EDITOR manifest.json

# 3) 清理（只进废纸篓；被占用的自动跳过，退出对应 App 后二刷）
~/.claude/skills/claude-ban-cleanup/scripts/cleanup.sh manifest.json --task <任务名>

# 4) 项目 Git 若被隔离流程弄坏（unborn / 空对象库）
~/.claude/skills/claude-ban-cleanup/scripts/restore-git.sh <repo-dir> <remote-url>

# 5) Surge 固定出口：把 surge/claude-rules.conf 的 <FIXED_NODE> / <HOME> /
#    <CLAUDE_BROWSER_APP> <CLAUDE_DESKTOP_APP> 填好，合并进你的 profile，手动切换

# 6) Claude Code 走专用口：把 claude/settings.env.example.json 的 env 段
#    合并进 ~/.claude/settings.json（BROWSER 记得改成你的路径）

# 7) 装专用浏览器 + 加固资料
browser/install.sh                      # Chrome 副本 + 启动器 + Dock 入口
~/.local/bin/claude-browser https://example.com/   # 拉起一次生成资料目录，然后退出
# Chrome 可能把资料放在 Default/ 或 Profile 1/，以实际目录为准
browser/harden-profile.py "~/Library/Application Support/Claude Browser/Default"

# 8) 编译默认浏览器路由器
router/build.sh --install               # 编成 ~/Applications/Claude Link Router.app
router/build.sh --set-default           # macOS 弹确认框，须亲手点

# 9) 一致性核查
scripts/verify.sh --check-exit \
    --browser-app "$HOME/Applications/Claude Browser Runtime/Claude Chrome.app"
```

## 文件地图

```
SKILL.md                      完整流程手册（§1 审计清单 → §7 踩坑清单）
scripts/audit.sh              只读审计 → Markdown 报告 + manifest 草稿
scripts/cleanup.sh            按确认过的 manifest 清理（mv 进废纸篓 / 钥匙串 / rc 注释）
scripts/restore-git.sh        修被弄坏的仓库：找回远端历史，停在动手之前
scripts/verify.sh             一致性核查：时区/代理/入口/钥匙串/规则/出口 IP
surge/claude-rules.conf       Surge 固定出口规则模板（三层结构 + NTP 直连）
claude/settings.env.example.json   合并进 ~/.claude/settings.json 的 env 段
browser/claude-browser.sh     专用浏览器启动器（装到 ~/.local/bin/claude-browser）
browser/install.sh            装三件套：Chrome 副本 / 启动器 / Dock 入口
browser/harden-profile.py     资料目录加固：语言/定位/安全 DNS/WebRTC/禁登录
router/main.swift             默认浏览器路由器源码（两个 URL 入口 + 3s 去重 + host 日志）
router/Info.plist             bundle 描述（LSUIElement、http/https URL types）
router/build.sh               swiftc 编译 + ad-hoc 签名 + 安装 + 设默认
docs/what-claude-code-sends.md   Claude Code 到底把哪些"地区信号"发给服务端
```

## 老账号标记扫描

`audit.sh --markers <file>`：把老 `.claude.json` 里的 `accountUuid` / `organizationUuid` /
email 每行一个写进文件，脚本在 `$HOME` 下做全盘文本扫描（已排除 Caches / node_modules /
.git 等大目录），只报「路径 + 命中行数 + 标记序号」，不报命中内容。目标：最终 0 命中。

## 坑

见 `SKILL.md` §7——12 条全是实战踩出来的，包括：wrapper 工作区才是活跃状态、被锁文件
先 `lsof` 再清、终端环境变量要重开、`spa:locale` 存 localStorage 后改请求头没用、
`DOMAIN-KEYWORD,sift` 太宽会误伤、`bypass-tun` 在 macOS 是无效参数名、Spotlight 会把
Chrome 副本索引出来拉起裸 Chrome 等。

## License

MIT，见 `LICENSE`。
