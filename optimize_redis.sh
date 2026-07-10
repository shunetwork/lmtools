#!/usr/bin/env bash
set -euo pipefail

# optimize_redis.sh - 根据硬件配置优化 Redis 配置
# 用途: 自动检测 CPU 核心数、内存大小、磁盘类型等硬件信息，
#       生成最优的 redis.conf 配置参数。
# 支持通过 --prefix-redis 覆盖安装前缀

PREFIX_REDIS=/usr/local/redis
REDIS_CONF=/etc/redis/redis.conf
BACKUP_DIR="/etc/redis/backup"
DRY_RUN=false
FORCE=false
SHOW_ONLY=false
VERBOSE=false
APPLY_SYSCTL=false
REDIS_PORT=6379
REDIS_BIND="127.0.0.1"
REDIS_MODE="auto"  # auto|standalone|sentinel|cluster

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
ok()    { echo -e "  ${GREEN}\xe2\x9c\x85${NC} $*"; }
fail()  { echo -e "  ${RED}\xe2\x9d\x8c${NC} $*"; }
skip()  { echo -e "  ${YELLOW}\xe2\x9a\xa0\xef\xb8\x8f${NC} $*"; }

usage() {
  cat <<EOF
用法: $0 [OPTIONS]

选项:
  --prefix-redis PATH   Redis 安装前缀（默认: ${PREFIX_REDIS}）
  --conf PATH           redis.conf 配置文件路径（默认: ${REDIS_CONF}）
  --port PORT           Redis 监听端口（默认: ${REDIS_PORT}）
  --bind ADDR           绑定地址（默认: ${REDIS_BIND}）
  --mode MODE           运行模式: standalone|sentinel|cluster|auto（默认: ${REDIS_MODE}）
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
  $0 --force --apply-sysctl             # 直接应用 Redis + 系统参数优化
  $0 --conf /etc/redis/redis.conf --force  # 指定配置文件并直接应用
  $0 --mode cluster --force             # 集群模式优化

说明:
  该工具会根据当前服务器的硬件配置自动计算最优的 Redis 参数：

  内存管理:
  - maxmemory: 根据总内存大小（通常 50-80%）
  - maxmemory-policy: 根据运行模式自动选择淘汰策略
  - maxmemory-samples: 根据 CPU 核心数

  持久化优化:
  - save 策略: 根据磁盘类型和内存大小调整
  - RDB/AOF 配置: 根据数据安全需求
  - aof-rewrite 阈值: 根据内存大小

  网络优化:
  - tcp-backlog: 根据系统 somaxconn
  - timeout: 根据内存和典型场景
  - tcp-keepalive: 根据网络环境

  性能优化:
  - maxclients: 根据系统 ulimit
  - hash/max-intset/list/set/zset 编码优化: 根据内存
  - hz（频率）: 根据 CPU 核心数
  - lazyfree 配置: 根据内存大小

  系统参数优化:
  - 透明大页（THP）: 建议关闭
  - 内存 overcommit: 建议启用
  - somaxconn: 建议增大
  - ulimit: 建议优化

EOF
}

parse_flags() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --prefix-redis) PREFIX_REDIS="$2"; shift 2;;
      --conf)         REDIS_CONF="$2"; shift 2;;
      --port)         REDIS_PORT="$2"; shift 2;;
      --bind)         REDIS_BIND="$2"; shift 2;;
      --mode)         REDIS_MODE="$2"; shift 2;;
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

