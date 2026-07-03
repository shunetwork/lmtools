#!/usr/bin/env bash
set -euo pipefail

# admg.sh - nginx/php/mysql/redis 管理脚本
# 用途: start|restart|reload|status|config for nginx/php/mysql/redis
# 支持通过 --prefix-xxx 覆盖安装前缀

PREFIX_NGINX=/usr/local/nginx
PREFIX_PHP=/usr/local/php
PREFIX_MYSQL=/usr/local/mysql
PREFIX_REDIS=/usr/local/redis

usage() {
  cat <<EOF
用法: $0 [OPTIONS] <nginx|php|mysql|redis> <start|restart|reload|status|config|help>

选项:
  --prefix-nginx PATH   Nginx 安装前缀（默认: ${PREFIX_NGINX}）
  --prefix-php PATH     PHP 安装前缀（默认: ${PREFIX_PHP}）
  --prefix-mysql PATH   MySQL 安装前缀（默认: ${PREFIX_MYSQL}）
  --prefix-redis PATH   Redis 安装前缀（默认: ${PREFIX_REDIS}）
  -h, --help            显示本帮助

示例:
  $0 nginx start
  $0 mysql status
  $0 redis status
  $0 --prefix-redis /opt/redis redis config

功能:
  start/restart/reload  启动/重启/重载 服务并输出最新状态
  status                输出服务状态（systemd 或 pidfile 检查）
  config                列出关键二进制和配置文件位置
  help                  显示本帮助

EOF
}

parse_flags() {
  while [[ "$#" -gt 0 && "$1" == --* ]]; do
    case "$1" in
      --prefix-nginx) PREFIX_NGINX="$2"; shift 2;;
      --prefix-php)   PREFIX_PHP="$2";   shift 2;;
      --prefix-mysql) PREFIX_MYSQL="$2"; shift 2;;
      --prefix-redis) PREFIX_REDIS="$2"; shift 2;;
      -h|--help) usage; exit 0;;
      *) echo "未知选项: $1"; usage; exit 1;;
    esac
  done
  TARGET=${1:-}
  ACTION=${2:-}
}

# ---- 辅助函数 ----
unit_exists() {
  local u=$1
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${u}" && return 0 || return 1
  fi
  return 1
}

get_pid() {
  local pidfile=$1
  if [ -f "$pidfile" ]; then
    cat "$pidfile" 2>/dev/null || true
  fi
}

is_running() {
  local pid=$1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ---- 服务操作 ----
svc_action() {
  local unit=$1; local action=$2
  # 对于 redis，优先尝试 systemctl（即使 unit_exists 检测失败）
  if [ "$unit" = "redis.service" ]; then
    if command -v systemctl >/dev/null 2>&1; then
      local svc_exists
      svc_exists=$(systemctl list-unit-files --type=service 2>/dev/null | grep -c "^redis.service" || true)
      if [ "$svc_exists" -gt 0 ]; then
        if [ "$action" = "stop" ]; then
          # 处理 Restart=always：临时禁用自动重启，停止后再恢复
          local restart_policy
          restart_policy=$(systemctl show redis.service -p Restart 2>/dev/null | cut -d= -f2 || true)
          if [ "$restart_policy" = "always" ] || [ "$restart_policy" = "on-failure" ]; then
            echo "检测到 Restart=${restart_policy}，临时禁用自动重启..."
            systemctl set-property redis.service Restart=no 2>/dev/null || true
            systemctl stop redis.service 2>/dev/null || true
            # 恢复 Restart 策略
            systemctl set-property redis.service Restart="${restart_policy}" 2>/dev/null || true
            echo "Redis 已停止（已恢复 Restart=${restart_policy}）"
          else
            echo "使用 systemctl ${action} ${unit}"
            systemctl "${action}" "${unit}" || true
          fi
        else
          echo "使用 systemctl ${action} ${unit}"
          systemctl "${action}" "${unit}" || true
        fi
        return
      fi
    fi
    # systemctl 不可用或服务不存在，走 redis_direct
    redis_direct "$action"
    return
  fi

  # 其他服务（nginx/php/mysql）保持原有逻辑
  if unit_exists "$unit"; then
    echo "使用 systemctl ${action} ${unit}"
    systemctl "${action}" "${unit}" || true
  else
    case "$unit" in
      nginx.service)    nginx_direct "$action" ;;
      php-fpm.service)  php_direct "$action" ;;
      mysqld.service)   mysql_direct "$action" ;;
      *) echo "未知服务单元：$unit" ;;
    esac
  fi
}

nginx_direct() {
  local action=$1
  local bin="${PREFIX_NGINX}/sbin/nginx"
  local pidfile="${PREFIX_NGINX}/logs/nginx.pid"
  case "$action" in
    start)
      if [ -x "$bin" ]; then "$bin" || true; else echo "未找到 $bin"; fi ;;
    reload)
      if [ -x "$bin" ]; then "$bin" -s reload || true; fi ;;
    restart)
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then kill -QUIT "$pid" 2>/dev/null || true; sleep 1; fi
      if [ -x "$bin" ]; then "$bin" || true; fi ;;
    stop)
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ]; then kill -QUIT "$pid" 2>/dev/null || true; fi ;;
  esac
}

php_direct() {
  local action=$1
  local bin="${PREFIX_PHP}/sbin/php-fpm"
  local pidfile="${PREFIX_PHP}/var/run/php-fpm.pid"
  case "$action" in
    start)
      if [ -x "$bin" ]; then "$bin" || true; else echo "未找到 $bin"; fi ;;
    reload)
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then kill -USR2 "$pid" 2>/dev/null || true; fi ;;
    restart)
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then kill -QUIT "$pid" 2>/dev/null || true; fi
      if [ -x "$bin" ]; then "$bin" || true; fi ;;
    stop)
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ]; then kill -QUIT "$pid" 2>/dev/null || true; fi ;;
  esac
}

