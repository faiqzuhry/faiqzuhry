#!/bin/bash

# Check if the script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "Error: Skrip ini harus dijalankan sebagai root."
    exit 1
fi
clear

domain=$(cat /etc/data/domain)
email=$(cat /etc/data/email)

#install cert
cd /opt/marzban
docker compose down
/root/.acme.sh/acme.sh --server letsencrypt --register-account -m $email --issue -d $domain --standalone -k ec-256 --force --debug
~/.acme.sh/acme.sh --installcert -d $domain --fullchainpath /var/lib/marzban/xray.crt --keypath /var/lib/marzban/xray.key --ecc
docker compose up -d
cd

#cek cert
cat /var/lib/marzban/xray.crt
cat /var/lib/marzban/xray.key
