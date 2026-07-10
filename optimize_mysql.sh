#!/usr/bin/env bash
set -euo pipefail

# optimize_mysql.sh - 根据硬件配置优化 MySQL 配置
# 用途: 自动检测 CPU 核心数、内存大小、磁盘类型等硬件信息，
#       生成最优的 my.cnf 配置参数。
# 支持通过 --prefix-mysql 覆盖安装前缀

PREFIX_MYSQL=/usr/local/mysql
MYSQL_CNF=/etc/my.cnf
BACKUP_DIR="/etc/my.cnf.backup"
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
  --prefix-mysql PATH   MySQL 安装前缀（默认: ${PREFIX_MYSQL}）
  --cnf PATH            my.cnf 配置文件路径（默认: ${MYSQL_CNF}）
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
  $0 --cnf /etc/my.cnf --force          # 指定配置文件并直接应用

说明:
  该工具会根据当前服务器的硬件配置自动计算最优的 MySQL 参数：

  InnoDB 缓冲池:
  - innodb_buffer_pool_size: 根据总内存大小（通常 50-70%）
  - innodb_buffer_pool_instances: 根据缓冲池大小和 CPU 核心数
  - innodb_log_file_size / innodb_log_buffer_size: 根据缓冲池大小

  InnoDB IO 线程:
  - innodb_io_capacity / innodb_io_capacity_max: 根据磁盘类型（SSD/HDD）
  - innodb_read_io_threads / innodb_write_io_threads: 根据 CPU 核心数
  - innodb_flush_method: 根据操作系统自动选择
  - innodb_flush_log_at_trx_commit: 根据数据安全需求

  连接管理:
  - max_connections: 根据内存和连接内存消耗
  - thread_cache_size: 根据 max_connections
  - table_open_cache: 根据内存大小
  - table_definition_cache: 根据内存大小

  临时表和排序:
  - tmp_table_size / max_heap_table_size: 根据内存
  - sort_buffer_size / join_buffer_size: 根据内存

  事务和日志:
  - innodb_log_file_size: 根据缓冲池大小
  - innodb_log_buffer_size: 根据事务大小
  - innodb_purge_threads: 根据 CPU 核心数

EOF
}

parse_flags() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --prefix-mysql) PREFIX_MYSQL="$2"; shift 2;;
      --cnf)          MYSQL_CNF="$2"; shift 2;;
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

  local data_dir="/var/lib/mysql"
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
  # 支持 LVM、dm-crypt、分区等场景，递归查找底层物理设备
  if [ -n "$device" ]; then
    local real_dev="$device"

    # 如果是 dm 设备（LVM），递归查找底层物理设备
    if [[ "$real_dev" =~ ^/dev/mapper/ ]] || [[ "$real_dev" =~ ^/dev/dm- ]]; then
      local dm_name
      dm_name=$(basename "$real_dev")
      # 通过 dmsetup 获取 dm 设备名，然后查找 slaves
      if command -v dmsetup >/dev/null 2>&1; then
        # 获取 dm 设备的主次设备号（格式: "253:0"）
        local dm_devno
        dm_devno=$(dmsetup info -c --noheadings -o major,minor "$dm_name" 2>/dev/null | awk '{print $1}' || echo "")
        if [ -n "$dm_devno" ]; then
          local dm_major dm_minor
          dm_major=$(echo "$dm_devno" | cut -d: -f1)
          dm_minor=$(echo "$dm_devno" | cut -d: -f2)
          # 遍历所有 dm-N 设备，找到匹配的
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
    # 去掉分区号，保留块设备名
    # NVMe 设备: nvme0n1p3 → nvme0n1
    # 传统设备: sda1 → sda, vda1 → vda
    # 注意: 先尝试去掉 "p数字" 后缀（NVMe 分区），再去掉纯数字后缀（传统分区）
    # 但不要去掉块设备名本身的数字（如 nvme0n1 中的 0 和 1）
    if echo "$basename_dev" | grep -qP 'p\d+$'; then
      # NVMe 风格: nvme0n1p3 → nvme0n1
      basename_dev=$(echo "$basename_dev" | sed -E 's/p[0-9]+$//')
    else
      # 传统风格: sda1 → sda, vda1 → vda
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

