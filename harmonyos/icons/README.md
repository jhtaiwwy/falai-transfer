# 应用图标资源

本目录包含从SVG转换生成的PNG格式图标，适用于不同操作系统和场景。

## 图标列表

| 文件名 | 尺寸 | 文件大小 | 适用场景 |
|--------|------|----------|----------|
| icon_512x512.png | 512×512 | ~17 KB | macOS、iOS应用图标 |
| icon_256x256.png | 256×256 | ~8 KB | HarmonyOS、Android应用图标 |
| icon_128x128.png | 128×128 | ~4 KB | Windows、Linux应用图标 |
| icon_64x64.png | 64×64 | ~2 KB | 小图标、列表视图 |
| icon_48x48.png | 48×48 | ~2 KB | Windows任务栏图标 |
| icon_32x32.png | 32×32 | ~1.5 KB | 系统托盘图标 |
| icon_16x16.png | 16×16 | ~0.7 KB | 最小图标、favicon |

## 设计特点

- 🎨 **现代渐变**：蓝紫色渐变背景，时尚优雅
- 📄 **主题明确**：文件传输主题，两个文件图标+传输箭头
- ⭐ **星光点缀**：四角星、六角星、光芒射线等装饰元素
- ✨ **发光效果**：柔和光晕效果，增强视觉层次
- 🎯 **细节丰富**：文件折角、内容线条、装饰圆点

## 使用建议

### HarmonyOS
- 使用 `icon_256x256.png` 或 SVG 格式
- 已自动配置到项目资源中

### Android
- 建议使用 `icon_192x192.png`（可从512尺寸缩放）
- 放置在 `mipmap-*` 目录中

### iOS / macOS
- 使用 `icon_512x512.png`
- 需要提供 @2x 和 @3x 版本

### Windows
- 使用 `icon_256x256.png` 作为应用图标
- `icon_48x48.png` 用于任务栏
- `icon_32x32.png` 用于系统托盘

### Web
- `icon_16x16.png` 作为 favicon
- `icon_128x128.png` 作为高分辨率 favicon

## 源文件

所有PNG图标均从以下SVG源文件生成：
- `../AppScope/resources/base/media/icon.svg`

如需修改图标，建议编辑SVG源文件，然后重新运行转换脚本。

## 重新生成

如需重新生成PNG图标，运行以下命令：

```bash
npm run convert
```

或直接运行：

```bash
node convert_svg_to_png.js
```

---

**设计工具**：SVG + Node.js (sharp)  
**生成时间**：2026-07-20  
**版本**：1.0.0
