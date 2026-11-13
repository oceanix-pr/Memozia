# Third-Party Notices

Memozia 的源代码采用 MIT License，但以下第三方组件、数据文件和用户下载的模型适用各自的许可证。本文件依据当前 `Package.resolved` 与源码中的资源来源整理；升级依赖或模型时应同步复核。

## Swift Package 依赖

| 组件 | 锁定版本 | 许可证 | 权利人或项目 |
|---|---:|---|---|
| [argmax-oss-swift / WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) | 0.18.0 | MIT | Copyright (c) 2024 argmax, inc. |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | MIT 及附带第三方条款 | Sparkle Project contributors；完整声明随 App 分发于 `Sparkle-LICENSE.txt` |
| [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) | 4.2.2 | MIT | Copyright (c) 2014 kishikawa katsumi |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | revision `1cb484a` | Apache-2.0 | sherpa-onnx contributors |
| [onnxruntime-libs](https://github.com/csukuangfj/onnxruntime-libs) | 1.27.1 | MIT（所分发 ONNX Runtime 二进制） | Microsoft Corporation and contributors |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | Swift Argument Parser contributors |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.1 | Apache-2.0 | Copyright 2022 The SwiftASN1 Project |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 | Apache-2.0 | Swift Collections contributors |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.0 | Apache-2.0 | Copyright 2019 The SwiftCrypto Project |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | 2.3.6 | Apache-2.0 | swift-jinja contributors |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.1.9 | Apache-2.0 | swift-transformers contributors |
| [yyjson](https://github.com/ibireme/yyjson) | 0.12.0 | MIT | Copyright (c) 2020 YaoYuan |

依赖由 Swift Package Manager 拉取，完整且版本对应的许可证文本位于各包源码中。MIT 与 Apache-2.0 的通用许可证正文也分别收录在 [`LICENSES/MIT.txt`](LICENSES/MIT.txt) 和 [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)。

### SwiftASN1 NOTICE

> The SwiftASN1 Project — Copyright 2022 The SwiftASN1 Project. This product contains derivations of scripts from SwiftNIO and Swift OpenAPI Generator.

上游完整 NOTICE：<https://github.com/apple/swift-asn1/blob/main/NOTICE.txt>

### SwiftCrypto NOTICE

> The SwiftCrypto Project — Copyright 2019 The SwiftCrypto Project. This product contains test vectors from Google's Wycheproof project and derivations of files from SwiftNIO.

上游完整 NOTICE：<https://github.com/apple/swift-crypto/blob/main/NOTICE.txt>

## 随仓库分发的数据

`Memozia/Resources/ChineseDictionary/*.txt` 来源于 [OpenCC](https://github.com/BYVoid/OpenCC)，采用 Apache License 2.0。词典文件保留了来源与许可证头；Apache-2.0 正文见 [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)。

## 运行时下载的模型

以下模型不存放在本仓库中，由用户在应用内下载或自行提供：

| 模型 | 来源 | 许可证 |
|---|---|---|
| WhisperKit Core ML 模型 | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) | MIT |
| pyannote segmentation 3.0 的 sherpa-onnx 导出 | [sherpa-onnx 发布资源](https://github.com/k2-fsa/sherpa-onnx/releases) | MIT（模型来源声明） |
| 3D-Speaker ERes2Net 声纹模型 | [sherpa-onnx 发布资源](https://github.com/k2-fsa/sherpa-onnx/releases) | Apache-2.0（模型来源项目） |

模型许可证可能随上游版本变化。分发预置模型或发布应用二进制前，必须对实际下载文件附带的许可证、模型卡和使用条件再次核验；本清单不替代上游条款。