detect_disk() {
  title "磁盘信息检测"

  local data_dir="/var/lib/redis"
  local disk_type="HDD"
  local disk_size_gb=0
  local disk_avail_mb=0

  # 检测数据目录所在磁盘
  local device=""
  if [ -d "$data_dir" ]; then
    device=$(df "$data_dir" 2>/dev/null | awk 'NR==2{print $1}' || echo "")
    disk_avail_mb=$(df -BM "$data_dir" 2>/dev/null | awk 'NR==2{print $4}' | sed 's/M//' || echo "0")
    disk_size_gb=$(df -BG "$data_dir" 2>/dev/null | awk 'NR==2{print $2}' | sed 's/G//' || echo "0")
  fi

  # 检测磁盘类型（SSD 或 HDD）
  if [ -n "$device" ]; then
    local real_dev="$device"

    # 如果是 dm 设备（LVM），递归查找底层物理设备
    if [[ "$real_dev" =~ ^/dev/mapper/ ]] || [[ "$real_dev" =~ ^/dev/dm- ]]; then
      local dm_name
      dm_name=$(basename "$real_dev")
      if command -v dmsetup >/dev/null 2>&1; then
        local dm_devno
        dm_devno=$(dmsetup info -c --noheadings -o major,minor "$dm_name" 2>/dev/null | awk '{print $1}' || echo "")
        if [ -n "$dm_devno" ]; then
          local dm_major dm_minor
          dm_major=$(echo "$dm_devno" | cut -d: -f1)
          dm_minor=$(echo "$dm_devno" | cut -d: -f2)
          for dm_entry in /sys/block/dm-*; do
            local entry_devno
            entry_devno=$(cat "${dm_entry}/dev" 2>/dev/null || echo "")
            local entry_major entry_minor
            entry_major=$(echo "$entry_devno" | cut -d: -f1)
            entry_minor=$(echo "$entry_devno" | cut -d: -f2)
            if [ "$entry_major" = "$dm_major" ] && [ "$entry_minor" = "$dm_minor" ]; then
              local slaves_dir="${dm_entry}/slaves"
              if [ -d "$slaves_dir" ]; then
                local slave
                slave=$(ls "$slaves_dir" 2>/dev/null | head -1)
                if [ -n "$slave" ]; then
                  real_dev="/dev/${slave}"
                  break
                fi
              fi
            fi
          done
        fi
      fi
    fi

    local basename_dev
    basename_dev=$(basename "$real_dev")
    if echo "$basename_dev" | grep -qP 'p\d+$'; then
      basename_dev=$(echo "$basename_dev" | sed -E 's/p[0-9]+$//')
    else
      basename_dev=$(echo "$basename_dev" | sed -E 's/[0-9]+$//')
    fi
    local rota_file="/sys/block/${basename_dev}/queue/rotational"
    if [ -f "$rota_file" ]; then
      local rota
      rota=$(cat "$rota_file" 2>/dev/null || echo "1")
      if [ "$rota" = "0" ]; then
        disk_type="SSD"
      fi
    fi
  fi

  echo "  数据目录: ${data_dir}"
  echo "  所在设备: ${device:-未知}"
  echo "  磁盘类型: ${disk_type}"
  echo "  磁盘大小: ${disk_size_gb}GB"
  echo "  可用空间: ${disk_avail_mb}MB"

  DISK_TYPE=$disk_type
  DISK_SIZE_GB=$disk_size_gb
  DISK_AVAIL_MB=$disk_avail_mb
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

detect_redis() {
  title "Redis 当前状态"

  local redis_bin="${PREFIX_REDIS}/bin/redis-server"
  local redis_cli="${PREFIX_REDIS}/bin/redis-cli"

  if [ -x "$redis_bin" ]; then
    local redis_ver
    redis_ver=$("$redis_bin" --version 2>/dev/null | awk '{print $3}' || echo "未知")
    echo "  Redis 版本: ${redis_ver}"
    echo "  安装路径: ${PREFIX_REDIS}"
    echo "  配置文件: ${REDIS_CONF}"

    # 读取当前配置
    if [ -f "$REDIS_CONF" ]; then
      local current_maxmemory
      current_maxmemory=$(grep -E "^\s*maxmemory" "$REDIS_CONF" 2>/dev/null | awk '{print $2}' || echo "未设置")
      local current_maxmemory_policy
      current_maxmemory_policy=$(grep -E "^\s*maxmemory-policy" "$REDIS_CONF" 2>/dev/null | awk '{print $2}' || echo "未设置")
      local current_save
      current_save=$(grep -E "^\s*save" "$REDIS_CONF" 2>/dev/null | head -3 || echo "未设置")
      local current_appendonly
      current_appendonly=$(grep -E "^\s*appendonly" "$REDIS_CONF" 2>/dev/null | awk '{print $2}' || echo "未设置")

      echo "  当前 maxmemory: ${current_maxmemory}"
      echo "  当前 maxmemory-policy: ${current_maxmemory_policy}"
      echo "  当前 appendonly: ${current_appendonly}"
      echo "  当前 save 策略:"
      echo "$current_save" | while IFS= read -r line; do
        echo "    ${line}"
      done
    fi

    # 尝试连接运行时 Redis 获取更多信息
    if [ -x "$redis_cli" ]; then
      local conn_opts=("-p" "${REDIS_PORT}")
      # 尝试从配置中读取密码
      local requirepass
      requirepass=$(grep -E "^\s*requirepass" "$REDIS_CONF" 2>/dev/null | awk '{print $2}' || echo "")
      [ -n "$requirepass" ] && conn_opts+=("-a" "$requirepass")

      local redis_info
      redis_info=$("$redis_cli" "${conn_opts[@]}" INFO 2>/dev/null || echo "")
      if [ -n "$redis_info" ]; then
        local used_memory_human
        used_memory_human=$(echo "$redis_info" | grep "used_memory_human:" | cut -d: -f2 || echo "")
        local total_system_memory_human
        total_system_memory_human=$(echo "$redis_info" | grep "total_system_memory_human:" | cut -d: -f2 || echo "")
        local connected_clients
        connected_clients=$(echo "$redis_info" | grep "connected_clients:" | cut -d: -f2 || echo "")
        local uptime_in_days
        uptime_in_days=$(echo "$redis_info" | grep "uptime_in_days:" | cut -d: -f2 || echo "")

        echo ""
        echo "  运行时信息:"
        [ -n "$used_memory_human" ] && echo "    已用内存: ${used_memory_human}"
        [ -n "$total_system_memory_human" ] && echo "    系统内存: ${total_system_memory_human}"
        [ -n "$connected_clients" ] && echo "    当前连接: ${connected_clients}"
        [ -n "$uptime_in_days" ] && echo "    运行时间: ${uptime_in_days} 天"
      fi
    fi

    REDIS_INSTALLED=true
  else
    echo "  Redis 未安装或未在 ${PREFIX_REDIS} 找到"
    REDIS_INSTALLED=false
  fi
}

detect_system_limits() {
  title "系统限制检测"

  # 检测 THP 状态
  local thp_status=""
  if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    thp_status=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "未知")
    echo "  透明大页 (THP): ${thp_status}"
  else
    echo "  透明大页 (THP): 不支持或不可用"
  fi

  # 检测 overcommit_memory
  local overcommit
  overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo "未知")
  echo "  vm.overcommit_memory: ${overcommit}"

  # 检测 somaxconn
  local somaxconn
  somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo "未知")
  echo "  net.core.somaxconn: ${somaxconn}"

  # 检测 ulimit
  local ulimit_n
  ulimit_n=$(ulimit -n 2>/dev/null || echo "1024")
  echo "  文件描述符限制 (ulimit -n): ${ulimit_n}"

  # 检测 huge pages
  local hugepages_total
  hugepages_total=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo "0")
  echo "  预留大页 (HugePages): ${hugepages_total}"

  THP_STATUS=$thp_status
  OVERCOMMIT=$overcommit
  SOMAXCONN=$somaxconn
  ULIMIT_N=$ulimit_n
  HUGEPAGES=$hugepages_total
}

