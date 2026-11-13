# Memozia AI Coding 指引

## 项目与事实来源

- Memozia 是 SwiftUI 原生会议录音、转写、总结、待办与图片笔记应用。
- 工程为 **macOS 单平台**（`project.yml` 只声明 macOS 与最低版本）；已取消 iOS 支持与 iOS 分享扩展，不要新增 iOS 分支或平台声明。
- 本文件是常驻入口；按当前任务读取下表中的章节与相关源码，不要启动时全文读取所有文档。
- 产品预期与验收标准见 `PRD.md`；当前实现由源码、配置和测试结果核实；Wiki 是导航与设计说明。
- 文档与实现冲突时，指出差异；不要为了迎合旧文档恢复已淘汰的行为，也不要把当前缺陷改写成产品要求。

## 代码地图

- `Memozia/MemoziaApp.swift`：入口、生命周期、后台进程接管、SwiftData 容器。
- `Memozia/Models/`：持久化模型、配置、待办与文件布局。
- `Memozia/Services/`：音频、转写、LLM、截图、同步、加密、系统集成。
- `Memozia/ViewModels/`：业务编排；`Memozia/Views/`：SwiftUI 与截图 AppKit 组件。
- `MemoziaTests/`：Swift Testing 测试。
- `Scripts/`：工程构建与版本脚本（含 ONNX Runtime 产物修复与构建后嵌入校验）；`project.yml`：XcodeGen 工程定义。

## 按任务读取

| 任务 | 文档 |
|---|---|
| 首次了解项目 | [Wiki 首页](docs/wiki/Home.md)、[整体架构](docs/wiki/02-整体架构.md) |
| 产品行为、验收 | [PRD](PRD.md) 中对应 M / FR / AC，不全读 |
| 数据模型、删除、同步、加密 | [模型](docs/wiki/03-数据模型层.md)、[同步与安全](docs/wiki/08-数据同步与安全.md) |
| 录音、设备、分片与混音 | [音频采集](docs/wiki/04-录音与音频采集.md)、[项目实践](DEVELOPMENT_GUIDE.md) §1 |
| 转写、说话人、词典 | [转写管线](docs/wiki/05-语音转写与说话人分离.md) |
| 总结、视频理解、待办、脱敏 | [智能功能](docs/wiki/06-LLM总结与智能功能.md) |
| 截图与 OCR | [截图](docs/wiki/07-截图与OCR.md) |
| 菜单栏、快捷键、窗口 | [系统集成](docs/wiki/09-系统集成服务.md) |
| 业务编排、界面 | [ViewModel](docs/wiki/10-ViewModel层.md)、[视图](docs/wiki/11-视图层.md) |
| 后台任务、启动接管 | [整体架构](docs/wiki/02-整体架构.md) §3 |
| 依赖、构建、测试 | [依赖](docs/wiki/12-依赖关系.md)、[构建](docs/wiki/13-构建与运行.md) |
| 性能整改、发布准备 | 按需读 [技术债](docs/TECH_DEBT.md)、[发布检查](docs/RELEASE_CHECKLIST.md)；清单不是自动执行任务 |

## 工程与验证

