import struct
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()

print(f"file size = {len(data)}")
byteorder = data[0:2]
assert byteorder == b"II", byteorder
magic = struct.unpack_from("<H", data, 2)[0]
assert magic == 42
first_ifd = struct.unpack_from("<I", data, 4)[0]
print(f"first IFD offset = {first_ifd}")

TYPE_SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8}

offset = first_ifd
seen = set()
page = 0
while offset != 0:
    if offset in seen:
        print(f"!! LOOP detected at offset {offset}")
        break
    seen.add(offset)
    print(f"--- Page {page} @ IFD offset {offset} ---")
    count = struct.unpack_from("<H", data, offset)[0]
    print(f"  tag count = {count}")
    tags = {}
    for i in range(count):
        entry_off = offset + 2 + i * 12
        tag, typ, cnt = struct.unpack_from("<HHI", data, entry_off)
        value_bytes = data[entry_off + 8: entry_off + 12]
        tags[tag] = (typ, cnt, value_bytes)
        val = struct.unpack_from("<I", value_bytes)[0]
        print(f"    tag={tag} type={typ} count={cnt} rawvalue={val}")
    next_ifd_off = offset + 2 + count * 12
    next_ifd = struct.unpack_from("<I", data, next_ifd_off)[0]
    print(f"  nextIFD (@ {next_ifd_off}) = {next_ifd}")

    w = struct.unpack_from("<I", tags[256][2])[0]
    h = struct.unpack_from("<I", tags[257][2])[0]
    print(f"  ImageWidth={w} ImageHeight={h}")

    offset = next_ifd
    page += 1

print(f"Total pages walked: {page}")
