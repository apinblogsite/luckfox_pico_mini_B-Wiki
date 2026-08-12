#!/bin/sh
# Pasang di board sebagai /oem/usr/ko/insmod_ko.sh (cadangkan aslinya dulu!)
#
# Versi ramping: melewati seluruh tumpukan media Rockchip.
#
# Alasan: ISP gagal probe dengan ENOMEM pada image Ubuntu, sehingga rockit
# menelurkan 10 thread yang tersangkut permanen di state D --
#   vlog valloc vsys vrga_0 vrga_1 venc rkisp-vir0 vpss vrgn vmcu
# Thread state D dihitung ke load average, jadi board idle tampak load ~10
# padahal CPU 99% idle. Thread itu juga TIDAK BISA dilepas: rmmod menggantung
# selamanya karena proses uninterruptible tidak dapat dibatalkan.
#
# Hasil: load idle 10-11 -> 0,3-0,5; MemAvailable ~28 MB -> ~40 MB.
#
# Kembalikan insmod_ko.sh.bak kalau nanti memakai kamera -- dan untuk kamera,
# image Buildroot lebih tepat daripada Ubuntu.
cmd=`realpath $0`
_DIR=`dirname $cmd`
cd $_DIR

# driver WiFi tetap dimuat
$(pwd)/insmod_wifi.sh &
