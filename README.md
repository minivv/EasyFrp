# EasyFrp

多台内网机器 frp 穿透的**一键部署** + 本地**交互式管理**工具。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

- 列表里按编号回车即浏览器打开服务，增删/改备注全交互
- 自动查重、自动分配端口，并规避 frps 上已被占用的端口
- 服务端 / 客户端各一条命令装好，所有 IP / token / 端口参数化

## 截图

| 选择机器 | 映射管理 |
| :---: | :---: |
| ![选择机器](docs/screenshots/select-machine.png) | ![映射管理](docs/screenshots/manage-list.png) |

| 服务端安装 | 客户端安装 |
| :---: | :---: |
| ![frps 安装](docs/screenshots/install-frps.png) | ![frpc 安装](docs/screenshots/install-frpc.png) |

## 快速开始

### 1. 服务端（公网服务器）

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/minivv/EasyFrp/main/install-frps.sh | bash
```

记下打印的 `auth.token`；记得在云安全组放行通信端口、dashboard 端口和端口范围。

### 2. 客户端（每台内网机器）

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/minivv/EasyFrp/main/install-frpc.sh | bash -s -- --server-addr <公网IP> --token <上一步的token>
```

自动探测空闲端口作为本机 ssh 远程端口，装完打印一段 `[[machines]]` 配置。

### 3. 本机管理工具

```bash
python3 -m venv ~/.local/share/easyfrp/venv
~/.local/share/easyfrp/venv/bin/pip install rich prompt_toolkit

mkdir -p ~/.config/easyfrp
cp config.example.toml ~/.config/easyfrp/config.toml   # 填 frps 信息 + 粘入 [[machines]] 片段
```

```bash
frp            # 选机器 → 进入映射管理
frp -m 106     # 直接指定机器名
```

管理命令：`编号`=浏览器打开、`a`=新增、`e`=改备注、`d`=删除、`m`=切机器、`r`=刷新、`q`=退出。

## 支持范围

| | Linux (systemd) | macOS | Windows |
|---|---|---|---|
| frps 服务端 | ✅ | 手动 | ❌ |
| frpc 内网机 | ✅ | 手动 | ❌ |
| 管理工具 | ✅ | ✅ | ⚠️ 改 `open` 命令 |

> Linux 脚本支持 `x86_64` / `arm64` 且带 systemd 的发行版（Ubuntu/Debian/CentOS/Fedora/Rocky 等）。

## 配置

```toml
[frps]
host = "公网IP"            # frps 地址
ssh_port = 22              # frps 所在机器 ssh 端口（探测端口占用用）
user = "root"
key = "~/.ssh/id_rsa"
port_range = [10000, 20000]

[commands]                 # 访问命令模板，占位符 {host} {port} {name} {desc} {key} {user}
tcp = "open http://{host}:{port}"

[[machines]]               # 每台 frpc 机器一条
name = "106"
ssh_port = 10022
proxies_dir = "/www/server/frp/proxies"
frpc_toml = "/www/server/frp/frpc.toml"
```

## License

[MIT](LICENSE)