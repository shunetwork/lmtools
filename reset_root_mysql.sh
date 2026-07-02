#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# reset_root_mysql.sh
# 重置 MySQL root 密码并执行安全初始化
# 自动生成随机密码，并创建 /bin/conn.sh 快速连接脚本
# 用法: sudo bash reset_root_mysql.sh [--old-pw PASSWORD]
#   --old-pw PASSWORD  指定当前 root 密码（非交互模式）
# =============================================================================

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

# ---- 配置 ----
MYSQL_BIN="/usr/local/mysql/bin"
MYSQL="${MYSQL_BIN}/mysql"
CONN_SCRIPT="/bin/conn.sh"
PASSWORD_FILE="/root/.mysql_root_pw"
OLD_PW=""

# ---- 参数解析 ----
while [ "$#" -gt 0 ]; do
  case "$1" in
    --old-pw) shift; OLD_PW="$1"; shift ;;
    -h|--help)
      echo "Usage: $0 [--old-pw PASSWORD]"
      echo "  --old-pw PASSWORD  指定当前 root 密码（非交互模式）"
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# ---- 自动提权 ----
if [ "$EUID" -ne 0 ]; then
  echo "非 root 用户，尝试通过 sudo 重新执行..."
  exec sudo bash "$0" "$@"
fi

# ---- 检查 MySQL 是否可用 ----
if [ ! -f "${MYSQL}" ]; then
  error "未找到 MySQL 客户端: ${MYSQL}"
  error "请先安装 MySQL"
  exit 1
fi

# ---- 生成随机密码 ----
step "生成随机 root 密码"

# 生成 20 位随机密码：大小写字母 + 数字 + 特殊符号
ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9!@#%^&*()_+-=' < /dev/urandom 2>/dev/null | head -c 20 || true)

# 后备方案：如果 /dev/urandom 不可用
if [ -z "${ROOT_PASSWORD}" ]; then
  ROOT_PASSWORD="Mysql$(date +%s)$(shuf -i 1000-9999 -n 1)!"
fi

info "已生成随机密码"

# ---- 保存密码到文件 ----
step "保存密码到 ${PASSWORD_FILE}"

cat > "${PASSWORD_FILE}" <<EOF
# MySQL root 密码 - 由 reset_root_mysql.sh 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
ROOT_PASSWORD='${ROOT_PASSWORD}'
EOF
chmod 600 "${PASSWORD_FILE}"
info "密码已保存到 ${PASSWORD_FILE}（仅 root 可读）"

# ---- 执行 MySQL 安全初始化 ----
step "执行 MySQL 安全初始化"

SOCKET="/var/run/mysqld/mysqld.sock"
MYSQL_OPTS=""
MYSQL_PW=""
CONNECTED=0

# 连接尝试策略：
# 1. 尝试 socket 无密码
# 2. 尝试 TCP 无密码
# 3. 尝试 socket + 指定密码
# 4. 尝试 TCP + 指定密码
# 5. 提示用户输入密码

try_connect() {
  local opts="$1"
  if ${MYSQL} ${opts} -u root -e "SELECT 1;" >/dev/null 2>&1; then
    MYSQL_OPTS="${opts}"
    CONNECTED=1
    return 0
  fi
  return 1
}

try_connect_with_pw() {
  local opts="$1"
  local pw="$2"
  if ${MYSQL} ${opts} -u root -p"${pw}" -e "SELECT 1;" >/dev/null 2>&1; then
    MYSQL_OPTS="${opts}"
    MYSQL_PW="${pw}"
    CONNECTED=1
    return 0
  fi
  return 1
}

# 策略 1: socket 无密码
info "尝试 socket 无密码连接..."
try_connect "-S ${SOCKET}" && info "Socket 无密码连接成功"

# 策略 2: TCP 无密码
if [ "${CONNECTED}" -eq 0 ]; then
  info "尝试 TCP 无密码连接..."
  try_connect "-h 127.0.0.1 -P 3306" && info "TCP 无密码连接成功"
fi

# 策略 3: 使用 --old-pw 参数指定的密码
if [ "${CONNECTED}" -eq 0 ] && [ -n "${OLD_PW}" ]; then
  info "尝试使用 --old-pw 参数指定的密码连接..."
  try_connect_with_pw "-S ${SOCKET}" "${OLD_PW}" && info "Socket + 密码连接成功"

  if [ "${CONNECTED}" -eq 0 ]; then
    info "尝试 TCP + 密码连接..."
    try_connect_with_pw "-h 127.0.0.1 -P 3306" "${OLD_PW}" && info "TCP + 密码连接成功"
  fi
fi

