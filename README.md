# BMP to TIFF 在线转换器

这是一个纯前端静态网页应用。你可以直接打开 `index.html`，无需后端服务。

## 使用方法

1. 直接打开 `index.html`：
   - 在浏览器中打开文件，或使用本地静态服务器
2. 拖拽 BMP 文件到页面中，或点击区域选择 BMP 文件
3. 选择压缩模式：NONE / LZW / ZIP / JPEG
4. 若选择 JPEG，可设置质量值 4-12（12 最好）
5. 选择线程数，默认使用浏览器 CPU 核心数最大值
6. 点击“开始转换”，下载生成的 `converted_tifs.zip`

## 注意

- 该页面会在浏览器内将 BMP 转为 TIFF
- 使用了 `JSZip` 生成 ZIP 包
- 使用了 `UTIF.js` 进行 TIFF 编码
