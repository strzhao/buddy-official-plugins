#!/bin/bash
# snippets.sh — snip / snip-mgr 共享 helper（sourced，不直接执行）
#
# 数据模型（snippets.json，契约 C9）：
#   顶级数组，元素 {"keyword":"sig","content":"...","created_at":"...","updated_at":"..."}
#   keyword 唯一键；content 可多行；created_at/updated_at 为 ISO8601。
#
# 文件位置：${BUDDY_SNIPPETS_FILE:-$HOME/.buddy/snippets.json}
#
# 容错契约（AC-SNIP-20 / C11）：
#   - 缺失/空文件/空数组/空对象 → 视为空片段库（正常，exit 0）
#   - 损坏（非法 JSON）→ snippets_load 报错到 stderr + 返回非 0，调用方决定是否退出
#     （snip list/get 优雅提示；snip-mgr add/edit 拒绝写以保护数据）
#
# 原子写（契约 C6 / AC-SNIP-15）：临时文件 + mv rename，禁裸 > 覆盖。
#
# 安全（契约 C8）：validate_keyword 白名单 [A-Za-z0-9_-]，防 shell 注入。

# MARK: - 配置

: "${BUDDY_SNIPPETS_FILE:=$HOME/.buddy/snippets.json}"

# MARK: - snippets_load：读 + 校验 JSON 合法性
#
# 用法：snippets_load || { 友好提示; exit 0; }
# 返回：
#   stdout = JSON 数组（合法时；缺失/空文件/空数组/空对象 → "[]"）
#   exit 0 = 合法（含空）
#   exit 1 = 损坏（非空但非法 JSON）—— 调用方应拒写
snippets_load() {
    local file="$BUDDY_SNIPPETS_FILE"
    # 缺失 → 空数组
    if [ ! -f "$file" ]; then
        echo "[]"
        return 0
    fi
    # 空文件 → 空数组
    if [ ! -s "$file" ]; then
        echo "[]"
        return 0
    fi
    # 读内容 + jq 校验合法性（jq 解析失败 → 非空文件但非法 JSON）
    local content
    content="$(cat "$file" 2>/dev/null)" || content=""
    # 用 jq . 做合法性校验 + 规范化输出（确保是数组）
    local normalized
    if ! normalized="$(echo "$content" | jq -c '. as $root | if ($root|type)=="array" then $root elif ($root|type)=="object" and ($root|length)==0 then [] else $root end' 2>/dev/null)"; then
        # jq 解析失败 = 损坏
        echo "snippets_load: snippets.json 损坏（非法 JSON），拒绝操作以保护数据" >&2
        return 1
    fi
    # 校验顶级是数组（{} 已转 []，但其他类型如 "string"/数字仍要拒）
    local top_type
    top_type="$(echo "$normalized" | jq -r 'type' 2>/dev/null)"
    if [ "$top_type" != "array" ]; then
        echo "snippets_load: snippets.json 顶级非数组（type=$top_type），拒绝操作" >&2
        return 1
    fi
    echo "$normalized"
}

# MARK: - snippets_get：精确 keyword 取单条
#
# 用法：snippets_get <keyword>
# stdout = 展开后的 content（命中）；空（未命中）
# exit 0 = 命中并输出；exit 0 + 空 stdout = 未命中（不崩，C11）
snippets_get() {
    local kw="$1"
    local data
    if ! data="$(snippets_load 2>/dev/null)"; then
        # 损坏 → 不崩，空输出
        return 0
    fi
    local content
    content="$(echo "$data" | jq -r --arg k "$kw" '.[] | select(.keyword == $k) | .content' 2>/dev/null | head -n1)"
    if [ -z "$content" ]; then
        return 0
    fi
    # 展开占位符
    expand_placeholders "$content"
}

