# Memozia 更新发布

`project.yml` 是版本、独立 HTTPS stable feed 和公开 Ed25519 密钥的事实源。私钥仅保存在本机 Keychain 的 `com.oceanix.Memozia.sparkle` 账户中；不要导出到源码、日志或构建环境。配置遵循 [Sparkle 官方文档](https://sparkle-project.org/documentation/)。

更新源：`https://raw.githubusercontent.com/oceanix-pr/Memozia/updates/stable/appcast.xml`。更新器在隐私同意及持久数据库可用后启动，默认自动检查；用户可以关闭检查，安装始终需要确认。旧的无更新源安装需要手动安装一次修复版。

## 发布步骤

1. 用 `Scripts/bump_version.sh`、`Scripts/bump_build_number.sh` 分配新版本与递增构建号，准备 `docs/releases/<版本>.md`，运行 `xcodegen generate`。不覆盖公开 tag 或 Release 附件。
2. 运行本次相关测试、本地化检查和 Release 构建，保留 `Verify Embedded Frameworks`。公证包用 Developer ID 完成签名与公证；现有预览包需显式传入 `MEMOZIA_UNNOTARIZED_BUILD=YES` 并仅构建 arm64。不要把预览包标成已公证。
3. 提交源码并创建对应 `vX.Y.Z` tag。使用 Python 3 和 OpenSSL 3+（macOS 系统 LibreSSL 不支持 Ed25519，Homebrew OpenSSL 可用，也可设置 `OPENSSL` 路径）打包，输出目录必须不存在：

   ```sh
   python3 Scripts/package_update.py --app <Release/Memozia.app> \
     --output <独立输出目录> --sparkle-bin <Sparkle/bin>
   # 现有未公证预览分发显式追加 --unnotarized-test。
   ```

   脚本不修改原构建，校验实际版本、独立 feed、公钥、CPU 架构、ONNX 引用和签名；调用 Sparkle 从 Keychain 签名，并独立使用包内公钥验证 ZIP 签名。预览包在副本中保留 Hardened Runtime，使用现有本地签名的单应用库验证例外。
4. 用 `gh release create <tag> <updates/ZIP> <updates/appcast.xml> <updates/SHA256SUMS> --draft --prerelease --notes-file docs/releases/<版本>.md` 创建草稿。核对实际附件与启动、录音中的安装保护、保存失败和重启行为；说明未覆盖项。发布后附件不替换。
5. 公开 Release 后运行 `python3 Scripts/publish_update_feed.py <tag>` 只读验包，再运行同命令加 `--publish` 推进 `updates` 分支。脚本匿名下载公开附件，验证 ZIP 完整性、SHA-256、Ed25519、Bundle 版本与更新配置，并拒绝同构建替换或版本倒退；写入使用旧 blob SHA 防止并发覆盖。网络和权限错误必须停止，不能当作空 feed。
6. 匿名读取 stable feed 并核对版本、签名、URL 和包长度。未完成 feed 更新时，不宣称自动更新已发布。保留发布 ZIP、appcast、SHA256SUMS、构建与测试日志。

大附件网络较慢时，发布 feed 可加 `--verified-archive <实际下载的草稿 ZIP>`：复用已下载字节，但仍核对 GitHub 为公开附件计算的 SHA-256，匿名读取公开 ZIP 的字节范围和总长度，并完成全部本地验签。不能使用未与实际附件核对的构建目录文件。

9.7.0 是恢复更新源的首次引导版本：手动安装后才能接收后续版本。当前仅提供 arm64 预览包，不承诺 Intel 支持或 Apple 公证。
