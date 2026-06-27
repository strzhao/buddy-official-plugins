#!/bin/bash
# qr-gen.sh — 二维码生成器（command mode 插件，shell 化版）
#
# 数据流：读 stdin JSON {query, sessionId, cwd, selection?} →
#         jq 取 query → qrencode 生成 PNG 写 $BUDDY_OUTPUT_IMAGE
#
# 契约（与 qr-gen.swift 1:1，state.md ## 契约规约）：
#   - query trim 空 → exit 1 + stderr（不写 BUDDY_OUTPUT_IMAGE）
#   - qrencode -s 24 -m 2 -l M：模块 24px + 边距 2 模块 + 纠错级 M
#     → 默认 module 约 24px × 21+ 模块 ≥ 480px（满足「边长 ≥ 480px」可扫码）
#   - PNG 写 $BUDDY_OUTPUT_IMAGE（框架注入 /tmp/buddy-plugin-<uuid>.png）
#   - stdout 保持空（图片走 BUDDY_OUTPUT_IMAGE，不污染文本通道）
#
# 与 qzh-exec 同款输入模式（镜像 StdinExecutor.swift:69 stdin JSON 契约）：
#   INPUT=$(cat) + jq -r '.query // ""'
#
# 容错：qrencode 失败（超容量 / IO 错误）→ 非零 exit + stderr，不写半成品文件。

set -euo pipefail

# MARK: - 1. 读 stdin JSON + jq 解析

INPUT=$(cat)
QUERY=$(echo "$INPUT" | jq -r '.query // ""' 2>/dev/null)
# trim 首尾空白（与 qr-gen.swift trimmingCharacters(in:.whitespacesAndNewlines) 同语义）
QUERY="$(echo "$QUERY" | awk '{$1=$1};1')"

# query 校验：空 → exit 1（契约边界：不写 BUDDY_OUTPUT_IMAGE）
if [ -z "$QUERY" ]; then
    echo "qr-gen: 查询为空，无法生成二维码" >&2
    exit 1
fi

# MARK: - 2. 校验环境变量 BUDDY_OUTPUT_IMAGE

OUTPUT_PATH="${BUDDY_OUTPUT_IMAGE:-}"
if [ -z "$OUTPUT_PATH" ]; then
    echo "qr-gen: 环境变量 BUDDY_OUTPUT_IMAGE 未设置" >&2
    exit 5
fi

# MARK: - 3. qrencode 生成 PNG（-s 24 模块 24px, -m 2 边距 2 模块, -l M 中等纠错）
#
# -s 24 + 默认 21 模块（v1 QR）+ 2×2 边距 = (21 + 4) × 24 = 600px ≥ 480px ✓
# 数据量大时 qrencode 自动升 QR 版本（模块数增加），边长只会更大，不会跌破 480px。
# -l M：纠错级 M（中等，约 15% 冗余），与 qr-gen.swift 默认级一致。
# -o 直接写 $BUDDY_OUTPUT_IMAGE，省去中间文件。
#
# 退出码：qrencode 成功=0；超容量 / IO 错误=非 0（set -e 会传播，不写半成品）。

if ! qrencode -o "$OUTPUT_PATH" -s 24 -m 2 -l M "$QUERY" 2>/tmp/qr-gen-err.$$; then
    # 读取 qrencode stderr 转发（容错：超容量等）
    ERR_MSG="$(cat /tmp/qr-gen-err.$$ 2>/dev/null || true)"
    rm -f /tmp/qr-gen-err.$$
    echo "qr-gen: qrencode 生成失败：${ERR_MSG:-未知错误}" >&2
    # 删除可能的半成品文件
    rm -f "$OUTPUT_PATH" 2>/dev/null || true
    exit 2
fi
rm -f /tmp/qr-gen-err.$$

# stdout 保持空（图片走 BUDDY_OUTPUT_IMAGE，不污染文本通道）
exit 0
