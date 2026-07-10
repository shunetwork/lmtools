#!/usr/bin/env bash
set -euo pipefail

# optimize_php.sh - 根据硬件配置优化 PHP-FPM 和 PHP 配置
# 用途: 自动检测 CPU 核心数、内存大小等硬件信息，
#       生成最优的 php-fpm.conf、php.ini 和 OPcache 配置。
# 支持通过 --prefix-php 覆盖安装前缀

PREFIX_PHP=/usr/local/php
BACKUP_DIR="${PREFIX_PHP}/etc/backup"
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
NC='\033[0m'

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
  --prefix-php PATH     PHP 安装前缀（默认: ${PREFIX_PHP}）
  --dry-run             仅预览优化结果，不写入文件
  --show-only           仅显示当前硬件信息和推荐配置，不写入文件
  --force               跳过确认提示，直接应用优化
  --verbose             输出详细调试信息
  -h, --help            显示本帮助

示例:
  $0                                    # 交互式优化
  $0 --dry-run                          # 预览优化结果
  $0 --show-only                        # 仅显示推荐配置
  $0 --force                            # 直接应用优化（无确认）
  $0 --prefix-php /opt/php --force      # 指定路径并直接应用

说明:
  该工具会根据当前服务器的硬件配置自动计算最优的 PHP 参数：

  PHP-FPM 进程管理:
  - pm.max_children: 根据内存和每个进程平均内存计算
  - pm.start_servers: 根据 CPU 核心数
  - pm.min/max_spare_servers: 根据 CPU 核心数
  - pm.max_requests: 根据内存稳定性需求

  PHP 配置 (php.ini):
  - memory_limit: 根据总内存大小
  - max_execution_time: 根据应用场景
  - upload_max_filesize / post_max_size: 根据内存
  - max_input_vars: 根据内存
  - realpath_cache: 根据内存

  OPcache 优化:
  - opcache.memory_consumption: 根据内存
  - opcache.max_accelerated_files: 根据内存
  - opcache.revalidate_freq: 根据应用场景

  PHP-FPM 系统参数:
  - rlimit_files: 根据系统 ulimit
  - 事件机制: 自动选择 epoll/kqueue

EOF
}

parse_flags() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --prefix-php) PREFIX_PHP="$2"; shift 2;;
      --dry-run)    DRY_RUN=true; shift;;
      --show-only)  SHOW_ONLY=true; shift;;
      --force)      FORCE=true; shift;;
      --verbose)    VERBOSE=true; shift;;
      -h|--help)    usage; exit 0;;
      *) echo "未知选项: $1"; usage; exit 1;;
    esac
  done
}

# ============================================================
# 硬件检测模块
# ============================================================

detect_cpu() {
  title "CPU 信息检测"

  local cpu_cores
  if [ -f /proc/cpuinfo ]; then
    cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
  else
    cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "1")
  fi

  local cpu_model=""
  if [ -f /proc/cpuinfo ]; then
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[ \t]*//' || echo "未知")
  else
    cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "未知")
  fi

  echo "  CPU 核心数: ${cpu_cores}"
  echo "  CPU 型号: ${cpu_model}"

  CPU_CORES=$cpu_cores
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
    mem_total_mb=$(($(sysctl -n hw.memsize 2>/dev/null || echo "1073741824") / 1024 / 1024))
    mem_total_gb=$(( mem_total_mb / 1024 ))
  fi

  echo "  总内存: ${mem_total_mb}MB (${mem_total_gb}GB)"
  echo "  Swap: ${swap_total_mb}MB"

  MEM_TOTAL_MB=$mem_total_mb
  MEM_TOTAL_GB=$mem_total_gb
  SWAP_TOTAL_MB=$swap_total_mb
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

