#!/usr/bin/env bash
set -euo pipefail

# 用途：为已安装的 nginx 添加虚拟主机（支持可选自签名 SSL）
# 依赖：bash, openssl, mkdir, chown, sed, grep
# 默认 nginx 前缀：/usr/local/nginx（可用 --nginx-prefix 覆盖）

NGINX_PREFIX="/usr/local/nginx"
PHP_FPM="127.0.0.1:9000"
SSL=false
# 日志相关
ENABLE_LOGS=true
ACCESS_LOG=""
ERROR_LOG=""
RESTART_SERVICES=false

usage() {
  cat <<EOF
Usage: $0 --domain example.com [--root /var/www/example] [--php host:port|unix:/path] [--nginx-prefix /usr/local/nginx] [--ssl]

Options:
  --domain DOMAIN         必需，站点域名（用于配置文件名和 server_name）
  --root PATH             网站根目录（默认 /var/www/<domain>）
  --php ADDR              php-fpm 地址，格式为 host:port 或 unix:/path（默认 ${PHP_FPM}）
  --nginx-prefix PATH     nginx 安装前缀（默认 ${NGINX_PREFIX}）
  --ssl                   为站点生成自签名证书并启用 HTTPS
  --enable-logs           启用访问/错误日志（默认启用）
  --disable-logs          禁用日志文件生成
  --access-log PATH       自定义访问日志路径
  --error-log PATH        自定义错误日志路径
  短选项：-d --domain, -r --root, -p --php, -n --nginx-prefix, -s --ssl, -h --help
  --restart, -R           创建站点后重启 nginx 与 php-fpm（使用 systemctl）
  -h, --help              显示本帮助

示例：
  sudo bash $0 --domain example.com --root /var/www/example --php 127.0.0.1:9000
  sudo bash $0 --domain example.com --ssl
EOF
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --domain|-d) DOMAIN="${2:-}"; shift 2;;
      --root|-r) WWWROOT="${2:-}"; shift 2;;
      --php|-p) PHP_FPM="${2:-}"; shift 2;;
      --nginx-prefix|-n) NGINX_PREFIX="${2:-}"; shift 2;;
      --ssl|-s) SSL=true; shift 1;;
      --restart|-R) RESTART_SERVICES=true; shift 1;;
      --enable-logs) ENABLE_LOGS=true; shift 1;;
      --disable-logs) ENABLE_LOGS=false; shift 1;;
      --access-log) ACCESS_LOG="${2:-}"; shift 2;;
      --error-log) ERROR_LOG="${2:-}"; shift 2;;
      -h|--help) usage;;
      *) echo "Unknown arg: $1"; usage;;
    esac
  done
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户运行此脚本。"
    exit 1
  fi
}

create_site_conf() {
  local conf_dir="${NGINX_PREFIX}/conf/conf.d"
  mkdir -p "$conf_dir"

  local conf_file="$conf_dir/${DOMAIN}.conf"

  # 生成 nginx server 配置
  cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root ${WWWROOT};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /nginx_status {
      stub_status;
      allow 127.0.0.1;
      deny all;
    }

    location ~ \.php$ {
        include ${NGINX_PREFIX}/conf/fastcgi_params;
        fastcgi_pass ${PHP_FPM};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME ${WWWROOT}\$fastcgi_script_name;
    }
}
EOF

  if [ "$SSL" = true ]; then
    # 添加 HTTPS 虚拟主机块
    cert_dir="/etc/ssl/${DOMAIN}"
    mkdir -p "$cert_dir"
    crt="$cert_dir/${DOMAIN}.crt"
    key="$cert_dir/${DOMAIN}.key"
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
      echo "正在为 ${DOMAIN} 生成自签名证书..."
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -subj "/CN=${DOMAIN}" \
        -keyout "$key" -out "$crt" >/dev/null 2>&1 || true
    fi

    cat >> "$conf_file" <<EOF

server {
    listen 443 ssl;
    server_name ${DOMAIN};
    root ${WWWROOT};
    index index.php index.html index.htm;
    ssl_certificate ${crt};
    ssl_certificate_key ${key};

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /nginx_status {
      stub_status;
      allow 127.0.0.1;
      deny all;
    }

    location ~ \.php$ {
        include ${NGINX_PREFIX}/conf/fastcgi_params;
        fastcgi_pass ${PHP_FPM};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME ${WWWROOT}\$fastcgi_script_name;
    }
}
EOF
  fi

  echo "已创建站点配置：$conf_file"
}

reload_nginx() {
  if systemctl list-unit-files | grep -q '^nginx'; then
    systemctl reload nginx || ${NGINX_PREFIX}/sbin/nginx -s reload || true
  else
    ${NGINX_PREFIX}/sbin/nginx -s reload || true
  fi
}

main() {
  parse_args "$@"
  require_root

  if [ -z "${DOMAIN:-}" ]; then
    echo "错误：必须指定 --domain"
    usage
  fi

  WWWROOT="${WWWROOT:-/var/www/${DOMAIN}}"
  mkdir -p "$WWWROOT"
  chown -R www:www "$WWWROOT" 2>/dev/null || true

  # 创建示例 index.php
  if [ ! -f "$WWWROOT/index.php" ]; then
    cat > "$WWWROOT/index.php" <<'EOF'
<?php
phpinfo();
EOF
  fi

  # 生成配置并重载 nginx
  create_site_conf
  # 创建并设置日志文件（如果启用）
  if [ "$ENABLE_LOGS" = true ]; then
    LOGDIR="/var/log/nginx"
    mkdir -p "$LOGDIR"
    # 默认路径
    ACCESS_LOG="${ACCESS_LOG:-${LOGDIR}/${DOMAIN}.access.log}"
    ERROR_LOG="${ERROR_LOG:-${LOGDIR}/${DOMAIN}.error.log}"
    touch "$ACCESS_LOG" "$ERROR_LOG" 2>/dev/null || true
    chown www:www "$ACCESS_LOG" "$ERROR_LOG" 2>/dev/null || true
  fi
  # 测试 nginx 配置语法
  if [ -x "${NGINX_PREFIX}/sbin/nginx" ]; then
    ${NGINX_PREFIX}/sbin/nginx -t || { echo "nginx 配置语法错误，请检查"; exit 1; }
  fi

  reload_nginx
  if [ "$RESTART_SERVICES" = true ]; then
    restart_services
  fi
  echo "虚拟主机 ${DOMAIN} 已添加并尝试重载 nginx。访问 http://127.0.0.1/ 进行测试（或使用域名）。"
}

restart_services() {
  echo "==> 重启 nginx 与 php-fpm（尝试使用 systemctl）"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart nginx php-fpm || echo "systemctl 重启失败，请手动检查服务。"
  else
    # 尝试用 nginx 信号平滑重载，php-fpm 请手动重启
    if [ -x "${NGINX_PREFIX}/sbin/nginx" ]; then
      ${NGINX_PREFIX}/sbin/nginx -s reload || echo "nginx reload 失败，请手动重启 nginx。"
    fi
    echo "未检测到 systemd，php-fpm 需要手动重启（例如：pkill -f php-fpm; /path/to/php-fpm --daemonize）。"
  fi
}

main "$@"
