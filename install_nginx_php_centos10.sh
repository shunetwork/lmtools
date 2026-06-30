#!/usr/bin/env bash
set -euo pipefail

# 安装并编译 nginx 1.28.0 与 PHP 8.5.7（适用于 CentOS Stream 10）
# 使用前请以 root 运行：sudo bash install_nginx_php_centos10.sh

NGINX_VERSION="1.28.0"
PHP_VERSION="8.3"
# 可选：指定 PHP 源码下载地址（若为空则从 php.net distributions 下载）
PHP_DOWNLOAD_URL="https://www.php.net/distributions/php-8.3.31.tar.gz"

# 安装选择控制（interactive 可选）
INSTALL_NGINX=true
INSTALL_PHP=true
NO_INTERACTIVE=false

# 可配置变量（可通过环境变量或命令行覆盖）
PREFIX_NGINX="/usr/local/nginx"
PREFIX_PHP="/usr/local/php"
BUILD_DIR="/usr/local/src/build_nginx_php"
PARALLEL_MAKE="$(nproc || echo 1)"

# 下载与校验（留空表示不校验）
NGINX_SHA256=""
PHP_SHA256=""

# 行为开关
DISABLE_FIREWALL_SELINUX=true
VERIFY_CHECKSUMS=false

usage() {
  cat <<EOF
Usage: $0 [--prefix-nginx PATH] [--prefix-php PATH] [--build-dir PATH] [--jobs N] [--no-disable-security] [--verify-checksums] [--php-download-url URL] [--only-nginx|--only-php] [--no-interactive]

Options:
  --prefix-nginx PATH    安装 nginx 前缀（默认 ${PREFIX_NGINX})
  --prefix-php PATH      安装 php 前缀（默认 ${PREFIX_PHP})
  --php-download-url URL 指定 PHP 源码下载地址，若设置则优先使用（默认: ${PHP_DOWNLOAD_URL})
  --only-nginx           仅安装 nginx（跳过 PHP）
  --only-php             仅安装 PHP（跳过 nginx）
  --no-interactive       跳过交互提示（非交互模式）
  --build-dir PATH       构建目录（默认 ${BUILD_DIR})
  --jobs N               并行编译数量（默认 ${PARALLEL_MAKE})
  --no-disable-security  不自动禁用 firewalld/SELinux
  --verify-checksums     启用下载包 sha256 校验（需提前设置 SHA256 变量）
  -h, --help             显示本帮助
EOF
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix-nginx) PREFIX_NGINX="$2"; shift 2;;
      --prefix-php) PREFIX_PHP="$2"; shift 2;;
      --php-download-url) PHP_DOWNLOAD_URL="$2"; shift 2;;
      --only-nginx) INSTALL_PHP=false; shift 1;;
      --only-php) INSTALL_NGINX=false; shift 1;;
      --no-interactive) NO_INTERACTIVE=true; shift 1;;
      --build-dir) BUILD_DIR="$2"; shift 2;;
      --jobs) PARALLEL_MAKE="$2"; shift 2;;
      --no-disable-security) DISABLE_FIREWALL_SELINUX=false; shift 1;;
      --verify-checksums) VERIFY_CHECKSUMS=true; shift 1;;
      -h|--help) usage;;
      *) echo "Unknown arg: $1"; usage;;
    esac
  done
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户运行此脚本。"
    exit 1
  fi
}

create_user() {
  if ! getent group www >/dev/null; then
    groupadd -r www
  fi
  if ! id -u www >/dev/null 2>&1; then
    useradd -r -g www -s /sbin/nologin -M www
  fi
}

