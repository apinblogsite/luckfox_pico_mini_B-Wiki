#!/bin/sh
# Mount partisi board dari kartu SD di WSL -- jalur pemulihan paling andal.
# Tidak butuh board menyala, tidak bergantung timing.
#
# JEBAKAN: blkdevparts adalah definisi partisi lewat cmdline kernel, BUKAN
# tabel partisi sungguhan. Linux biasa tidak akan melihat mmcblk1p7 di kartu.
# Harus mount pakai offset lewat loop device.
#
# Pakai (dari PowerShell, agar path tidak diacak Git Bash):
#   usbipd attach --wsl --busid <busid>
#   wsl -u root -e sh /mnt/c/.../mount_sdcard.sh
#
# WSL harus sudah berjalan sebelum usbipd attach, kalau tidak muncul
# "There is no WSL 2 distribution running":
#   Start-Process wsl.exe -ArgumentList "-e","sleep","600" -WindowStyle Hidden

set -e

DEV=${DEV:-/dev/sdd}
EXPECT_SIZE=8032092160

# offset byte, dari sd_update.txt
ROOTFS_OFF=839680000
ROOTFS_LEN=6442450944
OEM_OFF=34373632
OEM_LEN=536870912

[ "$(blockdev --getsize64 "$DEV")" = "$EXPECT_SIZE" ] || {
	echo "ABORT: $DEV bukan kartu yang diharapkan"; exit 1; }

umount /mnt/lfroot 2>/dev/null || true
umount /mnt/lfoem 2>/dev/null || true
losetup -D 2>/dev/null || true
mkdir -p /mnt/lfroot /mnt/lfoem

L1=$(losetup -o "$ROOTFS_OFF" --sizelimit "$ROOTFS_LEN" -f --show "$DEV")
L2=$(losetup -o "$OEM_OFF"    --sizelimit "$OEM_LEN"    -f --show "$DEV")
mount -t ext4 "$L1" /mnt/lfroot
mount -t ext4 "$L2" /mnt/lfoem

echo "rootfs -> /mnt/lfroot   ($L1)"
echo "oem    -> /mnt/lfoem    ($L2)"
echo "hostname di kartu: $(cat /mnt/lfroot/etc/hostname)"
echo
echo "Setelah selesai:"
echo "  sync; umount /mnt/lfroot /mnt/lfoem; losetup -D"
echo
echo "Yang biasanya perlu diperbaiki di sini:"
echo "  - hapus /mnt/lfroot/etc/NetworkManager/system-connections/*.nmconnection"
echo "  - kosongkan bagian penyambungan di /mnt/lfoem/usr/ko/insmod_rtl8188eu.sh"
echo "  - kembalikan mode peripheral: tulis cadangan partisi boot ke offset 819200"
