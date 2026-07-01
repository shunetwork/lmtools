#!/usr/bin/env bash
set -euo pipefail

# 安装 PHP javascript-obfuscator 扩展（适用于 CentOS Stream 10）
# 依赖：已通过 install_nginx_php_centos10.sh 编译安装的 PHP（默认 /usr/local/php）
# 使用前请以 root 运行：sudo bash install_php_javascript_obfuscator.sh

PREFIX_PHP="/usr/local/php"
BUILD_DIR="/usr/local/src/build_php_javascript_obfuscator"
PARALLEL_MAKE="$(nproc || echo 1)"
NODEJS_VERSION="22"
JSO_NPM_VERSION="latest"
JSO_BIN="/usr/local/bin/javascript-obfuscator"
NO_INTERACTIVE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_SRC_DIR="${SCRIPT_DIR}/php-ext-javascript-obfuscator"

usage() {
  cat <<EOF
Usage: $0 [--prefix-php PATH] [--build-dir PATH] [--jobs N] [--jso-bin PATH] [--nodejs-version N] [--no-interactive]

Options:
  --prefix-php PATH       PHP 安装前缀（默认 ${PREFIX_PHP}）
  --build-dir PATH        构建目录（默认 ${BUILD_DIR}）
  --jobs N                并行编译数量（默认 ${PARALLEL_MAKE}）
  --jso-bin PATH          javascript-obfuscator CLI 路径（默认 ${JSO_BIN}）
  --nodejs-version N      Node.js 主版本号（默认 ${NODEJS_VERSION}）
  --no-interactive        非交互模式
  -h, --help              显示本帮助
EOF
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix-php) PREFIX_PHP="$2"; shift 2;;
      --build-dir) BUILD_DIR="$2"; shift 2;;
      --jobs) PARALLEL_MAKE="$2"; shift 2;;
      --jso-bin) JSO_BIN="$2"; shift 2;;
      --nodejs-version) NODEJS_VERSION="$2"; shift 2;;
      --no-interactive) NO_INTERACTIVE=true; shift 1;;
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

PHPIZE="${PREFIX_PHP}/bin/phpize"
PHP_CONFIG="${PREFIX_PHP}/bin/php-config"
PHP_INI="${PREFIX_PHP}/etc/php.ini"
PHP_BIN="${PREFIX_PHP}/bin/php"

check_php() {
  if [ ! -x "${PHPIZE}" ]; then
    echo "错误：未找到 phpize: ${PHPIZE}"
    echo "请先运行 install_nginx_php_centos10.sh 安装 PHP。"
    exit 1
  fi
  if [ ! -x "${PHP_CONFIG}" ]; then
    echo "错误：未找到 php-config: ${PHP_CONFIG}"
    exit 1
  fi
}

install_build_deps() {
  echo "==> 安装编译依赖"
  dnf -y makecache || true
  dnf config-manager --set-enabled crb 2>/dev/null || dnf config-manager --set-enabled powertools 2>/dev/null || true

  declare -a pkgs=(
    gcc gcc-c++ make autoconf automake libtool pkgconfig
    wget curl tar which
  )

  for pkg in "${pkgs[@]}"; do
    dnf -y install "$pkg" >/dev/null 2>&1 || echo "警告：安装 $pkg 失败，继续..."
  done
}

install_nodejs() {
  echo "==> 安装 Node.js ${NODEJS_VERSION}.x"

  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    echo "已存在 Node.js: $(node -v), npm: $(npm -v)"
    return 0
  fi

  # 优先尝试 dnf 模块
  if dnf -y module install "nodejs:${NODEJS_VERSION}" >/dev/null 2>&1; then
    echo "已通过 dnf module 安装 Node.js"
    return 0
  fi

  # 回退：NodeSource 仓库
  echo "尝试通过 NodeSource 安装 Node.js..."
  local setup_url="https://rpm.nodesource.com/setup_${NODEJS_VERSION}.x"
  if curl -fsSL "$setup_url" | bash -; then
    dnf -y install nodejs
    return 0
  fi

  echo "错误：无法安装 Node.js，请手动安装后重试。"
  exit 1
}

install_javascript_obfuscator_cli() {
  echo "==> 安装 javascript-obfuscator CLI (npm global)"

  if ! command -v npm >/dev/null 2>&1; then
    echo "错误：npm 不可用"
    exit 1
  fi

  npm install -g "javascript-obfuscator@${JSO_NPM_VERSION}"

  local resolved_bin=""
  if command -v javascript-obfuscator >/dev/null 2>&1; then
    resolved_bin="$(command -v javascript-obfuscator)"
  elif [ -x "/usr/local/bin/javascript-obfuscator" ]; then
    resolved_bin="/usr/local/bin/javascript-obfuscator"
  elif [ -x "/usr/bin/javascript-obfuscator" ]; then
    resolved_bin="/usr/bin/javascript-obfuscator"
  fi

  if [ -z "$resolved_bin" ]; then
    echo "错误：javascript-obfuscator 安装后未找到可执行文件"
    exit 1
  fi

  if [ "$resolved_bin" != "$JSO_BIN" ]; then
    ln -sf "$resolved_bin" "$JSO_BIN" 2>/dev/null || cp -a "$resolved_bin" "$JSO_BIN"
  fi

  echo "javascript-obfuscator: $JSO_BIN ($(${JSO_BIN} --version 2>/dev/null || echo 'version unknown'))"
}

