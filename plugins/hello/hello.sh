#!/usr/bin/env bash
# hello 插件：stdin mode 最小示例。
# 框架通过 stdin 传入 PluginInput JSON：{query,sessionId,cwd,selection?}
# 插件把 stdout 作为 markdown 文本回显（这里回显一句问候）。
# 详见 /plugin/docs「最小示例」章节。
set -euo pipefail

# 读 stdin（PluginInput JSON）并解析 query 字段（容错：解析失败用占位文本）
input="$(cat)"
query="$(printf '%s' "$input" | /usr/bin/python3 -c 'import json,sys
try:
    obj=json.load(sys.stdin)
    q=obj.get("query") or ""
    print(q)
except Exception:
    print("")
' 2>/dev/null || true)"

# query 为空时给一个友好占位
if [ -z "$query" ]; then
    query="朋友"
fi

# 输出 markdown 文本（框架把 stdout 映射为 .text 事件）
printf '👋 你好，**%s**！这是 hello 示例插件。\n\n你刚才输入的内容是：%s\n' "$query" "$query"
