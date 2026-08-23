#!/usr/bin/env python3
"""GUI to rebuild Flutter release targets and the Windows MSI."""

from __future__ import annotations

import os
import queue
import shutil
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
PAYLOAD = ROOT / "build" / "windows" / "x64" / "runner" / "Release"
EXE = PAYLOAD / "bmp2tif_app.exe"
APK = ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
AAB = ROOT / "build" / "app" / "outputs" / "bundle" / "release" / "app-release.aab"
WEB = ROOT / "build" / "web"
MSI = DIST / "Bmp2Tif.msi"
WIXS = ROOT / "installer" / "Package.wxs"
WIX_GUESS = Path(r"C:\Program Files\WiX Toolset v7.0\bin\wix.exe")


def which(name: str) -> str | None:
    return shutil.which(name)


def find_wix() -> Path | None:
    wix = which("wix")
    if wix:
        return Path(wix)
    if WIX_GUESS.is_file():
        return WIX_GUESS
    return None


class RebuildGui(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("BMP → TIFF — Rebuild")
        self.geometry("780x560")
        self.minsize(640, 440)

        self._log_q: queue.Queue[str] = queue.Queue()
        self._busy = False
        self._vars = {
            "windows": tk.BooleanVar(value=True),
            "apk": tk.BooleanVar(value=False),
            "aab": tk.BooleanVar(value=False),
            "web": tk.BooleanVar(value=False),
            "msi": tk.BooleanVar(value=True),
        }
        self._reuse_windows = tk.BooleanVar(value=False)

        self._build_ui()
        self.after(80, self._drain_log)

    def _build_ui(self) -> None:
        pad = {"padx": 12, "pady": 8}
        ttk.Label(self, text="Release rebuild", font=("Segoe UI", 14, "bold")).pack(
            anchor="w", **pad
        )

        box = ttk.LabelFrame(self, text="Targets")
        box.pack(fill="x", padx=12, pady=(0, 8))

        rows = [
            ("windows", "Windows  (.exe in build/windows/...)"),
            ("apk", "Android APK"),
            ("aab", "Android App Bundle (.aab)"),
            ("web", "Web  (base-href /bmp2tif/)"),
            ("msi", "Windows MSI installer  (needs WiX + Windows build)"),
        ]
        for key, label in rows:
            ttk.Checkbutton(box, text=label, variable=self._vars[key]).pack(
                anchor="w", padx=10, pady=2
            )

        ttk.Checkbutton(
            box,
            text="Reuse existing Windows build for MSI (skip flutter build windows)",
            variable=self._reuse_windows,
        ).pack(anchor="w", padx=10, pady=(4, 8))

        btns = ttk.Frame(self)
        btns.pack(fill="x", padx=12, pady=(0, 8))
        self._go = ttk.Button(btns, text="Build selected", command=self._start)
        self._go.pack(side="left")
        ttk.Button(btns, text="Open dist folder", command=self._open_dist).pack(
            side="left", padx=8
        )
        ttk.Button(btns, text="Open Windows Release folder", command=self._open_release).pack(
            side="left"
        )

        log_frame = ttk.LabelFrame(self, text="Log")
        log_frame.pack(fill="both", expand=True, padx=12, pady=(0, 12))
        self._log = tk.Text(log_frame, wrap="word", height=18, font=("Consolas", 10))
        scroll = ttk.Scrollbar(log_frame, command=self._log.yview)
        self._log.configure(yscrollcommand=scroll.set, state="disabled")
        self._log.pack(side="left", fill="both", expand=True, padx=(8, 0), pady=8)
        scroll.pack(side="right", fill="y", pady=8, padx=(0, 8))

        self._status = ttk.Label(self, text=self._ready_status())
        self._status.pack(fill="x", padx=12, pady=(0, 10))

    def _ready_status(self) -> str:
        flutter = "Flutter OK" if which("flutter") else "Flutter not on PATH"
        wix = "WiX OK" if find_wix() else "WiX not found"
        return f"{flutter}  ·  {wix}  ·  {ROOT}"

    def log(self, line: str) -> None:
        self._log_q.put(line)

    def _drain_log(self) -> None:
        try:
            while True:
                line = self._log_q.get_nowait()
                self._log.configure(state="normal")
                self._log.insert("end", line + "\n")
                self._log.see("end")
                self._log.configure(state="disabled")
        except queue.Empty:
            pass
        self.after(80, self._drain_log)

    def _start(self) -> None:
        if self._busy:
            return
        selected = [k for k, v in self._vars.items() if v.get()]
        if not selected:
            messagebox.showinfo("Rebuild", "Select at least one target.")
            return
        if not which("flutter") and any(k != "msi" for k in selected):
            messagebox.showerror("Rebuild", "flutter is not on PATH.")
            return
        if "msi" in selected and not find_wix():
            messagebox.showerror(
                "Rebuild",
                "WiX CLI not found.\nInstall with:\n  winget install --id WiXToolset.WiXCLI -e",
            )
            return

        self._busy = True
        self._go.configure(state="disabled")
        self._status.configure(text="Building…")
        self._log.configure(state="normal")
        self._log.delete("1.0", "end")
        self._log.configure(state="disabled")
        threading.Thread(target=self._run, args=(selected,), daemon=True).start()

    def _run(self, selected: list[str]) -> None:
        ok = True
        outputs: list[str] = []
        try:
            os.chdir(ROOT)
            need_windows = "windows" in selected or (
                "msi" in selected and not self._reuse_windows.get()
            )
            if "msi" in selected and self._reuse_windows.get() and not EXE.is_file():
                self.log("Existing Windows exe missing — will build Windows first.")
                need_windows = True

            jobs: list[tuple[str, list[str], Path | None]] = []
            if need_windows:
                jobs.append(("Windows", ["flutter", "build", "windows", "--release"], EXE))
            if "apk" in selected:
                jobs.append(("Android APK", ["flutter", "build", "apk", "--release"], APK))
            if "aab" in selected:
                jobs.append(
                    ("Android App Bundle", ["flutter", "build", "appbundle", "--release"], AAB)
                )
            if "web" in selected:
                jobs.append(
                    (
                        "Web",
                        ["flutter", "build", "web", "--release", "--base-href", "/bmp2tif/"],
                        WEB / "index.html",
                    )
                )

            for name, cmd, artifact in jobs:
                if not self._exec(name, cmd):
                    ok = False
                    break
                if artifact and artifact.exists():
                    outputs.append(str(artifact))

            if ok and "msi" in selected:
                if not self._build_msi():
                    ok = False
                elif MSI.is_file():
                    outputs.append(str(MSI))

            if ok and "apk" in selected and APK.is_file():
                DIST.mkdir(parents=True, exist_ok=True)
                dest = DIST / "app-release.apk"
                shutil.copy2(APK, dest)
                self.log(f"Copied APK -> {dest}")
                outputs.append(str(dest))
        except Exception as exc:
            ok = False
            self.log(f"ERROR: {exc}")

        self.log("")
        if ok:
            self.log("All selected targets finished.")
            for p in outputs:
                self.log(f"  {p}")
        else:
            self.log("Stopped with errors.")
        self.after(0, lambda: self._done(ok))

    def _exec(self, name: str, cmd: list[str]) -> bool:
        self.log(f"=== {name} ===")
        self.log(" ".join(cmd))
        try:
            kwargs: dict = dict(
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            if os.name == "nt" and cmd[0] == "flutter":
                kwargs["shell"] = True
                proc = subprocess.Popen(subprocess.list2cmdline(cmd), **kwargs)
            else:
                proc = subprocess.Popen(cmd, **kwargs)
        except FileNotFoundError:
            self.log(f"Command not found: {cmd[0]}")
            return False
        assert proc.stdout is not None
        for line in proc.stdout:
            self.log(line.rstrip("\n"))
        code = proc.wait()
        self.log(f"[{name}] exit {code}")
        self.log("")
        return code == 0

    def _build_msi(self) -> bool:
        wix = find_wix()
        if wix is None:
            self.log("WiX CLI not found.")
            return False
        if not EXE.is_file():
            self.log(f"Missing {EXE}")
            return False
        DIST.mkdir(parents=True, exist_ok=True)
        cmd = [
            str(wix),
            "build",
            "-acceptEula",
            "wix7",
            str(WIXS),
            "-arch",
            "x64",
            "-bindpath",
            f"payload={PAYLOAD}",
            "-o",
            str(MSI),
        ]
        return self._exec("MSI", cmd)

    def _done(self, ok: bool) -> None:
        self._busy = False
        self._go.configure(state="normal")
        self._status.configure(text=("Done." if ok else "Failed.") + "  " + self._ready_status())
        if ok:
            messagebox.showinfo("Rebuild", "Selected targets finished.")
        else:
            messagebox.showerror("Rebuild", "A target failed. See the log.")

    def _open_dist(self) -> None:
        DIST.mkdir(parents=True, exist_ok=True)
        os.startfile(DIST)  # type: ignore[attr-defined]

    def _open_release(self) -> None:
        if PAYLOAD.is_dir():
            os.startfile(PAYLOAD)  # type: ignore[attr-defined]
        else:
            messagebox.showinfo("Rebuild", "Windows Release folder does not exist yet.")


def main() -> None:
    app = RebuildGui()
    app.mainloop()


if __name__ == "__main__":
    main()
