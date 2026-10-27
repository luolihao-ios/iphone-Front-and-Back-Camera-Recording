# 商店宣传素材制作计划

> 执行方式：当前会话直接制作与检查，不修改相机业务代码。

## 已确认设计

用户选择带中文文案的宣传图。无法获取真实截图时，允许使用 AI 生成功能示意图；布局与按钮尽量保持当前软件一致，不把示意图称为真机截图，不宣传不存在的功能。

## 交付范围

- iPhone 五张、iPad 五张、iPhone Duo 展开屏五张。
- 五个主题：前后同录、可移动画中画、上下与左右分屏、双摄拍照、实时合成与自动保存。
- 产品页标题大图一张，搜索结果大图一张。
- 当前版本为 1.0.13 (7)，不修改版本与录制实现。
- 推荐统一使用深色底、白色标题与少量暖色强调，拍摄内容使用非用户肖像的生成旅行场景。
- 当前界面参考：右侧网格、全屏、上下、左右、画中画、形状、设置；下方相册、中央拍摄按钮、右侧旋转与视频／拍照切换；补光灯位于上方。

## 方法与取舍

纯截图忠实但当前缺少三类设备完整素材；用户已选择宣传图，并允许 AI 生成功能画面。本次采用生成宣传素材，视觉复核后标注其用途，不伪称真机采集。

## 制作与检查

- [x] 核对当前界面代码与设备适配测试。
- [x] 查询 Apple 官方截图、标题及搜索结果素材规格。
- [ ] 生成首张宣传样稿并检查中文、布局与功能。
- [ ] 按统一风格生成其余设备和功能主题。
- [ ] 检查最终像素尺寸、无透明通道、无错误功能承诺与文字截断；保存原图和提示词。
- [ ] 检查上传能力和目标版本；可用时上传素材库并关联产品信息页。不能操作时明确说明，不声称上传完成。

## Apple 规格来源

- https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
- https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications/
- https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets

标题图采用 3840×1646；搜索图采用 3840×2560。截图按平台允许尺寸输出；Duo 展开屏采用 2007×2853，iPad 采用 2064×2752，iPhone 采用 1206×2622。
