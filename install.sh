#!/bin/bash
# LingVPN Marzban Installer - Auto Resume
# Support: Debian 11/12/13 + Ubuntu 20.04/22.04

sfile="https://raw.githubusercontent.com/faiqzuhry/faiqzuhry/main"
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
    read_saved email "Masukkan Email anda: " /etc/data/email
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
    if [ -z "${choice:-}" ] && [ -s /etc/data/ipv6_choice ]; then choice=$(cat /etc/data/ipv6_choice); fi
    if [ -z "${choice:-}" ]; then
        echo "1. Aktifkan IPv6"; echo "2. Nonaktifkan IPv6"; read -rp "Masukkan nomor pilihan (1 atau 2): " choice
        echo "$choice" >/etc/data/ipv6_choice
    fi

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
#Install Marzban
# Gunakan script resmi hanya untuk menyiapkan Docker/CLI.
# Output ditulis ke log agar traceback sementara tidak memenuhi terminal.
curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh -o /tmp/marzban-install.sh
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
curl -fsSL https://get.acme.sh | sh -s email="$email"
/root/.acme.sh/acme.sh --server letsencrypt --register-account -m $email --issue -d $domain --standalone -k ec-256 --debug
~/.acme.sh/acme.sh --installcert -d "$domain" --fullchainpath /var/lib/marzban/xray.crt --keypath /var/lib/marzban/xray.key --ecc
wget -O /var/lib/marzban/xray_config.json "$sfile/xray_config.json"

}


stage06() {
    set -e

    # =========================================================
    # FILE REPOSITORY — HANYA FILE YANG ADA DI REPOSITORY
    # =========================================================
    # Sengaja TIDAK memasang file add* seperti:
    # addvmess, addvless, addtrojan, addshadow,
    # addvmws/addvlws/addtrws/addssws, add*grpc, add*hu,
    # dan addtrial.
    #
    # Hanya file pendukung yang memang ada di repository
    # dan digunakan oleh menu/installer yang dipasang.
    # =========================================================
    cd /usr/bin

    install_repo_script() {
        local name="$1"
        local target="${2:-/usr/bin/$1}"

        wget -qO "$target" "$sfile/$name" || {
            echo "ERROR: gagal download $name dari repository."
            return 1
        }

        [ -s "$target" ] || {
            echo "ERROR: file $name kosong."
            return 1
        }

        chmod 755 "$target"

        # Validasi Bash hanya untuk script.
        case "$name" in
            *.sh|menu|menu-akun|menu-backup|menu-reboot|backup|buat_token|cekerror|ceklog|ceklogin|ceknginx|cekservice|expired|ganticore|hapus|ram|rebuild|renew|resetusage|routing|seeroute|setlimit|status|autokill|ganti_domain)
                bash -n "$target" >/dev/null 2>&1 || {
                    echo "ERROR: syntax $name tidak valid."
                    return 1
                }
                ;;
        esac
    }

    # Menu
    install_repo_script menu /usr/bin/menu
    install_repo_script menu-akun /usr/bin/menu-akun
    install_repo_script menu-backup /usr/bin/menu-backup
    install_repo_script menu-reboot /usr/bin/menu-reboot

    # User / account management
    install_repo_script ceklogin /usr/bin/ceklogin
    install_repo_script hapus /usr/bin/hapus
    install_repo_script renew /usr/bin/renew
    install_repo_script resetusage /usr/bin/resetusage
    install_repo_script expired /usr/bin/expired
    install_repo_script setlimit /usr/bin/setlimit
    install_repo_script status /usr/bin/status

    # Server tools
    install_repo_script buat_token /usr/bin/buat_token
    install_repo_script cekservice /usr/bin/cekservice
    install_repo_script ram /usr/bin/ram
    install_repo_script ceklog /usr/bin/ceklog
    install_repo_script cekerror /usr/bin/cekerror
    install_repo_script ceknginx /usr/bin/ceknginx
    install_repo_script clearlog /usr/bin/clearlog
    install_repo_script autokill /usr/bin/autokill

    # Network / routing / domain
    install_repo_script ganticore /usr/bin/ganticore
    install_repo_script routing /usr/bin/routing
    install_repo_script seeroute /usr/bin/seeroute
    install_repo_script ganti_domain /usr/bin/ganti_domain

    # Backup / reboot / rebuild
    install_repo_script backup /usr/bin/backup
    install_repo_script reboot_otomatis.sh /usr/bin/reboot_otomatis.sh
    install_repo_script rebuild /usr/local/bin/rebuild

    # SSL helper
    install_repo_script fix-ssl.sh /usr/bin/fix-ssl.sh

    # Cron
    cat > /etc/cron.d/clearlog_otomatis <<'EOF'