# ============================================================
# 配置计算模块
# ============================================================

calculate_optimizations() {
  title "计算优化参数"

  # ---- 运行模式检测 ----
  # 如果设置为 auto，尝试从配置文件中检测
  if [ "$REDIS_MODE" = "auto" ] && [ -f "$REDIS_CONF" ]; then
    if grep -qE "^\s*cluster-enabled\s+yes" "$REDIS_CONF" 2>/dev/null; then
      REDIS_MODE="cluster"
    elif grep -qE "^\s*sentinel" "$REDIS_CONF" 2>/dev/null || [ -f "/etc/redis/sentinel.conf" ]; then
      REDIS_MODE="sentinel"
    else
      REDIS_MODE="standalone"
    fi
    echo "  检测到运行模式: ${REDIS_MODE}"
  elif [ "$REDIS_MODE" = "auto" ]; then
    REDIS_MODE="standalone"
    echo "  未检测到现有配置，默认模式: ${REDIS_MODE}"
  else
    echo "  运行模式: ${REDIS_MODE}"
  fi

  # ---- maxmemory 计算 ----
  # 专用 Redis 服务器: 总内存的 80%
  # 共享服务器（运行其他服务）: 总内存的 50%
  # 这里使用 70% 作为平衡值
  local maxmemory_pct=70
  local maxmemory_bytes=$(( MEM_TOTAL_MB * maxmemory_pct / 100 * 1024 * 1024 ))

  # 限制最小 256MB
  local maxmemory_mb=$(( MEM_TOTAL_MB * maxmemory_pct / 100 ))
  if [ "$maxmemory_mb" -lt 256 ]; then
    maxmemory_mb=256
    maxmemory_bytes=$(( maxmemory_mb * 1024 * 1024 ))
  fi

  # 确保不超过可用磁盘空间（用于持久化）
  local max_disk_limit_mb=$(( DISK_AVAIL_MB * 80 / 100 ))
  if [ "$maxmemory_mb" -gt "$max_disk_limit_mb" ] && [ "$max_disk_limit_mb" -gt 256 ]; then
    maxmemory_mb=$max_disk_limit_mb
    maxmemory_bytes=$(( maxmemory_mb * 1024 * 1024 ))
  fi

  # ---- maxmemory-policy 选择 ----
  local maxmemory_policy="allkeys-lru"
  case "$REDIS_MODE" in
    cluster)
      # 集群模式: 使用 volatile-lru 避免 key 驱逐导致槽位迁移问题
      maxmemory_policy="volatile-lru"
      ;;
    sentinel)
      # 哨兵模式: 使用 allkeys-lru 最大化缓存效率
      maxmemory_policy="allkeys-lru"
      ;;
    standalone)
      # 单机模式: 根据内存大小选择
      if [ "$MEM_TOTAL_GB" -ge 32 ]; then
        # 大内存: 使用 allkeys-lfu（更精确的热点识别）
        maxmemory_policy="allkeys-lfu"
      elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
        maxmemory_policy="allkeys-lru"
      else
        # 小内存: 使用 volatile-lru 保证有 TTL 的 key 优先被淘汰
        maxmemory_policy="volatile-lru"
      fi
      ;;
  esac

  # maxmemory-samples（LRU/LFU 采样数，越大越精确但越耗 CPU）
  local maxmemory_samples=5
  if [ "$CPU_CORES" -ge 8 ]; then
    maxmemory_samples=10
  elif [ "$CPU_CORES" -ge 4 ]; then
    maxmemory_samples=7
  fi

  echo ""
  echo "  内存管理:"
  echo "    → maxmemory: ${maxmemory_mb}MB (总内存 ${MEM_TOTAL_GB}GB 的 ${maxmemory_pct}%)"
  echo "    → maxmemory-policy: ${maxmemory_policy}"
  echo "    → maxmemory-samples: ${maxmemory_samples}"

  # ---- 持久化策略 ----
  local save_config=""
  local appendonly="yes"
  local appendfsync="everysec"
  local auto_aof_rewrite_percentage=100
  local auto_aof_rewrite_min_size="64mb"
  local rdbcompression="yes"
  local rdbchecksum="yes"

  if [ "$DISK_TYPE" = "SSD" ]; then
    # SSD: 可以更频繁地持久化
    if [ "$MEM_TOTAL_GB" -ge 32 ]; then
      save_config='save 900 1\nsave 300 10\nsave 60 10000'
      auto_aof_rewrite_percentage=100
      auto_aof_rewrite_min_size="128mb"
    elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
      save_config='save 900 1\nsave 300 10\nsave 60 1000'
      auto_aof_rewrite_percentage=100
      auto_aof_rewrite_min_size="64mb"
    else
      save_config='save 900 1\nsave 300 10\nsave 60 100'
      auto_aof_rewrite_percentage=100
      auto_aof_rewrite_min_size="32mb"
    fi
  else
    # HDD: 减少持久化频率，避免磁盘 I/O 瓶颈
    if [ "$MEM_TOTAL_GB" -ge 32 ]; then
      save_config='save 3600 1\nsave 600 100\nsave 60 10000'
      auto_aof_rewrite_percentage=150
      auto_aof_rewrite_min_size="256mb"
    elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
      save_config='save 3600 1\nsave 600 100\nsave 60 1000'
      auto_aof_rewrite_percentage=150
      auto_aof_rewrite_min_size="128mb"
    else
      save_config='save 3600 1\nsave 600 10\nsave 60 100'
      auto_aof_rewrite_percentage=150
      auto_aof_rewrite_min_size="64mb"
    fi
  fi

  # 集群模式需要 AOF
  if [ "$REDIS_MODE" = "cluster" ]; then
    appendonly="yes"
    appendfsync="everysec"
  fi

  echo ""
  echo "  持久化:"
  echo "    → appendonly: ${appendonly}"
  echo "    → appendfsync: ${appendfsync}"
  echo "    → auto-aof-rewrite-percentage: ${auto_aof_rewrite_percentage}%"
  echo "    → auto-aof-rewrite-min-size: ${auto_aof_rewrite_min_size}"
  echo "    → 磁盘类型: ${DISK_TYPE}"

  # ---- 网络优化 ----
  local tcp_backlog=511
  local timeout=0
  local tcp_keepalive=300

  # 根据 somaxconn 调整 tcp-backlog
  if [ "$SOMAXCONN" != "未知" ] && [ "$SOMAXCONN" -gt 0 ]; then
    tcp_backlog=$SOMAXCONN
    [ "$tcp_backlog" -gt 65535 ] && tcp_backlog=65535
  fi

  # 根据内存调整 timeout
  if [ "$MEM_TOTAL_GB" -ge 32 ]; then
    timeout=0       # 大内存服务器，不主动断开连接
  elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
    timeout=300     # 5 分钟
  else
    timeout=600     # 10 分钟（小内存需要更早释放连接）
  fi

  echo ""
  echo "  网络:"
  echo "    → tcp-backlog: ${tcp_backlog}"
  echo "    → timeout: ${timeout}"
  echo "    → tcp-keepalive: ${tcp_keepalive}"

  # ---- 连接和客户端限制 ----
  local maxclients=10000
  local ulimit_max=$(( ULIMIT_N - 32 ))  # 为系统预留 32 个 FD
  if [ "$ulimit_max" -gt 0 ] && [ "$ulimit_max" -lt "$maxclients" ]; then
    maxclients=$ulimit_max
  fi
  [ "$maxclients" -lt 100 ] && maxclients=100
  [ "$maxclients" -gt 100000 ] && maxclients=100000

  echo ""
  echo "  连接限制:"
  echo "    → maxclients: ${maxclients}"

  # ---- 编码优化 ----
  local hash_max_ziplist_entries=512
  local hash_max_ziplist_value=64
  local list_max_ziplist_size=-2
  local list_compress_depth=0
  local set_max_intset_entries=512
  local zset_max_ziplist_entries=128
  local zset_max_ziplist_value=64

  if [ "$MEM_TOTAL_GB" -ge 32 ]; then
    # 大内存: 可以容忍更大的编码阈值
    hash_max_ziplist_entries=1024
    hash_max_ziplist_value=128
    set_max_intset_entries=1024
    zset_max_ziplist_entries=256
    zset_max_ziplist_value=128
  elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
    hash_max_ziplist_entries=512
    hash_max_ziplist_value=64
    set_max_intset_entries=512
    zset_max_ziplist_entries=128
    zset_max_ziplist_value=64
  fi

  echo ""
  echo "  编码优化:"
  echo "    → hash-max-ziplist-entries: ${hash_max_ziplist_entries}"
  echo "    → hash-max-ziplist-value: ${hash_max_ziplist_value}"
  echo "    → set-max-intset-entries: ${set_max_intset_entries}"
  echo "    → zset-max-ziplist-entries: ${zset_max_ziplist_entries}"

  # ---- 频率和延迟优化 ----
  local hz=10
  local dynamic_hz="yes"
  local lfu_log_factor=10
  local lfu_decay_time=1

  if [ "$CPU_CORES" -ge 8 ]; then
    hz=20        # 多核 CPU 可以承担更高的频率
    dynamic_hz="yes"
    lfu_log_factor=10
  elif [ "$CPU_CORES" -ge 4 ]; then
    hz=10
    dynamic_hz="yes"
    lfu_log_factor=10
  else
    hz=10
    dynamic_hz="yes"
    lfu_log_factor=5
  fi

  # 大内存需要更长的衰减时间
  if [ "$MEM_TOTAL_GB" -ge 32 ]; then
    lfu_decay_time=2
  elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
    lfu_decay_time=1
  else
    lfu_decay_time=1
  fi

  echo ""
  echo "  频率和延迟:"
  echo "    → hz: ${hz}"
  echo "    → dynamic-hz: ${dynamic_hz}"
  echo "    → lfu-log-factor: ${lfu_log_factor}"
  echo "    → lfu-decay-time: ${lfu_decay_time}"

  # ---- lazyfree 配置 ----
  local lazyfree_lazy_eviction="yes"
  local lazyfree_lazy_expire="yes"
  local lazyfree_lazy_server_del="yes"
  local replica_lazy_flush="yes"

  # 小内存服务器谨慎使用 lazyfree（可能增加内存碎片）
  if [ "$MEM_TOTAL_GB" -lt 4 ]; then
    lazyfree_lazy_eviction="no"
    lazyfree_lazy_expire="no"
    lazyfree_lazy_server_del="no"
    replica_lazy_flush="no"
  fi

  echo ""
  echo "  Lazy Free:"
  echo "    → lazyfree-lazy-eviction: ${lazyfree_lazy_eviction}"
  echo "    → lazyfree-lazy-expire: ${lazyfree_lazy_expire}"
  echo "    → lazyfree-lazy-server-del: ${lazyfree_lazy_server_del}"
  echo "    → replica-lazy-flush: ${replica_lazy_flush}"

  # ---- 慢查询日志 ----
  local slowlog_log_slower_than=10000
  local slowlog_max_len=128

  if [ "$MEM_TOTAL_GB" -ge 32 ]; then
    slowlog_log_slower_than=5000    # 大内存服务器，更敏感
    slowlog_max_len=256
  elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
    slowlog_log_slower_than=10000
    slowlog_max_len=128
  else
    slowlog_log_slower_than=20000
    slowlog_max_len=64
  fi

  echo ""
  echo "  慢查询日志:"
  echo "    → slowlog-log-slower-than: ${slowlog_log_slower_than} 微秒"
  echo "    → slowlog-max-len: ${slowlog_max_len}"

  # ---- 保存计算结果 ----
  MAXMEMORY_BYTES=$maxmemory_bytes
  MAXMEMORY_MB=$maxmemory_mb
  MAXMEMORY_POLICY=$maxmemory_policy
  MAXMEMORY_SAMPLES=$maxmemory_samples
  SAVE_CONFIG=$save_config
  APPENDONLY=$appendonly
  APPENDFSYNC=$appendfsync
  AOF_REWRITE_PCT=$auto_aof_rewrite_percentage
  AOF_REWRITE_MIN_SIZE=$auto_aof_rewrite_min_size
  RDBCOMPRESSION=$rdbcompression
  RDBCHECKSUM=$rdbchecksum
  TCP_BACKLOG=$tcp_backlog
  TIMEOUT=$timeout
  TCP_KEEPALIVE=$tcp_keepalive
  MAXCLIENTS=$maxclients
  HASH_MAX_ZIPLIST_ENTRIES=$hash_max_ziplist_entries
  HASH_MAX_ZIPLIST_VALUE=$hash_max_ziplist_value
  LIST_MAX_ZIPLIST_SIZE=$list_max_ziplist_size
  LIST_COMPRESS_DEPTH=$list_compress_depth
  SET_MAX_INTSET_ENTRIES=$set_max_intset_entries
  ZSET_MAX_ZIPLIST_ENTRIES=$zset_max_ziplist_entries
  ZSET_MAX_ZIPLIST_VALUE=$zset_max_ziplist_value
  HZ=$hz
  DYNAMIC_HZ=$dynamic_hz
  LFU_LOG_FACTOR=$lfu_log_factor
  LFU_DECAY_TIME=$lfu_decay_time
  LAZYFREE_EVICTION=$lazyfree_lazy_eviction
  LAZYFREE_EXPIRE=$lazyfree_lazy_expire
  LAZYFREE_SERVER_DEL=$lazyfree_lazy_server_del
  REPLICA_LAZY_FLUSH=$replica_lazy_flush
  SLOWLOG_SLOWER_THAN=$slowlog_log_slower_than
  SLOWLOG_MAX_LEN=$slowlog_max_len
}


