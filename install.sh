#!/bin/bash
# LingVPN Marzban Installer - Auto Resume
# Support: Debian 11/12/13 + Ubuntu 20.04/22.04

sfile="https://raw.githubusercontent.com/faiqzuhry/faiqzuhry/main"
# TIMEZONE POLICY: NEUTRAL — jangan set timezone berdasarkan IP/lokasi.
STATE_DIR="/var/lib/lingvpn-install/state"
LOG_FILE="/root/lingvpn-install.log"
# Pin Marzban/Xray so future upstream changes cannot silently alter this build.
MARZBAN_VERSION="v0.8.4"
XRAY_PINNED_VERSION="v26.9.9"
mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
set -o pipefail

download_required() {
    local url="$1" out="$2" label="${3:-file}"
    local tmp="${out}.tmp.$$"
    mkdir -p "$(dirname "$out")"
    rm -f "$tmp"
    if ! curl -4fL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$tmp"; then
        rm -f "$tmp"
        colorized_echo red "[ERROR] Gagal mengambil ${label}: ${url}"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        colorized_echo red "[ERROR] ${label} kosong setelah download."
        return 1
    fi
    mv -f "$tmp" "$out"
}

download_optional() {
    local url="$1" out="$2" label="${3:-file}"
    local tmp="${out}.tmp.$$"
    mkdir -p "$(dirname "$out")"
    rm -f "$tmp"
    if curl -4fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 "$url" -o "$tmp" && [ -s "$tmp" ]; then
        mv -f "$tmp" "$out"
        colorized_echo green "[✓] ${label} tersedia."
    else
        rm -f "$tmp"
        colorized_echo yellow "[!] ${label} tidak tersedia; bagian opsional dilewati."
    fi
    return 0
}

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
  bash /root/install.sh --reset         # hapus instalasi LingVPN/Marzban, lalu install ulang dari awal

Checkpoint disimpan di:
  /var/lib/lingvpn-install/state/

Log utama:
  /root/lingvpn-install.log
USAGE
}

reset_installation() {
    colorized_echo yellow ""
    colorized_echo yellow "⚠ PERINGATAN: --reset akan menghapus instalasi LingVPN/Marzban dari VPS."
    colorized_echo yellow "   - Container Marzban dan volume Compose akan dihapus."
    colorized_echo yellow "   - Database, konfigurasi, token, sertifikat, CloudFront Xray, BOT Usage, dan checkpoint akan dihapus."
    colorized_echo yellow "   - Docker, UFW, vnstat, swap, dan paket sistem umum TIDAK dihapus."
    colorized_echo yellow "   - File /root/install.sh tetap dipertahankan."
    echo
    read -r -p 'Ketik RESET untuk melanjutkan: ' confirm
    if [ "$confirm" != "RESET" ]; then
        colorized_echo yellow "Reset dibatalkan."
        exit 0
    fi

    colorized_echo cyan "[1/7] Menghentikan service LingVPN..."
    systemctl disable --now xray-cloudfront.service 2>/dev/null || true
    systemctl disable --now marzban-cloudfront-sync.timer 2>/dev/null || true
    systemctl disable --now check-usage.service 2>/dev/null || true

    colorized_echo cyan "[2/7] Menghapus container/volume Marzban..."
    if [ -f /opt/marzban/docker-compose.yml ]; then
        if docker compose version >/dev/null 2>&1; then
            (cd /opt/marzban && docker compose down -v --remove-orphans) || true
        elif command -v docker-compose >/dev/null 2>&1; then
            (cd /opt/marzban && docker-compose down -v --remove-orphans) || true
        fi
    fi

    colorized_echo cyan "[3/7] Menghapus service/config LingVPN..."
    rm -f \
      /etc/systemd/system/xray-cloudfront.service \
      /etc/systemd/system/marzban-cloudfront-sync.service \
      /etc/systemd/system/marzban-cloudfront-sync.timer \
      /etc/systemd/system/check-usage.service
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed 2>/dev/null || true

    rm -f \
      /usr/local/bin/cloudfront-xray \
      /usr/local/bin/cloudfront-xray-update \
      /usr/local/bin/xray-main-update \
      /usr/local/bin/xray-version \
      /usr/local/bin/bwbot \
      /usr/local/bin/usage.py \
      /usr/local/bin/bot_usage.json \
      /usr/local/bin/rebuild \
      /usr/local/bin/marzban-wrapper
    # Hapus CLI Marzban yang dipasang installer.
    rm -f /usr/local/bin/marzban

    colorized_echo cyan "[4/7] Menghapus cron dan data installer..."
    rm -f \
      /etc/cron.d/clearlog_otomatis \
      /etc/cron.d/bwbot \
      /etc/cron.d/expired_otomatis
    rm -rf /etc/data /var/lib/lingvpn-install

    colorized_echo cyan "[5/7] Menghapus Marzban/Xray/CloudFront..."
    rm -rf /opt/marzban \
      /var/lib/marzban \
      /opt/bot-usage-venv \
      /var/log/bwbot.log \
      /var/log/marzban-bootstrap.log
    rm -f /etc/marzban-xray-versions.conf
    rm -f /etc/logrotate.d/marzban

    colorized_echo cyan "[6/7] Membersihkan temporary installer..."
    rm -rf /tmp/xray-install /tmp/xray-cloudfront-install /tmp/marzban*
    rm -f /root/lingvpn-install.log

    colorized_echo cyan "[7/7] Menyiapkan state kosong untuk instalasi baru..."
    mkdir -p "$STATE_DIR"
    touch "$LOG_FILE"
    log "RESET TOTAL: instalasi LingVPN/Marzban lama dihapus. Instalasi baru dimulai dari tahap 01."
    colorized_echo green "[✓] Reset selesai. Melanjutkan instalasi dari awal..."
}

