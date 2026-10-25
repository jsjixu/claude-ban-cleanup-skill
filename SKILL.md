---
name: claude-ban-cleanup
description: macOS 上 Claude 账号被封/换号后的"干净接入"全流程：审计并清理老账号在 Claude Code、第三方启动器、Codex/Orca 等 agent 工具、浏览器里的全部残余；保留项目与配置让新账号接管；把 Claude 全部流量钉死到一个固定出口（Surge 专用端口 + 进程级 kill-switch）；隔离浏览器 + 按域名分流的默认浏览器；时区/语言/NTP 一致性核查。当用户提到 Claude 账号被封、换新账号、清理老账号痕迹、Claude 固定出口、Claude 专用浏览器、Claude Code 走代理时使用。
---

# Claude Ban Clean Up

> 一句话：**先审计、再确认、再动手；凡删必先进废纸篓；一个密钥都不打印。**

本 skill 把一次完整的"老账号清理 + 新账号接管 + 固定出口 + 浏览器隔离"实战整理成可复用的流程。
它解决的是**本机可控**的那部分一致性问题。它**不能**也不声称能对抗服务端风控
（支付方式、设备/行为指纹、IP 信誉等都不在本地控制范围内）；是否符合服务条款由使用者自行负责。

## 0. 原则（每一步都适用）

1. **审计先行**：任何写操作之前先跑 `scripts/audit.sh` 出报告，拿到用户逐项确认后再动。
2. **不打印密钥**：OAuth token、refresh token、API key、cookie、代理节点密码一律只报告"存在/位置/时间"，不输出值。
3. **只进废纸篓**：所有删除都是 `mv` 到带时间戳的目录（默认 `~/ClaudeBackups/<task>-<YYYYMMDD>/`），用户确认不需要后再 `rm`。
4. **白名单保护**：项目源码、Git 仓库、`~/.claude/projects`、sessions/history、skills/plugins/hooks/commands/agents/MCP 配置、settings 一律不碰，除非用户点名。
5. **不切换、不断网**：生成新的代理配置放到对应目录即可，由用户手动切换；给正在生效的配置加规则用临时规则（`surge-cli rule temp add`），不 reload。
6. **不夸大**：所有结论用 Surge 请求记录、`lsof`、系统日志等**实测**支撑，不用"应该"。

## 1. 账号状态在哪里（审计清单）