# ============================================================
# 配置生成模块
# ============================================================

generate_redis_conf() {
  title "生成 Redis 优化配置"

  local gen_time tmp_conf save_tmp
  gen_time=$(date '+%Y-%m-%d %H:%M:%S')
  tmp_conf="/tmp/redis_optimized.conf"
  save_tmp=$(mktemp)
  printf '%b\n' "$SAVE_CONFIG" > "$save_tmp"

  {
    cat <<-CONFEOF
# ============================================================
# 优化后的 Redis 配置文件
# 生成时间: ${gen_time}
# 生成工具: optimize_redis.sh
# 硬件信息:
#   CPU: ${CPU_CORES} 核心
#   内存: ${MEM_TOTAL_MB}MB (${MEM_TOTAL_GB}GB)
#   磁盘: ${DISK_TYPE}
#   系统: ${OS_TYPE} ${OS_VERSION}
#   运行模式: ${REDIS_MODE}
# ============================================================

# ---- 网络 ----
bind ${REDIS_BIND}
port ${REDIS_PORT}
tcp-backlog ${TCP_BACKLOG}
timeout ${TIMEOUT}
tcp-keepalive ${TCP_KEEPALIVE}

# ---- 通用 ----
daemonize no
supervised auto
pidfile /var/run/redis_${REDIS_PORT}.pid
loglevel notice
logfile /var/log/redis/redis.log
databases 16
always-show-logo no
set-proc-title yes
proc-title-template "{title} {listen-addr} {server-mode}"

# ---- 内存 ----
maxmemory ${MAXMEMORY_BYTES}
maxmemory-policy ${MAXMEMORY_POLICY}
maxmemory-samples ${MAXMEMORY_SAMPLES}

# ---- 快照 (RDB) ----
CONFEOF
    cat "$save_tmp"
    cat <<-CONFEOF
stop-writes-on-bgsave-error yes
rdbcompression ${RDBCOMPRESSION}
rdbchecksum ${RDBCHECKSUM}
dbfilename dump.rdb
rdb-del-sync-files no
dir /var/lib/redis

# ---- AOF ----
appendonly ${APPENDONLY}
appendfsync ${APPENDFSYNC}
auto-aof-rewrite-percentage ${AOF_REWRITE_PCT}
auto-aof-rewrite-min-size ${AOF_REWRITE_MIN_SIZE}

# ---- 内存编码 ----
hash-max-ziplist-entries ${HASH_MAX_ZIPLIST_ENTRIES}
hash-max-ziplist-value ${HASH_MAX_ZIPLIST_VALUE}
list-max-ziplist-size ${LIST_MAX_ZIPLIST_SIZE}
list-compress-depth ${LIST_COMPRESS_DEPTH}
set-max-intset-entries ${SET_MAX_INTSET_ENTRIES}
zset-max-ziplist-entries ${ZSET_MAX_ZIPLIST_ENTRIES}
zset-max-ziplist-value ${ZSET_MAX_ZIPLIST_VALUE}

# ---- 性能 ----
hz ${HZ}
dynamic-hz ${DYNAMIC_HZ}
lfu-log-factor ${LFU_LOG_FACTOR}
lfu-decay-time ${LFU_DECAY_TIME}
lazyfree-lazy-eviction ${LAZYFREE_EVICTION}
lazyfree-lazy-expire ${LAZYFREE_EXPIRE}
lazyfree-lazy-server-del ${LAZYFREE_SERVER_DEL}
replica-lazy-flush ${REPLICA_LAZY_FLUSH}

# ---- 日志 ----
slowlog-log-slower-than ${SLOWLOG_SLOWER_THAN}
slowlog-max-len ${SLOWLOG_MAX_LEN}
CONFEOF

    if [ "${REDIS_MODE}" = "cluster" ]; then
      cat <<-CLUSTEREOF

# ---- 集群 ----
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 15000
cluster-require-full-coverage yes
CLUSTEREOF
    fi
  } > "$tmp_conf"

  rm -f "$save_tmp"
}