00 2 * * * root /usr/bin/clearlog >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/clearlog_otomatis

    cat > /etc/cron.d/expired_otomatis <<'EOF'
00 1 * * * root /usr/bin/expired >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/expired_otomatis

    systemctl restart cron 2>/dev/null || true
    cd /root

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
# BOT USAGE - SOURCE FROM GITHUB
# Source resmi: faiqzuhry/faiqzuhry/main/usage.py
# =========================================================
log "Memasang BOT Usage dari GitHub..."

apt-get install -y python3 python3-venv curl >/dev/null 2>&1

USAGE_URL="https://raw.githubusercontent.com/faiqzuhry/faiqzuhry/main/usage.py"
USAGE_TMP="/tmp/usage.py.$$"

if ! curl -4fsSL --retry 3 --connect-timeout 15 "$USAGE_URL" -o "$USAGE_TMP"; then
    rm -f "$USAGE_TMP"
    colorized_echo red "[x] Gagal mengambil usage.py dari GitHub."
    return 1
fi

if [ ! -s "$USAGE_TMP" ] || ! grep -q 'def cek_usage_command' "$USAGE_TMP"; then
    rm -f "$USAGE_TMP"
    colorized_echo red "[x] usage.py dari GitHub tidak valid / bukan BOT Check Usage."
    return 1
fi

install -m 755 "$USAGE_TMP" /usr/local/bin/usage.py
rm -f "$USAGE_TMP"

# Isolasi dependency agar Python sistem tidak terganggu.
BOT_USAGE_VENV="/opt/bot-usage-venv"
if [ ! -x "$BOT_USAGE_VENV/bin/python" ]; then
    python3 -m venv "$BOT_USAGE_VENV"
fi

"$BOT_USAGE_VENV/bin/python" -m pip install --upgrade pip >/dev/null 2>&1 || true
if ! "$BOT_USAGE_VENV/bin/python" -m pip install 'python-telegram-bot==13.15' >/dev/null 2>&1; then
    colorized_echo red "[x] Gagal memasang python-telegram-bot 13.15 untuk usage.py."
    return 1
fi

# usage.py membaca bot_usage.json relatif terhadap WorkingDirectory.
if [ ! -f /etc/data/telegram_config.conf ]; then
    colorized_echo red "[x] /etc/data/telegram_config.conf tidak ditemukan."
    return 1
fi

BOT_TOKEN="$(awk -F= '$1=="BOT_TOKEN" || $1=="API_TOKEN" || $1=="TELEGRAM_BOT_TOKEN" {print $2; exit}' /etc/data/telegram_config.conf | tr -d '\r' | sed 's/^['\"]//;s/['\"]$//')"
CHAT_ID="$(awk -F= '$1=="CHAT_ID" || $1=="TELEGRAM_CHAT_ID" || $1=="chatId" {print $2; exit}' /etc/data/telegram_config.conf | tr -d '\r' | sed 's/^['\"]//;s/['\"]$//')"

if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    colorized_echo red "[x] BOT_TOKEN/CHAT_ID tidak ditemukan di telegram_config.conf."
    return 1
fi

cat > /usr/local/bin/bot_usage.json <<EOF
{
  "API_TOKEN": "$BOT_TOKEN",
  "CHAT_ID": "$CHAT_ID"
}
EOF
chmod 600 /usr/local/bin/bot_usage.json

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

# =========================================================
# MARZBAN IMAGE FIX
# Repository docker-compose memakai Docker Hub lama:
#   gozargah/marzban:latest
# Gunakan registry resmi GitHub Container Registry (GHCR).
# =========================================================
MARZBAN_IMAGE="ghcr.io/gozargah/marzban:latest"

# Paksa service marzban memakai image resmi GHCR.
# Tidak mengubah image nginx.
if grep -qE '^[[:space:]]+marzban:[[:space:]]*$' /opt/marzban/docker-compose.yml; then
    sed -i -E '/^[[:space:]]+marzban:[[:space:]]*$/,/^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ {
        /^[[:space:]]+image:[[:space:]]*/ s#^[[:space:]]*image:[[:space:]]*.*#    image: ghcr.io/gozargah/marzban:latest#
    }' /opt/marzban/docker-compose.yml
fi

# Pastikan service marzban benar-benar mempunyai image GHCR.
if ! grep -qE '^[[:space:]]+image:[[:space:]]*ghcr\.io/gozargah/marzban:latest[[:space:]]*$' /opt/marzban/docker-compose.yml; then
    colorized_echo red "Image Marzban GHCR tidak berhasil diterapkan ke docker-compose.yml."
    return 1
fi

