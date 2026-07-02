#!/usr/bin/env bash
# shellcheck disable=SC2317
set -euo pipefail

# =============================================================================
# install_redis_centos10.sh
# 一键编译安装 Redis（适用于 CentOS Stream 10）
# 用法: sudo bash install_redis_centos10.sh [OPTIONS]
# =============================================================================

# ---- 可配置变量 ----
REDIS_VERSION="7.2.6"
PREFIX_REDIS="/usr/local/redis"
BUILD_DIR="/usr/local/src/build_redis"
PARALLEL_MAKE="$(nproc 2>/dev/null || echo 1)"
REDIS_PORT=6379
REDIS_BIND="127.0.0.1"
REQUIREPASS=""
MODIFY_SECURITY=true
SKIP_DEPS=0
FORCE=0

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}==>${NC} $*"; }

# ---- 辅助函数 ----
die() { error "$1"; exit "${2:-1}"; }

safe_run() {
  local desc="$1"; shift
  if ! "$@"; then die "${desc} 失败"; fi
}

usage() {
  cat <<EOF
用法: $0 [OPTIONS]

选项:
  --version VER         Redis 版本（默认: ${REDIS_VERSION}）
  --prefix PATH         安装前缀（默认: ${PREFIX_REDIS}）
  --build-dir PATH      构建目录（默认: ${BUILD_DIR}）
  --jobs N              make 并行数（默认: ${PARALLEL_MAKE}）
  --requirepass PASS    设置 Redis 访问密码
  --port N              监听端口（默认: ${REDIS_PORT}）
  --bind ADDR           绑定地址（默认: ${REDIS_BIND}）
  --no-modify-security  不修改 firewall/SELinux 设置
  --skip-deps           跳过依赖安装
  --force               强制重新编译安装
  -h, --help            显示本帮助
EOF
  exit 0
}

# ---- 参数解析 ----
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)           REDIS_VERSION="$2"; shift 2 ;;
      --prefix)            PREFIX_REDIS="$2"; shift 2 ;;
      --build-dir)         BUILD_DIR="$2"; shift 2 ;;
      --jobs)              PARALLEL_MAKE="$2"; shift 2 ;;
      --requirepass)       REQUIREPASS="$2"; shift 2 ;;
      --port)              REDIS_PORT="$2"; shift 2 ;;
      --bind)              REDIS_BIND="$2"; shift 2 ;;
      --no-modify-security) MODIFY_SECURITY=false; shift ;;
      --skip-deps)         SKIP_DEPS=1; shift ;;
      --force)             FORCE=1; shift ;;
      -h|--help)           usage ;;
      *) die "未知参数: $1" 2 ;;
    esac
  done
}

# ---- 自动提权 ----
auto_sudo() {
  if [ "$EUID" -ne 0 ]; then
    warn "非 root 用户，尝试通过 sudo 重新执行..."
    exec sudo bash "$0" "$@"
  fi
}

# =============================================================================
# 步骤 1：安装编译依赖
# =============================================================================
install_build_deps() {
  step "安装编译依赖"
  if [ "${SKIP_DEPS}" -eq 1 ]; then
    info "跳过依赖安装 (--skip-deps)"
    return
  fi
  safe_run "安装编译工具链" dnf install -y gcc make jemalloc-devel tcl wget curl tar xz
}

# =============================================================================
# 步骤 2：创建 redis 用户和目录
# =============================================================================
create_user_and_dirs() {
  step "创建 redis 用户和目录"

  getent group redis >/dev/null 2>&1 || groupadd -r redis
  id -u redis >/dev/null 2>&1 || useradd -r -g redis -s /sbin/nologin -M redis

  mkdir -p /etc/redis /var/lib/redis /var/log/redis /var/run/redis
  chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis 2>/dev/null || true
}

