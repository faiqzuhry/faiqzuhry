#!/bin/bash
tanggal=$(date +"%m-%d-%Y")
waktu=$(date +"%T")
echo "Server telah berhasil direboot pada tanggal $tanggal pukul $waktu." >> /etc/data/log-reboot.txt
apt update && apt upgrade -y
/sbin/reboot
