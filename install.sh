#!/bin/bash
# LingVPN Marzban Installer - Auto Resume
# Support: Debian 11/12/13 + Ubuntu 20.04/22.04

sfile="https://raw.githubusercontent.com/faiqzuhry/faiqzuhry/main"
# TIMEZONE POLICY: NEUTRAL — jangan set timezone berdasarkan IP/lokasi.
STATE_DIR="/var/lib/lingvpn-install/state"
LOG_FILE="/root/lingvpn-install.log"
mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
set -o pipefail

colorized_echo() {
    local color=$1 text=$2
    case "$color" in
        red) printf '\e[91m%s\e[0m\n' "$text";;
        green) printf '\e[92m%s\e[0m\n' "$text";;
        yellow) printf '\e[93m%s\e[0m\n' "$text";;
        blue) printf '\e[94m%s\e[0m\n' "$text";;
        magenta) printf '\e[95m%s\e[0m\n' "$text";;
        cyan) printf '\e[96m%s\e[0m\n' "$text";;
        *) printf '%s\n' "$text";;
    esac
}

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }

# Error helper used by optional BOT Usage installer and other non-fatal blocks.
err(){ colorized_echo red "[ERROR] $*"; }

if [ "$(id -u)" != "0" ]; then
    colorized_echo red "Error: Skrip ini harus dijalankan sebagai root."
    exit 1
fi

usage(){
cat <<'USAGE'
LingVPN Installer

Pemakaian:
  bash /root/install.sh                 # otomatis resume
  bash /root/install.sh --resume        # lanjut dari checkpoint terakhir
  bash /root/install.sh --status        # lihat status tahap
  bash /root/install.sh --reset         # hapus checkpoint, ulang dari awal

Checkpoint disimpan di:
  /var/lib/lingvpn-install/state/

Log utama:
  /root/lingvpn-install.log
USAGE
}

case "${1:-}" in
  --status)
    echo "=== STATUS INSTALLASI LINGVPN ==="
    for i in {01..10}; do
      if [ -f "$STATE_DIR/stage_$i.done" ]; then echo "[✓] Tahap $i selesai"; else echo "[ ] Tahap $i belum selesai"; fi
    done
    echo "Log: $LOG_FILE"
    exit 0
    ;;
  --reset)
    rm -f "$STATE_DIR"/stage_*.done
    log "Checkpoint di-reset. Instalasi akan dimulai dari tahap 01."
    ;;
  --resume|"") ;;
  -h|--help) usage; exit 0 ;;
  *) colorized_echo red "Opsi tidak dikenal: $1"; usage; exit 1 ;;
esac

run_stage(){
    local id="$1" name="$2" func="$3"
    if [ -f "$STATE_DIR/stage_${id}.done" ]; then
        colorized_echo green "[✓] Tahap ${id} dilewati: ${name}"
        return 0
    fi
    echo
    colorized_echo cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    colorized_echo cyan "[→] Tahap ${id}/10: ${name}"
    colorized_echo cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if "$func"; then
        touch "$STATE_DIR/stage_${id}.done"
        log "DONE ${id} - ${name}"
        colorized_echo green "[✓] Tahap ${id} selesai. Checkpoint tersimpan."
    else
        log "FAILED ${id} - ${name} (exit=$?)"
        colorized_echo red "[x] Tahap ${id} gagal. Jalankan kembali: bash /root/install.sh --resume"
        exit 1
    fi
}

# Safe sysctl: parameter yang tidak tersedia di kernel akan dilewati.
# Muat kembali konfigurasi tersimpan agar resume melewati input tanpa variabel kosong.
[ -f /etc/os-release ] && {
    os_name=$(grep -E '^ID=' /etc/os-release | cut -d= -f2)
    os_version=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
}
for _v in email domain userpanel passpanel nama fileb port choice; do
    case "$_v" in
        fileb) _f=/etc/data/passbackup;;
        choice) _f=/etc/data/ipv6_choice;;
        *) _f=/etc/data/$_v;;
    esac
    if [ -s "$_f" ]; then eval "$_v=\"\$(cat \"$_f\")\""; fi
done
unset _v _f

safe_sysctl_apply(){
    local key value
    [ -f /etc/sysctl.conf ] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_.]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
            if sysctl -n "$key" >/dev/null 2>&1; then
                sysctl -w "$key=$value" >/dev/null 2>&1 || log "WARN sysctl gagal: $key"
            else
                log "SKIP sysctl tidak tersedia di kernel: $key"
            fi
        fi
    done < /etc/sysctl.conf
    return 0
}

# ===== AUTO SWAP 2GB =====
# Membuat dan mengaktifkan Swap 2GB pada VPS baru.
# Aman untuk --resume dan tidak membuat swap kedua jika sudah ada >= 2GB.

setup_swap_2gb(){
    local SWAPFILE="/swapfile"
    local SWAP_MB=2048
    local CURRENT_SWAP_MB=0

    CURRENT_SWAP_MB="$(free -m 2>/dev/null | awk '/^Swap:/ {print $2+0}')"

    # Jika sudah ada Swap >= 2GB, pertahankan konfigurasi yang ada.
    if [ "${CURRENT_SWAP_MB:-0}" -ge "$SWAP_MB" ]; then
        colorized_echo green "[✓] Swap >= 2GB sudah tersedia."
        return 0
    fi

    # Jika /swapfile ada tetapi tidak aktif/ukurannya salah, buat ulang.
    if [ -f "$SWAPFILE" ]; then
        if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
            colorized_echo green "[✓] /swapfile sudah aktif."
            return 0
        fi
        rm -f "$SWAPFILE"
    fi

    colorized_echo cyan "[*] Membuat Swap 2GB..."

    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l 2G "$SWAPFILE" 2>/dev/null || true
    fi

    # Fallback jika fallocate gagal/tidak tersedia.
    if [ ! -f "$SWAPFILE" ] || \
       [ "$(stat -c '%s' "$SWAPFILE" 2>/dev/null || echo 0)" -lt 2147483648 ]; then
        rm -f "$SWAPFILE"
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048 status=none
    fi

    chmod 600 "$SWAPFILE"

    if ! mkswap "$SWAPFILE" >/dev/null 2>&1; then
        colorized_echo yellow "[!] Gagal membuat Swap 2GB."
        rm -f "$SWAPFILE"
        return 0
    fi

    if ! swapon "$SWAPFILE" >/dev/null 2>&1; then
        colorized_echo yellow "[!] Gagal mengaktifkan Swap 2GB."
        return 0
    fi

    # Permanen setelah reboot.
    if ! grep -qE '^[[:space:]]*/swapfile[[:space:]]+none[[:space:]]+swap([[:space:]]|$)' /etc/fstab 2>/dev/null; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    # Swap hanya dipakai ketika memang diperlukan.
    if [ -f /etc/sysctl.conf ]; then
        if grep -qE '^[[:space:]]*vm\.swappiness=' /etc/sysctl.conf; then
            sed -i 's/^[[:space:]]*vm\.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf
        else
            echo "vm.swappiness=10" >> /etc/sysctl.conf
        fi
    else
        echo "vm.swappiness=10" > /etc/sysctl.conf
    fi

    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true

    colorized_echo green "[✓] Swap 2GB berhasil dibuat dan diaktifkan."
}

setup_swap_2gb

# ===== END AUTO SWAP 2GB =====

stage01(){
    local supported_os=false
    if [ -f /etc/os-release ]; then
        os_name=$(grep -E '^ID=' /etc/os-release | cut -d= -f2)
        os_version=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        os_codename=$(grep -E '^(VERSION_CODENAME|UBUNTU_CODENAME)=' /etc/os-release | cut -d= -f2 | tr -d '"' | head -n1 || true)
        if [ "$os_name" = "debian" ] && [[ "$os_version" =~ ^(11|12|13)$ ]]; then supported_os=true; fi
        if [ "$os_name" = "ubuntu" ] && [[ "$os_version" =~ ^(20\.04|22\.04)$ ]]; then supported_os=true; fi
    fi
    if [ "$supported_os" != true ]; then
        colorized_echo red "OS tidak didukung. Gunakan Debian 11/12/13 atau Ubuntu 20.04/22.04."
        return 1
    fi
    log "OS terdeteksi: $os_name $os_version"

    # Repo functions
    addDebianRepo(){
        local v="$1" c
        case "$v" in 11)c=bullseye;;12)c=bookworm;;13)c=trixie;;*) return 1;; esac
        cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        rm -f /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/debian.list 2>/dev/null || true
        cat > /etc/apt/sources.list.d/debian.sources <<EOF2
