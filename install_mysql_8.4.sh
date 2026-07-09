#!/usr/bin/env bash
# shellcheck disable=SC2317  # 部分函数被间接调用
set -euo pipefail

# =============================================================================
# install_mysql_8.4.sh
# 一键在 CentOS/RHEL 10 上安装 MySQL 二进制包（8.4.9）
# 用法: sudo bash install_mysql_8.4.sh [OPTIONS]
# =============================================================================

# ---- 可配置变量（用户可按需修改） ----
MYSQL_VERSION="8.4.9"
MYSQL_URL="https://cdn.mysql.com//Downloads/MySQL-${MYSQL_VERSION%.*}/mysql-${MYSQL_VERSION}-linux-glibc2.28-x86_64.tar.xz"
MYSQL_TAR="/usr/local/src/$(basename "${MYSQL_URL}")"
BASEDIR="/usr/local/mysql"
DATADIR="/var/lib/mysql"
RUN_USER="mysql"
RUN_GROUP="mysql"
SYSTEMD_UNIT="/etc/systemd/system/mysqld.service"
PROFILE_D="/etc/profile.d/mysql.sh"
SOCKET_FILE="/var/run/mysqld/mysqld.sock"
PID_FILE="/var/run/mysqld/mysqld.pid"
LOG_ERROR="/var/log/mysqld.err"
SLOW_QUERY_LOG="/var/log/mysql-slow.log"

# ---- 选项默认值 ----
AUTO_SECURE=0
OPEN_FIREWALL=0
SELINUX_ADJUST=0
ROOT_PW=""
SKIP_DEPS=0
FORCE=0

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}==>${NC} $*"; }

# =============================================================================
# 辅助函数
# =============================================================================

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --secure             安装完成后交互运行 mysql_secure_installation
  --open-firewall      自动添加 firewall-cmd 规则开放 MySQL 服务
  --selinux-adjust     为 MySQL 数据目录设置 SELinux 上下文（需要 semanage）
  --set-root-pw PW     非交互设置 root 密码为 PW
  --skip-deps          跳过依赖安装步骤
  --force              强制重新安装（覆盖已有目录/配置）
  -h, --help           显示此帮助信息
EOF
}

die() {
  error "$1"
  exit "${2:-1}"
}

# 检查命令是否存在
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "缺少必要命令: $1"
  fi
}

# 安全地执行命令，失败时给出明确提示
safe_run() {
  local desc="$1"
  shift
  if ! "$@"; then
    die "${desc} 失败，请检查错误信息"
  fi
}

# =============================================================================
# 参数解析
# =============================================================================

while [ "$#" -gt 0 ]; do
  case "$1" in
    --secure)        AUTO_SECURE=1; shift ;;
    --open-firewall) OPEN_FIREWALL=1; shift ;;
    --selinux-adjust) SELINUX_ADJUST=1; shift ;;
    --set-root-pw)   shift; ROOT_PW="$1"; shift ;;
    --skip-deps)     SKIP_DEPS=1; shift ;;
    --force)         FORCE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "未知参数: $1" 2 ;;
  esac
done

# ---- 自动提权 ----
if [ "$EUID" -ne 0 ]; then
  warn "非 root 用户，尝试通过 sudo 重新执行..."
  exec sudo bash "$0" "$@"
fi

# =============================================================================
# 步骤 1：安装系统依赖
# =============================================================================

step "安装系统依赖"
if [ "${SKIP_DEPS}" -eq 0 ]; then
  safe_run "安装系统依赖" dnf install -y wget libaio numactl xz
else
  info "跳过依赖安装 (--skip-deps)"
fi

# =============================================================================
# 步骤 2：下载 MySQL 二进制包
# =============================================================================

step "准备目录与下载包"
mkdir -p /usr/local/src

if [ ! -f "${MYSQL_TAR}" ]; then
  info "正在下载 ${MYSQL_URL}"
  wget -O "${MYSQL_TAR}" "${MYSQL_URL}" || die "下载失败: ${MYSQL_URL}"
else
  info "已存在 ${MYSQL_TAR}，跳过下载"
fi

# =============================================================================
# 步骤 3：解压并安装到目标目录
# =============================================================================

step "解压并安装到 ${BASEDIR}"