| 位置 | 内容 | 处理 |
|---|---|---|
| `~/.claude.json` | `oauthAccount`（accountUuid / organizationUuid / email）、MCP 授权态、项目列表 | 换号后由新登录覆盖；老的 UUID/email 是**老账号标记**，用于全盘扫描 |
| `~/.claude/` | settings、projects、sessions、skills、plugins、statsig、telemetry | 保留；只清 `statsig/`、`telemetry/`、含老 UUID 的 plugin 目录 |
| 钥匙串 `Claude Code-credentials` | 当前 OAuth 凭据 | 新登录会覆盖；审计只看 `security find-generic-password -s 'Claude Code-credentials'` 是否存在及修改时间 |
| 钥匙串 `claude-code-oauth-token`（或任意自定义服务名） | 长效令牌 | 老账号的要删；**先确认新 OAuth 凭据存在**再删 |
| shell rc（`.zshrc`/`.zprofile`/`.bashrc`） | `CLAUDE_CODE_OAUTH_TOKEN=` / `ANTHROPIC_API_KEY=` 注入、自定义 `claude` 函数或 alias | 注释/删除；**已开着的终端标签环境变量仍是旧的，必须新开** |
| `~/.local/bin/claude` | 可能被第三方启动器（wrapper）替换成脚本 | `file` + `readlink` 核对；恢复为指向 `~/.local/share/claude/versions/<ver>` 的软链 |
| 第三方启动器的数据目录（如 `~/Library/Application Support/<Wrapper>/workspaces/*/data/Claude`） | **完整的另一份 `.claude` 状态**，经常才是真正活跃的那份 | 逐工作区看 `oauthAccount`，分辨新/老账号 |
| Claude Desktop：`~/Library/Application Support/Claude`、`~/Library/Caches/com.anthropic.claudefordesktop`、`~/Library/Preferences/com.anthropic.claudefordesktop.plist`、`~/Library/HTTPStorages/com.anthropic.claudefordesktop` | 桌面端登录态、缓存、cookie | 退出 Desktop 后整体进废纸篓 |
| Codex：`~/.codex/sessions/*.jsonl`、`~/.codex/state_*.sqlite`、`thread_history_*.sqlite`（含 `-wal`/`-shm`） | 会话日志里会**原文记录**老账号 UUID/email | 退出 Codex（`lsof` 为空）后移走命中文件 |
| Orca 等 Electron agent 工具：`~/Library/Application Support/<App>/Partitions/<browser-partition>/` | 内置浏览器的 cookie/IndexedDB/缓存，可能带 claude.ai 登录态 | 退出 App 后整个 partition 目录进废纸篓 |
| 浏览器资料（Chrome/Edge/Safari 以及 wrapper 自建的 Chrome 资料） | claude.ai / anthropic / Google / Apple cookie，`spa:locale` 等 localStorage | 个人浏览器**不动**；专用浏览器资料重建 |
| `/tmp`、`~/Library/Caches`、`~/Library/Logs` 下 wrapper 的 IPC/日志 | 老会话 ID | 重启或手动清 |

**老账号标记扫描**：从老的 `.claude.json`（或 wrapper 工作区的那份）取出 `accountUuid`、`organizationUuid`、email，
用 `audit.sh --markers` 在 `$HOME` 下做全盘文本扫描（排除 `Library/Caches`、`node_modules`、`.git/objects` 等大目录），
命中文件逐个列出路径和命中次数——**不输出命中行内容**。目标是最终 0 命中。

## 2. 清理（必须有用户逐项确认）

`scripts/cleanup.sh <manifest.json>`：manifest 是 audit 生成、用户确认过的 JSON 列表，脚本只做：

- 对每一项：`lsof` 检查是否被占用 → 占用则跳过并报告 PID；否则 `mv` 到 `~/ClaudeBackups/<task>-<date>/` 保留相对路径。
- 钥匙串项用 `security delete-generic-password -s <service> -a <account>`，删前 `find-generic-password` 确认新凭据存在。
- rc 文件只注释不删行，并 `zsh -n` 校验语法。
- 结束输出：移动了什么、跳过了什么（含 PID）、废纸篓位置。

**常见二次清理**：第一轮会漏掉被进程锁住的文件（Codex 的 sqlite、Orca 的 partition）。退出对应 App 后再跑一次 manifest 中的 `skipped` 项。

## 3. 项目接管（新账号在 Orca / 终端里继续用原项目）

接管只依赖三样：项目目录、`~/.claude/projects/<编码后路径>/` 下的会话记录、settings。账号和项目之间没有绑定，新账号登录后直接 `cd` 进项目 `claude` 即可。

**但要检查 Git 是否被之前的"隔离/清理"弄坏**，典型症状（Orca 报"未找到基础分支"、"This branch does not have a committed HEAD yet"）：
- `git count-objects -v` 对象数为 0 / `git rev-parse HEAD` 失败（unborn branch）
- `git remote -v` 为空、没有 `origin/main`
- 工作区大量"已修改"实为被重写的文件

修复用 `scripts/restore-git.sh <repo> <remote-url>`：备份 `.git` → `git fetch origin` → `git reset --mixed origin/<default>` → 列出与远端的差异让用户决定 `checkout -- .` 还是保留。Orca 等工具的项目目录（catalog）和 worktree 用其自带 CLI 清理，不直接改它的数据库。

## 4. 固定出口（Surge）