Types: deb
URIs: http://kartolo.sby.datautama.net.id/debian
Suites: $c $c-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://kartolo.sby.datautama.net.id/debian-security
Suites: ${c}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF2
        : > /etc/apt/sources.list
    }
    addUbuntuRepo(){
        local v="$1" c
        case "$v" in 20.04)c=focal;;22.04)c=jammy;;*) return 1;; esac
        cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        cat > /etc/apt/sources.list <<EOF2
 deb https://buaya.klas.or.id/ubuntu/ $c main restricted universe multiverse
 deb https://buaya.klas.or.id/ubuntu/ ${c}-updates main restricted universe multiverse
 deb https://buaya.klas.or.id/ubuntu/ ${c}-security main restricted universe multiverse
 deb https://buaya.klas.or.id/ubuntu/ ${c}-backports main restricted universe multiverse
EOF2
        sed -i 's/^ //' /etc/apt/sources.list
    }

    mkdir -p /etc/data
    if [ -z "${REPO_CHOICE:-}" ]; then
        COUNTRY_CODE=$(curl -fsS --max-time 10 https://ipinfo.io/country 2>/dev/null || true)
        if [ "$COUNTRY_CODE" = "ID" ]; then
            read -rp "Gunakan repo lokal Indonesia? (y/n): " REPO_CHOICE
        else
            REPO_CHOICE="n"
        fi
        echo "$REPO_CHOICE" > /etc/data/repo_choice
    fi
    [ -f /etc/data/repo_choice ] && REPO_CHOICE=$(cat /etc/data/repo_choice)
    if [[ "$REPO_CHOICE" =~ ^[Yy]$ ]]; then
        [ "$os_name" = "debian" ] && addDebianRepo "$os_version"
        [ "$os_name" = "ubuntu" ] && addUbuntuRepo "$os_version"
    fi

    apt-get update
    apt-get install -y sudo curl lsb-release ca-certificates

    # Simpan input agar resume tidak bertanya ulang.
    read_saved(){ local var="$1" prompt="$2" file="$3"; if [ -s "$file" ]; then printf -v "$var" '%s' "$(cat "$file")"; else read -rp "$prompt" val; printf -v "$var" '%s' "$val"; printf '%s' "$val" > "$file"; fi; }
    # Email ACME dibuat otomatis agar domain tidak pernah salah dipakai sebagai email.
    # Jika file lama berisi domain / email tidak valid, otomatis diganti.
    ACME_EMAIL="faiqzuhry@gmail.com"
    if [ -s /etc/data/email ]; then
        saved_email="$(tr -d '\r\n' < /etc/data/email)"
        if [[ "$saved_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
            email="$saved_email"
        else
            email="$ACME_EMAIL"
            printf '%s\n' "$email" > /etc/data/email
        fi
    else
        email="$ACME_EMAIL"
        printf '%s\n' "$email" > /etc/data/email
    fi
    colorized_echo green "[✓] Email ACME otomatis: ${email}"
    read_saved domain "Masukkan Domain: " /etc/data/domain
    while true; do
        if [ -s /etc/data/userpanel ]; then userpanel=$(cat /etc/data/userpanel); break; fi
        read -rp "Masukkan UsernamePanel (hanya huruf dan angka): " userpanel
        if [[ "$userpanel" =~ ^[A-Za-z0-9]+$ ]] && [[ ! "$userpanel" =~ [Aa][Dd][Mm][Ii][Nn] ]]; then echo "$userpanel" >/etc/data/userpanel; break; fi
        echo "UsernamePanel tidak valid."
    done
    read_saved passpanel "Masukkan PasswordPanel: " /etc/data/passpanel
    read_saved nama "Masukkan ISP VPS: " /etc/data/nama
    read_saved fileb "Masukkan Pass untuk file Backup: " /etc/data/passbackup
    while true; do
        if [ -s /etc/data/port ]; then port=$(cat /etc/data/port); break; fi
        read -rp "Masukkan Default Port Marzban (selain 443/80): " port
        if [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)) && ((port!=443 && port!=80)); then echo "$port" >/etc/data/port; break; fi
        echo "Port tidak valid."
    done
    # IPv6 otomatis: gunakan "Ya" bila VPS memiliki IPv6 global/route IPv6,
    # selain itu otomatis "Tidak". Tidak ada pertanyaan interaktif.
    ipv6_addr="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2; exit}')"
    ipv6_route="$(ip -6 route show default 2>/dev/null | head -n1)"
    if [ -n "$ipv6_addr" ] || [ -n "$ipv6_route" ]; then
        choice="1"
        colorized_echo green "[✓] IPv6 terdeteksi — otomatis: Ya"
    else
        choice="2"
        colorized_echo yellow "[!] IPv6 tidak terdeteksi — otomatis: Tidak"
    fi
    printf '%s\n' "$choice" > /etc/data/ipv6_choice

    wget -q -O /etc/sysctl.conf "$sfile/sysctl.conf" || log "WARN: gagal mengambil sysctl.conf, memakai konfigurasi lama."
    case "$choice" in
      1) echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf; echo 'net.ipv6.conf.default.forwarding = 1' >> /etc/sysctl.conf;;
      2) echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.conf;;
    esac
    safe_sysctl_apply
    export email domain userpanel passpanel nama fileb port choice os_name os_version os_codename
}


stage02() {
    set -e
#Preparation
clear
cd;
apt-get update;

#Remove unused Module
apt-get -y --purge remove samba*;
apt-get -y --purge remove apache2*;
apt-get -y --purge remove sendmail*;
apt-get -y --purge remove bind9*;

#install benchmark
wget -O /usr/bin/bench "https://raw.githubusercontent.com/teddysun/across/master/bench.sh" && chmod +x /usr/bin/bench

#install toolkit
sudo apt-get install -y git perl libio-socket-inet6-perl libsocket6-perl libio-socket-ssl-perl libwww-perl zlib1g-dev dbus iftop zip unzip wget net-tools curl ca-certificates nano sed screen gnupg bc build-essential dirmngr dnsutils at htop iptables cron lsof lnav xz-utils
# Optional compatibility packages (do not abort installation if unavailable).
apt-get install -y libcrypt-ssleay-perl libnet-libidn-perl libpcre3 libpcre3-dev bsdmainutils apt-transport-https 2>/dev/null || true

#Install lolcat
apt-get install -y ruby;
gem install lolcat;


}


