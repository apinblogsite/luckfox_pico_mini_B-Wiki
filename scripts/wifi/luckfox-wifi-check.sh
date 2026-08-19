#!/bin/sh
# Pasang di board sebagai /usr/local/sbin/luckfox-wifi-check.sh
# Dijalankan berkala oleh luckfox-wifi-check.timer.
#
# MASALAH YANG DIPECAHKAN
# luckfox-wifi.service bertipe oneshot: begitu skripnya selesai dengan status 0,
# systemd tidak punya proses apa pun untuk diawasi. Kalau WiFi putus SETELAH
# itu -- AP di-reboot, dongle kehilangan asosiasi, driver tersangkut -- tidak
# ada yang menyadarinya. Restart= tidak bisa menolong karena tidak ada yang
# "gagal"; unitnya sudah lama selesai dengan sukses.
#
# Watchdog perangkat keras juga tidak menolong di sini: kernelnya baik-baik
# saja, hanya jaringannya yang mati. Gejalanya board diam-diam tidak terjangkau
# padahal ia masih berjalan normal.
#
# YANG DIPERIKSA, dari yang paling murah ke yang paling meyakinkan:
#   1. interface wireless ada
#   2. carrier menyala          (link layer hidup)
#   3. wpa_state=COMPLETED      (terasosiasi ke AP)
#   4. punya alamat IPv4
#   5. ada default route, dan route itu keluar lewat interface wireless
#   6. gateway menjawab ping    (satu-satunya bukti jalur benar-benar hidup)
#
# Lima yang pertama gratis. Yang keenam mengirim tiga paket ICMP ke gateway
# lokal saja -- tidak menyentuh internet, jadi pemeriksaan ini tidak akan
# melaporkan sehat/sakit karena urusan di luar jaringan Anda.
#
# JANGAN pakai `ping -I <interface>` di board ini. `ping` di sini adalah GNU
# inetutils 2.2, bukan iputils, dan ia tidak mengenal opsi -I:
#   ping: invalid option -- 'I'
# Perintahnya gagal karena opsi tidak valid, lalu skrip menyimpulkan gateway
# tidak menjawab. Hasilnya kegagalan palsu terus-menerus pada jaringan yang
# sebenarnya sehat -- dan pemeriksa yang seharusnya memulihkan justru menjadi
# sumber gangguan yang menjalankan ulang WiFi tiap beberapa menit.
#
# Pengikatan ke interface tidak diperlukan: alamat gateway diambil dari default
# route, dan langkah 5 sudah memastikan route itu memang keluar lewat interface
# wireless.
#
# KENAPA TIDAK LANGSUNG BERTINDAK PADA KEGAGALAN PERTAMA
# Satu ping yang meleset bukan berarti WiFi putus. Skrip menghitung kegagalan
# BERURUTAN di /run (tmpfs -- tidak membebani kartu SD) dan baru memulihkan
# setelah ambang tercapai. Hitungannya direset begitu sehat kembali.

CONF=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
SERVICE=luckfox-wifi.service
STATE=/run/luckfox-wifi-check.fail

PING_COUNT=3
PING_DEADLINE=5     # detik, total untuk seluruh percobaan ping

# Berapa kegagalan berurutan sebelum menjalankan ulang layanan WiFi.
RESTART_AFTER=2

# Berapa kegagalan berurutan sebelum me-reboot board. 0 = jangan pernah.
#
# Sengaja dimatikan secara bawaan. Kalau AP Anda mati selama berjam-jam,
# board akan reboot berulang tanpa guna dan hanya memperpendek umur kartu SD.
# Aktifkan (misalnya 10, artinya ~20 menit gagal terus) hanya kalau board
# dipasang di tempat yang sulit dijangkau DAN jaringannya biasanya andal.
REBOOT_AFTER=0

log() { echo "$*"; }

# --- jangan ikut campur saat layanan WiFi memang sedang bekerja -----------
state=$(systemctl show "$SERVICE" -p ActiveState --value 2>/dev/null)
case "$state" in
	activating|deactivating|reloading) exit 0 ;;
esac

# WiFi memang tidak dikonfigurasi di board ini -- bukan kegagalan.
[ -f "$CONF" ] || exit 0

fails=0
[ -r "$STATE" ] && fails=$(cat "$STATE" 2>/dev/null)
case "$fails" in ''|*[!0-9]*) fails=0 ;; esac

# --- pemeriksaan ----------------------------------------------------------
problem=""
IF=$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1)

if [ -z "$IF" ]; then
	problem="tidak ada interface wireless"
elif [ "$(cat "/sys/class/net/$IF/carrier" 2>/dev/null)" != "1" ]; then
	problem="carrier turun pada $IF"
elif ! wpa_cli -i "$IF" status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; then
	problem="tidak terasosiasi"
elif ! ip -4 addr show "$IF" 2>/dev/null | grep -q 'inet '; then
	problem="tidak ada alamat IPv4"
else
	GWLINE=$(ip route | awk '/^default/{print; exit}')
	GW=$(echo "$GWLINE" | awk '{print $3}')
	GWDEV=$(echo "$GWLINE" | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}')
	if [ -z "$GW" ]; then
		problem="tidak ada default route"
	elif [ "$GWDEV" != "$IF" ]; then
		# Kalau board Anda punya uplink lain (misalnya USB ethernet), longgarkan
		# atau hapus pemeriksaan ini -- di board ini WiFi satu-satunya jalan keluar.
		problem="default route lewat $GWDEV, bukan $IF"
	elif ! ping -c "$PING_COUNT" -w "$PING_DEADLINE" "$GW" >/dev/null 2>&1; then
		problem="gateway $GW tidak menjawab"
	fi
fi

# --- sehat ----------------------------------------------------------------
if [ -z "$problem" ]; then
	if [ "$fails" -gt 0 ]; then
		log "wifi sehat lagi (setelah $fails pemeriksaan gagal)"
		rm -f "$STATE"
	fi
	exit 0
fi

# --- gagal ----------------------------------------------------------------
fails=$((fails + 1))
echo "$fails" > "$STATE"
log "pemeriksaan gagal ($fails): $problem"

if [ "$REBOOT_AFTER" -gt 0 ] && [ "$fails" -ge "$REBOOT_AFTER" ]; then
	log "gagal $fails kali berturut-turut -- me-reboot board"
	rm -f "$STATE"
	sync
	systemctl reboot
	exit 0
fi

[ "$fails" -ge "$RESTART_AFTER" ] || exit 0

# --- pemulihan ------------------------------------------------------------
# wpa_supplicant yang tersangkut HARUS dimatikan lebih dulu. luckfox-wifi-up.sh
# memeriksa `pgrep wpa_supplicant`, melihat prosesnya masih hidup, lalu
# menyimpulkan "sudah jalan" dan keluar tanpa memperbaiki apa pun. Tanpa baris
# ini, menjalankan ulang layanan tidak berefek pada kasus asosiasi tersangkut --
# yaitu justru kasus yang paling sering terjadi.
if [ -n "$IF" ] && ! wpa_cli -i "$IF" status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; then
	if pkill -f "wpa_supplicant.*$IF" 2>/dev/null; then
		log "wpa_supplicant yang tersangkut dimatikan"
		sleep 1
	fi
fi

log "menjalankan ulang $SERVICE"
systemctl restart "$SERVICE"
