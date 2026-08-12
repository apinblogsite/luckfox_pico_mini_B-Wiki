# Akses konsol serial UART2 board dari Windows tanpa terminal tambahan.
#
# Konsol debug ada di UART2 (0xff4c0000 pada RV1106, lihat /proc/cmdline),
# 115200 8N1. Sambungkan TX, RX, GND saja -- JANGAN VCC bila board sudah
# punya sumber daya sendiri.
#
# Pakai:
#   .\serial-console.ps1                      # dengarkan 30 detik
#   .\serial-console.ps1 -Seconds 300 -Log boot.txt
#   .\serial-console.ps1 -Command "uptime" -User pico -Password rahasia
#
# CATATAN: satu port hanya bisa dipakai satu program. Tutup PuTTY dulu.

param(
    [string]$Port = "",
    [int]$Baud = 115200,
    [int]$Seconds = 30,
    [string]$Log = "",
    [string]$Command = "",
    [string]$User = "",
    [string]$Password = ""
)

if (-not $Port) {
    $dev = Get-PnpDevice -PresentOnly | Where-Object {
        $_.InstanceId -match 'VID_067B' -or $_.FriendlyName -match 'USB-to-Serial|USB Serial'
    } | Select-Object -First 1
    if ($dev -and $dev.FriendlyName -match '\((COM\d+)\)') { $Port = $Matches[1] }
    if (-not $Port) { Write-Error "Adapter serial tidak ditemukan. Sebutkan -Port COMx"; exit 1 }
    Write-Host "adapter terdeteksi: $Port"
}

$p = New-Object System.IO.Ports.SerialPort($Port, $Baud, "None", 8, "One")
$p.ReadTimeout = 500
$p.DtrEnable = $true
$p.RtsEnable = $true

function Wait-For($port, $pattern, $maxTicks) {
    $o = ""
    for ($i = 0; $i -lt $maxTicks; $i++) {
        if ($port.BytesToRead -gt 0) { $o += $port.ReadExisting() }
        if ($o -match $pattern) { return $o }
        Start-Sleep -Milliseconds 300
    }
    return $o
}

try {
    $p.Open()
    Start-Sleep -Milliseconds 400
    $p.DiscardInBuffer()

    if ($User) {
        # Login harus sinkron per-prompt. Mengirim membabi buta membuat
        # perintah berikutnya termakan sebagai jawaban password.
        $p.Write("`r"); $null = Wait-For $p "login:" 40
        $p.Write("$User`r"); $null = Wait-For $p "Password" 40
        $p.Write("$Password`r"); $null = Wait-For $p "\$ |# " 60
        Write-Host "login sebagai $User"
    }

    if ($Command) {
        $p.Write("$Command`r")
        $out = ""
        for ($i = 0; $i -lt 40; $i++) {
            if ($p.BytesToRead -gt 0) { $out += $p.ReadExisting() }
            Start-Sleep -Milliseconds 250
        }
        ($out -replace "`e\[[0-9;]*[A-Za-z]", "")
    }
    else {
        Write-Host "merekam $Seconds detik (Ctrl+C untuk berhenti)..."
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt ($Seconds * 2); $i++) {
            if ($i % 20 -eq 0) { $p.Write("`r") }
            if ($p.BytesToRead -gt 0) { $null = $sb.Append($p.ReadExisting()) }
            Start-Sleep -Milliseconds 500
        }
        $txt = $sb.ToString() -replace "`e\[[0-9;]*[A-Za-z]", ""
        if ($Log) {
            Set-Content -Path $Log -Value $txt -Encoding UTF8
            Write-Host "tersimpan: $($txt.Length) byte -> $Log"
            Select-String -Path $Log -Pattern "Internal error|scheduling while atomic|Modules linked in|Comm:|login:" |
                Select-Object -First 15 | ForEach-Object { $_.Line.Trim() }
        }
        else {
            if ($txt.Trim()) { $txt } else { "SUNYI - board mati, atau TX/RX/GND terlepas" }
        }
    }
}
finally {
    if ($p.IsOpen) { $p.Close() }
    $p.Dispose()
}