stage03() {
    set -e

# ===== TIMEZONE NEUTRAL =====
# Installer tidak mengubah timezone host berdasarkan IP/lokasi.
# VPS yang sudah UTC tetap UTC; VPS yang sudah Asia/Jakarta tetap Asia/Jakarta.
# Jangan bind-mount /etc/timezone atau /etc/localtime ke container.
export TZ="${TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)}"
# ===== END TIMEZONE NEUTRAL =====
#Install Marzban
# Gunakan script resmi hanya untuk menyiapkan Docker/CLI.
# Output ditulis ke log agar traceback sementara tidak memenuhi terminal.
curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh -o /tmp/marzban-install.sh

# Jalankan installer resmi Marzban tanpa follow log foreground.
# Script resmi menjalankan follow_marzban_logs setelah up_marzban,
# sehingga instalasi utama akan menunggu Ctrl+C. Di sini hanya pemanggilan
# follow tersebut di dalam install_command yang dinonaktifkan.
if [ -s /tmp/marzban-install.sh ]; then
    awk '
        /^install_command\(\)/ { in_install=1 }
        /^install_yq\(\)/ { in_install=0 }
        in_install && /^[[:space:]]*follow_marzban_logs[[:space:]]*$/ { next }
        { print }
    ' /tmp/marzban-install.sh > /tmp/marzban-install.no-follow.sh
    mv -f /tmp/marzban-install.no-follow.sh /tmp/marzban-install.sh
fi

if ! bash /tmp/marzban-install.sh install 2>&1 | tee -a /var/log/marzban-bootstrap.log; then
    colorized_echo yellow "Bootstrap Marzban selesai dengan peringatan. Instalasi utama akan dilanjutkan dengan konfigurasi resmi di bawah."
fi
rm -f /tmp/marzban-install.sh

#install subs
wget -O /opt/marzban/index.html "https://cdn.jsdelivr.net/gh/MuhammadAshouri/marzban-templates@master/template-01/index.html"

#install env
wget -O /opt/marzban/.env "$sfile/env"

#install compose
wget -O /opt/marzban/docker-compose.yml "$sfile/docker-compose.yml"

# Hapus seluruh bind-mount timezone dari Compose.
# Timezone host/container tidak dikonfigurasi oleh installer.
# Ini mencegah error Docker pada /etc/timezone dan /etc/localtime.
sed -i \
    -e '\#/etc/timezone#d' \
    -e '\#/etc/localtime#d' \
    /opt/marzban/docker-compose.yml

#install assets & core
mkdir -p /etc/autokill/logs
mkdir -p /etc/autokill/penalty_logs
mkdir -p /var/lib/marzban/assets
mkdir -p /var/lib/marzban/core

# Install Xray sesuai arsitektur VPS
XRAY_ARCH="$(uname -m)"
case "$XRAY_ARCH" in
    x86_64)
        XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
        ;;
    aarch64|arm64)
        XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
        ;;
    *)
        colorized_echo red "Arsitektur VPS tidak didukung: $XRAY_ARCH"
        exit 1
        ;;
esac

rm -rf /tmp/xray-install
mkdir -p /tmp/xray-install

curl -fL --retry 5 --retry-delay 2 -o /tmp/xray-install/xray.zip "$XRAY_URL" || {
    colorized_echo red "Gagal download Xray dari sumber resmi."
    exit 1
}

unzip -oq /tmp/xray-install/xray.zip xray -d /tmp/xray-install || {
    colorized_echo red "Gagal extract Xray."
    exit 1
}

if [ ! -s /tmp/xray-install/xray ]; then
    colorized_echo red "Binary Xray kosong/tidak ditemukan."
    exit 1
fi

install -m 755 /tmp/xray-install/xray /var/lib/marzban/core/xray
rm -rf /tmp/xray-install

/var/lib/marzban/core/xray version >/dev/null 2>&1 || {
    colorized_echo red "Binary Xray tidak dapat dijalankan. Arsitektur: $XRAY_ARCH"
    exit 1
}

colorized_echo green "Xray berhasil dipasang: $XRAY_ARCH"

}


stage04() {
    set -e
#profile
echo -e 'profile' >> /root/.profile
wget -O /usr/bin/profile "$sfile/profile";
chmod +x /usr/bin/profile
# Neofetch sudah tidak tersedia pada sebagian release baru (termasuk Debian 13).
# Gunakan fastfetch jika tersedia; neofetch hanya dipasang bila paket tersedia.
if apt-cache show neofetch >/dev/null 2>&1; then
    apt-get install -y neofetch >/dev/null 2>&1 || true
else
    apt-get install -y fastfetch >/dev/null 2>&1 || true
fi

# Profile eksternal dapat memanggil neofetch. Bungkus pemanggilannya agar
# login tidak menghasilkan "neofetch: command not found".
if [ -f /usr/bin/profile ]; then
    sed -i 's/^[[:space:]]*neofetch[[:space:]]*$/command -v neofetch >\/dev\/null 2>\&1 \&\& neofetch || (command -v fastfetch >\/dev\/null 2>\&1 \&\& fastfetch) || true/' /usr/bin/profile
fi

#Install VNSTAT
apt -y install vnstat
systemctl restart vnstat 2>/dev/null || true
apt -y install libsqlite3-dev
# Prefer Debian/Ubuntu's packaged vnstat on modern releases.
# Only fall back to the bundled 2.6 source if the package is unavailable.
if ! command -v vnstat >/dev/null 2>&1; then
    apt-get install -y vnstat || {
        wget -q -O /root/vnstat-2.6.tar.gz "$sfile/vnstat-2.6.tar.gz"
        tar zxf /root/vnstat-2.6.tar.gz -C /root
        cd /root/vnstat-2.6
        ./configure --prefix=/usr --sysconfdir=/etc && make -j"$(nproc)" && make install
        cd /root
        rm -rf /root/vnstat-2.6 /root/vnstat-2.6.tar.gz
    }
fi
mkdir -p /var/lib/vnstat
chown -R vnstat:vnstat /var/lib/vnstat 2>/dev/null || true
systemctl enable --now vnstat 2>/dev/null || true

#Install Speedtest
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
sudo apt-get install speedtest -y

#install gotop
rm -rf /tmp/gotop
git clone --depth 1 https://github.com/cjbassi/gotop /tmp/gotop
cd /tmp/gotop
./scripts/download.sh || true
if [ -f /tmp/gotop/gotop ]; then
    install -m 755 /tmp/gotop/gotop /usr/bin/gotop
fi
cd /root

}


stage05() {
    set -e
#install nginx
mkdir -p /var/log/nginx
touch /var/log/nginx/access.log
touch /var/log/nginx/error.log
wget -O /opt/marzban/nginx.conf "$sfile/nginx.conf"
wget -O /opt/marzban/default.conf "$sfile/vps.conf"
wget -O /opt/marzban/xray.conf "$sfile/xray.conf"
# Sinkronkan server_name Xray dengan domain yang dimasukkan saat instalasi.
domain="$(cat /etc/data/domain 2>/dev/null || printf "")"
if [ -z "$domain" ]; then echo "ERROR: domain kosong."; exit 1; fi
if grep -qE '^[[:space:]]*server_name[[:space:]]+[^;]+;' /opt/marzban/xray.conf; then
    sed -i -E "0,/^[[:space:]]*server_name[[:space:]]+[^;]+;/s//            server_name ${domain};/" /opt/marzban/xray.conf
else
    printf '\n            server_name %s;\n' "$domain" >> /opt/marzban/xray.conf
fi
mkdir -p /var/www/html
echo "<pre>Setup by AutoScript LingVPN</pre>" > /var/www/html/index.html

#install socat
apt install iptables -y
apt install curl socat xz-utils wget gnupg gnupg2 dnsutils lsb-release -y 
apt install socat cron bash-completion -y

#install cert
curl -4fsSL https://get.acme.sh | sh -s email="$email"
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
/root/.acme.sh/acme.sh --server letsencrypt --register-account --issue -d "$domain" --standalone -k ec-256 --debug
~/.acme.sh/acme.sh --installcert -d "$domain" --fullchainpath /var/lib/marzban/xray.crt --keypath /var/lib/marzban/xray.key --ecc
wget -O /var/lib/marzban/xray_config.json "$sfile/xray_config.json"

}


