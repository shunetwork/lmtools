#!/usr/bin/env bash
set -euo pipefail

# admg.sh - 简单的 nginx/php 管理脚本
# 用途: start|restart|reload|status|config for nginx/php
# 支持通过 --prefix-nginx 和 --prefix-php 覆盖安装前缀

PREFIX_NGINX=/usr/local/nginx
PREFIX_PHP=/usr/local/php

usage() {
  cat <<EOF
用法: $0 [--prefix-nginx PATH] [--prefix-php PATH] <nginx|php> <start|restart|reload|status|config|help>

示例:
  $0 nginx start
  $0 --prefix-nginx /opt/nginx php status

功能:
  start/restart/reload  启动/重启/重载 服务并输出最新状态
  status                输出服务状态 (systemd 或 pidfile 检查)
  config                列出关键二进制和配置文件位置
  help                  显示本帮助

EOF
}

parse_flags() {
  while [[ "$#" -gt 0 && "$1" == --* ]]; do
    case "$1" in
      --prefix-nginx) PREFIX_NGINX="$2"; shift 2;;
      --prefix-php) PREFIX_PHP="$2"; shift 2;;
      -h|--help) usage; exit 0;;
      *) echo "未知选项: $1"; usage; exit 1;;
    esac
  done
  # remaining args
  TARGET=${1:-}
  ACTION=${2:-}
}

# check if systemd unit exists
unit_exists() {
  local u=$1
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files --type=service 2>/dev/null | grep -c "^${u}" >/dev/null || return 1
    return 0
  fi
  return 1
}

svc_action() {
  local unit=$1; local action=$2
  if unit_exists "$unit"; then
    echo "使用 systemctl ${action} ${unit}"
    systemctl ${action} ${unit} || true
  else
    if [[ "$unit" == "nginx.service" ]]; then
      case "$action" in
        start)
          if [ -x "${PREFIX_NGINX}/sbin/nginx" ]; then
            ${PREFIX_NGINX}/sbin/nginx || true
          else
            echo "未找到 ${PREFIX_NGINX}/sbin/nginx";
          fi
          ;;
        reload)
          if [ -x "${PREFIX_NGINX}/sbin/nginx" ]; then
            ${PREFIX_NGINX}/sbin/nginx -s reload || true
          fi
          ;;
        restart)
          if [ -f "${PREFIX_NGINX}/logs/nginx.pid" ]; then
            pid=$(cat "${PREFIX_NGINX}/logs/nginx.pid" 2>/dev/null || true)
            if [ -n "$pid" ] && kill -QUIT "$pid" >/dev/null 2>&1; then
              sleep 1
            fi
          fi
          if [ -x "${PREFIX_NGINX}/sbin/nginx" ]; then
            ${PREFIX_NGINX}/sbin/nginx || true
          fi
          ;;
        stop)
          if [ -f "${PREFIX_NGINX}/logs/nginx.pid" ]; then
            pid=$(cat "${PREFIX_NGINX}/logs/nginx.pid" 2>/dev/null || true)
            if [ -n "$pid" ]; then kill -QUIT "$pid" >/dev/null 2>&1 || true; fi
          fi
          ;;
        *) echo "不支持的动作：$action" ;;
      esac
    elif [[ "$unit" == "php-fpm.service" ]]; then
      case "$action" in
        start)
          if [ -x "${PREFIX_PHP}/sbin/php-fpm" ]; then
            ${PREFIX_PHP}/sbin/php-fpm || true
          else
            echo "未找到 ${PREFIX_PHP}/sbin/php-fpm";
          fi
          ;;
        reload)
          if [ -f "${PREFIX_PHP}/var/run/php-fpm.pid" ]; then
            pid=$(cat "${PREFIX_PHP}/var/run/php-fpm.pid" 2>/dev/null || true)
            if [ -n "$pid" ]; then kill -USR2 "$pid" >/dev/null 2>&1 || true; fi
          fi
          ;;
        restart)
          if [ -f "${PREFIX_PHP}/var/run/php-fpm.pid" ]; then
            pid=$(cat "${PREFIX_PHP}/var/run/php-fpm.pid" 2>/dev/null || true)
            if [ -n "$pid" ]; then kill -QUIT "$pid" >/dev/null 2>&1 || true; fi
          fi
          if [ -x "${PREFIX_PHP}/sbin/php-fpm" ]; then
            ${PREFIX_PHP}/sbin/php-fpm || true
          fi
          ;;
        stop)
          if [ -f "${PREFIX_PHP}/var/run/php-fpm.pid" ]; then
            pid=$(cat "${PREFIX_PHP}/var/run/php-fpm.pid" 2>/dev/null || true)
            if [ -n "$pid" ]; then kill -QUIT "$pid" >/dev/null 2>&1 || true; fi
          fi
          ;;
        *) echo "不支持的动作：$action" ;;
      esac
    else
      echo "未知服务单元：$unit"
    fi
  fi
}