colorized_echo cyan "Image Marzban: ${MARZBAN_IMAGE}"

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

# Download image resmi GHCR sebelum migration.
# Pull langsung juga memastikan masalah registry terlihat jelas di log.
if ! docker pull "${MARZBAN_IMAGE}" >> /var/log/marzban-bootstrap.log 2>&1; then
    colorized_echo red "Gagal mengambil image Marzban dari GHCR."
    colorized_echo yellow "Image: ${MARZBAN_IMAGE}"
    colorized_echo yellow "Log: /var/log/marzban-bootstrap.log"
    return 1
fi

# Sinkronkan image Compose setelah pull berhasil.
$COMPOSE_CMD pull marzban >> /var/log/marzban-bootstrap.log 2>&1 || {
    colorized_echo red "Docker Compose gagal menyiapkan image Marzban."
    return 1
}

# Verifikasi image benar-benar tersedia secara lokal.
if ! docker image inspect "${MARZBAN_IMAGE}" >/dev/null 2>&1; then
    colorized_echo red "Image Marzban tidak tersedia setelah pull."
    return 1
fi

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

# Import admin setelah migration, bukan sebelumnya.
if command -v marzban >/dev/null 2>&1; then
    marzban cli admin import-from-env -y || {
        colorized_echo red "Import admin gagal."
        $COMPOSE_CMD logs --tail=80 marzban || true
        return 1
    }
fi

# Hapus kredensial sementara dari .env setelah admin berhasil dibuat.
sed -i "s/SUDO_USERNAME = \"${userpanel}\"/# SUDO_USERNAME = \"admin\"/" /opt/marzban/.env
sed -i "s/SUDO_PASSWORD = \"${passpanel}\"/# SUDO_PASSWORD = \"admin\"/" /opt/marzban/.env

$COMPOSE_CMD up -d --remove-orphans
cd
echo "Tunggu 30 detik untuk generate token API"
sleep 30s

}


stage10() {
    set -e
#instal token
curl -X 'POST' \
  "https://${domain}:${port}/api/admin/token" \
  -H 'accept: application/json' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=${userpanel}&password=${passpanel}&scope=&client_id=&client_secret=" > /etc/data/token.json
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
# Install script dipertahankan agar --resume tetap tersedia.
marzban cli admin delete -u admin -y || log "WARN: cleanup admin dilewati (exit=$?)"
}




run_stage 01 "Validasi OS + input konfigurasi" stage01
run_stage 02 "Persiapan VPS + paket" stage02
run_stage 03 "Bootstrap Marzban + Xray" stage03
run_stage 04 "Profile + VNStat + Speedtest + Gotop" stage04
run_stage 05 "Nginx + SSL + konfigurasi Xray" stage05
run_stage 06 "Menu + Tools Repository + BWBOT + cron" stage06
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

install_check_usage_bot() {
    local target="/usr/local/bin/usage.py"
    local service="/etc/systemd/system/check-usage.service"

    if [ ! -f "$target" ]; then
        colorized_echo yellow "[!] $target tidak ditemukan. BOT Check Usage dilewati."
        return 0
    fi

    chmod 755 "$target"

    # Pastikan tidak ada service lama yang menjalankan instance kedua.
    systemctl disable --now bot-usage.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/bot-usage.service
    rm -f /usr/local/bin/bot-usage-env

    cat > "$service" <<'CHECK_USAGE_SERVICE_EOF'
[Unit]
Description=Telegram Check Usage Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=/opt/bot-usage-venv/bin/python /usr/local/bin/usage.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
CHECK_USAGE_SERVICE_EOF

    chmod 644 "$service"
    systemctl daemon-reload
    systemctl reset-failed check-usage.service >/dev/null 2>&1 || true
    systemctl enable check-usage.service >/dev/null 2>&1 || true
    systemctl restart check-usage.service
    sleep 2

    if systemctl is-active --quiet check-usage.service; then
        colorized_echo green "[✓] BOT Check Usage aktif."
    else
        colorized_echo yellow "[!] BOT Check Usage gagal aktif."
        echo "    Cek: journalctl -u check-usage.service -n 50 --no-pager"
    fi
}


# Aktifkan BOT Check Usage sebelum installer menawarkan reboot.
install_check_usage_bot

colorized_echo green "╔════════════════════════════════════════════════════╗"
colorized_echo green "║       LINGVPN MARZBAN INSTALLATION SELESAI       ║"
colorized_echo green "╚════════════════════════════════════════════════════╝"
log "INSTALLATION COMPLETE"
echo
echo "Telegram Check Usage: /cek_usage"
echo "Service: check-usage.service"
echo
read -rp "Reboot sekarang? [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then reboot; fi