# qzh 插件 — QzhddrSrv 监控服务控制

快速「关闭 / 打开 / 查询」公司监控软件 QzhddrSrv 的运行状态。

## 工作机制

QzhddrSrv 是公司监控软件，3 个 launchd 项全部 `KeepAlive:true + RunAtLoad:true`：

| Label | 类型 | 作用 |
|-------|------|------|
| `com.cyberserval.qzhddr.service` | system Daemon | 主监控 QzhddrSrv + Scanner XPC（发热/监控元凶） |
| `com.cyberserval.qzhddr.update` | system Daemon | 更新服务 |
| `com.cyberserval.qzhddr.agent` | gui/501 Agent | 用户态 Agent（CPU 极低，不动） |

`KeepAlive` 意味着 `kill` 无效（launchd 立即重启）。唯一有效停止 = `sudo launchctl bootout`；
打开 = `sudo launchctl bootstrap`。

**关闭是可逆的**：bootout 只卸载不删 plist，重启电脑后 launchd 按 `RunAtLoad` 自动恢复 ——
恰好满足「日常不需要、在公司时需要」的诉求。

## 安装

### 1. 安装插件到 launcher

插件随 Claude Code Buddy app bundle 分发（`Marketplace/plugins/qzh/`）。
用户可本地链接到 `~/.buddy/launcher-plugins/qzh/`：

```bash
mkdir -p ~/.buddy/launcher-plugins
ln -s "/Applications/ClaudeCodeBuddy.app/Contents/Resources/Marketplace/plugins/qzh" \
      ~/.buddy/launcher-plugins/qzh
```

依赖：`jq`（Homebrew 安装：`brew install jq`）。

### 2. 配置 sudoers 免密（一次性，C7 最小权限）

qzh-exec 的 `sudo launchctl` 需要免密才能静默开关。运行 setup.sh（需一次输密码）：

```bash
sudo bash /Applications/ClaudeCodeBuddy.app/Contents/Resources/Marketplace/plugins/qzh/setup.sh
```

写入 `/etc/sudoers.d/qzhddr-launcher`，**仅放行 4 条精确命令**（C7 安全核心）：

```
%admin ALL=(root) NOPASSWD: /bin/launchctl bootout system/com.cyberserval.qzhddr.service
%admin ALL=(root) NOPASSWD: /bin/launchctl bootout system/com.cyberserval.qzhddr.update
%admin ALL=(root) NOPASSWD: /bin/launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.service.plist
%admin ALL=(root) NOPASSWD: /bin/launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.update.plist
```

**不放行通配 / 任意 label / 任意参数**（防提权放大）。查询用 `launchctl print` / `pgrep` 不需 sudo。

校验语法（应输出 `parsed OK`）：

```bash
sudo visudo -cf /etc/sudoers.d/qzhddr-launcher
```

## 使用

在 Launcher（Ctrl+Space）输入 `qzh`：

1. **查询**：显示当前状态（运行中/已停止）+ 各组件明细，候选列表出现「关闭监控」「打开监控」
2. **关闭**：选中「关闭监控」→ bootout service + update（可逆，重启自愈）
3. **打开**：选中「打开监控」→ bootstrap service + update（RunAtLoad 立即拉起）

候选操作通过框架的「选中回调重入」（C5）执行：选中后框架以 `selection=stop/start`
再次调用 qzh-exec，qzh-exec 据 selection 路由执行。**执行权留在插件**，launcher 绝不
执行候选携带命令（C2 安全红线）。

## 卸载

```bash
# 1. 移除 sudoers 免密条目
sudo rm /etc/sudoers.d/qzhddr-launcher

# 2. 移除插件链接
rm ~/.buddy/launcher-plugins/qzh
```

## 安全说明

- `LauncherCandidate.selection` 仅是标识字符串（`stop`/`start`），**禁含命令/路径**
- 执行权始终在 qzh-exec 插件，launcher 只透传 selection（C5）
- sudoers 最小权限：4 条精确命令，不放行通配（C7）
- 关闭可逆：重启自动恢复，无持久禁用副作用