# ============================================================
# 系统参数优化模块
# ============================================================

apply_sysctl() {
  title "应用系统参数优化"

  local sysctl_applied=false

  # ---- 关闭透明大页 (THP) ----
  if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    local current_thp
    current_thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "")
    if [ "$current_thp" != "never" ]; then
      echo "  关闭透明大页 (THP)..."
      echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && ok "THP 已关闭" || warn "无法关闭 THP（需要 root 权限）"
      sysctl_applied=true
    else
      ok "THP 已经是 'never'"
    fi

    # 写入 rc.local 确保重启后生效
    if ! grep -q "transparent_hugepage/enabled" /etc/rc.local 2>/dev/null; then
      if [ -f /etc/rc.local ]; then
        echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.local 2>/dev/null || true
      fi
    fi
  fi

  # ---- 设置 vm.overcommit_memory ----
  local current_overcommit
  current_overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo "")
  if [ "$current_overcommit" != "1" ]; then
    echo "  设置 vm.overcommit_memory = 1..."
    sysctl -w vm.overcommit_memory=1 2>/dev/null && ok "overcommit_memory 已设置" || warn "无法设置 overcommit_memory（需要 root 权限）"
    sysctl_applied=true
  else
    ok "vm.overcommit_memory 已经是 1"
  fi

  # ---- 设置 vm.overcommit_ratio ----
  local current_ratio
  current_ratio=$(cat /proc/sys/vm/overcommit_ratio 2>/dev/null || echo "")
  if [ "$current_ratio" != "100" ]; then
    echo "  设置 vm.overcommit_ratio = 100..."
    sysctl -w vm.overcommit_ratio=100 2>/dev/null && ok "overcommit_ratio 已设置" || warn "无法设置 overcommit_ratio"
    sysctl_applied=true
  fi

  # ---- 增大 somaxconn ----
  local current_somaxconn
  current_somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo "")
  if [ "$current_somaxconn" != "65535" ] && [ "$current_somaxconn" -lt 65535 ]; then
    echo "  设置 net.core.somaxconn = 65535..."
    sysctl -w net.core.somaxconn=65535 2>/dev/null && ok "somaxconn 已设置" || warn "无法设置 somaxconn"
    sysctl_applied=true
  else
    ok "net.core.somaxconn 已经是 65535"
  fi

  # ---- 增大 net.ipv4.tcp_max_syn_backlog ----
  echo "  设置 net.ipv4.tcp_max_syn_backlog = 65535..."
  sysctl -w net.ipv4.tcp_max_syn_backlog=65535 2>/dev/null && ok "tcp_max_syn_backlog 已设置" || warn "无法设置 tcp_max_syn_backlog"

  # ---- 设置 net.core.rmem_max / wmem_max ----
  sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
  sysctl -w net.core.wmem_max=16777216 2>/dev/null || true

  # ---- 禁用 numa 内存迁移（如果可用） ----
  if [ -f /proc/sys/kernel/numa_balancing ]; then
    local current_numa
    current_numa=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo "")
    if [ "$current_numa" != "0" ]; then
      echo "  禁用 NUMA balancing..."
      sysctl -w kernel.numa_balancing=0 2>/dev/null && ok "NUMA balancing 已禁用" || warn "无法禁用 NUMA balancing"
      sysctl_applied=true
    fi
  fi

  # ---- 增大 vm.max_map_count ----
  local current_max_map
  current_max_map=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo "")
  if [ "$current_max_map" != "262144" ] && [ "$current_max_map" -lt 262144 ]; then
    echo "  设置 vm.max_map_count = 262144..."
    sysctl -w vm.max_map_count=262144 2>/dev/null && ok "max_map_count 已设置" || warn "无法设置 max_map_count"
    sysctl_applied=true
  fi

  # ---- 写入 sysctl.conf 持久化 ----
  local sysctl_conf="/etc/sysctl.d/99-redis.conf"
  if [ "$sysctl_applied" = true ]; then
    cat > "$sysctl_conf" << SYSCTLEOF