detect_php() {
  title "PHP 当前状态"

  local php_bin="${PREFIX_PHP}/bin/php"
  local php_fpm_bin="${PREFIX_PHP}/sbin/php-fpm"
  local php_ini="${PREFIX_PHP}/etc/php.ini"
  local fpm_conf="${PREFIX_PHP}/etc/php-fpm.conf"
  local pool_dir="${PREFIX_PHP}/etc/php-fpm.d"

  if [ -x "$php_bin" ]; then
    local php_ver
    php_ver=$("$php_bin" -r 'echo PHP_VERSION;' 2>/dev/null || echo "未知")
    echo "  PHP 版本: ${php_ver}"
    echo "  安装路径: ${PREFIX_PHP}"
    echo "  php.ini: ${php_ini}"
    echo "  php-fpm.conf: ${fpm_conf}"

    # 获取当前 PHP 配置值
    local current_memory_limit
    current_memory_limit=$("$php_bin" -r 'echo ini_get("memory_limit");' 2>/dev/null || echo "未知")
    local current_max_execution_time
    current_max_execution_time=$("$php_bin" -r 'echo ini_get("max_execution_time");' 2>/dev/null || echo "未知")
    local current_upload_max_filesize
    current_upload_max_filesize=$("$php_bin" -r 'echo ini_get("upload_max_filesize");' 2>/dev/null || echo "未知")
    local current_post_max_size
    current_post_max_size=$("$php_bin" -r 'echo ini_get("post_max_size");' 2>/dev/null || echo "未知")
    local current_max_input_vars
    current_max_input_vars=$("$php_bin" -r 'echo ini_get("max_input_vars");' 2>/dev/null || echo "未知")

    echo "  当前 memory_limit: ${current_memory_limit}"
    echo "  当前 max_execution_time: ${current_max_execution_time}s"
    echo "  当前 upload_max_filesize: ${current_upload_max_filesize}"
    echo "  当前 post_max_size: ${current_post_max_size}"
    echo "  当前 max_input_vars: ${current_max_input_vars}"

    # 检查 OPcache
    local opcache_enabled
    opcache_enabled=$("$php_bin" -r 'echo extension_loaded("Zend OPcache") ? "已启用" : "未启用";' 2>/dev/null || echo "未知")
    echo "  OPcache: ${opcache_enabled}"

    PHP_INSTALLED=true
    PHP_INI=$php_ini
    FPM_CONF=$fpm_conf
    POOL_DIR=$pool_dir
  else
    echo "  PHP 未安装或未在 ${PREFIX_PHP} 找到"
    PHP_INSTALLED=false
    PHP_INI="${PREFIX_PHP}/etc/php.ini"
    FPM_CONF="${PREFIX_PHP}/etc/php-fpm.conf"
    POOL_DIR="${PREFIX_PHP}/etc/php-fpm.d"
  fi
}

detect_fpm_pool() {
  title "PHP-FPM 进程池检测"

  local pool_conf="${POOL_DIR}/www.conf"

  if [ -f "$pool_conf" ]; then
    local current_pm
    current_pm=$(grep -E "^\s*pm\s*=" "$pool_conf" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "未知")
    local current_max_children
    current_max_children=$(grep -E "^\s*pm.max_children\s*=" "$pool_conf" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "未知")
    local current_start_servers
    current_start_servers=$(grep -E "^\s*pm.start_servers\s*=" "$pool_conf" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "未知")
    local current_min_spare
    current_min_spare=$(grep -E "^\s*pm.min_spare_servers\s*=" "$pool_conf" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "未知")
    local current_max_spare
    current_max_spare=$(grep -E "^\s*pm.max_spare_servers\s*=" "$pool_conf" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "未知")

    echo "  进程池: www"
    echo "  当前 pm: ${current_pm}"
    echo "  当前 pm.max_children: ${current_max_children}"
    echo "  当前 pm.start_servers: ${current_start_servers}"
    echo "  当前 pm.min_spare_servers: ${current_min_spare}"
    echo "  当前 pm.max_spare_servers: ${current_max_spare}"

    FPM_POOL_CONF=$pool_conf
  else
    echo "  未找到进程池配置文件 (${pool_conf})"
    FPM_POOL_CONF="${POOL_DIR}/www.conf"
  fi
}

# ============================================================
# 配置计算模块
# ============================================================