mysql_direct() {
  local action=$1
  local bin="${PREFIX_MYSQL}/bin/mysqld"
  local pidfile="/var/run/mysqld/mysqld.pid"
  case "$action" in
    start)
      if [ -x "$bin" ]; then
        if [ -f "$pidfile" ]; then
          local pid; pid=$(get_pid "$pidfile")
          if is_running "$pid"; then echo "MySQL 已在运行 (PID=$pid)"; return; fi
        fi
        "$bin" --defaults-file=/etc/my.cnf --user=mysql &
        echo "MySQL 启动中..."
        sleep 2
      else
        echo "未找到 $bin"
      fi ;;
    reload)
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then
        kill -HUP "$pid" 2>/dev/null || true
        echo "MySQL 已重载"
      fi ;;
    restart)
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then
        kill -QUIT "$pid" 2>/dev/null || true
        sleep 3
      fi
      if [ -x "$bin" ]; then
        "$bin" --defaults-file=/etc/my.cnf --user=mysql &
        echo "MySQL 重启中..."
        sleep 2
      fi ;;
    stop)
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then
        kill -QUIT "$pid" 2>/dev/null || true
        echo "MySQL 停止中..."
      fi ;;
  esac
}

# 查找 redis-cli 可执行文件（按优先级）
_find_redis_cli() {
  local cli=""
  for c in "${PREFIX_REDIS}/bin/redis-cli" "/usr/local/bin/redis-cli" "/usr/bin/redis-cli"; do
    [ -x "$c" ] && { cli="$c"; break; }
  done
  echo "$cli"
}

redis_direct() {
  local action=$1
  local bin="${PREFIX_REDIS}/bin/redis-server"
  local cli; cli=$(_find_redis_cli)
  # 尝试多个可能的配置文件路径
  local conf=""
  for c in /www/server/redis/redis.conf /etc/redis/redis.conf "${PREFIX_REDIS}/redis.conf"; do
    [ -f "$c" ] && { conf="$c"; break; }
  done
  [ -z "$conf" ] && conf="/etc/redis/redis.conf"
  local port="6379"
  local pidfile="/var/run/redis/redis.pid"
  # 从配置中读取端口和 pidfile
  if [ -f "$conf" ]; then
    local conf_port; conf_port=$(grep -E "^port " "$conf" 2>/dev/null | awk '{print $2}')
    [ -n "$conf_port" ] && port="$conf_port"
    local conf_pidfile; conf_pidfile=$(grep -E "^pidfile " "$conf" 2>/dev/null | awk '{print $2}')
    [ -n "$conf_pidfile" ] && pidfile="$conf_pidfile"
  fi

  # 获取 Redis PID 的通用函数：优先 pidfile，其次 systemd，其次 pgrep，其次 ps
  _redis_get_pid() {
    local p
    p=$(get_pid "$pidfile")
    if [ -z "$p" ] || ! is_running "$p"; then
      if command -v systemctl >/dev/null 2>&1; then
        p=$(systemctl show redis.service -p MainPID 2>/dev/null | cut -d= -f2)
      fi
    fi
    # systemctl 可能返回 0（已退出），过滤掉
    [ "$p" = "0" ] && p=""
    if [ -z "$p" ] || ! is_running "$p"; then
      p=$(pgrep redis-server 2>/dev/null | head -1 || true)
    fi
    if [ -z "$p" ] || ! is_running "$p"; then
      p=$(ps -ef 2>/dev/null | grep '[r]edis-server' | awk '{print $2}' | head -1 || true)
    fi
    echo "$p"
  }

  case "$action" in
    start)
      if [ -x "$bin" ]; then
        local pid; pid=$(_redis_get_pid)
        if is_running "$pid"; then echo "Redis 已在运行 (PID=$pid)"; return; fi
        # 如果配置中 supervised 为 systemd，优先使用 systemd-run 启动
        if grep -q "^supervised systemd" "$conf" 2>/dev/null; then
          systemctl start redis.service 2>/dev/null || true
        else
          "$bin" "$conf" &
        fi
        echo "Redis 启动中..."
        sleep 2
      else
        echo "未找到 $bin"
      fi ;;
    reload)
      local pid; pid=$(_redis_get_pid)
      if [ -n "$pid" ] && is_running "$pid"; then
        kill -HUP "$pid" 2>/dev/null || true
        echo "Redis 已重载"
      fi ;;
    restart)
      local pid; pid=$(_redis_get_pid)
      if [ -n "$pid" ] && is_running "$pid"; then
        kill -QUIT "$pid" 2>/dev/null || true
        sleep 2
      fi
      if [ -x "$bin" ]; then
        if grep -q "^supervised systemd" "$conf" 2>/dev/null; then
          systemctl restart redis.service 2>/dev/null || true
        else
          "$bin" "$conf" &
        fi
        echo "Redis 重启中..."
        sleep 2
      fi ;;
    stop)
      local pid; pid=$(_redis_get_pid)
      if [ -n "$pid" ] && is_running "$pid"; then
        # 优先使用 redis-cli shutdown 优雅关闭
        if [ -x "$cli" ]; then
          local auth=""
          local conf_pw; conf_pw=$(grep -E "^requirepass " "$conf" 2>/dev/null | awk '{print $2}')
          [ -n "$conf_pw" ] && auth="-a '${conf_pw}'"
          eval "$cli -p '$port' $auth shutdown" 2>/dev/null || kill -QUIT "$pid" 2>/dev/null || true
        else
          kill -QUIT "$pid" 2>/dev/null || true
        fi
        echo "Redis 停止中..."
      else
        echo "Redis 未在运行"
      fi ;;
  esac
}