# Redis 优化参数 - 由 optimize_redis.sh 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# 内存管理
vm.overcommit_memory = 1
vm.overcommit_ratio = 100
vm.max_map_count = 262144

# 网络优化
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# NUMA
kernel.numa_balancing = 0
SYSCTLEOF
    ok "系统参数已持久化到 ${sysctl_conf}"
  fi

  # ---- 优化 ulimit ----
  local redis_ulimit_file="/etc/security/limits.d/99-redis.conf"
  if [ ! -f "$redis_ulimit_file" ]; then
    cat > "$redis_ulimit_file" << ULIMITEOF
# Redis 用户资源限制 - 由 optimize_redis.sh 生成
redis   soft    nofile    65536
redis   hard    nofile    65536
redis   soft    nproc     65536
redis   hard    nproc     65536
redis   soft    memlock   unlimited
redis   hard    memlock   unlimited
ULIMITEOF
    ok "Redis 用户 ulimit 已配置到 ${redis_ulimit_file}"
  else
    ok "Redis 用户 ulimit 已存在"
  fi

  echo ""
  echo "  系统参数优化完成。"
  echo "  注意: 部分参数需要重启 Redis 或重新登录才能生效。"
}

# ============================================================
# 备份模块
# ============================================================

backup_config() {
  title "备份当前配置"

  if [ ! -f "$REDIS_CONF" ]; then
    warn "当前配置文件 ${REDIS_CONF} 不存在，跳过备份"
    return
  fi

  mkdir -p "$BACKUP_DIR"

  local backup_file="${BACKUP_DIR}/redis.conf.backup.$(date '+%Y%m%d_%H%M%S')"
  cp "$REDIS_CONF" "$backup_file"
  ok "配置文件已备份到: ${backup_file}"

  # 清理旧备份（保留最近 10 个）
  local backup_count
  backup_count=$(ls -1 "${BACKUP_DIR}/redis.conf.backup."* 2>/dev/null | wc -l)
  if [ "$backup_count" -gt 10 ]; then
    ls -1t "${BACKUP_DIR}/redis.conf.backup."* 2>/dev/null | tail -n +11 | while IFS= read -r old_backup; do
      rm -f "$old_backup"
      debug "删除旧备份: ${old_backup}"
    done
    ok "已清理旧备份，保留最近 10 个"
  fi
}