calculate_optimizations() {
  title "计算优化参数"

  # ---- PHP-FPM 进程管理 ----
  # 每个 PHP-FPM 进程平均内存占用（保守估计）
  # WordPress/Laravel: ~30-50MB, 简单站点: ~10-20MB
  # 使用保守值 30MB/进程
  local mem_per_process=30  # MB per PHP-FPM process

  # 可用内存（总内存的 60% 分配给 PHP-FPM，留出系统和其他服务空间）
  local available_mem=$(( MEM_TOTAL_MB * 60 / 100 ))

  # max_children = 可用内存 / 每进程内存
  local max_children=$(( available_mem / mem_per_process ))

  # 限制范围: 5 - 500
  if [ "$max_children" -lt 5 ]; then
    max_children=5
  elif [ "$max_children" -gt 500 ]; then
    max_children=500
  fi

  # start_servers = min(max_children * 25%, CPU_CORES * 2)
  local start_servers=$(( max_children * 25 / 100 ))
  local start_servers_cpu=$(( CPU_CORES * 2 ))
  [ "$start_servers" -gt "$start_servers_cpu" ] && start_servers=$start_servers_cpu
  [ "$start_servers" -lt 2 ] && start_servers=2

  # min_spare_servers = CPU_CORES 或 start_servers 的一半
  local min_spare=$(( CPU_CORES ))
  [ "$min_spare" -gt "$(( start_servers / 2 ))" ] && min_spare=$(( start_servers / 2 ))
  [ "$min_spare" -lt 1 ] && min_spare=1

  # max_spare_servers = start_servers * 1.5
  local max_spare=$(( start_servers * 150 / 100 ))
  [ "$max_spare" -gt "$max_children" ] && max_spare=$max_children
  [ "$max_spare" -lt "$(( min_spare + 1 ))" ] && max_spare=$(( min_spare + 1 ))

  # max_requests = 每个进程处理多少请求后重启（防止内存泄漏）
  local max_requests=1000
  if [ "$MEM_TOTAL_GB" -ge 16 ]; then
    max_requests=5000
  elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
    max_requests=3000
  elif [ "$MEM_TOTAL_GB" -ge 4 ]; then
    max_requests=1000
  else
    max_requests=500
  fi

  echo "  PHP-FPM 进程管理:"
  echo "    可用内存: ${available_mem}MB (总内存 ${MEM_TOTAL_GB}GB 的 60%)"
  echo "    每进程预估: ${mem_per_process}MB"
  echo "    → pm.max_children: ${max_children}"
  echo "    → pm.start_servers: ${start_servers}"
  echo "    → pm.min_spare_servers: ${min_spare}"
  echo "    → pm.max_spare_servers: ${max_spare}"
  echo "    → pm.max_requests: ${max_requests}"

  # ---- PHP 配置 (php.ini) ----
  local memory_limit="128M"
  local max_execution_time=30
  local max_input_time=60
  local upload_max_filesize="2M"
  local post_max_size="8M"
  local max_input_vars=1000
  local realpath_cache_size="4096K"
  local realpath_cache_ttl=120

  if [ "$MEM_TOTAL_GB" -ge 64 ]; then
    memory_limit="1024M"
    max_execution_time=120
    max_input_time=120
    upload_max_filesize="200M"
    post_max_size="2048M"
    max_input_vars=10000
    realpath_cache_size="8192K"
    realpath_cache_ttl=600
  elif [ "$MEM_TOTAL_GB" -ge 32 ]; then
    memory_limit="512M"
    max_execution_time=90
    max_input_time=120
    upload_max_filesize="100M"
    post_max_size="1024M"
    max_input_vars=5000
    realpath_cache_size="8192K"
    realpath_cache_ttl=600
  elif [ "$MEM_TOTAL_GB" -ge 16 ]; then
    memory_limit="256M"
    max_execution_time=60
    max_input_time=120
    upload_max_filesize="50M"
    post_max_size="100M"
    max_input_vars=3000
    realpath_cache_size="4096K"
    realpath_cache_ttl=300
  elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
    memory_limit="256M"
    max_execution_time=60
    max_input_time=60
    upload_max_filesize="20M"
    post_max_size="50M"
    max_input_vars=2000
    realpath_cache_size="4096K"
    realpath_cache_ttl=300
  elif [ "$MEM_TOTAL_GB" -ge 4 ]; then
    memory_limit="128M"
    max_execution_time=30
    max_input_time=60
    upload_max_filesize="10M"
    post_max_size="20M"
    max_input_vars=1000
    realpath_cache_size="4096K"
    realpath_cache_ttl=120
  else
    memory_limit="64M"
    max_execution_time=30
    max_input_time=60
    upload_max_filesize="2M"
    post_max_size="8M"
    max_input_vars=1000
    realpath_cache_size="2048K"
    realpath_cache_ttl=120
  fi

  echo ""
  echo "  PHP 配置 (php.ini):"
  echo "    → memory_limit: ${memory_limit}"
  echo "    → max_execution_time: ${max_execution_time}s"
  echo "    → max_input_time: ${max_input_time}s"
  echo "    → upload_max_filesize: ${upload_max_filesize}"
  echo "    → post_max_size: ${post_max_size}"
  echo "    → max_input_vars: ${max_input_vars}"
  echo "    → realpath_cache_size: ${realpath_cache_size}"
  echo "    → realpath_cache_ttl: ${realpath_cache_ttl}s"

  # ---- OPcache 配置 ----
  local opcache_memory=64
  local opcache_max_files=4000
  local opcache_revalidate_freq=2
  local opcache_enable_cli=0

  if [ "$MEM_TOTAL_GB" -ge 64 ]; then
    opcache_memory=512
    opcache_max_files=20000
    opcache_revalidate_freq=60
  elif [ "$MEM_TOTAL_GB" -ge 32 ]; then
    opcache_memory=256
    opcache_max_files=15000
    opcache_revalidate_freq=30
  elif [ "$MEM_TOTAL_GB" -ge 16 ]; then
    opcache_memory=128
    opcache_max_files=10000
    opcache_revalidate_freq=10
  elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
    opcache_memory=96
    opcache_max_files=8000
    opcache_revalidate_freq=5
  elif [ "$MEM_TOTAL_GB" -ge 4 ]; then
    opcache_memory=64
    opcache_max_files=4000
    opcache_revalidate_freq=2
  else
    opcache_memory=32
    opcache_max_files=2000
    opcache_revalidate_freq=2
  fi

  echo ""
  echo "  OPcache 配置:"
  echo "    → opcache.memory_consumption: ${opcache_memory}MB"
  echo "    → opcache.max_accelerated_files: ${opcache_max_files}"
  echo "    → opcache.revalidate_freq: ${opcache_revalidate_freq}s"

  # ---- 保存计算结果 ----
  MAX_CHILDREN=$max_children
  START_SERVERS=$start_servers
  MIN_SPARE=$min_spare
  MAX_SPARE=$max_spare
  MAX_REQUESTS=$max_requests

  PHP_MEMORY_LIMIT=$memory_limit
  PHP_MAX_EXECUTION_TIME=$max_execution_time
  PHP_MAX_INPUT_TIME=$max_input_time
  PHP_UPLOAD_MAX_FILESIZE=$upload_max_filesize
  PHP_POST_MAX_SIZE=$post_max_size
  PHP_MAX_INPUT_VARS=$max_input_vars
  PHP_REALPATH_CACHE_SIZE=$realpath_cache_size
  PHP_REALPATH_CACHE_TTL=$realpath_cache_ttl

  OPCACHE_MEMORY=$opcache_memory
  OPCACHE_MAX_FILES=$opcache_max_files
  OPCACHE_REVALIDATE_FREQ=$opcache_revalidate_freq
}