install_build_deps() {
  dnf -y makecache
  dnf -y install epel-release || true
  dnf -y install dnf-plugins-core || true
  # 启用 CodeReady Builder (CRB) / PowerTools 并准备安装
  if command -v dnf >/dev/null 2>&1; then
    dnf config-manager --set-enabled crb || dnf config-manager --set-enabled powertools || true
    dnf -y makecache || true
  fi

  dnf -y groupinstall "Development Tools" || true

  # 要安装的软件包清单
  declare -a want=( \
    wget curl tar xz gcc gcc-c++ make autoconf automake libtool bison re2c \
    pcre pcre-devel zlib zlib-devel openssl openssl-devel \
    libcurl-devel libxml2-devel bzip2-devel libzip-devel oniguruma-devel \
    sqlite-devel libpng-devel libjpeg-turbo-devel freetype-devel libwebp-devel \
    cmake \
    libicu-devel gmp-devel which pkgconfig unzip )

  # Helper: try install list, return remaining failed
  try_install_list() {
    local -n arr=$1
    local -a remaining=()
    for pkg in "${arr[@]}"; do
      if ! dnf -y install "$pkg" >/dev/null 2>&1; then
        remaining+=("$pkg")
      fi
    done
    echo "${remaining[*]}"
  }

  # 首轮安装
  failed=( $(try_install_list want) )

  # 若失败，尝试启用 CRB/powertools（已尝试）并重试失败的包
  if [ ${#failed[@]} -ne 0 ]; then
    echo "部分包安装失败，正在启用 CRB/PowerTools 并重试安装： ${failed[*]}"
    if command -v dnf >/dev/null 2>&1; then
      dnf config-manager --set-enabled crb || dnf config-manager --set-enabled powertools || true
      dnf -y makecache || true
    fi
    # 重试失败包
    retry_failed=( $(try_install_list failed) )
    failed=( ${retry_failed[*]} )
  fi

  # 如果仍有 pcre 相关失败，尝试 pcre2 套件名
  if [[ " ${failed[*]} " =~ " pcre " ]] || [[ " ${failed[*]} " =~ " pcre-devel " ]]; then
    echo "尝试安装 pcre2/pcre2-devel 作为替代。"
    if dnf -y install pcre2 pcre2-devel >/dev/null 2>&1; then
      # 从 failed 中移除 pcre 条目
      failed=( ${failed[@]/pcre/} )
      failed=( ${failed[@]/pcre-devel/} )
    fi
  fi

  if [ ${#failed[@]} -ne 0 ]; then
    echo "警告：以下软件包安装失败： ${failed[*]}"
    echo "可能原因：需要启用 CRB/PowerTools 或使用替代包名。"
    echo "脚本会尝试回退从源码编译缺失的关键库（如果适用）。"
  fi
  FAILED_PKGS="${failed[*]}"
}

build_pcre_from_source() {
  echo "尝试从源码编译 PCRE（回退）"
  local urls=( \
    "https://ftp.pcre.org/pub/pcre/pcre-8.45.tar.gz" \
    "https://github.com/PhilipHazel/pcre/releases/download/pcre-8.45/pcre-8.45.tar.gz" \
  )
  for url in "${urls[@]}"; do
    echo "尝试下载 $url"
    if download_and_extract "$url"; then
      # 找到解压后的目录
      dir=$(basename "$url" .tar.gz)
      if [ -d "$BUILD_DIR/$dir" ]; then
        cd "$BUILD_DIR/$dir"
        ./configure --prefix=/usr/local || continue
          make -j"${PARALLEL_MAKE}" && make install && ldconfig || return 0
      else
        # 有些 tarball 解压目录名不同，尝试通配
        cd "$BUILD_DIR"
        for d in pcre*; do
          if [ -d "$d" ]; then
            cd "$d"
            ./configure --prefix=/usr/local || continue
            make -j"${PARALLEL_MAKE}" && make install && ldconfig || return 0
          fi
        done
      fi
    fi
  done
  echo "PCRE 源码编译失败，请手动安装 pcre/pcre-devel 或检查网络/镜像。"
  return 1
}

build_libzip_from_source() {
  echo "尝试从源码编译 libzip（回退）"
  local urls=( \
    "https://libzip.org/download/libzip-1.10.0.tar.gz" \
    "https://github.com/nih-at/libzip/releases/download/v1.10.0/libzip-1.10.0.tar.gz" \
  )
  for url in "${urls[@]}"; do
    echo "尝试下载 $url"
    if download_and_extract "$url"; then
      cd "$BUILD_DIR"
      for d in libzip*; do
        if [ -d "$d" ]; then
          cd "$d"
          if [ -f configure ]; then
            ./configure --prefix=/usr/local || continue
            make -j"${PARALLEL_MAKE}" && make install && ldconfig || return 0
          else
            mkdir -p build && cd build
            cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local || continue
            make -j"${PARALLEL_MAKE}" && make install && return 0
          fi
        fi
      done
    fi
  done
  echo "libzip 源码编译失败，请手动安装 libzip-devel 或检查网络/镜像。"
  return 1
}

build_oniguruma_from_source() {
  echo "尝试从源码编译 Oniguruma（回退）"
  local urls=( \
    "https://github.com/kkos/oniguruma/releases/download/v6.9.10/onig-6.9.10.tar.gz" \
    "https://github.com/kkos/oniguruma/releases/download/v6.9.9/onig-6.9.9.tar.gz" \
  )
  for url in "${urls[@]}"; do
    echo "尝试下载 $url"
    if download_and_extract "$url"; then
      cd "$BUILD_DIR"
      for d in onig* oniguruma*; do
        if [ -d "$d" ]; then
          cd "$d"
          ./autogen.sh 2>/dev/null || true
          ./configure --prefix=/usr/local || continue
          make -j"${PARALLEL_MAKE}" && make install && ldconfig || return 0
        fi
      done
    fi
  done
  echo "Oniguruma 源码编译失败，请手动安装 oniguruma-devel 或检查网络/镜像。"
  return 1
}

build_fallback_sources() {
  # 根据 FAILED_PKGS 决定回退编译哪些库
  if [[ " ${FAILED_PKGS} " =~ " pcre " ]] || [[ " ${FAILED_PKGS} " =~ " pcre-devel " ]]; then
    build_pcre_from_source || true
  fi
  if [[ " ${FAILED_PKGS} " =~ " libzip-devel " ]] || [[ " ${FAILED_PKGS} " =~ " libzip " ]]; then
    build_libzip_from_source || true
  fi
  if [[ " ${FAILED_PKGS} " =~ " oniguruma-devel " ]] || [[ " ${FAILED_PKGS} " =~ " oniguruma " ]]; then
    build_oniguruma_from_source || true
  fi
}

disable_firewall_selinux() {
  echo "==> 关闭 firewalld 并禁用 SELinux（会立即生效并修改配置文件）"
  # 备份 selinux 配置
  if [ -f /etc/selinux/config ]; then
    cp -a /etc/selinux/config /etc/selinux/config.bak.$(date +%s) || true
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
  fi
  # 立即设置为宽松模式
  if command -v setenforce >/dev/null 2>&1; then
    setenforce 0 || true
  fi

  # 停止并禁止 firewalld
  if systemctl list-unit-files | grep -q '^firewalld'; then
    systemctl stop firewalld || true
    systemctl disable firewalld || true
    systemctl mask firewalld || true
  fi

  # 清空 nft/iptables 规则以减少干扰
  if command -v nft >/dev/null 2>&1; then
    nft flush ruleset || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -F || true
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F || true
  fi

  echo "防火墙已停止并被禁止；SELinux 已设置为 disabled（并尝试立即生效）。"
}

download_and_extract() {
  local url="${1:-}"; local dest="${2:-}"
  if [ -z "$url" ]; then
    echo "download_and_extract: missing url"
    return 1
  fi
  local tarball; tarball="$(basename "$url")"
  # 目标目录：若传入 dest 使用 dest，否则回退到 BUILD_DIR
  if [ -n "$dest" ]; then
    mkdir -p "$dest"
    cd "$dest"
  else
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
  fi

  # 支持直接传入本地路径或 file:// URL
  if [ -f "$url" ]; then
    echo "复制本地文件 $url 到目标目录 $(pwd)"
    cp -a "$url" "$tarball" || { echo "复制本地文件失败: $url"; return 1; }
  elif [[ "$url" =~ ^file:// ]]; then
    local path="${url#file://}"
    if [ -f "$path" ]; then
      echo "复制本地文件 $path 到目标目录 $(pwd)"
      cp -a "$path" "$tarball" || { echo "复制本地文件失败: $path"; return 1; }
    else
      echo "本地文件未找到: $path"
      return 1
    fi
  else
    if [ ! -f "$tarball" ]; then
      echo "下载 $url -> $tarball 到目录 $(pwd)"
      if ! wget -c "$url" -O "$tarball"; then
        echo "下载失败: $url"
        return 1
      fi
    else
      echo "已存在本地文件 $tarball，跳过下载"
    fi
  fi

  # 基本校验：检查是否为 HTML（可能是 404 页面）
  if command -v file >/dev/null 2>&1; then
    file "$tarball" || true
  fi
  if head -c 512 "$tarball" | grep -qiE '<!doctype|<html|404 Not Found'; then
    echo "错误：下载内容看起来像 HTML（可能为 404 页面或错误响应），显示前 50 行："
    head -n 50 "$tarball" || true
    return 1
  fi

  case "$tarball" in
    *.tar.gz) tar xzf "$tarball" ;;
    *.tar.xz) tar xJf "$tarball" ;;
    *.zip)
      if ! command -v unzip >/dev/null 2>&1; then
        echo "错误：未安装 unzip，请先安装 unzip";
        return 1
      fi
      unzip -o "$tarball" ;;
    *) echo "未知压缩格式: $tarball"; return 1 ;;
  esac

  echo "解压后构建目录内容："; ls -la
}

resolve_php_latest_patch() {
  # 如果 PHP_VERSION 只有主次版本（如 8.3），尝试在线解析最新补丁版本
  if [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "解析 PHP ${PHP_VERSION} 的最新补丁版本..."
    local raw="" latest=""
    if command -v curl >/dev/null 2>&1; then
      raw=$(curl -fsSL "https://www.php.net/releases/index.php?json" 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
      raw=$(wget -qO- "https://www.php.net/releases/index.php?json" 2>/dev/null || true)
    fi

    if [ -n "$raw" ]; then
      latest=$(printf '%s\n' "$raw" \
        | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' \
        | tr -d '"' \
        | grep -E "^${PHP_VERSION}\\." \
        | sort -V \
        | tail -n1 || true)
      if [ -n "$latest" ]; then
        PHP_VERSION="$latest"
        echo "使用 PHP 版本: $PHP_VERSION"
        return 0
      fi
    fi

    # 回退：尝试解析发布页面中的补丁号
    if command -v curl >/dev/null 2>&1; then
      raw=$(curl -fsSL "https://www.php.net/releases/${PHP_VERSION//./_}.php" 2>/dev/null || true)
    else
      raw=$(wget -qO- "https://www.php.net/releases/${PHP_VERSION//./_}.php" 2>/dev/null || true)
    fi
    if [ -n "$raw" ]; then
      latest=$(printf '%s\n' "$raw" \
        | grep -oE "${PHP_VERSION}\\.[0-9]+" \
        | sort -V \
        | tail -n1 || true)
      if [ -n "$latest" ]; then
        PHP_VERSION="$latest"
        echo "使用 PHP 版本: $PHP_VERSION"
        return 0
      fi
    fi

    echo "警告：无法解析最新 ${PHP_VERSION} 补丁，继续使用 PHP_VERSION=${PHP_VERSION}"
  fi
}

prompt_install_choice() {
  if [ "$NO_INTERACTIVE" = true ]; then
    return 0
  fi
  # 仅在交互式终端询问
  if [ ! -t 0 ]; then
    return 0
  fi

  echo
  echo "请选择要安装的组件："
  echo " 1) nginx"
  echo " 2) php"
  echo " 3) both (默认)"
  echo " 4) none (退出)"
  read -p "输入选择 [3]: " choice || true
  choice=${choice:-3}
  case "$choice" in
    1)
      INSTALL_NGINX=true; INSTALL_PHP=false;;
    2)
      INSTALL_NGINX=false; INSTALL_PHP=true;;
    3)
      INSTALL_NGINX=true; INSTALL_PHP=true;;
    4)
      echo "已选择退出。"; exit 0;;
    *)
      echo "无效选择，继续安装 both"; INSTALL_NGINX=true; INSTALL_PHP=true;;
  esac
}

