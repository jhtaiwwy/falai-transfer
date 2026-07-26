const sharp = require('sharp');
const fs = require('fs');
const path = require('path');

// SVG文件路径
const svgPath = path.join(__dirname, 'AppScope/resources/base/media/icon.svg');

// 定义不同尺寸的PNG输出
const sizes = [
  { size: 512, name: 'icon_512x512.png', desc: '超高清（macOS、iOS）' },
  { size: 256, name: 'icon_256x256.png', desc: '高清（HarmonyOS、Android）' },
  { size: 128, name: 'icon_128x128.png', desc: '标准（Windows、Linux）' },
  { size: 64, name: 'icon_64x64.png', desc: '小图标' },
  { size: 48, name: 'icon_48x48.png', desc: 'Windows任务栏' },
  { size: 32, name: 'icon_32x32.png', desc: '系统托盘' },
  { size: 16, name: 'icon_16x16.png', desc: '最小图标' }
];

// 输出目录
const outputDir = path.join(__dirname, 'icons');

// 创建输出目录
if (!fs.existsSync(outputDir)) {
  fs.mkdirSync(outputDir, { recursive: true });
}

console.log('开始转换SVG到PNG...');
console.log(`源文件: ${svgPath}`);
console.log(`输出目录: ${outputDir}\n`);

// 转换不同尺寸的PNG
async function convertIcons() {
  try {
    // 读取SVG文件
    const svgBuffer = fs.readFileSync(svgPath);
    
    for (const { size, name, desc } of sizes) {
      const outputPath = path.join(outputDir, name);
      
      try {
        await sharp(svgBuffer)
          .resize(size, size)
          .png({ compressionLevel: 9, quality: 100 })
          .toFile(outputPath);
        
        const stats = fs.statSync(outputPath);
        const fileSize = stats.size;
        
        console.log(`✅ ${name.padEnd(20)} (${size}x${size}) - ${fileSize.toLocaleString()} bytes`);
      } catch (error) {
        console.log(`❌ ${name.padEnd(20)} - 转换失败: ${error.message}`);
      }
    }
    
    // 为HarmonyOS项目生成标准PNG
    const harmonyosPaths = [
      path.join(__dirname, 'AppScope/resources/base/media/icon.png'),
      path.join(__dirname, 'entry/src/main/resources/base/media/icon.png')
    ];
    
    console.log('\n为HarmonyOS项目生成标准PNG图标...');
    
    for (const harmonyosPath of harmonyosPaths) {
      try {
        await sharp(svgBuffer)
          .resize(256, 256)
          .png({ compressionLevel: 9, quality: 100 })
          .toFile(harmonyosPath);
        
        const stats = fs.statSync(harmonyosPath);
        const fileSize = stats.size;
        
        console.log(`✅ ${harmonyosPath}`);
        console.log(`   文件大小: ${fileSize.toLocaleString()} bytes`);
      } catch (error) {
        console.log(`❌ ${harmonyosPath} - 转换失败: ${error.message}`);
      }
    }
    
    console.log('\n✨ 转换完成！');
    console.log(`\n所有图标已保存到: ${outputDir}`);
    console.log('HarmonyOS项目图标已更新。');
    console.log('\n尺寸说明：');
    sizes.forEach(({ size, name, desc }) => {
      console.log(`  ${size}x${size} - ${desc}`);
    });
    
  } catch (error) {
    console.error('❌ 转换失败:', error.message);
    process.exit(1);
  }
}

convertIcons();
