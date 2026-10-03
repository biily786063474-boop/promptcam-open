# PromptCam Open · 口播相机公开版

iOS 口播录制工具：单摄 / 前后双摄画中画、随朗读自动滚动的提词器、本地录制与字幕时间轴导出。

> **源码公开，仅限协议允许的非商业用途。** 本项目使用
> [PolyForm Noncommercial 1.0.0](LICENSE.md)，不是 OSI 定义的开源软件。
> 商用需要另行取得授权；请通过本仓库 Issue 联系维护者，勿提交密钥或个人资料。
> 教育、慈善、政府等机构的许可例外及具体授权范围以 LICENSE.md 原文为准。

## 包含什么

- 单摄录制、前后镜头切换、前置录制镜像。
- 支持设备上的前后双摄画中画，小窗拖动、比例及大小设置。
- 脚本库与编辑器；中英文脚本识别、逐字高亮与逐行跟读。
- 字号、行距、面板高度、背景暗度、阅读线和屏幕补光调节。
- 视频留存在 App 本地并尝试保存到系统相册；回看、分享及删除。
- 基于原稿和识别时间生成字幕，导出 SRT 与 JSON 时间轴。

**不包含**换脸 / 不露脸功能、角色素材、相关渲染代码及制作工具。
此仓库是独立公开版本，不包含私有版的 Git 历史、签名配置、商店上架工具或内部文档。

## 环境

- macOS、Xcode 26（本次构建验证使用 Xcode 26.6）。
- iOS 26.0+，iPhone。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)；Swift 5 语言模式。
- 仅使用 Apple 系统框架，无第三方运行时包、无需 API key 或服务器。

## 构建与运行

```sh
brew install xcodegen
xcodegen generate
open PromptCam.xcodeproj
```

在 Xcode 选择 `PromptCam` scheme 和目标设备后运行。
模拟器无需开发者签名；真机运行须在 Signing & Capabilities 中选择自己的 Team，
将 `org.example.promptcam.open` 换为自己的唯一 Bundle Identifier。
`PromptCam.xcodeproj` 为生成文件，不入库；持久化构建配置请编辑 `project.yml`。

命令行构建：

```sh
xcodebuild -project PromptCam.xcodeproj -scheme PromptCam \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

运行单元测试与公开版 UI 冒烟测试（替换设备 ID）：

```sh
xcrun simctl list devices available
xcodebuild -project PromptCam.xcodeproj -scheme PromptCam \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

## 使用与限制

1. 授予相机、麦克风权限，选一个脚本或新建脚本。
2. 开启跟读自动滚动并开始录制；语音识别仅在录制期间开启。
3. 首次使用某种语言时可能需要联网下载 Apple 识别模型；识别在设备本地执行。
4. 停止录制后从回看列表导出视频、字幕或时间轴。

双摄能力、摄像头和本地语音模型取决于设备。模拟器适合 UI / 算法测试，
不能替代真机的摄像头、双摄、音频、跟读和成片验证。
当前公开版的真机端到端录制与字幕同步尚未验证。

## 源码结构

| 目录 | 职责 |
| --- | --- |
| `PromptCam/Sources/Capture` | 单摄 / 双摄、合成、录制生命周期 |
| `PromptCam/Sources/Speech` | 音频重采样、设备端语音识别 |
| `PromptCam/Sources/Align` | 脚本分词、语言判断、跟读对齐 |
| `PromptCam/Sources/Timeline` | 字幕与时间轴 |
| `PromptCam/Sources/Model` | 脚本和录制索引 |
| `PromptCam/Sources/Views` | 相机、提词器、脚本库、回看及设置 |
| `PromptCamTests` | 分词、语言和对齐算法测试 |
| `PromptCamUITests` | 公开版界面冒烟测试 |

## 授权与贡献

使用、修改或分发须遵守 [LICENSE.md](LICENSE.md) 并保留 [NOTICE](NOTICE)。
公开源码不等于允许商用；也不意味着禁止所有机构使用，具体以许可证为准。
第三方组件、平台 SDK 和商标仍遵循各自条款。

欢迎报告问题。提交代码前请确认你有权提交该内容，并同意贡献按本项目许可证提供；
维护者若需将第三方贡献另行商业授权，须另行取得相应权利。