# ---- 简洁状态输出 ----
show_simple_status() {
  local unit=$1
  case "$unit" in
    nginx.service)
      local pidfile="${PREFIX_NGINX}/logs/nginx.pid"
      local bin="${PREFIX_NGINX}/sbin/nginx"
      echo "binary: $bin"
      echo "pidfile: $pidfile"
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then echo "nginx 正在运行 (PID=$pid)"
      elif [ -n "$pid" ]; then echo "nginx pidfile 存在但进程未运行"
      else echo "nginx 已经停止运行"; fi ;;
    php-fpm.service)
      local pidfile="${PREFIX_PHP}/var/run/php-fpm.pid"
      local bin="${PREFIX_PHP}/sbin/php-fpm"
      echo "binary: $bin"
      echo "pidfile: $pidfile"
      local pid; pid=$(get_pid "$pidfile")
      # 如果 pidfile 不存在，尝试从 systemd 获取 PID
      if [ -z "$pid" ] && command -v systemctl >/dev/null 2>&1; then
        pid=$(systemctl show php-fpm.service -p MainPID 2>/dev/null | cut -d= -f2)
      fi
      # 如果 systemd 也没有，尝试 pgrep（不用 -x，因为进程名可能包含额外信息）
      if [ -z "$pid" ] || ! is_running "$pid"; then
        pid=$(pgrep php-fpm 2>/dev/null | head -1 || true)
      fi
      # 最后尝试通过 ps 直接查找
      if [ -z "$pid" ] || ! is_running "$pid"; then
        pid=$(ps -ef 2>/dev/null | grep '[p]hp-fpm:' | awk '{print $2}' | head -1 || true)
      fi
      if [ -n "$pid" ] && is_running "$pid"; then echo "php-fpm 正在运行 (PID=$pid)"
      elif [ -n "$pid" ]; then echo "php-fpm pidfile 存在但进程未运行"
      else echo "php-fpm 已经停止运行"; fi ;;
    mysqld.service)
      local pidfile="/var/run/mysqld/mysqld.pid"
      local bin="${PREFIX_MYSQL}/bin/mysqld"
      echo "binary: $bin"
      echo "pidfile: $pidfile"
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then echo "MySQL 正在运行 (PID=$pid)"
      elif [ -n "$pid" ]; then echo "MySQL pidfile 存在但进程未运行"
      else echo "MySQL 已经停止运行"; fi ;;
    redis.service)
      local bin="${PREFIX_REDIS}/bin/redis-server"
      # 从配置读取 pidfile 路径
      local pidfile="/var/run/redis/redis.pid"
      local conf=""
      for c in /www/server/redis/redis.conf /etc/redis/redis.conf "${PREFIX_REDIS}/redis.conf"; do
        [ -f "$c" ] && { conf="$c"; break; }
      done
      [ -f "$conf" ] && local conf_pidfile; conf_pidfile=$(grep -E "^pidfile " "$conf" 2>/dev/null | awk '{print $2}')
      [ -n "$conf_pidfile" ] && pidfile="$conf_pidfile"
      echo "binary: $bin"
      echo "pidfile: $pidfile"
      local pid; pid=$(get_pid "$pidfile")
      # 如果 pidfile 不存在，尝试从 systemd 获取 PID
      if [ -z "$pid" ] && command -v systemctl >/dev/null 2>&1; then
        pid=$(systemctl show redis.service -p MainPID 2>/dev/null | cut -d= -f2)
      fi
      # systemctl 可能返回 0（已退出），过滤掉
      [ "$pid" = "0" ] && pid=""
      # 如果 systemd 也没有，尝试 pgrep（不用 -x，进程名可能不精确匹配）
      if [ -z "$pid" ] || ! is_running "$pid"; then
        pid=$(pgrep redis-server 2>/dev/null | head -1 || true)
      fi
      # 最后尝试通过 ps 直接查找
      if [ -z "$pid" ] || ! is_running "$pid"; then
        pid=$(ps -ef 2>/dev/null | grep '[r]edis-server' | awk '{print $2}' | head -1 || true)
      fi
      if [ -n "$pid" ] && is_running "$pid"; then echo "Redis 正在运行 (PID=$pid)"
      elif [ -n "$pid" ]; then echo "Redis pidfile 存在但进程未运行"
      else echo "Redis 已经停止运行"; fi ;;

  esac
}