build_nginx() {
  echo "==> 构建 nginx ${NGINX_VERSION}"
  # 使用独立子目录存放 nginx 源码，避免与 PHP 源混淆
  mkdir -p "${BUILD_DIR}/nginx-src"
  cd "${BUILD_DIR}/nginx-src"
  download_and_extract "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" "${BUILD_DIR}/nginx-src"
  if [ -d "nginx-${NGINX_VERSION}" ]; then
    cd "nginx-${NGINX_VERSION}"
  else
    for d in nginx*; do
      if [ -d "$d" ]; then
        cd "$d"; break
      fi
    done
  fi

  # 期望的 configure 选项列表（可根据需要调整）
  opts=(
    "--prefix=${PREFIX_NGINX}"
    "--user=www"
    "--group=www"
    "--with-http_ssl_module"
    "--with-http_v2_module"
    "--with-http_realip_module"
    "--with-http_stub_status_module"
    "--with-http_gzip_static_module"
    "--with-http_rewrite_module"
    "--with-stream"
    "--with-stream_ssl_module"
    "--with-threads"
    "--with-file-aio"
    "--with-pcre-jit"
  )

  # 获取 configure 支持选项：用 --help 检查并过滤掉不支持的选项
  help_out="$(./configure --help 2>&1 || true)"
  filtered=()
  for o in "${opts[@]}"; do
    # 仅检查长选项名部分（例如 --with-http_rewrite_module）是否存在于 help 输出中
    key="$o"
    if echo "$help_out" | grep -F -- "$key" >/dev/null 2>&1; then
      filtered+=("$o")
    else
      echo "警告：configure 不支持选项 $o，已跳过。"
    fi
  done

  echo "运行 ./configure ${filtered[*]}"
  ./configure "${filtered[@]}"

  make -j"${PARALLEL_MAKE}"
  make install
}

