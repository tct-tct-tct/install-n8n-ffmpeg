#!/bin/bash

echo "======================================================================"
echo "     Script cài đặt N8N + FFmpeg + SSL (Caddy)                         "
echo "======================================================================"

# --- Kiểm tra root ---
if [[ $EUID -ne 0 ]]; then
   echo "⚠️ Script này cần chạy với quyền root (sudo)."
   exit 1
fi

# --- Tham số mặc định ---
N8N_DIR="/home/n8n"
SKIP_DOCKER=false

# --- Hiển thị trợ giúp ---
show_help() {
    echo "Cách sử dụng: $0 [tùy chọn]"
    echo "Tùy chọn:"
    echo "  -h, --help             Hiển thị trợ giúp"
    echo "  -d, --dir DIR          Thư mục cài đặt n8n (mặc định: /home/n8n)"
    echo "  -s, --skip-docker      Bỏ qua cài đặt Docker (nếu đã có)"
    exit 0
}

# --- Xử lý tham số ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        -d|--dir)  N8N_DIR="$2"; shift 2 ;;
        -s|--skip-docker) SKIP_DOCKER=true; shift ;;
        *) echo "Tùy chọn không hợp lệ: $1"; show_help ;;
    esac
done

# --- Cài đặt các công cụ cơ bản ---
apt-get update && apt-get install -y dnsutils curl cron unzip zip

# --- Đảm bảo cron chạy ---
systemctl enable cron
systemctl start cron

# --- Nhập domain ---
read -p "Nhập tên miền hoặc subdomain của bạn: " DOMAIN
SERVER_IP=$(curl -s https://api.ipify.org)
DOMAIN_IP=$(dig +short $DOMAIN)
if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    echo "⚠️ Domain $DOMAIN chưa trỏ tới IP $SERVER_IP."
    echo "Vui lòng cập nhật DNS trước rồi chạy lại script."
    exit 1
fi

# --- Cài Docker/Docker Compose ---
if ! $SKIP_DOCKER; then
    echo "Cài đặt Docker..."
    apt-get install -y apt-transport-https ca-certificates software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    echo "Bỏ qua cài Docker theo yêu cầu."
fi

# --- Chuẩn bị thư mục ---
mkdir -p $N8N_DIR/files/temp

# --- Tạo Dockerfile ---
cat << 'EOF' > $N8N_DIR/Dockerfile
FROM n8nio/n8n:latest
USER root
RUN apk update && apk add --no-cache ffmpeg wget zip unzip
USER node
EOF

# --- Nhập thông tin proxy (nếu có) ---
read -p "Nhập Proxy HTTP (bỏ trống nếu không dùng): " HTTP_PROXY_INPUT
if [ -n "$HTTP_PROXY_INPUT" ]; then
    HTTPS_PROXY_INPUT=$HTTP_PROXY_INPUT
else
    HTTPS_PROXY_INPUT=""
fi

# --- Tạo docker-compose.yml ---
cat << EOF > $N8N_DIR/docker-compose.yml
version: "3.8"
services:
  n8n:
    build:
      context: .
      dockerfile: Dockerfile
    image: n8nio/n8n:latest
    restart: always
    ports:
      - "5678:5678"
    environment:
      N8N_HOST: ${DOMAIN}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      NODE_ENV: production
      WEBHOOK_URL: https://${DOMAIN}
      GENERIC_TIMEZONE: Asia/Ho_Chi_Minh
      N8N_DEFAULT_BINARY_DATA_MODE: filesystem
      N8N_BINARY_DATA_STORAGE: /files
      N8N_DEFAULT_BINARY_DATA_FILESYSTEM_DIRECTORY: /files
      N8N_DEFAULT_BINARY_DATA_TEMP_DIRECTORY: /files/temp
      NODE_FUNCTION_ALLOW_BUILTIN: child_process,path,fs,util,os
      N8N_EXECUTIONS_DATA_MAX_SIZE: 304857600
      PUPPETEER_SKIP_CHROMIUM_DOWNLOAD: "true"
      PUPPETEER_EXECUTABLE_PATH: /usr/bin/google-chrome
      N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE: "true"
      HTTP_PROXY: "${HTTP_PROXY_INPUT}"
      HTTPS_PROXY: "${HTTPS_PROXY_INPUT}"
      NO_PROXY: "localhost,127.0.0.1"
    volumes:
      - ${N8N_DIR}:/home/node/.n8n
      - ${N8N_DIR}/files:/files
    user: "1000:1000"

  caddy:
    image: caddy:2
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${N8N_DIR}/Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - n8n

volumes:
  caddy_data:
  caddy_config:
EOF

# --- Tạo Caddyfile ---
cat << EOF > $N8N_DIR/Caddyfile
${DOMAIN} {
    reverse_proxy n8n:5678
}
EOF

# --- Quyền ---
chown -R 1000:1000 $N8N_DIR
chmod -R 755 $N8N_DIR

# --- Khởi động ---
cd $N8N_DIR
if command -v docker-compose &> /dev/null; then
    docker-compose up -d
else
    docker compose up -d
fi

echo "======================================================================"
echo "N8n đã được cài đặt tại $N8N_DIR"
echo "Truy cập https://${DOMAIN} sau vài phút để kiểm tra SSL"
echo "HTTP Proxy: ${HTTP_PROXY_INPUT:-Không cấu hình}"
echo "======================================================================"
