#!/usr/bin/env bash
set -euo pipefail

# optimize_nginx.sh - 根据硬件配置优化 Nginx 配置
# 用途: 自动检测 CPU 核心数、内存大小、磁盘类型等硬件信息，
#       生成最优的 nginx.conf 配置参数。
# 支持通过 --prefix-nginx 覆盖安装前缀

PREFIX_NGINX=/usr/local/nginx
BACKUP_DIR="${PREFIX_NGINX}/conf/backup"
DRY_RUN=false
FORCE=false
SHOW_ONLY=false
VERBOSE=false
APPLY_SYSCTL=false

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
debug() { $VERBOSE && echo -e "${BLUE}[DEBUG]${NC} $*" || true; }
title() { echo -e "\n${CYAN}==== $* ====${NC}"; }
ok()    { echo -e "  ${GREEN}✅${NC} $*"; }
fail()  { echo -e "  ${RED}❌${NC} $*"; }
skip()  { echo -e "  ${YELLOW}⚠️${NC} $*"; }

usage() {
  cat <<EOF
用法: $0 [OPTIONS]

选项:
  --prefix-nginx PATH   Nginx 安装前缀（默认: ${PREFIX_NGINX}）
  --dry-run             仅预览优化结果，不写入文件
  --show-only           仅显示当前硬件信息和推荐配置，不写入文件
  --force               跳过确认提示，直接应用优化
  --apply-sysctl        同时应用系统内核参数优化（sysctl）
  --verbose             输出详细调试信息
  -h, --help            显示本帮助

示例:
  $0                                    # 交互式优化
  $0 --dry-run                          # 预览优化结果
  $0 --show-only                        # 仅显示推荐配置
  $0 --force                            # 直接应用优化（无确认）
  $0 --force --apply-sysctl             # 直接应用 Nginx + 系统参数优化
  $0 --prefix-nginx /opt/nginx --force  # 指定路径并直接应用

说明:
  该工具会根据当前服务器的硬件配置自动计算最优的 Nginx 参数：
  - worker_processes: 根据 CPU 核心数
  - worker_connections: 根据内存和系统限制
  - 事件模型: 自动选择 epoll/kqueue
  - 缓冲区优化: 根据内存大小调整
  - 超时设置: 根据内存和典型场景
  - 静态文件缓存: 根据内存大小
  - Gzip/SSL 优化: 根据 CPU 核心数
  - 系统参数优化: 自动应用内核参数优化（使用 --apply-sysctl）
  - ulimit 优化: 自动调整文件描述符限制
  - THP 优化: 自动检测并建议关闭透明大页

EOF
}

parse_flags() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --prefix-nginx) PREFIX_NGINX="$2"; shift 2;;
      --dry-run)      DRY_RUN=true; shift;;
      --show-only)    SHOW_ONLY=true; shift;;
      --force)        FORCE=true; shift;;
      --apply-sysctl) APPLY_SYSCTL=true; shift;;
      --verbose)      VERBOSE=true; shift;;
      -h|--help)      usage; exit 0;;
      *) echo "未知选项: $1"; usage; exit 1;;
    esac
  done
}

# ============================================================
# 硬件检测模块
# ============================================================

detect_cpu() {
  title "CPU 信息检测"

  # CPU 核心数（物理核心）
  local cpu_cores
  if [ -f /proc/cpuinfo ]; then
    cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
  else
    # macOS/BSD
    cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "1")
  fi
  echo "  CPU 核心数: ${cpu_cores}"

  # CPU 型号
  local cpu_model=""
  if [ -f /proc/cpuinfo ]; then
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[ \t]*//' || echo "未知")
  else
    cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "未知")
  fi
  echo "  CPU 型号: ${cpu_model}"

  # CPU 架构
  local cpu_arch
  cpu_arch=$(uname -m 2>/dev/null || echo "未知")
  echo "  CPU 架构: ${cpu_arch}"

  # 建议 worker_processes
  # 规则: 对于 I/O 密集型（Nginx 典型场景），建议设为 CPU 核心数
  #       对于 CPU 密集型（SSL 终结、压缩），建议设为核心数的 1-2 倍
  local worker_proc_io=$cpu_cores
  local worker_proc_cpu=$(( cpu_cores * 2 ))

  echo ""
  echo "  📊 推荐 worker_processes:"
  echo "     - I/O 密集型（反向代理、静态文件）: ${worker_proc_io}"
  echo "     - CPU 密集型（SSL 终结、Gzip 压缩）: ${worker_proc_cpu}"
  echo "     - 自动模式（auto）: Nginx 自动检测"

  CPU_CORES=$cpu_cores
  WORKER_PROC_IO=$worker_proc_io
  WORKER_PROC_CPU=$worker_proc_cpu
}

