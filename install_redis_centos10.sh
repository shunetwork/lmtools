#!/usr/bin/env bash
set -euo pipefail

# 安装并配置 Redis（适用于 CentOS Stream 10）
# 以 root 运行：sudo bash install_redis_centos10.sh

REDIS_VERSION="7.2.6"
PREFIX_REDIS="/usr/local/redis"
BUILD_DIR="/usr/local/src/build_redis"
PARALLEL_MAKE="$(nproc 2>/dev/null || echo 1)"
REDIS_PORT=6379
REDIS_BIND="127.0.0.1"
MODIFY_SECURITY=true
REQUIREPASS=""

usage(){
  cat <<EOF
Usage: $0 [--version VER] [--prefix PATH] [--build-dir PATH] [--jobs N] [--no-modify-security] [--requirepass PASS] [--port N] [--bind ADDR]

Options:
  --version       Redis 版本（默认 ${REDIS_VERSION}）
  --prefix        安装前缀（默认 ${PREFIX_REDIS}）
  --build-dir     构建目录（默认 ${BUILD_DIR}）
  --jobs          make 并行数（默认 ${PARALLEL_MAKE}）
  --no-modify-security  不修改 firewall/SELinux 设置
  --requirepass   设置 Redis 访问密码（可选）
  --port          监听端口（默认 ${REDIS_PORT}）
  --bind          绑定地址（默认 ${REDIS_BIND}）
  -h, --help      显示本帮助
EOF
  exit 1
}

parse_args(){
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version) REDIS_VERSION="$2"; shift 2;;
      --prefix) PREFIX_REDIS="$2"; shift 2;;
      --build-dir) BUILD_DIR="$2"; shift 2;;
      --jobs) PARALLEL_MAKE="$2"; shift 2;;
      --no-modify-security) MODIFY_SECURITY=false; shift 1;;
      --requirepass) REQUIREPASS="$2"; shift 2;;
      --port) REDIS_PORT="$2"; shift 2;;
      --bind) REDIS_BIND="$2"; shift 2;;
      -h|--help) usage;;
      *) echo "Unknown arg: $1"; usage;;
    esac
  done
}

# Interactive helper: 安全进入第一个匹配目录（在交互式 shell 中使用）
# 用法示例：在当前 shell 运行 `cdf redis*`，会进入第一个匹配的目录
cdf(){
  matches=("$@")
  if [ ${#matches[@]} -eq 0 ]; then
    echo "cdf: 没有匹配项"
    return 1
  fi
  cd -- "${matches[0]}"
}

check_root(){
  if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 运行本脚本。"
    exit 1
  fi
}

install_build_deps(){
  dnf -y makecache || true
  dnf -y install epel-release || true
  dnf -y install gcc make jemalloc-devel tcl wget curl tar xz || true
}

create_user_and_dirs(){
  if ! getent group redis >/dev/null 2>&1; then
    groupadd -r redis
  fi
  if ! id -u redis >/dev/null 2>&1; then
    useradd -r -g redis -s /sbin/nologin -M redis
  fi

  mkdir -p /etc/redis
  mkdir -p /var/lib/redis
  mkdir -p /var/log/redis
  chown -R redis:redis /var/lib/redis /var/log/redis || true
}

download_and_build(){
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  local tarball="redis-${REDIS_VERSION}.tar.gz"
  local url="https://download.redis.io/releases/${tarball}"
  if [ ! -f "$tarball" ]; then
    echo "Downloading $url"
    if ! wget -c "$url"; then
      echo "下载失败: $url"; return 1
    fi
  fi
  tar xzf "$tarball"
  cd "redis-${REDIS_VERSION}"
  make -j"${PARALLEL_MAKE}"
  make install
}

install_config_and_systemd(){
  # 默认 redis-server 安装到 /usr/local/bin
  REDIS_SERVER_BIN="/usr/local/bin/redis-server"
  REDIS_CLI_BIN="/usr/local/bin/redis-cli"

  # 生成配置文件
  local conf="/etc/redis/redis.conf"
  if [ -f "redis.conf" ]; then
    cp redis.conf "$conf"
  fi
  # 如果 build dir 中没有可用配置，创建最小配置
  if [ ! -f "$conf" ]; then
    cat > "$conf" <<EOF
bind ${REDIS_BIND}
port ${REDIS_PORT}
dir /var/lib/redis
logfile /var/log/redis/redis.log
dbfilename dump.rdb
appendonly yes
appendfilename "appendonly.aof"
supervised systemd
daemonize no
pidfile /var/run/redis/redis.pid
EOF
  fi

  # 调整配置项
  sed -i "s/^supervised .*/supervised systemd/" "$conf" || true
  sed -i "s/^daemonize .*/daemonize no/" "$conf" || true
  sed -i "s#^dir .*#dir /var/lib/redis#" "$conf" || true
  sed -i "s#^logfile .*#logfile /var/log/redis/redis.log#" "$conf" || true
  # 绑定与端口
  if grep -q "^bind" "$conf" >/dev/null 2>&1; then
    sed -i "s/^bind.*/bind ${REDIS_BIND}/" "$conf" || true
  else
    echo "bind ${REDIS_BIND}" >> "$conf"
  fi
  if grep -q "^port" "$conf" >/dev/null 2>&1; then
    sed -i "s/^port .*/port ${REDIS_PORT}/" "$conf" || true
  else
    echo "port ${REDIS_PORT}" >> "$conf"
  fi

  if [ -n "${REQUIREPASS}" ]; then
    if grep -q "^# requirepass" "$conf" >/dev/null 2>&1; then
      sed -i "s/# requirepass .*/requirepass ${REQUIREPASS}/" "$conf" || true
    elif grep -q "^requirepass" "$conf" >/dev/null 2>&1; then
      sed -i "s/^requirepass .*/requirepass ${REQUIREPASS}/" "$conf" || true
    else
      echo "requirepass ${REQUIREPASS}" >> "$conf"
    fi
  fi

  # systemd unit
  cat > /etc/systemd/system/redis.service <<'UNIT'
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
User=redis
Group=redis
ExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf
ExecStop=/usr/local/bin/redis-cli shutdown
Restart=always
LimitNOFILE=10032

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now redis.service || true
}

adjust_firewall_selinux(){
  if [ "$MODIFY_SECURITY" = true ]; then
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port=${REDIS_PORT}/tcp || true
      firewall-cmd --reload || true
    fi
    if [ -f /etc/selinux/config ]; then
      echo "注意：脚本未修改 SELinux 状态，仅确保 firewall 如果可用已打开端口。"
    fi
  else
    echo "跳过防火墙/SELinux 修改（已请求）。"
  fi
}

verify(){
  echo "==> 验证服务状态"
  systemctl status redis --no-pager || true
  sleep 1
  if [ -x "/usr/local/bin/redis-cli" ]; then
    if [ -n "${REQUIREPASS}" ]; then
      /usr/local/bin/redis-cli -a "${REQUIREPASS}" -p ${REDIS_PORT} ping || true
    else
      /usr/local/bin/redis-cli -p ${REDIS_PORT} ping || true
    fi
  fi
}

main(){
  parse_args "$@"
  check_root
  install_build_deps
  create_user_and_dirs
  download_and_build
  install_config_and_systemd
  adjust_firewall_selinux
  verify
  echo "安装完成：redis ${REDIS_VERSION}（配置: /etc/redis/redis.conf）"
}

main "$@"