prepare_extension_source() {
  echo "==> 准备扩展源码"

  if [ ! -d "$EXT_SRC_DIR" ]; then
    echo "错误：扩展源码目录不存在: $EXT_SRC_DIR"
    exit 1
  fi

  mkdir -p "$BUILD_DIR"
  rm -rf "${BUILD_DIR}/php-ext-javascript-obfuscator"
  cp -a "$EXT_SRC_DIR" "${BUILD_DIR}/php-ext-javascript-obfuscator"

  # 将 CLI 路径写入编译宏
  sed -i "s|#define JSO_BIN \".*\"|#define JSO_BIN \"${JSO_BIN//\//\\/}\"|" \
    "${BUILD_DIR}/php-ext-javascript-obfuscator/javascript_obfuscator.c"
}

build_php_extension() {
  echo "==> 编译安装 PHP javascript_obfuscator 扩展"

  local src="${BUILD_DIR}/php-ext-javascript-obfuscator"
  cd "$src"

  if [ -f Makefile ] || [ -f configure ]; then
    make clean 2>/dev/null || true
    "${PHPIZE}" --clean 2>/dev/null || true
  fi

  "${PHPIZE}"
  ./configure --with-php-config="${PHP_CONFIG}" --enable-javascript-obfuscator
  make -j"${PARALLEL_MAKE}"
  make install

  local ext_dir
  ext_dir="$("${PHP_CONFIG}" --extension-dir)"
  echo "扩展已安装到: ${ext_dir}/javascript_obfuscator.so"
}

enable_extension() {
  echo "==> 启用扩展"

  mkdir -p "${PREFIX_PHP}/etc/php.d"
  echo "extension=javascript_obfuscator.so" > "${PREFIX_PHP}/etc/php.d/javascript_obfuscator.ini"

  if [ -f "${PHP_INI}" ]; then
    if ! grep -q "javascript_obfuscator.so" "${PHP_INI}" 2>/dev/null; then
      echo "" >> "${PHP_INI}"
      echo "; javascript-obfuscator" >> "${PHP_INI}"
      echo "extension=javascript_obfuscator.so" >> "${PHP_INI}"
    fi
  fi
}

restart_services() {
  echo "==> 重启 php-fpm / nginx"
  if systemctl list-unit-files 2>/dev/null | grep -q '^php-fpm.service'; then
    systemctl restart php-fpm || echo "警告: 重启 php-fpm 失败"
  fi
  systemctl restart nginx 2>/dev/null || true
}

verify_installation() {
  echo "==> 验证安装"

  if "${PHP_BIN}" -m | grep -q '^javascript_obfuscator$'; then
    echo "javascript_obfuscator 扩展: 已加载"
  else
    echo "错误：javascript_obfuscator 扩展未加载"
    exit 1
  fi

  echo ""
  echo "CLI 测试:"
  if command -v "${JSO_BIN}" >/dev/null 2>&1; then
    echo "alert('hi');" | tee /tmp/jso_test_in.js >/dev/null
    "${JSO_BIN}" /tmp/jso_test_in.js -o /tmp/jso_test_out.js
    echo "  javascript-obfuscator CLI: OK"
    rm -f /tmp/jso_test_in.js /tmp/jso_test_out.js
  fi

  echo ""
  echo "PHP 函数测试:"
  "${PHP_BIN}" -r '
    $out = javascript_obfuscator_obfuscate("alert(1);");
    if (!is_string($out) || $out === "") {
        fwrite(STDERR, "obfuscate failed\n");
        exit(1);
    }
    echo "  javascript_obfuscator_obfuscate(): OK\n";
  '

  echo ""
  "${PHP_BIN}" --ri javascript_obfuscator 2>/dev/null || true
}

main() {
  parse_args "$@"
  check_root
  check_php

  echo "===================================="
  echo " Install PHP javascript-obfuscator"
  echo "===================================="
  echo "PHP 前缀: ${PREFIX_PHP}"
  echo "CLI 路径: ${JSO_BIN}"
  echo ""

  install_build_deps
  install_nodejs
  install_javascript_obfuscator_cli
  prepare_extension_source
  build_php_extension
  enable_extension
  restart_services
  verify_installation

  echo ""
  echo "===================================="
  echo " 安装完成"
  echo "===================================="
  echo "用法示例:"
  echo '  <?php'
  echo '  $code = "console.log(\"hello\");";'
  echo '  $obfuscated = javascript_obfuscator_obfuscate($code);'
  echo '  echo $obfuscated;'
  echo ""
}

main "$@"