build_php() {
  echo "==> 构建 PHP ${PHP_VERSION}"
  # 使用独立子目录存放 PHP 源码，避免与 nginx 等源码混淆
  mkdir -p "${BUILD_DIR}/php-src"
  cd "${BUILD_DIR}/php-src"
  if [ -n "${PHP_DOWNLOAD_URL}" ]; then
    echo "使用自定义下载地址: ${PHP_DOWNLOAD_URL}"
    download_and_extract "${PHP_DOWNLOAD_URL}" "${BUILD_DIR}/php-src"
  else
    download_and_extract "https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz" "${BUILD_DIR}/php-src"
  fi
  # 强制：仅在 ${BUILD_DIR}/php-src 中查找已解压的 PHP 源代码
  SRC_DIR=""
  if [ -d "php-${PHP_VERSION}" ]; then
    SRC_DIR="$(pwd)/php-${PHP_VERSION}"
  elif [ -f configure.ac ] || [ -d main ] || [ -d ext ]; then
    SRC_DIR="$(pwd)"
  else
    for d in php*; do
      if [ -d "$d" ]; then
        SRC_DIR="$(pwd)/$d"
        break
      fi
    done
  fi

  if [ -z "$SRC_DIR" ]; then
    echo "错误：在指定的 php-src 目录 (${BUILD_DIR}/php-src) 未找到解压出的 PHP 源代码。"
    echo "请把源码解压到 ${BUILD_DIR}/php-src，或使用 --php-download-url 让脚本在该目录解压。"
    echo "当前目录内容："; ls -la || true
    return 1
  fi

  cd "$SRC_DIR"
  echo "使用源码目录: $(pwd)"

  # 确保 buildconf 可执行并尝试生成 configure
  if [ -f ./buildconf ] && [ ! -x ./buildconf ]; then
    chmod +x ./buildconf || true
  fi

  # 仅在缺少 ./configure 时才运行 buildconf（官方发布的源码通常已包含 configure）
  if [ ! -f ./configure ]; then
    if [ -f ./buildconf ]; then
      echo "检测到缺少 ./configure，正在运行 ./buildconf --force 以生成 configure..."
      ./buildconf --force || true
    fi
  fi

  if [ ! -f ./configure ]; then
    echo "错误：未生成 ./configure，列出当前源码目录文件以供诊断："; ls -la
    return 1
  fi

  ./configure \
    --prefix=${PREFIX_PHP} \
    --with-config-file-path=${PREFIX_PHP}/etc \
    --enable-fpm \
    --with-fpm-user=www \
    --with-fpm-group=www \
    --enable-opcache \
    --enable-mbstring \
    --enable-bcmath \
    --enable-calendar \
    --enable-exif \
    --enable-pcntl \
    --enable-sockets \
    --enable-shmop \
    --enable-sysvsem \
    --enable-sysvshm \
    --enable-sysvmsg \
    --enable-ftp \
    --enable-intl \
    --with-zlib \
    --with-curl \
    --with-openssl \
    --with-zip \
    --with-gettext \
    --with-mysqli=mysqlnd \
    --with-pdo-mysql=mysqlnd

  make -j"${PARALLEL_MAKE}"
  make install

  # 安装 php.ini
  mkdir -p ${PREFIX_PHP}/etc
  if [ -f php.ini-production ]; then
    cp php.ini-production ${PREFIX_PHP}/etc/php.ini
  elif [ -f ${PREFIX_PHP}/etc/php.ini ]; then
    :
  fi

  # 安装并生成 php-fpm 配置
  if [ -f sapi/fpm/php-fpm.conf ]; then
    cp sapi/fpm/php-fpm.conf ${PREFIX_PHP}/etc/php-fpm.conf
  else
    ${PREFIX_PHP}/sbin/php-fpm --dump-conf > ${PREFIX_PHP}/etc/php-fpm.conf || true
  fi

  mkdir -p ${PREFIX_PHP}/etc/php-fpm.d
  cat > ${PREFIX_PHP}/etc/php-fpm.d/www.conf <<'EOF'
[www]
user = www
group = www
listen = 127.0.0.1:9000
listen.allowed_clients = 127.0.0.1
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
access.log = /var/log/php-fpm/www-access.log
slowlog = /var/log/php-fpm/www-slow.log
EOF

  mkdir -p /var/log/php-fpm
  chown -R www:www /var/log/php-fpm || true
}