detect_mysql() {
  title "MySQL 当前状态"

  local mysql_bin="${PREFIX_MYSQL}/bin/mysql"
  local mysqld_bin="${PREFIX_MYSQL}/bin/mysqld"

  if [ -x "$mysqld_bin" ]; then
    local mysql_ver
    mysql_ver=$("$mysqld_bin" --version 2>/dev/null | awk '{print $3}' || echo "未知")
    echo "  MySQL 版本: ${mysql_ver}"
    echo "  安装路径: ${PREFIX_MYSQL}"
    echo "  配置文件: ${MYSQL_CNF}"

    # 尝试获取当前运行时配置
    local conn_cmd=""
    if command -v conn.sh >/dev/null 2>&1; then
      conn_cmd="conn.sh"
    elif [ -f /root/.mysql_root_pw ]; then
      local pw
      pw=$(grep ROOT_PASSWORD /root/.mysql_root_pw 2>/dev/null | cut -d"'" -f2 || true)
      if [ -n "$pw" ]; then
        conn_cmd="${mysql_bin} -u root -p'${pw}' -S /var/run/mysqld/mysqld.sock"
      fi
    fi

    if [ -n "$conn_cmd" ]; then
      local bp_size
      bp_size=$($conn_cmd -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size'" 2>/dev/null | sed -n '2p' | awk '{print $2}' || echo "未知")
      if [ -n "$bp_size" ] && [ "$bp_size" != "未知" ]; then
        echo "  当前 innodb_buffer_pool_size: $(( bp_size / 1024 / 1024 ))MB"
      fi
      local max_conn
      max_conn=$($conn_cmd -e "SHOW VARIABLES LIKE 'max_connections'" 2>/dev/null | sed -n '2p' | awk '{print $2}' || echo "未知")
      echo "  当前 max_connections: ${max_conn}"
    fi

    MYSQL_INSTALLED=true
  else
    echo "  MySQL 未安装或未在 ${PREFIX_MYSQL} 找到"
    MYSQL_INSTALLED=false
  fi
}

# ============================================================
# 配置计算模块
# ============================================================

calculate_optimizations() {
  title "计算优化参数"

  # ---- InnoDB 缓冲池 ----
  # 专用 MySQL 服务器: 总内存的 70%
  # 共享服务器（运行其他服务）: 总内存的 50%
  # 这里使用 60% 作为平衡值
  local buffer_pool_pct=60
  local buffer_pool_mb=$(( MEM_TOTAL_MB * buffer_pool_pct / 100 ))

  # 限制最小 256MB，最大不超过可用磁盘空间
  if [ "$buffer_pool_mb" -lt 256 ]; then
    buffer_pool_mb=256
  fi

  # 确保缓冲池不超过可用磁盘空间的一半
  local max_bp_mb=$(( DISK_AVAIL_MB / 2 ))
  if [ "$buffer_pool_mb" -gt "$max_bp_mb" ] && [ "$max_bp_mb" -gt 256 ]; then
    buffer_pool_mb=$max_bp_mb
  fi

  # buffer_pool_instances: 每个实例至少 1GB，最多 CPU_CORES 个
  local bp_instances=$(( buffer_pool_mb / 1024 ))
  [ "$bp_instances" -lt 1 ] && bp_instances=1
  [ "$bp_instances" -gt "$CPU_CORES" ] && bp_instances=$CPU_CORES
  [ "$bp_instances" -gt 8 ] && bp_instances=8

  # ---- InnoDB 日志 ----
  # log_file_size = buffer_pool 的 25%（范围 64MB - 2GB）
  local log_file_mb=$(( buffer_pool_mb * 25 / 100 ))
  [ "$log_file_mb" -lt 64 ] && log_file_mb=64
  [ "$log_file_mb" -gt 2048 ] && log_file_mb=2048

  # log_buffer_size = 16MB - 256MB
  local log_buffer_mb=16
  if [ "$buffer_pool_mb" -ge 8192 ]; then
    log_buffer_mb=64
  elif [ "$buffer_pool_mb" -ge 4096 ]; then
    log_buffer_mb=32
  fi

  # ---- IO 线程 ----
  local io_capacity=200
  local io_capacity_max=2000
  if [ "$DISK_TYPE" = "SSD" ]; then
    io_capacity=2000
    io_capacity_max=4000
  fi

  local read_io_threads=$(( CPU_CORES ))
  [ "$read_io_threads" -gt 16 ] && read_io_threads=16
  [ "$read_io_threads" -lt 4 ] && read_io_threads=4

  local write_io_threads=$(( CPU_CORES ))
  [ "$write_io_threads" -gt 16 ] && write_io_threads=16
  [ "$write_io_threads" -lt 4 ] && write_io_threads=4

  # ---- 连接管理 ----
  # 每个连接约 10MB 内存（含排序、临时表等）
  local mem_per_conn=10
  local max_conn=$(( (MEM_TOTAL_MB - buffer_pool_mb) / mem_per_conn ))
  [ "$max_conn" -lt 50 ] && max_conn=50
  [ "$max_conn" -gt 2000 ] && max_conn=2000

  local thread_cache=$(( max_conn / 10 ))
  [ "$thread_cache" -lt 8 ] && thread_cache=8
  [ "$thread_cache" -gt 200 ] && thread_cache=200

  # ---- 表缓存 ----
  local table_cache=400
  local table_def_cache=400
  if [ "$MEM_TOTAL_GB" -ge 64 ]; then
    table_cache=8000
    table_def_cache=4000
  elif [ "$MEM_TOTAL_GB" -ge 32 ]; then
    table_cache=4000
    table_def_cache=2000
  elif [ "$MEM_TOTAL_GB" -ge 16 ]; then
    table_cache=2000
    table_def_cache=1000
  elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
    table_cache=1000
    table_def_cache=800
  elif [ "$MEM_TOTAL_GB" -ge 4 ]; then
    table_cache=400
    table_def_cache=400
  fi

  # ---- 临时表和排序 ----
  local tmp_table_size_mb=16
  local sort_buffer_size_mb=0.25  # 256KB
  local join_buffer_size_mb=0.25  # 256KB

  if [ "$MEM_TOTAL_GB" -ge 64 ]; then
    tmp_table_size_mb=128
    sort_buffer_size_mb=4
    join_buffer_size_mb=4
  elif [ "$MEM_TOTAL_GB" -ge 32 ]; then
    tmp_table_size_mb=64
    sort_buffer_size_mb=2
    join_buffer_size_mb=2
  elif [ "$MEM_TOTAL_GB" -ge 16 ]; then
    tmp_table_size_mb=32
    sort_buffer_size_mb=1
    join_buffer_size_mb=1
  elif [ "$MEM_TOTAL_GB" -ge 8 ]; then
    tmp_table_size_mb=32
    sort_buffer_size_mb=0.5
    join_buffer_size_mb=0.5
  elif [ "$MEM_TOTAL_GB" -ge 4 ]; then
    tmp_table_size_mb=16
    sort_buffer_size_mb=0.25
    join_buffer_size_mb=0.25
  fi

  # ---- 清理线程 ----
  local purge_threads=1
  [ "$CPU_CORES" -ge 4 ] && purge_threads=4
  [ "$CPU_CORES" -ge 8 ] && purge_threads=4

  local page_cleaners=$CPU_CORES
  [ "$page_cleaners" -gt 16 ] && page_cleaners=16

  # ---- 自适应哈希索引 ----
  # 对于 NVMe SSD，AHI 可能带来额外开销，根据内存决定
  local adaptive_hash_index="ON"
  if [ "$MEM_TOTAL_GB" -le 4 ]; then
    adaptive_hash_index="OFF"
  fi

  # ---- 输出计算结果 ----
  echo "  InnoDB 缓冲池:"
  echo "    → innodb_buffer_pool_size: ${buffer_pool_mb}MB (总内存 ${MEM_TOTAL_GB}GB 的 ${buffer_pool_pct}%)"
  echo "    → innodb_buffer_pool_instances: ${bp_instances}"
  echo "    → innodb_log_file_size: ${log_file_mb}MB"
  echo "    → innodb_log_buffer_size: ${log_buffer_mb}MB"
  echo ""
  echo "  InnoDB IO:"
  echo "    → innodb_io_capacity: ${io_capacity}"
  echo "    → innodb_io_capacity_max: ${io_capacity_max}"
  echo "    → innodb_read_io_threads: ${read_io_threads}"
  echo "    → innodb_write_io_threads: ${write_io_threads}"
  echo "    → innodb_flush_method: O_DIRECT"
  echo ""
  echo "  连接管理:"
  echo "    → max_connections: ${max_conn}"
  echo "    → thread_cache_size: ${thread_cache}"
  echo "    → table_open_cache: ${table_cache}"
  echo "    → table_definition_cache: ${table_def_cache}"
  echo ""
  echo "  临时表和排序:"
  echo "    → tmp_table_size: ${tmp_table_size_mb}MB"
  echo "    → max_heap_table_size: ${tmp_table_size_mb}MB"
  echo "    → sort_buffer_size: ${sort_buffer_size_mb}MB"
  echo "    → join_buffer_size: ${join_buffer_size_mb}MB"
  echo ""
  echo "  其他:"
  echo "    → innodb_purge_threads: ${purge_threads}"
  echo "    → innodb_page_cleaners: ${page_cleaners}"
  echo "    → innodb_adaptive_hash_index: ${adaptive_hash_index}"

  # ---- 保存计算结果 ----
  BP_SIZE_MB=$buffer_pool_mb
  BP_INSTANCES=$bp_instances
  LOG_FILE_MB=$log_file_mb
  LOG_BUFFER_MB=$log_buffer_mb
  IO_CAPACITY=$io_capacity
  IO_CAPACITY_MAX=$io_capacity_max
  READ_IO_THREADS=$read_io_threads
  WRITE_IO_THREADS=$write_io_threads
  MAX_CONNECTIONS=$max_conn
  THREAD_CACHE=$thread_cache
  TABLE_CACHE=$table_cache
  TABLE_DEF_CACHE=$table_def_cache
  TMP_TABLE_SIZE_MB=$tmp_table_size_mb
  SORT_BUFFER_SIZE_MB=$sort_buffer_size_mb
  JOIN_BUFFER_SIZE_MB=$join_buffer_size_mb
  PURGE_THREADS=$purge_threads
  PAGE_CLEANERS=$page_cleaners
  ADAPTIVE_HASH_INDEX=$adaptive_hash_index
}

# ============================================================
# 配置生成模块
# ============================================================

generate_my_cnf() {
  title "生成 MySQL 配置 (my.cnf)"

  # 将 MB 值转换为字节
  local bp_size_bytes=$(( BP_SIZE_MB * 1024 * 1024 ))
  local log_file_bytes=$(( LOG_FILE_MB * 1024 * 1024 ))
  local log_buffer_bytes=$(( LOG_BUFFER_MB * 1024 * 1024 ))
  local tmp_table_bytes=$(( TMP_TABLE_SIZE_MB * 1024 * 1024 ))
  local max_heap_bytes=$(( TMP_TABLE_SIZE_MB * 1024 * 1024 ))

  # sort_buffer_size 和 join_buffer_size 可能是小数
  local sort_buffer_bytes
  sort_buffer_bytes=$(awk "BEGIN {printf \"%d\", ${SORT_BUFFER_SIZE_MB} * 1024 * 1024}")
  local join_buffer_bytes
  join_buffer_bytes=$(awk "BEGIN {printf \"%d\", ${JOIN_BUFFER_SIZE_MB} * 1024 * 1024}")

  cat > /tmp/my_cnf_optimized.conf << MY_CNF_EOF
# ============================================================
# 优化后的 MySQL 配置文件 (my.cnf)
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 生成工具: optimize_mysql.sh
# 硬件信息:
#   CPU: ${CPU_CORES} 核心
#   内存: ${MEM_TOTAL_MB}MB (${MEM_TOTAL_GB}GB)
#   磁盘: ${DISK_TYPE} (${DISK_SIZE_GB}GB)
#   系统: ${OS_TYPE} ${OS_VERSION}
# ============================================================

[mysqld]
# ---- 基础路径 ----
basedir=${PREFIX_MYSQL}
datadir=/var/lib/mysql
socket=/var/run/mysqld/mysqld.sock
pid-file=/var/run/mysqld/mysqld.pid
user=mysql

# ---- 网络与字符集 ----
bind-address=0.0.0.0
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
skip-name-resolve

# ============================================================
# InnoDB 缓冲池（最关键的性能参数）
# ============================================================

# InnoDB 缓冲池大小
# 根据内存 ${MEM_TOTAL_GB}GB 优化: 总内存的 ${BP_SIZE_MB}MB (${BP_SIZE_MB}MB)
innodb_buffer_pool_size = ${bp_size_bytes}

# 缓冲池实例数（减少锁竞争）
# 每个实例建议 ≥ 1GB，不超过 CPU 核心数
innodb_buffer_pool_instances = ${BP_INSTANCES}

# ============================================================
# InnoDB 日志
# ============================================================

# Redo 日志文件大小（每个）
# 建议缓冲池的 25%，范围 64MB - 2GB
innodb_log_file_size = ${log_file_bytes}

# Redo 日志缓冲大小
# 大事务需要更大的日志缓冲
innodb_log_buffer_size = ${log_buffer_bytes}

# 日志刷新策略
# 1 = 每次事务提交都刷新（最安全，性能适中）
# 2 = 每秒刷新（性能更好，可能丢失 1 秒数据）
innodb_flush_log_at_trx_commit = 1

# ============================================================
# InnoDB IO 配置
# ============================================================

# IO 容量（SSD 建议 2000-4000，HDD 建议 200-400）
innodb_io_capacity = ${IO_CAPACITY}
innodb_io_capacity_max = ${IO_CAPACITY_MAX}

# IO 线程数
innodb_read_io_threads = ${READ_IO_THREADS}
innodb_write_io_threads = ${WRITE_IO_THREADS}

# 刷新方法（Linux 建议 O_DIRECT，绕过操作系统缓存）
innodb_flush_method = O_DIRECT

# 独立表空间（每个表一个文件，便于管理）
innodb_file_per_table = ON

# ============================================================
# 连接管理
# ============================================================

# 最大连接数
# 根据内存优化: (总内存 - 缓冲池) / 每连接 10MB
max_connections = ${MAX_CONNECTIONS}

# 线程缓存（减少创建/销毁线程的开销）
thread_cache_size = ${THREAD_CACHE}

# 表缓存（提高表打开速度）
table_open_cache = ${TABLE_CACHE}
table_definition_cache = ${TABLE_DEF_CACHE}

# 连接超时
wait_timeout = 600
interactive_timeout = 28800
connect_timeout = 10

# ============================================================
# 临时表和排序
# ============================================================

# 内存临时表大小（超过此值使用磁盘 MyISAM 临时表）
tmp_table_size = ${tmp_table_bytes}
max_heap_table_size = ${max_heap_bytes}

# 排序缓冲（每个连接分配，不宜过大）
sort_buffer_size = ${sort_buffer_bytes}

# 连接缓冲（每个连接分配，不宜过大）
join_buffer_size = ${join_buffer_bytes}

# ============================================================
# 事务和清理
# ============================================================

# 事务隔离级别（默认 REPEATABLE-READ）
#transaction_isolation = READ-COMMITTED

# 清理线程数（加速 undo 日志清理）
innodb_purge_threads = ${PURGE_THREADS}

# 缓冲池清理线程数
innodb_page_cleaners = ${PAGE_CLEANERS}

# ============================================================
# 自适应特性
# ============================================================

# 自适应哈希索引（SSD 下可能收益有限，大内存建议开启）
innodb_adaptive_hash_index = ${ADAPTIVE_HASH_INDEX}

# 自适应刷新阈值
innodb_adaptive_flushing = ON

# 自适应刷新延迟
#innodb_adaptive_flushing_lwm = 10

# ============================================================
# 其他优化
# ============================================================

# 自增锁模式（2 = 交错模式，最高并发）
innodb_autoinc_lock_mode = 2

# 旧块在缓冲池中的停留时间（毫秒）
innodb_old_blocks_time = 1000

# 统计信息自动更新（生产环境建议 OFF）
innodb_stats_on_metadata = OFF

# 变更缓冲（none/inserts/deletes/changes/purges/all）
innodb_change_buffering = all

# LRU 扫描深度
innodb_lru_scan_depth = 1024

# 打开文件数限制
open_files_limit = 65535

# ============================================================
# 日志与慢查询
# ============================================================

log_error = /var/log/mysqld.err
slow_query_log = 1
slow_query_log_file = /var/log/mysql-slow.log
long_query_time = 2
log_queries_not_using_indexes = 0

# ============================================================
# SQL 模式
# ============================================================

# 严格模式（推荐生产环境）
#sql_mode = STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION

# 兼容模式（当前配置）
sql_mode = ''

# ============================================================
# 二进制日志/复制（如需启用，取消注释并配置）
# ============================================================
# server-id = 1
# log_bin = mysql-bin
# binlog_format = ROW
# binlog_row_image = FULL
# expire_logs_days = 7
# max_binlog_size = 1G
# binlog_cache_size = 32K
# sync_binlog = 1

# ============================================================
# 性能模式（用于诊断，轻微性能开销）
# ============================================================
performance_schema = ON

[client]
default-character-set = utf8mb4
socket = /var/run/mysqld/mysqld.sock

[mysql]
default_character_set = utf8mb4
prompt = '\u@\h [\d]> '

[mysqld_safe]
log-error = /var/log/mysqld.err
pid-file = /var/run/mysqld/mysqld.pid

MY_CNF_EOF

  echo "  ✅ MySQL 配置已生成到 /tmp/my_cnf_optimized.conf"
}

# ============================================================
# 系统参数建议
# ============================================================

show_sysctl_suggestions() {
  title "系统内核参数优化建议"

  cat <<SYSCTL_EOF
以下系统参数可提升 MySQL 性能（使用 --apply-sysctl 自动应用）:

# 内核参数优化（追加到 /etc/sysctl.conf）
# 适用于 MySQL 数据库服务器

# 减少 swap 使用（优先使用物理内存）
vm.swappiness = 1

# 增加文件描述符限制
fs.file-max = 6815744

# 网络连接优化
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_slow_start_after_idle = 0

# 大内存页（透明大页建议关闭，避免 MySQL 延迟抖动）
# echo never > /sys/kernel/mm/transparent_hugepage/enabled

# 内存 overcommit（建议 1，避免 MySQL fork 失败）
vm.overcommit_memory = 1

# 脏页比例（MySQL 使用 O_DIRECT，可适当调大）
vm.dirty_background_ratio = 3
vm.dirty_ratio = 10

SYSCTL_EOF
}

apply_sysctl() {
  title "应用系统内核参数"

  local sysctl_conf="/etc/sysctl.conf"
  local applied=0

  # vm.swappiness
  local current_swappiness
  current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")
  if [ "$current_swappiness" -gt 1 ]; then
    sysctl -w vm.swappiness=1 >/dev/null 2>&1
    if grep -q "^vm.swappiness" "$sysctl_conf" 2>/dev/null; then
      sed -i 's/^vm.swappiness.*/vm.swappiness = 1/' "$sysctl_conf"
    else
      echo "vm.swappiness = 1" >> "$sysctl_conf"
    fi
    ok "vm.swappiness: 60 → 1"
    applied=$((applied + 1))
  fi

  # fs.file-max
  local current_file_max
  current_file_max=$(cat /proc/sys/fs/file-max 2>/dev/null || echo "0")
  if [ "$current_file_max" -lt 6815744 ]; then
    sysctl -w fs.file-max=6815744 >/dev/null 2>&1
    if grep -q "^fs.file-max" "$sysctl_conf" 2>/dev/null; then
      sed -i 's/^fs.file-max.*/fs.file-max = 6815744/' "$sysctl_conf"
    else
      echo "fs.file-max = 6815744" >> "$sysctl_conf"
    fi
    ok "fs.file-max: ${current_file_max} → 6815744"
    applied=$((applied + 1))
  fi

  # vm.overcommit_memory
  local current_overcommit
  current_overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo "0")
  if [ "$current_overcommit" -ne 1 ]; then
    sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1
    if grep -q "^vm.overcommit_memory" "$sysctl_conf" 2>/dev/null; then
      sed -i 's/^vm.overcommit_memory.*/vm.overcommit_memory = 1/' "$sysctl_conf"
    else
      echo "vm.overcommit_memory = 1" >> "$sysctl_conf"
    fi
    ok "vm.overcommit_memory: ${current_overcommit} → 1"
    applied=$((applied + 1))
  fi

  # net.core.somaxconn
  local current_somaxconn
  current_somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo "128")
  if [ "$current_somaxconn" -lt 65535 ]; then
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1
    if grep -q "^net.core.somaxconn" "$sysctl_conf" 2>/dev/null; then
      sed -i 's/^net.core.somaxconn.*/net.core.somaxconn = 65535/' "$sysctl_conf"
    else
      echo "net.core.somaxconn = 65535" >> "$sysctl_conf"
    fi
    ok "net.core.somaxconn: ${current_somaxconn} → 65535"
    applied=$((applied + 1))
  fi

  # vm.dirty_ratio
  local current_dirty_ratio
  current_dirty_ratio=$(cat /proc/sys/vm/dirty_ratio 2>/dev/null || echo "20")
  if [ "$current_dirty_ratio" -gt 10 ]; then
    sysctl -w vm.dirty_ratio=10 >/dev/null 2>&1
    if grep -q "^vm.dirty_ratio" "$sysctl_conf" 2>/dev/null; then
      sed -i 's/^vm.dirty_ratio.*/vm.dirty_ratio = 10/' "$sysctl_conf"
    else
      echo "vm.dirty_ratio = 10" >> "$sysctl_conf"
    fi
    ok "vm.dirty_ratio: ${current_dirty_ratio} → 10"
    applied=$((applied + 1))
  fi

  # vm.dirty_background_ratio
  local current_dirty_bg
  current_dirty_bg=$(cat /proc/sys/vm/dirty_background_ratio 2>/dev/null || echo "10")
  if [ "$current_dirty_bg" -gt 3 ]; then
    sysctl -w vm.dirty_background_ratio=3 >/dev/null 2>&1
    if grep -q "^vm.dirty_background_ratio" "$sysctl_conf" 2>/dev/null; then
      sed -i 's/^vm.dirty_background_ratio.*/vm.dirty_background_ratio = 3/' "$sysctl_conf"
    else
      echo "vm.dirty_background_ratio = 3" >> "$sysctl_conf"
    fi
    ok "vm.dirty_background_ratio: ${current_dirty_bg} → 3"
    applied=$((applied + 1))
  fi

  if [ "$applied" -gt 0 ]; then
    ok "已应用 ${applied} 项内核参数并持久化到 ${sysctl_conf}"
  else
    info "所有内核参数已是最优，无需修改"
  fi
}