# ---- 详细状态输出 ----
show_status() {
  local unit=$1
  case "$unit" in
    nginx.service)
      local pidfile="${PREFIX_NGINX}/logs/nginx.pid"
      local bin="${PREFIX_NGINX}/sbin/nginx"
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then
        local nginx_ver; nginx_ver=$(${bin} -v 2>&1 | awk '{print $3}' | sed 's/nginx\///')
        local compile_time; compile_time=$(stat -c '%y' "$bin" 2>/dev/null | cut -d. -f1)
        local worker_total; worker_total=$(ps --ppid "$pid" -o pid= 2>/dev/null | wc -l)
        local worker_running; worker_running=$(ps --ppid "$pid" -o stat= 2>/dev/null | grep -c 'R' 2>/dev/null || true)
        local start_time; start_time=$(stat -c '%Y' "/proc/${pid}" 2>/dev/null || echo "$(date +%s)")
        local now; now=$(date +%s)
        local uptime_sec=$(( now - start_time ))
        local uptime_str; uptime_str=$(printf "%dd %02dh" $((uptime_sec/86400)) $(((uptime_sec%86400)/3600)))
        local reload_count; reload_count=$(journalctl -u nginx.service --no-pager 2>/dev/null | grep -c 'signal process started' || true)
        local config_test; config_test=$(${bin} -t 2>&1 | grep -q "successful" && echo "PASS" || echo "FAIL")
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
        echo "运行状态             : 已停止"
      fi ;;
    php-fpm.service)
      local pidfile="${PREFIX_PHP}/var/run/php-fpm.pid"
      local bin="${PREFIX_PHP}/sbin/php-fpm"
      local pid; pid=$(get_pid "$pidfile")
      # 如果 pidfile 不存在，尝试从 systemd 获取 PID
      if [ -z "$pid" ] && command -v systemctl >/dev/null 2>&1; then
        pid=$(systemctl show php-fpm.service -p MainPID 2>/dev/null | cut -d= -f2)
      fi
      # 如果 systemd 也没有，尝试 pgrep（不用 -x，因为进程名可能包含额外信息）
      if [ -z "$pid" ] || ! is_running "$pid"; then
        pid=$(pgrep php-fpm 2>/dev/null | head -1 || true)
      fi
      # 最后尝试通过 ps 直接查找
      if [ -z "$pid" ] || ! is_running "$pid"; then
        pid=$(ps -ef 2>/dev/null | grep '[p]hp-fpm:' | awk '{print $2}' | head -1 || true)
      fi
      if [ -n "$pid" ] && is_running "$pid"; then
        echo "运行状态             : 正在运行"
        echo "Master PID           : ${pid}"
        local pm_count; pm_count=$(ps --ppid "$pid" -o pid= 2>/dev/null | wc -l)
        echo "Worker Processes     : ${pm_count}"
      else
        echo "运行状态             : 已停止"
      fi
      if [ -x "${PREFIX_PHP}/bin/php" ]; then
        echo "PHP Version          : $( ${PREFIX_PHP}/bin/php -r 'echo PHP_VERSION;' 2>/dev/null)"
        echo "memory_limit         : $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("memory_limit");' 2>/dev/null)"
        echo "max_execution_time   : $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("max_execution_time");' 2>/dev/null)s"
        echo "upload_max_filesize  : $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("upload_max_filesize");' 2>/dev/null)"
        echo "post_max_size        : $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("post_max_size");' 2>/dev/null)"
        echo "max_input_vars       : $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("max_input_vars");' 2>/dev/null)"
        echo "display_errors       : $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("display_errors");' 2>/dev/null)"
        echo "date.timezone        : $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("date.timezone");' 2>/dev/null)"
        echo "OPcache              : $( ${PREFIX_PHP}/bin/php -r 'echo extension_loaded("Zend OPcache") ? "已启用" : "未启用";' 2>/dev/null)"
      fi ;;
    mysqld.service)
      local pidfile="/var/run/mysqld/mysqld.pid"
      local bin="${PREFIX_MYSQL}/bin/mysqld"
      local mysql_client="${PREFIX_MYSQL}/bin/mysql"
      local pid; pid=$(get_pid "$pidfile")
      if [ -n "$pid" ] && is_running "$pid"; then
        echo "运行状态             : 正在运行"
        echo "Master PID           : ${pid}"

        # 尝试多种方式获取 MySQL 信息（优先使用 conn.sh，其次密码文件，最后无密码）
        local mysql_cmd="${mysql_client} -u root"
        if command -v conn.sh >/dev/null 2>&1; then
          mysql_cmd="conn.sh"
        elif [ -f /root/.mysql_root_pw ]; then
          local pw; pw=$(grep ROOT_PASSWORD /root/.mysql_root_pw 2>/dev/null | cut -d"'" -f2 || true)
          if [ -n "$pw" ]; then
            mysql_cmd="${mysql_client} -u root -p'${pw}'"
          fi
        fi

        if [ -x "$mysql_client" ]; then
          # MySQL 版本
          local mysql_ver; mysql_ver=$($mysql_cmd -e "SELECT VERSION();" 2>/dev/null | sed -n '2p' || echo "未知")
          echo "MySQL Version        : ${mysql_ver}"

          # 运行时间（从进程）
          local start_time; start_time=$(stat -c '%Y' "/proc/${pid}" 2>/dev/null || echo "$(date +%s)")
          local now; now=$(date +%s)
          local uptime_sec=$(( now - start_time ))
          local uptime_str; uptime_str=$(printf "%dd %02dh" $((uptime_sec/86400)) $(((uptime_sec%86400)/3600)))
          echo "Uptime               : ${uptime_str}"

          # 关键状态
          local status_info; status_info=$($mysql_cmd -e "SHOW GLOBAL STATUS LIKE 'Questions'; SHOW GLOBAL STATUS LIKE 'Threads_connected';" 2>/dev/null || true)
          local questions; questions=$(echo "$status_info" | grep "Questions" | awk '{print $2}')
          local threads; threads=$(echo "$status_info" | grep "Threads_connected" | awk '{print $2}')
          echo "Total Queries        : ${questions:-N/A}"
          echo "Connected Threads    : ${threads:-N/A}"

          # InnoDB 缓冲池
          local bp_size; bp_size=$($mysql_cmd -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null | sed -n '2p' | awk '{print $2}')
          if [ -n "$bp_size" ]; then
            echo "InnoDB Buffer Pool   : $(( bp_size / 1024 / 1024 ))MB"
          fi
        fi
      else
        echo "运行状态             : 已停止"
      fi
      echo "Config Path          : /etc/my.cnf"
      echo "Data Directory       : /var/lib/mysql"
      echo "Socket               : /var/run/mysqld/mysqld.sock"
      echo "Error Log            : /var/log/mysqld.err" ;;
    redis.service)
      local bin="${PREFIX_REDIS}/bin/redis-server"
      local cli; cli=$(_find_redis_cli)
      # 尝试多个可能的配置文件路径
      local conf=""
      for c in /www/server/redis/redis.conf /etc/redis/redis.conf "${PREFIX_REDIS}/redis.conf"; do
        [ -f "$c" ] && { conf="$c"; break; }
      done
      [ -z "$conf" ] && conf="/etc/redis/redis.conf"

      # 从配置读取 pidfile 路径
      local pidfile="/var/run/redis/redis.pid"
      if [ -f "$conf" ]; then
        local conf_pidfile; conf_pidfile=$(grep -E "^pidfile " "$conf" 2>/dev/null | awk '{print $2}')
        [ -n "$conf_pidfile" ] && pidfile="$conf_pidfile"
      fi

      local pid; pid=$(get_pid "$pidfile")
      # 如果 pidfile 不存在，尝试从 systemd 获取 PID
      if [ -z "$pid" ] && command -v systemctl >/dev/null 2>&1; then
        pid=$(systemctl show redis.service -p MainPID 2>/dev/null | cut -d= -f2)
      fi
      # 如果 systemd 也没有，尝试 pgrep（不用 -x，进程名可能不精确匹配）
      if [ -z "$pid" ] || ! is_running "$pid"; then
        pid=$(pgrep redis-server 2>/dev/null | head -1 || true)
      fi
      # 最后尝试通过 ps 直接查找
      if [ -z "$pid" ] || ! is_running "$pid"; then
        pid=$(ps -ef 2>/dev/null | grep '[r]edis-server' | awk '{print $2}' | head -1 || true)
      fi

      if [ -n "$pid" ] && is_running "$pid"; then

        # ---- 从配置读取端口、密码、bind ----
        local port="6379"
        local auth=""
        local bind="127.0.0.1"
        if [ -f "$conf" ]; then
          local conf_port; conf_port=$(grep -E "^port " "$conf" 2>/dev/null | awk '{print $2}')
          [ -n "$conf_port" ] && port="$conf_port"
          local conf_bind; conf_bind=$(grep -E "^bind " "$conf" 2>/dev/null | awk '{print $2}')
          [ -n "$conf_bind" ] && bind="$conf_bind"
          local conf_pw; conf_pw=$(grep -E "^requirepass " "$conf" 2>/dev/null | awk '{print $2}')
          [ -n "$conf_pw" ] && auth="-a '${conf_pw}'"
        fi

        # ---- 通过 redis-cli 获取 INFO ----
        local redis_info=""
        if [ -x "$cli" ]; then
          redis_info=$(eval "$cli -p '$port' $auth info 2>/dev/null" || true)
        fi

        # ---- 提取各字段（注意：redis-cli 返回 \r\n，需去除 \r） ----
        local redis_ver; redis_ver=$(echo "$redis_info" | grep "^redis_version:" | cut -d: -f2 | tr -d '\r' || true)
        local uptime_sec; uptime_sec=$(echo "$redis_info" | grep "^uptime_in_seconds:" | cut -d: -f2 | tr -d '\r' || true)
        local role; role=$(echo "$redis_info" | grep "^role:" | cut -d: -f2 | tr -d '\r' || true)
        local used_mem_human; used_mem_human=$(echo "$redis_info" | grep "^used_memory_human:" | cut -d: -f2 | tr -d '\r' || true)
        local used_mem_rss_human; used_mem_rss_human=$(echo "$redis_info" | grep "^used_memory_rss_human:" | cut -d: -f2 | tr -d '\r' || true)
        local maxmemory; maxmemory=$(echo "$redis_info" | grep "^maxmemory:" | cut -d: -f2 | tr -d '\r' || true)
        local maxmemory_policy; maxmemory_policy=$(echo "$redis_info" | grep "^maxmemory_policy:" | cut -d: -f2 | tr -d '\r' || true)
        local connected_clients; connected_clients=$(echo "$redis_info" | grep "^connected_clients:" | cut -d: -f2 | tr -d '\r' || true)
        local blocked_clients; blocked_clients=$(echo "$redis_info" | grep "^blocked_clients:" | cut -d: -f2 | tr -d '\r' || true)
        local total_connections_received; total_connections_received=$(echo "$redis_info" | grep "^total_connections_received:" | cut -d: -f2 | tr -d '\r' || true)
        local keyspace_hits; keyspace_hits=$(echo "$redis_info" | grep "^keyspace_hits:" | cut -d: -f2 | tr -d '\r' || true)
        local keyspace_misses; keyspace_misses=$(echo "$redis_info" | grep "^keyspace_misses:" | cut -d: -f2 | tr -d '\r' || true)
        local total_commands_processed; total_commands_processed=$(echo "$redis_info" | grep "^total_commands_processed:" | cut -d: -f2 | tr -d '\r' || true)
        local instantaneous_ops_per_sec; instantaneous_ops_per_sec=$(echo "$redis_info" | grep "^instantaneous_ops_per_sec:" | cut -d: -f2 | tr -d '\r' || true)
        local used_cpu_sys; used_cpu_sys=$(echo "$redis_info" | grep "^used_cpu_sys:" | cut -d: -f2 | tr -d '\r' || true)
        local used_cpu_user; used_cpu_user=$(echo "$redis_info" | grep "^used_cpu_user:" | cut -d: -f2 | tr -d '\r' || true)
        local rdb_last_save_time; rdb_last_save_time=$(echo "$redis_info" | grep "^rdb_last_save_time:" | cut -d: -f2 | tr -d '\r' || true)
        local aof_enabled; aof_enabled=$(echo "$redis_info" | grep "^aof_enabled:" | cut -d: -f2 | tr -d '\r' || true)
        local aof_current_size; aof_current_size=$(echo "$redis_info" | grep "^aof_current_size:" | cut -d: -f2 | tr -d '\r' || true)
        local aof_rewrite_in_progress; aof_rewrite_in_progress=$(echo "$redis_info" | grep "^aof_rewrite_in_progress:" | cut -d: -f2 | tr -d '\r' || true)
        local maxclients; maxclients=$(echo "$redis_info" | grep "^maxclients:" | cut -d: -f2 | tr -d '\r' || true)
        local tls_port; tls_port=$(echo "$redis_info" | grep "^tls_port:" | cut -d: -f2 | tr -d '\r' || true)
        local connected_slaves; connected_slaves=$(echo "$redis_info" | grep "^connected_slaves:" | cut -d: -f2 | tr -d '\r' || true)
        local db0_keys; db0_keys=$(echo "$redis_info" | grep "^db0:" | cut -d: -f2 | sed 's/,/\n/g' | grep "^keys=" | cut -d= -f2 | tr -d '\r' || true)
        local db0_expires; db0_expires=$(echo "$redis_info" | grep "^db0:" | cut -d: -f2 | sed 's/,/\n/g' | grep "^expires=" | cut -d= -f2 | tr -d '\r' || true)

        # ---- 计算衍生值 ----
        local uptime_str=""
        if [ -n "$uptime_sec" ]; then
          local d=$((uptime_sec / 86400))
          local h=$(( (uptime_sec % 86400) / 3600 ))
          local m=$(( (uptime_sec % 3600) / 60 ))
          uptime_str=$(printf "%dd %02dh %02dm" "$d" "$h" "$m")
        fi

        local hit_ratio="N/A"
        if [ -n "$keyspace_hits" ] && [ -n "$keyspace_misses" ]; then
          local total_ops=$(( keyspace_hits + keyspace_misses ))
          if [ "$total_ops" -gt 0 ]; then
            hit_ratio=$(awk "BEGIN {printf \"%.2f%%\", ${keyspace_hits} / ${total_ops} * 100}")
          fi
        fi

        local maxmem_human="N/A"
        if [ -n "$maxmemory" ] && [ "$maxmemory" -gt 0 ]; then
          maxmem_human=$(awk "BEGIN {printf \"%.0f MB\", ${maxmemory} / 1024 / 1024}")
        elif [ -n "$maxmemory" ] && [ "$maxmemory" -eq 0 ]; then
          maxmem_human="无限制"
        fi

        local aof_size_human="N/A"
        if [ -n "$aof_current_size" ] && [ "$aof_current_size" -gt 0 ]; then
          aof_size_human=$(awk "BEGIN {printf \"%.0f MB\", ${aof_current_size} / 1024 / 1024}")
        fi

        local cpu_usage="N/A"
        if [ -n "$used_cpu_sys" ] && [ -n "$used_cpu_user" ] && [ -n "$uptime_sec" ] && [ "$uptime_sec" -gt 0 ]; then
          local cpu_total; cpu_total=$(awk "BEGIN {printf \"%.1f\", ${used_cpu_sys} + ${used_cpu_user}}")
          cpu_usage=$(awk "BEGIN {printf \"%.1f%%\", ${cpu_total} / ${uptime_sec} * 100}")
        fi

        local mem_usage_pct="N/A"
        if [ -n "$maxmemory" ] && [ "$maxmemory" -gt 0 ] && [ -n "$used_mem_human" ]; then
          local used_bytes; used_bytes=$(echo "$redis_info" | grep "^used_memory:" | cut -d: -f2)
          if [ -n "$used_bytes" ] && [ "$used_bytes" -gt 0 ]; then
            mem_usage_pct=$(awk "BEGIN {printf \"%.0f%%\", ${used_bytes} / ${maxmemory} * 100}")
          fi
        fi

        local total_keys=0
        local db_keys_list=""
        local db_count=0
        # 遍历所有 dbN 获取 keys
        while IFS= read -r line; do
          local db_name; db_name=$(echo "$line" | cut -d: -f1)
          local db_keys_val; db_keys_val=$(echo "$line" | cut -d: -f2 | sed 's/,/\n/g' | grep "^keys=" | cut -d= -f2)
          if [ -n "$db_keys_val" ]; then
            total_keys=$(( total_keys + db_keys_val ))
            db_count=$(( db_count + 1 ))
            [ -z "$db_keys_list" ] && db_keys_list="${db_name}: ${db_keys_val}" || db_keys_list="${db_keys_list}, ${db_name}: ${db_keys_val}"
          fi
        done < <(echo "$redis_info" | grep "^db[0-9]\+:")

        local qps="0"
        [ -n "$instantaneous_ops_per_sec" ] && qps="$instantaneous_ops_per_sec"

        local total_cmds="N/A"
        if [ -n "$total_commands_processed" ]; then
          total_cmds=$(printf "%'d" "$total_commands_processed" 2>/dev/null || echo "$total_commands_processed")
        fi

        local rdb_last_save_str="N/A"
        if [ -n "$rdb_last_save_time" ]; then
          rdb_last_save_str=$(date -d "@${rdb_last_save_time}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$rdb_last_save_time")
        fi

        local aof_status="未开启"
        [ "$aof_enabled" = "1" ] && aof_status="已开启"

        local aof_rewrite_status="否"
        [ "$aof_rewrite_in_progress" = "1" ] && aof_rewrite_status="是"

        local has_auth="未开启"
        [ -n "$(echo "$conf_pw" 2>/dev/null)" ] && has_auth="已开启"

        local has_tls="未开启"
        [ -n "$tls_port" ] && [ "$tls_port" != "0" ] && has_tls="已开启"

        local public_listen="否"
        [ "$bind" != "127.0.0.1" ] && [ "$bind" != "localhost" ] && public_listen="是"

        # ---- 获取 slave 信息 ----
        local slave_info=""
        if [ -n "$connected_slaves" ] && [ "$connected_slaves" -gt 0 ]; then
          for ((i=0; i<connected_slaves; i++)); do
            local slave_line; slave_line=$(echo "$redis_info" | grep "^slave${i}:" | cut -d: -f2)
            if [ -n "$slave_line" ]; then
              local slave_ip; slave_ip=$(echo "$slave_line" | awk '{print $1}' | cut -d= -f2)
              local slave_port; slave_port=$(echo "$slave_line" | awk '{print $2}' | cut -d= -f2)
              local slave_state; slave_state=$(echo "$slave_line" | awk '{print $3}' | cut -d= -f2)
              [ -z "$slave_state" ] && slave_state="online"
              slave_info="${slave_info}\n  Slave$((i+1))              : ${slave_ip}:${slave_port} ${slave_state}"
            fi
          done
        fi

        # ---- 输出 ----
        echo ""
        echo "========================================"
        echo "Redis 服务状态"
        echo "========================================"
        echo "运行状态             : ✅ 正在运行"
        echo "Master PID           : ${pid}"
        echo "Redis Version        : ${redis_ver:-未知}"
        echo "运行时间             : ${uptime_str:-未知}"
        echo "模式                 : standalone"
        echo "角色                 : ${role:-master}"
        echo "配置文件             : ${conf}"
        echo "监听地址             : ${bind}"
        echo "监听端口             : ${port}"
        echo "Unix Socket          : 未启用"
        echo ""
        echo "========================================"
        echo "资源使用"
        echo "========================================"
        echo "CPU 使用率           : ${cpu_usage}"
        echo "内存占用             : ${used_mem_human:-N/A}"
        echo "最大内存             : ${maxmem_human}"
        echo "内存策略             : ${maxmemory_policy:-N/A}"
        echo "连接数               : ${connected_clients:-0} / ${maxclients:-10000}"
        echo "阻塞客户端           : ${blocked_clients:-0}"
        echo ""
        echo "========================================"
        echo "数据统计"
        echo "========================================"
        echo "数据库数量           : ${db_count:-1}"
        echo "Keys(DB0)            : ${db0_keys:-0}"
        echo "总Keys               : ${total_keys}"
        echo "命中率               : ${hit_ratio}"
        echo "QPS                  : ${qps}"
        echo "总命令数             : ${total_cmds}"
        echo ""
        echo "========================================"
        echo "持久化"
        echo "========================================"
        echo "RDB                  : 已开启"
        echo "最近保存             : ${rdb_last_save_str}"
        echo "AOF                  : ${aof_status}"
        echo "AOF大小              : ${aof_size_human}"
        echo "AOF重写              : ${aof_rewrite_status}"
        echo ""
        echo "========================================"
        echo "复制状态"
        echo "========================================"
        echo "角色                 : ${role^}"
        echo "Slave数量            : ${connected_slaves:-0}"
        if [ -n "$slave_info" ]; then
          echo -e "${slave_info}"
        fi
        echo ""
        echo "========================================"
        echo "网络"
        echo "========================================"
        echo "监听                 : ${bind}:${port}"
        echo "公网监听             : ${public_listen}"
        echo "TLS                  : ${has_tls}"
        echo "密码认证             : ${has_auth}"
        echo ""
        echo "========================================"
        echo "告警"
        echo "========================================"
        echo "✓ 服务运行正常"
        if [ -n "$mem_usage_pct" ] && [ "$mem_usage_pct" != "N/A" ]; then
          echo "✓ 内存使用率 ${mem_usage_pct}"
        fi
        if [ -n "$blocked_clients" ] && [ "$blocked_clients" -eq 0 ]; then
          echo "✓ 无阻塞客户端"
        fi
        if [ -n "$rdb_last_save_str" ] && [ "$rdb_last_save_str" != "N/A" ]; then
          echo "✓ 最近持久化成功"
        fi
      else
        echo ""
        echo "========================================"
        echo "Redis 服务状态"
        echo "========================================"
        echo "运行状态             : ❌ 已停止"
        echo "配置文件             : ${conf}"
        echo ""
      fi ;;
  esac
}