stage06() {
    set -e
#install command
cd /usr/bin
#Additional
wget -O status "$sfile/status" && chmod +x status
wget -qO /usr/bin/menu "$sfile/menu" && chmod 755 /usr/bin/menu
test -s /usr/bin/menu || { echo "ERROR: file menu kosong/gagal di-download."; exit 1; }
test -s /usr/bin/menu || { echo "ERROR: file menu kosong/gagal di-download."; exit 1; }
bash -n /usr/bin/menu || { echo "ERROR: file menu dari repository tidak valid."; exit 1; }
# Download ganti_domain sebagai file terpisah dari repository.
wget -qO /usr/bin/ganti_domain "$sfile/ganti_domain" && chmod 755 /usr/bin/ganti_domain
test -s /usr/bin/ganti_domain || { echo "ERROR: file ganti_domain kosong/gagal di-download."; exit 1; }
test -s /usr/bin/ganti_domain || { echo "ERROR: file ganti_domain kosong/gagal di-download."; exit 1; }
bash -n /usr/bin/ganti_domain || { echo "ERROR: file ganti_domain dari repository tidak valid."; exit 1; }
wget -O ceklogin "$sfile/ceklogin" && chmod +x ceklogin
wget -O hapus "$sfile/hapus" && chmod +x hapus
wget -O renew "$sfile/renew" && chmod +x renew
wget -O resetusage "$sfile/resetusage" && chmod +x resetusage
wget -O buat_token "$sfile/buat_token" && chmod +x buat_token
wget -O cekservice "$sfile/cekservice" && chmod +x cekservice
wget -O ram "$sfile/ram" && chmod +x ram
wget -O menu-backup "$sfile/menu-backup" && chmod +x menu-backup
wget -O menu-reboot "$sfile/menu-reboot" && chmod +x menu-reboot
wget -O menu-akun "$sfile/menu-akun" && chmod +x menu-akun
wget -O backup "$sfile/backup" && chmod +x backup
wget -O clearlog "$sfile/clearlog" && chmod +x clearlog
# Jalankan clearlog otomatis setiap hari pukul 02:00 WIB.
cat > /etc/cron.d/clearlog_otomatis <<'EOF'
00 2 * * * root /usr/bin/clearlog >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/clearlog_otomatis
systemctl restart cron 2>/dev/null || true
wget -O ceklog "$sfile/ceklog" && chmod +x ceklog
wget -O cekerror "$sfile/cekerror" && chmod +x cekerror
wget -O ceknginx "$sfile/ceknginx" && chmod +x ceknginx
wget -O expired "$sfile/expired" && chmod +x expired
wget -O setlimit "$sfile/setlimit" && chmod +x setlimit
wget -O autokill "$sfile/autokill" && chmod +x autokill

# =========================================================
# Install BWBOT - bandwidth monitor Telegram
# Aman untuk installer: tidak meminta input, tidak mengubah Marzban,
# memakai konfigurasi Telegram bersama menu-backup, dan dijalankan 02:00.
# =========================================================
cat > /usr/local/bin/bwbot <<'BWBOT_EOF'
#!/bin/bash

# BWBOT 02AM - CLEAN / SYNC
# - Public IP otomatis
# - Telegram config bersama dengan menu-backup
# - Client/expiry dari permission database
# - Tidak bergantung pada CRONTAB_ENABLED_FILE
# - Cron dijadwalkan di /etc/cron.d/bwbot (02:00)

set -u

export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export CYAN='\033[0;36m'
export PINK='\033[0;35m'
export ORANGE='\033[38;5;208m'
export TEAL='\033[38;5;30m'
export WHITE='\033[1;37m'
export NC='\033[0m'

CONFIG_FILE="/etc/data/telegram_config.conf"
PERMISSION_URL="https://raw.githubusercontent.com/faiqzuhry/akses-faiq/main/iphost.txt"
IPIFY_URL="https://api.ipify.org"
IPINFO_IP_URL="https://ipinfo.io/ip"
IPINFO_JSON_BASE="https://ipinfo.io"
TELEGRAM_API="https://api.telegram.org"

# ---------- Helpers ----------
die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || die "curl tidak tersedia."
command -v jq >/dev/null 2>&1 || die "jq tidak tersedia."
command -v vnstat >/dev/null 2>&1 || die "vnstat tidak tersedia."

# ---------- Shared Telegram config ----------
if [[ ! -s "$CONFIG_FILE" ]]; then
    die "Konfigurasi Telegram belum tersedia. Jalankan menu-backup dan simpan konfigurasi Telegram."
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

BOT_TOKEN="${BOT_TOKEN:-${botToken:-}}"
CHAT_ID="${CHAT_ID:-${chatId:-}}"
REMARKS="${REMARKS:-}"
button_text="${button_text:-Cek Server}"
button_url="${button_url:-https://google.com}"

[[ -n "$BOT_TOKEN" ]] || die "BOT_TOKEN kosong."
[[ -n "$CHAT_ID" ]] || die "CHAT_ID kosong."
[[ -n "$button_text" ]] || button_text="Cek Server"
[[ -n "$button_url" ]] || button_url="https://google.com"

# ---------- System ----------
OS=$(lsb_release -ds 2>/dev/null || grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')
RAM=$(free -m | awk '/Mem:/ {print $2}')
UPTIME=$(uptime -p 2>/dev/null || echo "-")
DOMAIN=$(cat /etc/data/domain 2>/dev/null || echo "-")

# ---------- Public IP ----------
IP_VPS=$(curl -4fsS --max-time 10 "$IPIFY_URL" 2>/dev/null || true)

if [[ -z "$IP_VPS" ]]; then
    IP_VPS=$(curl -4fsS --max-time 10 "$IPINFO_IP_URL" 2>/dev/null || true)
fi

if [[ -z "$IP_VPS" ]]; then
    IP_VPS=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

[[ -n "$IP_VPS" ]] || die "Tidak dapat mendeteksi IP VPS."

echo -e "${TEAL}♻️ Detected public IP VPS: ${CYAN}${IP_VPS}${NC}"

# ---------- IP / ISP information ----------
IP_INFO=$(curl -4fsS --max-time 10 "${IPINFO_JSON_BASE}/${IP_VPS}/json" 2>/dev/null || true)

ISP=$(printf '%s' "$IP_INFO" | jq -r '.org // empty' 2>/dev/null || true)
REGION=$(printf '%s' "$IP_INFO" | jq -r '.timezone // .region // empty' 2>/dev/null || true)
IP_COUNTRY=$(printf '%s' "$IP_INFO" | jq -r '.country // empty' 2>/dev/null || true)
IP_LOC=$(printf '%s' "$IP_INFO" | jq -r '.loc // empty' 2>/dev/null || true)

[[ -n "$ISP" ]] || ISP="Unknown ISP"
[[ -n "$REGION" ]] || REGION="-"

# ---------- Permission database ----------
# Hanya satu request. Tidak ada curl dengan URL kosong.
PERMISSION_FILE=$(curl -4fsS --max-time 10 "$PERMISSION_URL" 2>/dev/null || true)

clientname="Auto IP"
exp_date="-"
CLIENT_REGISTERED="no"

if [[ -n "$PERMISSION_FILE" ]]; then
    CLIENT_INFO=$(printf '%s\n' "$PERMISSION_FILE" |
        awk -v ip="$IP_VPS" '$1 == ip {print $2 "|" $4; exit}')

    if [[ -n "$CLIENT_INFO" ]]; then
        IFS='|' read -r clientname exp_date <<< "$CLIENT_INFO"
        CLIENT_REGISTERED="yes"
    fi
fi

# ---------- Expiry ----------
current_date=$(date +%Y-%m-%d)

if [[ "$exp_date" != "-" && "$exp_date" != "Not Found" && -n "$exp_date" ]]; then
    if expiry_epoch=$(date -d "$exp_date" +%s 2>/dev/null); then
        current_epoch=$(date -d "$current_date" +%s)

        if (( expiry_epoch < current_epoch )); then
            echo -e "${RED}[ INFO ] Script Expired ⛔${NC}"
            echo -e "${CYAN}Contact admin : ✦ @Faiqzuhry ✦${NC}"
            exit 1
        fi

        days_remaining=$(( (expiry_epoch - current_epoch) / 86400 ))
    else
        days_remaining="-"
    fi
else
    days_remaining="-"
fi

# ---------- Bandwidth ----------
vnstat_output=$(
    vnstat -y 1 --style 0 2>/dev/null |
    sed -n 6p |
    awk '{print "Download :", $2, $3 "\nUpload :", $5, $6 "\nTotal Usage :", $8, $9}'
)

if [[ -z "$vnstat_output" ]]; then
    vnstat_output=$'Download : -\nUpload : -\nTotal Usage : -'
fi

# ---------- Uptime ----------
uptime_raw="$UPTIME"
uptime_filtered=$(printf '%s\n' "$uptime_raw" |
    sed -e 's/.*up *//' \
        -e 's/minutes/min/g' \
        -e 's/minute/min/g' \
        -e 's/hours/hrs/g' \
        -e 's/hour/hr/g' \
        -e 's/weeks/week/g' \
        -e 's/days/day/g' |
    awk -F, '{print $1 "," $2}')

uptime_final=$(printf '%s' "$uptime_filtered" | sed 's/,$//' | sed 's/^,//')
[[ -n "$uptime_final" ]] || uptime_final="-"

# ---------- Telegram message ----------
current_time=$(date +"%d-%m-%Y %I:%M %p")
button_text_with_emoji="🐳 ${button_text} 🐳"

monospace_message=$(cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━
     🌙 DATA TRAFFIC SERVER 🌙
━━━━━━━━━━━━━━━━━━━━━━━
🌐 ISP : <code>${ISP}</code>
🚀 Status : <code>Active</code>
⏱ Uptime : <code>${uptime_final}</code>
🌍 Reg : <code>${REGION}</code>
➖➖➖➖➖➖➖➖➖➖➖➖
📥 <code>$(printf '%s\n' "$vnstat_output" | sed -n '1p')</code>
📤 <code>$(printf '%s\n' "$vnstat_output" | sed -n '2p')</code>
💼 <code>$(printf '%s\n' "$vnstat_output" | sed -n '3p')</code>
━━━━━━━━━━━━━━━━━━━━━━━
  ⚠️ Automatic 02:00 Update ⚠️
━━━━━━━━━━━━━━━━━━━━━━━
Last Update : ${current_time}
━━━━━━━━━━━━━━━━━━━━━━━
 🤖 Bot Version 0.23.1
EOF
)

keyboard=$(jq -n \
    --arg text "$button_text_with_emoji" \
    --arg url "$button_url" \
    '{inline_keyboard: [[{text: $text, url: $url}]]}')

data=$(jq -n \
    --arg chat_id "$CHAT_ID" \
    --arg text "$monospace_message" \
    --argjson reply_markup "$keyboard" \
    '{chat_id: $chat_id, text: $text, parse_mode: "HTML", reply_markup: $reply_markup}')

TELEGRAM_URL="${TELEGRAM_API}/bot${BOT_TOKEN}/sendMessage"

if curl -fsS --max-time 20 \
    -X POST "$TELEGRAM_URL" \
    -H "Content-Type: application/json" \
    -d "$data" >/dev/null; then

    echo -e "${CYAN}────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}❖ Pesan berhasil dikirim ke Telegram.${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────${NC}"
else
    echo -e "${RED}❖ Gagal mengirim pesan ke Telegram.${NC}"
    exit 1
fi
BWBOT_EOF
chmod 755 /usr/local/bin/bwbot

# Dependensi BWBOT. curl/vnstat sudah dipakai installer; jq diperlukan bot.
apt-get install -y jq curl vnstat

# Pastikan hanya ada satu jadwal BWBOT dan tidak mengganggu cron lain.
rm -f /etc/cron.d/bwbot
cat > /etc/cron.d/bwbot <<'CRON_EOF'
0 2 * * * root /usr/local/bin/bwbot >/var/log/bwbot.log 2>&1
CRON_EOF
chmod 644 /etc/cron.d/bwbot

# Aktifkan cron tanpa menyentuh konfigurasi service lain.
systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true

log "BWBOT terpasang: /usr/local/bin/bwbot; cron setiap hari 02:00."
wget -O fix-ssl "$sfile/fix-ssl.sh" && chmod +x fix-ssl
wget -O ganticore "$sfile/ganticore" && chmod +x ganticore
wget -O routing "$sfile/routing" && chmod +x routing
wget -O seeroute "$sfile/seeroute" && chmod +x seeroute
cd

#Install reboot dan expired otomatis
wget -O /usr/bin/reboot_otomatis "$sfile/reboot_otomatis.sh";
chmod +x /usr/bin/reboot_otomatis;
cat > /etc/cron.d/expired_otomatis <<'EOF'
00 1 * * * root /usr/bin/expired >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/expired_otomatis;
systemctl restart cron;

}




# =========================================================
# BOT USAGE - FINAL
# Menggunakan BOT_TOKEN + CHAT_ID yang SAMA dengan BWBOT/menu-backup.
# Menggunakan virtual environment terisolasi untuk python-telegram-bot.
# =========================================================
log "Memasang BOT Usage FINAL..."

apt-get install -y python3 >/dev/null 2>&1

# ==================== BOT USAGE - FINAL ====================
install_bot_usage() {
    log "Memasang BOT Usage..."

    local usage_url="https://raw.githubusercontent.com/faiqzuhry/faiqzuhry/main/usage.py"
    local venv="/opt/bot-usage-venv"
    local legacy_venv="/opt/bot-usage-env"
    local usage_file="/usr/local/bin/usage.py"
    local config_file="/etc/data/telegram_config.conf"

    # BOT Usage source
    curl -4fsSL "$usage_url" -o "$usage_file" || {
        err "Gagal download usage.py dari GitHub."
        return 1
    }

    chmod 755 "$usage_file"

    # uv dipakai agar Python 3.12 tersedia tanpa mengubah Python sistem.
    if ! command -v uv >/dev/null 2>&1; then
        log "Memasang uv untuk menyediakan Python 3.12..."
        curl -4LsSf https://astral.sh/uv/install.sh | sh || {
            err "Gagal memasang uv."
            return 1
        }
    fi

    export PATH="/root/.local/bin:/usr/local/bin:$PATH"

    log "Menyiapkan Python 3.12 untuk BOT Usage..."
    uv python install 3.12 || {
        err "Gagal menyediakan Python 3.12."
        return 1
    }

    rm -rf "$venv"
    uv venv --python 3.12 --seed "$venv" || {
        err "Gagal membuat virtual environment BOT Usage."
        return 1
    }

    # Kompatibilitas dengan installer/service lama yang masih memanggil
    # /opt/bot-usage-env/bin/python. Symlink dibuat SETELAH venv benar-benar ada,
    # sehingga tidak pernah menghasilkan "No such file or directory".
    if [ -L "$legacy_venv" ] || [ -e "$legacy_venv" ]; then
        rm -rf "$legacy_venv"
    fi
    ln -s "$venv" "$legacy_venv"

    if [ ! -x "$venv/bin/python" ]; then
        err "Interpreter BOT Usage tidak ditemukan: $venv/bin/python"
        return 1
    fi

    # usage.py dari GitHub sudah merupakan versi final dan menangani
    # filter username + pemecahan pesan panjang sendiri.
    # Installer TIDAK melakukan patch/penyisipan kode lagi.

    # PTB 13.15 membutuhkan dependency lama tertentu.
    "$venv/bin/python" -m pip install --no-cache-dir \
        "pip<25" \
        "setuptools<81" \
        wheel \
        "six==1.16.0" \
        "urllib3==1.26.20" \
        "certifi>=2021.5.30" \
        "cachetools==4.2.2" \
        "APScheduler==3.6.3" \
        "pytz>=2018.6" \
        "tornado==6.1" || {
        err "Gagal memasang dependency BOT Usage."
        return 1
    }

    "$venv/bin/python" -m pip install --no-cache-dir \
        "python-telegram-bot==13.15" --no-deps || {
        err "Gagal memasang python-telegram-bot 13.15."
        return 1
    }

    # PTB 13.15 membawa vendored urllib3 yang bermasalah pada environment ini.
    rm -rf "$venv/lib/python3.12/site-packages/telegram/vendor/ptb_urllib3/urllib3"

    # Config BOT_TOKEN tetap bersumber dari /etc/data/telegram_config.conf.
    if [ ! -f "$config_file" ]; then
        err "$config_file tidak ditemukan. Jalankan telegram_final_setup terlebih dahulu."
        return 1
    fi

    local bot_token chat_id
    bot_token="$(grep -m1 '^BOT_TOKEN=' "$config_file" | cut -d= -f2-)"
    chat_id="$(grep -m1 '^CHAT_ID=' "$config_file" | cut -d= -f2-)"

    if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        err "BOT_TOKEN/CHAT_ID tidak ditemukan di $config_file."
        return 1
    fi

    # usage.py lama membaca bot_usage.json secara relatif terhadap WorkingDirectory.
    cat > /usr/local/bin/bot_usage.json <<EOF
{
  "API_TOKEN": "$bot_token",
  "CHAT_ID": "$chat_id"
}
EOF
    chmod 600 /usr/local/bin/bot_usage.json

    # Validasi dependency dan syntax sebelum service dijalankan.
    "$venv/bin/python" - <<'PY' || return 1
import telegram
import cachetools
import apscheduler
import tornado
import urllib3
print("telegram =", telegram.__version__)
print("cachetools =", cachetools.__version__)
print("APScheduler =", apscheduler.__version__)
print("tornado =", tornado.version)
print("urllib3 =", urllib3.__version__)
PY

    "$venv/bin/python" -m py_compile "$usage_file" || {
        err "usage.py gagal py_compile."
        return 1
    }

    # Verifikasi juga path legacy yang muncul pada installer lama.
    "$legacy_venv/bin/python" --version >/dev/null 2>&1 || {
        err "Compatibility interpreter BOT Usage gagal: $legacy_venv/bin/python"
        return 1
    }

    systemctl disable --now bot-usage.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/bot-usage.service

    cat > /etc/systemd/system/check-usage.service <<'EOF'
[Unit]
Description=Telegram Check Usage Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=/opt/bot-usage-venv/bin/python /usr/local/bin/usage.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable check-usage.service >/dev/null 2>&1
    systemctl restart check-usage.service
    sleep 3

    if systemctl is-active --quiet check-usage.service; then
        log "[✓] BOT Check Usage aktif."
    else
        err "BOT Check Usage gagal aktif."
        systemctl status check-usage.service --no-pager || true
        journalctl -u check-usage.service -n 30 --no-pager || true
        return 1
    fi
}

