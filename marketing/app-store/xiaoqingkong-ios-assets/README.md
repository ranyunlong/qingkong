# 小晴空 · iOS 商店静态素材

语言：简体中文。更名与补充素材日期：2026-11-20。

名称统一为「小晴空」。这套图片沿用 App 的晴空蓝与原创小团子，使用当前 App 的真实模拟器截图。包括六组 iPhone 产品页截图、四张 Apple Watch 原生截图、产品页标题图、搜索结果创意图，以及现有 App 图标的无透明版本。另提供 iPhone Duo 内屏与外屏的排版草稿。

## 文件与上传位置

| 用途 | 文件或目录 | 像素尺寸 |
| --- | --- | --- |
| iPhone 大屏截图 | `screenshots/iphone-large/`，按 01–06 顺序 | 1320 × 2868，各 6 张 |
| iPhone 中屏截图 | `screenshots/iphone-medium/`，按 01–06 顺序 | 1206 × 2622，各 6 张 |
| Apple Watch 原生截图 | `screenshots/apple-watch/`，按 01–04 顺序 | 416 × 496，共 4 张 |
| 产品页标题图 Product page header | `creative/product-page-header-3840x1646.png` | 3840 × 1646 |
| 搜索结果创意图 Search results | `creative/search-results-3840x2560.png` | 3840 × 2560 |
| 现有 App 图标平面版 | `creative/app-icon-1024x1024.png` | 1024 × 1024 |

在 App Store Connect 中，把两套 iPhone 截图分别放入对应设备尺寸栏位。标题图、搜索结果图对应创意素材栏位；它们与常规的六张截图用途不同。图标平面版用于素材留档，不替代工程中的图标配置。

Watch 的四张图片分别展示健康概览、健康详情、心情和离线声音。图片直接采自 Apple Watch Series 11（46mm）模拟器，没有额外的营销标题和设备边框，保持手表原生截图尺寸。

`previews/overview.png` 是 iPhone 总览；`previews/watch-duo-overview.png` 是 Watch 与 Duo 草稿总览。`previews/*-safe-area.png` 标示安全区，`previews/*-safe-crop.png` 展示核心区域的裁切效果。`previews/watch-promo-*.png` 是与 iPhone 同风格的手表宣传排版。这些预览图不用于上传到 Watch 截图栏位。

本次交付均为静态图片。Apple 的 App Preview 视频是另一个素材类型，本次没有生成视频。

## iPhone Duo：排版已备，原生截图尚未完成

| 草稿 | 目录 | 横向像素尺寸 |
| --- | --- | --- |
| 外屏 | `drafts/iphone-duo-outer/`，共 6 张 | 2034 × 1398 |
| 内屏 | `drafts/iphone-duo-inner/`，共 6 张 | 2853 × 2007 |

本机安装的是 Xcode 26.6、iOS 26.5 模拟器，没有 iPhone Duo 设备类型或运行时。因此这 12 张图片是按照官方内外屏尺寸重新构图的排版稿，画面中展示的是现有 iPhone 界面，**不是 Duo 原生截图，也不表示 App 已完成 Duo 适配，请勿直接上传**。图片底部和文件名均已标记草稿，独立放在 `drafts/` 中。

在支持 Duo 的 Xcode 与模拟器上验证 App 的布局后，重新采集原生界面替换草稿中的界面区域，再移除草稿说明。仅改图片尺寸不能证明双屏或展开状态适配。Apple 官方当前说明：从 2027 年 4 月开始，使用 iOS 27.1 SDK 或更高版本的 App 需要提供 Duo 截图；实际要求以提交时的 App Store Connect 为准。

## 六张截图的顺序

1. 今日：了解身体，也关心自己。
2. 心情：每一种心情，都值得被接住。
3. 助眠：把今天，轻轻放下来。
4. 趋势：看见变化，找到自己的节奏。
5. 主题：换个风景，换种心情。
6. 隐私：你的日常，只属于你。

## 已执行的检查

- 通过独立 iPhone 17 Pro Max 模拟器运行当前 App，XCTest 截图流程通过，导出六个页面；没有重绘或拼造 App 内的功能界面。
- 健康数据通过 DEBUG 参数 `--demo-health` 展示。今日、趋势页保留 App 内的演示说明，并在营销画布中再次标识。搜索结果图也明确标识演示健康数值。
- 逐张检查最终 PNG 的尺寸、sRGB 色彩空间、RGB 通道和无 alpha 通道。
- 检查标题及界面元素的画布边界，检查标题图、搜索结果图核心元素的安全区边界，并导出安全区预览。
- 两套 iPhone 截图使用同一排版。中屏版等比缩放、居中适配，没有拉伸 App 界面。

详细导出记录见项目中的 `source/verification.json` 与 `source/additional-verification.json`。本次只制作本地文件，没有向 App Store Connect 上传。

## 发布前复核

这些图片基于当前开发构建。项目现有三个离线音频仍是约 16 秒的开发循环样本；应先按 `docs/Assets.md` 更换为有明确商用授权的正式音源，再用最终发布构建复核图片和实际体验。当前文案仅说明已实现的离线播放、循环与定时能力，没有宣称正式音源数量、时长或助眠疗效。

若最终构建的界面或功能发生变化，请保留本套排版并重新采图。健康参考功能不应描述为疾病诊断或疗效保证。

## Apple 官方规格来源

创意图规格和素材建议于 2026-11-19 读取；截图规格于 2026-11-20 再次读取，核对了 Watch 和 Duo 尺寸。实际上传以 App Store Connect 当前对应栏位为准。

- 创意素材规格：<https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications>
- 截图规格：<https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/>
- 素材建议：<https://developer.apple.com/app-store/asset-best-practices/>

标题图的核心安全区为 1646 × 661，起点 `(1097, 493)`。3840 × 2560 搜索结果图的核心安全区为 2168 × 1030，起点 `(836, 765)`。完整导出图不带安全框。

## 排版源文件

项目内的 `source/design.mjs` 保存共享视觉与文案，`source/render.mjs` 导出 iPhone 和创意图，`source/render-additional.mjs` 导出 Watch、Duo 排版稿和补充预览。`source/screens/`、`source/watch-raw/` 保留原始 App 截图。脚本使用本机 Chrome、Node.js、Playwright 和 sharp，并读取工程中的原始插画与照片。解压交付包即可使用成品，不需要运行脚本。
