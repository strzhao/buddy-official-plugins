#!/bin/bash
# qzh 插件 sudoers 免密 setup（一次性，C7 安全核心）
#
# 写 /etc/sudoers.d/qzhddr-launcher，让 qzh-exec 的 sudo launchctl 免密。
# 之后所有开关操作静默执行（无需每次输密码）。
#
# 安全红线（C7）：NOPASSWD 仅放行 4 条**精确** launchctl 命令串：
#   1. launchctl bootout system/com.cyberserval.qzhddr.service
#   2. launchctl bootout system/com.cyberserval.qzhddr.update
#   3. launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.service.plist
#   4. launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.update.plist
# 不放行通配 / 任意 label / 任意参数（防提权放大）。
# 查询用 launchctl print / pgrep 不需 sudo，不放行。
#
# 本脚本需用户一次 sudo（写 /etc/sudoers.d）。
# 卸载：sudo rm /etc/sudoers.d/qzhddr-launcher

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/qzhddr-launcher"
SUDOERS_TMP=$(mktemp)

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root 权限写入 /etc/sudoers.d，请用 sudo 运行："
    echo "  sudo bash $0"
    exit 1
fi

# 检查 visudo 可用
if ! command -v visudo >/dev/null 2>&1; then
    echo "错误：visudo 不可用（非 macOS 标准环境？）" >&2
    exit 1
fi

# 构造 sudoers 内容（4 条精确 NOPASSWD，C7 最小权限）
cat > "$SUDOERS_TMP" <<'SUDOERS_EOF'
# qzh launcher 插件免密（C7 最小权限）—— 仅放行 QzhddrSrv 的精确 launchctl 命令。
# 生成自 claude-code-buddy/apps/desktop Marketplace/plugins/qzh/setup.sh
# 卸载：sudo rm /etc/sudoers.d/qzhddr-launcher
#
# 安全：不放行通配 / 任意 label / 任意参数。查询（launchctl print / pgrep）不需 sudo。

# 关闭：bootout service + update
%admin ALL=(root) NOPASSWD: /bin/launchctl bootout system/com.cyberserval.qzhddr.service
%admin ALL=(root) NOPASSWD: /bin/launchctl bootout system/com.cyberserval.qzhddr.update

# 打开：bootstrap service + update（plist 路径精确匹配）
%admin ALL=(root) NOPASSWD: /bin/launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.service.plist
%admin ALL=(root) NOPASSWD: /bin/launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.update.plist
SUDOERS_EOF

# visudo 语法校验（写入前校验，避免损坏 sudoers 导致系统锁死）
if ! visudo -cf "$SUDOERS_TMP" >/dev/null; then
    echo "错误：sudoers 语法校验失败，未写入系统（保护 sudoers 完整性）" >&2
    rm -f "$SUDOERS_TMP"
    exit 1
fi

# 写入 /etc/sudoers.d（权限 0440，root:wheel）
install -m 0440 -o root -g wheel "$SUDOERS_TMP" "$SUDOERS_FILE"
rm -f "$SUDOERS_TMP"

# 再次校验已写入的文件（最终确认，场景8.P2）
if ! visudo -cf "$SUDOERS_FILE" >/dev/null; then
    echo "错误：写入后 visudo 校验失败，请检查 $SUDOERS_FILE" >&2
    exit 1
fi

echo "✓ sudoers 免密已配置：$SUDOERS_FILE"
echo "  放行 4 条精确 launchctl 命令（bootout/bootstrap service + update）"
echo ""
echo "卸载方法：sudo rm $SUDOERS_FILE"