# 简洁状态输出 (用于 start/stop 后)
show_simple_status() {
  local unit=$1
  if [[ "$unit" == "nginx.service" ]]; then
    pidfile="${PREFIX_NGINX}/logs/nginx.pid"
    bin="${PREFIX_NGINX}/sbin/nginx"
    echo "binary: $bin"
    echo "pidfile: $pidfile"
    if [ -f "$pidfile" ]; then
      pid=$(cat "$pidfile" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
        echo "nginx 正在运行 (PID=$pid)"
      else
        echo "nginx pidfile 存在但进程未运行"
      fi
    else
      echo "nginx 已经停止运行"
    fi
  elif [[ "$unit" == "php-fpm.service" ]]; then
    pidfile="${PREFIX_PHP}/var/run/php-fpm.pid"
    bin="${PREFIX_PHP}/sbin/php-fpm"
    echo "binary: $bin"
    echo "pidfile: $pidfile"
    if [ -f "$pidfile" ]; then
      pid=$(cat "$pidfile" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
        echo "php-fpm 正在运行 (PID=$pid)"
      else
        echo "php-fpm pidfile 存在但进程未运行"
      fi
    else
      echo "php-fpm 已经停止运行"
    fi
  fi
}

show_status() {
  local unit=$1
  if [[ "$unit" == "nginx.service" ]]; then
    pidfile="${PREFIX_NGINX}/logs/nginx.pid"
    bin="${PREFIX_NGINX}/sbin/nginx"
    if [ -f "$pidfile" ]; then
      pid=$(cat "$pidfile" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
        # 获取 nginx 版本
        local nginx_ver=$( ${bin} -v 2>&1 | awk '{print $3}' | sed 's/nginx\///' )
        # 获取编译时间 (从 nginx 二进制文件的修改时间)
        local compile_time=$( stat -c '%y' "$bin" 2>/dev/null | cut -d. -f1 | sed 's/-/:/g' | tr ':' '-' | cut -d' ' -f1 )
        # 获取 worker 进程数
        local worker_total=$( ps --ppid "$pid" -o pid= 2>/dev/null | wc -l )
        local worker_running=$( ps --ppid "$pid" -o stat= 2>/dev/null | grep -c 'R' 2>/dev/null || true )
        # 获取运行时间
        local start_time=$( stat -c '%Y' "/proc/${pid}" 2>/dev/null || echo "$(date +%s)" )
        local now=$( date +%s )
        local uptime_sec=$(( now - start_time ))
        local uptime_d=$(( uptime_sec / 86400 ))
        local uptime_h=$(( (uptime_sec % 86400) / 3600 ))
        local uptime_m=$(( (uptime_sec % 3600) / 60 ))
        local uptime_str=$( printf "%dd %02dh" "${uptime_d}" "${uptime_h}" )
        # 获取重载次数
        local reload_count=$( journalctl -u nginx.service --no-pager 2>/dev/null | grep -c 'signal process started' || true )
        # 配置测试
        local config_test=$( ${bin} -t 2>&1 | grep -q "successful" && echo "PASS" || echo "FAIL" )

        echo "运行状态             : 正在运行"
        echo "Nginx Version        : ${nginx_ver}"
        echo "Compile Time         : ${compile_time}"
        echo "Master PID           : ${pid}"
        echo "Worker Processes     : ${worker_total}"
        echo "Worker Running       : ${worker_running}"
        echo "Uptime               : ${uptime_str}"
        echo "Reload Count         : ${reload_count}"
        echo "Config Test          : ${config_test}"
        echo "Config Path          : ${PREFIX_NGINX}/conf/nginx.conf"
      else
        echo "运行状态             : pidfile 存在但进程未运行"
      fi
    else
      echo "运行状态             : 已停止"
    fi
  elif [[ "$unit" == "php-fpm.service" ]]; then
    pidfile="${PREFIX_PHP}/var/run/php-fpm.pid"
    bin="${PREFIX_PHP}/sbin/php-fpm"
    echo "binary: $bin"
    echo "pidfile: $pidfile"
    if [ -f "$pidfile" ]; then
      pid=$(cat "$pidfile" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
        echo "php-fpm 正在运行 (PID=$pid)"
        local pm_count=$(ps --ppid "$pid" -o pid= 2>/dev/null | wc -l)
        echo "php-fpm 进程数: ${pm_count}"
      else
        echo "php-fpm pidfile 存在但进程未运行"
      fi
    else
      echo "php-fpm 已经停止运行"
    fi
    # 显示 PHP 关键参数
    if [ -x "${PREFIX_PHP}/bin/php" ]; then
      echo "PHP 版本: $( ${PREFIX_PHP}/bin/php -r 'echo PHP_VERSION;' 2>/dev/null)"
      echo "memory_limit: $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("memory_limit");' 2>/dev/null)"
      echo "max_execution_time: $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("max_execution_time");' 2>/dev/null)s"
      echo "upload_max_filesize: $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("upload_max_filesize");' 2>/dev/null)"
      echo "post_max_size: $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("post_max_size");' 2>/dev/null)"
      echo "max_input_vars: $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("max_input_vars");' 2>/dev/null)"
      echo "display_errors: $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("display_errors");' 2>/dev/null)"
      echo "date.timezone: $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("date.timezone");' 2>/dev/null)"
      echo "OPcache: $( ${PREFIX_PHP}/bin/php -r 'echo extension_loaded("Zend OPcache") ? "已启用" : "未启用";' 2>/dev/null)"
    fi
  fi
}

show_config() {
  local svc=$1
  if [[ "$svc" == "nginx" ]]; then
    echo "---- nginx 配置与位置 ----"
    echo "binary: ${PREFIX_NGINX}/sbin/nginx"
    echo "main conf: ${PREFIX_NGINX}/conf/nginx.conf"
    echo "conf.d dir: ${PREFIX_NGINX}/conf/conf.d"
    echo "html root: ${PREFIX_NGINX}/html"
    echo "logs: ${PREFIX_NGINX}/logs"
    echo "pidfile: ${PREFIX_NGINX}/logs/nginx.pid"
    if [ -f "${PREFIX_NGINX}/conf/nginx.conf" ]; then
      echo
      echo "包含的配置片段 (前三行预览) :"
      sed -n '1,3p' "${PREFIX_NGINX}/conf/nginx.conf" || true
    fi
  elif [[ "$svc" == "php" ]]; then
    echo "---- php / php-fpm 配置与位置 ----"
    echo "binary: ${PREFIX_PHP}/bin/php"
    echo "php.ini: ${PREFIX_PHP}/etc/php.ini"
    echo "php-fpm conf: ${PREFIX_PHP}/etc/php-fpm.conf"
    echo "php-fpm pools: ${PREFIX_PHP}/etc/php-fpm.d"
    echo "pidfile: ${PREFIX_PHP}/var/run/php-fpm.pid"
    if [ -x "${PREFIX_PHP}/bin/php" ]; then
      echo "extension_dir: $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("extension_dir");' 2>/dev/null || echo "unknown")"
      echo "loaded modules:"
      ${PREFIX_PHP}/bin/php -m 2>/dev/null | sed -n '1,200p' || true
    fi
  else
    echo "未知服务: $svc"
  fi
}

# main
if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

# parse optional flags
parse_flags "$@"

if [ -z "${TARGET}" ] || [ -z "${ACTION}" ]; then
  usage
  exit 1
fi

case "$TARGET" in
  nginx)
    unit=nginx.service
    case "$ACTION" in
      start|restart|reload|stop)
        svc_action "$unit" "$ACTION"
        sleep 1
        show_simple_status "$unit"
        ;;
      status)
        show_status "$unit"
        ;;
      config)
        show_config nginx
        ;;
      help|--help|-h)
        usage
        ;;
      *) echo "未知动作: $ACTION"; usage; exit 1;;
    esac
    ;;
  php)
    unit=php-fpm.service
    case "$ACTION" in
      start|restart|reload|stop)
        svc_action "$unit" "$ACTION"
        sleep 1
        show_simple_status "$unit"
        ;;
      status)
        show_status "$unit"
        ;;
      config)
        show_config php
        ;;
      help|--help|-h)
        usage
        ;;
      *) echo "未知动作: $ACTION"; usage; exit 1;;
    esac
    ;;
  help|--help|-h)
    usage
    ;;
  *) echo "未知目标: $TARGET"; usage; exit 1;;
esac