# =============================================================================
# 步骤 3：下载并编译 Redis
# =============================================================================
download_and_build() {
  step "下载并编译 Redis ${REDIS_VERSION}"

  mkdir -p "${BUILD_DIR}"
  local tarball="redis-${REDIS_VERSION}.tar.gz"
  local url="https://download.redis.io/releases/${tarball}"
  local src_dir="${BUILD_DIR}/redis-${REDIS_VERSION}"

  # 下载源码包
  if [ ! -f "${BUILD_DIR}/${tarball}" ]; then
    info "正在下载 ${url}"
    safe_run "下载 Redis 源码" wget -c "${url}" -O "${BUILD_DIR}/${tarball}"
  else
    info "已存在 ${tarball}，跳过下载"
  fi

  # 如果源码目录已存在且 --force，则清理
  if [ -d "${src_dir}" ]; then
    if [ "${FORCE}" -eq 1 ]; then
      warn "强制模式：清理已有源码目录"
      rm -rf "${src_dir}"
    else
      info "源码目录已存在，跳过解压（使用 --force 强制重新解压）"
    fi
  fi

  # 解压
  if [ ! -d "${src_dir}" ]; then
    safe_run "解压源码包" tar xzf "${BUILD_DIR}/${tarball}" -C "${BUILD_DIR}"
  fi

  cd "${src_dir}"

  # 如果已编译且 --force，清理旧编译产物
  if [ -f "src/redis-server" ] && [ "${FORCE}" -eq 1 ]; then
    warn "强制模式：清理旧编译产物"
    make distclean 2>/dev/null || true
  fi

  # 编译
  if [ ! -f "src/redis-server" ]; then
    info "编译中（${PARALLEL_MAKE} 线程）..."
    safe_run "编译 Redis" make -j"${PARALLEL_MAKE}"
  else
    info "已编译，跳过编译步骤（使用 --force 强制重新编译）"
  fi

  # 安装到 PREFIX
  info "安装到 ${PREFIX_REDIS}..."
  mkdir -p "${PREFIX_REDIS}/bin"
  safe_run "安装 Redis 二进制" make install PREFIX="${PREFIX_REDIS}"

  # 创建符号链接到 /usr/local/bin
  info "创建符号链接到 /usr/local/bin..."
  for cmd in "${PREFIX_REDIS}/bin/"*; do
    if [ -f "${cmd}" ] && [ -x "${cmd}" ]; then
      ln -sf "${cmd}" "/usr/local/bin/$(basename "${cmd}")" 2>/dev/null || true
    fi
  done
}

# =============================================================================
# 步骤 4：生成配置文件和 systemd 单元
# =============================================================================
install_config_and_systemd() {
  step "生成配置文件和 systemd 单元"

  local conf="/etc/redis/redis.conf"
  local src_conf="${BUILD_DIR}/redis-${REDIS_VERSION}/redis.conf"

  # 生成配置文件
  if [ -f "${conf}" ] && [ "${FORCE}" -eq 0 ]; then
    info "配置文件 ${conf} 已存在，保留原文件（使用 --force 覆盖）"
  else
    if [ "${FORCE}" -eq 1 ] && [ -f "${conf}" ]; then
      warn "强制模式：覆盖 ${conf}"
    fi

    # 优先使用源码中的默认配置
    if [ -f "${src_conf}" ]; then
      cp "${src_conf}" "${conf}"
      info "已从源码复制默认配置"
    else
      # 创建最小配置
      cat > "${conf}" <<EOF
# Redis 配置文件 - 由 install_redis_centos10.sh 生成
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
      info "已创建最小配置"
    fi

    # 统一调整关键配置项
    local config_map=(
      "supervised:supervised systemd"
      "daemonize:daemonize no"
      "dir:dir /var/lib/redis"
      "logfile:logfile /var/log/redis/redis.log"
      "bind:bind ${REDIS_BIND}"
      "port:port ${REDIS_PORT}"
    )

    for entry in "${config_map[@]}"; do
      local key="${entry%%:*}"
      local value="${entry#*:}"
      if grep -q "^${key}" "${conf}" 2>/dev/null; then
        sed -i "s|^${key} .*|${value}|" "${conf}"
      elif grep -q "^# ${key}" "${conf}" 2>/dev/null; then
        sed -i "s|^# ${key} .*|${value}|" "${conf}"
      else
        echo "${value}" >> "${conf}"
      fi
    done

    # 设置密码
    if [ -n "${REQUIREPASS}" ]; then
      if grep -q "^requirepass" "${conf}" 2>/dev/null; then
        sed -i "s|^requirepass .*|requirepass ${REQUIREPASS}|" "${conf}"
      elif grep -q "^# requirepass" "${conf}" 2>/dev/null; then
        sed -i "s|^# requirepass .*|requirepass ${REQUIREPASS}|" "${conf}"
      else
        echo "requirepass ${REQUIREPASS}" >> "${conf}"
      fi
    fi

    info "配置文件已生成: ${conf}"
  fi

  # systemd 单元
  step "写入 systemd 单元"

  cat > /etc/systemd/system/redis.service <<UNIT
[Unit]
Description=Redis In-Memory Data Store ${REDIS_VERSION}
Documentation=https://redis.io/documentation
After=network.target

[Service]
Type=simple
User=redis
Group=redis
ExecStart=/usr/local/bin/redis-server ${conf}
ExecStop=/usr/local/bin/redis-cli -p ${REDIS_PORT} shutdown
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
LimitNOFILE=10032
LimitNPROC=65535
PrivateTmp=true
TimeoutSec=300

[Install]
WantedBy=multi-user.target
UNIT

  info "systemd 单元已写入: /etc/systemd/system/redis.service"

  # 启动服务
  step "启动 Redis 服务"
  systemctl daemon-reload
  systemctl enable --now redis.service || warn "Redis 服务启动失败，请检查日志"
}