# 策略 4: 使用已保存的密码文件
if [ "${CONNECTED}" -eq 0 ] && [ -f "${PASSWORD_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${PASSWORD_FILE}"
  SAVED_PW="${ROOT_PASSWORD}"

  info "尝试 socket + 已保存密码连接..."
  try_connect_with_pw "-S ${SOCKET}" "${SAVED_PW}" && info "Socket + 密码连接成功"

  if [ "${CONNECTED}" -eq 0 ]; then
    info "尝试 TCP + 已保存密码连接..."
    try_connect_with_pw "-h 127.0.0.1 -P 3306" "${SAVED_PW}" && info "TCP + 密码连接成功"
  fi
fi

# 策略 5: 提示用户输入密码
if [ "${CONNECTED}" -eq 0 ]; then
  warn "无法自动连接 MySQL，需要手动输入当前 root 密码"
  echo ""
  # 使用临时文件避免特殊字符问题
  PW_PROMPT_FILE=$(mktemp)
  cat > "${PW_PROMPT_FILE}" <<'PROMPT'
#!/usr/bin/env bash
read -r -s -p "请输入当前 MySQL root 密码（留空则跳过）: " USER_PW
echo ""
echo "${USER_PW}"
PROMPT
  chmod +x "${PW_PROMPT_FILE}"
  USER_PW=$("${PW_PROMPT_FILE}")
  rm -f "${PW_PROMPT_FILE}"

  if [ -n "${USER_PW}" ]; then
    info "尝试使用输入的密码连接..."
    try_connect_with_pw "-S ${SOCKET}" "${USER_PW}" || \
      try_connect_with_pw "-h 127.0.0.1 -P 3306" "${USER_PW}" || \
      warn "输入的密码也无法连接"
  fi
fi

# 最终检查
if [ "${CONNECTED}" -eq 0 ]; then
  error "无法连接到 MySQL，请手动执行: sudo ${MYSQL} -u root -p"
  exit 1
fi

# 执行安全初始化 SQL
info "设置 root 密码并清理安全风险..."

if [ -n "${MYSQL_PW}" ]; then
  # 有密码的情况
  ${MYSQL} ${MYSQL_OPTS} -u root -p"${MYSQL_PW}" <<SQL
-- 设置 root 密码
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASSWORD}';

-- 删除匿名用户
DELETE FROM mysql.user WHERE user='';

-- 删除空 Host 记录
DELETE FROM mysql.user WHERE host='';

-- 删除测试库
DROP DATABASE IF EXISTS test;

-- 删除 test 权限
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

FLUSH PRIVILEGES;
SQL
else
  # 无密码的情况
  ${MYSQL} ${MYSQL_OPTS} -u root <<SQL
-- 设置 root 密码
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASSWORD}';

-- 删除匿名用户
DELETE FROM mysql.user WHERE user='';

-- 删除空 Host 记录
DELETE FROM mysql.user WHERE host='';

-- 删除测试库
DROP DATABASE IF EXISTS test;

-- 删除 test 权限
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

FLUSH PRIVILEGES;
SQL
fi

info "MySQL 安全初始化完成"

# ---- 创建 conn.sh 快速连接脚本 ----
step "创建快速连接脚本 ${CONN_SCRIPT}"

cat > "${CONN_SCRIPT}" <<SCRIPT
#!/usr/bin/env bash
# =============================================================================
# conn.sh - MySQL root 快速连接脚本
# 由 reset_root_mysql.sh 自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# 从密码文件读取密码
PASSWORD_FILE="${PASSWORD_FILE}"
if [ -f "\${PASSWORD_FILE}" ]; then
  # shellcheck source=/dev/null
  source "\${PASSWORD_FILE}"
else
  echo "错误: 密码文件 \${PASSWORD_FILE} 不存在" >&2
  echo "请先运行: sudo bash reset_root_mysql.sh" >&2
  exit 1
fi

# 默认使用 socket 连接
SOCKET="${SOCKET}"
MYSQL="${MYSQL_BIN}/mysql"

if [ -S "\${SOCKET}" ]; then
  exec \${MYSQL} -u root -p"\${ROOT_PASSWORD}" -S "\${SOCKET}" "\$@"
else
  exec \${MYSQL} -u root -p"\${ROOT_PASSWORD}" -h 127.0.0.1 -P 3306 "\$@"
fi
SCRIPT

chmod 755 "${CONN_SCRIPT}"
info "快速连接脚本已创建: ${CONN_SCRIPT}"
info "使用方式: conn.sh 或 conn.sh -e \"SHOW DATABASES;\""

# ---- 完成 ----
echo ""
info "========================================"
info "  MySQL root 密码重置完成！"
info "========================================"
echo ""
info "root 密码: ${ROOT_PASSWORD}"
info "密码已保存到: ${PASSWORD_FILE}（仅 root 可读）"
echo ""
info "快速连接 MySQL:"
echo "  conn.sh                    # 交互式连接"
echo "  conn.sh -e \"SHOW DATABASES;\"  # 执行 SQL"
echo ""
info "查看密码:"
echo "  cat ${PASSWORD_FILE}"
echo ""

exit 0