# ============================================================
# 重启 Redis 模块
# ============================================================

restart_redis() {
  title "重启 Redis 服务"

  local redis_bin="${PREFIX_REDIS}/bin/redis-server"
  local redis_cli="${PREFIX_REDIS}/bin/redis-cli"

  if [ ! -x "$redis_bin" ]; then
    error "Redis 可执行文件不存在: ${redis_bin}"
    return 1
  fi

  # 检查 systemd 服务
  if systemctl is-active redis >/dev/null 2>&1; then
    echo "  通过 systemd 重启 Redis..."
    if systemctl restart redis 2>/dev/null; then
      ok "Redis 已通过 systemd 重启"
      return 0
    else
      warn "systemd 重启失败，尝试直接启动..."
    fi
  fi

  # 尝试通过 redis-cli 关闭
  if [ -x "$redis_cli" ]; then
    echo "  通过 redis-cli 发送 SHUTDOWN 命令..."
    $redis_cli -p "$REDIS_PORT" SHUTDOWN 2>/dev/null || true
    sleep 1
  fi

  # 检查是否还有残留进程
  local pid_file="/var/run/redis_${REDIS_PORT}.pid"
  if [ -f "$pid_file" ]; then
    local old_pid
    old_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      echo "  强制终止旧 Redis 进程 (PID: ${old_pid})..."
      kill "$old_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$old_pid" 2>/dev/null || true
    fi
  fi

  # 启动 Redis
  echo "  启动 Redis..."
  if "$redis_bin" "$REDIS_CONF" > /dev/null 2>&1 & then
    sleep 2
    # 验证启动
    if $redis_cli -p "$REDIS_PORT" PING 2>/dev/null | grep -q "PONG"; then
      ok "Redis 已成功启动"
      return 0
    else
      error "Redis 启动失败，请检查日志"
      return 1
    fi
  else
    error "Redis 启动命令失败"
    return 1
  fi
}

