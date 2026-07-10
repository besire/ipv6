# IPv6 Control

一个简单的 Linux IPv6 管理脚本，使用 POSIX `sh` 编写，支持状态查询、临时启停、永久启停以及交互菜单。

## 功能

- 查询当前网络命名空间的 IPv6 内核开关。
- 显示各接口标志、IPv6 地址和默认路由。
- 临时开启或关闭现有接口以及新接口默认值。
- 通过 `/etc/sysctl.d/99-ipv6-control.conf` 保存永久关闭配置。
- 只删除内容完整匹配的本工具配置，不覆盖或删除同名的其他文件。
- 写入每个运行时标志后立即回读校验，失败时返回非零状态。

## 环境要求

- Linux，并提供 `/proc/sys/net/ipv6/conf`。
- POSIX 兼容的 `/bin/sh`，例如 `dash`、BusyBox `ash` 或 Bash。
- 修改操作需要 `root`，并要求 `/proc/sys` 可写。
- 常见基础命令：`id`、`sed`、`awk`、`grep`、`cmp`、`mktemp`、`mkdir`、`mv`、`rm`、`chmod`。
- `ip` 为详细地址和路由查询的可选依赖。

永久配置要在重启后生效，系统启动时必须加载 `/etc/sysctl.d/*.conf`。脚本不依赖 systemd，也不会执行 `sysctl --system`。

## 使用

推荐先安全下载到临时文件，再执行：

```sh
(
  script=$(mktemp) || exit 1
  trap 'rm -f "$script"' 0
  curl -fsSL https://raw.githubusercontent.com/besire/ipv6/main/ipv6.sh -o "$script" &&
  sh -n "$script" &&
  sudo sh "$script"
)
```

执行指定命令时，在最后添加参数：

```sh
sudo sh ipv6.sh disable-perm
sudo sh ipv6.sh enable-perm
sh ipv6.sh status
sh ipv6.sh status-full
```

也可以直接执行：

```sh
chmod +x ipv6.sh
./ipv6.sh
```

## 命令

| 命令 | 说明 | root |
| --- | --- | --- |
| `status` | 简洁显示内核开关和永久配置 | 否 |
| `status-full` | 显示所有标志、地址和默认路由 | 否 |
| `disable-temp` | 临时关闭 IPv6 | 是 |
| `disable-perm` | 安装永久关闭配置并立即关闭 | 是 |
| `enable-temp` | 临时开启 IPv6 | 是 |
| `enable-perm` | 删除本工具配置并立即开启 | 是 |
| `version` | 显示版本 | 否 |
| `help` | 显示帮助 | 否 |

退出码：`0` 成功，`1` 操作失败，`2` 参数错误。

## 状态说明

`status` 根据实际接口的 `disable_ipv6` 值显示：

- `已开启`：所有当前接口均为 `0`。
- `已关闭`：所有当前接口均为 `1`。
- `部分关闭`：当前接口同时存在 `0` 和 `1`。
- `未知`：没有接口或某个值无法读取。

该状态只表示内核开关，不代表已经获得 IPv6 地址、路由、DNS 或公网连通性。请使用 `status-full` 继续检查。

## 永久配置保护

本工具只管理以下固定文件：

```text
/etc/sysctl.d/99-ipv6-control.conf
```

如果该路径已经存在，但内容不是本工具生成的完整配置，`disable-perm` 和 `enable-perm` 都会拒绝操作。旧版本生成且未修改的五行配置仍可识别和删除。

`enable-perm` 不会删除其他 sysctl 文件。如果系统中还有其他 `disable_ipv6 = 1`，脚本会提示对应文件。

## 注意

- 通过 IPv6 SSH 执行关闭操作可能立即断开当前连接，请准备 IPv4 或控制台恢复方式。
- 关闭操作包含 `lo`，依赖 `::1` 的本机服务可能受到影响。
- 容器内即使 UID 为 `0`，也可能因为缺少能力或 `/proc/sys` 只读而失败。
- 设置 `NO_COLOR=1` 可关闭颜色输出。
- 永久配置写入成功但立即应用失败时，命令返回 `1`，配置文件会保留。
- 永久配置删除成功但立即开启失败时，命令返回 `1`，配置文件仍保持已删除。

## 测试

测试只使用临时目录，不修改真实网络或 `/etc`：

```sh
sh tests/test.sh
dash tests/test.sh
bash tests/test.sh
shellcheck -x --shell=sh ipv6.sh tests/test.sh
```
