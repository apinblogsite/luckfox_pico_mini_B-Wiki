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

[ -f "$CONF" ] || { echo "config wifi tidak ada"; exit 0; }

# tunggu interface wireless muncul.
# systemd mengganti nama wlan0 -> wlx<mac>, jadi deteksi dinamis.
i=0
IF=""
while [ $i -lt 30 ]; do
	IF=$(ls /sys/class/net 2>/dev/null | grep -E "^wl" | head -1)
	[ -n "$IF" ] && break
	sleep 1
	i=$((i + 1))
done
[ -n "$IF" ] || { echo "tidak ada interface wireless"; exit 0; }
echo "interface: $IF"

ip link set "$IF" up

# Driver aircrack-ng mendukung nl80211; driver staging lama hanya WEXT.
# Coba nl80211 dulu, jatuh ke wext bila gagal.
if pgrep -f "wpa_supplicant.*$IF" >/dev/null 2>&1; then
	echo "wpa_supplicant sudah jalan"
else
	if wpa_supplicant -B -i "$IF" -c "$CONF" 2>/dev/null; then
		echo "wpa_supplicant: nl80211"
	elif wpa_supplicant -B -D wext -i "$IF" -c "$CONF" 2>/dev/null; then
		echo "wpa_supplicant: wext"
	else
		echo "wpa_supplicant GAGAL"
		exit 1
	fi
fi

# tunggu asosiasi sungguhan sebelum konfigurasi alamat
n=0
while [ $n -lt 30 ]; do
	if wpa_cli -i "$IF" status 2>/dev/null | grep -q "wpa_state=COMPLETED"; then
		echo "terasosiasi"
		break
	fi
	sleep 1
	n=$((n + 1))
done

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
	ip -4 addr show "$IF" | grep -q "inet " || dhclient -nw "$IF" || udhcpc -i "$IF" -b
fi

echo "alamat : $(ip -4 -o addr show "$IF" | awk '{print $4}')"
echo "gateway: $(ip route | awk '/^default/{print $3}')"
echo "selesai"
