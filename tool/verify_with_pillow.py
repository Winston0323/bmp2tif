import glob
import os
import sys
from PIL import Image, ImageSequence

ORIGINALS = {
    "sample1": "test_assets/sample1.bmp",
    "sample2": "test_assets/sample2.bmp",
}

failures = 0
total = 0

for path in sorted(glob.glob("test_output/*.tif")):
    name = os.path.basename(path)
    if name.startswith("debug"):
        continue
    total += 1
    base = name.split("_")[0]
    orig_path = ORIGINALS.get(base)
    try:
        im = Image.open(path)
        n_frames = getattr(im, "n_frames", 1)
        sizes = []
        page0 = None
        for i in range(n_frames):
            im.seek(i)
            if i == 0:
                page0 = im.convert("RGB")
            sizes.append(im.size)

        expected_pyramid = "pyrtrue" in name
        if expected_pyramid and n_frames < 2:
            raise Exception(f"expected multi-page pyramid, got {n_frames} page(s)")
        if not expected_pyramid and n_frames != 1:
            raise Exception(f"expected 1 page, got {n_frames} page(s)")

        # Validate pyramid pages roughly halve in size each step.
        prev_w, prev_h = sizes[0]
        for pw, ph in sizes[1:]:
            if pw >= prev_w or ph >= prev_h:
                raise Exception(f"pyramid page did not shrink: {prev_w}x{prev_h} -> {pw}x{ph}")
            prev_w, prev_h = pw, ph

        is_lossless = any(tag in name for tag in ("_none_", "_lzw_", "_zip_"))
        if orig_path and is_lossless:
            orig = Image.open(orig_path).convert("RGB")
            if page0.size != orig.size:
                raise Exception(f"size mismatch {page0.size} vs {orig.size}")
            mism = 0
            ow, oh = orig.size
            op = orig.load()
            pp = page0.load()
            for y in range(0, oh, 7):
                for x in range(0, ow, 7):
                    if op[x, y] != pp[x, y]:
                        mism += 1
            if mism:
                raise Exception(f"{mism} pixel mismatches (lossless check)")

        print(f"OK   {name}  pages={n_frames} size={page0.size}")
    except Exception as e:
        print(f"FAIL {name}: {e}")
        failures += 1

print("---")
print(f"Total: {total}, Failures: {failures}")
sys.exit(1 if failures else 0)