install_php_redis_extension() {
  echo "==> 安装 phpredis 扩展 (PECL redis)"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  # 下载最新稳定的 redis 扩展包（pecl 会重定向到最新稳定版）
  if ! wget -O redis.tgz https://pecl.php.net/get/redis >/dev/null 2>&1; then
    echo "警告：无法从 pecl.php.net 下载 redis 扩展。跳过 phpredis 安装。"
    return 0
  fi

  tar xzf redis.tgz || { echo "解压 redis 扩展失败"; return 1; }

  # 找到解压后的目录并构建
  for d in redis*; do
    if [ -d "$d" ]; then
      cd "$d"
      if [ -x "${PREFIX_PHP}/bin/phpize" ]; then
        "${PREFIX_PHP}/bin/phpize"
        ./configure --with-php-config="${PREFIX_PHP}/bin/php-config" || { echo "configure failed"; return 1; }
      else
        # 退回到系统 phpize（若存在），但优先使用自编译 PHP 的 phpize
        if command -v phpize >/dev/null 2>&1; then
          phpize
          ./configure --with-php-config=php-config || { echo "configure failed"; return 1; }
        else
          echo "未找到 phpize，无法构建 redis 扩展。"
          return 1
        fi
      fi

      make -j"${PARALLEL_MAKE}" && make install || { echo "编译/安装 redis 扩展失败"; return 1; }

      # 启用扩展（添加到 php.ini，如果存在）
      if [ -f "${PREFIX_PHP}/etc/php.ini" ]; then
        if ! grep -q "extension=redis.so" "${PREFIX_PHP}/etc/php.ini" >/dev/null 2>&1; then
          echo "extension=redis.so" >> "${PREFIX_PHP}/etc/php.ini"
        fi
      fi

      # 尝试重启 php-fpm 以加载扩展
      if systemctl list-unit-files | grep -q '^php-fpm.service'; then
        systemctl restart php-fpm.service || true
      fi

      echo "phpredis 扩展安装完成（如果 make install 成功）。"
      return 0
    fi
  done

  echo "未找到 redis 源目录，跳过 phpredis 安装。"
  return 1
}