目标：**Claude Code、claude.ai 网页、专用浏览器的每个请求都从同一个固定节点出去，一个都不漏，漏了宁可断。**

### 4.1 三层结构
1. **专用入口端口**：Surge `http-listen = 127.0.0.1:6152, 127.0.0.1:62919`，第二个口只给 Claude 用；规则 `IN-PORT,62919,"🤖 Claude"` 放在 `[Rule]` 最顶部。`🤖 Claude` 策略组是 `select`，**只含一个固定节点，没有 DIRECT、没有自动切换**。
2. **进程级 kill-switch**：`PROCESS-NAME,"<claude 二进制目录>/",REJECT` 和 `PROCESS-NAME,"<专用浏览器 .app 路径>/",REJECT`——这两个程序若绕开专用口直连（Chrome 的 WebRTC/STUN、Bun 的直连），整条掐断，不回退任何出口。这是用"把真实 IP 泄露变成断网"换来的确定性。
3. **域名/IP 兜底**：Claude 核心域名、CDN/认证、遥测（datadog/statsig/sentry/sift）、第三方 widget、Anthropic 自有 IP 段与 ASN 全部进 `🤖 Claude`。即便 `--proxy-server` 失效，域名层还能接住。

完整规则模板见 `surge/claude-rules.conf`，`[General]` 还需要：`udp-policy-not-supported-behaviour = REJECT`（节点不转 UDP 时拒绝而不是直连）。

### 4.2 让 Claude Code 走专用口
不要用 wrapper。直接写进 `~/.claude/settings.json`（Orca 聊天模式、终端、Ghostty 全部一致生效）：
```json
"env": {
  "HTTPS_PROXY": "http://127.0.0.1:62919",
  "HTTP_PROXY": "http://127.0.0.1:62919",
  "NO_PROXY": "localhost,127.0.0.1",
  "BROWSER": "/Users/<you>/.local/bin/claude-browser"
}
```
`BROWSER` 让 Claude Code 自己打开的 OAuth/artifact 链接进专用浏览器（已核对二进制：它读 `process.env.BROWSER`）。

### 4.3 验证（必须实测）
- `surge-cli rule match https://claude.ai/` 与 `https://anthropic.auth0.com/` → 固定节点
- `curl -x http://127.0.0.1:62919 https://api.ipify.org` → 固定出口 IP；不带代理的 `curl` → 本地出口 IP，两者不同
- Surge 请求记录按进程过滤：专用浏览器/claude 的请求 100% 命中 `IN-PORT` 或 `PROCESS-NAME … REJECT`，0 条 DIRECT / 其它节点。看到若干条 STUN 被 REJECT 是**正常且期望的**（WebRTC 探测被掐）。
- `claude -p "hi"` 能回答，即证明走了专用口（直连被 REJECT，通了只能是代理）。

### 4.4 NTP：有意不走代理（不要照搬网上"NTP 泄露时区"的说法）
NTP 返回 UTC 时间，不含任何时区信息；时区完全由系统设置决定。把 NTP 送进不支持 UDP 的节点 + `udp-policy-not-supported-behaviour = REJECT` = **对时被掐断**，几天后 TLS/签名类接口莫名出错。显式钉住：常见对时域名 `DIRECT` + `DEST-PORT,123,DIRECT` 兜底（见模板第 8 段）。

## 5. 专用浏览器 + 按域名分流的默认浏览器