# ============================================================
# 配置生成模块
# ============================================================

generate_fpm_pool_conf() {
  title "生成 PHP-FPM 进程池配置"

  local events_mechanism="epoll"
  case "$OS_TYPE" in
    macos|darwin) events_mechanism="kqueue" ;;
    freebsd)      events_mechanism="kqueue" ;;
    linux)        events_mechanism="epoll" ;;
  esac

  # 获取系统 ulimit
  local ulimit_n
  ulimit_n=$(ulimit -n 2>/dev/null || echo "1024")
  local rlimit_files=$ulimit_n
  [ "$rlimit_files" -gt 65535 ] && rlimit_files=65535

  cat > /tmp/php_fpm_pool_optimized.conf << FPM_POOL_EOF
; ============================================================
; 优化后的 PHP-FPM 进程池配置
; 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
; 生成工具: optimize_php.sh
; 硬件信息:
;   CPU: ${CPU_CORES} 核心
;   内存: ${MEM_TOTAL_MB}MB (${MEM_TOTAL_GB}GB)
;   系统: ${OS_TYPE} ${OS_VERSION}
; ============================================================

[www]

; ---- 用户/组 ----
user = www
group = www

; ---- 监听地址 ----
listen = 127.0.0.1:9000
listen.allowed_clients = 127.0.0.1