detect_memory() {
  title "内存信息检测"

  local mem_total_kb=0
  local mem_total_mb=0
  local mem_total_gb=0
  local swap_total_mb=0

  if [ -f /proc/meminfo ]; then
    mem_total_kb=$(grep "^MemTotal" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    mem_total_mb=$(( mem_total_kb / 1024 ))
    mem_total_gb=$(( mem_total_mb / 1024 ))

    local swap_total_kb
    swap_total_kb=$(grep "^SwapTotal" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    swap_total_mb=$(( swap_total_kb / 1024 ))
  else
    # macOS/BSD
    mem_total_mb=$(($(sysctl -n hw.memsize 2>/dev/null || echo "1073741824") / 1024 / 1024))
    mem_total_gb=$(( mem_total_mb / 1024 ))
  fi

  echo "  总内存: ${mem_total_mb}MB (${mem_total_gb}GB)"
  echo "  Swap: ${swap_total_mb}MB"

  # 根据内存大小推荐配置
  # worker_connections 计算公式:
  #   每个 worker 连接大约消耗 0.5MB-2MB 内存（取决于使用场景）
  #   保守估计: 可用内存的 10% 用于 Nginx 连接
  local conn_mem_mb=$(( mem_total_mb / 10 ))  # 分配给 Nginx 连接的内存 (10%)
  local conn_per_worker=$(( conn_mem_mb / CPU_CORES * 512 ))  # 每个连接约 512KB
  # 限制范围: 512 - 65535
  if [ "$conn_per_worker" -lt 512 ]; then
    conn_per_worker=512
  elif [ "$conn_per_worker" -gt 65535 ]; then
    conn_per_worker=65535
  fi

  # 根据内存大小分档推荐
  local worker_conn_rec=1024
  local sendfile_max_chunk="512k"
  local proxy_buffers="8 8k"
  local fastcgi_buffers="8 8k"
  local client_body_buffer_size="128k"
  local client_max_body_size="20m"
  local open_file_cache="max=1000 inactive=20s"
  local keepalive_timeout=65
  local keepalive_requests=1000

  if [ "$mem_total_gb" -ge 64 ]; then
    worker_conn_rec=65535
    sendfile_max_chunk="2m"
    proxy_buffers="256 16k"
    fastcgi_buffers="256 16k"
    client_body_buffer_size="1m"
    client_max_body_size="100m"
    open_file_cache="max=10000 inactive=20s"
    keepalive_timeout=120
    keepalive_requests=10000
  elif [ "$mem_total_gb" -ge 32 ]; then
    worker_conn_rec=32768
    sendfile_max_chunk="1m"
    proxy_buffers="128 16k"
    fastcgi_buffers="128 16k"
    client_body_buffer_size="512k"
    client_max_body_size="50m"
    open_file_cache="max=5000 inactive=20s"
    keepalive_timeout=90
    keepalive_requests=5000
  elif [ "$mem_total_gb" -ge 16 ]; then
    worker_conn_rec=16384
    sendfile_max_chunk="1m"
    proxy_buffers="64 16k"
    fastcgi_buffers="64 16k"
    client_body_buffer_size="256k"
    client_max_body_size="30m"
    open_file_cache="max=3000 inactive=20s"
    keepalive_timeout=75
    keepalive_requests=3000
  elif [ "$mem_total_gb" -ge 8 ]; then
    worker_conn_rec=8192
    sendfile_max_chunk="512k"
    proxy_buffers="32 8k"
    fastcgi_buffers="32 8k"
    client_body_buffer_size="128k"
    client_max_body_size="20m"
    open_file_cache="max=2000 inactive=20s"
    keepalive_timeout=65
    keepalive_requests=2000
  elif [ "$mem_total_gb" -ge 4 ]; then
    worker_conn_rec=4096
    sendfile_max_chunk="256k"
    proxy_buffers="16 8k"
    fastcgi_buffers="16 8k"
    client_body_buffer_size="64k"
    client_max_body_size="10m"
    open_file_cache="max=1000 inactive=20s"
    keepalive_timeout=65
    keepalive_requests=1000
  elif [ "$mem_total_gb" -ge 2 ]; then
    worker_conn_rec=2048
    sendfile_max_chunk="128k"
    proxy_buffers="8 8k"
    fastcgi_buffers="8 8k"
    client_body_buffer_size="32k"
    client_max_body_size="5m"
    open_file_cache="max=500 inactive=20s"
    keepalive_timeout=60
    keepalive_requests=500
  else
    worker_conn_rec=1024
    sendfile_max_chunk="64k"
    proxy_buffers="4 8k"
    fastcgi_buffers="4 8k"
    client_body_buffer_size="16k"
    client_max_body_size="2m"
    open_file_cache="max=200 inactive=20s"
    keepalive_timeout=30
    keepalive_requests=200
  fi

  # 如果用户设置的连接数超过系统限制，进行调整
  local ulimit_n
  ulimit_n=$(ulimit -n 2>/dev/null || echo "1024")
  local max_conn_sys=$(( ulimit_n / CPU_CORES ))
  if [ "$worker_conn_rec" -gt "$max_conn_sys" ] && [ "$max_conn_sys" -gt 0 ]; then
    warn "worker_connections ${worker_conn_rec} 超过系统限制 (ulimit -n: ${ulimit_n}, 每进程约 ${max_conn_sys})"
    worker_conn_rec=$max_conn_sys
    info "已将 worker_connections 调整为 ${worker_conn_rec}"
  fi

  MEM_TOTAL_MB=$mem_total_mb
  MEM_TOTAL_GB=$mem_total_gb
  SWAP_TOTAL_MB=$swap_total_mb
  WORKER_CONN=$worker_conn_rec
  SENDFILE_MAX_CHUNK=$sendfile_max_chunk
  PROXY_BUFFERS=$proxy_buffers
  FASTCGI_BUFFERS=$fastcgi_buffers
  CLIENT_BODY_BUFFER_SIZE=$client_body_buffer_size
  CLIENT_MAX_BODY_SIZE=$client_max_body_size
  OPEN_FILE_CACHE=$open_file_cache
  KEEPALIVE_TIMEOUT=$keepalive_timeout
  KEEPALIVE_REQUESTS=$keepalive_requests
}

detect_disk() {
  title "磁盘信息检测"

  # 检测是否为 SSD
  local is_ssd=false
  local disk_type="未知"

  # 尝试通过多种方式检测磁盘类型
  if [ -d /sys/block ]; then
    for disk in /sys/block/[a-z]*; do
      [ -d "$disk" ] || continue
      local dev
      dev=$(basename "$disk")
      # 跳过 loop、ram、dm 设备
      [[ "$dev" =~ ^(loop|ram|dm-) ]] && continue

      local rotational
      rotational=$(cat "$disk/queue/rotational" 2>/dev/null || echo "1")
      if [ "$rotational" = "0" ]; then
        is_ssd=true
        disk_type="SSD/NVMe"
        debug "  设备 ${dev}: SSD/NVMe"
      else
        debug "  设备 ${dev}: HDD"
        [ "$disk_type" = "未知" ] && disk_type="HDD"
      fi
    done
  fi

  # 如果检测到至少一个 SSD，则认为是 SSD
  if $is_ssd; then
    disk_type="SSD/NVMe"
  fi

  echo "  磁盘类型: ${disk_type}"

  # 根据磁盘类型调整参数
  local aio="off"
  local directio="off"
  local output_buffers="128 8k"

  if $is_ssd; then
    # SSD: 可以启用 AIO，更大的输出缓冲区
    aio="on"
    directio="512k"
    output_buffers="256 8k"
    echo "  ✅ SSD 检测: 启用 AIO，优化 I/O 性能"
  else
    echo "  ⚠️  HDD 检测: 禁用 AIO，使用传统 I/O 模式"
  fi

  DISK_TYPE=$disk_type
  AIO=$aio
  DIRECTIO=$directio
  OUTPUT_BUFFERS=$output_buffers
}

detect_network() {
  title "网络信息检测"

  # 获取默认路由接口
  local default_iface=""
  default_iface=$(ip route 2>/dev/null | grep "^default" | awk '{print $5}' | head -1 || echo "")

  if [ -z "$default_iface" ]; then
    default_iface=$(route -n 2>/dev/null | grep "^0.0.0.0" | awk '{print $8}' | head -1 || echo "未知")
  fi

  echo "  默认网卡: ${default_iface}"

  # 获取 TCP 缓冲区大小
  local tcp_rmem=""
  local tcp_wmem=""
  if [ -f /proc/sys/net/ipv4/tcp_rmem ]; then
    tcp_rmem=$(cat /proc/sys/net/ipv4/tcp_rmem 2>/dev/null || echo "未知")
    tcp_wmem=$(cat /proc/sys/net/ipv4/tcp_wmem 2>/dev/null || echo "未知")
  fi

  if [ -n "$tcp_rmem" ]; then
    echo "  TCP 接收缓冲区: ${tcp_rmem}"
    echo "  TCP 发送缓冲区: ${tcp_wmem}"
  fi

  # 获取 somaxconn
  local somaxconn=""
  somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo "未知")
  echo "  net.core.somaxconn: ${somaxconn}"

  # 根据内存大小推荐网络参数
  local proxy_connect_timeout=60
  local proxy_send_timeout=60
  local proxy_read_timeout=60

  if [ "$MEM_TOTAL_GB" -ge 16 ]; then
    proxy_connect_timeout=30
    proxy_send_timeout=30
    proxy_read_timeout=30
  elif [ "$MEM_TOTAL_GB" -ge 4 ]; then
    proxy_connect_timeout=60
    proxy_send_timeout=60
    proxy_read_timeout=60
  else
    proxy_connect_timeout=75
    proxy_send_timeout=75
    proxy_read_timeout=75
  fi

  PROXY_CONNECT_TIMEOUT=$proxy_connect_timeout
  PROXY_SEND_TIMEOUT=$proxy_send_timeout
  PROXY_READ_TIMEOUT=$proxy_read_timeout
}

detect_os() {
  title "操作系统信息"

  local os=""
  local os_ver=""

  if [ -f /etc/os-release ]; then
    os=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    os_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
  elif [ -f /etc/redhat-release ]; then
    os="rhel"
    os_ver=$(cat /etc/redhat-release)
  elif command -v sw_vers >/dev/null 2>&1; then
    os="macos"
    os_ver=$(sw_vers -productVersion 2>/dev/null || echo "未知")
  else
    os=$(uname -s 2>/dev/null || echo "未知")
    os_ver=$(uname -r 2>/dev/null || echo "未知")
  fi

  echo "  操作系统: ${os} ${os_ver}"
  echo "  内核版本: $(uname -r 2>/dev/null || echo '未知')"

  OS_TYPE=$os
  OS_VERSION=$os_ver
}

detect_nginx() {
  title "Nginx 当前状态"

  local nginx_bin="${PREFIX_NGINX}/sbin/nginx"
  local nginx_conf="${PREFIX_NGINX}/conf/nginx.conf"

  if [ -x "$nginx_bin" ]; then
    local nginx_ver
    nginx_ver=$("$nginx_bin" -v 2>&1 | awk '{print $3}' | sed 's/nginx\///' || echo "未知")
    echo "  Nginx 版本: ${nginx_ver}"
    echo "  安装路径: ${PREFIX_NGINX}"
    echo "  配置文件: ${nginx_conf}"

    # 检查当前配置
    if [ -f "$nginx_conf" ]; then
      local current_workers
      current_workers=$(grep -E "^\s*worker_processes" "$nginx_conf" 2>/dev/null | awk '{print $2}' | tr -d ';' || echo "未知")
      local current_connections
      current_connections=$(grep -E "^\s*worker_connections" "$nginx_conf" 2>/dev/null | awk '{print $2}' | tr -d ';' || echo "未知")
      echo "  当前 worker_processes: ${current_workers}"
      echo "  当前 worker_connections: ${current_connections}"
    fi

    NGINX_INSTALLED=true
    NGINX_CONF=$nginx_conf
  else
    echo "  Nginx 未安装或未在 ${PREFIX_NGINX} 找到"
    NGINX_INSTALLED=false
    NGINX_CONF="${PREFIX_NGINX}/conf/nginx.conf"
  fi
}

# ============================================================
# 配置生成模块
# ============================================================

generate_nginx_conf() {
  title "生成优化配置"

  # 选择 worker_processes 值
  # 默认使用 I/O 密集型配置（CPU 核心数）
  local worker_proc=$WORKER_PROC_IO

  # 事件模型选择
  local event_model="epoll"
  case "$OS_TYPE" in
    macos|darwin) event_model="kqueue" ;;
    freebsd)      event_model="kqueue" ;;
    linux)        event_model="epoll" ;;
  esac

  # 是否启用多接受
  local multi_accept="on"
  # 如果连接数较大，启用 multi_accept 提高吞吐量
  [ "$WORKER_CONN" -ge 16384 ] && multi_accept="on" || multi_accept="on"

  # 是否启用 accept_mutex
  local accept_mutex="on"
  # 对于 epoll，accept_mutex 默认关闭（Linux 3.9+ 已修复 thundering herd）
  if [ "$event_model" = "epoll" ]; then
    accept_mutex="off"
  fi

  # Gzip 配置
  local gzip="on"
  local gzip_min_length=1000
  local gzip_comp_level=2
  local gzip_types="text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml"

  # 如果 CPU 核心数较多，可以提高压缩级别
  if [ "$CPU_CORES" -ge 8 ]; then
    gzip_comp_level=3
  elif [ "$CPU_CORES" -ge 4 ]; then
    gzip_comp_level=2
  else
    gzip_comp_level=1
  fi

  # SSL 配置（如果内存充足）
  local ssl_session_cache="shared:SSL:10m"
  local ssl_session_timeout="10m"
  if [ "$MEM_TOTAL_GB" -ge 8 ]; then
    ssl_session_cache="shared:SSL:50m"
    ssl_session_timeout="30m"
  elif [ "$MEM_TOTAL_GB" -ge 4 ]; then
    ssl_session_cache="shared:SSL:20m"
    ssl_session_timeout="10m"
  fi

  # 日志配置
  local log_format='main  $remote_addr - $remote_user [$time_local] "$request" '
  log_format+='$status $body_bytes_sent "$http_referer" '
  log_format+='"$http_user_agent" "$http_x_forwarded_for"'
  log_format+=' $request_time $upstream_response_time'

  # 构建配置内容
  cat > /tmp/nginx_optimized.conf << NGINX_CONF_EOF