# ---- 配置信息输出 ----
show_config() {
  local svc=$1
  case "$svc" in
    nginx)
      echo "---- nginx 配置与位置 ----"
      echo "binary:       ${PREFIX_NGINX}/sbin/nginx"
      echo "main conf:    ${PREFIX_NGINX}/conf/nginx.conf"
      echo "conf.d dir:   ${PREFIX_NGINX}/conf/conf.d"
      echo "html root:    ${PREFIX_NGINX}/html"
      echo "logs:         ${PREFIX_NGINX}/logs"
      echo "pidfile:      ${PREFIX_NGINX}/logs/nginx.pid"
      if [ -f "${PREFIX_NGINX}/conf/nginx.conf" ]; then
        echo
        echo "包含的配置片段 (前三行预览):"
        sed -n '1,3p' "${PREFIX_NGINX}/conf/nginx.conf" || true
      fi ;;
    php)
      echo "---- php / php-fpm 配置与位置 ----"
      echo "binary:       ${PREFIX_PHP}/bin/php"
      echo "php.ini:      ${PREFIX_PHP}/etc/php.ini"
      echo "php-fpm conf: ${PREFIX_PHP}/etc/php-fpm.conf"
      echo "php-fpm pools:${PREFIX_PHP}/etc/php-fpm.d"
      echo "pidfile:      ${PREFIX_PHP}/var/run/php-fpm.pid"
      if [ -x "${PREFIX_PHP}/bin/php" ]; then
        echo "extension_dir: $( ${PREFIX_PHP}/bin/php -r 'echo ini_get("extension_dir");' 2>/dev/null || echo "unknown")"
        echo "loaded modules:"
        ${PREFIX_PHP}/bin/php -m 2>/dev/null || true
      fi ;;
    mysql)
      echo "---- MySQL 配置与位置 ----"
      echo "binary:       ${PREFIX_MYSQL}/bin/mysqld"
      echo "client:       ${PREFIX_MYSQL}/bin/mysql"
      echo "config:       /etc/my.cnf"
      echo "datadir:      /var/lib/mysql"
      echo "socket:       /var/run/mysqld/mysqld.sock"
      echo "pidfile:      /var/run/mysqld/mysqld.pid"
      echo "error log:    /var/log/mysqld.err"
      echo "slow log:     /var/log/mysql-slow.log"
      if [ -f /etc/my.cnf ]; then
        echo
        echo "my.cnf 关键配置:"
        grep -E "^(basedir|datadir|port|bind-address|innodb_buffer_pool_size|max_connections|character-set-server)" /etc/my.cnf 2>/dev/null || true
      fi
      if [ -x "${PREFIX_MYSQL}/bin/mysql" ]; then
        echo
        echo "MySQL 变量:"
        ${PREFIX_MYSQL}/bin/mysql -u root -e "SHOW VARIABLES LIKE 'version'; SHOW VARIABLES LIKE 'port'; SHOW VARIABLES LIKE 'datadir'; SHOW VARIABLES LIKE 'socket';" 2>/dev/null | sed 's/|//g' | awk 'NR>1{printf "  %-30s %s\n", $1, $2}' || true
      fi ;;
    redis)
      # 尝试多个可能的配置文件路径
      local conf=""
      for c in /www/server/redis/redis.conf /etc/redis/redis.conf "${PREFIX_REDIS}/redis.conf"; do
        [ -f "$c" ] && { conf="$c"; break; }
      done
      [ -z "$conf" ] && conf="/etc/redis/redis.conf"

      local cli; cli=$(_find_redis_cli)

      echo "---- Redis 配置与位置 ----"
      echo "binary:       ${PREFIX_REDIS}/bin/redis-server"
      echo "client:       ${cli:-${PREFIX_REDIS}/bin/redis-cli (未找到)}"
      echo "config:       ${conf}"
      echo "datadir:      /var/lib/redis"
      # 从配置读取 pidfile 路径
      local cfg_pidfile="/var/run/redis/redis.pid"
      if [ -f "$conf" ]; then
        local _pidf; _pidf=$(grep -E "^pidfile " "$conf" 2>/dev/null | awk '{print $2}')
        [ -n "$_pidf" ] && cfg_pidfile="$_pidf"
      fi
      echo "pidfile:      ${cfg_pidfile}"
      echo "log file:     /var/log/redis/redis.log"
      if [ -f "$conf" ]; then
        echo
        echo "redis.conf 关键配置:"
        grep -E "^(port|bind|requirepass|daemonize|supervised|appendonly|dir|logfile|pidfile)" "$conf" 2>/dev/null || true
      fi
      if [ -x "$cli" ]; then
        echo
        echo "Redis 信息:"
        local port="6379"
        local conf_port; conf_port=$(grep -E "^port " "$conf" 2>/dev/null | awk '{print $2}')
        [ -n "$conf_port" ] && port="$conf_port"
        $cli -p "$port" info server 2>/dev/null | grep -E "^(redis_version|tcp_port|uptime_in_seconds|os|arch_bits)" || true
      fi ;;
    *) echo "未知服务: $svc" ;;
  esac
}

