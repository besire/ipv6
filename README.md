# IPv6 One-Click Script

一个 Linux IPv6 一键管理脚本，支持：

- IPv6 状态查询
- 临时关闭 IPv6
- 永久关闭 IPv6
- 临时开启 IPv6
- 永久开启 IPv6
- 交互菜单和命令行参数两种模式

## 支持系统

适用于常见 Linux 发行版，包括 Debian、Ubuntu、CentOS、RHEL、Rocky Linux、AlmaLinux、Fedora、Arch Linux、Alpine 等。

脚本通过 Linux 内核的 `/proc/sys/net/ipv6/conf/*/disable_ipv6` 和 `/etc/sysctl.d/99-ipv6-control.conf` 工作，不依赖 systemd，因此也兼容 OpenRC、BusyBox 环境中的多数场景。

## 使用方法

GitHub 一键执行交互菜单：

```sh
curl -fsSL https://raw.githubusercontent.com/besire/ipv6/main/ipv6.sh -o /tmp/ipv6.sh && chmod +x /tmp/ipv6.sh && sudo /tmp/ipv6.sh
```

GitHub 一键永久关闭 IPv6：

```sh
curl -fsSL https://raw.githubusercontent.com/besire/ipv6/main/ipv6.sh -o /tmp/ipv6.sh && chmod +x /tmp/ipv6.sh && sudo /tmp/ipv6.sh disable-perm
```

GitHub 一键永久开启 IPv6：

```sh
curl -fsSL https://raw.githubusercontent.com/besire/ipv6/main/ipv6.sh -o /tmp/ipv6.sh && chmod +x /tmp/ipv6.sh && sudo /tmp/ipv6.sh enable-perm
```

本地执行：

```sh
chmod +x ipv6.sh
./ipv6.sh
```

状态查询不需要 root：

```sh
./ipv6.sh status
```

关闭或开启 IPv6 需要 root：

```sh
sudo ./ipv6.sh disable-temp
sudo ./ipv6.sh disable-perm
sudo ./ipv6.sh enable-temp
sudo ./ipv6.sh enable-perm
```

## 命令说明

```text
status          查询 IPv6 当前状态
disable-temp    临时关闭 IPv6，重启或网络服务重载后可能恢复
disable-perm    永久关闭 IPv6，并立即应用
enable-temp     临时开启 IPv6
enable-perm     删除本脚本创建的永久关闭配置，并立即开启 IPv6
help            显示帮助
```

## 注意事项

`enable-perm` 只会删除本脚本创建的 `/etc/sysctl.d/99-ipv6-control.conf`。如果系统里其他配置文件也写了 `net.ipv6.conf.*.disable_ipv6 = 1`，脚本会在开启后提示这些文件，需要你按实际情况检查。

如果系统内核或容器环境没有暴露 IPv6 控制路径，脚本会提示 IPv6 kernel controls unavailable。