# 计算 tar 包内顶层目录名（使用 sed 在读取第一行后退出，避免 SIGPIPE）
DIRNAME=$(tar -tf "${MYSQL_TAR}" 2>/dev/null | sed -n '1p' | cut -f1 -d"/")
[ -z "${DIRNAME}" ] && die "无法解析 tar 包目录结构"

# 如果目标目录已存在
if [ -d "${BASEDIR}" ]; then
  if [ "${FORCE}" -eq 1 ]; then
    warn "强制模式：删除现有 ${BASEDIR}"
    rm -rf "${BASEDIR}"
  else
    info "${BASEDIR} 已存在，跳过解压（使用 --force 强制覆盖）"
  fi
fi

if [ ! -d "${BASEDIR}" ]; then
  # 如果已经提前解压到了 /usr/local/src，直接移动
  if [ -d "/usr/local/src/${DIRNAME}" ]; then
    info "检测到 /usr/local/src/${DIRNAME}，直接移动到 ${BASEDIR}"
    mv "/usr/local/src/${DIRNAME}" "${BASEDIR}"
  else
    safe_run "解压二进制包" tar -xJf "${MYSQL_TAR}" -C /usr/local/src
    if [ -d "/usr/local/src/${DIRNAME}" ]; then
      mv "/usr/local/src/${DIRNAME}" "${BASEDIR}"
    else
      die "解压后未找到目录 /usr/local/src/${DIRNAME}"
    fi
  fi
fi

# =============================================================================
# 步骤 4：创建 mysql 用户与数据目录
# =============================================================================

step "创建 mysql 用户与数据目录"

getent group "${RUN_GROUP}" >/dev/null || groupadd -r "${RUN_GROUP}"
getent passwd "${RUN_USER}" >/dev/null || useradd -r -g "${RUN_GROUP}" -s /sbin/nologin "${RUN_USER}"

mkdir -p "${DATADIR}"
chown -R "${RUN_USER}:${RUN_GROUP}" "${BASEDIR}" "${DATADIR}"

# =============================================================================
# 步骤 5：初始化数据库
# =============================================================================

step "初始化数据库（insecure 模式：初始 root 无密码）"

if [ -z "$(ls -A "${DATADIR}" 2>/dev/null)" ]; then
  safe_run "数据库初始化" "${BASEDIR}/bin/mysqld" \
    --initialize-insecure \
    --basedir="${BASEDIR}" \
    --datadir="${DATADIR}" \
    --user="${RUN_USER}"
