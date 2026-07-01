#!/usr/bin/env bash
set -euo pipefail

# install_mysql_8.4.sh
# 一键在 CentOS/RHEL 10 上安装 MySQL 二进制包（8.4.9）
# 用法: sudo bash install_mysql_8.4.sh [--secure]
#   --secure : 脚本执行完后自动交互运行 mysql_secure_installation

MYSQL_URL="https://cdn.mysql.com//Downloads/MySQL-8.4/mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz"
MYSQL_TAR="/usr/local/src/$(basename ${MYSQL_URL})"
BASEDIR="/usr/local/mysql"
DATADIR="/var/lib/mysql"
RUN_USER="mysql"
RUN_GROUP="mysql"
SYSTEMD_UNIT="/etc/systemd/system/mysqld.service"
PROFILE_D="/etc/profile.d/mysql.sh"

# Options (defaults)
AUTO_SECURE=0
OPEN_FIREWALL=0
SELINUX_ADJUST=0
ROOT_PW=""
SKIP_DEPS=0

usage() {
  cat <<EOF
Usage: $0 [--secure] [--open-firewall] [--selinux-adjust] [--set-root-pw PASSWORD] [--skip-deps]
  --secure           : 在安装完成后交互运行 mysql_secure_installation
  --open-firewall    : 自动添加 firewall-cmd 规则开放 MySQL 服务
  --selinux-adjust   : 尝试为 MySQL 数据目录设置 SELinux 上下文（需要 semanage）
  --set-root-pw PW   : 非交互设置 root 密码为 PW
  --skip-deps        : 跳过依赖安装步骤
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --secure) AUTO_SECURE=1; shift ;;
    --open-firewall) OPEN_FIREWALL=1; shift ;;
    --selinux-adjust) SELINUX_ADJUST=1; shift ;;
    --set-root-pw) shift; ROOT_PW="$1"; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

echo "==> 安装系统依赖"
if [ ${SKIP_DEPS} -eq 0 ]; then
  dnf install -y wget libaio numactl xz || { echo "dnf 安装失败"; exit 1; }
else
  echo "跳过依赖安装 (--skip-deps)"
fi

echo "==> 准备目录与下载包"
mkdir -p /usr/local/src
if [ ! -f "${MYSQL_TAR}" ]; then
  echo "Downloading ${MYSQL_URL} to ${MYSQL_TAR}"
  wget -O "${MYSQL_TAR}" "${MYSQL_URL}"
else
  echo "已存在 ${MYSQL_TAR}, 跳过下载"
fi

# 计算 tar 包内顶层目录名
DIRNAME=$(tar -tf "${MYSQL_TAR}" | head -1 | cut -f1 -d"/")

if [ -d "${BASEDIR}" ]; then
  echo "${BASEDIR} 已存在，跳过解压并保留现有目录"
else
  # 如果已经提前解压到了 /usr/local/src，直接移动
  if [ -d "/usr/local/src/${DIRNAME}" ]; then
    echo "检测到 /usr/local/src/${DIRNAME}，直接移动到 ${BASEDIR}"
    mv "/usr/local/src/${DIRNAME}" "${BASEDIR}" || { echo "移动失败：/usr/local/src/${DIRNAME} -> ${BASEDIR}"; exit 1; }
  else
    echo "==> 解压并安装到 ${BASEDIR}"
    tar -xJf "${MYSQL_TAR}" -C /usr/local/src || { echo "解压失败：${MYSQL_TAR}"; exit 1; }
    if [ -d "/usr/local/src/${DIRNAME}" ]; then
      mv "/usr/local/src/${DIRNAME}" "${BASEDIR}" || { echo "移动失败：/usr/local/src/${DIRNAME} -> ${BASEDIR}"; exit 1; }
    else
      echo "错误：解压后未找到目录 /usr/local/src/${DIRNAME}"; exit 1
    fi
  fi
fi

echo "==> 创建 mysql 用户与数据目录"
getent group ${RUN_GROUP} >/dev/null || groupadd -r ${RUN_GROUP}
getent passwd ${RUN_USER} >/dev/null || useradd -r -g ${RUN_GROUP} -s /sbin/nologin ${RUN_USER}
mkdir -p "${DATADIR}"
chown -R ${RUN_USER}:${RUN_GROUP} "${BASEDIR}" "${DATADIR}"

echo "==> 初始化数据库（insecure 模式：初始 root 无密码）"
if [ -z "$(ls -A "${DATADIR}")" ]; then
  ${BASEDIR}/bin/mysqld --initialize-insecure --basedir=${BASEDIR} --datadir=${DATADIR} --user=${RUN_USER}
else
  echo "数据目录非空，跳过初始化"
fi

echo "==> 生成更完整的 /etc/my.cnf（如不存在）"
if [ ! -f /etc/my.cnf ]; then
  cat > /etc/my.cnf <<EOF
[mysqld]
# 基础路径
basedir=${BASEDIR}
datadir=${DATADIR}
socket=/var/run/mysqld/mysqld.sock
pid-file=/var/run/mysqld/mysqld.pid
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
log_error=/var/log/mysqld.err
slow_query_log=1
slow_query_log_file=/var/log/mysql-slow.log
long_query_time=2