case "${1:-}" in
  --status)
    echo "=== STATUS INSTALLASI LINGVPN ==="
    for i in {01..12}; do
      if [ -f "$STATE_DIR/stage_$i.done" ]; then echo "[✓] Tahap $i selesai"; else echo "[ ] Tahap $i belum selesai"; fi
    done
    echo "Log: $LOG_FILE"
    exit 0
    ;;
  --reset)
    reset_installation
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
    colorized_echo cyan "[→] Tahap ${id}/12: ${name}"
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
download_optional "https://raw.githubusercontent.com/teddysun/across/master/bench.sh" "/usr/bin/bench" "benchmark bench"; chmod +x /usr/bin/bench 2>/dev/null || true

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
# Jangan mengeksekusi perintah `install` dari marzban.sh resmi di sini.
# Stage 03 memasang Docker dan menyiapkan CLI wrapper; file .env + compose
# custom dipasang sesudahnya dan Stage 09 melakukan migration + up.
# Ini menghindari ketergantungan pada perubahan internal marzban.sh (termasuk
# follow_marzban_logs) yang dapat berubah atau gagal parse saat upstream berubah.

if ! command -v docker >/dev/null 2>&1; then
    colorized_echo cyan "Docker belum terpasang. Memasang Docker..."
    if ! curl -4fsSL --retry 3 --connect-timeout 5 --max-time 60 https://get.docker.com | sh >>/var/log/marzban-bootstrap.log 2>&1; then
        colorized_echo red "Gagal memasang Docker."
        tail -n 80 /var/log/marzban-bootstrap.log || true
        return 1
    fi
fi

systemctl enable --now docker >/dev/null 2>&1 || true

# Pastikan Docker Compose tersedia. Docker resmi modern menyediakan `docker compose`.
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    colorized_echo red "Docker Compose tidak tersedia setelah Docker dipasang."
    docker version || true
    return 1
fi

# Pasang CLI host Marzban dari script resmi hanya jika file resmi valid.
# Jika upstream sedang mengirim file yang rusak/tidak lengkap, jangan biarkan
# syntax error menghentikan installer; buat wrapper CLI yang memakai container.
MARZBAN_SCRIPT="/tmp/marzban-install.sh"
if download_required "https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh" "$MARZBAN_SCRIPT" "installer resmi Marzban"; then
    if bash -n "$MARZBAN_SCRIPT" >/dev/null 2>&1; then
        install -m 755 "$MARZBAN_SCRIPT" /usr/local/bin/marzban
        colorized_echo green "[✓] Marzban CLI resmi terpasang."
    else
        colorized_echo yellow "Installer resmi Marzban gagal syntax-check; memakai CLI wrapper container."
    fi
else
    colorized_echo yellow "Installer resmi Marzban tidak dapat diambil; memakai CLI wrapper container."
fi
rm -f "$MARZBAN_SCRIPT"

# Wrapper dipakai sebagai fallback dan juga membuat `marzban cli ...` stabil
# tanpa harus menjalankan bootstrap installer upstream.
cat > /usr/local/bin/marzban-wrapper <<'EOF_MARZBAN_WRAPPER'
#!/usr/bin/env bash
set -e
COMPOSE_FILE=/opt/marzban/docker-compose.yml
if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    echo "Docker Compose tidak tersedia." >&2
    exit 1
fi
if [[ "${1:-}" == "cli" ]]; then
    shift
fi
exec "${COMPOSE[@]}" -f "$COMPOSE_FILE" -p marzban exec -T marzban marzban-cli "$@"
EOF_MARZBAN_WRAPPER
chmod 755 /usr/local/bin/marzban-wrapper

# Jika script resmi tidak valid, gunakan wrapper sebagai /usr/local/bin/marzban.
if ! command -v marzban >/dev/null 2>&1; then
    ln -sf /usr/local/bin/marzban-wrapper /usr/local/bin/marzban
fi

#install subs
download_required "$sfile/index.html" "/opt/marzban/index.html" "template index"

#install env
download_required "$sfile/env" "/opt/marzban/.env" "Marzban .env custom"

#install compose
download_required "$sfile/docker-compose.yml" "/opt/marzban/docker-compose.yml" "docker-compose custom"
    if grep -qE 'image:[[:space:]]*gozargah/marzban:' /opt/marzban/docker-compose.yml; then
        sed -i -E "s#(image:[[:space:]]*gozargah/marzban:)[^[:space:]]+#\\1${MARZBAN_VERSION}#" /opt/marzban/docker-compose.yml
    else
        colorized_echo red "Image Marzban tidak ditemukan di docker-compose custom."
        return 1
    fi

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

# =========================================================
# XRAY MAIN CORE - PINNED / UPDATE-SAFE
# =========================================================
XRAY_MAIN_VERSION="${XRAY_PINNED_VERSION}"
XRAY_VERSION_FILE="/etc/marzban-xray-versions.conf"
XRAY_ARCH="$(uname -m)"
case "$XRAY_ARCH" in
    x86_64) XRAY_ASSET="Xray-linux-64.zip" ;;
    aarch64|arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
    *) colorized_echo red "Arsitektur VPS tidak didukung: $XRAY_ARCH"; exit 1 ;;
