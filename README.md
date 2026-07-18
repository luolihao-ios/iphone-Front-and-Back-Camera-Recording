# DualCapture（前后双摄同步录制）

DualCapture 是一个原生 iOS 示例项目：在**硬件支持多摄会话**的旧款 iPhone 上，同时采集前、后摄像头视频，并提供画中画或分屏的合成成片。

项目不依赖 iPhone 17 专属的系统相机入口；它使用 Apple AVFoundation 的 `AVCaptureMultiCamSession`。因此，能否真同步双摄由实际机型的多摄能力决定，应用会在运行时检测，不会以快速切换摄像头冒充同步录制。

## 当前功能

- 前后摄像头同步录制，使用一个系统麦克风音轨。
- 录制前切换“画中画”或“分屏”布局。
- 生成前摄独立视频、后摄独立视频和合成视频。
- 录制结束后由用户选择保存哪些文件到系统照片图库。
- 不支持双摄会话、相机/麦克风未授权或资源不足时显示提示。

## 环境与设备要求

- Xcode 16 或更高版本。
- iOS 17 或更高版本。
- 真机测试；模拟器没有可用的多摄硬件。
- 仅当 `AVCaptureMultiCamSession.isMultiCamSupported` 返回 `true`，且该设备允许前后摄组合时，才能录制。不同机型支持的分辨率和稳定性不同。

## 本地开发

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `project.yml` 生成，避免提交机器相关的 Xcode 工程文件。

```bash
brew install xcodegen
xcodegen generate
open DualCapture.xcodeproj
```

在 Xcode 的 **Signing & Capabilities** 中：

1. 选择你的 Apple ID Team。
2. 将 Bundle Identifier 改为你自己的唯一标识，例如 `com.yourname.dualcapture`。
3. 选择已连接的 iPhone 后运行。

首次运行时，请允许相机、麦克风和“添加到照片图库”权限。

## GitHub Actions 构建 IPA

仓库内置工作流 [build-ipa.yml](.github/workflows/build-ipa.yml)。推送到 `main` / `master`，或在 GitHub 的 **Actions → Build unsigned IPA → Run workflow** 手动触发后，工作流会：

1. 在 macOS Runner 安装 XcodeGen 并生成工程；
2. 使用 `iphoneos` SDK 编译 Release `.app`，不使用签名；
3. 将 `.app` 打包为 `DualCapture-unsigned.ipa`；
4. 在该次工作流的 Artifacts 中上传 `DualCapture-unsigned-ipa`。

这个 IPA **未签名，不能直接安装**；它的用途是交给本地工具使用你的账户签名。GitHub Runner 不应保存个人 Apple ID 密码、双重认证验证码或免费开发证书。

## 用爱思助手免费 Apple ID 签名安装测试

1. 从 GitHub Actions 该次成功构建的 Artifacts 下载并解压 `DualCapture-unsigned-ipa`。
2. 在 Windows 安装并打开爱思助手，使用数据线连接 iPhone，并按爱思助手的提示安装其移动端/驱动组件。
3. 在爱思助手的 IPA 签名或安装入口选择 `DualCapture-unsigned.ipa`，登录你自己的 Apple ID，并使用**免费开发者签名**。
4. 将已签名 IPA 安装到手机。若 iOS 提示不受信任，请在“设置 → 通用 → VPN 与设备管理”中信任对应开发者。
5. 打开应用，授予相机、麦克风和照片权限；在支持的 iPhone 上点击录制并验证三种视频能按选择保存。

### 免费签名限制

- 免费 Apple ID 签名的应用通常仅能使用有限时间（常见为 7 天），到期后需重新签名安装。
- 免费账户有设备数、App ID 和并发安装数量限制，具体限制由 Apple 和爱思助手当前规则决定。
- 仅应使用你自己的 Apple ID；不要把账号密码、验证码、证书或描述文件提交到 GitHub。

## 项目结构

```text
DualCapture/
  ContentView.swift        主界面与保存选择
  CameraManager.swift      多摄会话、权限与录制协调
  MovieRecorder.swift      单路视频/音频写入
  CameraPreview.swift      相机预览
  Models.swift             布局及文件模型
project.yml                XcodeGen 工程定义
.github/workflows/         GitHub Actions 构建流程
```

## 验收检查

- GitHub Actions 成功生成并上传 `DualCapture-unsigned.ipa`。
- 爱思助手能选择该 IPA 并用本地免费 Apple ID 完成签名和安装。
- 在支持设备上授权后，前后摄可以同时录制。
- 停止录制后，可以选择保存合成、前摄、后摄视频中的任意组合。
- 在不支持设备上，不会开始伪同步录制，而是显示明确提示。
