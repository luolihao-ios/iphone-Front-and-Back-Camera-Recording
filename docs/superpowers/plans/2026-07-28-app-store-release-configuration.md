# App Store 正式发布配置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 DualCapture 的工程标识和版本切换为可创建 App Store 归档的正式发布配置。

**Architecture:** 仅修改 XcodeGen 的单一配置源 `project.yml`。XcodeGen 生成的工程会继承 Bundle ID、开发团队和版本号；应用功能代码与 Info.plist 权限键保持不变。

**Tech Stack:** XcodeGen、Xcode、Swift 5、XCTest。

## Global Constraints

- `PRODUCT_BUNDLE_IDENTIFIER` 必须为 `com.luolihao.dualcapture`。
- `DEVELOPMENT_TEAM` 必须为 `5J4K4PZHCV`。
- `MARKETING_VERSION` 必须为 `1.0.5`，`CURRENT_PROJECT_VERSION` 必须为 `6`。
- 不修改任何相机录制功能、权限用途文案、Capability 或部署版本。

---

### Task 1: 更新并验证 App Store 发布配置

**Files:**
- Modify: `project.yml`
- Test: 生成的 `DualCapture.xcodeproj`（临时构建产物）

**Interfaces:**
- Consumes: Apple Developer Explicit App ID `com.luolihao.dualcapture` 与团队 ID `5J4K4PZHCV`。
- Produces: Xcode 自动签名可识别的 iOS App Store 归档配置。

- [ ] **Step 1: 修改配置源**

将 `project.yml` 中的设置改为：

```yaml
MARKETING_VERSION: 1.0.5
CURRENT_PROJECT_VERSION: 6
PRODUCT_BUNDLE_IDENTIFIER: com.luolihao.dualcapture
DEVELOPMENT_TEAM: 5J4K4PZHCV
```

- [ ] **Step 2: 生成 Xcode 工程**

Run: `xcodegen generate`

Expected: 生成 `DualCapture.xcodeproj`，且无配置错误。

- [ ] **Step 3: 构建并运行单元测试**

Run: `xcodebuild test -project DualCapture.xcodeproj -scheme DualCapture -destination 'platform=iOS Simulator,name=iPhone 16'`

Expected: 构建成功，全部 XCTest 通过。

- [ ] **Step 4: 提交配置与文档**

```bash
git add project.yml docs/superpowers
git commit -m "chore: configure app store release identity"
```