esac
XRAY_DIR="/var/lib/marzban/xray-core"
XRAY_BIN="${XRAY_DIR}/xray"
rm -rf /tmp/xray-install
mkdir -p /tmp/xray-install "$XRAY_DIR"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_MAIN_VERSION}/${XRAY_ASSET}"
colorized_echo cyan "Memasang Xray Main Core ${XRAY_MAIN_VERSION}..."
curl -fL --retry 5 --retry-delay 2 -o /tmp/xray-install/xray.zip "$XRAY_URL"
unzip -oq /tmp/xray-install/xray.zip xray -d /tmp/xray-install
[ -s /tmp/xray-install/xray ] || { colorized_echo red "Binary Xray kosong/tidak ditemukan."; exit 1; }
install -m 755 /tmp/xray-install/xray "$XRAY_BIN"
rm -rf /tmp/xray-install
XRAY_VERSION_OUTPUT="$($XRAY_BIN version 2>/dev/null || true)"
if ! printf '%s\n' "$XRAY_VERSION_OUTPUT" | grep -q "Xray ${XRAY_MAIN_VERSION#v}"; then
    colorized_echo red "Versi Xray tidak sesuai. Diharapkan ${XRAY_MAIN_VERSION}."
    printf '%s\n' "$XRAY_VERSION_OUTPUT"
    exit 1
fi
if grep -qE '^XRAY_EXECUTABLE_PATH[[:space:]]*=' /opt/marzban/.env; then
    sed -i -E 's#^XRAY_EXECUTABLE_PATH[[:space:]]*=.*#XRAY_EXECUTABLE_PATH = "/var/lib/marzban/xray-core/xray"#' /opt/marzban/.env
else
    printf '\nXRAY_EXECUTABLE_PATH = "/var/lib/marzban/xray-core/xray"\n' >> /opt/marzban/.env
fi
if grep -qE '^XRAY_ASSETS_PATH[[:space:]]*=' /opt/marzban/.env; then
    sed -i -E 's#^XRAY_ASSETS_PATH[[:space:]]*=.*#XRAY_ASSETS_PATH = "/var/lib/marzban/assets"#' /opt/marzban/.env
else
    printf 'XRAY_ASSETS_PATH = "/var/lib/marzban/assets"\n' >> /opt/marzban/.env
fi
colorized_echo green "[✓] Main Xray ${XRAY_MAIN_VERSION} terpasang: ${XRAY_BIN}"
$XRAY_BIN version | head -n 2

cat > "$XRAY_VERSION_FILE" <<EOFVER
XRAY_MAIN_VERSION="${XRAY_MAIN_VERSION}"
XRAY_CLOUDFRONT_VERSION="${XRAY_PINNED_VERSION}"
EOFVER
chmod 644 "$XRAY_VERSION_FILE"

}


stage04() {
    set -e
#profile
echo -e 'profile' >> /root/.profile
download_optional "$sfile/profile" "/usr/bin/profile" "profile";
chmod +x /usr/bin/profile 2>/dev/null || true
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
download_required "$sfile/nginx.conf" "/opt/marzban/nginx.conf" "Nginx/Xray config nginx.conf"
download_required "$sfile/vps.conf" "/opt/marzban/default.conf" "Nginx/Xray config vps.conf"
download_required "$sfile/xray.conf" "/opt/marzban/xray.conf" "Nginx/Xray config xray.conf"
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
download_required "$sfile/xray_config.json" "/var/lib/marzban/xray_config.json" "Xray config JSON"

}