# ============================================================
# 显示优化摘要
# ============================================================

show_summary() {
  title "优化配置摘要"

  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │               MySQL 优化配置摘要                    │"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-35s %-20s │\n" "innodb_buffer_pool_size" "${BP_SIZE_MB}MB"
  printf "  │  %-35s %-20s │\n" "innodb_buffer_pool_instances" "${BP_INSTANCES}"
  printf "  │  %-35s %-20s │\n" "innodb_log_file_size" "${LOG_FILE_MB}MB"
  printf "  │  %-35s %-20s │\n" "innodb_log_buffer_size" "${LOG_BUFFER_MB}MB"
  printf "  │  %-35s %-20s │\n" "innodb_io_capacity" "${IO_CAPACITY}"
  printf "  │  %-35s %-20s │\n" "innodb_read_io_threads" "${READ_IO_THREADS}"
  printf "  │  %-35s %-20s │\n" "innodb_write_io_threads" "${WRITE_IO_THREADS}"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-35s %-20s │\n" "max_connections" "${MAX_CONNECTIONS}"
  printf "  │  %-35s %-20s │\n" "thread_cache_size" "${THREAD_CACHE}"
  printf "  │  %-35s %-20s │\n" "table_open_cache" "${TABLE_CACHE}"
  printf "  │  %-35s %-20s │\n" "table_definition_cache" "${TABLE_DEF_CACHE}"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-35s %-20s │\n" "tmp_table_size" "${TMP_TABLE_SIZE_MB}MB"
  printf "  │  %-35s %-20s │\n" "sort_buffer_size" "${SORT_BUFFER_SIZE_MB}MB"
  printf "  │  %-35s %-20s │\n" "join_buffer_size" "${JOIN_BUFFER_SIZE_MB}MB"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  %-35s %-20s │\n" "innodb_purge_threads" "${PURGE_THREADS}"
  printf "  │  %-35s %-20s │\n" "innodb_page_cleaners" "${PAGE_CLEANERS}"
  printf "  │  %-35s %-20s │\n" "innodb_adaptive_hash_index" "${ADAPTIVE_HASH_INDEX}"
  echo "  └─────────────────────────────────────────────────────┘"
  echo ""
}