stage07() {
    set -e
#install Firewall
apt install ufw -y
apt install fail2ban -y
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw allow 1080/tcp
sudo ufw allow 2082/tcp
sudo ufw allow 2083/tcp
sudo ufw allow 3128/tcp
sudo ufw allow 8080/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 8880/tcp
sudo ufw allow 8081/tcp
sudo ufw allow $port/tcp
yes | sudo ufw enable
systemctl enable ufw
systemctl start ufw

}


stage08() {
    set -e
#install database
wget -O /var/lib/marzban/db.sqlite3 "$sfile/db.sqlite3"

#install warp
wget -O /root/warp "https://raw.githubusercontent.com/hamid-gh98/x-ui-scripts/main/install_warp_proxy.sh"
sudo chmod +x /root/warp
sudo bash /root/warp -y
rm /root/warp

#finishing
apt autoremove -y
apt clean


}



# Logrotate Marzban
mkdir -p /etc/logrotate.d
cat > /etc/logrotate.d/marzban <<'EOF'
/var/lib/marzban/assets/*.log {
    daily
    rotate 7
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF


stage09() {
    set -e
cd /opt/marzban

# ===== TIMEZONE NEUTRAL =====
# Jangan mengubah timezone host/container. Hapus bind-mount timezone
# dari compose agar Docker mengikuti environment tanpa memaksa zona waktu.
sed -i -e '\\#/etc/timezone#d' -e '\\#/etc/localtime#d' /opt/marzban/docker-compose.yml 2>/dev/null || true
# ===== END TIMEZONE NEUTRAL =====

# ---------------------------------------------------------
# Marzban database safety + migration
# Mencegah error: sqlite3.OperationalError: no such column: admins.users_usage
# ---------------------------------------------------------
if [ ! -f /opt/marzban/.env ] || [ ! -f /opt/marzban/docker-compose.yml ]; then
    colorized_echo red "File konfigurasi Marzban tidak lengkap."
    return 1
fi

# Pastikan Compose yang dipakai migration bersih dari konfigurasi timezone.
# Ini juga memperbaiki instalasi lama saat --resume langsung masuk ke Stage 09.
sed -i \
    -e '\#/etc/timezone#d' \
    -e '\#/etc/localtime#d' \
    /opt/marzban/docker-compose.yml

# Pastikan image panel dan migration berasal dari upstream Marzban yang sama.
# Ini mencegah compose custom lama menjalankan kode baru dengan schema lama.
if grep -qE 'image:[[:space:]]*gozargah/marzban:' /opt/marzban/docker-compose.yml; then
    sed -i -E 's#(image:[[:space:]]*gozargah/marzban:)[^[:space:]]+#\1latest#' /opt/marzban/docker-compose.yml
fi

# Migration tanpa membuat backup database otomatis sebelum migration.
DB_BACKUP=""

# Set kredensial sementara untuk import admin.
sed -i "s/# SUDO_USERNAME = \"admin\"/SUDO_USERNAME = \"${userpanel}\"/" /opt/marzban/.env
sed -i "s/# SUDO_PASSWORD = \"admin\"/SUDO_PASSWORD = \"${passpanel}\"/" /opt/marzban/.env
sed -i "s/UVICORN_PORT = 7879/UVICORN_PORT = ${port}/" /opt/marzban/.env

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    colorized_echo red "Docker Compose tidak ditemukan."
    return 1
fi

# Pastikan image Marzban v0.8.4 tersedia sebelum migration.
# Pull langsung dibuat eksplisit agar kegagalan tidak tersembunyi.
MARZBAN_IMAGE="gozargah/marzban:latest"
colorized_echo cyan "Mengambil image ${MARZBAN_IMAGE}..."
if ! docker pull "${MARZBAN_IMAGE}" >> /var/log/marzban-bootstrap.log 2>&1; then
    colorized_echo red "Gagal mengambil image Marzban ${MARZBAN_IMAGE}."
    echo "===== docker pull error ====="
    tail -n 80 /var/log/marzban-bootstrap.log || true
    return 1
fi

# Pastikan compose menunjuk ke image yang benar-benar tersedia.
sed -i -E 's#(image:[[:space:]]*gozargah/marzban:)[^[:space:]]+#\1latest#' /opt/marzban/docker-compose.yml

# Jalankan Alembic SEBELUM panel dijalankan.
# Dengan demikian query admin baru tidak dieksekusi pada schema lama.
colorized_echo cyan "Menjalankan database migration Marzban..."
if ! $COMPOSE_CMD run --rm --no-deps --entrypoint alembic marzban upgrade head; then
    colorized_echo yellow "Perintah alembic langsung gagal, mencoba Python module alembic..."
    if ! $COMPOSE_CMD run --rm --no-deps --entrypoint python marzban -m alembic upgrade head; then
        colorized_echo red "Migration database Marzban gagal."
        return 1
    fi
fi

colorized_echo green "Database migration Marzban berhasil."

# Baru jalankan panel setelah schema selesai dimigrasikan.
$COMPOSE_CMD up -d --remove-orphans

# Tunggu container sehat sebelum import admin.
for i in $(seq 1 30); do
    if $COMPOSE_CMD ps --status running 2>/dev/null | grep -q marzban; then
        break
    fi
    sleep 2
done

# Import admin setelah migration.
# Kompatibilitas dengan model Admin pada image Marzban saat ini:
# telegram_id harus integer dan discord_webhook berupa string.
# Patch dilakukan DI DALAM container sebelum CLI dijalankan.
if command -v marzban >/dev/null 2>&1; then
    colorized_echo cyan "Menyiapkan kompatibilitas CLI admin Marzban..."

    $COMPOSE_CMD exec -T marzban python - <<'PY'
from pathlib import Path

p = Path("/code/cli/admin.py")
s = p.read_text(encoding="utf-8")
original = s

# Existing-admin path
s = s.replace(
    'AdminPartialModify(password=password, is_sudo=True)',
    'AdminPartialModify(password=password, is_sudo=True, telegram_id=0, discord_webhook="")'
)
s = s.replace(
    'AdminPartialModify(password=password, is_sudo=True, telegram_id="", discord_webhook="")',
    'AdminPartialModify(password=password, is_sudo=True, telegram_id=0, discord_webhook="")'
)

# New-admin path
s = s.replace(
    'AdminCreate(username=username, password=password, is_sudo=True)',
    'AdminCreate(username=username, password=password, is_sudo=True, telegram_id=0, discord_webhook="")'
)
s = s.replace(
    'AdminCreate(username=username, password=password, is_sudo=True, telegram_id="", discord_webhook="")',
    'AdminCreate(username=username, password=password, is_sudo=True, telegram_id=0, discord_webhook="")'
)

if s != original:
    p.write_text(s, encoding="utf-8")
    print("ADMIN_CLI_PATCHED")
else:
    print("ADMIN_CLI_ALREADY_COMPATIBLE_OR_PATTERN_CHANGED")
PY

    if ! marzban cli admin import-from-env -y; then
        colorized_echo red "Import admin gagal."
        $COMPOSE_CMD logs --tail=80 marzban || true
        return 1
    fi

    # Remove bootstrap credentials after successful import.
    if [ -f /opt/marzban/.env ]; then
        sed -i             '/^[[:space:]]*SUDO_USERNAME[[:space:]]*=/d;
             /^[[:space:]]*SUDO_PASSWORD[[:space:]]*=/d'             /opt/marzban/.env
    fi
fi

# Hapus kredensial sementara dari .env setelah admin berhasil dibuat.
sed -i "s/SUDO_USERNAME = \"${userpanel}\"/# SUDO_USERNAME = \"admin\"/" /opt/marzban/.env
sed -i "s/SUDO_PASSWORD = \"${passpanel}\"/# SUDO_PASSWORD = \"admin\"/" /opt/marzban/.env

$COMPOSE_CMD up -d --remove-orphans
cd
echo "Marzban siap; melanjutkan ke pembuatan token API."

}


stage10() {
    set -e

    # =========================================================
    # TOKEN API MARZBAN - FINAL ROBUST
    # Jangan langsung request setelah container start.
    # Marzban/uvicorn butuh waktu untuk bind port dan siap menerima API.
    # =========================================================
    mkdir -p /etc/data
    chmod 700 /etc/data

    TOKEN_FILE="/etc/data/token.json"
    TOKEN_TMP="/etc/data/.token.json.tmp"
    rm -f "$TOKEN_TMP"

    # Ambil port yang benar-benar digunakan Marzban dari .env.
    # Jika tidak ditemukan, gunakan port dari konfigurasi installer.
    API_PORT=""
    if [ -f /opt/marzban/.env ]; then
        API_PORT="$(sed -n 's/^[[:space:]]*UVICORN_PORT[[:space:]]*=[[:space:]]*//p' /opt/marzban/.env | tail -n 1 | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
    fi
    [ -n "$API_PORT" ] || API_PORT="${port}"
    [ -n "$API_PORT" ] || API_PORT="8000"

    token_ok() {
        [ -s "$TOKEN_TMP" ] || return 1
        if command -v jq >/dev/null 2>&1; then
            jq -e '(.access_token // "") | length > 0' "$TOKEN_TMP" >/dev/null 2>&1
        else
            grep -q '"access_token"[[:space:]]*:' "$TOKEN_TMP"
        fi
    }

    request_token() {
        local url="$1"
        : > "$TOKEN_TMP"
        curl -4ksS --connect-timeout 5 --max-time 15 \
            -X POST "$url" \
            -H 'accept: application/json' \
            -H 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode 'grant_type=password' \
            --data-urlencode "username=${userpanel}" \
            --data-urlencode "password=${passpanel}" \
            --data-urlencode 'scope=' \
            --data-urlencode 'client_id=' \
            --data-urlencode 'client_secret=' \
            > "$TOKEN_TMP" 2>/dev/null
    }

    colorized_echo cyan "Menunggu Marzban benar-benar siap..."

    # Tunggu sampai port API benar-benar listen.
    READY=0
    for i in $(seq 1 45); do
        if (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${API_PORT}$|\]:${API_PORT}$") \
           || (command -v netstat >/dev/null 2>&1 && netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${API_PORT}$|\]:${API_PORT}$"); then
            READY=1
            break
        fi

        # Pastikan container tetap hidup sambil menunggu.
        if ! docker inspect -f '{{.State.Running}}' marzban-marzban-1 2>/dev/null | grep -q true; then
            $COMPOSE_CMD -f /opt/marzban/docker-compose.yml up -d marzban >/dev/null 2>&1 || true
        fi
        sleep 2
    done

    if [ "$READY" -eq 0 ]; then
        colorized_echo yellow "Port ${API_PORT} belum terdeteksi setelah 90 detik; tetap mencoba API lokal."
    else
        colorized_echo green "Marzban API sudah listen di port ${API_PORT}."
    fi

    colorized_echo cyan "Membuat token API Marzban..."
    TOKEN_SUCCESS=0

    # Coba lokal berulang kali. Ini mengatasi race-condition saat container baru start.
    for i in $(seq 1 15); do
        if request_token "https://127.0.0.1:${API_PORT}/api/admin/token" && token_ok; then
            TOKEN_SUCCESS=1
            break
        fi

        if request_token "http://127.0.0.1:${API_PORT}/api/admin/token" && token_ok; then
            TOKEN_SUCCESS=1
            break
        fi

        sleep 2
    done

    # Domain hanya fallback terakhir.
    if [ "$TOKEN_SUCCESS" -eq 0 ]; then
        for i in $(seq 1 5); do
            if request_token "https://${domain}:${API_PORT}/api/admin/token" && token_ok; then
                TOKEN_SUCCESS=1
                break
            fi
            sleep 2
        done
    fi

    if [ "$TOKEN_SUCCESS" -eq 0 ]; then
        colorized_echo red "Gagal membuat token API Marzban."
        echo "Port API yang digunakan: ${API_PORT}"
        echo "Periksa status Marzban dan listener port:"
        ss -ltnp 2>/dev/null | grep -E ":${API_PORT}[[:space:]]|:${API_PORT}$" || true
        echo
        $COMPOSE_CMD -f /opt/marzban/docker-compose.yml ps 2>/dev/null || true
        echo
        echo "Log Marzban terakhir:"
        $COMPOSE_CMD -f /opt/marzban/docker-compose.yml logs --tail=40 marzban 2>/dev/null || true
        echo
        echo "Respons terakhir:"
        cat "$TOKEN_TMP" 2>/dev/null || true
        rm -f "$TOKEN_TMP"
        return 1
    fi

    mv -f "$TOKEN_TMP" "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    colorized_echo green "Token API Marzban berhasil dibuat."

    cd
    sed -i -e 's/\r$//' /usr/bin/routing
    if command -v neofetch >/dev/null 2>&1; then
        neofetch
    elif command -v fastfetch >/dev/null 2>&1; then
        fastfetch
    fi
    if [ -f ~/.config/neofetch/config.conf ]; then
        sed -i '/info title/d' ~/.config/neofetch/config.conf
        sed -i '/info "Packages" packages/d' ~/.config/neofetch/config.conf
        sed -i '/info "Shell" shell/d' ~/.config/neofetch/config.conf
        sed -i '/info "Resolution" resolution/d' ~/.config/neofetch/config.conf
        sed -i '/info "Memory" memory/d' ~/.config/neofetch/config.conf
    fi
    command -v profile >/dev/null 2>&1 && profile || true
    echo "Untuk data login dashboard Marzban: " | tee -a /root/log-install.txt
    echo "-=================================-" | tee -a /root/log-install.txt
    echo "URL       : https://${domain}:${port}/dashboard" | tee -a /root/log-install.txt
    echo "username  : ${userpanel}" | tee -a /root/log-install.txt
    echo "password  : ${passpanel}" | tee -a /root/log-install.txt
    echo "-=================================-" | tee -a /root/log-install.txt
    echo "Script telah berhasil di install" | tee -a /root/log-install.txt
    marzban cli admin delete -u admin -y || log "WARN: cleanup admin dilewati (exit=$?)"
}