stage06() {
    set -e
#install command
cd /usr/bin
#Additional
download_required "$sfile/status" "/usr/bin/status" "command status" && chmod +x "/usr/bin/status"
download_required "$sfile/menu" "/usr/bin/menu" "command menu" && chmod 755 /usr/bin/menu
test -s /usr/bin/menu || { echo "ERROR: file menu kosong/gagal di-download."; exit 1; }
bash -n /usr/bin/menu || { echo "ERROR: file menu dari repository tidak valid."; exit 1; }
# Download ganti_domain sebagai file terpisah dari repository.
download_required "$sfile/ganti_domain" "/usr/bin/ganti_domain" "command ganti_domain" && chmod 755 /usr/bin/ganti_domain
test -s /usr/bin/ganti_domain || { echo "ERROR: file ganti_domain kosong/gagal di-download."; exit 1; }
bash -n /usr/bin/ganti_domain || { echo "ERROR: file ganti_domain dari repository tidak valid."; exit 1; }
download_required "$sfile/ceklogin" "/usr/bin/ceklogin" "command ceklogin" && chmod +x "/usr/bin/ceklogin"
download_required "$sfile/hapus" "/usr/bin/hapus" "command hapus" && chmod +x "/usr/bin/hapus"
download_required "$sfile/renew" "/usr/bin/renew" "command renew" && chmod +x "/usr/bin/renew"
download_required "$sfile/resetusage" "/usr/bin/resetusage" "command resetusage" && chmod +x "/usr/bin/resetusage"
download_required "$sfile/buat_token" "/usr/bin/buat_token" "command buat_token" && chmod +x "/usr/bin/buat_token"
download_required "$sfile/cekservice" "/usr/bin/cekservice" "command cekservice" && chmod +x "/usr/bin/cekservice"
download_required "$sfile/ram" "/usr/bin/ram" "command ram" && chmod +x "/usr/bin/ram"
download_required "$sfile/menu-backup" "/usr/bin/menu-backup" "command menu-backup" && chmod +x "/usr/bin/menu-backup"
download_required "$sfile/menu-reboot" "/usr/bin/menu-reboot" "command menu-reboot" && chmod +x "/usr/bin/menu-reboot"
download_required "$sfile/menu-akun" "/usr/bin/menu-akun" "command menu-akun" && chmod +x "/usr/bin/menu-akun"
download_required "$sfile/backup" "/usr/bin/backup" "command backup" && chmod +x "/usr/bin/backup"
download_required "$sfile/clearlog" "/usr/bin/clearlog" "command clearlog" && chmod +x "/usr/bin/clearlog"
# Jalankan clearlog otomatis setiap hari pukul 02:00 WIB.
cat > /etc/cron.d/clearlog_otomatis <<'EOF'
00 2 * * * root /usr/bin/clearlog >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/clearlog_otomatis
systemctl restart cron 2>/dev/null || true
download_required "$sfile/ceklog" "/usr/bin/ceklog" "command ceklog" && chmod +x "/usr/bin/ceklog"
download_required "$sfile/cekerror" "/usr/bin/cekerror" "command cekerror" && chmod +x "/usr/bin/cekerror"
download_required "$sfile/ceknginx" "/usr/bin/ceknginx" "command ceknginx" && chmod +x "/usr/bin/ceknginx"
download_required "$sfile/expired" "/usr/bin/expired" "command expired" && chmod +x "/usr/bin/expired"
download_required "$sfile/setlimit" "/usr/bin/setlimit" "command setlimit" && chmod +x "/usr/bin/setlimit"
download_required "$sfile/autokill" "/usr/bin/autokill" "command autokill" && chmod +x "/usr/bin/autokill"

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
download_required "$sfile/fix-ssl.sh" "/usr/bin/fix-ssl" "command fix-ssl" && chmod +x /usr/bin/fix-ssl
download_required "$sfile/ganticore" "/usr/bin/ganticore" "command ganticore" && chmod +x "/usr/bin/ganticore"
download_required "$sfile/routing" "/usr/bin/routing" "command routing" && chmod +x "/usr/bin/routing"
download_required "$sfile/seeroute" "/usr/bin/seeroute" "command seeroute" && chmod +x "/usr/bin/seeroute"
cd

#Install reboot dan expired otomatis
download_required "$sfile/reboot_otomatis.sh" "/usr/bin/reboot_otomatis" "reboot otomatis";
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
# Jangan overwrite database hasil bootstrap/migration dengan database repository.
if [ -f /var/lib/marzban/db.sqlite3 ]; then
    chmod 600 /var/lib/marzban/db.sqlite3 || true
    colorized_echo green "[✓] Database Marzban dipertahankan."
fi

# WARP opsional: kegagalan WARP tidak boleh menghentikan Marzban/CloudFront.
download_optional "https://raw.githubusercontent.com/hamid-gh98/x-ui-scripts/main/install_warp_proxy.sh" "/root/warp" "installer WARP"
if [ -s /root/warp ]; then
    chmod +x /root/warp
    bash /root/warp -y || colorized_echo yellow "[!] WARP gagal dipasang; instalasi tetap dilanjutkan."
    rm -f /root/warp
fi

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

# Pastikan image panel tetap pada versi yang dipin.
if grep -qE 'image:[[:space:]]*gozargah/marzban:' /opt/marzban/docker-compose.yml; then
    sed -i -E "s#(image:[[:space:]]*gozargah/marzban:)[^[:space:]]+#\\1${MARZBAN_VERSION}#" /opt/marzban/docker-compose.yml
fi

# Migration tanpa membuat backup database otomatis sebelum migration.
DB_BACKUP=""

# Set kredensial sementara untuk import admin.
if grep -qE '^[[:space:]]*SUDO_USERNAME[[:space:]]*=' /opt/marzban/.env; then
    sed -i -E "s#^[[:space:]]*SUDO_USERNAME[[:space:]]*=.*#SUDO_USERNAME = \"${userpanel}\"#" /opt/marzban/.env
else
    printf '\nSUDO_USERNAME = "%s"\n' "$userpanel" >> /opt/marzban/.env
fi
if grep -qE '^[[:space:]]*SUDO_PASSWORD[[:space:]]*=' /opt/marzban/.env; then
    sed -i -E "s#^[[:space:]]*SUDO_PASSWORD[[:space:]]*=.*#SUDO_PASSWORD = \"${passpanel}\"#" /opt/marzban/.env
else
    printf 'SUDO_PASSWORD = "%s"\n' "$passpanel" >> /opt/marzban/.env
fi
if grep -qE '^[[:space:]]*UVICORN_PORT[[:space:]]*=' /opt/marzban/.env; then
    sed -i -E "s#^[[:space:]]*UVICORN_PORT[[:space:]]*=.*#UVICORN_PORT = ${port}#" /opt/marzban/.env
else
    printf 'UVICORN_PORT = %s\n' "$port" >> /opt/marzban/.env
fi

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
MARZBAN_IMAGE="gozargah/marzban:${MARZBAN_VERSION}"
colorized_echo cyan "Mengambil image ${MARZBAN_IMAGE}..."
if ! docker pull "${MARZBAN_IMAGE}" >> /var/log/marzban-bootstrap.log 2>&1; then
    colorized_echo red "Gagal mengambil image Marzban ${MARZBAN_IMAGE}."
    echo "===== docker pull error ====="
    tail -n 80 /var/log/marzban-bootstrap.log || true
    return 1
fi

# Pastikan compose menunjuk ke image yang benar-benar tersedia.
sed -i -E "s#(image:[[:space:]]*gozargah/marzban:)[^[:space:]]+#\\1${MARZBAN_VERSION}#" /opt/marzban/docker-compose.yml

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

    MARZBAN_CLI="$(command -v marzban 2>/dev/null || printf /usr/local/bin/marzban)"
    if ! "$MARZBAN_CLI" cli admin import-from-env -y; then
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

# Verifikasi final: container Marzban benar-benar menggunakan main Xray pinned.
# Jangan lanjut jika runtime masih menunjuk ke core lain.
MAIN_XRAY_VERSION="$($COMPOSE_CMD exec -T marzban /var/lib/marzban/xray-core/xray version 2>/dev/null | head -n 1 || true)"
if ! printf '%s\n' "$MAIN_XRAY_VERSION" | grep -q 'Xray 26.9.9'; then
    colorized_echo red "Runtime Marzban tidak memakai Xray 26.9.9."
    echo "Hasil: ${MAIN_XRAY_VERSION}"
    echo "XRAY_EXECUTABLE_PATH:"
    grep -E '^XRAY_EXECUTABLE_PATH[[:space:]]*=' /opt/marzban/.env || true
    return 1
fi
colorized_echo green "[✓] Runtime Marzban terverifikasi memakai Xray 26.9.9."
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

        # Pastikan service tetap hidup sambil menunggu; jangan bergantung pada nama container.
        if ! $COMPOSE_CMD -f /opt/marzban/docker-compose.yml ps --status running marzban 2>/dev/null | grep -q marzban; then
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
    if command -v marzban >/dev/null 2>&1 || [ -x /usr/local/bin/marzban ]; then
        MARZBAN_CLI="$(command -v marzban 2>/dev/null || printf /usr/local/bin/marzban)"
        "$MARZBAN_CLI" cli admin delete -u admin -y || log "WARN: cleanup admin dilewati (exit=$?)"
    fi
}