# ============================================================
# 优化后的 Nginx 主配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 生成工具: optimize_nginx.sh
# 硬件信息:
#   CPU: ${CPU_CORES} 核心
#   内存: ${MEM_TOTAL_MB}MB (${MEM_TOTAL_GB}GB)
#   磁盘: ${DISK_TYPE}
#   系统: ${OS_TYPE} ${OS_VERSION}
# ============================================================

# ---- 用户 ----
#user  nobody;

# ---- 工作进程 ----
# 根据 CPU 核心数自动优化
# I/O 密集型场景（反向代理、静态文件）: ${WORKER_PROC_IO}
# CPU 密集型场景（SSL 终结、Gzip）: ${WORKER_PROC_CPU}
worker_processes  ${worker_proc};

# 绑定 worker 到指定 CPU 核心（避免上下文切换）
# 仅在 worker_processes 等于 CPU 核心数时启用
#worker_cpu_affinity auto;

# 错误日志
#error_log  logs/error.log;
#error_log  logs/error.log  notice;
#error_log  logs/error.log  info;

# PID 文件
pid        logs/nginx.pid;

# ---- 事件模块 ----
events {
    # 事件模型（自动选择最优模型）
    # Linux: epoll, FreeBSD/macOS: kqueue
    use                 ${event_model};

    # 每个 worker 的最大连接数
    # 根据内存 ${MEM_TOTAL_GB}GB 优化
    worker_connections  ${WORKER_CONN};

    # 一次 accept 多个连接（提高吞吐量）
    multi_accept        ${multi_accept};

    # accept_mutex（epoll 下建议关闭）
    accept_mutex        ${accept_mutex};
}

