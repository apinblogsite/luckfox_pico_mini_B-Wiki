#!/usr/bin/env python3
"""Ubah kernel bootargs di partisi env U-Boot Luckfox.

Kenapa perlu skrip: `fw_setenv` tidak disertakan di image, dan Ctrl+C tidak
menginterupsi U-Boot (bootdelay nol). Satu-satunya jalan adalah menulis
partisi env langsung -- dan itu berarti menghitung ulang CRC32.

Format partisi env (/dev/mmcblk1p1, 32 KB):
    byte 0-3 : CRC32 little-endian atas seluruh sisa
    byte 4+  : key=value dipisah NUL, lalu padding nol sampai akhir

Pakai di board:
    sudo dd if=/dev/mmcblk1p1 of=/tmp/env.bin bs=1k count=32
    sudo python3 patch_bootargs.py /tmp/env.bin /tmp/env_new.bin \
         "rk_dma_heap_cma=1M" "rk_dma_heap_cma=16M"
    sudo dd if=/tmp/env_new.bin of=/dev/mmcblk1p1 bs=1k count=32 conv=fsync
    sync

SELALU cadangkan env asli sebelum menulis, dan verifikasi read-back sesudahnya.
"""
import binascii
import sys


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        return 1

    src, dst, old, new = sys.argv[1:5]
    raw = open(src, "rb").read()
    print(f"ukuran env      : {len(raw)}")

    stored = int.from_bytes(raw[:4], "little")
    data = raw[4:]
    calc = binascii.crc32(data) & 0xFFFFFFFF
    print(f"CRC tersimpan   : 0x{stored:08x}")
    print(f"CRC dihitung    : 0x{calc:08x}")
    if stored != calc:
        print(">>> FORMAT TIDAK COCOK - JANGAN TULIS APA PUN")
        return 1
    print(">>> format terkonfirmasi: CRC32 standar U-Boot")

    ob, nb = old.encode(), new.encode()
    n = data.count(ob)
    print(f"kemunculan pola : {n}")
    if n != 1:
        print(">>> pola tidak unik atau tidak ditemukan - batal")
        return 1

    nd = data.replace(ob, nb)
    # Panjang total harus tetap. Kelebihan diambil dari padding nol di ekor.
    if len(nd) > len(data):
        tail = nd[len(data):]
        if tail.strip(b"\x00"):
            print(">>> padding tidak cukup - batal")
            return 1
        nd = nd[: len(data)]
    elif len(nd) < len(data):
        nd = nd + b"\x00" * (len(data) - len(nd))
    assert len(nd) == len(data)

    crc = binascii.crc32(nd) & 0xFFFFFFFF
    open(dst, "wb").write(crc.to_bytes(4, "little") + nd)
    print(f"CRC baru        : 0x{crc:08x}")
    print(f"ditulis ke      : {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