# =========================================================
# STAGE 11 - CLOUDFRONT XRAY (SEPARATE CORE)
# =========================================================
stage11() {
    set -e
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        colorized_echo red "Docker Compose tidak ditemukan."
        return 1
    fi
    cd /opt/marzban

    local CF_VERSION="${XRAY_PINNED_VERSION}"
    if [ -f /etc/marzban-xray-versions.conf ]; then
        . /etc/marzban-xray-versions.conf
        CF_VERSION="${XRAY_CLOUDFRONT_VERSION:-v26.9.9}"
    fi
    local CF_DIR="/var/lib/marzban/cloudfront"
    local CF_BIN="${CF_DIR}/xray"
    local CF_CFG="${CF_DIR}/config.json"
    local CF_SCRIPT="/usr/local/bin/cloudfront-xray"
    local CF_SYNC="/usr/local/bin/cloudfront-xray-update"
    local CF_SERVICE="/etc/systemd/system/xray-cloudfront.service"
    local CF_SYNC_SERVICE="/etc/systemd/system/marzban-cloudfront-sync.service"
    local CF_TIMER="/etc/systemd/system/marzban-cloudfront-sync.timer"
    local NGX="/opt/marzban/xray.conf"

    mkdir -p "$CF_DIR" /etc/systemd/system

    case "$(uname -m)" in
        x86_64) CF_ASSET="Xray-linux-64.zip" ;;
        aarch64|arm64) CF_ASSET="Xray-linux-arm64-v8a.zip" ;;
        *) colorized_echo red "Arsitektur CloudFront tidak didukung: $(uname -m)"; return 1 ;;
    esac

    rm -rf /tmp/xray-cloudfront-install
    mkdir -p /tmp/xray-cloudfront-install
    curl -fL --retry 5 --retry-delay 2 \
        -o /tmp/xray-cloudfront-install/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/download/${CF_VERSION}/${CF_ASSET}"
    unzip -oq /tmp/xray-cloudfront-install/xray.zip xray -d /tmp/xray-cloudfront-install
    install -m 755 /tmp/xray-cloudfront-install/xray "$CF_BIN"
    rm -rf /tmp/xray-cloudfront-install

    # Jangan gunakan `xray version | grep -q` langsung karena installer
    # memakai pipefail. grep -q dapat menutup pipe lebih awal dan membuat
    # Xray menerima SIGPIPE, sehingga verifikasi palsu dianggap gagal.
    CF_VERSION_OUTPUT="$("$CF_BIN" version 2>/dev/null || true)"
    if ! printf '%s\\n' "$CF_VERSION_OUTPUT" | grep -q "Xray ${CF_VERSION#v}"; then
        colorized_echo red "CloudFront Xray bukan ${CF_VERSION}."
        printf '%s\\n' "$CF_VERSION_OUTPUT"
        return 1
    fi

    cp -a "$NGX" "/root/xray.conf.before-cloudfront-v3.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    python3 - "$NGX" <<'PYNGX'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
block="""

# CloudFront WebSocket -> separate Xray core
location = /vmess-cloudfront {
    proxy_pass http://127.0.0.1:10010;
    proxy_http_version 1.1;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $http_host;
    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
    proxy_buffering off;
}

location = /vless-cloudfront {
    proxy_pass http://127.0.0.1:10011;
    proxy_http_version 1.1;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $http_host;
    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
    proxy_buffering off;
}

location = /trojan-cloudfront {
    proxy_pass http://127.0.0.1:10012;
    proxy_http_version 1.1;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $http_host;
    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
    proxy_buffering off;
}
"""
if '/vmess-cloudfront' not in s:
    needle='root /var/www/html;'
    if needle not in s: raise SystemExit('root /var/www/html; tidak ditemukan')
    s=s.replace(needle, needle+block, 1)
p.write_text(s)
PYNGX

    cat > "$CF_SCRIPT" <<'EOFCFGEN'
#!/usr/bin/env bash
set -euo pipefail
CF_DIR=/var/lib/marzban/cloudfront
CF_CFG="$CF_DIR/config.json"
DB=/var/lib/marzban/db.sqlite3
LOCK=/run/cloudfront-xray-sync.lock
exec 9>"$LOCK"
flock -n 9 || exit 0
python3 - "$DB" "$CF_CFG.tmp" <<'PYCF'
import json, sqlite3, sys
from datetime import datetime, timezone

