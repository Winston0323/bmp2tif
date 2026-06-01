#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
BMP 转 TIF 批量转换工具 - Web 版本
"""

import os
import io
import uuid
import copy
import shutil
import zipfile
import threading
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import FileResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image

app = FastAPI(title="BMP 转 TIF 批量转换工具")

# 任务存储
tasks = {}
tasks_lock = threading.Lock()

UPLOAD_DIR = Path("uploads")
OUTPUT_DIR = Path("outputs")
UPLOAD_DIR.mkdir(exist_ok=True)
OUTPUT_DIR.mkdir(exist_ok=True)


class AtomicCounter:
    """线程安全计数器"""
    def __init__(self, initial=0):
        self._value = initial
        self._lock = threading.Lock()

    def increment(self):
        with self._lock:
            self._value += 1
            return self._value

    @property
    def value(self):
        with self._lock:
            return self._value


def format_size(size_bytes):
    """格式化文件大小"""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    else:
        return f"{size_bytes / 1024 / 1024:.1f} MB"


def convert_single(bmp_path: Path, filename: str, comp: str, bo: str, pyramid: bool):
    """转换单个 BMP 文件"""
    img = Image.open(bmp_path)
    output_buf = io.BytesIO()

    # 生成图像金字塔
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
    stem = Path(filename).stem

    if bo == "perchannel" and img.mode == "RGB":
        r, g, b = img.split()
        if pyramid and append_imgs:
            r_layers = [p.split()[0] for p in append_imgs if p.mode == "RGB"]
            g_layers = [p.split()[1] for p in append_imgs if p.mode == "RGB"]
            b_layers = [p.split()[2] for p in append_imgs if p.mode == "RGB"]
            r.save(output_buf, format="TIFF", compression=comp_val,
                   save_all=True, append_images=r_layers + g_layers + b_layers + [g, b])
        else:
            r.save(output_buf, format="TIFF", compression=comp_val,
                   save_all=True, append_images=[g, b])
    else:
        if pyramid and append_imgs:
            img.save(output_buf, format="TIFF", compression=comp_val,
                     save_all=True, append_images=append_imgs)
        else:
            save_kwargs = {"format": "TIFF"}
            if comp != "none":
                save_kwargs["compression"] = comp
            img.save(output_buf, **save_kwargs)

    img.close()
    output_buf.seek(0)
    return f"{stem}.tif", output_buf.getvalue()


def _on_convert_done(task_id, future, filename, completed, total, results_list):
    """单个文件转换完成的回调，用线程安全计数器更新进度"""
    try:
        tif_name, tif_data = future.result()
        results_list.append((tif_name, tif_data))
        done = completed.increment()
        with tasks_lock:
            tasks[task_id]["progress"] = done
            tasks[task_id]["success"] = done
            tasks[task_id]["details"].append({"name": tif_name, "status": "ok"})
    except Exception as e:
        done = completed.increment()
        with tasks_lock:
            tasks[task_id]["progress"] = done
            tasks[task_id]["fail"] = total - done + (done - tasks[task_id].get("success", 0))
            tasks[task_id]["details"].append({"name": filename, "status": "error", "error": str(e)})


def run_task(task_id: str, file_list: list, comp: str, bo: str, pyramid: bool, max_workers: int):
    """后台执行转换任务"""
    total = len(file_list)
    print(f"[{task_id}] 任务开始: {total} 个文件, {max_workers} 线程, 压缩={comp}, 排列={bo}, 金字塔={pyramid}")

    # 读取阶段
    with tasks_lock:
        tasks[task_id]["status"] = "reading"
        tasks[task_id]["read_progress"] = 0
        tasks[task_id]["total_files"] = total
    print(f"[{task_id}] 阶段: 读取 0/{total}")

    bmp_files = []
    for i, (orig_name, src_path) in enumerate(file_list):
        bmp_files.append((orig_name, src_path))
        with tasks_lock:
            tasks[task_id]["read_progress"] = i + 1
    print(f"[{task_id}] 阶段: 读取完成 {total}/{total}")

    # 转换阶段
    with tasks_lock:
        tasks[task_id]["status"] = "processing"
        tasks[task_id]["progress"] = 0
        tasks[task_id]["success"] = 0
        tasks[task_id]["fail"] = 0
    print(f"[{task_id}] 阶段: 转换 0/{total}")

    # 线程安全计数器：已完成数
    completed = AtomicCounter(0)
    results = []

    executor = ThreadPoolExecutor(max_workers=max_workers)
    futures = {}
    for i, (filename, bmp_path) in enumerate(bmp_files):
        future = executor.submit(convert_single, bmp_path, filename, comp, bo, pyramid)
        futures[future] = (i, filename)

    # 逐个收集结果，用 AtomicCounter 保证计数线程安全
    for future in as_completed(futures):
        idx, filename = futures[future]
        try:
            tif_name, tif_data = future.result()
            results.append((tif_name, tif_data))
            done = completed.increment()
            with tasks_lock:
                tasks[task_id]["progress"] = done
                tasks[task_id]["success"] = done
                tasks[task_id]["fail"] = total - done
                tasks[task_id]["details"].append({"name": tif_name, "status": "ok"})
            print(f"[{task_id}] 阶段: 转换 {done}/{total} ✓ {tif_name}")
        except Exception as e:
            done = completed.increment()
            with tasks_lock:
                tasks[task_id]["progress"] = done
                tasks[task_id]["details"].append({"name": filename, "status": "error", "error": str(e)})
            print(f"[{task_id}] 阶段: 转换 {done}/{total} ✗ {filename} - {e}")

    # 修正最终 success/fail 计数
    fail_count = total - len(results)
    success_count = len(results)
    with tasks_lock:
        tasks[task_id]["success"] = success_count
        tasks[task_id]["fail"] = fail_count
    print(f"[{task_id}] 阶段: 转换完成 成功={success_count} 失败={fail_count}")

    # 转换全部完成，立即切到打包状态
    pack_total = len(results) * 2 + 1
    with tasks_lock:
        tasks[task_id]["status"] = "packing"
        tasks[task_id]["pack_progress"] = 0
        tasks[task_id]["pack_total"] = pack_total
    print(f"[{task_id}] 阶段: 打包 0/{pack_total}")

    task_output_dir = OUTPUT_DIR / task_id
    task_output_dir.mkdir(exist_ok=True)

    pack_done = 0
    for tif_name, tif_data in results:
        with open(task_output_dir / tif_name, "wb") as f:
            f.write(tif_data)
        pack_done += 1
        with tasks_lock:
            tasks[task_id]["pack_progress"] = pack_done
    print(f"[{task_id}] 阶段: 打包 写盘完成 {pack_done}/{pack_total}")

    # 创建 zip（逐文件更新进度）
    zip_path = OUTPUT_DIR / f"{task_id}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for tif_name, tif_data in results:
            zf.writestr(tif_name, tif_data)
            pack_done += 1
            with tasks_lock:
                tasks[task_id]["pack_progress"] = pack_done

    pack_done += 1  # ZIP finalize
    with tasks_lock:
        tasks[task_id]["pack_progress"] = pack_done

    zip_size = zip_path.stat().st_size
    print(f"[{task_id}] 阶段: 打包完成 ZIP={format_size(zip_size)}")

    # 关闭线程池
    executor.shutdown(wait=False)

    # 清理上传临时文件
    task_upload_dir = UPLOAD_DIR / task_id
    if task_upload_dir.exists():
        shutil.rmtree(task_upload_dir, ignore_errors=True)

    with tasks_lock:
        tasks[task_id]["status"] = "done"
        tasks[task_id]["zip_size"] = zip_size
    print(f"[{task_id}] 任务完成 ✓ 成功={success_count} 失败={fail_count} ZIP={format_size(zip_size)}")


@app.post("/api/convert")
async def convert(
    files: list[UploadFile] = File(...),
    compression: str = Form("lzw"),
    pixel_layout: str = Form("interleaved"),
    pyramid: bool = Form(False),
    workers: int = Form(os.cpu_count() or 4),
):
    """上传 BMP 文件并开始转换 - 先保存文件到磁盘，立即返回 task_id"""
    task_id = str(uuid.uuid4())[:8]
    task_upload_dir = UPLOAD_DIR / task_id
    task_upload_dir.mkdir(exist_ok=True)

    # 快速保存文件到磁盘（不等读取内容）
    file_list = []
    for f in files:
        if not f.filename.lower().endswith(".bmp"):
            continue
        dest = task_upload_dir / f.filename
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(dest, "wb") as out:
            shutil.copyfileobj(f.file, out)
        file_list.append((f.filename, str(dest)))

    if not file_list:
        shutil.rmtree(task_upload_dir, ignore_errors=True)
        raise HTTPException(status_code=400, detail="没有找到 BMP 文件")

    print(f"[{task_id}] 上传完成: {len(file_list)} 个 BMP 文件")

    with tasks_lock:
        tasks[task_id] = {
            "id": task_id,
            "status": "queued",
            "total_files": len(file_list),
            "progress": 0,
            "success": 0,
            "fail": 0,
            "details": [],
            "compression": compression,
            "pixel_layout": pixel_layout,
            "pyramid": pyramid,
            "workers": min(workers, os.cpu_count() or 1),
            "created_at": datetime.now().isoformat(),
        }

    thread = threading.Thread(
        target=run_task,
        args=(task_id, file_list, compression, pixel_layout, pyramid, tasks[task_id]["workers"]),
        daemon=True,
    )
    thread.start()

    return {"task_id": task_id, "total": len(file_list)}


@app.get("/api/task/{task_id}")
async def get_task(task_id: str):
    """查询任务状态"""
    with tasks_lock:
        if task_id not in tasks:
            raise HTTPException(status_code=404, detail="任务不存在")
        # 返回深拷贝，避免后台线程修改导致序列化不一致
        data = copy.deepcopy(tasks[task_id])
    return JSONResponse(content=data, headers={"Cache-Control": "no-store"})


@app.get("/api/download/{task_id}")
async def download_zip(task_id: str):
    """下载转换结果 ZIP"""
    zip_path = OUTPUT_DIR / f"{task_id}.zip"
    if not zip_path.exists():
        raise HTTPException(status_code=404, detail="文件不存在")
    print(f"[{task_id}] 下载 ZIP {format_size(zip_path.stat().st_size)}")
    return FileResponse(zip_path, filename="bmp2tif_converted.zip", media_type="application/zip")


@app.get("/api/download/{task_id}/{filename}")
async def download_single(task_id: str, filename: str):
    """下载单个转换结果"""
    file_path = OUTPUT_DIR / task_id / filename
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="文件不存在")
    return FileResponse(file_path, filename=filename, media_type="image/tiff")


@app.get("/api/cpu")
async def cpu_info():
    """返回 CPU 核心数"""
    return {"cpu_count": os.cpu_count() or 1}


# 静态文件
app.mount("/", StaticFiles(directory=str(Path(__file__).parent / "static"), html=True), name="static")
