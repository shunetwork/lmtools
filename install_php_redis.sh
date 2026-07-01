#!/bin/bash

# PHP安装目录
PHP_PREFIX="/usr/local/php"

# 自动获取phpize
PHPIZE="${PHP_PREFIX}/bin/phpize"
PHP_CONFIG="${PHP_PREFIX}/bin/php-config"
PHP_INI="${PHP_PREFIX}/etc/php.ini"

echo "===================================="
echo " Install PHP Redis Extension"
echo "===================================="

# 检查PHP
if [ ! -f "${PHPIZE}" ]; then
    echo "phpize不存在: ${PHPIZE}"
    exit 1
fi

# 安装编译环境
if command -v dnf >/dev/null 2>&1; then
    dnf install -y gcc gcc-c++ make autoconf
elif command -v yum >/dev/null 2>&1; then
    yum install -y gcc gcc-c++ make autoconf
fi

cd /usr/local/src

# 下载最新版redis扩展
REDIS_VERSION="6.2.0"

rm -rf redis-${REDIS_VERSION}
rm -f redis-${REDIS_VERSION}.tgz

wget https://pecl.php.net/get/redis-${REDIS_VERSION}.tgz

if [ $? -ne 0 ]; then
    echo "下载失败"
    exit 1
fi

tar zxvf redis-${REDIS_VERSION}.tgz
cd redis-${REDIS_VERSION}

# 编译安装
${PHPIZE}

./configure \
    --with-php-config=${PHP_CONFIG}

make -j$(nproc)

make install

if [ $? -ne 0 ]; then
    echo "安装失败"
    exit 1
fi

# 获取扩展目录
EXT_DIR=$(${PHP_CONFIG} --extension-dir)

echo "extension=redis.so" > ${PHP_PREFIX}/etc/php.d/redis.ini

# php.ini不存在则创建配置
if ! grep -q "redis.so" ${PHP_INI}; then
    echo "" >> ${PHP_INI}
    echo ";redis" >> ${PHP_INI}
    echo "extension=redis.so" >> ${PHP_INI}
fi

echo "===================================="
echo " Redis Installed"
echo "===================================="

${PHP_PREFIX}/bin/php -m | grep redis

${PHP_PREFIX}/bin/php --ri redis

echo ""
echo "重启并检查服务状态..."
# 尝试重启 php-fpm（若存在）和 nginx
if systemctl list-units --type=service | grep -q '^php-fpm.service'; then
    systemctl restart php-fpm || echo "警告: 重启 php-fpm 失败"
else
    systemctl restart php || echo "警告: 未找到 php-fpm.service，尝试重启 php 失败或不存在"
fi
systemctl restart nginx || echo "警告: 重启 nginx 失败"

echo ""
echo "服务状态："
systemctl status nginx --no-pager || true
# 先尝试显示用户指定的 `systemctl status php`，若失败则尝试 `php-fpm`
if systemctl status php --no-pager >/dev/null 2>&1; then
    systemctl status php --no-pager || true
else
    systemctl status php-fpm --no-pager || true
fi