db,out=sys.argv[1:]
con=sqlite3.connect(db, timeout=10); con.row_factory=sqlite3.Row
users={dict(r).get('id'):dict(r) for r in con.execute('SELECT * FROM users')}
clients={'vmess':[],'vless':[],'trojan':[]}
now=int(datetime.now(timezone.utc).timestamp())
for rr in con.execute('SELECT * FROM proxies'):
    p=dict(rr); u=users.get(p.get('user_id'))
    if not u: continue
    if str(u.get('status','active')).lower() not in ('active','limited','on_hold'): continue
    exp=u.get('expire')
    try:
        if exp and int(exp)>0 and int(exp)<now: continue
    except Exception: pass
    typ=str(p.get('type','')).lower(); raw=p.get('settings')
    if typ not in clients or not raw: continue
    try: st=json.loads(raw) if isinstance(raw,str) else raw
    except Exception: continue
    name=str(u.get('username') or '')
    if typ in ('vmess','vless'):
        uid=st.get('id') or st.get('uuid')
        if uid:
            x={'id':uid,'email':name}
            if typ=='vmess': x['alterId']=0
            clients[typ].append(x)
    elif typ=='trojan' and st.get('password'):
        clients[typ].append({'password':st['password'],'email':name})
cfg={
 'log':{'loglevel':'warning'},
 'api':{'tag':'api-cf','services':['HandlerService','LoggerService','StatsService']},
 'stats':{},
 'policy':{'levels':{'0':{'statsUserUplink':True,'statsUserDownlink':True}}},
 'inbounds':[
  {'tag':'api-cf','listen':'127.0.0.1','port':10085,'protocol':'dokodemo-door','settings':{'address':'127.0.0.1'}},
  {'tag':'VMESS_CLOUDFRONT','listen':'127.0.0.1','port':10010,'protocol':'vmess','settings':{'clients':clients['vmess']},'streamSettings':{'network':'ws','wsSettings':{'path':'/vmess-cloudfront'}}},
  {'tag':'VLESS_CLOUDFRONT','listen':'127.0.0.1','port':10011,'protocol':'vless','settings':{'clients':clients['vless'],'decryption':'none'},'streamSettings':{'network':'ws','wsSettings':{'path':'/vless-cloudfront'}}},
  {'tag':'TROJAN_CLOUDFRONT','listen':'127.0.0.1','port':10012,'protocol':'trojan','settings':{'clients':clients['trojan']},'streamSettings':{'network':'ws','wsSettings':{'path':'/trojan-cloudfront'}}}
 ],
 'outbounds':[{'protocol':'freedom','tag':'direct'},{'protocol':'blackhole','tag':'blocked'}],
 'routing':{'rules':[]}
}
open(out,'w').write(json.dumps(cfg,indent=2))
PYCF
mv -f "$CF_CFG.tmp" "$CF_CFG"
EOFCFGEN
    chmod 755 "$CF_SCRIPT"
    "$CF_SCRIPT"
    "$CF_BIN" run -test -config "$CF_CFG"

    cat > "$CF_SERVICE" <<EOFCS
[Unit]
Description=CloudFront Xray Core (separate from Marzban)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CF_BIN run -config $CF_CFG
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOFCS

    cat > "$CF_SYNC" <<'EOFSYNC'
#!/usr/bin/env bash
set -euo pipefail
CF_DIR=/var/lib/marzban/cloudfront
DB=/var/lib/marzban/db.sqlite3
CF_CFG="$CF_DIR/config.json"
LOCK=/run/cloudfront-xray-sync.lock
exec 9>"$LOCK"
flock -n 9 || exit 0
[ -f "$DB" ] && [ -x "$CF_DIR/xray" ] || exit 0
python3 - "$DB" "$CF_CFG.new.json" <<'PYCFSYNC'
import json, sqlite3, sys
from datetime import datetime, timezone

db,out=sys.argv[1:]
con=sqlite3.connect(db, timeout=10); con.row_factory=sqlite3.Row
users={dict(r).get('id'):dict(r) for r in con.execute('SELECT * FROM users')}
clients={'vmess':[],'vless':[],'trojan':[]}; now=int(datetime.now(timezone.utc).timestamp())
for rr in con.execute('SELECT * FROM proxies'):
    p=dict(rr); u=users.get(p.get('user_id'))
    if not u or str(u.get('status','active')).lower() not in ('active','limited','on_hold'): continue
    exp=u.get('expire')
    try:
        if exp and int(exp)>0 and int(exp)<now: continue
    except Exception: pass
    typ=str(p.get('type','')).lower(); raw=p.get('settings')
    if typ not in clients or not raw: continue
    try: st=json.loads(raw) if isinstance(raw,str) else raw
    except Exception: continue
    name=str(u.get('username') or '')
    if typ in ('vmess','vless') and (uid:=st.get('id') or st.get('uuid')):
        x={'id':uid,'email':name};
        if typ=='vmess': x['alterId']=0
        clients[typ].append(x)
    elif typ=='trojan' and st.get('password'):
        clients[typ].append({'password':st['password'],'email':name})
cfg={'log':{'loglevel':'warning'},'api':{'tag':'api-cf','services':['HandlerService','LoggerService','StatsService']},'stats':{},'policy':{'levels':{'0':{'statsUserUplink':True,'statsUserDownlink':True}}},'inbounds':[
 {'tag':'api-cf','listen':'127.0.0.1','port':10085,'protocol':'dokodemo-door','settings':{'address':'127.0.0.1'}},
 {'tag':'VMESS_CLOUDFRONT','listen':'127.0.0.1','port':10010,'protocol':'vmess','settings':{'clients':clients['vmess']},'streamSettings':{'network':'ws','wsSettings':{'path':'/vmess-cloudfront'}}},
 {'tag':'VLESS_CLOUDFRONT','listen':'127.0.0.1','port':10011,'protocol':'vless','settings':{'clients':clients['vless'],'decryption':'none'},'streamSettings':{'network':'ws','wsSettings':{'path':'/vless-cloudfront'}}},
 {'tag':'TROJAN_CLOUDFRONT','listen':'127.0.0.1','port':10012,'protocol':'trojan','settings':{'clients':clients['trojan']},'streamSettings':{'network':'ws','wsSettings':{'path':'/trojan-cloudfront'}}}],
'outbounds':[{'protocol':'freedom','tag':'direct'},{'protocol':'blackhole','tag':'blocked'}],'routing':{'rules':[]}}
open(out,'w').write(json.dumps(cfg,sort_keys=True,indent=2))
PYCFSYNC
if ! cmp -s "$CF_CFG.new.json" "$CF_CFG"; then
    "$CF_DIR/xray" run -test -config "$CF_CFG.new.json"
    mv -f "$CF_CFG.new.json" "$CF_CFG"
    systemctl restart xray-cloudfront.service