else
  if [ "${FORCE}" -eq 1 ]; then
    warn "强制模式：清空数据目录 ${DATADIR}"
    rm -rf "${DATADIR:?}"/*
    safe_run "数据库初始化" "${BASEDIR}/bin/mysqld" \
      --initialize-insecure \
      --basedir="${BASEDIR}" \
      --datadir="${DATADIR}" \
      --user="${RUN_USER}"
  else
    info "数据目录非空，跳过初始化（使用 --force 强制重新初始化）"
  fi
fi

# =============================================================================
# 步骤 6：生成 /etc/my.cnf
# =============================================================================

step "生成 /etc/my.cnf"

if [ -f /etc/my.cnf ] && [ "${FORCE}" -eq 0 ]; then
  info "/etc/my.cnf 已存在，保留原文件（使用 --force 覆盖）"
else
  if [ "${FORCE}" -eq 1 ] && [ -f /etc/my.cnf ]; then
    warn "强制模式：覆盖 /etc/my.cnf"
  fi

  cat > /etc/my.cnf <<MYCNF
[mysqld]
# 基础路径
basedir=${BASEDIR}
datadir=${DATADIR}
socket=${SOCKET_FILE}
pid-file=${PID_FILE}
user=${RUN_USER}

# 网络与字符集
bind-address=0.0.0.0
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
skip-name-resolve

# InnoDB（根据机器内存调整 innodb_buffer_pool_size）
innodb_file_per_table=1
innodb_flush_method=O_DIRECT
innodb_buffer_pool_size=512M
innodb_log_file_size=128M
innodb_buffer_pool_instances=1

# 连接与缓存
max_connections=200
thread_cache_size=100
table_open_cache=400

# 日志与慢查询
log_error=${LOG_ERROR}
slow_query_log=1
slow_query_log_file=${SLOW_QUERY_LOG}
long_query_time=2

# SQL 模式
sql_mode=''

# 二进制日志/复制（如需启用，取消注释并配置）
# server-id=1
# log_bin=mysql-bin
# binlog_format=ROW
# expire_logs_days=7

[client]
default-character-set=utf8mb4
socket=${SOCKET_FILE}

[mysql]
default_character_set=utf8mb4

[mysqld_safe]
log-error=${LOG_ERROR}
pid-file=${PID_FILE}
MYCNF

  info "/etc/my.cnf 已创建，建议根据服务器内存调整 innodb_buffer_pool_size"
fi

# =============================================================================
# 步骤 7：写入 systemd 单元
# =============================================================================

step "写入 systemd 单元"

cat > "${SYSTEMD_UNIT}" <<UNIT
[Unit]
Description=MySQL Server ${MYSQL_VERSION}
Documentation=https://dev.mysql.com/doc/refman/${MYSQL_VERSION%.*}/en/
After=network.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
ExecStart=${BASEDIR}/bin/mysqld --defaults-file=/etc/my.cnf
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=5000
LimitNPROC=65535
Restart=on-failure
RestartSec=5
TimeoutSec=300
PrivateTmp=true

# 自动创建 /run/mysqld 目录并设置所有权
RuntimeDirectory=mysqld
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
UNIT

info "systemd 单元已写入: ${SYSTEMD_UNIT}"

# =============================================================================
# 步骤 8：确保日志与运行目录存在并设置权限
# =============================================================================

step "确保日志与运行目录存在并设置权限"

mkdir -p /var/log /var/run/mysqld

# 错误日志
touch "${LOG_ERROR}" 2>/dev/null || true
chown "${RUN_USER}:${RUN_GROUP}" "${LOG_ERROR}" 2>/dev/null || true

# 慢查询日志
touch "${SLOW_QUERY_LOG}" 2>/dev/null || true
chown "${RUN_USER}:${RUN_GROUP}" "${SLOW_QUERY_LOG}" 2>/dev/null || true
chmod 0640 "${SLOW_QUERY_LOG}" 2>/dev/null || true

# 运行目录
chown "${RUN_USER}:${RUN_GROUP}" /var/run/mysqld 2>/dev/null || true

# 配置 tmpfiles.d 确保重启后 /run/mysqld 目录自动创建并设置正确权限
cat > /etc/tmpfiles.d/mysql.conf <<TMPF
d /run/mysqld 0755 ${RUN_USER} ${RUN_GROUP} -
TMPF
info "tmpfiles.d 配置已写入: /etc/tmpfiles.d/mysql.conf"

# =============================================================================
# 步骤 9：启动 MySQL 服务
# =============================================================================

step "重新加载 systemd 并启动 mysqld"

systemctl daemon-reload
systemctl enable --now mysqld

# 等待服务就绪
info "等待 MySQL 服务就绪..."
for i in $(seq 1 30); do
  if [ -S "${SOCKET_FILE}" ]; then
    info "MySQL socket 已就绪（${i}s）"
    break
  fi
  if [ "${i}" -eq 30 ]; then
    warn "MySQL socket 未在预期时间内就绪，请检查日志: journalctl -u mysqld -e"
  fi
  sleep 1
done

# 检查服务状态
if ! systemctl is-active --quiet mysqld; then
  warn "MySQL 服务未正常运行，请检查日志: journalctl -u mysqld -e"
  systemctl status mysqld --no-pager || true
fi

# =============================================================================
# 步骤 10：设置 root 密码（可选）
# =============================================================================

if [ -n "${ROOT_PW}" ]; then
  step "非交互设置 root 密码"

  if [ -S "${SOCKET_FILE}" ]; then
    "${BASEDIR}/bin/mysql" -u root -S "${SOCKET_FILE}" \
      -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}'; FLUSH PRIVILEGES;" || \
      warn "无法通过 socket 设置 root 密码，请稍后手动运行 mysql_secure_installation"
    info "root 密码已设置"
  else
    warn "socket 文件不存在，跳过设置 root 密码"
  fi
fi

# =============================================================================
# 步骤 11：添加 MySQL 到系统 PATH
# =============================================================================

step "添加 MySQL 到系统 PATH"

# 方式一：创建符号链接到 /usr/local/bin（立即生效，所有用户可用）
info "创建 MySQL 命令符号链接到 /usr/local/bin..."
MYSQL_BIN="${BASEDIR}/bin"
if [ -d "${MYSQL_BIN}" ]; then
  for cmd in "${MYSQL_BIN}"/*; do
    cmd_name=$(basename "${cmd}")
    # 只链接可执行文件，跳过目录
    if [ -f "${cmd}" ] && [ -x "${cmd}" ]; then
      ln -sf "${cmd}" "/usr/local/bin/${cmd_name}" 2>/dev/null || true
    fi
  done
  info "MySQL 命令已链接到 /usr/local/bin，当前会话即可使用"
fi

# 方式二：写入 profile.d（新登录 shell 生效）
cat > "${PROFILE_D}" <<PROFILE
# MySQL ${MYSQL_VERSION} PATH
export PATH=${MYSQL_BIN}:\$PATH
PROFILE
chmod +x "${PROFILE_D}"

# 方式三：立即导出到当前会话
export PATH="${MYSQL_BIN}:${PATH}"
info "MySQL bin 目录已添加到当前会话 PATH"

# =============================================================================
# 步骤 12：自动运行 mysql_secure_installation（可选）
# =============================================================================

if [ "${AUTO_SECURE}" -eq 1 ]; then
  step "自动运行 mysql_secure_installation（交互式）"
  if [ -f "${BASEDIR}/bin/mysql_secure_installation" ]; then
    "${BASEDIR}/bin/mysql_secure_installation" || true
  else
    warn "未找到 mysql_secure_installation，跳过"
  fi
fi

# =============================================================================
# 步骤 13：开放防火墙端口（可选）
# =============================================================================

if [ "${OPEN_FIREWALL}" -eq 1 ]; then
  step "使用 firewalld 开放 MySQL 服务端口"
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --add-service=mysql --permanent || warn "无法添加防火墙规则"
    firewall-cmd --reload || warn "无法重载防火墙"
    info "防火墙规则已添加"
  else
    warn "未检测到 firewall-cmd，跳过开放防火墙"
  fi
fi

# =============================================================================
# 步骤 14：调整 SELinux 上下文（可选）
# =============================================================================

if [ "${SELINUX_ADJUST}" -eq 1 ]; then
  step "调整 SELinux 上下文"

  if ! command -v getenforce >/dev/null 2>&1; then
    warn "未检测到 getenforce，无法调整 SELinux 上下文"
  else
    SELSTAT=$(getenforce)
    info "SELinux 状态: ${SELSTAT}"

    if [ "${SELSTAT}" = "Enforcing" ]; then
      if ! command -v semanage >/dev/null 2>&1; then
        info "semanage 未安装，尝试安装 policycoreutils-python-utils"
        dnf install -y policycoreutils-python-utils || warn "无法安装 semanage，跳过 SELinux 调整"
      fi

      if command -v semanage >/dev/null 2>&1; then
        info "为 ${DATADIR} 添加 SELinux 文件上下文"
        semanage fcontext -a -t mysqld_db_t "${DATADIR}(/.*)?" 2>/dev/null || \
          semanage fcontext -m -t mysqld_db_t "${DATADIR}(/.*)?" || true
        restorecon -Rv "${DATADIR}" || true
        info "SELinux 上下文已调整"
      fi
    else
      info "SELinux 未处于 Enforcing 模式，跳过上下文调整"
    fi
  fi
fi

# =============================================================================
# 完成
# =============================================================================

echo ""
info "========================================"
info "  MySQL ${MYSQL_VERSION} 安装完成！"
info "========================================"
echo ""
info "服务管理命令："
echo "  sudo systemctl status mysqld    # 查看服务状态"
echo "  sudo systemctl start mysqld     # 启动服务"
echo "  sudo systemctl stop mysqld      # 停止服务"
echo "  sudo systemctl restart mysqld   # 重启服务"
echo ""
info "日志查看："
echo "  sudo journalctl -u mysqld -e    # 查看服务日志"
echo "  tail -f ${LOG_ERROR}            # 查看错误日志"
echo ""
info "安全配置："
echo "  sudo ${BASEDIR}/bin/mysql_secure_installation"
echo ""
info "连接 MySQL："
echo "  mysql -u root -p"
echo ""

exit 0
