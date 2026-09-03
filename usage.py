import sqlite3
import json
import os
import sys
from telegram import Update
from telegram.ext import CommandHandler, CallbackContext, Updater
from datetime import datetime

# Path ke file konfigurasi baru
config_file = 'bot_usage.json'

# Warna untuk output di terminal
CYAN = '\033[96m'
RESET = '\033[0m'

# Fungsi untuk menyimpan konfigurasi
def save_config(api_token, chat_id):
    config = {
        'API_TOKEN': api_token,
        'CHAT_ID': chat_id
    }
    with open(config_file, 'w') as f:
        json.dump(config, f)

# Fungsi untuk memuat konfigurasi
def load_config():
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            try:
                return json.load(f)
            except json.JSONDecodeError:
                print("File konfigurasi kosong atau tidak valid.")
    return None

# Fungsi untuk mengonversi traffic ke MB, GB, atau TB
def format_traffic(traffic_bytes):
    if traffic_bytes < (1024 ** 3):
        return f"{traffic_bytes / (1024 ** 2):.2f} MB"
    elif traffic_bytes < (1024 ** 4):
        return f"{traffic_bytes / (1024 ** 3):.2f} GB"
    else:
        return f"{traffic_bytes / (1024 ** 4):.2f} TB"

# Fungsi untuk mengonversi timestamp expire ke format tanggal
def format_expire_date(expire_timestamp):
    if expire_timestamp:
        return datetime.fromtimestamp(expire_timestamp).strftime('%Y-%m-%d')
    return "No Expiration"

# Fungsi untuk mengambil data dari SQLite
# /cek_usage          -> semua user
# /cek_usage Faiq     -> hanya user Faiq
def get_usage_from_db(username=None):
    db_path = '/var/lib/marzban/db.sqlite3'
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    if username:
        # Exact username match, tidak membedakan huruf besar/kecil.
        cursor.execute(
            "SELECT username, used_traffic, status, data_limit, expire "
            "FROM users WHERE username = ? COLLATE NOCASE LIMIT 1",
            (username.strip(),)
        )
    else:
        cursor.execute(
            "SELECT username, used_traffic, status, data_limit, expire FROM users"
        )

    users = cursor.fetchall()
    conn.close()

    if username and not users:
        return f"❌ *Username* : `{username}` tidak ditemukan."

    usage_text = ""

    for user, traffic, status, data_limit, expire in users:
        formatted_traffic = format_traffic(int(traffic or 0))

        if data_limit is None:
            data_limit_text = "Unlimited"
        else:
            data_limit_text = (
                "Unlimited" if data_limit == -1
                else format_traffic(int(data_limit))
            )

        expire_text = format_expire_date(expire)

        usage_text += f"👤 *Username* : `{user}`\n"
        usage_text += f"📊 *Used Traffic* : `{formatted_traffic}`\n"
        usage_text += f"📋 *Status* : `{status}`\n"
        usage_text += f"🔐 *Data Limit* : `{data_limit_text}`\n"
        usage_text += f"⏳ *Expires At* : `{expire_text}`\n\n"

    return usage_text

# Telegram membatasi panjang satu pesan. Jika /cek_usage tanpa username
# menghasilkan daftar sangat panjang, kirim dalam beberapa pesan.
def send_usage_text(update: Update, usage_text):
    max_length = 4000

    if len(usage_text) <= max_length:
        update.message.reply_text(usage_text, parse_mode='Markdown')
        return

    chunks = []
    current = ""

    for block in usage_text.split("\n\n"):
        block = block.strip()
        if not block:
            continue

        candidate = block if not current else current + "\n\n" + block

        if len(candidate) <= max_length:
            current = candidate
        else:
            if current:
                chunks.append(current)
            current = block

    if current:
        chunks.append(current)

    for chunk in chunks:
        update.message.reply_text(chunk, parse_mode='Markdown')

# Fungsi handler bot untuk command /cek_usage
def cek_usage_command(update: Update, context: CallbackContext):
    username = " ".join(context.args).strip() if context.args else None
    usage_text = get_usage_from_db(username)
    send_usage_text(update, usage_text)

# Main function untuk menjalankan bot
def main():
    config = load_config()
    
    if config is None:
        # Meminta input dari pengguna untuk API token dan Chat ID
        api_token = input("Masukkan API Bot Telegram: ")
        chat_id = input("Masukkan Chat ID Telegram: ")
        
        # Menyimpan konfigurasi ke file
        save_config(api_token, chat_id)
        
        print("Konfigurasi telah disimpan.")
        
        # Menggunakan nohup untuk menjalankan script
        print(f"{CYAN}Script running.. silahkan close terminal udah auto running\nketik /cek_usage di dalam bot !{RESET}")
        os.execvp("nohup", ["nohup", sys.executable, __file__, "&"])

        return  # Menghentikan eksekusi script setelah memulai nohup

    # Pastikan API_TOKEN dan CHAT_ID ada
    api_token = config.get('API_TOKEN')
    chat_id = config.get('CHAT_ID')

    if not api_token or not chat_id:
        print("API_TOKEN atau CHAT_ID tidak ditemukan dalam konfigurasi.")
        return

    # Inisialisasi Updater dan Dispatcher
    updater = Updater(api_token)
    dp = updater.dispatcher

    # Command /cek_usage
    dp.add_handler(CommandHandler("cek_usage", cek_usage_command))

    # Mulai bot
    updater.start_polling()
    updater.idle()

if __name__ == '__main__':
    main()