# =========================================================
# REBUILD VPS
# Dipasang sebagai /usr/local/bin/rebuild
# =========================================================
install_rebuild() {
    local target="/usr/local/bin/rebuild"
    local tmp="${target}.tmp"
    local url="${sfile}/rebuild"

    colorized_echo cyan "[*] Memasang Rebuild VPS..."

    if ! command -v curl >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl >/dev/null 2>&1 || {
            colorized_echo yellow "[!] curl tidak tersedia. Rebuild dilewati."
            return 0
        }
    fi

    if curl -4fsSL --retry 3 --connect-timeout 15 --max-time 120 \
        "$url" -o "$tmp"; then
        if [ -s "$tmp" ] && bash -n "$tmp" >/dev/null 2>&1; then
            chmod 755 "$tmp"
            mv -f "$tmp" "$target"
            colorized_echo green "[✓] Rebuild VPS terpasang: $target"
        else
            rm -f "$tmp"
            colorized_echo yellow "[!] File Rebuild tidak valid. Instalasi dilanjutkan."
        fi
    else
        rm -f "$tmp"
        colorized_echo yellow "[!] Gagal mengambil Rebuild. Instalasi dilanjutkan."
    fi
}

install_rebuild

run_stage 01 "Validasi OS + input konfigurasi" stage01
run_stage 02 "Persiapan VPS + paket" stage02
run_stage 03 "Bootstrap Marzban + Xray" stage03
run_stage 04 "Profile + VNStat + Speedtest + Gotop" stage04
run_stage 05 "Nginx + SSL + konfigurasi Xray" stage05
run_stage 06 "Command LingVPN + Ganti Domain + BWBOT + cron" stage06
run_stage 07 "Firewall + Fail2ban" stage07
run_stage 08 "Database + WARP" stage08
run_stage 09 "Migration database + Admin Marzban" stage09
run_stage 10 "Token API + finalisasi" stage10

