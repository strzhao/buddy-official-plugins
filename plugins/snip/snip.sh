#!/bin/bash
# snip.sh — 文本片段速取（command mode 插件）
#
# 数据流：读 stdin JSON {query, sessionId, cwd, selection?} →
#         精确命中 keyword → stdout 展开后片段（框架 autoCopy 写剪贴板）
#         空/模糊/未命中 → 候选 JSON 写 $BUDDY_OUTPUT_CANDIDATES + stdout（便于 run 调试观测）
#         selection=del:<kw> → 真删 + stdout 提示
#
# 契约（state.md ## 契约规约）：
#   C1 读类零 LLM（command mode，框架零 provider 调用）
#   C2b del 走 command selection 回调（selection=del:<kw>，二次确认才真删）
#   C3 autoCopy（plugin.json autoCopyToClipboard:true，命中时框架代写剪贴板）
#   C4 候选通道（$BUDDY_OUTPUT_CANDIDATES JSON [{id,title,subtitle,selection}]）
#   C5 占位符（{date}/{time}/{clipboard} 展开；{cursor} 不支持；未定义原样保留）
#   C11 不崩退出码（未命中/损坏 exit 0 + 友好提示）
#
# candidates JSON schema（与 qzh 同款）：
#   [{id, title, subtitle?, selection}]
#   selection 字段用于 submitWithCandidate 回调（command mode only）

set -euo pipefail

# MARK: - source 共享 helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/snippets.sh
. "$SCRIPT_DIR/lib/snippets.sh"

# MARK: - 读 stdin JSON
INPUT="$(cat)"
QUERY="$(printf '%s' "$INPUT" | jq -r '.query // ""' 2>/dev/null || echo "")"
# trim 首尾空白
QUERY="$(printf '%s' "$QUERY" | awk '{$1=$1};1')"
SELECTION="$(printf '%s' "$INPUT" | jq -r '.selection // ""' 2>/dev/null || echo "")"

# MARK: - 路径 1：selection=del:<kw> → 真删（C2b 二次确认回调）
if [ -n "$SELECTION" ]; then
    case "$SELECTION" in
        del:*)
            DEL_KW="${SELECTION#del:}"
            # 校验 del 关键词白名单（防注入）
            if ! validate_keyword "$DEL_KW"; then
                echo "snip: 无效的删除目标 '$DEL_KW'" >&2
                exit 0
            fi
            # 真删（snippets_del 幂等，不存在也成功；静默其 stdout，本脚本自己输出提示）
            snippets_del "$DEL_KW" >/dev/null 2>&1 || true
            echo "已删除片段 '$DEL_KW'"
            exit 0
            ;;
        *)
            # 未知 selection → 友好提示不崩（C11）
            echo "snip: 未知操作"
            exit 0
            ;;
    esac
fi

# MARK: - 路径 2：精确命中 keyword → stdout 展开后片段（框架 autoCopy）
if [ -n "$QUERY" ]; then
    EXACT_CONTENT="$(snippets_get "$QUERY" 2>/dev/null || echo "")"
    if [ -n "$EXACT_CONTENT" ]; then
        # stdout 展开后片段（框架 autoCopy 写剪贴板，C3）
        printf '%s' "$EXACT_CONTENT"
        exit 0
    fi
fi

# MARK: - 路径 3：空 query 或模糊/未命中 → 候选列表
#
# 同时写 $BUDDY_OUTPUT_CANDIDATES（框架 UI 渲染）+ stdout（便于 run 调试观测，修 NB1）
# 候选 schema：[{id, title, subtitle, selection}]
#   - 每条候选 selection 字段 = "del:<kw>"，用户选中后框架回调本脚本 selection=del:<kw>
#   - id 唯一（用 keyword）

# 取候选（空 query → list 全部；非空 → search 模糊）
if [ -z "$QUERY" ]; then
    CANDIDATES_RAW="$(snippets_list 2>/dev/null || echo "[]")"
else
    CANDIDATES_RAW="$(snippets_search "$QUERY" 2>/dev/null || echo "[]")"
fi

CANDIDATE_COUNT="$(printf '%s' "$CANDIDATES_RAW" | jq 'length' 2>/dev/null || echo "0")"

# 构造 candidates JSON（含删除项）
build_candidates_json() {
    local raw="$1"
    # 每条 → {id: keyword, title: keyword, subtitle: snippet, selection: "del:<keyword>"}
    printf '%s' "$raw" | jq -c '[.[] | {
        id: .keyword,
        title: ("📍 \(.keyword)"),
        subtitle: .snippet,
        selection: ("del:" + .keyword)
    }]' 2>/dev/null || echo "[]"
}

CANDIDATES_JSON="$(build_candidates_json "$CANDIDATES_RAW")"

# 写 $BUDDY_OUTPUT_CANDIDATES（框架 UI 渲染候选，C4）
OUTPUT_CANDIDATES_PATH="${BUDDY_OUTPUT_CANDIDATES:-}"
if [ -n "$OUTPUT_CANDIDATES_PATH" ]; then
    printf '%s' "$CANDIDATES_JSON" > "$OUTPUT_CANDIDATES_PATH" 2>/dev/null || true
fi

# stdout 输出（便于 run 调试观测 + 用户直接看候选）
if [ "$CANDIDATE_COUNT" = "0" ]; then
    if [ -z "$QUERY" ]; then
        echo "暂无文本片段。用「加个 <关键词> 内容 <内容>」添加片段。"
    else
        echo "未找到匹配 '$QUERY' 的片段。"
    fi
    exit 0
fi

# 有候选 → stdout 输出候选列表（人类可读 + JSON 都给，便于调试）
if [ -z "$QUERY" ]; then
    echo "所有片段（共 $CANDIDATE_COUNT 条，选中可删除）："
else
    echo "匹配 '$QUERY' 的片段（共 $CANDIDATE_COUNT 条，选中可删除）："
fi
printf '%s' "$CANDIDATES_RAW" | jq -r '.[] | "  \(.keyword): \(.snippet)"' 2>/dev/null || true
exit 0
