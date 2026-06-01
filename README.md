# bmp2tif

批量 BMP 转 TIF 工具，支持 GUI 和命令行两种使用方式。

## 功能

- 批量将 BMP 图片转换为 TIF (TIFF) 格式
- 支持多种压缩方式：**LZW**（默认）、**ZIP/Deflate**、**JPEG**、不压缩
- GUI 图形界面，带进度显示和日志
- 可中途停止转换

## 使用方式

### GUI 版本（推荐）

双击 `bmp2tif_gui.exe` 运行：

1. 选择包含 BMP 文件的输入目录
2. （可选）选择输出目录，默认与输入目录相同
3. 选择 TIF 压缩方式
4. 点击「开始转换」

### 命令行版本

```bash
# 转换当前目录
bmp2tif.exe .

# 指定输入目录
bmp2tif.exe ./input_folder

# 指定输入和输出目录
bmp2tif.exe ./input_folder ./output_folder
```

## 压缩方式说明

| 方式 | 说明 |
|------|------|
| **LZW** | 无损压缩，兼容性最好 |
| **ZIP / Deflate** | 无损压缩，压缩率较高 |
| **JPEG** | 有损压缩，文件最小，适合照片 |
| **不压缩** | 文件最大，质量不变 |

## 依赖

- Python 3.x
- Pillow (`pip install Pillow`)

## 构建

```bash
# GUI 版本
pyinstaller --onefile --windowed --name bmp2tif_gui bmp2tif_gui.py

# 命令行版本
pyinstaller --onefile --console --name bmp2tif bmp2tif.py
```
