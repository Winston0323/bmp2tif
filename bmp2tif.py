#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
批量 BMP 转 TIF 工具
用法: python bmp2tif.py [输入目录] [输出目录]
"""

import os
import sys
from pathlib import Path
try:
    from PIL import Image
except ImportError:
    print("请先安装 Pillow 库: pip install Pillow")
    sys.exit(1)


def convert_bmp_to_tif(input_dir: str, output_dir: str = None):
    """批量将 BMP 图片转换为 TIF 格式"""
    input_path = Path(input_dir).resolve()
    
    if output_dir:
        output_path = Path(output_dir).resolve()
    else:
        output_path = input_path
    
    # 创建输出目录
    output_path.mkdir(parents=True, exist_ok=True)
    
    # 查找所有 BMP 文件
    bmp_files = list(input_path.glob("*.bmp")) + list(input_path.glob("*.BMP"))
    
    if not bmp_files:
        print(f"在 {input_path} 中未找到 BMP 文件")
        return
    
    print(f"找到 {len(bmp_files)} 个 BMP 文件")
    print(f"输出目录: {output_path}")
    print("-" * 50)
    
    success_count = 0
    fail_count = 0
    
    for i, bmp_file in enumerate(bmp_files, 1):
        try:
            # 打开并转换图片
            img = Image.open(bmp_file)
            
            # 生成输出文件名
            output_file = output_path / (bmp_file.stem + ".tif")
            
            # 保存为 TIF 格式
            img.save(output_file, "TIFF")
            
            print(f"[{i}/{len(bmp_files)}] ✓ {bmp_file.name} -> {output_file.name}")
            success_count += 1
            
        except Exception as e:
            print(f"[{i}/{len(bmp_files)}] ✗ {bmp_file.name} 转换失败: {e}")
            fail_count += 1
    
    print("-" * 50)
    print(f"转换完成! 成功: {success_count}, 失败: {fail_count}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\n示例:")
        print("  python bmp2tif.py .                    # 转换当前目录的 BMP 文件")
        print("  python bmp2tif.py ./input              # 指定输入目录")
        print("  python bmp2tif.py ./input ./output     # 指定输入和输出目录")
        return
    
    input_dir = sys.argv[1]
    output_dir = sys.argv[2] if len(sys.argv) > 2 else None
    
    convert_bmp_to_tif(input_dir, output_dir)


if __name__ == "__main__":
    main()
