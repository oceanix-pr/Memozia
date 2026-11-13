# 发布与开源准备

仅在发布或开源任务中读取。本清单保留历史审查的待核查事项，不代表已完成安全、许可证或商店审核。

已配置 Memozia 独立更新源与 Sparkle 公钥，发布流程见 [GitHub 发布](GITHUB_RELEASE.md)。反馈邮箱和 Developer ID 签名团队仍需配置；现有分发为明确标注的未公证预览包。

## 隐私与合规

- [ ] 隐私政策正文与实现一致：改 `Memozia/Services/MemoziaPrivacyPolicy.swift` 的 `sections` 后提升 `version` 主版本号，并实际验证「旧版本已同意的用户升级后会重新看到同意页」。
- [ ] 声纹单独同意在真实链路生效：未勾选时不能生成声纹、不能比对声纹库；撤回后停止处理；已有声纹可在「设置 → 声纹库」逐条删除。
- [ ] `PrivacyInfo.xcprivacy` 与实际外发数据一致：云端视觉模型上传截图/关键帧 → `PhotosorVideos`；声纹仅本地处理 → 不声明 `SensitiveInfo`（若未来增加声纹上传则必须补声明并提升政策主版本号）。
- [ ] 提供独立、可公开访问的隐私政策网页 URL（App Store Connect 必填）；内容与应用内正文一致，并标注政策版本与生效日期。
- [ ] 准备 EULA / 用户协议；`LICENSE` 是 MIT 源码许可，不能替代用户协议。
- [ ] 隐私政策正文多语言：正文为简体中文权威版本；UI 词条覆盖 21 种语言，若目标市场要求正文译文，需翻译当前 `MemoziaPrivacyPolicy.sections` 并同步公开网页。政策版本与日期以源码为准。
- [ ] App Store 隐私标签（App Privacy）与应用内政策、`PrivacyInfo.xcprivacy` 三者一致；逐项核对云端转写/LLM/视觉、模型下载、iCloud 现状。
- [ ] 若启用 iCloud/CloudKit 同步或自动更新：先更新政策并提升主版本号，再验证重新同意流程，避免“功能上线但政策未披露”。
- [ ] 在发布包中走查「设置 → 关于 → 隐私政策」：版本号、声纹单独同意开关、撤回同意（退出并重新征求）均可操作。
- [ ] 配置并验证 `MEMOZIA_CONTACT_EMAIL`；确认安全报告与隐私投诉渠道有效，并同步应用内政策和 `SECURITY.md`。

## 构建与分发

- [ ] 用目标配置构建、测试并验证导出包启动（工程为 macOS 单平台）。
- [ ] 核查签名团队、`app.memozia` Bundle ID 与分发配置；确认新应用的数据目录、钥匙串和权限与旧应用隔离。
- [ ] 检查发布产物的 Hardened Runtime、entitlements、`get-task-allow` 和最小权限。
- [ ] `PrivacyInfo.xcprivacy` 已声明 Audio / OtherUserContent / PhotosorVideos；发布前按「隐私与合规」小节核对实际数据使用与届时平台要求。
- [ ] 评估 ATS 例外。移除 `NSAllowsArbitraryLoads` 前同时核对应用层 URL 校验与局域网 HTTP 使用需求，不承诺仅改 plist 即可支持或禁止某端点。
- [ ] 若计划 Mac App Store 分发，核查 Sandbox 与自定义存储目录访问方案。
- [ ] 实测包体积与模型资源引用；当前 `project.yml` 排除 `Resources/Models/**`，不再以旧“内置四档模型约 2GB”作为现状。
- [ ] 发布时用 `Scripts/bump_version.sh` 调整营销版本；发布前手动分配递增构建号，构建期间只读版本，详见 [构建说明](wiki/13-构建与运行.md)。

## 公开仓库准备

- [ ] 检查 Git 实际跟踪内容与忽略规则，排除 `.packages/`、构建二进制、`xcuserdata/`、`.DS_Store`、临时诊断及备份；依赖缓存无需为节省上下文而物理删除。
- [ ] 检查历史提到的 `bug.txt`、`.i18n_tmp/`、`icon_backup/`、`ax-diagnose`、`calibrate-diarization-bin`、`transcribe` 是否仍存在或被跟踪；源码、必要资源与生成产物分开处理。
- [ ] 扫描待公开文件中的密钥、私人端点、系统诊断、本机绝对路径与个人身份信息；若创建 Git 历史，也要检查全部可达提交。
- [ ] 确认自有代码的开源授权，补充适用的 LICENSE；核查第三方代码、二进制、模型和 OpenCC 字典的许可证、归属及 notices，保留随附许可文本。
- [ ] 核实 App 图标、Logo 和其他素材来源及分发授权，不根据文件名推断素材出处。
- [ ] 提供面向贡献者的 README：项目用途、环境、构建、模型准备、签名替换；按需要补贡献指南。
- [ ] 审阅公开文档中的路线图、个人路径和内部诊断信息；产品与技术文档是否公开按实际发布范围决定。

CloudKit、后台交接和性能遗留事项见 [技术债](TECH_DEBT.md)，不在这里重复维护状态。