create_systemd_units() {
  echo "==> 创建 systemd 单元"

[ -e /etc/systemd/system/nginx.service ] && rm -f /etc/systemd/system/nginx.service || true
  cat > /etc/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=${PREFIX_NGINX}/logs/nginx.pid
ExecStartPre=${PREFIX_NGINX}/sbin/nginx -t
ExecStart=${PREFIX_NGINX}/sbin/nginx
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p ${PREFIX_PHP}/var/run
[ -e /etc/systemd/system/php-fpm.service ] && rm -f /etc/systemd/system/php-fpm.service || true
  cat > /etc/systemd/system/php-fpm.service <<EOF
[Unit]
Description=The PHP FastCGI Process Manager
After=network.target

[Service]
Type=simple
PIDFile=${PREFIX_PHP}/var/run/php-fpm.pid
ExecStart=${PREFIX_PHP}/sbin/php-fpm --nodaemonize --fpm-config ${PREFIX_PHP}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now nginx.service php-fpm.service || true
}

ensure_conf_d_included() {
  local conf="${PREFIX_NGINX}/conf/nginx.conf"
  if [ ! -f "$conf" ]; then
    echo "警告：未找到 nginx 主配置 $conf，跳过包含 conf.d 的修改。"
    return 0
  fi

  # 检查是否已包含 conf.d
  if grep -q "conf.d" "$conf" >/dev/null 2>&1; then
    return 0
  fi

  cp -a "$conf" "${conf}.bak.$(date +%s)" || true
  awk -v inc="    include ${PREFIX_NGINX}/conf/conf.d/*.conf;" '
    /^[[:space:]]*http[[:space:]]*\{/ && !found { print; print inc; found=1; next } { print }
  ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"

  echo "已在 ${conf} 的 http 段插入 include conf.d/*.conf" || true
}

configure_nginx_php_integration() {
  echo "==> 配置 nginx 与 php-fpm 互通（示例 vhost 与 phpinfo）"
  mkdir -p "${PREFIX_NGINX}/conf/conf.d"
  mkdir -p "${PREFIX_NGINX}/html"
  # 创建一个简单的 server 配置文件
  cat > "${PREFIX_NGINX}/conf/conf.d/php-site.conf" <<EOF
server {
    listen       80;
    server_name  localhost;
    root ${PREFIX_NGINX}/html;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME ${PREFIX_NGINX}/html\$fastcgi_script_name;
    }
}
EOF

  # 创建 phpinfo 测试页
  cat > "${PREFIX_NGINX}/html/phpinfo.php" <<'EOF'
<?php
phpinfo();
EOF

  chown -R www:www "${PREFIX_NGINX}/html" || true
  # 重新加载 nginx
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx || ${PREFIX_NGINX}/sbin/nginx -s reload || true
  fi
}