; ---- 进程管理 ----
; 进程管理方式: dynamic（动态）、static（静态）、ondemand（按需）
; dynamic: 根据负载动态调整子进程数量（推荐大多数场景）
pm = dynamic

; 最大子进程数
; 根据内存 ${MEM_TOTAL_GB}GB 优化: 可用内存 60% / 每进程 30MB
pm.max_children = ${MAX_CHILDREN}

; 启动时创建的子进程数
pm.start_servers = ${START_SERVERS}

; 空闲进程最小数量
pm.min_spare_servers = ${MIN_SPARE}

; 空闲进程最大数量
pm.max_spare_servers = ${MAX_SPARE}

; 每个子进程处理 ${MAX_REQUESTS} 个请求后自动重启（防止内存泄漏）
pm.max_requests = ${MAX_REQUESTS}

; ---- 请求超时设置 ----
; 请求终止超时（秒）
request_terminate_timeout = ${PHP_MAX_EXECUTION_TIME}s

; 请求慢日志阈值（秒）
request_slowlog_timeout = 5s

; 慢日志路径
slowlog = /var/log/php-fpm/www-slow.log

; ---- 访问日志 ----
access.log = /var/log/php-fpm/www-access.log

; ---- 资源限制 ----
; 文件描述符限制
rlimit_files = ${rlimit_files}

; 核心转储限制
;rlimit_core = unlimited

; ---- 环境变量 ----
env[HOSTNAME] = \$HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp

; ---- 安全配置 ----
; 禁止执行危险函数
;php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source

; 时区设置
php_admin_value[date.timezone] = Asia/Shanghai

; 错误显示（生产环境建议关闭）
php_admin_flag[display_errors] = off

; 上传限制
php_admin_value[upload_max_filesize] = ${PHP_UPLOAD_MAX_FILESIZE}
php_admin_value[post_max_size] = ${PHP_POST_MAX_SIZE}
php_admin_value[max_execution_time] = ${PHP_MAX_EXECUTION_TIME}
php_admin_value[max_input_time] = ${PHP_MAX_INPUT_TIME}
php_admin_value[max_input_vars] = ${PHP_MAX_INPUT_VARS}
php_admin_value[memory_limit] = ${PHP_MEMORY_LIMIT}

; 会话配置
php_admin_value[session.gc_maxlifetime] = 1440
php_admin_value[session.save_path] = /tmp

FPM_POOL_EOF

  echo "  ✅ PHP-FPM 进程池配置已生成到 /tmp/php_fpm_pool_optimized.conf"
}

generate_php_ini_section() {
  title "生成 PHP 配置 (php.ini) 优化段"

  cat > /tmp/php_ini_optimized.conf << PHP_INI_EOF
; ============================================================
; 优化后的 PHP 配置段
; 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
; 生成工具: optimize_php.sh
; 硬件信息:
;   CPU: ${CPU_CORES} 核心
;   内存: ${MEM_TOTAL_MB}MB (${MEM_TOTAL_GB}GB)
; ============================================================
; 将此段内容追加到 php.ini 文件末尾
; 或替换 php.ini 中对应的配置项
; ============================================================

; ---- 资源限制 ----
memory_limit = ${PHP_MEMORY_LIMIT}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
max_input_time = ${PHP_MAX_INPUT_TIME}

; ---- 文件上传 ----
upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}
post_max_size = ${PHP_POST_MAX_SIZE}
max_file_uploads = 20

; ---- 输入限制 ----
max_input_vars = ${PHP_MAX_INPUT_VARS}

; ---- 路径缓存 ----
realpath_cache_size = ${PHP_REALPATH_CACHE_SIZE}
realpath_cache_ttl = ${PHP_REALPATH_CACHE_TTL}

; ---- 错误处理（生产环境） ----
display_errors = Off
display_startup_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT

; ---- 时区 ----
date.timezone = Asia/Shanghai

; ---- 会话 ----
session.gc_maxlifetime = 1440
session.save_path = /tmp

; ---- OPcache ----
zend_extension=opcache.so

