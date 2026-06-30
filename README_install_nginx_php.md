# install_nginx_php_centos10.sh

用途：在 CentOS Stream 10 上编译安装 nginx 1.28.0 与 PHP 8.5.7（脚本可参数化）。

主要特性：
- 自动安装编译依赖（尝试启用 CRB 并逐包安装）
- 若缺失关键 -devel 包，会回退到源码编译 `pcre`、`libzip`、`oniguruma`
- 可选择禁用 firewalld 与 SELinux（默认会禁用，传 `--no-disable-security` 可关闭此行为）
- 生成 systemd 单元并启用服务
- 自动创建 nginx vhost 并放置 `phpinfo.php` 测试页
- 提供简单的安装验证（检查 systemd 服务并请求 `phpinfo.php`）

使用示例：

```bash
# 以 root 运行并使用默认设置
sudo bash install_nginx_php_centos10.sh

# 更改前缀与并行编译数，并不自动禁用安全项
sudo bash install_nginx_php_centos10.sh --prefix-nginx /opt/nginx --prefix-php /opt/php --jobs 4 --no-disable-security
```

注意：
- 脚本会修改系统配置（可能禁用防火墙与 SELinux），请在受控环境中运行并确保已备份关键数据。
- 脚本默认不验证下载包的 SHA256，若需要，请在脚本顶部填写 `NGINX_SHA256` 与 `PHP_SHA256` 并传入 `--verify-checksums`。
- 若目标系统缺少某些包，脚本会尝试从源码编译回退库，但这需要额外工具（`cmake`, `make`, `gcc` 等）。

故障排查：
- 若出现 `pcre` 或 `pcre-devel` 找不到，先在目标主机启用 CRB：

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --set-enabled crb
sudo dnf -y makecache
```

然后重试脚本。

- 查看日志与服务状态：

```bash
systemctl status nginx
systemctl status php-fpm
journalctl -u nginx -n 200
journalctl -u php-fpm -n 200
```

如果需要，我可以：
- 把所有版本/URL/校验和变量集中到脚本顶部并在 README 中记录；
- 添加更详细的单元测试与日志记录；
- 将脚本拆成子命令（install, uninstall, verify）。
