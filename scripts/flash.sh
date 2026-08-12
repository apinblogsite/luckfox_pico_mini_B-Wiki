#!/bin/sh
# Flash firmware Luckfox Pico Mini B (paket MicroSD) ke kartu SD.
#
# Setara blkenvflash.py -- offset identik, diambil dari sd_update.txt bawaan
# firmware dan dicocokkan dengan blkdevparts di .env.txt.
#
# Bedanya: O_DIRECT dengan blok besar, bukan bs=1k.
#   * bs=1k untuk rootfs 1,08 GB berarti ~1,1 juta syscall write
#   * lewat USB/IP setiap operasi menambah round-trip -- berjam-jam
#   * TANPA O_DIRECT penulisan GAGAL sama sekali di reader murah:
#       Sense Key 0x3 (MEDIUM ERROR), phys_seg 30
#     writeback dari page cache menghasilkan scatter-gather terfragmentasi
#     yang tidak sanggup dilayani reader; O_DIRECT mengirim buffer kontigu.
#
# Jalankan DARI POWERSHELL, bukan Git Bash:
#   wsl -u root -e sh /home/<user>/luckfox-fw/flash.sh
# (Git Bash menerjemahkan /home/... jadi C:/Program Files/Git/home/...)

set -e

DEV=/dev/sdd
FW=$HOME/luckfox-fw/Ubuntu_Luckfox_Pico_Mini_B_MicroSD_250313
EXPECT_SIZE=8032092160

# nama:offset_byte -- lihat sd_update.txt
IMGS="env:0 idblock:32768 uboot:557056 boot:819200 oem:34373632 userdata:571244544 rootfs:839680000"

echo "=== PEMERIKSAAN KESELAMATAN ==="
SIZE=$(blockdev --getsize64 "$DEV")
[ "$SIZE" = "$EXPECT_SIZE" ] || { echo "ABORT: ukuran $DEV = $SIZE, diharapkan $EXPECT_SIZE"; exit 1; }
[ "$(cat /sys/block/$(basename $DEV)/removable)" = "1" ] || { echo "ABORT: $DEV bukan removable"; exit 1; }
echo "  $DEV size=$SIZE removable=1 -> OK"
umount /mnt/sd 2>/dev/null || true

echo "=== TULIS ==="
for e in $IMGS; do
	name=${e%%:*}; off=${e##*:}
	f="$FW/$name.img"
	[ -f "$f" ] || { echo "ABORT: $f tidak ada"; exit 1; }
	sz=$(stat -c%s "$f")
	printf '  %-13s offset %12s  %10s byte ... ' "$name.img" "$off" "$sz"
	dd if="$f" of="$DEV" bs=4M oflag=direct,seek_bytes seek="$off" status=none
	echo "OK"
done
sync

echo "=== VERIFIKASI READ-BACK ==="
fail=0
for e in $IMGS; do
	name=${e%%:*}; off=${e##*:}
	f="$FW/$name.img"; sz=$(stat -c%s "$f")
	a=$(sha256sum "$f" | cut -d' ' -f1)
	b=$(dd if="$DEV" bs=4M iflag=direct,skip_bytes,count_bytes skip="$off" count="$sz" status=none | sha256sum | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then
		printf '  %-13s COCOK\n' "$name.img"
	else
		printf '  %-13s BEDA!\n    file: %s\n    disk: %s\n' "$name.img" "$a" "$b"
		fail=1
	fi
done
[ "$fail" = "0" ] && echo "=== SEMUA COCOK ===" || { echo "=== ADA YANG TIDAK COCOK ==="; exit 1; }