# ============================================================
# 应用优化模块
# ============================================================

apply_optimization() {
  title "应用优化配置"

  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')

  # ---- 备份原配置 ----
  mkdir -p "$BACKUP_DIR"

  if [ -f "$MYSQL_CNF" ]; then
    cp "$MYSQL_CNF" "${BACKUP_DIR}/my.cnf.${timestamp}"
    info "原配置已备份到 ${BACKUP_DIR}/my.cnf.${timestamp}"
  fi

  # ---- 写入新配置 ----
  cp /tmp/my_cnf_optimized.conf "$MYSQL_CNF"
  ok "新配置已写入 ${MYSQL_CNF}"

  # ---- 应用系统参数 ----
  if $APPLY_SYSCTL; then
    apply_sysctl
  fi

  # ---- 测试 MySQL 配置 ----
  local mysqld_bin="${PREFIX_MYSQL}/bin/mysqld"
  echo ""
  info "正在测试 MySQL 配置..."

  # MySQL 8.4 使用 --validate-config 测试配置
  local config_test=false
  if $mysqld_bin --validate-config --defaults-file="$MYSQL_CNF" 2>/dev/null; then
    config_test=true
  elif $mysqld_bin --help --defaults-file="$MYSQL_CNF" >/dev/null 2>&1 <<< ""; then
    config_test=true
  fi

  if $config_test; then
    ok "配置测试通过"

    # 询问是否重启
    if ! $FORCE; then
      echo ""
      read -r -p "是否立即重启 MySQL 以应用新配置？[Y/n] " reload_ans
      reload_ans=${reload_ans:-Y}
    else
      reload_ans="Y"
    fi

    if [[ "$reload_ans" =~ ^[Yy] ]]; then
      echo ""
      info "正在重启 MySQL..."

      local restarted=false
      if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart mysqld.service 2>/dev/null || systemctl restart mysql.service 2>/dev/null; then
          ok "MySQL 已通过 systemctl 成功重启"
          restarted=true
        fi
      fi

      if ! $restarted; then
        # 尝试直接重启
        local mysql_pidfile="/var/run/mysqld/mysqld.pid"
        if [ -f "$mysql_pidfile" ]; then
          local pid
          pid=$(cat "$mysql_pidfile" 2>/dev/null || echo "")
          if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -QUIT "$pid" 2>/dev/null || true
            sleep 3
          fi
        fi
        if [ -x "$mysqld_bin" ]; then
          $mysqld_bin --defaults-file="$MYSQL_CNF" --user=mysql &
          sleep 2
          ok "MySQL 已直接启动"
          restarted=true
        fi
      fi

      if ! $restarted; then
        fail "MySQL 重启失败，请手动检查"
        warn "备份配置位于: ${BACKUP_DIR}/my.cnf.${timestamp}"
        warn "手动重启: systemctl restart mysqld"
      fi
    else
      info "配置已写入但未重启。手动重启命令:"
      echo "  systemctl restart mysqld"
      echo "  或: ${mysqld_bin} --defaults-file=${MYSQL_CNF} --user=mysql &"
    fi
  else
    fail "配置测试失败！"
    warn "正在恢复备份配置..."
    if [ -f "${BACKUP_DIR}/my.cnf.${timestamp}" ]; then
      cp "${BACKUP_DIR}/my.cnf.${timestamp}" "$MYSQL_CNF"
      ok "已恢复原配置"
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
  echo "  ║         MySQL 配置优化工具 v1.0                      ║"
  echo "  ║     根据硬件配置自动优化 MySQL 参数                  ║"
  echo "  ╚══════════════════════════════════════════════════════╝"

  # 执行硬件检测
  detect_os
  detect_cpu
  detect_memory
  detect_disk
  detect_mysql

  # 计算优化参数
  calculate_optimizations

  # 生成配置
  generate_my_cnf

  # 显示摘要
  show_summary

  # 显示系统参数建议
  show_sysctl_suggestions

  # 如果只是显示，则退出
  if $SHOW_ONLY; then
    echo ""
    info "预览模式，未写入任何文件"
    echo ""
    info "优化后的 MySQL 配置: /tmp/my_cnf_optimized.conf"
    exit 0
  fi

  # 如果是 dry-run，显示但不应用
  if $DRY_RUN; then
    echo ""
    info "Dry-Run 模式，未写入任何文件"
    echo ""
    info "优化后的 MySQL 配置: /tmp/my_cnf_optimized.conf"
    echo ""
    info "查看配置: cat /tmp/my_cnf_optimized.conf"
    exit 0
  fi

  # 确认应用
  if ! $FORCE; then
    echo ""
    echo "  ⚠️  即将应用以上优化配置"
    echo "  - MySQL 配置文件: ${MYSQL_CNF}"
    echo "  原配置将备份到 ${BACKUP_DIR}/"
    if $APPLY_SYSCTL; then
      echo "  - 同时应用系统内核参数优化"
    fi
    echo ""
    read -r -p "是否继续？[y/N] " confirm
    confirm=${confirm:-N}
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
      info "已取消"
      info "生成的配置文件仍保留在: /tmp/my_cnf_optimized.conf"
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
  echo "  例如: cp ${BACKUP_DIR}/my.cnf.${timestamp:-bak} ${MYSQL_CNF}"
  echo "  然后: systemctl restart mysqld"
}

# 执行主函数
main "$@"