# =========================================================
# TELEGRAM FINAL SETUP - PALING AKHIR
# Token + Chat ID baru diminta setelah seluruh stage 01-10 selesai.
# Config yang sama dipakai BWBOT + menu-backup + BOT Usage.
# =========================================================
telegram_final_setup() {
    mkdir -p /etc/data
    chmod 700 /etc/data

    local config_file="/etc/data/telegram_config.conf"
    local tg_bot tg_chat

    echo
    colorized_echo cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    colorized_echo cyan "        KONFIGURASI TELEGRAM - TAHAP AKHIR"
    colorized_echo cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Semua instalasi VPS sudah selesai."
    echo "Sekarang masukkan Bot Token dan Chat ID Telegram."
    echo

    while true; do
        read -r -p "Masukkan Telegram Bot Token: " tg_bot
        tg_bot="${tg_bot#botToken=}"
        tg_bot="${tg_bot#BOT_TOKEN=}"
        tg_bot="${tg_bot#TELEGRAM_BOT_TOKEN=}"
        tg_bot="${tg_bot//$'\r'/}"
        tg_bot="${tg_bot//$'\n'/}"

        if [[ "$tg_bot" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            break
        fi
        colorized_echo red "[ERROR] Bot Token tidak valid."
    done

    while true; do
        read -r -p "Masukkan Telegram Chat ID: " tg_chat
        tg_chat="${tg_chat#chatId=}"
        tg_chat="${tg_chat#CHAT_ID=}"
        tg_chat="${tg_chat#TELEGRAM_CHAT_ID=}"
        tg_chat="${tg_chat//$'\r'/}"
        tg_chat="${tg_chat//$'\n'/}"

        if [[ "$tg_chat" =~ ^-?[0-9]+$ ]]; then
            break
        fi
        colorized_echo red "[ERROR] Chat ID harus berupa angka."
    done

    # Shell-safe config. Semua nama variabel kompatibel dengan script lama/baru.
    umask 077
    {
        printf 'BOT_TOKEN=%q\n' "$tg_bot"
        printf 'CHAT_ID=%q\n' "$tg_chat"
        printf 'botToken=%q\n' "$tg_bot"
        printf 'chatId=%q\n' "$tg_chat"
        printf 'TELEGRAM_BOT_TOKEN=%q\n' "$tg_bot"
        printf 'TELEGRAM_CHAT_ID=%q\n' "$tg_chat"
        printf 'REMARKS=%q\n' ""
        printf 'button_text=%q\n' "Cek Server"
        printf 'button_url=%q\n' "https://google.com"
    } > "$config_file"
    chmod 600 "$config_file"

    echo
    colorized_echo green "[✓] Konfigurasi Telegram tersimpan."

    # Validasi token langsung ke Telegram tanpa menampilkan token.
    local api_result
    api_result="$(curl -4fsS --connect-timeout 10 --max-time 20 \
        "https://api.telegram.org/bot${tg_bot}/getMe" 2>/dev/null || true)"

    if printf '%s' "$api_result" | grep -q '"ok":true'; then
        colorized_echo green "[✓] Bot Token Telegram valid."
    else
        colorized_echo yellow "[!] Token tersimpan, tetapi validasi Telegram gagal."
        echo "    Periksa token atau koneksi internet bila bot belum merespons."
    fi

    echo
    colorized_echo green "[✓] Telegram BWBOT + menu-backup + BOT Usage tersinkron."
}

telegram_final_setup
install_bot_usage

colorized_echo green "╔════════════════════════════════════════════════════╗"
colorized_echo green "║       LINGVPN MARZBAN INSTALLATION SELESAI       ║"
colorized_echo green "╚════════════════════════════════════════════════════╝"
log "INSTALLATION COMPLETE"
echo
read -rp "Reboot sekarang? [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then reboot; fi

# =========================================================
# FAIQVPN CHECK_USAGE BOT
# Telegram token/chat ID memakai /etc/data/telegram_config.conf.
# Tidak memasang telegram-vps-menu.py / remote menu.
# =========================================================

# Aktifkan BOT Check Usage sebelum installer menawarkan reboot.

colorized_echo green "╔════════════════════════════════════════════════════╗"
colorized_echo green "║       LINGVPN MARZBAN INSTALLATION SELESAI       ║"
colorized_echo green "╚════════════════════════════════════════════════════╝"
log "INSTALLATION COMPLETE"
echo
echo "Telegram Check Usage: /cek_usage atau /cek_usage username"
echo "Service: check-usage.service"
echo
read -rp "Reboot sekarang? [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then reboot; fi

colorized_echo green "╔════════════════════════════════════════════════════╗"
colorized_echo green "║       LINGVPN MARZBAN INSTALLATION SELESAI       ║"
colorized_echo green "╚════════════════════════════════════════════════════╝"
log "INSTALLATION COMPLETE"
echo
read -rp "Reboot sekarang? [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then reboot; fi

# =========================================================
# FAIQVPN CHECK_USAGE BOT
# Telegram token/chat ID memakai /etc/data/telegram_config.conf.
# Tidak memasang telegram-vps-menu.py / remote menu.
# =========================================================

# Aktifkan BOT Check Usage sebelum installer menawarkan reboot.

colorized_echo green "╔════════════════════════════════════════════════════╗"
colorized_echo green "║       LINGVPN MARZBAN INSTALLATION SELESAI       ║"
colorized_echo green "╚════════════════════════════════════════════════════╝"
log "INSTALLATION COMPLETE"
echo
echo "Telegram Check Usage: /cek_usage atau /cek_usage username"
echo "Service: check-usage.service"
echo
read -rp "Reboot sekarang? [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then reboot; fi
