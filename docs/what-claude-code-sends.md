# Claude Code 会把本机哪些"地区信号"发给服务端

核对对象：Claude Code 原生二进制 2.1.310（`~/.local/share/claude/versions/2.1.310`，Bun 打包，内嵌 JS 可直接检索字符串）。
方法：对二进制做字节级正则搜索，定位 `Intl.DateTimeFormat().resolvedOptions()`、`Today's date is`、`process.env.*` 等调用点并读上下文。
版本升级后结论可能变化，升级后请按同样方法复核。

## 会发的

| 内容 | 来源 | 出现在哪 |
|---|---|---|
| 时区名（如 `America/Los_Angeles`） | `Intl.DateTimeFormat().resolvedOptions().timeZone` → 进程的 `TZ` 环境变量，未设则为系统时区（`/etc/localtime`） | 系统提示 / 上下文附件（`Today's date is …` 按本地日期算）；定时任务与云端 agent 等 skill 的 `userTimezone` 字段；时间解析提示里的 `Local timezone:` |
| 本地时间 + UTC 偏移（如 `2026-10-25T10:10:30-07:00`） | `new Date()` + `getTimezoneOffset()` | 每一轮对话附带的时间戳（`formatPerTurnNow`） |
| UTC 时间戳 | `toISOString()` | 同上 |

## 不会发的

- `LANG` / `LC_*`：二进制中没有 `process.env.LANG` 的读取。
- macOS 的"地区"（`AppleLocale`）与"首选语言"（`AppleLanguages`）：没有任何读取。
- `Intl…resolvedOptions().locale`（进程 locale）：只在**语音输入**功能的遥测里出现（`systemLocaleLanguage`），不用语音功能就不会发。
- `Accept-Language` 请求头：二进制里只有 HTTP 库的头名常量表，没有主动设置该头的代码。

## 对你意味着什么

1. **系统时区必须和出口 IP 的时区一致**，这是 Claude Code 这条通道上唯一可见的"地区"信号。
   - 看：`readlink /etc/localtime`、`date`
   - 改：系统设置 → 通用 → 日期与时间 → 关闭"使用你的当前位置自动设定时区"，手动选城市
   - 核实自动时区确实关了：`log show --last 1d --predicate 'process == "timed"' | grep TMAutomaticTimeZoneEnabled` 应为 `v,"0"`。
     **不要**看 `/Library/Preferences/com.apple.timezone.auto.plist`——那是旧版系统的遗留键，可能常年写着 `Active = 1`。
2. 如果不想改系统时区，也可以只在 `~/.claude/settings.json` 的 `env` 里加 `"TZ": "America/Los_Angeles"`，Claude Code 进程会以它为准；但浏览器里 JS 读到的仍是系统时区，两边会不一致，不推荐。
3. **NTP 和这一切无关**：NTP 只让时钟准（返回 UTC 瞬时值），不改变时区，也不改变 Claude Code 发出的任何字段。它该直连就直连（见 `surge/claude-rules.conf` 第 8 段）。
