# SoftRouter 图标

`SoftRouterIcon.png` 是由内置 imagegen 工具生成的项目图标原稿：深蓝圆角底板、连接无线与有线端点的 S 形路径。保留透明通道与原始 C2PA 来源信息；未添加文字，也未使用外部品牌图形。

构建脚本使用 macOS 自带 `sips` 与 `iconutil` 生成标准尺寸的 `SoftRouter.icns`，同时将原稿放入应用资源供窗口展示。缩放是构建产物处理，原稿保持不变；生成的 ICNS 不等同于原始 PNG 的来源签名。

发布检查只允许这一精确路径的 PNG，校验尺寸、像素数据、块校验和及允许的元数据。C2PA 块固定到本次已审阅的摘要；替换图标时需要同时审阅新来源信息，而非放宽全部二进制文件的发布限制。

## 生成提示词

```text
Use case: logo-brand. Asset type: production macOS app icon for SoftRouter, a small app that shares a Mac's Wi-Fi connection through Ethernet. Create one elegant, distinctive icon, square 1024 by 1024 composition. A softly rounded square tile contains a bold, simple S-shaped routed connection with two rounded endpoint nodes, suggesting a bridge from wireless to wired networking. Restrained premium native macOS feel, tactile frosted glass and satin ceramic, subtle depth, crisp silhouette that remains recognizable at 32 pixels, calm cool blue/teal accent against a deep ink blue tile with a luminous near-white central routing mark. Soft even studio light, front-facing centered composition, balanced generous internal spacing, tiny controlled highlight, no dramatic glow. Tile fills about 88 percent of canvas; true transparent pixels around its rounded outer silhouette. The tile itself is opaque. No words, letters as typography, slogans, watermark, mockup, extra icons, surrounding objects, interface screenshot, border frame or background scene. Deliver the icon only.
```
