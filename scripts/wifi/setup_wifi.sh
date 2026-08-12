#!/bin/sh
# Simpan kredensial WiFi di board.
# Pakai: sudo sh setup_wifi.sh "<SSID>" "<PASSWORD>"
#
# PSK disimpan sebagai hash, bukan teks polos. Baris komentar berisi password
# polos yang biasa dicetak wpa_passphrase sengaja dibuang.
set -e

SSID="$1"
PSK="$2"
if [ -z "$SSID" ] || [ -z "$PSK" ]; then
	echo "Pakai: $0 \"<SSID>\" \"<PASSWORD>\""
	exit 1
fi
if [ ${#PSK} -lt 8 ]; then
	echo "ERROR: password WPA minimal 8 karakter"
	exit 1
fi

mkdir -p /etc/wpa_supplicant
CONF=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
{
	echo "ctrl_interface=/run/wpa_supplicant"
	echo "update_config=1"
	echo "country=ID"
	wpa_passphrase "$SSID" "$PSK" | grep -v '#psk='
} > "$CONF"
chmod 600 "$CONF"
echo "OK  $CONF ditulis (PSK sebagai hash)"

# Verifikasi tanpa menampilkan nilai
echo "kunci yang tersimpan:"
grep -oE "^[a-z_]+=|^[[:space:]]+[a-z_]+=" "$CONF" | tr -d ' \t'
echo "baris password polos tersisa: $(grep -c '[#]psk=' "$CONF")  (harus 0)"
sync
