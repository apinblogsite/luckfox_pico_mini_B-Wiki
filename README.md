# Luckfox Pico Mini B — Flash, Mode Host, WiFi & Konsol Serial

Panduan lengkap: menyiapkan WSL2 agar bisa membaca USB SD card reader, mem-flash firmware
Ubuntu ke microSD, mengakses board via ADB/SSH, mengubah USB ke mode host, memasang dongle
WiFi USB, dan memperbaiki board secara offline lewat kartu SD saat ia tidak bisa diakses.

Ditulis berdasarkan proses yang benar-benar dijalankan dan diverifikasi, bukan teori —
termasuk jalan buntu yang ditemui, supaya tidak diulang.

> **Baca ini dulu kalau board sudah dalam mode host:** ADB dan RNDIS tidak ada lagi. Jalur akses
> Anda adalah **konsol serial UART2** (Bagian 7) dan **perbaikan offline kartu SD** (Bagian 10).
> Keduanya tidak pernah bergantung pada USB, jadi tidak bisa hilang.

---

## Isi repo ini

Selain dokumentasi di bawah, repo ini memuat skrip yang dipakai sepanjang prosesnya:

```
scripts/flash.sh                      flash firmware ke SD (O_DIRECT + verifikasi sha256)
scripts/wifi/insmod_rtl8188eu.sh      loader driver WiFi
scripts/wifi/luckfox-wifi-up.sh       penyambung WiFi (statis atau DHCP)
scripts/wifi/luckfox-wifi.service     unit systemd
scripts/wifi/setup_wifi.sh            simpan kredensial (PSK sebagai hash)
scripts/wifi/99-unmanage-wifi.conf    jauhkan NetworkManager dari WiFi
scripts/trim/insmod_ko_min.sh         loader ramping, lewati tumpukan media
scripts/uboot/patch_bootargs.py       ubah bootargs + hitung ulang CRC32 env
scripts/recovery/mount_sdcard.sh      mount partisi board offline dari WSL
tools/serial-console.ps1              akses konsol serial dari Windows
```

Setiap skrip memuat komentar tentang **kenapa** ia ditulis begitu — bukan sekadar apa yang
dilakukannya. Bagian-bagian di bawah menjelaskan konteks lengkapnya.

---

## Ringkasan lingkungan

| Komponen | Versi / nilai |
|---|---|
| Host | Windows 11 (10.0.26200) |
| WSL | 2.4.13.0 |
| Distro | Ubuntu 24.04.3 LTS |
| Kernel WSL (bawaan) | 5.15.167.4-microsoft-standard-WSL2 |
| Card reader | Generic Mass Storage Device, VID:PID `14cd:1212`, busid `1-2` |
| microSD | 8,03 GB (15.687.680 sektor) |
| Firmware | `Ubuntu_Luckfox_Pico_Mini_B_MicroSD_250313.zip` (690 MB) |
| Hasil di board | Ubuntu 22.04.3 LTS, kernel 5.10.160 armv7l |

---

## Bagian 1 — Kenapa WSL2 tidak melihat SD card reader

`usbipd` bisa meng-attach reader dan kernel WSL berhasil meng-enumerate perangkatnya:

```
usb 1-1: New USB device found, idVendor=14cd, idProduct=1212
usb 1-1: Product: Mass Storage Device
```

…tapi `/dev/sdX` tidak pernah muncul. Penyebabnya ada di config kernel WSL2 bawaan Microsoft:

```
CONFIG_BLK_DEV_SD=y
# CONFIG_USB_STORAGE is not set     ← biang masalahnya
```

Driver `usb-storage` **tidak dikompilasi**, dan modulnya juga tidak disediakan di `/lib/modules`,
jadi `modprobe usb-storage` pun percuma. Perangkat masuk sebagai USB device tetapi tidak ada
driver yang mengklaim interface mass-storage-nya.

Cara memeriksa di sistem Anda:

```bash
zcat /proc/config.gz | grep -E 'CONFIG_USB_STORAGE|CONFIG_BLK_DEV_SD'
ls /sys/module | grep -iE 'usb|scsi'
```

Kalau hanya butuh **membaca file** dari kartu, tidak perlu semua ini — cukup biarkan Windows
yang mount (`usbipd detach --busid 1-2`) lalu akses via `/mnt/e`. Kernel kustom hanya diperlukan
kalau Anda butuh block device asli untuk `dd`, `fdisk`, atau partisi ext4 — seperti saat mem-flash.

---

## Bagian 2 — Build kernel WSL2 dengan dukungan USB storage

### 2.1 Dependensi

```bash
sudo apt update
sudo apt install -y build-essential flex bison libssl-dev libelf-dev bc dwarves python3 cpio kmod git
```

> Kalau `sudo` meminta password dan Anda ingin melewatinya, jalankan dari Windows:
> `wsl -u root -e <perintah>` — WSL mengizinkan root tanpa password.

### 2.2 Clone source dengan tag yang cocok

Tag **harus** sesuai versi kernel Anda (`uname -r`):

```bash
cd ~
git clone --depth 1 -b linux-msft-wsl-5.15.167.4 \
  https://github.com/microsoft/WSL2-Linux-Kernel.git
cd WSL2-Linux-Kernel
```

### 2.3 Konfigurasi

```bash
cp Microsoft/config-wsl .config
scripts/config --enable CONFIG_USB_STORAGE \
               --enable CONFIG_USB_UAS \
               --enable CONFIG_EXFAT_FS \
               --enable CONFIG_NTFS3_FS \
               --enable CONFIG_VFAT_FS \
               --enable CONFIG_NLS_CODEPAGE_437 \
               --enable CONFIG_NLS_ISO8859_1
make olddefconfig
```

Verifikasi semuanya jadi built-in (`=y`, bukan `=m` — kernel WSL tidak punya infrastruktur modul):

```bash
grep -E 'CONFIG_USB_STORAGE=|CONFIG_USB_UAS=|CONFIG_EXFAT_FS=|CONFIG_NTFS3_FS=' .config
```

### 2.4 Build & pasang

```bash
make -j$(nproc) bzImage           # ~10-20 menit di 12 core
mkdir -p /mnt/c/Users/<user>/wsl-kernel
cp arch/x86/boot/bzImage /mnt/c/Users/<user>/wsl-kernel/bzImage
```

Edit `C:\Users\<user>\.wslconfig` — **tambahkan** baris `kernel=`, jangan hapus setelan lain:

```ini
[wsl2]
kernel=C:\\Users\\<user>\\wsl-kernel\\bzImage
```

Backslash harus ganda. Lalu:

```powershell
wsl --shutdown
wsl -e uname -r        # harus berakhiran "+" → 5.15.167.4-microsoft-standard-WSL2+
```

> **Konsekuensi:** selama baris `kernel=` ada, `wsl --update` **tidak** akan mengganti kernel ini.
> Anda tidak lagi menerima patch keamanan kernel otomatis. Untuk kembali ke bawaan, hapus baris
> tersebut lalu `wsl --shutdown`.

---

## Bagian 3 — Menghubungkan card reader ke WSL

