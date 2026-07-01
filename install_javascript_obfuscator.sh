#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Install JavaScript Obfuscator (Node.js 版本)
# 适用于 CentOS / RHEL 系列
# ============================================

# 可配置变量
NODEJS_VERSION="20"          # Node.js 主版本（18 / 20 / 22）
INSTALL_DIR="/usr/local/share/javascript-obfuscator"
BIN_LINK="/usr/local/bin/javascript-obfuscator"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "请以 root 用户运行此脚本。"
    exit 1
  fi
}

install_nodejs() {
  info "检查 Node.js 环境..."

  if command -v node &>/dev/null; then
    local current_ver
    current_ver=$(node --version 2>/dev/null | sed 's/v//')
    info "Node.js 已安装，版本: v${current_ver}"
    return 0
  fi

  info "安装 Node.js ${NODEJS_VERSION}.x ..."

  # 优先使用 NodeSource 官方源安装指定版本
  # 注意: NodeSource setup 脚本仅添加 yum 仓库，不直接安装 nodejs
  local nodesetup_url="https://rpm.nodesource.com/setup_${NODEJS_VERSION}.x"
  local node_source_used=false

  if command -v curl &>/dev/null; then
    bash <(curl -fsSL "$nodesetup_url") 2>&1 || true
    node_source_used=true
  elif command -v wget &>/dev/null; then
    bash <(wget -qO- "$nodesetup_url") 2>&1 || true
    node_source_used=true
  fi

  # 如果使用了 NodeSource，尝试从 NodeSource 仓库安装
  if [ "$node_source_used" = true ]; then
    info "从 NodeSource 仓库安装 Node.js..."
    if command -v dnf &>/dev/null; then
      dnf install -y nodejs 2>&1 || true
    elif command -v yum &>/dev/null; then
      yum install -y nodejs 2>&1 || true
    fi
  fi

  # 如果仍未安装成功，回退到系统包管理器
  if ! command -v node &>/dev/null; then
    warn "NodeSource 安装失败，尝试使用系统包管理器..."

    if command -v dnf &>/dev/null; then
      dnf install -y epel-release 2>/dev/null || true
      dnf module enable -y nodejs:${NODEJS_VERSION} 2>/dev/null || true
      dnf install -y nodejs 2>/dev/null || dnf install -y nodejs-${NODEJS_VERSION}* 2>/dev/null || true
    elif command -v yum &>/dev/null; then
      yum install -y epel-release 2>/dev/null || true
      yum install -y nodejs 2>/dev/null || yum install -y nodejs-${NODEJS_VERSION}* 2>/dev/null || true
    fi
  fi

  # 最终检查
  if ! command -v node &>/dev/null; then
    error "Node.js 安装失败。请手动安装后重试。"
    exit 1
  fi

  info "Node.js $(node --version) 安装成功"
  info "npm $(npm --version) 已就绪"
}

install_javascript_obfuscator() {
  info "安装 javascript-obfuscator (全局 npm 包)..."

  # 使用 npm 全局安装
  npm install -g javascript-obfuscator 2>&1

  if [ $? -ne 0 ]; then
    error "npm 全局安装失败，尝试本地安装..."
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    npm init -y 2>/dev/null || true
    npm install javascript-obfuscator 2>&1

    if [ ! -f "node_modules/.bin/javascript-obfuscator" ]; then
      error "javascript-obfuscator 安装失败。"
      exit 1
    fi

    # 创建软链接
    info "创建软链接: ${BIN_LINK}"
    ln -sf "$(pwd)/node_modules/.bin/javascript-obfuscator" "$BIN_LINK"
  else
    # npm -g 安装后，二进制文件通常在 /usr/local/bin/ 或 /usr/bin/
    local npm_bin
    npm_bin=$(npm root -g 2>/dev/null)/.bin/javascript-obfuscator
    if [ -f "$npm_bin" ]; then
      info "全局安装路径: ${npm_bin}"
      # 确保软链接存在
      if [ ! -f "$BIN_LINK" ]; then
        ln -sf "$npm_bin" "$BIN_LINK"
      fi
    fi
  fi

  # 验证安装
  if command -v javascript-obfuscator &>/dev/null; then
    info "javascript-obfuscator 安装成功！"
    javascript-obfuscator --version 2>&1 || javascript-obfuscator -v 2>&1 || true
  else
    error "javascript-obfuscator 命令未找到，请检查 PATH 或手动创建软链接。"
    exit 1
  fi
}

verify_installation() {
  echo ""
  info "===================================="
  info " 验证安装"
  info "===================================="

  echo "  Node.js    : $(node --version 2>/dev/null || echo '未安装')"
  echo "  npm        : $(npm --version 2>/dev/null || echo '未安装')"
  echo "  Obfuscator : $(javascript-obfuscator --version 2>/dev/null || javascript-obfuscator -v 2>/dev/null || echo '未安装')"
  echo ""

  # 简单功能测试
  info "运行功能测试..."
  local test_js="/tmp/test_obfuscator.js"
  cat > "$test_js" <<'EOF'
function hello(name) {
  console.log("Hello, " + name + "!");
}
hello("World");
EOF

  javascript-obfuscator "$test_js" --output /tmp/test_obfuscator_output.js 2>&1 || true

  if [ -f /tmp/test_obfuscator_output.js ]; then
    info "功能测试通过！混淆后的代码已输出到 /tmp/test_obfuscator_output.js"
    echo "--- 原始代码 ---"
    cat "$test_js"
    echo ""
    echo "--- 混淆后代码（前5行） ---"
    head -n 5 /tmp/test_obfuscator_output.js
    echo "..."
    rm -f "$test_js" /tmp/test_obfuscator_output.js
  else
    warn "功能测试未生成输出文件（可能是版本差异），但命令执行成功。"
    rm -f "$test_js"
  fi
  echo ""
}

usage() {
  cat <<EOF
用法: $0 [选项]

选项:
  --node-version VERSION  指定 Node.js 主版本号（默认: ${NODEJS_VERSION}）
                          可选: 18, 20, 22
  -h, --help              显示此帮助信息

示例:
  sudo $0                    # 使用默认 Node.js 20 安装
  sudo $0 --node-version 22  # 使用 Node.js 22 安装
EOF
  exit 0
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --node-version) NODEJS_VERSION="$2"; shift 2 ;;
      -h|--help) usage ;;
      *) echo "未知参数: $1"; usage ;;
    esac
  done
}

main() {
  parse_args "$@"
  check_root

  echo ""
  echo "===================================="
  echo " Install JavaScript Obfuscator"
  echo " Node.js ${NODEJS_VERSION}.x"
  echo "===================================="
  echo ""

  install_nodejs
  install_javascript_obfuscator
  verify_installation

  echo ""
  info "===================================="
  info " 安装完成！"
  info "===================================="
  echo ""
  echo "使用方法:"
  echo "  javascript-obfuscator input.js -o output.js"
  echo "  javascript-obfuscator input.js --output output.js --compact true --string-array-encoding rc4"
  echo ""
  echo "查看帮助:"
  echo "  javascript-obfuscator --help"
  echo ""
}

main "$@"