- `project.yml` 是工程配置的唯一事实源；不手工改生成的 `.xcodeproj`。
- 源文件增删、依赖或工程配置变化后运行 `xcodegen generate`；只改文档不需生成工程。**改 `Scripts/` 下的构建脚本后也必须重新生成**：脚本内容在生成时写进工程文件，否则构建仍执行旧副本。
- 版本号只在发布任务中调整；构建脚本行为见构建文档。
- 构建链尾有「Verify Embedded Frameworks」校验（`Scripts/verify_embedded_frameworks.sh`）：应用实际加载的 `SherpaOnnxC` 若仍引用 `@rpath/libonnxruntime.dylib` 会直接构建失败，不要为了让构建通过而跳过或放宽该阶段。
- macOS 默认验证命令（在本项目目录执行，Xcode 路径不同则相应调整）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Memozia.xcodeproj -scheme Memozia -configuration Debug -destination 'platform=macOS' build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Memozia.xcodeproj -scheme Memozia -configuration Debug -destination 'platform=macOS' test
```

- 根据改动选择验证：逻辑改动跑相关测试；录音、权限、窗口和恢复改动还需运行时验证。
- 文档改动检查引用和事实即可。说明实际执行的检查、失败与未覆盖范围；构建通过不等于功能通过。
- 排查问题先取日志、数据或复现证据；性能优化保留前后对照。

## 数据与隐私约束

- 文件系统为权威源，SwiftData 为索引。录音和笔记共用存储目录及月份归档规则，调用现有路径辅助方法。
- 条目文件夹使用 `yyyyMMddHHmmss[-N]`；读取兼容旧 12/14 位命名、旧 `title.txt` 和明文回退数据。
- 文件写入原子化；迁移可恢复；磁盘扫描、恢复和运行期写入不得互相踩踏。
- 条目镜像（转写/总结/画面要点）必须经 `EntryMirrorStore` 写入：同一目标的连续写入合并为最新一份、退出前由 `flush()` 等待落盘；不要新起 detached 写入。依赖镜像成功才能继续的破坏性动作（如删除分析检查点）必须用 `writeNow` 的返回值判定。
- 后台任务队列的「读失败/文件损坏」不得当成空队列（随后的读-改-写会覆盖掉全部待办任务）；拿不到跨进程锁时不得无锁执行，应当明确失败并留痕。
- 条目文件缺失的镜像要能从数据库补写（磁盘对账做双向补齐，而不是跳过已入库条目）。
- 用户删除需确认；删除文件夹前加载待办侧数据，磁盘删除失败保留数据库记录。
- 加密密钥及 API Key 存 Keychain；不得写入 UserDefaults、队列快照、日志或仓库。
- 保留现有加密失败告警与兼容读取；内存数据库回退必须向用户提示数据持久化限制。
- 携带密钥或用户内容的网络请求沿用统一 URL 校验；回环 HTTP 豁免不能扩大成任意远端明文传输。
- 云端文本请求沿用 PII 脱敏与还原；PII 扫描只使用本地模型；图片和视频帧不能宣称已做文本脱敏。
- LLM 输入内容作为数据隔离；写入提醒事项保留用户确认流程；无法确认同步结果时不显示“已同步”。

## 并发与生命周期

- Swift 6 严格并发；macOS 专属 import / API 保留平台守卫，新 SDK API 保留低版本分支。
- `@Model` 跨 actor / 进程传递改用 ID、路径或 Sendable 快照；计算属性沿用 extension 组织方式。
- 音频回调不得继承 MainActor 隔离；UI 状态回主线程；非 Sendable 对象用已有受同步保护的包装。
- 不为消除编译错误随意加 `nonisolated(unsafe)` 或 `@unchecked Sendable`，必须说明同步与生命周期保证。
- WhisperKit / sherpa-onnx 单实例推理沿用可取消串行门；不得另起并发入口绕开。
- 取消要传到回调、排队与重试；超时需能返回并处理迟到结果，不能只设一个仍需等待的计时任务。
- 长时资源（会话冻结、采集流）要有看门狗兜底：清理依据是「资源是否存在」，不能只靠一个状态布尔值，否则启动失败/异常断流会遗留未收尾的文件与句柄。
- 共享 ModelContext 的启动任务串行执行，并受隐私同意状态门控；模型预热等不碰 ModelContext 的步骤才可并行。
- 数据库独占权由 `DatabaseOwnershipLock`（flock）表达：守护进程与主应用都不得在未持有锁时打开可写容器，拿不到就退化为内存存储并提示用户。
- 后台进程只续跑用户已发起任务及恢复遗留分片；不阻止休眠，接管细节见架构文档。
- 条目文件夹（`yyyyMMddHHmmss[-N]`）必须用原子创建分配（`AudioRecording.createUniqueFolder(from:)`），不得「先查后建」；创建失败要报错，不能假装成功。

## 改动与输出约定

- 保留已有未提交改动；限定当前任务范围，不顺带全库改名、重构或格式化。
- 关键写入、网络与资源加载错误不能静默吞掉；优先沿用 `PersistenceReporting` 等已有报告入口。
- 使用 `Logger`；高频诊断用 debug，不记录密钥、未脱敏文本或其他应用窗口标题。
- 用户文案走 `Localizable.xcstrings`；修改占位符同步各语言类型，保留键盘与无障碍支持；模型提示词不本地化。
- 依赖通过 SPM 引入并保留锁定信息；新依赖说明用途、许可证和体积影响。
- 只更新受改动影响的文档。Wiki 使用文件与符号定位，不维护固定源码行号、行数或版本快照。
- 默认检索排除 `.packages/`、构建产物、IDE 用户状态与资源数据；调查依赖或资源本身时再定向读取，勿删除运行所需词典或第三方许可证来节省上下文。