### 5.1 专用浏览器 = 一份独立的 Chrome 副本 + 独立资料目录
`browser/claude-browser.sh`（装到 `~/.local/bin/claude-browser`）：
```
--user-data-dir=<独立资料目录>  --proxy-server=http://127.0.0.1:62919
--lang=en-US --accept-lang=en-US,en --disable-quic
--force-webrtc-ip-handling-policy=disable_non_proxied_udp
--no-first-run --no-default-browser-check
```
- 用**单独复制的一份 Chrome.app**（不是 `/Applications/Google Chrome.app`），这样 Surge 的 `PROCESS-NAME … REJECT` 能按路径精确只掐它，不影响个人 Chrome。复制即可，不改签名；钥匙串 Chrome Safe Storage 认签名不认路径，改名/移动不丢登录态。Dock 显示的名字 = `.app` 文件夹名。
- Dock/Spotlight 入口做一个 50 字节的 launcher `.app`（`Contents/MacOS/<name>` 是 `exec ~/.local/bin/claude-browser "$@"`），所有参数只在 `claude-browser` 一处维护。给 Chrome 副本所在目录放 `.metadata_never_index`，防止 Spotlight 直接拉起无参数的裸 Chrome。
- `browser/harden-profile.py <profile-dir>`（Chrome 退出后运行）写 Preferences：`intl.accept_languages=en-US,en`、拼写词典 en-US、翻译关、`geolocation=2`（定位 API 默认拒绝——它走 Google 位置服务 + Wi-Fi 扫描，不受代理约束）、安全 DNS 关、`webrtc.ip_handling_policy=disable_non_proxied_udp`、禁止登录 Chrome 本体/Sync。**注意**：若之后在 Chrome 里新建资料或登录 Google 账号，Chrome 可能切到 `Profile 1/`，需对新目录重跑。

### 5.2 默认浏览器 = 40 行 Swift 路由器
`router/main.swift` → `router/build.sh` 生成 `~/Applications/Claude Link Router.app`（`LSUIElement`，登记 http/https）。逻辑：
- host 命中 `claude.ai / claude.com / anthropic.com / claudeusercontent.com / claudemcpcontent.com / claude.app` → 调 `claude-browser`
- 其它 → `NSWorkspace.open(withApplicationAt: 个人浏览器)`，个人浏览器资料一个字节不碰
- 两个入口都要实现（`kAEGetURL` AppleEvent + `application(_:open:)`），3 秒内同 URL 去重，只记 host 到 `~/Library/Logs/claude-link-router.log`，处理完自退出。
- `build.sh --set-default` 调 `NSWorkspace.setDefaultApplication`，macOS 会弹确认框，**必须用户亲手点**。

意义：终端（Ghostty ⌘点击）、Orca、Claude 对话里的 artifact 链接——不管来源——claude 域名永远不会落进带老账号 cookie 的个人浏览器。

## 6. 一致性核查（`scripts/verify.sh`）

| 信号 | 怎么看 | 期望 |
|---|---|---|
| Claude Code 发给服务端的时区/时间 | 它用 `Intl.DateTimeFormat().resolvedOptions().timeZone`（= 系统时区 `/etc/localtime`），出现在系统提示 `Today's date is …`、每轮的本地时间戳（带 UTC 偏移）、部分 skill 的 `userTimezone` 字段里。**不读** `LANG`、地区、语言偏好。详见 `docs/what-claude-code-sends.md` | 系统时区与出口 IP 所在时区一致 |
| 系统时区自动设定 | `log show --last 1d --predicate 'process == "timed"' \| grep TMAutomaticTimeZoneEnabled` → 看 `v,"0"`。**不要**看 `/Library/Preferences/com.apple.timezone.auto.plist`，那是旧版遗留键 | 关闭（`0`），时区手动钉死 |
| 浏览器 Accept-Language | 本地起一个回显请求头的 HTTP 服务让专用浏览器访问 | `en-US,en;q=0.9` |
| 站点自己记住的语言 | claude.ai 把首次判定写进 localStorage `spa:locale`，之后**不再看请求头** | 若已是 zh：退出浏览器，移走资料里 claude.ai 的 Local/Session Storage、IndexedDB、Service Worker；登录后在账号设置里确认 English |
| WebRTC / QUIC | Surge 记录里 STUN 被 REJECT；`--disable-quic` | 0 条 UDP 出网 |
| DNS | Surge 记录：claude 域名**不在本机解析**，域名直接交给节点远端解析 | 本机只解析节点自身地址 |
| 钥匙串 | `Claude Code-credentials` 存在且修改时间 = 新登录时间；老的长效令牌服务名不存在 | |
| 远控 | CLI 顶栏 `/rc active`；网页端 "Not connected" 指**该网页条目对应的本机进程**不在线——每个 CLI 会话注册一个随机名字的环境，旧进程退出即永远 Not connected，不是网络问题。用 `/remote-control` 看当前会话名再去网页对应 | |
| 改不了的 | 字体指纹（系统中文字体）、屏幕/GPU 指纹、出口 IP 信誉随时间变化 | 如实告知用户 |

