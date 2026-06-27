# qr 插件

二维码生成器（command mode 插件）。输入文本或网址，生成一张可扫码的 PNG 二维码图片。

## 用法

在 Launcher 里输入 `qr` 触发，或在 CLI 直接 dry-run：

```bash
echo '{"query":"https://example.com"}' | \
  BUDDY_OUTPUT_IMAGE=/tmp/qr.png ./qr-gen.sh
# → /tmp/qr.png 生成一张 ≥480px 的二维码 PNG
```

app 内点击生成的图片可一键复制到剪贴板。

## 依赖

首次使用时，app 会弹信任框并自动安装以下依赖（通过 Homebrew）：

| 命令 | brew 包 | 说明 |
|---|---|---|
| `qrencode` | `qrencode` | 二维码生成库（PNG 输出） |
| `jq` | `jq` | JSON 解析（从 stdin PluginInput 取 query） |

手动安装：

```bash
brew install qrencode jq
```

## 契约

- **mode**：`command`（零 LLM、bypass agent loop，子进程直接产出图片）
- **输入**：stdin JSON `{query, sessionId?, cwd?, selection?}`，取 `query` 字段
- **空查询**：`query` trim 后为空 → `exit 1` + stderr，不写图片
- **输出**：PNG 写环境变量 `$BUDDY_OUTPUT_IMAGE`（框架注入 `/tmp/buddy-plugin-<uuid>.png`）
- **尺寸**：`qrencode -s 24 -m 2 -l M` → 模块 24px + 边距 2 模块 + 纠错级 M，边长 ≥ 480px（保证可扫码）
- **stdout**：保持空（图片走 `$BUDDY_OUTPUT_IMAGE`，不污染文本通道）
- **纠错级**：M（中等，约 15% 冗余）

## 文件

- `qr-gen.sh` — shell 实现（command mode 可执行脚本，chmod 755）
- `plugin.json` — 插件清单（声明 deps + requiredPath）

## 历史

v0.2.0 从编译型 universal binary（`qr-gen`，CoreImage `CIFilter.qrCodeGenerator`）改为 shell 脚本（`qrencode`）。原因：binary 预编译入库维护成本高（需 lipo 双 arch + 热更新兼容），shell 化后声明 deps 由 app 首次执行时自动安装，零编译、可读、可审计。
