#!/bin/sh
# Pasang kebijakan restart untuk layanan inti, plus perbaikan ukuran /run yang
# membuat systemd daemon-reload bisa dijalankan sama sekali. Jalankan DI BOARD
# sebagai root, dari dalam direktori ini.
#
# Urutannya penting: /run harus diperbesar LEBIH DULU, kalau tidak
# daemon-reload di bawah akan ditolak dan drop-in baru berlaku setelah reboot.

set -e
[ "$(id -u)" = 0 ] || { echo "jalankan sebagai root" >&2; exit 1; }
DIR=$(dirname "$0")

echo "== 1. perbesar /run (berlaku seketika) =="
df -h /run | tail -1
mount -o remount,size=24M /run
df -h /run | tail -1

echo
echo "== 2. buat perubahan itu bertahan setelah reboot =="
install -m 644 "$DIR/run-resize.service" /etc/systemd/system/run-resize.service

echo
echo "== 3. pasang drop-in kebijakan restart =="
for pair in \
	"luckfox-wifi:luckfox-wifi-10-restart.conf" \
	"mosquitto:mosquitto-10-restart.conf" \
	"ssh:ssh-10-restart.conf"
do
	unit=${pair%%:*}
	file=${pair#*:}
	mkdir -p "/etc/systemd/system/$unit.service.d"
	install -m 644 "$DIR/$file" "/etc/systemd/system/$unit.service.d/10-restart.conf"
	echo "   $unit"
done

# luckfox-telemetry sudah memakai Restart=always di unitnya sendiri; yang
# kurang hanya mematikan pembatasan laju.
mkdir -p /etc/systemd/system/luckfox-telemetry.service.d
cat > /etc/systemd/system/luckfox-telemetry.service.d/10-restart.conf <<'EOF'
# Unit sudah memakai Restart=always RestartSec=10. Yang kurang hanyalah
# mematikan pembatasan laju bawaan (5 start per 10 detik) supaya layanan tidak
# menyerah permanen kalau broker sempat lama tidak tersedia.
[Unit]
StartLimitIntervalSec=0
EOF
echo "   luckfox-telemetry"

echo
echo "== 4. terapkan =="
systemctl daemon-reload
systemctl enable run-resize.service

echo
echo "== 5. kebijakan efektif =="
printf "   %-22s %-11s %-6s %-6s %s\n" LAYANAN Restart Sec LimitI Burst
for u in luckfox-wifi luckfox-telemetry mosquitto ssh; do
	printf "   %-22s " "$u"
	systemctl show "$u.service" -p Restart -p RestartUSec \
		-p StartLimitIntervalUSec -p StartLimitBurst --value 2>/dev/null | tr '\n' ' '
	echo
done

echo
echo "Selesai. Uji dengan membunuh salah satu layanan:"
echo "  sudo kill -9 \$(systemctl show mosquitto -p MainPID --value)"
echo "  sleep 9; systemctl show mosquitto -p NRestarts -p MainPID"
