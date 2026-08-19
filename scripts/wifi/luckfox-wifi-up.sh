#!/bin/sh
# Pasang di board sebagai /usr/local/sbin/luckfox-wifi-up.sh
# Dijalankan luckfox-wifi.service SETELAH sistem siap, bukan dari rc.local.
#
# Sesuaikan IPADDR/GATEWAY dengan jaringan Anda, atau kosongkan IPADDR
# untuk memakai DHCP (lihat blok di bawah).

CONF=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
IPADDR=192.168.1.50      # GANTI sesuai jaringan Anda
PREFIX=24
GATEWAY=192.168.1.1     # GANTI
DNS1=192.168.1.1        # GANTI
DNS2=1.1.1.1

# --- Kenapa kode keluar di bawah ini penting ------------------------------
# Unit memakai Restart=on-failure. Setiap kegagalan yang masih bisa ditolong
# dengan mencoba lagi HARUS keluar bukan-nol. Versi pertama skrip ini keluar 0
# untuk "tidak ada interface wireless" dan untuk asosiasi yang gagal, sehingga
# systemd menganggapnya sukses dan tidak pernah mencoba ulang -- board bisa
# berakhir tanpa jaringan sama sekali padahal percobaan kedua kemungkinan besar
# berhasil (dongle USB kerap terlambat enumerasi).
#
#   keluar 0 = tidak ada yang perlu dikerjakan (WiFi memang tidak dikonfigurasi)
#   keluar 1 = gagal, dan mencoba lagi masuk akal

[ -f "$CONF" ] || { echo "config wifi tidak ada -- WiFi tidak dikonfigurasi"; exit 0; }

# Tunggu interface wireless muncul. systemd mengganti nama wlan0 -> wlx<mac>,
# jadi deteksinya dinamis.
i=0
IF=""
while [ $i -lt 30 ]; do
	IF=$(ls /sys/class/net 2>/dev/null | grep -E "^wl" | head -1)
	[ -n "$IF" ] && break
	sleep 1
	i=$((i + 1))
done
if [ -z "$IF" ]; then
	echo "tidak ada interface wireless setelah 30 detik" >&2
	exit 1
fi
echo "interface: $IF"

ip link set "$IF" up

# Driver aircrack-ng mendukung nl80211; driver staging lama hanya WEXT.
# Coba nl80211 dulu, jatuh ke wext bila gagal.
if pgrep -f "wpa_supplicant.*$IF" >/dev/null 2>&1; then
	echo "wpa_supplicant sudah jalan"
elif wpa_supplicant -B -i "$IF" -c "$CONF" 2>/dev/null; then
	echo "wpa_supplicant: nl80211"
elif wpa_supplicant -B -D wext -i "$IF" -c "$CONF" 2>/dev/null; then
	echo "wpa_supplicant: wext"
else
	echo "wpa_supplicant gagal dijalankan" >&2
	exit 1
fi

# Tunggu asosiasi sungguhan. Kalau tidak pernah tercapai, jangan teruskan
# memasang alamat pada interface yang tidak terhubung -- laporkan gagal.
n=0
while [ $n -lt 30 ]; do
	wpa_cli -i "$IF" status 2>/dev/null | grep -q "wpa_state=COMPLETED" && break
	sleep 1
	n=$((n + 1))
done
if ! wpa_cli -i "$IF" status 2>/dev/null | grep -q "wpa_state=COMPLETED"; then
	echo "tidak terasosiasi setelah 30 detik" >&2
	exit 1
fi
echo "terasosiasi"

if [ -n "$IPADDR" ]; then
	# --- IP statis (idempoten) ---
	ip -4 addr show "$IF" | grep -q "$IPADDR/$PREFIX" || ip addr add "$IPADDR/$PREFIX" dev "$IF"
	ip route | grep -q "^default via $GATEWAY" || ip route add default via "$GATEWAY" dev "$IF"
	if [ ! -L /etc/resolv.conf ]; then
		printf "nameserver %s\nnameserver %s\n" "$DNS1" "$DNS2" > /etc/resolv.conf
	fi
else
	# --- DHCP ---
	# Aman dengan driver aircrack-ng. Dengan driver staging lama, dhclient
	# adalah pemicu crash tersering.
	if ! ip -4 addr show "$IF" | grep -q "inet "; then
		dhclient -nw "$IF" 2>/dev/null || udhcpc -i "$IF" -b 2>/dev/null
	fi
	# dhclient -nw kembali seketika; tunggu alamatnya benar-benar terpasang,
	# kalau tidak pemeriksaan akhir di bawah akan gagal secara palsu.
	d=0
	while [ $d -lt 20 ]; do
		ip -4 addr show "$IF" | grep -q "inet " && break
		sleep 1
		d=$((d + 1))
	done
fi

# Verifikasi hasil akhir, bukan menganggap perintah di atas pasti berhasil.
ADDR=$(ip -4 -o addr show "$IF" | awk "{print \$4}" | head -1)
GW=$(ip route | awk "/^default/{print \$3; exit}")
[ -n "$ADDR" ] || { echo "interface tidak mendapat alamat IPv4" >&2; exit 1; }
[ -n "$GW" ]   || { echo "tidak ada default route" >&2; exit 1; }

echo "alamat : $ADDR"
echo "gateway: $GW"
echo "selesai"
