#!/bin/bash
# snip-mgr.sh — 文本片段管理（stdin mode 插件，仅 add/edit）
#
# 数据流：读 stdin JSON {query, sessionId, cwd, rawToolInput?} →
#         rawToolInput.{action, keyword, content} → add/edit CRUD → stdout 回灌 LLM
#
# 契约（state.md ## 契约规约）：
#   C2 写类走 stdin agent loop（LLM tool_use 真执行 + 回灌）
#   依赖 T0 扩展 B（PluginInput.rawToolInput 透传 tool_use 结构化参数到 stdin）
#   仅做 add/edit（del 在 snip command 经 selection 回调，C2b）
#
# 向后兼容：rawToolInput 缺失（老框架/非 tool 路径）→ 退化用 query 解析（best effort）
#
# keywords 禁含 add/edit/del 单字（防 AI 流 contains 误触，I2）

set -euo pipefail

# MARK: - source 共享 helper（与 snip 共享 ~/.buddy/snippets.json）
SNIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../snip/lib/snippets.sh
. "$SNIP_DIR/snip/lib/snippets.sh"

# MARK: - 读 stdin JSON
INPUT="$(cat)"

# T0 扩展 B：优先从 rawToolInput 读结构化参数（tool_use 路径）
# rawToolInput 缺失 → 退化从顶层 query 解析（best effort，向后兼容）
RAW_ACTION="$(printf '%s' "$INPUT" | jq -r '.rawToolInput.action // ""' 2>/dev/null || echo "")"
RAW_KEYWORD="$(printf '%s' "$INPUT" | jq -r '.rawToolInput.keyword // ""' 2>/dev/null || echo "")"
RAW_CONTENT="$(printf '%s' "$INPUT" | jq -r '.rawToolInput.content // ""' 2>/dev/null || echo "")"

# 退化路径：rawToolInput 缺失，从 query 解析（格式："add|edit <keyword> <content>"）
if [ -z "$RAW_ACTION" ]; then
    QUERY="$(printf '%s' "$INPUT" | jq -r '.query // ""' 2>/dev/null || echo "")"
    # 解析 "add kw content..." 或 "edit kw content..."
    ACTION_PARSED="$(printf '%s' "$QUERY" | awk '{print tolower($1)}' 2>/dev/null || echo "")"
    case "$ACTION_PARSED" in
        add|edit)
            RAW_ACTION="$ACTION_PARSED"
            RAW_KEYWORD="$(printf '%s' "$QUERY" | awk '{print $2}' 2>/dev/null || echo "")"
            # content = 第 3 个字段之后的所有内容
            RAW_CONTENT="$(printf '%s' "$QUERY" | awk '{$1=""; $2=""; sub(/^[ \t]+/,""); print}' 2>/dev/null || echo "")"
            ;;
        *)
            # 无法解析 → 提示用户用自然语言
            echo "snip-mgr 收到无法解析的输入。请用自然语言描述，如「加个 sig 内容 张三 13800138000」或「把 sig 改成 李四」。"
            exit 0
            ;;
    esac
fi

# trim 参数
RAW_ACTION="$(printf '%s' "$RAW_ACTION" | awk '{$1=$1};1')"
RAW_KEYWORD="$(printf '%s' "$RAW_KEYWORD" | awk '{$1=$1};1')"
RAW_CONTENT="$(printf '%s' "$RAW_CONTENT" | awk '{$1=$1};1')"

# MARK: - 参数校验
if [ -z "$RAW_ACTION" ] || [ -z "$RAW_KEYWORD" ] || [ -z "$RAW_CONTENT" ]; then
    echo "snip-mgr: 缺少必要参数（action/keyword/content）。请提供完整信息。"
    exit 0
fi

# MARK: - 路由 add / edit
case "$RAW_ACTION" in
    add)
        # 校验 keyword 白名单（snippets_add 内部也校验，这里提前给出友好提示）
        if ! validate_keyword "$RAW_KEYWORD"; then
            echo "添加失败：关键词 '$RAW_KEYWORD' 含非法字符（只能含字母数字 _ -）。"
            exit 0
        fi
        # 调 snippets_add（keyword 已存在会返回非 0）
        if ADD_OUT="$(snippets_add "$RAW_KEYWORD" "$RAW_CONTENT" 2>&1)"; then
            echo "$ADD_OUT"
            exit 0
        else
            # add 失败（已存在 / 损坏）→ 回灌错误给 LLM
            echo "$ADD_OUT"
            exit 0
        fi
        ;;
    edit)
        # 校验 keyword 非空（snippets_edit 内部也校验）
        if ! validate_keyword "$RAW_KEYWORD"; then
            echo "修改失败：关键词 '$RAW_KEYWORD' 含非法字符（只能含字母数字 _ -）。"
            exit 0
        fi
        if EDIT_OUT="$(snippets_edit "$RAW_KEYWORD" "$RAW_CONTENT" 2>&1)"; then
            echo "$EDIT_OUT"
            exit 0
        else
            echo "$EDIT_OUT"
            exit 0
        fi
        ;;
    *)
        echo "snip-mgr: 未知 action '$RAW_ACTION'（仅支持 add / edit）。"
        exit 0
        ;;
esac