# MARK: - snippets_search：模糊匹配候选列表
#
# 用法：snippets_search <query>
# stdout = JSON 数组 [{keyword, content, snippet(content,80)}]（命中条目，按 keyword 字典序）
# 未命中 → "[]"（C11，不崩）
snippets_search() {
    local q="$1"
    local data
    if ! data="$(snippets_load 2>/dev/null)"; then
        echo "[]"
        return 0
    fi
    # 模糊匹配：keyword contains query（大小写敏感，简化实现；query 空则列全部）
    if [ -z "$q" ]; then
        echo "$data" | jq -c '[.[] | {keyword, content, snippet: (.content[:80])}] | sort_by(.keyword)' 2>/dev/null || echo "[]"
    else
        echo "$data" | jq -c --arg q "$q" '[.[] | select(.keyword | ascii_downcase | contains($q|ascii_downcase)) | {keyword, content, snippet: (.content[:80])}] | sort_by(.keyword)' 2>/dev/null || echo "[]"
    fi
}

# MARK: - snippets_list：列全部
#
# 用法：snippets_list
# stdout = JSON 数组 [{keyword, snippet}]（按 keyword 字典序）
snippets_list() {
    local data
    if ! data="$(snippets_load 2>/dev/null)"; then
        echo "[]"
        return 0
    fi
    echo "$data" | jq -c '[.[] | {keyword, snippet: (.content[:80])}] | sort_by(.keyword)' 2>/dev/null || echo "[]"
}

