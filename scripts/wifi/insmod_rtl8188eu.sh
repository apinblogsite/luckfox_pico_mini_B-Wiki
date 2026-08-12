#!/bin/sh
# Pasang di board sebagai /oem/usr/ko/insmod_rtl8188eu.sh
#
# HANYA memuat modul. Penyambungan WiFi ditangani luckfox-wifi.service
# setelah sistem siap -- menjalankannya dari rc.local membuat board hang.
#
# Driver: 8188eu.ko dari aircrack-ng/rtl8188eus, di-cross-compile terhadap
# kernel SDK 5.10.160. Menggantikan r8188eu.ko dari drivers/staging yang
# punya bug "scheduling while atomic": membocorkan preempt count lalu
# membuat kernel Oops saat dhclient atau NetworkManager memakai interface.
#
# Driver ini hanya bergantung pada cfg80211 -- lib80211 tidak diperlukan.
KO=/oem/usr/ko

lsmod | grep -q "^cfg80211" || insmod $KO/cfg80211.ko
lsmod | grep -q "^8188eu"   || insmod $KO/8188eu.ko