# =============================================================================
# 步骤 5：调整防火墙
# =============================================================================
adjust_firewall() {
  if [ "${MODIFY_SECURITY}" = false ]; then
    info "跳过防火墙配置 (--no-modify-security)"
    return
  fi

  step "配置防火墙"

  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --list-ports 2>/dev/null | grep -q "${REDIS_PORT}/tcp"; then
      info "端口 ${REDIS_PORT}/tcp 已开放，跳过"
    else
      safe_run "开放防火墙端口" firewall-cmd --permanent --add-port="${REDIS_PORT}/tcp"
      safe_run "重载防火墙规则" firewall-cmd --reload
      info "防火墙端口 ${REDIS_PORT}/tcp 已开放"
    fi
  else
    warn "未检测到 firewall-cmd，跳过防火墙配置"
  fi
}

# =============================================================================
# 步骤 6：验证安装
# =============================================================================
verify() {
  step "验证安装"

  # 等待服务就绪
  info "等待 Redis 服务就绪..."
  for i in $(seq 1 15); do
    if systemctl is-active --quiet redis.service 2>/dev/null; then
      info "Redis 服务已就绪（${i}s）"
      break
    fi
    if [ "${i}" -eq 15 ]; then
      warn "Redis 服务未在预期时间内就绪，请检查日志: journalctl -u redis -e"
    fi
    sleep 1
  done

  # 显示服务状态
  systemctl status redis --no-pager || true

  # 测试连接
  if command -v redis-cli >/dev/null 2>&1; then
    echo ""
    info "测试 Redis 连接..."
    if [ -n "${REQUIREPASS}" ]; then
      redis-cli -a "${REQUIREPASS}" -p "${REDIS_PORT}" ping 2>&1 || warn "PING 测试失败"
    else
      redis-cli -p "${REDIS_PORT}" ping 2>&1 || warn "PING 测试失败"
    fi
  fi
}

# =============================================================================
# 完成输出
# =============================================================================
print_summary() {
  echo ""
  info "========================================"
  info "  Redis ${REDIS_VERSION} 安装完成！"
  info "========================================"
  echo ""
  info "服务管理命令："
  echo "  sudo systemctl status redis     # 查看服务状态"
  echo "  sudo systemctl start redis      # 启动服务"
  echo "  sudo systemctl stop redis       # 停止服务"
  echo "  sudo systemctl restart redis    # 重启服务"
  echo ""
  info "配置文件："
  echo "  /etc/redis/redis.conf"
  echo ""
  info "数据目录："
  echo "  /var/lib/redis"
  echo ""
  info "日志文件："
  echo "  /var/log/redis/redis.log"
  echo ""
  info "连接 Redis："
  if [ -n "${REQUIREPASS}" ]; then
    echo "  redis-cli -a '${REQUIREPASS}' -p ${REDIS_PORT}"
  else
    echo "  redis-cli -p ${REDIS_PORT}"
  fi
  echo ""
}

# =============================================================================
# 主入口
# =============================================================================
main() {
  parse_args "$@"
  auto_sudo "$@"

  install_build_deps
  create_user_and_dirs
  download_and_build
  install_config_and_systemd
  adjust_firewall
  verify
  print_summary
}

main "$@"