[opcache]
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=${OPCACHE_MEMORY}
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=${OPCACHE_MAX_FILES}
opcache.max_wasted_percentage=5
opcache.use_cwd=1
opcache.validate_timestamps=1
opcache.revalidate_freq=${OPCACHE_REVALIDATE_FREQ}
opcache.fast_shutdown=1
opcache.enable_file_override=0
opcache.optimization_level=0x7FFFBFFF
opcache.huge_code_pages=1

PHP_INI_EOF

  echo "  ✅ PHP 配置段已生成到 /tmp/php_ini_optimized.conf"
}

# ============================================================
# 显示优化摘要
# ============================================================

show_summary() {
  title "优化配置摘要"

  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │               PHP-FPM 优化配置摘要                   │"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-30s %-25s │\n" "pm.max_children" "${MAX_CHILDREN}"
  printf "  │  %-30s %-25s │\n" "pm.start_servers" "${START_SERVERS}"
  printf "  │  %-30s %-25s │\n" "pm.min_spare_servers" "${MIN_SPARE}"
  printf "  │  %-30s %-25s │\n" "pm.max_spare_servers" "${MAX_SPARE}"
  printf "  │  %-30s %-25s │\n" "pm.max_requests" "${MAX_REQUESTS}"
  echo "  ├─────────────────────────────────────────────────────┤"
  echo "  │               PHP 配置摘要                          │"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-30s %-25s │\n" "memory_limit" "${PHP_MEMORY_LIMIT}"
  printf "  │  %-30s %-25s │\n" "max_execution_time" "${PHP_MAX_EXECUTION_TIME}s"
  printf "  │  %-30s %-25s │\n" "upload_max_filesize" "${PHP_UPLOAD_MAX_FILESIZE}"
  printf "  │  %-30s %-25s │\n" "post_max_size" "${PHP_POST_MAX_SIZE}"
  printf "  │  %-30s %-25s │\n" "max_input_vars" "${PHP_MAX_INPUT_VARS}"
  echo "  ├─────────────────────────────────────────────────────┤"
  echo "  │               OPcache 配置                          │"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-30s %-25s │\n" "opcache.memory_consumption" "${OPCACHE_MEMORY}MB"
  printf "  │  %-30s %-25s │\n" "opcache.max_accelerated_files" "${OPCACHE_MAX_FILES}"
  printf "  │  %-30s %-25s │\n" "opcache.revalidate_freq" "${OPCACHE_REVALIDATE_FREQ}s"
  echo "  └─────────────────────────────────────────────────────┘"
  echo ""
}

# ============================================================
# 应用优化模块
# ============================================================

