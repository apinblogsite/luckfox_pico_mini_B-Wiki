#!/bin/sh
# Uji watchdog secara sungguhan: membuat board MACET, lalu membuktikan ia
# memulihkan dirinya sendiri.
#
# JALANKAN INI HANYA KALAU ANDA BISA MENCABUT DAYA BOARD SECARA FISIK.
# Kalau watchdog ternyata tidak aktif, board akan menggantung total dan
# satu-satunya jalan keluar adalah memutus daya.
#
# CARA KERJANYA
# RV1103 hanya punya satu inti. Sebuah proses SCHED_FIFO prioritas 99 karena
# itu bisa menguasai seluruh CPU dan membuat systemd tidak pernah terjadwal
# untuk memberi makan watchdog.
#
# Kenapa RT throttling harus dimatikan dulu: secara bawaan kernel mengembalikan
# 5% waktu CPU (sched_rt_runtime_us=950000 dari 1000000) kepada tugas non-RT
# setiap detik. Jatah kecil itu sudah lebih dari cukup bagi PID 1 untuk terus
# memberi makan watchdog, sehingga ujinya tidak akan pernah memicu apa pun.
# Menyetelnya ke -1 membuat kelaparan CPU benar-benar total. Nilai ini tidak
# persisten -- ia kembali ke 950000 sendirinya setelah board reset, dan itu
# sekaligus menjadi salah satu bukti bahwa reset memang terjadi.
#
# YANG SEHARUSNYA TERJADI
# Board berhenti merespons dalam beberapa detik, lalu mereset diri sekitar
# 44 detik kemudian (sesuai RuntimeWatchdogSec) dan boot seperti biasa.
#
# CARA MEMBUKTIKAN RESET-NYA NYATA, bukan reboot rapi -- periksa setelah board
# kembali:
#   uptime                                   -> terhitung ulang dari nol
#   pgrep -af spin.sh                        -> proses lenyap
#   cat /proc/sys/kernel/sched_rt_runtime_us -> kembali 950000
#   dmesg | grep -i "EXT4-fs.*recovery"      -> jurnal ext4 diputar ulang
# Yang terakhir itu buktinya: pemulihan jurnal hanya terjadi setelah shutdown
# tidak bersih.

set -e
[ "$(id -u)" = 0 ] || { echo "jalankan sebagai root" >&2; exit 1; }

if ! ls -l /proc/1/fd/ 2>/dev/null | grep -qi watchdog; then
	echo "PID 1 tidak memegang /dev/watchdog -- systemd belum diatur." >&2
	echo "Periksa: systemctl show -p RuntimeWatchdogUSec" >&2
	exit 1
fi

echo "uptime sebelum uji: $(cut -d. -f1 /proc/uptime) detik"
echo "watchdog dipegang PID 1, RuntimeWatchdogUSec=$(systemctl show -p RuntimeWatchdogUSec --value)"
sync

echo -1 > /proc/sys/kernel/sched_rt_runtime_us
echo "RT throttling dimatikan (sched_rt_runtime_us=$(cat /proc/sys/kernel/sched_rt_runtime_us))"

printf 'while : ; do : ; done\n' > /tmp/spin.sh
echo "melepas proses FIFO prioritas 99..."
setsid chrt -f 99 sh /tmp/spin.sh >/dev/null 2>&1 </dev/null &

echo "dilepas. board seharusnya mereset diri dalam ~44 detik."