## 7. 踩过的坑（照着避免）

1. `~/.claude` 不一定是活跃状态——wrapper 的工作区目录才是。先 `ps`/`which claude`/`file` 看清楚链路。
2. Codex sqlite、Orca partition 被进程锁住时 `mv` 会导致半残状态：先 `lsof`，占用就跳过，退出 App 后二次清理。
3. 隔离/清理脚本可能把 Git 对象库清空、留下 unborn branch，表面看项目还在；接管前必跑 `git rev-parse HEAD` + `git remote -v`。
4. 已开的终端标签环境变量不会变；改完 settings/rc 后要用户**退出重开 Orca/Ghostty**，否则还在用旧令牌。
5. 新登录后钥匙串里可能已有一条用长效令牌写进去的 `Claude Code-credentials`，看起来"已登录"；照样 `/login` 走 OAuth 覆盖它。
6. Chrome 的 `--lang` 只管 UI 语言，网页看到的是 `intl.accept_languages`；而站点可能把首次语言存在 localStorage 里，改设置不会生效。
7. 改专用浏览器 `.app` 名/路径前：先 `surge-cli rule temp add` 一条新路径的 REJECT 做兜底 → 改磁盘上的配置 → 实测新规则命中 → 删临时规则。中间没有裸奔窗口。
8. `DOMAIN-SUFFIX,datadoghq.com` 抓不到 `browser-intake-us5-datadoghq.com`（连字符，根域是它自己）；用 `DOMAIN-KEYWORD,datadoghq`。`DOMAIN-KEYWORD,sift` 则太宽，用 `sift.com`/`siftscience.com` 精确后缀。
9. `PROCESS-NAME,claude,...` 这种按进程名的"兜底"在原生二进制 + IN-PORT 结构下永远轮不到，是死规则，删掉以免误导。
10. Surge 的 `bypass-tun` 是 iOS 旧参数名，macOS 报"未知的配置"且从未生效，用 `tun-excluded-routes`。把 `192.168.0.0/16` 整段放进 `skip-proxy`/`tun-excluded-routes` 会让所有针对内网段的代理跳板规则永远不触发。
11. `com.apple.timezone.auto.plist Active=1` 是 2021 年的遗留键，不代表自动时区开着；以 `timed` 日志的 `TMAutomaticTimeZoneEnabled` 为准。
12. Spotlight 会把 Chrome 副本本体索引出来，用户一点就拉起无代理参数的裸 Chrome——给目录放 `.metadata_never_index`。

## 8. 交付时报告什么

- 清理：移走了哪些（按类别计数）、废纸篓路径、老账号标记扫描结果（命中 0）、被跳过的文件及原因。
- 接管：三样东西各自状态（项目目录、Git HEAD/remote/base、`~/.claude/projects` 会话）。
- 网络：Surge 规则命中统计表（条数 × 协议 × 规则 × 策略）、出口 IP 对比、当前加载的 profile 未变。
- 浏览器：Accept-Language 回显、时区、WebRTC 结果、路由器日志样例（`claude.ai -> isolated`、`example.com -> personal`）。
- 明确列出"改不了的"和"不保证的"。