apply_optimization() {
  title "应用优化配置"

  if ! $PHP_INSTALLED; then
    warn "PHP 未安装，仅生成配置文件"
    mkdir -p "$POOL_DIR"
    cp /tmp/php_fpm_pool_optimized.conf "$FPM_POOL_CONF"
    info "进程池配置已生成到 ${FPM_POOL_CONF}"
    info "PHP 配置段已生成到 /tmp/php_ini_optimized.conf"
    return
  fi

  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')

  # ---- 备份并应用 PHP-FPM 进程池配置 ----
  mkdir -p "$BACKUP_DIR"

  if [ -f "$FPM_POOL_CONF" ]; then
    cp "$FPM_POOL_CONF" "${BACKUP_DIR}/www.conf.${timestamp}"
    info "原进程池配置已备份到 ${BACKUP_DIR}/www.conf.${timestamp}"
  fi

  cp /tmp/php_fpm_pool_optimized.conf "$FPM_POOL_CONF"
  info "新进程池配置已写入 ${FPM_POOL_CONF}"

  # ---- 备份并应用 php.ini ----
  if [ -f "$PHP_INI" ]; then
    cp "$PHP_INI" "${BACKUP_DIR}/php.ini.${timestamp}"
    info "原 php.ini 已备份到 ${BACKUP_DIR}/php.ini.${timestamp}"
  fi

  # ---- 启用 OPcache 扩展 ----
  # 检查并取消注释 zend_extension=opcache 行
  if grep -q "^;zend_extension[[:space:]]*=[[:space:]]*opcache" "$PHP_INI" 2>/dev/null; then
    sed -i 's/^;zend_extension[[:space:]]*=[[:space:]]*opcache/zend_extension=opcache.so/' "$PHP_INI"
    ok "已取消注释 zend_extension=opcache.so（原为注释状态）"
  elif grep -q "^zend_extension[[:space:]]*=[[:space:]]*opcache\.so" "$PHP_INI" 2>/dev/null; then
    ok "zend_extension=opcache.so 已启用"
  elif grep -q "^zend_extension[[:space:]]*=[[:space:]]*opcache" "$PHP_INI" 2>/dev/null; then
    # 如果已有但缺少 .so 后缀，补全
    sed -i 's/^zend_extension[[:space:]]*=[[:space:]]*opcache[[:space:]]*$/zend_extension=opcache.so/' "$PHP_INI"
    ok "已修正 zend_extension=opcache.so"
  else
    # 在文件头部添加（OPcache 扩展必须在 [opcache] 段之前加载）
    sed -i '1i zend_extension=opcache.so' "$PHP_INI"
    ok "已添加 zend_extension=opcache.so 到 php.ini 头部"
  fi

  # 检查 php.ini 中是否已有 [opcache] 段
  if grep -q "^\[opcache\]" "$PHP_INI" 2>/dev/null; then
    # 已有 [opcache] 段，取消注释其中的关键配置行
    local opcache_keys=(
      "opcache.enable"
      "opcache.enable_cli"
      "opcache.memory_consumption"
      "opcache.interned_strings_buffer"
      "opcache.max_accelerated_files"
      "opcache.max_wasted_percentage"
      "opcache.use_cwd"
      "opcache.validate_timestamps"
      "opcache.revalidate_freq"
      "opcache.fast_shutdown"
      "opcache.enable_file_override"
      "opcache.optimization_level"
      "opcache.huge_code_pages"
    )
    local uncommented=0
    for key in "${opcache_keys[@]}"; do
      if grep -q "^;${key}" "$PHP_INI" 2>/dev/null; then
        sed -i "s/^;${key}[[:space:]]*=/  ${key} =/" "$PHP_INI"
        uncommented=$((uncommented + 1))
      fi
    done
    if [ "$uncommented" -gt 0 ]; then
      ok "已取消注释 ${uncommented} 项 OPcache 配置"
    fi

    # 更新关键值（使用 sed 替换）
    sed -i "s/^opcache.memory_consumption[[:space:]]*=.*/opcache.memory_consumption = ${OPCACHE_MEMORY}/" "$PHP_INI"
    sed -i "s/^opcache.max_accelerated_files[[:space:]]*=.*/opcache.max_accelerated_files = ${OPCACHE_MAX_FILES}/" "$PHP_INI"
    sed -i "s/^opcache.revalidate_freq[[:space:]]*=.*/opcache.revalidate_freq = ${OPCACHE_REVALIDATE_FREQ}/" "$PHP_INI"
    sed -i "s/^opcache.enable[[:space:]]*=.*/opcache.enable = 1/" "$PHP_INI"
    sed -i "s/^opcache.huge_code_pages[[:space:]]*=.*/opcache.huge_code_pages = 1/" "$PHP_INI"
    ok "OPcache 配置值已更新"
  else
    # 追加优化配置到 php.ini
    cat /tmp/php_ini_optimized.conf >> "$PHP_INI"
    ok "优化配置已追加到 ${PHP_INI}"
  fi

  # ---- 测试 PHP-FPM 配置 ----
  local php_fpm_bin="${PREFIX_PHP}/sbin/php-fpm"
  echo ""
  info "正在测试 PHP-FPM 配置..."
  if $php_fpm_bin -t 2>&1; then
    ok "配置测试通过"

    # 询问是否重启
    if ! $FORCE; then
      echo ""
      read -r -p "是否立即重启 PHP-FPM 以应用新配置？[Y/n] " reload_ans
      reload_ans=${reload_ans:-Y}
    else
      reload_ans="Y"
    fi

    if [[ "$reload_ans" =~ ^[Yy] ]]; then
      echo ""
      info "正在重启 PHP-FPM..."

      # 尝试多种方式重启
      local restarted=false
      if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart php-fpm.service 2>/dev/null; then
          ok "PHP-FPM 已通过 systemctl 成功重启"
          restarted=true
        fi
      fi

      if ! $restarted; then
        # 尝试通过信号重启
        local fpm_pid="${PREFIX_PHP}/var/run/php-fpm.pid"
        if [ -f "$fpm_pid" ]; then
          local pid
          pid=$(cat "$fpm_pid" 2>/dev/null || echo "")
          if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -USR2 "$pid" 2>/dev/null && {
              ok "PHP-FPM 已通过 USR2 信号成功重启"
              restarted=true
            }
          fi
        fi
      fi

      if ! $restarted; then
        # 直接启动
        if $php_fpm_bin --fpm-config "$FPM_CONF" 2>/dev/null; then
          ok "PHP-FPM 已启动"
          restarted=true
        fi
      fi

      if ! $restarted; then
        fail "PHP-FPM 重启失败，请手动检查"
        warn "备份配置位于: ${BACKUP_DIR}/"
        warn "手动重启: ${php_fpm_bin} -t && systemctl restart php-fpm"
      fi
    else
      info "配置已写入但未重启。手动重启命令:"
      echo "  ${php_fpm_bin} -t && systemctl restart php-fpm"
    fi
  else
    fail "配置测试失败！"
    warn "正在恢复备份配置..."
    if [ -f "${BACKUP_DIR}/www.conf.${timestamp}" ]; then
      cp "${BACKUP_DIR}/www.conf.${timestamp}" "$FPM_POOL_CONF"
      ok "已恢复进程池配置"
    fi
    if [ -f "${BACKUP_DIR}/php.ini.${timestamp}" ]; then
      cp "${BACKUP_DIR}/php.ini.${timestamp}" "$PHP_INI"
      ok "已恢复 php.ini"
    fi
    return 1
  fi
}

