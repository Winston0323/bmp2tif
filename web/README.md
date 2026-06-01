# BMP 转 TIF 批量转换工具 - Web 版

基于 FastAPI 的 BMP → TIF 批量转换工具，支持浏览器上传、实时进度跟踪、自动下载。

## 功能特性

- 批量上传 BMP 文件并转换为 TIF 格式
- 支持压缩方式：LZW / ZIP / JPEG / 无压缩
- 支持像素排列：Interleaved (RGBRGB) / Per-Channel (RRGGBB)
- 可选图像金字塔（Image Pyramid）
- 多线程并行转换，自动使用最大 CPU 核心数
- 五阶段实时进度：上传 → 读取 → 转换 → 打包 → 下载
- 支持文件夹上传（保留子目录结构）

## 环境要求

- Python 3.8+
- 依赖库见 `requirements.txt`

## 安装步骤

```bash
cd web
pip install -r requirements.txt
```

## 启动服务器

```bash
cd web
python -m uvicorn app:app --host 127.0.0.1 --port 8001
```

启动后在浏览器中访问：**http://localhost:8001**

> ⚠️ 不要使用 `0.0.0.0` 作为浏览器地址，请使用 `localhost` 或 `127.0.0.1`。

如需局域网内其他设备访问，启动时使用 `--host 0.0.0.0`，但浏览器地址栏仍输入服务器的实际 IP（如 `http://192.168.1.100:8001`）。

## 项目结构

```
web/
├── app.py              # FastAPI 后端主程序
├── requirements.txt    # Python 依赖
├── README.md           # 本文件
├── static/
│   └── index.html      # 前端页面
├── uploads/            # 上传临时目录（自动创建，运行时生成）
└── outputs/            # 转换输出目录（自动创建，运行时生成）
```

## API 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/convert` | 上传 BMP 文件并启动转换 |
| GET  | `/api/task/{task_id}` | 查询任务状态与进度 |
| GET  | `/api/download/{task_id}` | 下载转换结果 ZIP |
| GET  | `/api/download/{task_id}/{filename}` | 下载单个 TIF 文件 |
| GET  | `/api/cpu` | 获取 CPU 核心数 |
