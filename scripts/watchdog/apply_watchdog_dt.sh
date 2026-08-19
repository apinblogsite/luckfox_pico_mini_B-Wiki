#!/bin/sh
# Menambahkan node watchdog ke DTB di partisi boot board (dijalankan DI BOARD).
#
# Partisi boot (/dev/mmcblk1p4) berisi FIT image dengan tata letak:
#   offset 0      header FIT (FDT pembungkus), 2048 byte
#   offset 2048   blob device tree kernel        <-- yang kita ubah
#   offset 38400  image kernel
#
# Dua hal yang WAJIB benar saat mengubahnya:
#   1. FDT baru tidak boleh melewati 36352 byte (38400 - 2048), kalau tidak
#      ia menimpa awal kernel dan board tidak akan boot lagi.
#   2. Field "data-size" di header FIT harus diperbarui. Fungsi
#      luckfox_fdt_overlay dari /usr/bin/luckfox-config sudah menanganinya.
#
# Ukuran terukur pada firmware 250313: FDT lama 36054 byte, setelah overlay
# 36242 byte. Sisa ruang tinggal 110 byte -- sempit, jadi jangan menambah
# properti lain tanpa menghitung ulang.
#
# CADANGKAN DULU. Dari PC:
#   plink ... "echo <sandi> | sudo -S dd if=/dev/mmcblk1p4 bs=1M count=4" > boot_p4.bin
# Pemulihan bila gagal boot: tulis balik berkas itu ke offset 819200 pada kartu
# SD secara offline (lihat scripts/recovery/mount_sdcard.sh).

set -e

DTS="${1:-$(dirname "$0")/watchdog-overlay.dts}"
PART="${PART:-/dev/mmcblk1p4}"
FDT_OFFSET=2048
FDT_LIMIT=36352

[ -r "$DTS" ] || { echo "tidak bisa membaca $DTS" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "jalankan sebagai root" >&2; exit 1; }

echo "== membaca FDT yang sekarang dari $PART =="
dd if="$PART" of=/tmp/wdt_hdr.dtb bs=1 count=$FDT_OFFSET 2>/dev/null
SZ=$(fdtdump /tmp/wdt_hdr.dtb 2>/dev/null | grep -A5 "fdt {" | grep "data-size" \
     | awk '{print $3}' | tr -d ';<>')
SZ=$(printf "%d" "$SZ")
echo "   data-size sekarang: $SZ byte"
dd if="$PART" of=/tmp/wdt_cur.dtb bs=1 skip=$FDT_OFFSET count="$SZ" 2>/dev/null

echo "== kompilasi overlay =="
# -W no-unit_address_vs_reg: node root memakai #address-cells = <1> sedangkan
# nama node memuat alamat 32-bit; peringatan ini tidak relevan di sini.
dtc -I dts -O dtb -o /tmp/wdt.dtbo -W no-unit_address_vs_reg "$DTS" 2>/dev/null
echo "   dtbo: $(stat -c%s /tmp/wdt.dtbo) byte"

echo "== uji coba pada SALINAN (belum menulis apa pun) =="
fdtoverlay -i /tmp/wdt_cur.dtb -o /tmp/wdt_new.dtb /tmp/wdt.dtbo
NEW=$(stat -c%s /tmp/wdt_new.dtb)
echo "   FDT setelah overlay: $NEW byte (batas $FDT_LIMIT, sisa $((FDT_LIMIT - NEW)))"
if [ "$NEW" -gt "$FDT_LIMIT" ]; then
	echo "   TIDAK MUAT -- akan menimpa kernel. Dibatalkan." >&2
	exit 1
fi
dtc -I dtb -O dts /tmp/wdt_new.dtb 2>/dev/null | grep -q "watchdog@ff5a0000" \
	|| { echo "   node tidak terbentuk. Dibatalkan." >&2; exit 1; }
echo "   muat, dan node terbentuk"

echo "== menulis ke $PART =="
# luckfox-config dipanggil dengan argumen tak dikenal supaya hanya fungsinya
# yang termuat, tanpa memicu menu interaktif.
. /usr/bin/luckfox-config __noop__
LUCKFOX_CHIP_MEDIA="$PART"
LUCKFOX_CHIP_MEDIA_CLASS=sdmmc
luckfox_update_fdt
luckfox_fdt_overlay "$(cat "$DTS")"
sync

echo "== verifikasi hasil baca-ulang dari partisi =="
dd if="$PART" of=/tmp/wdt_hdr2.dtb bs=1 count=$FDT_OFFSET 2>/dev/null
SZ2=$(fdtdump /tmp/wdt_hdr2.dtb 2>/dev/null | grep -A5 "fdt {" | grep "data-size" \
      | awk '{print $3}' | tr -d ';<>')
SZ2=$(printf "%d" "$SZ2")
echo "   data-size baru: $SZ2 byte"
dd if="$PART" of=/tmp/wdt_chk.dtb bs=1 skip=$FDT_OFFSET count="$SZ2" 2>/dev/null
dtc -I dtb -O dts /tmp/wdt_chk.dtb 2>/dev/null | grep -A7 "watchdog@ff5a0000" | sed 's/^/   /'
sync

echo
echo "Selesai. Reboot, lalu periksa: ls -l /dev/watchdog*"
