#!/bin/bash
set -euo pipefail

# 在交互式终端中提示用户输入目标 IP 和要设置的密码，并使用 MySQL 管理员账号执行 SQL

escape_sql() {
  # 将单引号转义成 '\''，以便安全地包含在单引号 SQL 字符串中
  printf "%s" "$1" | sed "s/'/'\\''/g"
}

if ! command -v mysql >/dev/null 2>&1; then
  echo "错误：未找到 mysql 客户端。请先安装并确保在 PATH 中。"
  exit 1
fi

read -p "请输入目标 IP（例如 192.168.1.100）：" TARGET_IP
read -s -p "请输入要为用户 'root'@'$TARGET_IP' 设置的密码：" NEW_PASS
echo
read -p "用于连接 MySQL 的管理员用户名（默认 root）：" ADMIN_USER
ADMIN_USER=${ADMIN_USER:-root}
read -s -p "请输入 MySQL 管理员密码（将用于连接）：" ADMIN_PASS
echo

ESC_PWD=$(escape_sql "$NEW_PASS")

SQL="CREATE USER 'root'@'${TARGET_IP}' IDENTIFIED BY '${ESC_PWD}';\nGRANT ALL PRIVILEGES ON *.* TO 'root'@'${TARGET_IP}' WITH GRANT OPTION;\nFLUSH PRIVILEGES;"

echo "正在向 MySQL 发送以下语句（敏感内容已隐藏）..."

# 使用 MYSQL_PWD 环境变量避免在命令行参数中暴露密码
MYSQL_PWD="$ADMIN_PASS" mysql -u "$ADMIN_USER" -e "$SQL"

if [ $? -eq 0 ]; then
  echo "操作完成：已创建用户 'root'@'$TARGET_IP' 并授予权限。"
  echo "列出当前所有 MySQL 用户："
  MYSQL_PWD="$ADMIN_PASS" mysql -u "$ADMIN_USER" -e "SELECT CONCAT(User,'@',Host) AS account FROM mysql.user;"
else
  echo "操作失败：请检查管理员用户名/密码或 MySQL 连接。"
  exit 1
fi