verify_installation() {
  echo "==> 验证安装（检查服务与 HTTP 响应）"
  sleep 2
  if [ "$INSTALL_NGINX" = true ]; then
    systemctl status nginx --no-pager || true
  fi
  if [ "$INSTALL_PHP" = true ]; then
    systemctl status php-fpm --no-pager || true
  fi

  if [ "$INSTALL_NGINX" = true ] && [ "$INSTALL_PHP" = true ]; then
    if command -v curl >/dev/null 2>&1; then
      echo "尝试请求 http://127.0.0.1/phpinfo.php"
      if curl -sS --max-time 5 http://127.0.0.1/phpinfo.php | grep -q "PHP Version"; then
        echo "PHP 已通过 nginx 提供 (phpinfo 页面可访问)。"
      else
        echo "警告：无法通过 HTTP 获取 phpinfo 页面，检查 nginx 与 php-fpm 状态及端口。"
      fi
    else
      echo "未安装 curl，无法进行 http 验证。";
    fi
  fi

  if [ "$INSTALL_PHP" = true ]; then
    # 使用编译安装的 PHP 二进制检查扩展
    if [ -x "${PREFIX_PHP}/bin/php" ]; then
      echo "检查 PHP 模块支持..."
      if ${PREFIX_PHP}/bin/php -m | grep -q -i '^redis$' ; then
        echo "redis 扩展: 已安装"
      else
        echo "警告：redis 扩展未安装或未启用。可运行脚本中的 install_php_redis_extension 安装。"
      fi

      if ${PREFIX_PHP}/bin/php -m | grep -E -q 'mysqli|pdo_mysql'; then
        echo "MySQL 支持 (mysqli/pdo_mysql): 已启用"
      else
        echo "警告：MySQL 支持未启用（mysqli / pdo_mysql 未检测到）。"
      fi
    else
      echo "未找到 ${PREFIX_PHP}/bin/php，无法检测 PHP 模块。"
    fi
  fi
}

