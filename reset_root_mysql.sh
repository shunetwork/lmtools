#!/bin/bash

MYSQL="/usr/local/mysql/bin/mysql"

ROOT_PASSWORD='Mysql@2026!'

$MYSQL <<EOF

-- 设置 root 密码
ALTER USER 'root'@'localhost'
IDENTIFIED BY '${ROOT_PASSWORD}';

-- 删除匿名用户
DELETE FROM mysql.user
WHERE user='';

-- 删除空Host记录
DELETE FROM mysql.user
WHERE host='';

-- 删除测试库
DROP DATABASE IF EXISTS test;

-- 删除test权限
DELETE FROM mysql.db
WHERE Db='test'
OR Db='test\\_%';

FLUSH PRIVILEGES;

EOF

echo ""
echo "=================================="
echo "MySQL 初始化完成"
echo "root密码: ${ROOT_PASSWORD}"
echo "=================================="
