# Third-Party Notices

Memozia 源代码采用 [MIT License](LICENSE)。第三方组件、数据文件和按需下载的模型适用各自的许可证。应用包的 `Contents/Resources` 收录本清单、Memozia 的 MIT 许可证和第三方许可文件。

## Swift Package 依赖

| 组件 | 锁定版本 | 许可证 | 权利人或项目 |
|---|---:|---|---|
| [argmax-oss-swift / WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) | 0.18.0 | MIT | Copyright (c) 2024 argmax, inc. |
| [EventSource](https://github.com/mattt/eventsource) | 1.5.1 | MIT | 完整许可证见 `MCP-LICENSES.txt` |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | MIT 及附带第三方条款 | Sparkle Project contributors；完整声明随 App 分发于 `Sparkle-LICENSE.txt` |
| [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) | 4.2.2 | MIT | Copyright (c) 2014 kishikawa katsumi |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | v1.13.6（`1cb484a`） | Apache-2.0 及随附第三方条款 | 应用使用上游 macOS shared no-TTS 构建 |
| [onnxruntime-libs](https://github.com/csukuangfj/onnxruntime-libs) | 1.27.1 | MIT（所分发 ONNX Runtime 二进制） | Microsoft Corporation and contributors |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 with Runtime Library Exception | Swift Argument Parser contributors |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.1 | Apache-2.0 | Copyright 2022 The SwiftASN1 Project |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 with Runtime Library Exception | 完整许可证见 `MCP-LICENSES.txt` |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 | Apache-2.0 with Runtime Library Exception | Swift Collections contributors |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.0 | Apache-2.0 | Copyright 2019 The SwiftCrypto Project |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | 2.3.6 | Apache-2.0 | swift-jinja contributors |
| [swift-log](https://github.com/apple/swift-log) | 1.16.2 | Apache-2.0 | 完整许可和声明见 `MCP-LICENSES.txt` |
| [SwiftNIO](https://github.com/apple/swift-nio) | 2.104.0 | Apache-2.0 及随附第三方条款 | 完整许可和声明见 `MCP-LICENSES.txt` 与 `Swift-Package-Notices.txt` |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | MIT / Apache-2.0 过渡许可 | 完整许可证见 `MCP-LICENSES.txt` |
| [Swift System](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 with Runtime Library Exception | 完整许可证见 `MCP-LICENSES.txt` |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.1.9 | Apache-2.0 | swift-transformers contributors |
| [yyjson](https://github.com/ibireme/yyjson) | 0.12.0 | MIT | Copyright (c) 2020 YaoYuan |

Swift 包的许可证与版权声明随应用分发于 `Sparkle-LICENSE.txt`、`MCP-LICENSES.txt` 和 [`LICENSES/Swift-Package-Notices.txt`](LICENSES/Swift-Package-Notices.txt)。[Apache-2.0 正文](LICENSES/Apache-2.0.txt)与这些声明一同收录。

### Sherpa-ONNX 与 ONNX Runtime 的内嵌组件

SwiftPM 提供 Sherpa 的 Swift 模块和头文件。构建阶段采用 [Sherpa v1.13.6 官方 macOS no-TTS 构建](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.6) 的 C API 动态库。框架修改、内嵌库的版权声明与 Eigen 对应版本的 MPL-2.0 源码下载地址见 [`LICENSES/Sherpa-ONNX-Notices.txt`](LICENSES/Sherpa-ONNX-Notices.txt)。

ONNX Runtime 自身采用 [MIT](LICENSES/ONNXRuntime-LICENSE.txt)，内嵌组件适用 [ONNX Runtime 上游第三方声明](LICENSES/ONNXRuntime-ThirdPartyNotices.txt)列出的条款。

## 随仓库分发的数据

`Memozia/Resources/ChineseDictionary/*.txt` 来源于 [OpenCC](https://github.com/BYVoid/OpenCC)，采用 Apache License 2.0。词典文件保留来源与许可头，应用包附带 [OpenCC 原始许可](LICENSES/OpenCC-LICENSE.txt)。

## 运行时下载的模型

内置图文推理使用 MIT 许可的 [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 与 [mlx-swift](https://github.com/ml-explore/mlx-swift)，对应许可证收录在 [Swift Package 声明](LICENSES/Swift-Package-Notices.txt)。分词复用已锁定的 swift-transformers；模型权重在用户确认后下载。

以下模型不存放在本仓库中，由用户在应用内下载或自行提供：

| 模型 | 来源 | 许可证 |
|---|---|---|
| Qwen3.5-2B（MLX 4 位，含视觉编码器） | [Qwen 官方模型卡](https://huggingface.co/Qwen/Qwen3.5-2B)、[MLX 转换权重](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit) | Apache-2.0，许可全文随应用分发 |
| WhisperKit Core ML 模型 | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) | MIT |
| pyannote segmentation 3.0 的 sherpa-onnx 导出 | [sherpa-onnx 发布资源](https://github.com/k2-fsa/sherpa-onnx/releases) | MIT（模型来源声明） |
| 3D-Speaker ERes2Net 声纹模型 | [sherpa-onnx 发布资源](https://github.com/k2-fsa/sherpa-onnx/releases) | Apache-2.0（模型来源项目） |

模型许可证可能随上游版本变化。分发预置模型或发布应用二进制前，必须对实际下载文件附带的许可证、模型卡和使用条件再次核验；本清单不替代上游条款。