post_install_notes() {
  echo
  echo "安装完成。"
  echo "nginx 可执行文件: ${PREFIX_NGINX}/sbin/nginx"
  echo "php 可执行文件: ${PREFIX_PHP}/bin/php"
  echo "php-fpm 配置: ${PREFIX_PHP}/etc/php-fpm.conf 与池目录 ${PREFIX_PHP}/etc/php-fpm.d/"
  echo "已尝试启用并启动 systemd 服务：nginx, php-fpm。请查看服务状态："
  echo "  systemctl status nginx php-fpm"
}

main() {
  parse_args "$@"
  resolve_php_latest_patch
  prompt_install_choice
  check_root
  if [ "$DISABLE_FIREWALL_SELINUX" = true ]; then
    disable_firewall_selinux
  fi
  create_user
  install_build_deps
  mkdir -p "$BUILD_DIR"
  build_fallback_sources

  if [ "$INSTALL_NGINX" = true ]; then
    build_nginx
    ensure_conf_d_included
  fi

  if [ "$INSTALL_PHP" = true ]; then
    build_php
    # 安装 phpredis 扩展（如果可能）
    install_php_redis_extension || true
  fi

  if [ "$INSTALL_NGINX" = true ] || [ "$INSTALL_PHP" = true ]; then
    create_systemd_units
  fi

  if [ "$INSTALL_NGINX" = true ] && [ "$INSTALL_PHP" = true ]; then
    configure_nginx_php_integration
  elif [ "$INSTALL_NGINX" = true ]; then
    echo "nginx 已安装（未配置 PHP 集成）。"
  elif [ "$INSTALL_PHP" = true ]; then
    echo "PHP 已安装（未配置 nginx 集成）。"
  fi

  post_install_notes
  verify_installation
}

main "$@"