# ============================================================
# 主流程
# ============================================================

main() {
  title "Redis 配置优化工具"
  echo "  开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  # 检测硬件
  detect_cpu
  detect_memory
  detect_disk
  detect_os
  detect_system_limits
  detect_redis

  # 计算优化参数
  calculate_optimizations

  # 如果只是显示信息，则退出
  if [ "$SHOW_ONLY" = true ]; then
    echo ""
    info "已显示硬件信息和推荐配置。使用 --dry-run 可查看完整配置文件。"
    exit 0
  fi

  # 生成配置文件
  generate_redis_conf

  # 如果是 dry-run 模式，显示配置并退出
  if [ "$DRY_RUN" = true ]; then
    echo ""
    info "===== 优化后的配置文件预览 ====="
    cat /tmp/redis_optimized.conf
    echo ""
    info "以上为优化后的配置预览。移除 --dry-run 参数以实际应用。"
    exit 0
  fi

  # 确认提示
  if [ "$FORCE" = false ]; then
    echo ""
    warn "即将应用优化配置到: ${REDIS_CONF}"
    echo ""
    read -r -p "是否继续? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo ""
      info "已取消优化。"
      exit 0
    fi
  fi

  # 备份当前配置
  backup_config

  # 应用新配置
  echo ""
  echo "  应用新配置到 ${REDIS_CONF}..."
  cp /tmp/redis_optimized.conf "$REDIS_CONF"
  ok "新配置已写入 ${REDIS_CONF}"

  # 设置权限
  if [ -f "$REDIS_CONF" ]; then
    chmod 644 "$REDIS_CONF" 2>/dev/null || true
  fi

  # 应用系统参数优化
  if [ "$APPLY_SYSCTL" = true ]; then
    apply_sysctl
  fi

  # 重启 Redis
  echo ""
  if [ "$FORCE" = true ]; then
    restart_redis || warn "Redis 重启失败，请手动检查。"
  else
    read -r -p "是否重启 Redis 以应用新配置? [y/N] " restart_confirm
    if [[ "$restart_confirm" =~ ^[Yy]$ ]]; then
      restart_redis
    else
      info "请手动重启 Redis 以应用新配置。"
    fi
  fi

  # 显示优化摘要
  echo ""
  title "优化摘要"
  echo "  CPU: ${CPU_CORES} 核心"
  echo "  内存: ${MEM_TOTAL_MB}MB (${MEM_TOTAL_GB}GB)"
  echo "  磁盘: ${DISK_TYPE}"
  echo "  运行模式: ${REDIS_MODE}"
  echo "  maxmemory: ${MAXMEMORY_MB}MB"
  echo "  maxmemory-policy: ${MAXMEMORY_POLICY}"
  echo "  maxclients: ${MAXCLIENTS}"
  echo "  appendonly: ${APPENDONLY}"
  echo "  tcp-backlog: ${TCP_BACKLOG}"
  echo "  timeout: ${TIMEOUT}"
  echo "  hz: ${HZ}"
  echo ""
  echo "  配置文件: ${REDIS_CONF}"
  if [ "$APPLY_SYSCTL" = true ]; then
    echo "  系统参数: 已优化"
  else
    echo "  系统参数: 未优化（使用 --apply-sysctl 可同时优化系统参数）"
  fi
  echo ""
  ok "优化完成！"
}

# ============================================================
# 入口
# ============================================================

parse_flags "$@"
main