else
    rm -f "$CF_CFG.new.json"
fi
EOFSYNC
    chmod 755 "$CF_SYNC"

    cat > "$CF_SYNC_SERVICE" <<EOFSS
[Unit]
Description=Sync Marzban users to CloudFront Xray
After=docker.service xray-cloudfront.service

[Service]
Type=oneshot
ExecStart=$CF_SYNC
EOFSS

    cat > "$CF_TIMER" <<EOFT
[Unit]
Description=Periodic Marzban to CloudFront Xray sync

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOFT

    $COMPOSE_CMD -f /opt/marzban/docker-compose.yml config --quiet
    $COMPOSE_CMD -f /opt/marzban/docker-compose.yml up -d --force-recreate nginx
    $COMPOSE_CMD -f /opt/marzban/docker-compose.yml exec -T nginx nginx -t

    systemctl daemon-reload
    systemctl enable --now xray-cloudfront.service
    systemctl enable --now marzban-cloudfront-sync.timer
    "$CF_SYNC"

    colorized_echo green "[✓] Main Xray:"
    /var/lib/marzban/xray-core/xray version | head -n 2
    colorized_echo green "[✓] CloudFront Xray:"
    "$CF_BIN" version | head -n 2
    colorized_echo green "[✓] CloudFront listener:"
    ss -ltnp 2>/dev/null | grep -E ':10010|:10011|:10012|:10085' || true
    colorized_echo green "[✓] CloudFront Xray + Nginx route + auto-sync terpasang."
    colorized_echo yellow "CloudFront AWS tetap memakai origin HTTPS domain VPS dan viewer domain CloudFront."
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

    download_optional "$url" "$tmp" "Rebuild VPS"
    if [ -s "$tmp" ] && bash -n "$tmp" >/dev/null 2>&1; then
        chmod 755 "$tmp"
        mv -f "$tmp" "$target"
        colorized_echo green "[✓] Rebuild VPS terpasang: $target"
    else
        rm -f "$tmp"
        colorized_echo yellow "[!] Rebuild VPS tidak tersedia/valid. Instalasi dilanjutkan."
    fi
}

# =========================================================
# STAGE 12 - XRAY MAIN VERSION MANAGER
# =========================================================
stage12() {
    set -e
    local VERSION_FILE="/etc/marzban-xray-versions.conf"
    local MAIN_DIR="/var/lib/marzban/xray-core"
    local MAIN_BIN="${MAIN_DIR}/xray"
    local BACKUP_DIR="${MAIN_DIR}/backups"
    local COMPOSE="/opt/marzban/docker-compose.yml"
    local CF_BIN="/var/lib/marzban/cloudfront/xray"
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        colorized_echo red "Docker Compose tidak ditemukan."
        return 1
    fi
    mkdir -p "$BACKUP_DIR"
    cat > "$VERSION_FILE" <<EOFVER
XRAY_MAIN_VERSION="${XRAY_PINNED_VERSION}"
XRAY_CLOUDFRONT_VERSION="${XRAY_PINNED_VERSION}"
EOFVER
    chmod 644 "$VERSION_FILE"

    cat > /usr/local/bin/xray-main-update <<'EOFXUP'
#!/usr/bin/env bash
set -Eeuo pipefail
VERSION_FILE=/etc/marzban-xray-versions.conf
MAIN_DIR=/var/lib/marzban/xray-core
MAIN_BIN=$MAIN_DIR/xray
BACKUP_DIR=$MAIN_DIR/backups
COMPOSE=/opt/marzban/docker-compose.yml
ENV_FILE=/opt/marzban/.env
XCFG=/var/lib/marzban/xray_config.json
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ASSET=Xray-linux-64.zip ;;
  aarch64|arm64) ASSET=Xray-linux-arm64-v8a.zip ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
