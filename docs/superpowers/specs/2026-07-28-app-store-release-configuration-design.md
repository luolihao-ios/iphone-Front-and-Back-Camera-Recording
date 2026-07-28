# App Store 正式发布配置设计

## 目标

将 DualCapture 从自由签名测试配置切换为可用于 App Store 归档与上传的正式工程配置；不改变任何双摄录制、视频保存或界面功能。

## 配置范围

- Bundle ID 固定为 `com.luolihao.dualcapture`，与 Apple Developer 中注册的 Explicit App ID 保持完全一致。
- 开发团队固定为 `5J4K4PZHCV`，继续使用 Xcode 自动签名。
- 市场版本由 `1.0.4` 升至 `1.0.5`，构建号由 `5` 升至 `6`。
- 保持 iOS 17.0 最低系统版本、仅 iPhone、竖屏，以及现有相机、麦克风、照片图库权限说明。

## 非目标

- 不上传 IPA、不创建 App Store Connect 应用记录、不提交审核。
- 不修改功能代码、录制逻辑、隐私数据处理范围或 Capability。

## 验证方式

用 XcodeGen 从 `project.yml` 生成工程，并对 `DualCapture` scheme 执行 iPhone Simulator 的构建与单元测试。正式签名和上传需在具备 Apple 分发证书与 App Store Connect 权限的 Mac/Xcode 环境中完成。
