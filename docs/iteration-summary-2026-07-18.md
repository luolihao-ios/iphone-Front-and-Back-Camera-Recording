# DualCapture 首次迭代总结

## 目标与结果

目标是在非 iPhone 17 的 iPhone 上实现真实的前后摄同步录制，并支持 GitHub 自动构建 IPA、爱思助手使用免费 Apple ID 签名安装及真机测试。

本次已完成并在 **iPhone 11** 上验证：应用可显示前后摄画面、同步录制、保存独立前摄/后摄/合成视频；通过爱思助手免费 Apple ID 签名安装成功；竖屏、画中画、上下分屏与反复切换主次画面均已验收通过。

最终交付版本：`1.0.4 (5)`。

## 功能实现

- 原生 iOS：SwiftUI + AVFoundation，最低 iOS 17。
- 使用 `AVCaptureMultiCamSession` 同时采集前摄、后摄与单一系统麦克风音轨；启动前以 `isMultiCamSupported` 检测真实硬件能力。
- 每次录制生成前摄独立视频、后摄独立视频和合成视频；结束后由用户勾选保存到系统照片图库的文件。
- 支持两种合成布局：画中画、上下分屏。录制前可点击任一预览画面切换主次：
  - 画中画：主画面全屏，次画面为右上角小窗。
  - 分屏：主画面在上，次画面在下。
  - 可不限次数交换；录制开始后锁定布局与主次关系，使导出成片与录制前预览一致。
- App 和视频输出均固定为 portrait，避免竖屏拿机时预览或录制横置。

## 构建与签名流程

- 以 `project.yml` 作为 XcodeGen 工程定义，不提交机器相关的 `.xcodeproj`。
- GitHub Actions 工作流：生成工程 → 编译 iPhone Release app（不签名）→ 运行 iOS Simulator 单元测试 → 将 `Payload/DualCapture.app` 用标准 ZIP 打包为 IPA → 上传 Artifact。
- 已修正 IPA 兼容性：归档根目录为 `Payload/`，而非 `ipa/Payload/`；补齐 `CFBundleShortVersionString` 与 `CFBundleVersion`；最终 IPA 已做 ZIP 完整性与 bundle 信息检查。
- GitHub 仓库：<https://github.com/luolihao-aicode/iphone-Front-and-Back-Camera-Recording>。
- 真机安装：下载 Actions Artifact，在爱思助手中选择 IPA 签名，用本机免费 Apple ID 签名并安装；账号密码和验证码不进入仓库或工作流。

## 问题与修复记录

| 现象 | 根因 | 修复 |
| --- | --- | --- |
| CI 链接后找不到 `Info.plist` | XcodeGen 未启用自动 Info.plist | 启用 `GENERATE_INFOPLIST_FILE` |
| 爱思助手提示 IPA 文件损坏 | IPA 根目录错误，且缺少版本元数据 | 标准 ZIP 打包 `Payload/`，增加版本号 |
| iPhone 11 黑屏且停止时录制失败 | 视频/音频输出 delegate 为临时对象，未被强引用，帧回调中断 | 引入 `CaptureDelegateRegistry` 持有三个 delegate |
| 竖屏显示为横屏 | App 未限制方向，视频连接未指定方向 | App 只支持 portrait；视频连接设为 `.portrait` |
| 小画面放大后原大画面被覆盖 | 次画面没有移动到 Core Animation 最上层 | 每次布局均重排主层/次层，次层在顶层 |
| 只能交换一次 | 全屏主层先参与命中判断，覆盖了小窗的点击坐标 | 命中检测先检查次画面，再检查主画面 |
| 分屏为左右结构 | 初始布局和合成视频均按左右计算 | 预览与 `VideoComposer` 同步改为上下结构 |

## 测试与验证

- GitHub Actions 多次执行通过：XcodeGen 生成、iPhoneOS 编译、Simulator 单元测试、IPA 打包和 Artifact 上传。
- 单元测试覆盖：
  - 输出 delegate 在调用方释放后仍被 registry 强引用。
  - 前摄为主画面时后摄成为次画面。
  - 次画面层位于主画面层之上。
  - 点击命中优先处理次画面，从而允许连续交换。
- IPA 验证：ZIP 校验通过；包含 `Payload/DualCapture.app`；最终 bundle 版本为 `1.0.4 (5)`。
- 真机验证：用户在 iPhone 11 上通过爱思助手免费 Apple ID 签名安装，并确认前后摄显示、录制、竖屏、主次反复切换和上下分屏均通过。

## 已知边界

- 仅在系统支持 `AVCaptureMultiCamSession` 且允许该前后摄组合的设备上提供真实双摄；不支持的设备不会伪造同步录像。
- 免费 Apple ID 签名受 Apple 的有效期和设备/App ID 数量限制，可能需要定期重新签名。
- 合成视频的布局在录制开始后固定；录制中不允许切换主次，以确保时间轴与导出行为确定。