usage(){ echo "Usage: xray-main-update status | update v26.10.x | rollback"; }
current(){ "$MAIN_BIN" version 2>/dev/null | head -n1 || true; }
status(){
  echo "Desired : $(grep -E '^XRAY_MAIN_VERSION=' "$VERSION_FILE" 2>/dev/null | head -n1 || echo unknown)"
  echo "Active  : $(current)"
  echo "CloudFront: $(/var/lib/marzban/cloudfront/xray version 2>/dev/null | head -n1 || echo not-installed)"
}
backup(){
  local v stamp dest
  v=$(current | sed 's/[^0-9.]//g'); stamp=$(date +%Y%m%d-%H%M%S)
  dest="$BACKUP_DIR/xray-${v:-unknown}-${stamp}"
  cp -a "$MAIN_BIN" "$dest"; echo "$dest"
}
update(){
  local requested="$1" tmp url newver backup_path cfver runtime
  [[ "$requested" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version harus seperti v26.10.1" >&2; exit 2; }
  requested="v${requested#v}"
  tmp=$(mktemp -d /tmp/xray-main-update.XXXXXX)
  trap 'rm -rf "$tmp"' RETURN
  url="https://github.com/XTLS/Xray-core/releases/download/${requested}/${ASSET}"
  curl -fL --retry 5 --retry-delay 2 -o "$tmp/xray.zip" "$url"
  unzip -oq "$tmp/xray.zip" xray -d "$tmp"
  chmod 755 "$tmp/xray"
  newver=$("$tmp/xray" version 2>/dev/null | head -n1)
  grep -q "Xray ${requested#v}" <<<"$newver" || { echo "Version binary tidak sesuai: $newver" >&2; exit 1; }
  [[ ! -f "$XCFG" ]] || "$tmp/xray" run -test -config "$XCFG"
  backup_path=$(backup)
  cfver=$(grep -E '^XRAY_CLOUDFRONT_VERSION=' "$VERSION_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "\'" || true)
  cfver=${cfver:-v26.9.9}
  install -m 755 "$tmp/xray" "$MAIN_BIN"
  { printf 'XRAY_MAIN_VERSION="%s"\n' "$requested"; printf 'XRAY_CLOUDFRONT_VERSION="%s"\n' "$cfver"; } > "$VERSION_FILE.tmp"
  mv -f "$VERSION_FILE.tmp" "$VERSION_FILE"
  sed -i -E 's#^[[:space:]]*XRAY_EXECUTABLE_PATH[[:space:]]*=.*#XRAY_EXECUTABLE_PATH = "/var/lib/marzban/xray-core/xray"#' "$ENV_FILE" 2>/dev/null || true
  cd /opt/marzban
  docker compose config --quiet
  docker compose up -d --no-deps --force-recreate marzban
  sleep 3
  runtime=$(docker compose exec -T marzban /var/lib/marzban/xray-core/xray version 2>/dev/null | head -n1 || true)
  if ! grep -q "Xray ${requested#v}" <<<"$runtime"; then
    echo "Runtime verification FAILED; rollback otomatis." >&2
    install -m 755 "$backup_path" "$MAIN_BIN"
    docker compose up -d --no-deps --force-recreate marzban
    exit 1
  fi
  echo "SUCCESS: $runtime"; echo "Backup: $backup_path"
}
rollback(){
  local backup_path runtime
  backup_path=$(ls -1t "$BACKUP_DIR"/xray-* 2>/dev/null | head -n1 || true)
  [[ -n "$backup_path" && -f "$backup_path" ]] || { echo "No Xray backup found." >&2; exit 1; }
  [[ ! -f "$XCFG" ]] || "$backup_path" run -test -config "$XCFG"
  install -m 755 "$backup_path" "$MAIN_BIN"
  cd /opt/marzban
  docker compose up -d --no-deps --force-recreate marzban
  sleep 3
  runtime=$(docker compose exec -T marzban /var/lib/marzban/xray-core/xray version 2>/dev/null | head -n1 || true)
  echo "Rollback runtime: $runtime"
  grep -q 'Xray ' <<<"$runtime"
  rollback_ver=$(printf '%s\n' "$runtime" | sed -n 's/.*Xray \([0-9][0-9.]*\).*/\1/p' | head -n1)
  if [[ -n "$rollback_ver" ]]; then
    cfver=$(grep -E '^XRAY_CLOUDFRONT_VERSION=' "$VERSION_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
    cfver=${cfver:-v26.9.9}
    { printf 'XRAY_MAIN_VERSION="v%s"\n' "$rollback_ver"; printf 'XRAY_CLOUDFRONT_VERSION="%s"\n' "$cfver"; } > "$VERSION_FILE.tmp"
    mv -f "$VERSION_FILE.tmp" "$VERSION_FILE"
  fi
}
case "${1:-status}" in
 status) status;;
 update) [[ -n "${2:-}" ]] || { usage; exit 2; }; update "$2";;
 rollback) rollback;;
 *) usage; exit 2;;
esac
EOFXUP
    chmod 755 /usr/local/bin/xray-main-update
    cat > /usr/local/bin/xray-version <<'EOFXV'
#!/usr/bin/env bash
exec /usr/local/bin/xray-main-update status
EOFXV
    chmod 755 /usr/local/bin/xray-version
    MAIN_VERSION_OUTPUT="$("$MAIN_BIN" version 2>/dev/null || true)"
    printf '%s\\n' "$MAIN_VERSION_OUTPUT" | grep -q "Xray ${XRAY_PINNED_VERSION#v}"

    if [ -x "$CF_BIN" ]; then
        CF_VERSION_OUTPUT="$("$CF_BIN" version 2>/dev/null || true)"
        printf '%s\\n' "$CF_VERSION_OUTPUT" | grep -q "Xray ${XRAY_PINNED_VERSION#v}"
    fi
    $COMPOSE_CMD -f "$COMPOSE" config --quiet
    colorized_echo green "[✓] Xray version manager terpasang."
    colorized_echo cyan "Main Xray : v26.9.9"
    colorized_echo cyan "CloudFront: v26.9.9"
    colorized_echo yellow "Upgrade: xray-main-update update v26.10.x"
    colorized_echo yellow "Rollback: xray-main-update rollback"
}

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
run_stage 11 "CloudFront Xray + Nginx WebSocket + auto-sync user" stage11
run_stage 12 "Xray Main version manager + backup + rollback" stage12

# Rebuild dipasang setelah semua dependency dan seluruh stage selesai.
install_rebuild

# =========================================================
# TELEGRAM FINAL SETUP - PALING AKHIR
# Token + Chat ID baru diminta setelah seluruh stage 01-12 selesai.
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
echo "Telegram Check Usage: /cek_usage atau /cek_usage username"
echo "Service: check-usage.service"
echo
read -rp "Reboot sekarang? [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then reboot; fi