# SQL 模式（移除已移除/不兼容的标志如 NO_AUTO_CREATE_USER）
# 如需调整，请修改 /etc/my.cnf
sql_mode=''

# 二进制日志/复制（如需启用，取消注释并配置）
# server-id=1
# log_bin=mysql-bin
# binlog_format=ROW
# expire_logs_days=7

[client]
default-character-set=utf8mb4
socket=/var/run/mysqld/mysqld.sock

[mysql]
default_character_set=utf8mb4

[mysqld_safe]
log-error=/var/log/mysqld.err
pid-file=/var/run/mysqld/mysqld.pid
EOF
  echo "/etc/my.cnf 已创建，建议根据服务器内存调整 innodb_buffer_pool_size"
else
  echo "/etc/my.cnf 已存在，保留原文件"
fi

echo "==> 写入 systemd 单元"
cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=MySQL Server
After=network.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
ExecStart=${BASEDIR}/bin/mysqld --defaults-file=/etc/my.cnf
LimitNOFILE=5000
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF


echo "==> 确保日志与运行目录存在并设置权限"
mkdir -p /var/log
touch /var/log/mysqld.err || true
chown ${RUN_USER}:${RUN_GROUP} /var/log/mysqld.err || true
mkdir -p /var/run/mysqld
chown ${RUN_USER}:${RUN_GROUP} /var/run/mysqld || true
# 确保慢查询日志存在并设置权限
touch /var/log/mysql-slow.log || true
chown ${RUN_USER}:${RUN_GROUP} /var/log/mysql-slow.log || true
chmod 0640 /var/log/mysql-slow.log || true

echo "==> 重新加载 systemd 并启动 mysqld"
systemctl daemon-reload
systemctl enable --now mysqld
systemctl status mysqld --no-pager || true

# 等待短时间，确保 socket 就绪
sleep 3

# 如果用户通过 --set-root-pw 提供密码，则以非交互方式设置 root 密码
if [ -n "${ROOT_PW}" ]; then
  echo "==> 非交互设置 root 密码"
  ${BASEDIR}/bin/mysql -u root -S /var/run/mysqld/mysqld.sock -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}'; FLUSH PRIVILEGES;" || \
    echo "警告: 无法通过 socket 设置 root 密码，请稍后手动运行 mysql_secure_installation"
fi

echo "==> 添加 PATH 到 ${PROFILE_D}"
cat > "${PROFILE_D}" <<EOF
export PATH=${BASEDIR}/bin:\$PATH
EOF
chmod +x "${PROFILE_D}"

echo
echo "安装完成。请按需执行下面的操作："
echo " - 交互式设置 root 密码并移除匿名用户： /usr/local/mysql/bin/mysql_secure_installation"
echo " - 或使用脚本自动运行： sudo /usr/local/mysql/bin/mysql_secure_installation"

if [ ${AUTO_SECURE} -eq 1 ]; then
  echo "==> 自动运行 mysql_secure_installation（交互式）"
  ${BASEDIR}/bin/mysql_secure_installation || true
fi

# 可选：开放防火墙端口
if [ ${OPEN_FIREWALL} -eq 1 ]; then
  if command -v firewall-cmd >/dev/null 2>&1; then
    echo "==> 使用 firewalld 开放 MySQL 服务端口"
    firewall-cmd --add-service=mysql --permanent || echo "警告: 无法添加防火墙规则"
    firewall-cmd --reload || echo "警告: 无法重载防火墙"
  else
    echo "警告: 未检测到 firewall-cmd，跳过开放防火墙"
  fi
fi

# 可选：调整 SELinux 上下文
if [ ${SELINUX_ADJUST} -eq 1 ]; then
  if command -v getenforce >/dev/null 2>&1; then
    SELSTAT=$(getenforce)
    echo "SELinux 状态: ${SELSTAT}"
    if [ "${SELSTAT}" = "Enforcing" ]; then
      if command -v semanage >/dev/null 2>&1; then
        echo "==> 为 ${DATADIR} 添加 SELinux 文件上下文并恢复上下文"
        semanage fcontext -a -t mysqld_db_t "${DATADIR}(/.*)?" || true
        restorecon -Rv ${DATADIR} || true
      else
        echo "semanage 未安装，尝试安装 policycoreutils-python-utils"
        dnf install -y policycoreutils-python-utils || echo "无法安装 semanage，跳过 SELinux 调整"
        if command -v semanage >/dev/null 2>&1; then
          semanage fcontext -a -t mysqld_db_t "${DATADIR}(/.*)?" || true
          restorecon -Rv ${DATADIR} || true
        fi
      fi
    else
      echo "SELinux 未处于 Enforcing，跳过上下文调整"
    fi
  else
    echo "未检测到 getenforce，无法调整 SELinux 上下文"
  fi
fi

echo "如果服务无法启动，请查看日志： sudo journalctl -u mysqld -e"
echo "如果需要开放防火墙端口： sudo firewall-cmd --add-service=mysql --permanent && sudo firewall-cmd --reload"

exit 0