# ============================================================
# 主函数
# ============================================================

main() {
  # 先解析命令行参数
  parse_flags "$@"

  echo ""
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║         PHP 配置优化工具 v1.0                        ║"
  echo "  ║     根据硬件配置自动优化 PHP-FPM 和 PHP 参数         ║"
  echo "  ╚══════════════════════════════════════════════════════╝"

  # 执行硬件检测
  detect_os
  detect_cpu
  detect_memory
  detect_php
  detect_fpm_pool

  # 计算优化参数
  calculate_optimizations

  # 生成配置
  generate_fpm_pool_conf
  generate_php_ini_section

  # 显示摘要
  show_summary

  # 如果只是显示，则退出
  if $SHOW_ONLY; then
    echo ""
    info "预览模式，未写入任何文件"
    echo ""
    info "优化后的 PHP-FPM 配置: /tmp/php_fpm_pool_optimized.conf"
    info "PHP 配置段: /tmp/php_ini_optimized.conf"
    exit 0
  fi

  # 如果是 dry-run，显示但不应用
  if $DRY_RUN; then
    echo ""
    info "Dry-Run 模式，未写入任何文件"
    echo ""
    info "优化后的 PHP-FPM 配置: /tmp/php_fpm_pool_optimized.conf"
    info "PHP 配置段: /tmp/php_ini_optimized.conf"
    echo ""
    info "查看配置: cat /tmp/php_fpm_pool_optimized.conf"
    info "查看 PHP 配置: cat /tmp/php_ini_optimized.conf"
    exit 0
  fi

  # 确认应用
  if ! $FORCE; then
    echo ""
    echo "  ⚠️  即将应用以上优化配置"
    echo "  - PHP-FPM 进程池: ${FPM_POOL_CONF}"
    echo "  - PHP 配置: ${PHP_INI}"
    echo "  原配置将备份到 ${BACKUP_DIR}/"
    echo ""
    read -r -p "是否继续？[y/N] " confirm
    confirm=${confirm:-N}
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
      info "已取消"
      info "生成的配置文件仍保留在:"
      info "  /tmp/php_fpm_pool_optimized.conf"
      info "  /tmp/php_ini_optimized.conf"
      exit 0
    fi
  fi

  # 应用优化
  apply_optimization

  echo ""
  info "优化完成！"
  echo ""
  info "如需恢复原配置:"
  echo "  备份文件位于 ${BACKUP_DIR}/"
  echo "  例如: cp ${BACKUP_DIR}/www.conf.${timestamp:-bak} ${FPM_POOL_CONF}"
  echo "  然后: systemctl restart php-fpm"
}

# 执行主函数
main "$@"