# ---- 主入口 ----
if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

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
        show_simple_status "$unit" ;;
      status) show_status "$unit" ;;
      config) show_config nginx ;;
      help|--help|-h) usage ;;
      *) echo "未知动作: $ACTION"; usage; exit 1 ;;
    esac ;;
  php)
    unit=php-fpm.service
    case "$ACTION" in
      start|restart|reload|stop)
        svc_action "$unit" "$ACTION"
        sleep 1
        show_simple_status "$unit" ;;
      status) show_status "$unit" ;;
      config) show_config php ;;
      help|--help|-h) usage ;;
      *) echo "未知动作: $ACTION"; usage; exit 1 ;;
    esac ;;
  mysql)
    unit=mysqld.service
    case "$ACTION" in
      start|restart|reload|stop)
        svc_action "$unit" "$ACTION"
        sleep 1
        show_simple_status "$unit" ;;
      status) show_status "$unit" ;;
      config) show_config mysql ;;
      help|--help|-h) usage ;;
      *) echo "未知动作: $ACTION"; usage; exit 1 ;;
    esac ;;
  redis)
    unit=redis.service
    case "$ACTION" in
      start|restart|reload|stop)
        svc_action "$unit" "$ACTION"
        sleep 1
        show_simple_status "$unit" ;;
      status) show_status "$unit" ;;
      config) show_config redis ;;
      help|--help|-h) usage ;;
      *) echo "未知动作: $ACTION"; usage; exit 1 ;;
    esac ;;
  help|--help|-h) usage ;;
  *) echo "未知目标: $TARGET"; usage; exit 1 ;;
esac
