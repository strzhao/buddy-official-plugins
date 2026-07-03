# snip-mgr — 文本片段管理

用自然语言添加或修改文本片段，配合 `snip`（只读取/删除）使用。走 LLM tool-use 路径，理解自然语言意图后执行 add/edit。

## 用法

```
加个 <关键词> 内容 <内容>      # 添加新片段
把 <关键词> 改成 <新内容>      # 修改已存在片段
添加地址片段 内容 <内容>，关键词 <kw>   # 变体表达
```

## 示例

```
加个 sig 内容 张三 13800138000
# → 已添加片段 'sig'

把 sig 改成 李四 13900139000
# → 已更新片段 'sig'
```

## 职责边界（与 snip 分工）

| 操作 | 插件 | 路径 |
|---|---|---|
| 取片段 | snip | command mode，零 LLM 秒回 |
| 列全部 | snip | command mode，零 LLM |
| 删除片段 | snip | command mode，候选选中二次确认 |
| **添加片段** | **snip-mgr** | **stdin mode，LLM tool-use** |
| **修改片段** | **snip-mgr** | **stdin mode，LLM tool-use** |

## 参数（LLM tool schema）

snip-mgr 声明结构化参数，LLM 按以下 schema 填 slot：

| 字段 | 类型 | 说明 |
|---|---|---|
| action | enum: `add` / `edit` | 操作类型 |
| keyword | string | 片段关键词，白名单 `[A-Za-z0-9_-]`，长度 1-64 |
| content | string | 片段内容，最长 10000 字符，支持 `{date}`/`{time}`/`{clipboard}` 占位符 |

## 关键词设计（防误触）

snip-mgr 的 keywords 是 `snipm` / `片段管理`，**禁含 `add`/`edit`/`del` 单字**，防止 AI 流 contains 误触路由（设计契约 I2）。

## 数据存储

与 snip 共享 `~/.buddy/snippets.json`（同文件，原子写）。

## 依赖

- `jq`（JSON 处理）

## 限制

- 仅做 add/edit，删除请用 snip 候选列表
- keyword 白名单 `[A-Za-z0-9_-]`（防 shell 注入）
- content 长度上限 10000 字符
- 损坏的 snippets.json 会拒绝写入以保护数据