Butuh [usbipd-win](https://github.com/dorssel/usbipd-win). Dari PowerShell **sebagai Administrator**:

```powershell
usbipd list                              # cari busid card reader
usbipd bind --busid 1-2                  # sekali saja; tambah --force bila ada USB filter
usbipd attach --wsl --busid 1-2          # ulangi tiap reboot / cabut-colok
```

Konfirmasi di WSL:

```bash
lsblk                    # harus muncul /dev/sdd (atau sdX lain)
dmesg | tail -20
```

Yang benar terlihat seperti ini:

```
usb-storage 1-1:1.0: USB Mass Storage device detected
scsi host1: usb-storage 1-1:1.0
sd 1:0:0:0: [sdd] 15687680 512-byte logical blocks: (8.03 GB/7.48 GiB)
sd 1:0:0:0: [sdd] Attached SCSI removable disk
```

> **Awas:** WSL VM mati sendiri setelah idle, dan attachment ikut hilang. Kalau `/dev/sdd`
> tiba-tiba lenyap, cek `usbipd list` — statusnya kembali `Shared`. Attach ulang.

---

## Bagian 4 — Flash firmware

### 4.1 Ekstrak

```bash
mkdir -p ~/luckfox-fw && cd ~/luckfox-fw
unzip /mnt/c/Users/<user>/Downloads/Ubuntu_Luckfox_Pico_Mini_B_MicroSD_250313.zip
```

Isinya 13 file. Yang ditulis ke kartu hanya 7 `.img`. `download.bin` untuk mode maskrom via USB,
dan **`update.img` tidak bisa di-`dd`** — itu paket format Rockchip RKFW untuk SocToolKit.

### 4.2 Peta offset

Diambil dari `sd_update.txt` bawaan firmware, dan sudah dicocokkan dengan `blkdevparts` di `.env.txt`:

```
blkdevparts=mmcblk1:32K(env),512K@32K(idblock),256K(uboot),32M(boot),512M(oem),256M(userdata),6G(rootfs)
```

| Image | Offset (byte) | Offset (sektor) |
|---|---:|---:|
| `env.img` | 0 | 0 |
| `idblock.img` | 32.768 | 64 |
| `uboot.img` | 557.056 | 1.088 |
| `boot.img` | 819.200 | 1.600 |
| `oem.img` | 34.373.632 | 67.136 |
| `userdata.img` | 571.244.544 | 1.115.712 |
| `rootfs.img` | 839.680.000 | 1.640.000 |

Penulisan berakhir di ~1,98 GB, jadi kartu 8 GB lebih dari cukup.

### 4.3 Soal `blkenvflash.py`

Skrip resminya ada di
`https://raw.githubusercontent.com/themrleon/luckfox-pico-mini-b/main/tools/blkenvflash.py`.
Skrip itu **benar** — offset yang dihasilkan akumulator internalnya cocok persis dengan tabel di atas.

Tapi ia memakai `bs=1k`. Untuk `rootfs.img` 1,08 GB itu ~1,1 juta syscall write; lewat USB/IP setiap
operasi menambah round-trip, jadi realistis berjam-jam. Skrip di bawah memakai offset identik
dengan blok besar.

### 4.4 Skrip flash

Simpan sebagai `flash.sh`, sesuaikan `DEV`, `FW`, dan `EXPECT_SIZE`:

```sh
#!/bin/sh
# Setara blkenvflash.py (offset identik), tapi O_DIRECT bs=4M + verifikasi.
set -e

DEV=/dev/sdd
FW=$HOME/luckfox-fw/Ubuntu_Luckfox_Pico_Mini_B_MicroSD_250313
EXPECT_SIZE=8032092160

IMGS="env:0 idblock:32768 uboot:557056 boot:819200 oem:34373632 userdata:571244544 rootfs:839680000"

echo "=== PEMERIKSAAN KESELAMATAN ==="
SIZE=$(blockdev --getsize64 "$DEV")
[ "$SIZE" = "$EXPECT_SIZE" ] || { echo "ABORT: ukuran $DEV = $SIZE, diharapkan $EXPECT_SIZE"; exit 1; }
[ "$(cat /sys/block/$(basename $DEV)/removable)" = "1" ] || { echo "ABORT: $DEV bukan removable"; exit 1; }
echo "  $DEV size=$SIZE removable=1 -> OK"
umount /mnt/sd 2>/dev/null || true

echo "=== TULIS ==="
for e in $IMGS; do
  name=${e%%:*}; off=${e##*:}
  f="$FW/$name.img"
  [ -f "$f" ] || { echo "ABORT: $f tidak ada"; exit 1; }
  sz=$(stat -c%s "$f")
  printf '  %-13s offset %12s  %10s byte ... ' "$name.img" "$off" "$sz"
  dd if="$f" of="$DEV" bs=4M oflag=direct,seek_bytes seek="$off" status=none
  echo "OK"
done
sync

echo "=== VERIFIKASI READ-BACK ==="
fail=0
for e in $IMGS; do
  name=${e%%:*}; off=${e##*:}
  f="$FW/$name.img"; sz=$(stat -c%s "$f")
  a=$(sha256sum "$f" | cut -d' ' -f1)
  b=$(dd if="$DEV" bs=4M iflag=direct,skip_bytes,count_bytes skip="$off" count="$sz" status=none | sha256sum | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then printf '  %-13s COCOK\n' "$name.img"
  else printf '  %-13s BEDA!\n    file: %s\n    disk: %s\n' "$name.img" "$a" "$b"; fail=1; fi
done
[ "$fail" = "0" ] && echo "=== SEMUA COCOK ===" || { echo "=== ADA YANG TIDAK COCOK ==="; exit 1; }
```

Jalankan **dari PowerShell**, bukan Git Bash (Git Bash menerjemahkan `/home/...` jadi
`C:/Program Files/Git/home/...`):

```powershell
wsl -u root -e sh /home/<user>/luckfox-fw/flash.sh
```

Waktu tempuh: ~5 menit menulis + ~4 menit verifikasi, di ~6,2 MB/s.

### 4.5 `oflag=direct` itu wajib, bukan optimasi

Tanpa O_DIRECT penulisan gagal seperti ini:

```
sd 1:0:0:0: [sdd] tag#0 Sense Key : 0x3 [current]      ← MEDIUM ERROR
sd 1:0:0:0: [sdd] tag#0 ASC=0x3 ASCQ=0x0               ← PERIPHERAL DEVICE WRITE FAULT
blk_update_request: I/O error, dev sdd, sector 64 op 0x1:(WRITE) flags 0x4800 phys_seg 30
```

Ini **bukan** kartu rusak dan **bukan** batas ukuran transfer — tulis 64 MB dengan O_DIRECT
berjalan mulus. Kuncinya di `phys_seg 30`: writeback async dari page cache menghasilkan
scatter-gather 30 segmen yang tidak sanggup dilayani reader murah ini lewat USB/IP, sementara
O_DIRECT mengirim buffer kontigu.

Syarat O_DIRECT: semua offset dan ukuran image harus kelipatan logical block size (512).
Untuk firmware ini semuanya sudah memenuhi.

### 4.6 Setelah selesai

```powershell
wsl -u root -e sync
usbipd detach --busid 1-2
```

> **JANGAN FORMAT.** Saat kartu dicolok ke Windows akan muncul
> *"You need to format the disk before you can use it"*. Itu normal — kartu berisi layout
> Rockchip mentah tanpa partition table yang dikenali Windows. Klik **Cancel**.

---

## Bagian 5 — Boot dan akses board

Cabut kartu, pasang ke Luckfox, colok USB. Board otomatis boot dari SD bila kartu ada,
dan jatuh ke SPI flash internal bila tidak.

### 5.1 Konfirmasi board hidup

```powershell
Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -match 'VID_2207'} |
  Select-Object Status,Class,FriendlyName
```

Yang diharapkan:

```
USB\VID_2207&PID_0019&MI_00  →  Remote NDIS based Internet Sharing Device
USB\VID_2207&PID_0019&MI_02  →  ADB Interface
```

`2207` = Rockchip. PID `0019` = mode gadget normal — kalau yang muncul PID `110c`/`110b`,
board masuk **maskrom**, artinya boot gagal.

### 5.2 ADB (tidak butuh konfigurasi IP)

Platform-tools portabel, tanpa instalasi sistem:

```powershell
Invoke-WebRequest -Uri "https://dl.google.com/android/repository/platform-tools-latest-windows.zip" -OutFile "$env:TEMP\pt.zip"
Expand-Archive "$env:TEMP\pt.zip" -DestinationPath "$env:USERPROFILE\platform-tools" -Force
& "$env:USERPROFILE\platform-tools\platform-tools\adb.exe" devices -l
```

Board akan muncul sebagai `product:occam model:Nexus_4 device:mako` — itu deskriptor ADB
bawaan Rockchip, normal. `adb shell` memberi **root tanpa password**.

### 5.3 SSH

Alamat board: **`172.32.0.70/16`** pada `usb0`.

> Banyak dokumentasi menyebut `172.32.0.93` — pada image ini **salah**. Cek sendiri dengan
> `adb shell "ip -4 addr show usb0"`.

Board tidak menjalankan DHCP server, jadi Windows hanya dapat APIPA (`169.254.x.x`) dan tidak
bisa menjangkaunya. Set IP statis pada adapter RNDIS (namanya biasanya `Ethernet 2`):

```powershell
New-NetIPAddress -InterfaceAlias "Ethernet 2" -IPAddress 172.32.0.100 -PrefixLength 24
ssh pico@172.32.0.70
```

Kredensial terverifikasi: **`pico` / `luckfox`**. Root shell juga tersedia via `adb shell`.

Mengembalikan adapter ke DHCP:

```powershell
Remove-NetIPAddress -InterfaceAlias "Ethernet 2" -IPAddress 172.32.0.100 -Confirm:$false
Set-NetIPInterface -InterfaceAlias "Ethernet 2" -Dhcp Enabled
```

### 5.4 Verifikasi hasil flash dari sisi board

```bash
cat /proc/cmdline      # harus memuat storagemedia=sd  ← bukti boot dari SD
uname -a               # Linux luckfox 5.10.160 #8 Thu Mar 13 21:14:48 CST 2025 armv7l
cat /etc/os-release    # Ubuntu 22.04.3 LTS
cat /proc/partitions   # mmcblk1p1..p7
df -h                  # / (5,9G) + /oem (488M) + /userdata (238M)
```

Partisi yang benar terbentuk:

| Partisi | Blok | Deklarasi |
|---|---:|---|
| `mmcblk1p1` | 32 K | env |
| `mmcblk1p2` | 512 K | idblock |
| `mmcblk1p3` | 256 K | uboot |
| `mmcblk1p4` | 32.768 K | boot |
| `mmcblk1p5` | 524.288 K | oem |
| `mmcblk1p6` | 262.144 K | userdata |
| `mmcblk1p7` | 6.291.456 K | rootfs |

---

## Bagian 6 — Memberi board akses internet

RNDIS hanya membuat kabel virtual board↔PC. Tidak ada berbagi internet otomatis. Dua hal hilang:

1. **Board tanpa default route** — `ip route` hanya berisi `172.32.0.0/16 dev usb0`.
   Penyebabnya `/etc/init.d/S50usbdevice` cuma menjalankan `ifconfig usb0 172.32.0.70` tanpa gateway.
2. **Windows tidak meneruskan paket** — `Forwarding` = `Disabled` dan tidak ada NAT.

### 6.1 Sisi Windows (Administrator)

```powershell
Set-NetIPInterface -InterfaceAlias "Ethernet 2" -Forwarding Enabled
Set-NetIPInterface -InterfaceAlias "Wi-Fi"      -Forwarding Enabled
New-NetNat -Name LuckfoxNat -InternalIPInterfaceAddressPrefix 172.32.0.0/24
```

Persisten lintas reboot. Membatalkan:

```powershell
Remove-NetNat -Name LuckfoxNat -Confirm:$false
Set-NetIPInterface -InterfaceAlias "Ethernet 2" -Forwarding Disabled
Set-NetIPInterface -InterfaceAlias "Wi-Fi"      -Forwarding Disabled
```

### 6.2 Sisi board

Sementara:

```bash
ip route add default via 172.32.0.100 dev usb0
```

Permanen — sisipkan ke `/etc/init.d/S50usbdevice`, **bukan** ke `/etc/rc.local`. Alasannya
`rc.local` menjalankan loop `usb_reset` yang me-restart `S50usbdevice` setiap USB terputus,
dan restart itu menjalankan ulang `ifconfig usb0` yang menghapus default route:

```bash
cp /etc/init.d/S50usbdevice /etc/init.d/S50usbdevice.bak
sed -i 's|^\(\s*\)ifconfig usb0 up|\1ifconfig usb0 up\n\1ip route add default via 172.32.0.100 dev usb0 2>/dev/null|' \
  /etc/init.d/S50usbdevice
bash -n /etc/init.d/S50usbdevice && echo "sintaks OK"
sync
```

DNS tidak perlu disentuh — systemd-resolved di image ini sudah berfungsi.

### 6.3 Verifikasi

```bash
ping -c 3 8.8.8.8
curl -4 -sI https://deb.debian.org | head -1
apt-get update
```

Hasil yang terbukti: ping 0% loss / 19 ms, HTTPS 200, `apt update` mengunduh 30,7 MB dalam 54 detik
(570 kB/s) dan mengenali 113.267 nama paket.

> Internet board bergantung pada PC ini — harus menyala, terhubung jaringan, dan kabel USB tercolok.

---

## Bagian 7 — Konsol serial UART2

Ini jalur akses paling penting begitu USB dipakai untuk hal lain. Ia tidak pernah hilang.

### 7.1 UART mana

Dari `/proc/cmdline` board:

```
earlycon=uart8250,mmio32,0xff4c0000 console=ttyFIQ0
```

Pada RV1106, `0xff4c0000` adalah base address **UART2**. Jadi konsol debug ada di UART2,
bukan UART0. Sambungkan **TX, RX, GND saja** — 115200 8N1.

### 7.2 Soal adapter "5V"

Jangan sambungkan pin VCC adapter ke board yang sudah punya sumber daya sendiri; itu membuat
dua sumber beradu. Cukup tiga kabel sinyal.

Dengan VCC dibiarkan menggantung, jumper 5V/3,3V pada modul PL2303 **tidak relevan** — jumper itu
hanya mengatur pin VCC yang tidak Anda pakai. Pada pengujian nyata, modul PL2303 berlabel 5V
bekerja normal tanpa merusak board karena yang menyentuh pin UART hanyalah level sinyal, dan pada
mayoritas modul level itu mengikuti regulator 3,3V internal chip.

> Tetap perlu diketahui: pad GPIO RV1106 secara spesifikasi bukan 5V-tolerant. Kalau ragu, ukur
> tegangan pin TX adapter saat idle. ~3,3V berarti aman sepenuhnya.

### 7.3 Akses dari Windows

PuTTY:

```powershell
& "C:\Program Files\PuTTY\putty.exe" -serial COM8 -sercfg 115200,8,n,1,N
```

Cari nomor COM-nya dengan:

```powershell
Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -match 'VID_067B'} |
  Select-Object Status,FriendlyName
```

> Satu port hanya bisa dipakai satu program. Tutup PuTTY sebelum skrip lain memakai COM-nya.

Login: `pico` / `luckfox`, atau `root` / `root` (khusus konsol, lihat 7.4).

### 7.4 Root lewat SSH ditolak — itu bukan salah password

`/etc/ssh/sshd_config` memuat `#PermitRootLogin prohibit-password` dalam keadaan **ter-comment**,
sehingga default OpenSSH berlaku: root hanya boleh masuk dengan kunci, tidak pernah dengan
password. Akun root sendiri aktif (`passwd -S root` → `P`), dan di konsol serial ia bekerja normal.

Jalur yang benar lewat SSH:

```bash
ssh pico@<IP-BOARD>
sudo -i
```

Ingat bedanya: `su` meminta password **root**, sedangkan `sudo` meminta password **akun Anda**.
Salah satu ini paling sering bikin bingung setelah mengganti password.

---

## Bagian 8 — Mengubah USB ke mode host

Board hanya punya satu port USB. Mode host membuatnya bisa menerima perangkat (dongle WiFi,
flashdisk, kamera UVC) — tapi **ADB dan RNDIS hilang permanen** sampai mode dikembalikan.
Siapkan konsol serial (Bagian 7) sebelum melakukan ini.

### 8.1 Cara kerjanya

`luckfox-config` menyimpan mode bukan di file konfigurasi biasa, melainkan **langsung ke partisi
boot**. Urutannya: baca header FIT 2048 byte dari `/dev/mmcblk1p4`, ambil FDT dari offset 2048,
terapkan overlay `dr_mode="host"`, tulis balik, lalu perbarui `data-size` dan hash SHA256 di
header FIT supaya U-Boot tidak menolak image.

Konsekuensinya: **pemulihan = tulis ulang partisi boot**, bukan mengedit file di rootfs.
`USB_MODE=host` di `/etc/luckfox.cfg` hanya catatan — tidak pernah dibaca ulang saat boot.

### 8.2 Cadangkan dulu

```bash
dd if=/dev/mmcblk1p4 of=/userdata/boot_p4_before_host.bin bs=1M count=4
sync
```

Lalu tarik ke PC (`adb pull`, atau salin lewat jaringan). Ini titik pulih paling presisi.

### 8.3 Menerapkan

Menu `luckfox-config` berbasis `dialog` dan tidak punya argumen CLI, jadi jalankan interaktif
lewat konsol serial: **Advanced Options → USB → host**, lalu reboot.

### 8.4 Verifikasi

```powershell
Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -match 'VID_2207'}
```

Kosong = mode host aktif (board bukan lagi perangkat USB). Dari sisi board:

```bash
cat /proc/device-tree/usbdrd/usb@ffb00000/dr_mode   # host
lsusb                                               # harus muncul dua root hub
```

Kehadiran **root hub** adalah bukti kuat: dalam mode peripheral tidak ada root hub sama sekali.

### 8.5 Daya — kendala fisik yang nyata

Dalam mode host, port USB-C harus **memberi** daya, bukan menerima. Board tidak punya regulator
VBUS yang dikendalikan software (tidak ada node vbus/extcon di device tree, `/sys/class/power_supply`
kosong), jadi dayanya harus datang dari luar. Board Pico Mini B punya pad **VBUS** (bukan pad 5V),
yang satu net dengan VBUS konektor USB-C.

Pilihan, dari yang paling andal:

1. **Powered USB OTG hub** — hub menyuplai dongle, board tidak menanggungnya
2. **Adapter OTG dengan input daya** (Y-cable)
3. **Injeksi 5V ke pad VBUS** — harus sumber kuat (≥1 A). Pin VCC modul PL2303 **tidak cukup**:
   sudah diuji dan board gagal boot sama sekali

> Gejala daya kurang: board kadang tidak menyala sama sekali (konsol sunyi dari detik nol),
> atau boot lalu tidak stabil begitu WiFi mulai transmit. Kalau Oops menampilkan rentang stack
> mustahil seperti `Stack: (0xaef549f8 to 0xb3042000)` — 62 MB — itu nilai korup, dan korupsi
> memori sangat cocok dengan tegangan yang melorot.

**Kasus nyata yang terjadi di sini.** Susunan awal memakai **hub OTG pasif** (tanpa input daya).
Hub pasif hanya membagi satu jalur VBUS, sehingga board (~150–300 mA) dan dongle (~200–300 mA
saat transmit) berebut satu sumber lewat konektor dan jalur tipis. Akibatnya:

- Board crash empat kali, selalu berkaitan dengan aktivitas WiFi
- Beberapa kali gagal boot total, konsol sunyi sejak detik nol
- Sekali reset spontan tanpa dump — tanda khas brownout

Setelah susunan daya diperbaiki, board berhenti gagal boot dan `reboot` lewat SSH berjalan normal.

> **Batas dari perbaikan ini.** Daya menjelaskan **gagal boot** — konsol sunyi dari detik nol,
> dan reset spontan. Ia **tidak** menjelaskan kernel Oops yang muncul saat WiFi aktif; itu bug
> driver yang berdiri sendiri (9.8). Saya sempat menyatukan keduanya sebagai satu masalah daya,
> dan itu keliru — keduanya nyata tapi terpisah.

Pelajarannya tetap berlaku: kalau board gagal menyala atau reset acak, **periksa daya dulu**.
Tapi jangan berhenti di situ kalau gejalanya berupa Oops dengan jejak modul — rekam konsol dari
detik nol dan baca header-nya.

---

## Bagian 9 — Dongle WiFi USB (TP-Link TL-WN725N / RTL8188EU)

### 9.1 Image bawaan tidak punya drivernya

`insmod_wifi.sh` memang punya cabang untuk beberapa dongle USB, tapi file `.ko`-nya tidak pernah
disertakan. Driver USB yang terdaftar di image bawaan hanya:

```
hub  usb  usb-storage  usbfs  uvcvideo
```

Satu-satunya driver WiFi yang ada adalah `aic8800_*` (SDIO, untuk varian board "W" — model
`Luckfox Pico Mini` tidak akan pernah menjalankannya).

### 9.2 Build dari staging (yang berhasil)

Kernel SDK 5.10.160 punya `drivers/staging/rtl8188eu`, dan vermagic-nya cocok karena
`CONFIG_MODVERSIONS` mati dan `CONFIG_LOCALVERSION=""` — jadi tidak perlu `Module.symvers`
dari build asli Luckfox.

```bash
K=~/src/luckfox-pico/sysdrv/source/kernel
O=~/src/luckfox-pico/sysdrv/source/objs_kernel
CC=~/src/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf-
cd $K
scripts/config --file $O/.config --module R8188EU \
               --module LIB80211 --module LIB80211_CRYPT_WEP --module LIB80211_CRYPT_CCMP
make O=$O ARCH=arm CROSS_COMPILE=$CC olddefconfig
make O=$O ARCH=arm CROSS_COMPILE=$CC modules -j$(nproc)
${CC}strip --strip-debug $O/drivers/staging/rtl8188eu/r8188eu.ko
```

`lib80211` **wajib** — tanpa itu `insmod` gagal dengan `Unknown symbol lib80211_get_crypto_ops`.

> Bangun target `modules` penuh, jangan `M=net/wireless` — direktori itu punya tracepoint dan
> akan gagal dengan `fatal error: ./trace.h: No such file or directory`.

Firmware eksternal juga diperlukan (tidak embedded di 5.10):

```bash
curl -fsSL -o rtl8188eufw.bin \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rtlwifi/rtl8188eufw.bin
# taruh di board: /lib/firmware/rtlwifi/rtl8188eufw.bin
```

Salin `r8188eu.ko`, `lib80211.ko`, `lib80211_crypt_ccmp.ko` ke `/oem/usr/ko/`.
(`lib80211_crypt_wep.ko` gagal dimuat karena kurang simbol arc4 — abaikan, WEP tidak dipakai.)

### 9.3 Temuan kunci: driver ini WEXT, bukan nl80211

Inilah inti dari seluruh masalah WiFi:

```
nl80211: Driver does not support authentication/association or connect commands
```

`r8188eu` mendaftar ke cfg80211 tapi tidak mengimplementasikan perintah connect/auth nl80211 —
ia memakai **wireless extensions**. Konsekuensinya:

- `wpa_supplicant` **wajib** dijalankan dengan `-D wext`
- **NetworkManager harus dijauhkan sepenuhnya.** NM memaksa jalur nl80211 dan memicu
  `BUG: scheduling while atomic` lalu kernel Oops. Ini bukan hipotesis — terjadi dua kali.

Jauhkan NM:

```bash
cat > /etc/NetworkManager/conf.d/99-unmanage-wifi.conf <<EOF
[keyfile]
unmanaged-devices=type:wifi
EOF
```

> Kalau profil NM sudah terlanjur dibuat dengan `autoconnect=yes`, board akan crash **setiap boot**
> dan konsol dibanjiri dump stack berjam-jam. Satu-satunya jalan keluar praktis adalah perbaikan
> offline lewat kartu SD (Bagian 10).

### 9.4 Nama interface berubah

systemd mengganti nama `wlan0` menjadi `wlx<mac>`:

```
r8188eu 1-1:1.0 wlx6c4cbc88e05a: renamed from wlan0
```

Semua skrip harus mendeteksi interface secara dinamis, jangan mem-patok `wlan0`:

```sh
IF=$(ls /sys/class/net | grep -E "^wl" | head -1)
```

### 9.5 Kredensial

```bash
mkdir -p /etc/wpa_supplicant
{
  echo "ctrl_interface=/run/wpa_supplicant"
  echo "update_config=1"
  echo "country=ID"
  wpa_passphrase "SSID" "PASSWORD" | grep -v '#psk='   # buang baris password polos
} > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
```

`grep -v '#psk='` penting: `wpa_passphrase` mencetak password polos sebagai komentar.
Setelah dibuang, yang tersimpan hanya hash 64 hex.

> Sebaliknya, NetworkManager menyimpan PSK **dalam teks polos** di `.nmconnection`.

### 9.6 Menyambung — dan kapan menjalankannya

Urutan yang terbukti bekerja:

```bash
ip link set "$IF" up
wpa_supplicant -B -D wext -i "$IF" -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
# tunggu wpa_state=COMPLETED
dhclient -nw "$IF"
```

**Jangan jalankan ini dari `rc.local`.** Sudah dicoba dan board hang saat boot. Pakai systemd
service yang berjalan setelah sistem tenang:

```ini
[Unit]
Description=Luckfox WiFi (RTL8188EU via wpa_supplicant WEXT)
After=multi-user.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 15
ExecStart=/usr/local/sbin/luckfox-wifi-up.sh
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

Sementara `/oem/usr/ko/insmod_rtl8188eu.sh` cukup memuat modul saja, tanpa menyambung.

Hasil terverifikasi: asosiasi WPA2-PSK/CCMP, `wpa_state=COMPLETED`, IP dari DHCP,
ping 8.8.8.8 0% loss, HTTPS 200, SSH dari laptop tembus.

### 9.7 Jalan buntu yang tidak perlu diulang

**Driver vendor Rockchip** (`drivers/net/wireless/rockchip_wlan/rtl8188eu`) terlihat menjanjikan
tapi **tidak bisa dipakai**. Penjaga versi tertingginya berhenti di `KERNEL_VERSION(5, 1)`,
sedangkan kernel board 5.10. Rentetan errornya: `struct sha256_state` bentrok dengan `crypto/sha.h`,
VLA terlarang di `ioctl_mp.c`, `ndo_select_queue` berubah signature di 5.2, `mgmt_frame_register`
dihapus dari `cfg80211_ops` di 5.8 — dan tidak ada cara tahu berapa lagi setelahnya.

Petunjuk yang seharusnya saya baca lebih awal: Rockchip **tidak menyambungkan** direktori itu ke
`Kconfig` maupun `Makefile` induk. Mereka sendiri tidak membangunnya untuk kernel ini.

**Chipset WiFi 6** (mis. Archer TX20U Nano / RTL8852BU) tidak didukung sama sekali: driver vendor
terbaru di SDK hanya sampai RTL8822B (WiFi 5), `rtw88` di 5.10 masih PCIe saja, dan `rtw89`
belum ada. Perlu driver out-of-tree, dengan kendala RAM 56 MB yang serius.

### 9.8 Driver staging punya bug fatal — ganti dengan yang dirawat

Driver `r8188eu` dari `drivers/staging` **berhasil menyambung WiFi**, tapi menyebabkan kernel
Oops berulang. Butuh empat crash dan beberapa jam salah tebak sebelum penyebabnya tertangkap
utuh dengan merekam konsol dari detik nol:

```
[38.959] BUG: scheduling while atomic: dhclient/586/0x00000200
[39.004] Unable to handle kernel paging request at virtual address a6947008
[39.020] Internal error: Oops: 80f [#1] THUMB2
[39.025] Modules linked in: r8188eu(CO) lib80211_crypt_ccmp lib80211 cfg80211
[39.032] CPU: 0 PID: 586 Comm: dhclient
[39.080] Flags: Nzcv  IRQs on  FIQs on  Mode USER_32  ISA Thumb  Segment user
```

Bacaannya: driver **membocorkan preempt count** (`0x200` = preempt count 2 yang tidak pernah
dilepas — biasanya spinlock yang lupa di-unlock). Setelah state kernel rusak, page fault biasa
di userspace ikut dilaporkan sebagai Oops. Perhatikan `Mode USER_32` dan `Segment user`:
alamat PC-nya milik userspace, bukan kernel.

> **Koreksi penting.** Rentang stack mustahil seperti `Stack: (0xaef549f8 to 0xb3042000)` — 62 MB —
> sempat saya baca sebagai tanda korupsi memori akibat tegangan melorot. Itu keliru: nilai itu
> **akibat** preempt count yang korup, bukan penyebabnya. Crash ini bug software murni.
> Masalah daya (8.5) nyata dan terpisah — ia menyebabkan **gagal boot**, bukan crash ini.

Pemicunya bergantian antara `dhclient` dan `NetworkManager`; keduanya menyentuh jalur kode
yang sama. Ini juga menjelaskan kenapa mematok profil NM ke `wlan0` yang tidak ada dulu
"menyelamatkan" board — NM tidak pernah benar-benar menyentuh driver.

**Solusinya: `aircrack-ng/rtl8188eus`** — turunan Realtek yang dipelihara sampai kernel 6.x.
Berbeda dari driver vendor Rockchip (9.7) yang mentok di kernel 5.1.

```bash
cd ~/luckfox-wifi
git clone --depth 1 https://github.com/aircrack-ng/rtl8188eus.git
cd rtl8188eus

# platform: dari I386_PC ke ARM_RPI (blok Linux generik, tanpa definisi Android)
sed -i 's/^CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' Makefile
sed -i 's/^CONFIG_PLATFORM_ARM_RPI = n/CONFIG_PLATFORM_ARM_RPI = y/' Makefile

make ARCH=arm CROSS_COMPILE=$CC KSRC=$O \
     USER_EXTRA_CFLAGS="-Wno-implicit-fallthrough -Wno-error -Wno-misleading-indentation \
                        -Wno-stringop-truncation -Wno-vla -Wno-unused-but-set-variable" -j$(nproc)
${CC}strip --strip-debug 8188eu.ko
```

Blok `ARM_RPI` dipilih karena memakai `?=` untuk `ARCH`/`CROSS_COMPILE` sehingga override dari
command line berlaku, dan tidak mendefinisikan `CONFIG_PLATFORM_ANDROID` seperti blok `RK3188`.

**Satu tambalan diperlukan.** Kernel 5.4+ menaruh `filp_open` dan `kernel_read` dalam namespace
terbatas, sehingga `modpost` menolak:

```
ERROR: modpost: module 8188eu uses symbol kernel_read from namespace
VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver, but does not import it.
```

Cukup satu baris di `os_dep/linux/os_intfs.c`, tepat sebelum `MODULE_LICENSE`:

```c
MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);
```

Hasilnya `8188eu.ko` (1,16 MB setelah strip), vermagic cocok, dan **hanya bergantung pada
`cfg80211`** — `lib80211` dan `lib80211_crypt_ccmp` tidak lagi diperlukan.

### 9.9 IP statis, bukan DHCP

`dhclient` adalah pemicu crash tersering, jadi dihapus dari persamaan. Skrip penyambung memakai:

```sh
ip addr add <IP-BOARD>/24 dev "$IF"
ip route add default via <GATEWAY> dev "$IF"
```

Driver baru mendukung nl80211 dengan benar (`CONFIG_IOCTL_CFG80211`), jadi `-D wext` tidak lagi
wajib — tapi skrip mencoba nl80211 dulu lalu jatuh ke wext, supaya aman terhadap keduanya.

Alternatif yang lebih rapi kalau Anda mengelola router: buat **DHCP reservation** untuk MAC
`<MAC-DONGLE>`, sehingga board tetap memakai DHCP tapi selalu mendapat alamat sama.

### 9.10 Hasil setelah penggantian

Beban yang sebelumnya **selalu** menjatuhkan board kini lewat tanpa jejak:

```
3x unduh 1,7 MB   →  ~400 KB/s, mulus
apt update        →  8,9 MB dalam 21 detik (425 KB/s)
Oops sejak boot   →  0
```

---

## Bagian 10 — Perbaikan offline lewat kartu SD

Jalur pemulihan paling andal. Tidak butuh board menyala, tidak butuh timing, tidak bisa gagal
karena board hang.

### 10.1 Jebakan: `blkdevparts` bukan partition table

Partisi board didefinisikan lewat **cmdline kernel**, bukan tabel partisi sungguhan. Linux biasa
tidak akan melihat `mmcblk1p7` di kartu. Harus mount pakai offset:

```bash
# rootfs (mmcblk1p7)
L1=$(losetup -o 839680000 --sizelimit 6442450944 -f --show /dev/sdd)
mount -t ext4 "$L1" /mnt/lfroot

# oem (mmcblk1p5)
L2=$(losetup -o 34373632 --sizelimit 536870912 -f --show /dev/sdd)
mount -t ext4 "$L2" /mnt/lfoem
```

Selalu verifikasi kartu yang benar sebelum menulis:

```bash
[ "$(blockdev --getsize64 /dev/sdd)" = "8032092160" ] || exit 1
cat /mnt/lfroot/etc/hostname    # harus "luckfox"
```

Selesai:

```bash
sync; umount /mnt/lfroot /mnt/lfoem; losetup -D
```

### 10.2 Yang biasanya perlu diperbaiki di sini

| Masalah | Perbaikan |
|---|---|
| Crash loop karena profil NM | Hapus `/etc/NetworkManager/system-connections/*.nmconnection` |
| NM menyentuh WiFi | Tambah `conf.d/99-unmanage-wifi.conf` dengan `unmanaged-devices=type:wifi` |
| Board hang saat boot | Kosongkan bagian penyambungan di `/oem/usr/ko/insmod_rtl8188eu.sh` |
| Kembali ke mode peripheral | Tulis balik cadangan partisi boot ke offset 819200 |

### 10.3 Catatan menjalankannya

WSL harus sedang berjalan sebelum `usbipd attach`, kalau tidak muncul
`There is no WSL 2 distribution running`:

```powershell
Start-Process wsl.exe -ArgumentList "-e","sleep","600" -WindowStyle Hidden
usbipd attach --wsl --busid 1-1
```

Mount tidak bertahan antar pemanggilan `wsl -e` yang terpisah — kerjakan semuanya dalam **satu**
skrip. Dan tulis skripnya sebagai file lalu jalankan (`wsl -u root -e sh /tmp/fix.sh`); perintah
shell panjang yang di-inline lewat PowerShell akan diacak escaping-nya. Jangan lupa `tr -d '\r'`
kalau file dibuat di Windows.

---

## Bagian 11 — Kamera CSI (SC3336)

**Kamera BISA berjalan di image Ubuntu.** Kesimpulan awal saya — bahwa RAM 56 MB terlalu sempit
dan kamera hanya mungkin di Buildroot — **terbukti salah**.

Penyebab sebenarnya dua hal, keduanya bisa diperbaiki:

1. **Fragmentasi memori**, bukan kekurangan RAM. `devm_kmalloc` di `rkisp_plat_probe` butuh
   halaman fisik kontigu orde tinggi. `/proc/buddyinfo` menunjukkan orde-8 berjumlah **nol**
   padahal `MemFree` 17 MB. Setelah `drop_caches` + `compact_memory`, probe berhasil.
2. **Urutan pemuatan modul**. Sensor harus terdaftar sebelum `video_rkcif` probe, kalau tidak
   async notifier gagal menautkannya (`remote pad is null`).

Terbukti menangkap frame nyata pada 320×240 dan 640×480. Resolusi lebih tinggi dibatasi CMA
bawaan 1 MB — dan **di situlah** menaikkan `rk_dma_heap_cma` benar-benar tepat, berbeda dari
percobaan awal saya yang menaikkannya untuk memperbaiki probe ISP (tidak berhasil dan justru
memangkas `MemTotal` 15 MB).

> Catatan untuk pembaca: baris `No reserved memory region. default cma area!` **bukan** penyebab
> kegagalan probe, hanya informasi. Saya sempat mengejarnya berjam-jam ke arah yang salah.

Prosedur lengkap, skrip, contoh hasil tangkapan, dan cara memverifikasi bahwa datanya nyata
ada di repo terpisah — lihat **Contoh project** di bawah.

## Bagian 12 — Mengubah kernel bootargs (env U-Boot)

Berguna untuk `rk_dma_heap_cma`, `console`, atau parameter kernel lain. Teknik ini terverifikasi
dan aman selama CRC dihitung ulang.

### 12.1 Jalur yang tidak bekerja

- **`fw_setenv` tidak ada** di image ini
- **Ctrl+C saat power-up tidak menginterupsi U-Boot** — `bootdelay` tampaknya nol, tidak ada
  jendela sama sekali. Board langsung boot ke Linux meski Ctrl+C dikirim terus-menerus

### 12.2 Jalur yang bekerja: tulis langsung partisi env

Partisi `env` adalah `/dev/mmcblk1p1`, 32 KB, format U-Boot standar:

```
byte 0-3 : CRC32 little-endian
byte 4+  : key=value dipisah NUL, lalu padding nol sampai 32768
```

Isinya hanya tiga variabel: `blkdevparts`, `sys_bootargs`, `sd_parts`.

**Selalu cadangkan dulu**, lalu verifikasi format dengan mencocokkan CRC tersimpan dan CRC
hitungan sebelum menulis apa pun:

```python
import binascii
raw = open('/tmp/env.bin','rb').read()          # dd if=/dev/mmcblk1p1 bs=1k count=32
stored = int.from_bytes(raw[:4],'little')
calc   = binascii.crc32(raw[4:]) & 0xffffffff
assert stored == calc, "format tidak cocok - jangan tulis"

data = raw[4:].replace(b'rk_dma_heap_cma=1M', b'rk_dma_heap_cma=16M')
data = data[:len(raw)-4]                        # jaga panjang total; kelebihan diambil dari padding
crc  = binascii.crc32(data) & 0xffffffff
open('/tmp/env_new.bin','wb').write(crc.to_bytes(4,'little') + data)
```

Tulis, lalu **baca ulang dan verifikasi** sebelum reboot:

```bash
sudo dd if=/tmp/env_new.bin of=/dev/mmcblk1p1 bs=1k count=32 conv=fsync
sudo sync
sudo dd if=/dev/mmcblk1p1 of=/tmp/env_verify.bin bs=1k count=32
sha256sum /tmp/env_new.bin /tmp/env_verify.bin   # harus identik
```

Pemulihan kalau salah: tulis balik cadangan, atau ekstrak `env.img` dari paket firmware asli
dan tulis ke offset 0.

> Partisi `env` terpisah dari partisi `boot`, jadi cadangan `boot_p4_before_host.bin` tidak
> terpengaruh oleh perubahan ini — dan sebaliknya.

---

## Bagian 13 — Merampingkan sistem

### 13.1 Misteri load average 10 — dan jawabannya

Board idle menunjukkan load average konsisten **10–11**, padahal `vmstat` melaporkan CPU
**98–99% idle**. Penyebabnya bukan beban CPU sama sekali:

```
 311 D  vlog        316 D  venc
 312 D  valloc      317 D  rkisp-vir0
 313 D  vsys        318 D  vpss
 314 D  vrga_0      319 D  vrgn
 315 D  vrga_1      320 D  vmcu
```

Sepuluh thread kernel milik **`rockit`** (framework media Rockchip) tersangkut permanen di state
**D** — uninterruptible sleep. Linux menghitung proses state D ke dalam load average, jadi sepuluh
thread menghasilkan load ~10 tanpa memakai CPU sedikit pun.

Kenapa tersangkut? Salah satu namanya memberi petunjuk: `rkisp-vir0`. Mereka menunggu ISP yang
**tidak pernah berhasil probe** (Bagian 11). Jadi dua gejala yang tampak terpisah — kamera mati
dan load average aneh — ternyata satu akar masalah.

> Dugaan awal bahwa penyebabnya `rkipc` **terbukti salah**: `pgrep rkipc` menunjukkan proses itu
> tidak pernah berjalan.

### 13.2 Tidak bisa dilepas saat runtime

`rmmod rockit` **menggantung selamanya** — proses uninterruptible tidak bisa dibatalkan, bahkan
oleh `timeout`. `rmmod` sendiri lalu ikut masuk state D dan menaikkan load jadi 11. Satu-satunya
jalan adalah mencegahnya dimuat saat boot.

### 13.3 Ganti `insmod_ko.sh` dengan versi ramping

Karena ISP gagal probe, seluruh tumpukan media percuma. Cadangkan aslinya lalu ganti:

```sh
#!/bin/sh
cmd=`realpath $0`
_DIR=`dirname $cmd`
cd $_DIR

# driver WiFi tetap dimuat
$(pwd)/insmod_wifi.sh &
```

Yang tidak lagi dimuat: `rockit`, `video_rkisp`, `video_rkcif`, `mpp_vcodec`, `rga3`, `rknpu`,
`rk_dvbm`, `rve`, `phy_rockchip_csi2_dphy*`, dan seluruh driver sensor.
Asli tersimpan di `insmod_ko.sh.bak`.

### 13.4 Layanan lain

```bash
# NetworkManager tidak dipakai -- WiFi ditangani wpa_supplicant langsung
sudo systemctl disable NetworkManager NetworkManager-wait-online

# journald ke RAM saja: hemat memori dan memperpanjang umur kartu SD
sudo mkdir -p /etc/systemd/journald.conf.d
printf "[Journal]\nStorage=volatile\nRuntimeMaxUse=2M\n" | \
  sudo tee /etc/systemd/journald.conf.d/99-volatile.conf
```

### 13.5 Hasilnya

| Metrik | Sebelum | Sesudah |
|---|---:|---:|
| Load average (idle) | 10–11 | **0,3–0,5** |
| Thread state D | 10 | **0** |
| Modul termuat | 15 | **2** (`8188eu`, `cfg80211`) |
| `MemFree` | 1–7 MB | **13–24 MB** |
| `MemAvailable` | ~28 MB | **40 MB** |

Selisih ~12 MB `MemAvailable` itu besar pada board 56 MB — kira-kira sepertiga ruang kerja
yang tadinya terbuang.

---

## Contoh project

Repo ini fokus pada **platform**: menyiapkan board, flash, mode USB host, driver WiFi, konsol
serial, dan pemulihan lewat kartu SD. Implementasi di atasnya dipisah ke repo sendiri agar
keduanya tidak saling mengaburkan.

### 1. Telemetri via MQTT

**Repo:** https://github.com/apinblogsite/luckfox_pico_mini_B-Telemetry

Board menerbitkan suhu SoC, frekuensi CPU, load, memori, disk, sinyal WiFi, dan trafik jaringan
ke broker MQTT setiap 5 detik sebagai satu payload JSON datar. Mosquitto berjalan di board itu
sendiri, jadi ia sekaligus broker dan publisher.

Biaya sumber daya: **~6,5 MB RAM** total (mosquitto ~5,4 MB, publisher ~1,1 MB), menyisakan
~34 MB dari 56 MB. Konsumen yang sudah disiapkan di repo tersebut: jq, Python `paho-mqtt`,
Home Assistant, dan Node-RED.

Ini contoh yang cocok dengan karakter board — butuh jaringan dan logika di perangkat, bukan
butuh memori. Untuk perbandingan apa yang **tidak** muat di 56 MB (Node.js, Docker, database
server, Home Assistant *core*), lihat pembahasan di README repo tersebut.

### 2. Kamera CSI (SC3336)

**Repo:** https://github.com/apinblogsite/luckfox_pico_mini_B-Camera

Menjalankan kamera MIPI CSI-2 di image Ubuntu — yang semula saya simpulkan mustahil. Memuat
tumpukan kamera dengan kompaksi memori lebih dulu dan urutan modul yang benar, lalu menangkap
frame mentah lewat V4L2.

Berisi analisis `/proc/buddyinfo` sebelum-sesudah kompaksi, tabel kebutuhan buffer per resolusi
terhadap batas CMA, skrip konversi RAW10 ke gambar, dan cara membuktikan frame yang tertangkap
benar-benar dari sensor (bukan frame konstan yang ukurannya kebetulan benar).

## Troubleshooting

| Gejala | Penyebab | Solusi |
|---|---|---|
| `/dev/sdX` tidak muncul walau `usbipd attach` sukses | `CONFIG_USB_STORAGE` tidak aktif di kernel WSL bawaan | Bagian 2 |
| `/dev/sdX` hilang tiba-tiba | WSL VM idle dan mati, attachment lepas | `usbipd attach --wsl --busid 1-2` |
| `dd: fsync failed ... Input/output error`, Sense Key 0x3 | Buffered write menghasilkan SG list terfragmentasi | Pakai `oflag=direct` |
| Windows minta format kartu setelah flash | Layout Rockchip tanpa partition table | Klik **Cancel**, jangan format |
| `sh: 0: cannot open C:/Program Files/Git/home/...` | Translasi path MSYS di Git Bash | Jalankan lewat PowerShell |
| Board tidak bisa di-ping di `172.32.0.93` | Image ini pakai `172.32.0.70` | `adb shell "ip -4 addr show usb0"` |
| Windows dapat `169.254.x.x` di adapter RNDIS | Board tidak menjalankan DHCP server | Set IP statis (5.3) |
| Board tidak bisa internet | Tidak ada default route + NAT | Bagian 6 |
| Board muncul dengan PID `110c`/`110b` | Masuk maskrom — boot gagal | Cek ulang hasil flash |
| `bind` ditolak usbipd | Ada USB filter pihak ketiga | `usbipd bind --force --busid 1-2` |
| Konsol serial sunyi total dari detik nol | Board tidak menyala (daya kurang), atau GND lepas | Cek daya dulu; LED mati = daya, LED nyala = kabel sinyal (8.5) |
| Konsol dibanjiri dump stack berjam-jam | Kernel Oops dengan rentang stack korup | Cabut daya; perbaiki offline (Bagian 10) |
| Board crash tiap boot setelah setup WiFi | Profil NM `autoconnect` memicu jalur nl80211 | Hapus profil NM offline (10.2) |
| `wpa_supplicant` gagal: `Driver does not support ... connect commands` | Driver WEXT, bukan nl80211 | Tambah `-D wext` (9.3) |
| `insmod r8188eu.ko` → `Unknown symbol lib80211_get_crypto_ops` | `lib80211.ko` belum dimuat | Muat `lib80211.ko` dulu (9.2) |
| Skrip WiFi tidak jalan, `wlan0` tidak ada | systemd mengganti nama jadi `wlx<mac>` | Deteksi dinamis `^wl` (9.4) |
| Board hang saat boot setelah auto-connect dipasang | Penyambungan dijalankan dari `rc.local` | Pindah ke systemd service (9.6) |
| SSH `root@` tolak password yang benar | `PermitRootLogin prohibit-password` (default) | `ssh pico@` lalu `sudo -i` (7.4) |
| `su` tolak password baru | `su` minta password **root**, bukan password Anda | Pakai `sudo -i`, atau set `sudo passwd root` |
| `usbipd attach` → `no WSL 2 distribution running` | WSL VM mati | Jalankan WSL dulu (10.3) |
| ADB & RNDIS hilang | USB dalam mode host — memang begitu | Pakai konsol serial (Bagian 7) |
| Board reset spontan / gagal boot acak / crash saat WiFi aktif | Daya kurang — hub OTG **pasif** tidak menyuplai apa pun | Powered OTG hub atau OTG Y-cable (8.5) |
| `rkisp: probe of rkisp-vir0 failed with error -12` | Fragmentasi memori — `devm_kmalloc` butuh halaman kontigu orde tinggi | `drop_caches` + `compact_memory` sebelum memuat modul (Bagian 11). Menaikkan CMA **tidak** membantu di sini |
| `vb2_cma_sg_alloc_contiguous: alloc pages fail` saat capture | Buffer capture melebihi CMA (bawaan 1 MB) | Turunkan resolusi, atau naikkan `rk_dma_heap_cma` (Bagian 12) |
| `rkcif: get_remote_sensor: remote pad is null` | Modul sensor dimuat setelah `video_rkcif` | Muat sensor lebih dulu (Bagian 11) |
| Ctrl+C tidak masuk ke prompt U-Boot | `bootdelay` nol, tidak ada jendela interupsi | Tulis partisi env langsung (Bagian 12) |
| `fw_setenv: command not found` | Tidak disertakan di image | Tulis partisi env langsung (Bagian 12) |
| `plink`/`pscp` gagal: `Cannot confirm a host key in batch mode` | Host key belum ter-cache | Tambah `-hostkey "SHA256:..."` dari pesan errornya |
| Perintah lewat PowerShell teracak (`$(`, `{64}`, `<`, `#`) | PowerShell mengurai karakter itu lebih dulu | Tulis skrip sebagai file, jalankan dengan `plink -m` atau `sh /tmp/x.sh` |
| Kernel Oops `scheduling while atomic` saat WiFi dipakai | Bug driver staging `r8188eu` membocorkan preempt count | Ganti ke `aircrack-ng/rtl8188eus` (9.8) |
| `modpost: uses symbol kernel_read from namespace VFS_internal_...` | Kernel 5.4+ membatasi namespace simbol | Tambah `MODULE_IMPORT_NS(...)` di `os_intfs.c` (9.8) |
| Load average ~10 tapi CPU 99% idle | Thread `rockit` tersangkut state D menunggu ISP yang gagal probe | Ramping-kan `insmod_ko.sh` (Bagian 13) |
| `rmmod rockit` menggantung dan tidak bisa dibatalkan | Thread state D tidak dapat diinterupsi | Tidak bisa dilepas saat runtime — cegah saat boot (13.2) |
| Login serial gagal padahal password benar | Perintah berikutnya termakan sebagai jawaban prompt | Tunggu `login:` lalu `Password:` satu per satu sebelum mengirim |
| Service `enabled` tapi `inactive (dead)`, `journalctl -b -u` kosong | Siklus ordering systemd — unit `After=` service yang sendirinya `After=multi-user.target` | Ubah ke `After=network.target`; systemd membuang job tanpa pesan error |
| `Refusing to reload, not enough space available on /run/systemd` saat `apt install` | tmpfs `/run` sempit di board 56 MB | Abaikan — paket dan service tetap terpasang; buat symlink `multi-user.target.wants` manual bila `systemctl enable` ikut gagal |
| Board statis tidak terjangkau setelah pindah jaringan | Alamat statis terikat satu subnet | Pastikan laptop di SSID yang sama; dongle 2,4 GHz tidak bisa 5 GHz |

## Catatan RAM

Board hanya punya **56 MB** total dengan ~34 MB available. Hindari `apt upgrade` untuk banyak
paket sekaligus — `dpkg` rakus memori dan berisiko OOM. Kalau perlu, lakukan bertahap per
kelompok kecil.

Boot arg `rk_dma_heap_cma=1M` sudah aktif di image ini, jadi alokasi CMA 24 MB yang biasa
memakan RAM sudah ditekan.

Load average tinggi yang dulu membingungkan **sudah terpecahkan** — sepuluh thread `rockit` di
state D, lihat Bagian 13. Setelah tumpukan media tidak dimuat, load idle turun ke 0,3–0,5.

Setelah perampingan, angka yang wajar: `MemFree` 13–24 MB, `MemAvailable` ~40 MB dari total 56 MB.
Sebelumnya `MemFree` bisa turun ke 1 MB — itu yang membuat alokasi besar seperti probe ISP gagal
(Bagian 11).

## Cadangan yang sebaiknya disimpan

| File | Isi |
|---|---|
| `backup/boot_p4_before_host.bin` | Partisi boot sebelum diubah ke mode host — kembalikan ke offset 819200 untuk balik ke peripheral |
| `backup/env_p1_original.bin` | Partisi env asli (`rk_dma_heap_cma=1M`) — tulis ke `/dev/mmcblk1p1` kalau bootargs rusak |
| `Ubuntu_Luckfox_Pico_Mini_B_MicroSD_250313.zip` | Firmware asli, untuk flash ulang total |
| `/oem/usr/ko/*.bak`, `/etc/init.d/S50usbdevice.bak` | Versi asli skrip yang dimodifikasi |

## Referensi

- [microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
- [dorssel/usbipd-win](https://github.com/dorssel/usbipd-win)
- [themrleon/luckfox-pico-mini-b](https://github.com/themrleon/luckfox-pico-mini-b) — dokumentasi komunitas, sumber `blkenvflash.py`
- [LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico) — SDK resmi
- [linux-firmware / rtlwifi](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/rtlwifi) — `rtl8188eufw.bin`
- [aircrack-ng/rtl8188eus](https://github.com/aircrack-ng/rtl8188eus) — driver out-of-tree yang dirawat, cadangan kalau staging bermasalah
