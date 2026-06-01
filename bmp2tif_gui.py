#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
批量 BMP 转 TIF 工具 - GUI 版本 (独立运行)
"""

import os
import sys
import threading
from pathlib import Path
from datetime import datetime

try:
    from PIL import Image
except ImportError:
    print("请先安装 Pillow: pip install Pillow")
    sys.exit(1)

try:
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox, scrolledtext
except ImportError:
    print("GUI 依赖不可用")
    sys.exit(1)


class Bmp2TifApp:
    def __init__(self, root):
        self.root = root
        self.root.title("BMP 转 TIF 批量转换工具")
        self.root.geometry("700x620")
        self.root.resizable(True, True)
        self._stop_flag = False
        
        self._create_widgets()
        
    def _create_widgets(self):
        # 主框架
        main_frame = ttk.Frame(self.root, padding=15)
        main_frame.pack(fill=tk.BOTH, expand=True)
        
        # 标题
        title_label = ttk.Label(main_frame, text="BMP 转 TIF 批量转换工具",
                                font=("Microsoft YaHei", 16, "bold"))
        title_label.pack(pady=(0, 15))
        
        # 输入目录框架
        input_frame = ttk.LabelFrame(main_frame, text="输入目录 (包含 BMP 文件的文件夹)", padding=10)
        input_frame.pack(fill=tk.X, pady=(0, 10))
        
        self.input_var = tk.StringVar(value="")
        self.input_entry = ttk.Entry(input_frame, textvariable=self.input_var, width=60)
        self.input_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5))
        
        ttk.Button(input_frame, text="浏览...", command=self._browse_input).pack(side=tk.RIGHT)
        
        # 输出目录框架
        output_frame = ttk.LabelFrame(main_frame, text="输出目录 (可选，默认与输入目录相同)", padding=10)
        output_frame.pack(fill=tk.X, pady=(0, 10))
        
        self.output_var = tk.StringVar(value="")
        self.output_entry = ttk.Entry(output_frame, textvariable=self.output_var, width=60)
        self.output_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5))
        
        ttk.Button(output_frame, text="浏览...", command=self._browse_output).pack(side=tk.RIGHT)
        ttk.Button(output_frame, text="清空", command=lambda: self.output_var.set("")).pack(side=tk.RIGHT, padx=(0, 5))
        
        # 压缩 + 字节序选项框架
        opt_frame = ttk.LabelFrame(main_frame, text="TIF 输出选项", padding=10)
        opt_frame.pack(fill=tk.X, pady=(0, 10))
        
        self.compress_var = tk.StringVar(value="lzw")
        self.byteorder_var = tk.StringVar(value="interleaved")
        
        # 左侧：压缩方式
        compress_lab = ttk.Label(opt_frame, text="压缩方式:", font=("Microsoft YaHei", 9))
        compress_lab.grid(row=0, column=0, sticky=tk.W, padx=5)
        
        compress_options = [
            ("LZW",  "lzw"),
            ("ZIP",  "zip"),
            ("JPEG", "jpeg"),
            ("无",   "none")
        ]
        
        for col, (label, val) in enumerate(compress_options):
            rb = ttk.Radiobutton(opt_frame, text=label, value=val,
                                 variable=self.compress_var)
            rb.grid(row=1, column=col, sticky=tk.W, padx=8, pady=2)
        
        # 分隔
        ttk.Separator(opt_frame, orient=tk.VERTICAL).grid(row=0, column=4,
                rowspan=3, sticky=tk.NS, padx=15)
        
        # 右侧：像素排列方式
        px_lab = ttk.Label(opt_frame, text="像素排列:", font=("Microsoft YaHei", 9))
        px_lab.grid(row=0, column=5, sticky=tk.W, padx=5)
        
        px_info = ttk.Label(opt_frame, text="(Planar Configuration)", font=("Microsoft YaHei", 8),
                            foreground="gray")
        px_info.grid(row=0, column=6, sticky=tk.W)
        
        px_options = [
            ("Interleaved\nRGBRGB (默认)", "interleaved"),
            ("Per-Channel\nRRGGBB",         "perchannel")
        ]
        
        for col, (label, val) in enumerate(px_options):
            rb = ttk.Radiobutton(opt_frame, text=label, value=val,
                                 variable=self.byteorder_var)
            rb.grid(row=1, column=5+col, sticky=tk.W, padx=8, pady=2)
        
        # 底部：图像金字塔选项
        self.pyramid_var = tk.BooleanVar(value=False)
        pyramid_cb = ttk.Checkbutton(opt_frame, text="保存图像金字塔 (Image Pyramid)",
                                      variable=self.pyramid_var)
        pyramid_cb.grid(row=2, column=0, columnspan=4, sticky=tk.W, padx=8, pady=(8, 2))
        
        pyramid_info = ttk.Label(opt_frame, 
            text="在文件内嵌入多级分辨率缩略图，文件增大约 33%，适用于 GIS/医学影像/快速预览",
            font=("Microsoft YaHei", 8), foreground="gray")
        pyramid_info.grid(row=3, column=0, columnspan=8, sticky=tk.W, padx=8)
        
        # 按钮区域
        btn_frame = ttk.Frame(main_frame)
        btn_frame.pack(fill=tk.X, pady=(5, 10))
        
        self.convert_btn = ttk.Button(btn_frame, text="🔄 开始转换", 
                                       command=self._start_convert)
        self.convert_btn.pack(side=tk.LEFT)
        
        self.stop_btn = ttk.Button(btn_frame, text="⏹ 停止", command=self._stop_convert, state=tk.DISABLED)
        self.stop_btn.pack(side=tk.LEFT, padx=(10, 0))
        
        self.clear_btn = ttk.Button(btn_frame, text="清除日志", command=self._clear_log)
        self.clear_btn.pack(side=tk.LEFT, padx=(15, 0))
        
        # 进度条
        progress_frame = ttk.Frame(main_frame)
        progress_frame.pack(fill=tk.X, pady=(5, 10))
        
        self.progress_label = ttk.Label(progress_frame, text="", font=("Microsoft YaHei", 9))
        self.progress_label.pack(anchor=tk.W)
        
        self.progress = ttk.Progressbar(progress_frame, mode='determinate', length=100)
        self.progress.pack(fill=tk.X, pady=(3, 0))
        
        # 日志区域
        log_frame = ttk.LabelFrame(main_frame, text="运行日志", padding=5)
        log_frame.pack(fill=tk.BOTH, expand=True)
        
        self.log_text = scrolledtext.ScrolledText(log_frame, height=12, font=("Consolas", 9),
                                                   bg="#1e1e1e", fg="#d4d4d4", wrap=tk.WORD)
        self.log_text.pack(fill=tk.BOTH, expand=True)
        
        # 状态栏
        self.status_var = tk.StringVar(value="就绪")
        status_bar = ttk.Label(self.root, textvariable=self.status_var, relief=tk.SUNKEN,
                               anchor=tk.W, padding=(5, 2))
        status_bar.pack(fill=tk.X, side=tk.BOTTOM)
        
        # 初始化日志
        self._log("欢迎使用 BMP 转 TIF 批量转换工具！")
    
    def _browse_input(self):
        directory = filedialog.askdirectory(title="选择包含 BMP 文件的输入目录")
        if directory:
            self.input_var.set(directory)
            bmp_files = list(Path(directory).glob("*.bmp"))
            bmp_count = len(bmp_files)
            self._log(f"已选择: {directory} (发现 {bmp_count} 个 BMP 文件)")
    
    def _browse_output(self):
        directory = filedialog.askdirectory(title="选择输出目录")
        if directory:
            self.output_var.set(directory)
            self._log(f"输出目录: {directory}")
    
    def _log(self, message, level="info"):
        """添加日志信息"""
        timestamp = datetime.now().strftime("%H:%M:%S")
        color_map = {"info": "#d4d4d4", "success": "#4ec9b0", 
                     "warning": "#ce9178", "error": "#f14c4c"}
        
        self.log_text.insert(tk.END, f"[{timestamp}] {message}\n")
        self.log_text.see(tk.END)
        
        line_start = f"{self.log_text.index('end-2c').split('.')[0]}.0"
        self.log_text.tag_add(level, line_start, f"{line_start} lineend")
        self.log_text.tag_config(level, foreground=color_map.get(level, "#d4d4d4"))
    
    def _clear_log(self):
        self.log_text.delete(1.0, tk.END)
        self._log("日志已清除")
    
    def _start_convert(self):
        input_dir = self.input_var.get().strip()
        if not input_dir or not os.path.isdir(input_dir):
            messagebox.showwarning("警告", "请选择有效的输入目录！")
            return
        
        self._stop_flag = False
        thread = threading.Thread(target=self._run_convert, daemon=True)
        thread.start()
    
    def _stop_convert(self):
        self._stop_flag = True
    
    def _run_convert(self):
        """在后台线程中执行转换（内嵌逻辑）"""
        input_dir = self.input_var.get().strip()
        output_dir = self.output_var.get().strip() or None
        
        input_path = Path(input_dir).resolve()
        if output_dir:
            output_path = Path(output_dir).resolve()
        else:
            output_path = input_path
        
        self.root.after(0, lambda: self._log("-" * 50))
        self.root.after(0, lambda: [
            self.convert_btn.config(state=tk.DISABLED),
            self.stop_btn.config(state=tk.NORMAL),
            self.status_var.set("正在转换..."),
            self.progress.configure(value=0)
        ])
        
        try:
            # 查找所有 BMP 文件（Windows 不区分大小写，只需一个 glob）
            bmp_files = sorted(input_path.glob("*.bmp"))
            
            if not bmp_files:
                self.root.after(0, lambda: [
                    self._log("未找到任何 BMP 文件！", "error"),
                    self.status_var.set("无文件")
                ])
                return
            
            total = len(bmp_files)
            compression = self.compress_var.get()
            comp_label = {"lzw": "LZW", "zip": "ZIP/Deflate", "jpeg": "JPEG", "none": "不压缩"}.get(compression, compression)
            bo = self.byteorder_var.get()
            bo_label = {"interleaved": "Interleaved (RGBRGB)", "perchannel": "Per-Channel (RRGGBB)"}.get(bo, bo)
            pyramid = self.pyramid_var.get()
            pyramid_label = "是" if pyramid else "否"
            
            self.root.after(0, lambda: [
                self._log(f"找到 {total} 个 BMP 文件"),
                self._log(f"输出目录: {output_path}"),
                self._log(f"压缩方式: {comp_label}"),
                self._log(f"像素排列: {bo_label}"),
                self._log(f"图像金字塔: {pyramid_label}")
            ])
            
            os.makedirs(output_path, exist_ok=True)
            
            success_count = 0
            fail_count = 0
            
            for i, bmp_file in enumerate(bmp_files):
                if self._stop_flag:
                    self.root.after(0, lambda: [
                        self._log("⚠ 用户停止了转换", "warning"),
                        self.status_var.set("已停止")
                    ])
                    break
                
                try:
                    img = Image.open(bmp_file)
                    output_file = output_path / (bmp_file.stem + ".tif")
                    comp = self.compress_var.get()
                    bo = self.byteorder_var.get()
                    pyramid = self.pyramid_var.get()
                    
                    # 生成图像金字塔（多级缩略图）
                    append_imgs = []
                    if pyramid:
                        current = img
                        while min(current.size) >= 64:
                            new_size = (current.size[0] // 2, current.size[1] // 2)
                            if new_size[0] < 1 or new_size[1] < 1:
                                break
                            current = current.resize(new_size, Image.LANCZOS)
                            append_imgs.append(current.copy())
                    
                    comp_val = None if comp == "none" else comp
                    
                    # Per-channel: 拆分通道按 RR GG BB 排列保存
                    if bo == "perchannel" and img.mode == "RGB":
                        r, g, b = img.split()
                        # 金字塔也需要拆分通道
                        if pyramid and append_imgs:
                            r_layers = [p.split()[0] for p in append_imgs if p.mode == "RGB"]
                            g_layers = [p.split()[1] for p in append_imgs if p.mode == "RGB"]
                            b_layers = [p.split()[2] for p in append_imgs if p.mode == "RGB"]
                            r.save(output_file, format="TIFF",
                                   compression=comp_val,
                                   save_all=True,
                                   append_images=r_layers + g_layers + b_layers + [g, b])
                        else:
                            r.save(output_file, format="TIFF",
                                   compression=comp_val,
                                   save_all=True,
                                   append_images=[g, b])
                    else:
                        if pyramid and append_imgs:
                            img.save(output_file, format="TIFF",
                                     compression=comp_val,
                                     save_all=True,
                                     append_images=append_imgs)
                        else:
                            save_kwargs = {"format": "TIFF"}
                            if comp != "none":
                                save_kwargs["compression"] = comp
                            img.save(output_file, **save_kwargs)
                    
                    success_count += 1
                    self.root.after(0, lambda idx=i+1, tot=total, name=bmp_file.name: (
                        self._log(f"[{idx}/{tot}] ✓ {name}", "info"),
                        self.progress_label.configure(text=f"进度: {idx}/{tot} ({success_count} 成功)"),
                        self.progress.configure(value=(idx/tot)*100)
                    ))
                    
                except Exception as e:
                    fail_count += 1
                    self.root.after(0, lambda idx=i+1, name=bmp_file.name, err=str(e): (
                        self._log(f"[{idx}] ✗ {name}: {err}", "error")
                    ))
                
                # 小延迟避免 UI 卡顿
                import time; time.sleep(0.01)
            
            if not self._stop_flag:
                _s, _f = success_count, fail_count
                self.root.after(0, lambda s=_s, f=_f: [
                    self._log("-" * 50),
                    self._log(f"✓ 转换完成! 成功: {s}, 失败: {f}", "success"),
                    self.progress.configure(value=100),
                    self.progress_label.configure(text=f"完成: {s} 成功, {f} 失败"),
                    self.status_var.set("转换完成"),
                    messagebox.showinfo("完成", f"转换完成！\n成功: {s}\n失败: {f}")
                ] if s > 0 else None)
                
        except Exception as e:
            self.root.after(0, lambda err=str(e): [
                self._log(f"错误: {err}", "error"),
                self.status_var.set(f"出错: {err}")
            ])
        finally:
            self.root.after(0, lambda: [
                self.progress.stop(),
                self.convert_btn.config(state=tk.NORMAL),
                self.stop_btn.config(state=tk.DISABLED)
            ])


def main():
    root = tk.Tk()
    
    try:
        style = ttk.Style()
        available_themes = style.theme_names()
        for theme in ['clam', 'vista', 'xpnative']:
            if theme in available_themes:
                style.theme_use(theme)
                break
    except:
        pass
    
    app = Bmp2TifApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