# MARK: - snippets_add：新增（keyword 唯一，已存在则失败）
#
# 用法：snippets_add <keyword> <content>
# exit 0 = 成功；exit 1 = 校验失败 / 已存在；exit 2 = 写失败
snippets_add() {
    local kw="$1"
    local content="$2"
    # 校验 keyword（锁外快速失败）
    if ! validate_keyword "$kw"; then
        echo "snippets_add: keyword 含非法字符（仅允许字母数字 _ -）" >&2
        return 1
    fi
    if [ ${#content} -gt 10000 ]; then
        echo "snippets_add: content 超过长度上限（10000 字符）" >&2
        return 1
    fi
    # read-modify-write 在 subshell + 文件锁内（AC-SNIP-15 并发事务原子），trap EXIT 解锁
    (
        trap '_snippets_unlock' EXIT
        if ! _snippets_lock; then
            echo "snippets_add: 获取文件锁超时" >&2
            exit 2
        fi
        local data
        if ! data="$(snippets_load 2>/dev/null)"; then
            echo "snippets_add: snippets.json 损坏，拒绝写入以保护数据" >&2
            exit 2
        fi
        local exists
        exists="$(echo "$data" | jq -r --arg k "$kw" '[.[] | select(.keyword == $k)] | length' 2>/dev/null)"
        if [ "$exists" != "0" ]; then
            echo "snippets_add: keyword '$kw' 已存在，请用 edit 修改" >&2
            exit 1
        fi
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local newdata
        newdata="$(echo "$data" | jq -c --arg k "$kw" --arg c "$content" --arg t "$ts" \
            '. + [{keyword: $k, content: $c, created_at: $t, updated_at: $t}] | sort_by(.keyword)' 2>/dev/null)"
        if [ -z "$newdata" ]; then
            echo "snippets_add: 构造新数据失败" >&2
            exit 2
        fi
        if ! _snippets_atomic_write "$newdata"; then
            echo "snippets_add: 原子写失败" >&2
            exit 2
        fi
        echo "已添加片段 '$kw'"
        exit 0
    )
}

# MARK: - snippets_edit：更新已存在（不存在则失败）
#
# 用法：snippets_edit <keyword> <content>
# exit 0 = 成功；exit 1 = 校验失败 / 不存在；exit 2 = 写失败
snippets_edit() {
    local kw="$1"
    local content="$2"
    # 校验（锁外快速失败）
    if [ -z "$kw" ]; then
        echo "snippets_edit: keyword 不能为空" >&2
        return 1
    fi
    if [ ${#content} -gt 10000 ]; then
        echo "snippets_edit: content 超过长度上限（10000 字符）" >&2
        return 1
    fi
    # read-modify-write 在 subshell + 文件锁内（AC-SNIP-15 并发事务原子）
    (
        trap '_snippets_unlock' EXIT
        if ! _snippets_lock; then
            echo "snippets_edit: 获取文件锁超时" >&2
            exit 2
        fi
        local data
        if ! data="$(snippets_load 2>/dev/null)"; then
            echo "snippets_edit: snippets.json 损坏，拒绝写入以保护数据" >&2
            exit 2
        fi
        local exists
        exists="$(echo "$data" | jq -r --arg k "$kw" '[.[] | select(.keyword == $k)] | length' 2>/dev/null)"
        if [ "$exists" != "1" ]; then
            echo "snippets_edit: keyword '$kw' 不存在（无法 edit），请用 add 添加" >&2
            exit 1
        fi
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local newdata
        newdata="$(echo "$data" | jq -c --arg k "$kw" --arg c "$content" --arg t "$ts" \
            'map(if .keyword == $k then .content = $c | .updated_at = $t else . end) | sort_by(.keyword)' 2>/dev/null)"
        if [ -z "$newdata" ]; then
            echo "snippets_edit: 构造新数据失败" >&2
            exit 2
        fi
        if ! _snippets_atomic_write "$newdata"; then
            echo "snippets_edit: 原子写失败" >&2
            exit 2
        fi
        echo "已更新片段 '$kw'"
        exit 0
    )
}

# MARK: - snippets_del：删除（keyword 存在则删）
#
# 用法：snippets_del <keyword>
# exit 0 = 成功（含不存在）；exit 2 = 写失败 / 损坏
snippets_del() {
    local kw="$1"
    if [ -z "$kw" ]; then
        return 0
    fi
    # read-modify-write 在 subshell + 文件锁内（AC-SNIP-15 并发事务原子）
    (
        trap '_snippets_unlock' EXIT
        if ! _snippets_lock; then
            echo "snippets_del: 获取文件锁超时" >&2
            exit 2
        fi
        local data
        if ! data="$(snippets_load 2>/dev/null)"; then
            echo "snippets_del: snippets.json 损坏，拒绝写入以保护数据" >&2
            exit 2
        fi
        # 不存在 → 直接成功（幂等）
        local exists
        exists="$(echo "$data" | jq -r --arg k "$kw" '[.[] | select(.keyword == $k)] | length' 2>/dev/null)"
        if [ "$exists" = "0" ]; then
            echo "snippets_del: keyword '$kw' 不存在（已删除）"
            exit 0
        fi
        local newdata
        newdata="$(echo "$data" | jq -c --arg k "$kw" '[.[] | select(.keyword != $k)] | sort_by(.keyword)' 2>/dev/null)"
        if [ -z "$newdata" ]; then
            echo "snippets_del: 构造新数据失败" >&2
            exit 2
        fi
        if ! _snippets_atomic_write "$newdata"; then
            echo "snippets_del: 原子写失败" >&2
            exit 2
        fi
        echo "已删除片段 '$kw'"
        exit 0
    )
}

# MARK: - expand_placeholders：动态占位符展开
#
# 用法：expand_placeholders <text>
# stdout = 展开后的文本
# 契约 C5：
#   {date}     → YYYY-MM-DD（date +%Y-%m-%d）
#   {time}     → HH:MM（date +%H:%M）
#   {clipboard}→ 当前剪贴板（pbpaste）
#   {cursor}   → 不支持（原样保留，README 明示）
#   未定义/畸形（{nope}、{date、{）→ 原样保留（AC-SNIP-19 降级锁定）
#
# 实现：仅替换已知占位符，其余一律原样保留。
# 用 sed 做精确字符串替换（不用正则贪婪匹配，避免误吞）。
expand_placeholders() {
    local text="$1"
    if [ -z "$text" ]; then
        echo ""
        return 0
    fi
    local today now clip
    today="$(date +%Y-%m-%d 2>/dev/null || echo '{date}')"
    now="$(date +%H:%M 2>/dev/null || echo '{time}')"
    # P0-1 修复（product-ux-scorer 发现）：原 sed 替换在剪贴板多行时静默失败
    # （sed replacement 含换行截断命令）→ snippets_get 空 stdout → 精确命中 fallthrough
    # 候选 → autoCopy 不触发，用户 Cmd+V 粘贴旧内容。日常剪贴板常多行（段落/代码）。
    # 改用 perl -pe（原生多行）+ $ENV 替换（replacement 无需转义）；并 lazy 化——
    # 只在 text 含 {clipboard} 时才读 pbpaste（避免无条件副作用 + 性能）。
    clip=""
    if [[ "$text" == *"{clipboard}"* ]]; then
        clip="$(pbpaste 2>/dev/null || echo '{clipboard}')"
    fi
    printf '%s' "$text" | DATE="$today" TIME="$now" CLIP="$clip" perl -pe '
        s/\{date\}/$ENV{DATE}/g;
        s/\{time\}/$ENV{TIME}/g;
        s/\{clipboard\}/$ENV{CLIP}/g;
    '
}

# MARK: - validate_keyword：白名单校验
#
# 用法：validate_keyword <keyword>
# exit 0 = 合法；exit 1 = 非法（含非法字符 / 空 / 超长）
# 白名单：[A-Za-z0-9_-]，长度 1-64（防 shell 注入，契约 C8）
validate_keyword() {
    local kw="$1"
    if [ -z "$kw" ]; then
        return 1
    fi
    if [ ${#kw} -gt 64 ]; then
        return 1
    fi
    # 仅允许字母数字 _ -，其余一律拒
    if printf '%s' "$kw" | LC_ALL=C grep -qE '^[A-Za-z0-9_-]+$'; then
        return 0
    fi
    return 1
}

# MARK: - _snippets_lock/_snippets_unlock：文件锁（mkdir 原子，保证 read-modify-write 事务）
#
# AC-SNIP-15 并发安全：snippets_add/edit/del 是 read-modify-write；
# _snippets_atomic_write 只保证单次 write 原子，不保证事务原子。
# mkdir 是 POSIX 原子操作，作互斥锁；配合 subshell trap EXIT 退出自动解锁。
# 含 stale lock 检测（写 PID，持有者进程不在则清理），防死锁。
_snippets_lock() {
    local lockdir="$BUDDY_SNIPPETS_FILE.lock"
    local tries=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        # 每 ~2s 检查锁持有者是否还活着（防 stale lock 死锁）
        if [ $((tries % 40)) -eq 0 ]; then
            local owner_pid
            owner_pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
            if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
                rm -rf "$lockdir" 2>/dev/null || true
                continue
            fi
        fi
        tries=$((tries + 1))
        if [ $tries -gt 200 ]; then
            return 1  # ~10s 超时
        fi
        sleep 0.05
    done
    echo "$$" > "$lockdir/pid" 2>/dev/null || true
    return 0
}

_snippets_unlock() {
    rm -rf "$BUDDY_SNIPPETS_FILE.lock" 2>/dev/null || true
}

# MARK: - _snippets_atomic_write：内部原子写（临时文件 + mv rename）
#
# 用法：_snippets_atomic_write <json_string>
# exit 0 = 成功；exit 1 = 失败
# 确保目录存在 + 临时文件同目录（mv rename 原子性要求同文件系统）
_snippets_atomic_write() {
    local content="$1"
    local file="$BUDDY_SNIPPETS_FILE"
    local dir
    dir="$(dirname "$file")"
    # 确保目录存在（权限 0700，与 ~/.buddy/ 一致）
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" 2>/dev/null || return 1
        chmod 700 "$dir" 2>/dev/null || true
    fi
    # 临时文件（同目录，保证 mv rename 原子性）
    local tmp
    tmp="$file.tmp.$$"
    # 写临时文件（printf 避免 echo 转义；jq -c 已规范为紧凑 JSON）
    if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    # 写后再校验一次合法性（防写过程被截断）
    if ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    # mv rename（原子）
    if ! mv "$tmp" "$file" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 600 "$file" 2>/dev/null || true
    return 0
}
