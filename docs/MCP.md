# Memozia 本机 MCP

## 使用

1. 启动 Memozia，完成当前版本隐私确认与磁盘对账。临时内存模式不提供 MCP。
2. 在「设置 → MCP 集成」启用本机只读服务。默认地址为 `http://127.0.0.1:42817/mcp`；修改端口前先关闭服务。
3. 输入客户端名称，选择共享起始日期与是否脱敏，点击「授权并复制连接配置」。默认只共享最近 30 天的脱敏文本；隐藏条目始终排除。
4. 将复制的配置加入支持 stdio MCP 的本机客户端。配置采用常见的 `mcpServers` JSON 结构；使用其他配置格式的客户端填写相同的 `command` 与 `env` 字段。命令指向 App 内的 `Contents/Helpers/memozia-mcp`，移动 App 后需重新复制配置。
5. Memozia 进程必须运行；完整退出、撤回隐私同意或关闭 MCP 后不可访问。客户端授权可分别撤销，原访问令牌立即失效。App 更新准备阶段暂不接受请求。

连接配置包含独立访问令牌。Memozia 将令牌存于 Keychain，偏好只保存客户端名称、授权日期和脱敏开关；不要把复制的配置提交到仓库。客户端可能将收到的明文交给云端模型，启用本机传输不等于内容始终离线。脱敏沿用本机词典和规则，不保证识别全部敏感信息，脱敏映射不会返回客户端。

支持直接配置 HTTP 的本机客户端也可使用该地址及 `Authorization: Bearer <访问令牌>`；使用同一授权凭据，按 SDK 支持的 MCP `2025-11-25` 协议初始化。当前不提供 OAuth、公网监听或远程网关。

## 只读接口

| Tool | 参数要点 | 结果 |
|---|---|---|
| `list_entries` | `type`（recording/video/note）、ISO 8601 `since/until`、`limit` 1–50、`cursor` | 授权范围内条目的 ID、标题、类型、日期与内容 URI |
| `search_entries` | 必填 `query`（1–200 字符），其余同上 | 标题、总结、正文、OCR、画面要点或转写的首个关键词命中；转写命中含起止秒数 |
| `get_entry` | `entry_id`、`field`（默认 summary；笔记支持 text/ocr，录音支持 visual）、`limit` 1–16000 字符、`cursor` | 指定文本字段的一页及是否已有内容 |
| `get_transcript` | `entry_id`、可选 `start_seconds/end_seconds`、`limit` 1–100、`cursor` | 按时间排序的转写片段、说话人和转写状态 |
| `get_todos` | `entry_id` | 本地已保存的待办，不读取或修改 EventKit 提醒事项 |

所有分页跟随 `next_cursor`，为 null 才表示结束。列表按条目文件夹名倒序排列（兼容旧 12/14 位命名），每次搜索最多扫描 500 条并受时间预算限制，可能返回空结果页及后续游标；不能据一页空结果断定全库没有命中。游标绑定客户端、授权与参数，正文和转写游标还绑定内容版本；参数变化或正文/转写更新后应重新查询。

Resource templates：`memozia://entries/{entry_id}/{summary|text|ocr|visual|transcript}`。结果是同一授权与脱敏规则下的分页 JSON，长内容继续调用对应 Tool。录音、图片、视频、模型配置、声纹向量和任意文件路径均不通过此接口导出。

## 实现与边界

- `Services/MCP/EntryQueryService.swift`：MainActor 内使用现有 ModelContext，只输出 Sendable 的值；明确区分未生成、找不到、解密/读盘失败。搜索直接读取当前索引中的加密字段，不另建明文全文索引。
- `Services/EntryIdentityStore.swift`：新建/保存元数据时写 `entry_id`；启用 MCP 前对旧条目补齐。保留未知元数据字段、原子写入；损坏的元数据拒绝覆盖。`FileSyncService` 从磁盘重建条目时恢复同一 UUID。旧根目录中尚无独立条目文件夹的数据不对外列出。
- `MCPReadOnlyServer.swift`：官方 SDK 处理 JSON-RPC；每个 MCP 会话独立 Server/transport，凭据每次验证，会话绑定客户端。关闭/撤销后不返回进行中请求的旧结果。
- `MCPLoopbackListener.swift`：SwiftNIO 处理 HTTP，固定监听 `127.0.0.1`，验证 Host/Origin；请求体上限 64 KiB，响应上限 512 KiB，并限制并发与会话数量。GET SSE 返回 405，客户端使用 JSON 响应；业务只读，不申请录音/提醒事项权限。
- `MCPServerController.swift`：隐私确认、持有数据库锁、持久化启动对账完成后才启动服务；磁盘对账、录音合并与更新安装期间暂停查询，退出时先停止入口。helper 不打开数据库、不读取 AES/LLM 密钥，也不加载推理模型。
- 当前仅有只读能力；创建笔记、异步处理账本、录音控制和远程连接属于后续阶段，未注册相应工具。

## 构建与验证

新增依赖与 helper target 都在 `project.yml`。源文件、脚本或工程配置变化后先执行 `xcodegen generate`，再按 [构建文档](wiki/13-构建与运行.md) 构建与运行单元测试。构建阶段通过 `Scripts/embed_mcp_helper.sh` 将已签名的 helper 嵌入 App，现有 Verify Embedded Frameworks 校验保持启用。

`MemoziaTests/MCPReadOnlyTests.swift` 覆盖凭据撤销、范围与隐藏状态、全文检索、游标、时间位置、脱敏、身份元数据和协议会话隔离。发布前还需在真实客户端上验证连接配置、退出/重启和钥匙串授权行为。