# ---- HTTP 模块 ----
http {
    include       /usr/local/nginx/conf/conf.d/*.conf;
    include       mime.types;
    default_type  application/octet-stream;

    # ---- 日志格式 ----
    #log_format  main  '${log_format}';

    # 访问日志（建议生产环境开启）
    #access_log  logs/access.log  main;

    # ---- 基础优化 ----
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;

    # ---- 超时设置 ----
    keepalive_timeout   ${KEEPALIVE_TIMEOUT};
    keepalive_requests  ${KEEPALIVE_REQUESTS};
    client_body_timeout   10;
    client_header_timeout 10;
    send_timeout          10;

    # ---- 客户端请求体大小 ----
    client_body_buffer_size  ${CLIENT_BODY_BUFFER_SIZE};
    client_max_body_size     ${CLIENT_MAX_BODY_SIZE};

    # ---- 静态文件缓存 ----
    open_file_cache          ${OPEN_FILE_CACHE};
    open_file_cache_valid    30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors   on;

    # ---- sendfile 优化 ----
    sendfile_max_chunk  ${SENDFILE_MAX_CHUNK};

    # ---- 输出缓冲区 ----
    output_buffers    ${OUTPUT_BUFFERS};

    # ---- AIO（异步 I/O，仅 SSD 推荐） ----
    aio              ${AIO};
    directio         ${DIRECTIO};

    # ---- 代理优化 ----
    proxy_connect_timeout   ${PROXY_CONNECT_TIMEOUT}s;
    proxy_send_timeout      ${PROXY_SEND_TIMEOUT}s;
    proxy_read_timeout      ${PROXY_READ_TIMEOUT}s;

    proxy_buffering         on;
    proxy_buffer_size       4k;
    proxy_buffers           ${PROXY_BUFFERS};
    proxy_busy_buffers_size 16k;
    proxy_temp_file_write_size 16k;

    # ---- FastCGI 优化 ----
    fastcgi_connect_timeout 60s;
    fastcgi_send_timeout    60s;
    fastcgi_read_timeout    60s;

    fastcgi_buffering       on;
    fastcgi_buffer_size     4k;
    fastcgi_buffers         ${FASTCGI_BUFFERS};
    fastcgi_busy_buffers_size 16k;
    fastcgi_temp_file_write_size 16k;

    # ---- Gzip 压缩 ----
    gzip              ${gzip};
    gzip_min_length   ${gzip_min_length};
    gzip_comp_level   ${gzip_comp_level};
    gzip_vary         on;
    gzip_disable      "msie6";
    gzip_proxied      any;
    gzip_types        ${gzip_types};

    # ---- SSL 优化 ----
    ssl_session_cache    ${ssl_session_cache};
    ssl_session_timeout  ${ssl_session_timeout};
    ssl_session_tickets  off;

    # ---- 限制连接（防止资源耗尽） ----
    #limit_conn_zone \$binary_remote_addr zone=addr:10m;
    #limit_conn addr 100;

    # ---- 限制请求速率 ----
    #limit_req_zone \$binary_remote_addr zone=one:10m rate=10r/s;

    # ---- 服务器配置 ----
    #server {
    #    listen       80;
    #    server_name  localhost;
    #
    #    #charset koi8-r;
    #
    #    #access_log  logs/host.access.log  main;
    #
    #    location / {
    #        root   html;
    #        index  index.html index.htm;
    #    }
    #
    #    #error_page  404              /404.html;
    #
    #    # redirect server error pages to the static page /50x.html
    #    #
    #    error_page   500 502 503 504  /50x.html;
    #    location = /50x.html {
    #        root   html;
    #    }
    #
    #    # proxy the PHP scripts to Apache listening on 127.0.0.1:80
    #    #
    #    #location ~ \.php$ {
    #    #    proxy_pass   http://127.0.0.1;
    #    #}
    #
    #    # pass the PHP scripts to FastCGI server listening on 127.0.0.1:9000
    #    #
    #    #location ~ \.php$ {
    #    #    root           html;
    #    #    fastcgi_pass   127.0.0.1:9000;
    #    #    fastcgi_index  index.php;
    #    #    fastcgi_param  SCRIPT_FILENAME  /scripts\$fastcgi_script_name;
    #    #    include        fastcgi_params;
    #    #}
    #
    #    # deny access to .htaccess files, if Apache's document root
    #    # concurs with nginx's one
    #    #
    #    #location ~ /\.ht {
    #    #    deny  all;
    #    #}
    #}
}

NGINX_CONF_EOF

  echo "  ✅ 优化配置已生成到 /tmp/nginx_optimized.conf"
}

# ============================================================
# 系统参数建议模块
# ============================================================

generate_sysctl_advice() {
  title "系统参数优化建议"

  local advice_file="/tmp/nginx_sysctl_advice.txt"

  cat > "$advice_file" << 'SYSCTL_EOF'
# ============================================================
# Nginx 优化 - 系统内核参数建议
# 将以下内容添加到 /etc/sysctl.conf 并执行 sysctl -p
# ============================================================

# ---- 网络优化 ----

# 最大连接队列长度（默认 128，建议增大）
# net.core.somaxconn = 65535

# 网络设备接收数据包的队列长度
# net.core.netdev_max_backlog = 65535

# TCP 连接快速回收（已废弃，不建议使用）
# net.ipv4.tcp_tw_recycle = 0

# 允许 TIME_WAIT 状态的 socket 用于新连接
# net.ipv4.tcp_tw_reuse = 1

# 快速回收 TIME_WAIT 连接
# net.ipv4.tcp_fin_timeout = 15

# TCP 连接 keepalive 探测
# net.ipv4.tcp_keepalive_time = 300
# net.ipv4.tcp_keepalive_probes = 3
# net.ipv4.tcp_keepalive_intvl = 15

# TCP 缓冲区（根据内存大小调整）
# net.ipv4.tcp_rmem = 4096 87380 16777216
# net.ipv4.tcp_wmem = 4096 65536 16777216

# TCP 拥塞控制算法（BBR 推荐）
# net.core.default_qdisc = fq
# net.ipv4.tcp_congestion_control = bbr

# ---- 文件句柄限制 ----

# 系统级文件句柄限制
# fs.file-max = 1000000

# ---- 内存优化 ----

# 允许将 TIME_WAIT socket 用于新连接
# net.ipv4.tcp_max_tw_buckets = 2000000

# 最大孤儿 socket 数量
# net.ipv4.tcp_max_orphans = 3276800

# 最大 SYN 半连接队列
# net.ipv4.tcp_max_syn_backlog = 65535

# SYN Flood 防护
# net.ipv4.tcp_syncookies = 1

# ---- 端口范围 ----
# net.ipv4.ip_local_port_range = 1024 65535

SYSCTL_EOF

  # 根据内存大小调整建议值
  if [ "$MEM_TOTAL_GB" -ge 16 ]; then
    cat >> "$advice_file" << SYSCTL_LARGE
# ---- 大内存优化（${MEM_TOTAL_GB}GB） ----

# 增大网络缓冲区
# net.core.rmem_max = 16777216
# net.core.wmem_max = 16777216

# 增大连接队列
# net.core.somaxconn = 65535
# net.core.netdev_max_backlog = 65535

SYSCTL_LARGE
  elif [ "$MEM_TOTAL_GB" -ge 4 ]; then
    cat >> "$advice_file" << SYSCTL_MEDIUM
# ---- 中等内存优化（${MEM_TOTAL_GB}GB） ----

# 适度增大网络缓冲区
# net.core.rmem_max = 8388608
# net.core.wmem_max = 8388608

# 适度增大连接队列
# net.core.somaxconn = 16384
# net.core.netdev_max_backlog = 16384

SYSCTL_MEDIUM
  else
    cat >> "$advice_file" << SYSCTL_SMALL
# ---- 小内存优化（${MEM_TOTAL_GB}GB） ----

# 适度增大网络缓冲区
# net.core.rmem_max = 4194304
# net.core.wmem_max = 4194304

# 适度增大连接队列
# net.core.somaxconn = 8192
# net.core.netdev_max_backlog = 8192

SYSCTL_SMALL
  fi

  echo "  ✅ 系统参数建议已生成到 ${advice_file}"
  echo ""
  echo "  建议执行以下命令应用优化："
  echo "    # cat ${advice_file} >> /etc/sysctl.conf"
  echo "    # sysctl -p"
}

# ============================================================
# 显示优化摘要
# ============================================================

show_summary() {
  title "优化配置摘要"

  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │               Nginx 优化配置摘要                     │"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-25s %-30s │\n" "worker_processes" "${WORKER_PROC_IO}"
  printf "  │  %-25s %-30s │\n" "worker_connections" "${WORKER_CONN}"
  printf "  │  %-25s %-30s │\n" "事件模型" "${event_model:-epoll}"
  printf "  │  %-25s %-30s │\n" "磁盘类型" "${DISK_TYPE}"
  printf "  │  %-25s %-30s │\n" "内存" "${MEM_TOTAL_GB}GB"
  printf "  │  %-25s %-30s │\n" "CPU 核心" "${CPU_CORES}"
  printf "  │  %-25s %-30s │\n" "keepalive_timeout" "${KEEPALIVE_TIMEOUT}s"
  printf "  │  %-25s %-30s │\n" "keepalive_requests" "${KEEPALIVE_REQUESTS}"
  printf "  │  %-25s %-30s │\n" "client_max_body_size" "${CLIENT_MAX_BODY_SIZE}"
  printf "  │  %-25s %-30s │\n" "Gzip 压缩级别" "${gzip_comp_level:-2}"
  printf "  │  %-25s %-30s │\n" "SSL Session Cache" "${ssl_session_cache:-shared:SSL:10m}"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-25s %-30s │\n" "AIO (异步 I/O)" "${AIO:-off}"
  printf "  │  %-25s %-30s │\n" "Proxy Buffers" "${PROXY_BUFFERS}"
  printf "  │  %-25s %-30s │\n" "FastCGI Buffers" "${FASTCGI_BUFFERS}"
  echo "  └─────────────────────────────────────────────────────┘"
  echo ""
}

# ============================================================
# 应用优化模块
# ============================================================

apply_optimization() {
  title "应用优化配置"

  # 检查 Nginx 是否安装
  if ! $NGINX_INSTALLED; then
    warn "Nginx 未安装，仅生成配置文件到 ${NGINX_CONF}"
    # 确保目录存在
    local conf_dir
    conf_dir=$(dirname "$NGINX_CONF")
    mkdir -p "$conf_dir"
    cp /tmp/nginx_optimized.conf "$NGINX_CONF"
    info "配置文件已生成到 ${NGINX_CONF}"
    info "请安装 Nginx 后使用此配置"
    return
  fi

  # 备份原配置
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  local backup_file="${BACKUP_DIR}/nginx.conf.${timestamp}"

  mkdir -p "$BACKUP_DIR"

  if [ -f "$NGINX_CONF" ]; then
    cp "$NGINX_CONF" "$backup_file"
    info "原配置已备份到 ${backup_file}"
  fi

  # 应用新配置
  cp /tmp/nginx_optimized.conf "$NGINX_CONF"
  info "新配置已写入 ${NGINX_CONF}"

  # 测试配置
  local nginx_bin="${PREFIX_NGINX}/sbin/nginx"
  echo ""
  info "正在测试新配置..."
  if $nginx_bin -t 2>&1; then
    ok "配置测试通过"

    # 询问是否重载
    if ! $FORCE; then
      echo ""
      read -r -p "是否立即重载 Nginx 以应用新配置？[Y/n] " reload_ans
      reload_ans=${reload_ans:-Y}
    else
      reload_ans="Y"
    fi

    if [[ "$reload_ans" =~ ^[Yy] ]]; then
      echo ""
      info "正在重载 Nginx..."
      if $nginx_bin -s reload 2>&1; then
        ok "Nginx 已成功重载"
      else
        fail "Nginx 重载失败，请手动检查"
        warn "备份配置位于: ${backup_file}"
        warn "如需恢复: cp ${backup_file} ${NGINX_CONF} && ${nginx_bin} -s reload"
      fi
    else
      info "配置已写入但未重载。手动重载命令:"
      echo "  ${nginx_bin} -t && ${nginx_bin} -s reload"
    fi
  else
    fail "配置测试失败！"
    warn "正在恢复备份配置..."
    if [ -f "$backup_file" ]; then
      cp "$backup_file" "$NGINX_CONF"
      ok "已恢复备份配置"
    fi
    return 1
  fi
}

# ============================================================
# 系统参数应用模块
# ============================================================

apply_sysctl() {
  title "应用系统内核参数优化"

  local sysctl_conf="/etc/sysctl.conf"
  local backup_file="${BACKUP_DIR}/sysctl.conf.$(date '+%Y%m%d_%H%M%S')"
  local errors=0
  local applied=0

  # 检查 root 权限
  if [ "$(id -u)" -ne 0 ]; then
    fail "应用系统参数需要 root 权限，请使用 sudo 或以 root 身份运行"
    return 1
  fi

  # 备份当前 sysctl.conf
  if [ -f "$sysctl_conf" ]; then
    mkdir -p "$BACKUP_DIR"
    cp "$sysctl_conf" "$backup_file"
    ok "sysctl.conf 已备份到 ${backup_file}"
  fi

  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │              系统参数优化项                          │"
  echo "  ├─────────────────────────────────────────────────────┤"

  # ---- 1. net.core.somaxconn ----
  local somaxconn_val=16384
  [ "$MEM_TOTAL_GB" -ge 16 ] && somaxconn_val=65535
  [ "$MEM_TOTAL_GB" -ge 4 ] && [ "$MEM_TOTAL_GB" -lt 16 ] && somaxconn_val=16384
  [ "$MEM_TOTAL_GB" -lt 4 ] && somaxconn_val=8192

  local current_somaxconn
  current_somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo "0")
  if [ "$current_somaxconn" -lt "$somaxconn_val" ]; then
    sysctl -w "net.core.somaxconn=${somaxconn_val}" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "net.core.somaxconn" "${somaxconn_val} (${current_somaxconn}→${somaxconn_val})"
  else
    printf "  │  %-25s %-20s │\n" "net.core.somaxconn" "${current_somaxconn} (已满足)"
  fi

  # ---- 2. net.core.netdev_max_backlog ----
  local backlog_val=16384
  [ "$MEM_TOTAL_GB" -ge 16 ] && backlog_val=65535
  [ "$MEM_TOTAL_GB" -lt 4 ] && backlog_val=8192

  local current_backlog
  current_backlog=$(cat /proc/sys/net/core/netdev_max_backlog 2>/dev/null || echo "0")
  if [ "$current_backlog" -lt "$backlog_val" ]; then
    sysctl -w "net.core.netdev_max_backlog=${backlog_val}" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "net.core.netdev_max_backlog" "${backlog_val} (${current_backlog}→${backlog_val})"
  else
    printf "  │  %-25s %-20s │\n" "net.core.netdev_max_backlog" "${current_backlog} (已满足)"
  fi

  # ---- 3. net.ipv4.tcp_tw_reuse ----
  local current_tw_reuse
  current_tw_reuse=$(cat /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null || echo "0")
  if [ "$current_tw_reuse" != "1" ]; then
    sysctl -w "net.ipv4.tcp_tw_reuse=1" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_tw_reuse" "1 (${current_tw_reuse}→1)"
  else
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_tw_reuse" "1 (已启用)"
  fi

  # ---- 4. net.ipv4.tcp_fin_timeout ----
  local current_fin_timeout
  current_fin_timeout=$(cat /proc/sys/net/ipv4/tcp_fin_timeout 2>/dev/null || echo "0")
  if [ "$current_fin_timeout" -gt 15 ]; then
    sysctl -w "net.ipv4.tcp_fin_timeout=15" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_fin_timeout" "15 (${current_fin_timeout}→15)"
  else
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_fin_timeout" "${current_fin_timeout} (已优化)"
  fi

  # ---- 5. net.ipv4.tcp_keepalive_time ----
  local current_ka_time
  current_ka_time=$(cat /proc/sys/net/ipv4/tcp_keepalive_time 2>/dev/null || echo "0")
  if [ "$current_ka_time" -gt 300 ]; then
    sysctl -w "net.ipv4.tcp_keepalive_time=300" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_keepalive_time" "300 (${current_ka_time}→300)"
  else
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_keepalive_time" "${current_ka_time} (已优化)"
  fi

  # ---- 6. net.ipv4.tcp_syncookies ----
  local current_syncookies
  current_syncookies=$(cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null || echo "0")
  if [ "$current_syncookies" != "1" ]; then
    sysctl -w "net.ipv4.tcp_syncookies=1" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_syncookies" "1 (${current_syncookies}→1)"
  else
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_syncookies" "1 (已启用)"
  fi

  # ---- 7. net.ipv4.tcp_max_syn_backlog ----
  local syn_backlog_val=65535
  [ "$MEM_TOTAL_GB" -lt 4 ] && syn_backlog_val=16384

  local current_syn_backlog
  current_syn_backlog=$(cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null || echo "0")
  if [ "$current_syn_backlog" -lt "$syn_backlog_val" ]; then
    sysctl -w "net.ipv4.tcp_max_syn_backlog=${syn_backlog_val}" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_max_syn_backlog" "${syn_backlog_val} (${current_syn_backlog}→${syn_backlog_val})"
  else
    printf "  │  %-25s %-20s │\n" "net.ipv4.tcp_max_syn_backlog" "${current_syn_backlog} (已满足)"
  fi

  # ---- 8. fs.file-max ----
  local file_max_val=1000000
  [ "$MEM_TOTAL_GB" -lt 4 ] && file_max_val=500000

  local current_file_max
  current_file_max=$(cat /proc/sys/fs/file-max 2>/dev/null || echo "0")
  if [ "$current_file_max" -lt "$file_max_val" ]; then
    sysctl -w "fs.file-max=${file_max_val}" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "fs.file-max" "${file_max_val} (${current_file_max}→${file_max_val})"
  else
    printf "  │  %-25s %-20s │\n" "fs.file-max" "${current_file_max} (已满足)"
  fi

  # ---- 9. net.core.rmem_max / wmem_max ----
  local rmem_max_val=8388608
  local wmem_max_val=8388608
  [ "$MEM_TOTAL_GB" -ge 16 ] && rmem_max_val=16777216 && wmem_max_val=16777216
  [ "$MEM_TOTAL_GB" -lt 4 ] && rmem_max_val=4194304 && wmem_max_val=4194304

  local current_rmem_max
  current_rmem_max=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo "0")
  if [ "$current_rmem_max" -lt "$rmem_max_val" ]; then
    sysctl -w "net.core.rmem_max=${rmem_max_val}" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "net.core.rmem_max" "${rmem_max_val} (${current_rmem_max}→${rmem_max_val})"
  else
    printf "  │  %-25s %-20s │\n" "net.core.rmem_max" "${current_rmem_max} (已满足)"
  fi

  local current_wmem_max
  current_wmem_max=$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo "0")
  if [ "$current_wmem_max" -lt "$wmem_max_val" ]; then
    sysctl -w "net.core.wmem_max=${wmem_max_val}" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "net.core.wmem_max" "${wmem_max_val} (${current_wmem_max}→${wmem_max_val})"
  else
    printf "  │  %-25s %-20s │\n" "net.core.wmem_max" "${current_wmem_max} (已满足)"
  fi

  # ---- 10. net.ipv4.ip_local_port_range ----
  local current_port_range
  current_port_range=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo "")
  local port_low
  port_low=$(echo "$current_port_range" | awk '{print $1}' || echo "0")
  if [ "$port_low" -gt 1024 ]; then
    sysctl -w "net.ipv4.ip_local_port_range=1024 65535" >/dev/null 2>&1 && applied=$((applied + 1)) || errors=$((errors + 1))
    printf "  │  %-25s %-20s │\n" "ip_local_port_range" "1024 65535"
  else
    printf "  │  %-25s %-20s │\n" "ip_local_port_range" "${current_port_range} (已优化)"
  fi

  echo "  └─────────────────────────────────────────────────────┘"
  echo ""

  # ---- 11. 关闭 THP (Transparent Huge Pages) ----
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │              THP (透明大页) 检测                     │"
  echo "  ├─────────────────────────────────────────────────────┤"
  local thp_status
  thp_status=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "")
  if echo "$thp_status" | grep -q "\[never\]"; then
    printf "  │  %-25s %-20s │\n" "THP" "已关闭 (推荐)"
  else
    printf "  │  %-25s %-20s │\n" "THP" "未关闭 (建议关闭)"
    skip "THP 未关闭，建议手动执行:"
    echo "    echo never > /sys/kernel/mm/transparent_hugepage/enabled"
    echo "    echo never > /sys/kernel/mm/transparent_hugepage/defrag"
  fi
  echo "  └─────────────────────────────────────────────────────┘"
  echo ""

  # ---- 12. ulimit 优化 ----
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │              ulimit (文件描述符) 优化                │"
  echo "  ├─────────────────────────────────────────────────────┤"
  local current_ulimit
  current_ulimit=$(ulimit -n 2>/dev/null || echo "1024")
  local target_ulimit=65535
  [ "$MEM_TOTAL_GB" -lt 4 ] && target_ulimit=32768

  if [ "$current_ulimit" -lt "$target_ulimit" ]; then
    printf "  │  %-25s %-20s │\n" "ulimit -n" "${current_ulimit} → 建议 ${target_ulimit}"
    skip "当前 ulimit -n 为 ${current_ulimit}，建议设为 ${target_ulimit}"
    echo "    在 /etc/security/limits.conf 添加:"
    echo "    * soft nofile ${target_ulimit}"
    echo "    * hard nofile ${target_ulimit}"
    echo "    root soft nofile ${target_ulimit}"
    echo "    root hard nofile ${target_ulimit}"
  else
    printf "  │  %-25s %-20s │\n" "ulimit -n" "${current_ulimit} (已满足)"
  fi
  echo "  └─────────────────────────────────────────────────────┘"
  echo ""

  # ---- 写入 sysctl.conf 持久化 ----
  echo ""
  info "正在将参数写入 ${sysctl_conf} 以持久化..."
  {
    echo ""
    echo "# ============================================================"
    echo "# Nginx 优化参数 - 由 optimize_nginx.sh 添加"
    echo "# 添加时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# ============================================================"
    echo "net.core.somaxconn = ${somaxconn_val}"
    echo "net.core.netdev_max_backlog = ${backlog_val}"
    echo "net.ipv4.tcp_tw_reuse = 1"
    echo "net.ipv4.tcp_fin_timeout = 15"
    echo "net.ipv4.tcp_keepalive_time = 300"
    echo "net.ipv4.tcp_syncookies = 1"
    echo "net.ipv4.tcp_max_syn_backlog = ${syn_backlog_val}"
    echo "fs.file-max = ${file_max_val}"
    echo "net.core.rmem_max = ${rmem_max_val}"
    echo "net.core.wmem_max = ${wmem_max_val}"
    echo "net.ipv4.ip_local_port_range = 1024 65535"
  } >> "$sysctl_conf"
  ok "参数已持久化到 ${sysctl_conf}"

  # 汇总
  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │              系统参数优化结果                        │"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-25s %-20s │\n" "已应用" "${applied} 项"
  printf "  │  %-25s %-20s │\n" "错误" "${errors} 项"
  printf "  │  %-25s %-20s │\n" "已满足（无需修改）" "$((10 - applied - errors)) 项"
  echo "  └─────────────────────────────────────────────────────┘"
  echo ""

  if [ "$errors" -gt 0 ]; then
    warn "部分参数应用失败，请检查日志"
  fi

  ok "系统内核参数优化完成"
}

# ============================================================
# 主函数
# ============================================================

main() {
  # 先解析命令行参数
  parse_flags "$@"

  echo ""
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║         Nginx 配置优化工具 v1.0                       ║"
  echo "  ║     根据硬件配置自动优化 Nginx 参数                   ║"
  echo "  ╚══════════════════════════════════════════════════════╝"

  # 执行硬件检测
  detect_os
  detect_cpu
  detect_memory
  detect_disk
  detect_network
  detect_nginx

  # 生成配置
  generate_nginx_conf
  generate_sysctl_advice

  # 显示摘要
  show_summary

  # 如果只是显示，则退出
  if $SHOW_ONLY; then
    echo ""
    info "预览模式，未写入任何文件"
    echo ""
    info "优化后的配置文件: /tmp/nginx_optimized.conf"
    info "系统参数建议: /tmp/nginx_sysctl_advice.txt"
    exit 0
  fi

  # 如果是 dry-run，显示但不应用
  if $DRY_RUN; then
    echo ""
    info "Dry-Run 模式，未写入任何文件"
    echo ""
    info "优化后的配置文件: /tmp/nginx_optimized.conf"
    info "系统参数建议: /tmp/nginx_sysctl_advice.txt"
    echo ""
    info "查看配置: cat /tmp/nginx_optimized.conf"
    info "查看系统参数建议: cat /tmp/nginx_sysctl_advice.txt"
    exit 0
  fi

  # 确认应用
  if ! $FORCE; then
    echo ""
    echo "  ⚠️  即将应用以上优化配置到 ${NGINX_CONF}"
    echo "  原配置将备份到 ${BACKUP_DIR}/"
    echo ""
    read -r -p "是否继续？[y/N] " confirm
    confirm=${confirm:-N}
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
      info "已取消"
      info "生成的配置文件仍保留在: /tmp/nginx_optimized.conf"
      info "系统参数建议: /tmp/nginx_sysctl_advice.txt"
      exit 0
    fi
  fi

  # 应用优化
  apply_optimization

  # 如果指定了 --apply-sysctl，应用系统参数优化
  if $APPLY_SYSCTL; then
    echo ""
    apply_sysctl
  fi

  echo ""
  info "优化完成！"
  echo ""
  if $APPLY_SYSCTL; then
    info "系统内核参数已优化并持久化到 /etc/sysctl.conf"
  else
    info "系统参数优化建议文件: /tmp/nginx_sysctl_advice.txt"
    echo "  查看建议: cat /tmp/nginx_sysctl_advice.txt"
    echo "  使用 --apply-sysctl 参数可直接应用系统参数优化"
  fi
  echo ""
  info "如需恢复原配置:"
  echo "  备份文件位于 ${BACKUP_DIR}/"
  echo "  例如: cp ${BACKUP_DIR}/nginx.conf.$(date '+%Y%m%d_*') ${NGINX_CONF}"
  echo "  然后: ${PREFIX_NGINX}/sbin/nginx -s reload"
}

# 执行主函数
main "$@"
