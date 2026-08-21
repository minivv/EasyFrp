# EasyFrp

多台内网机器 frp 穿透的**一键部署** + 本地**交互式管理**工具。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

- 不再手写 toml、不用记端口：列表里按编号回车即浏览器打开服务，增删/改备注都交互完成
- 新增映射自动查重、自动分配端口，并**自动避开 frps 上已被占用的端口**
- `frps` 服务端 和 `frpc` 客户端 都有 `install-*.sh`，一条命令装好
- 所有 IP / token / 端口全部参数化，谁拿到都能用

## 截图

| 选择机器 | 映射管理 |
| :---: | :---: |
| ![选择机器](docs/screenshots/select-machine.png) | ![映射管理](docs/screenshots/manage-list.png) |

| 服务端安装 | 客户端安装 |
| :---: | :---: |
| ![frps 安装](docs/screenshots/install-frps.png) | ![frpc 安装](docs/screenshots/install-frpc.png) |

## 架构

```
公网 frps 服务器 (install-frps.sh)
   └─ frpc 机器 A (install-frpc.sh)  —— 各自直连 frps，互相无需互通
   └─ frpc 机器 B (install-frpc.sh)  —— 每台都把自己的 ssh 暴露成 frps 上一个唯一端口
        ...
本机 (easyfrp.py) —— 通过 frps 转发 ssh 管理任意一台，启动后先选机器
```

## 快速开始

### 1. 服务端（公网服务器上执行）

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/minivv/EasyFrp/main/install-frps.sh | bash
```

装完会打印 `auth.token` 和 dashboard 账号密码，**记好 token**（下一步要用）。
记得在云安全组放行：通信端口、dashboard 端口、端口范围。

### 2. 客户端（每台内网机器上执行）

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/minivv/EasyFrp/main/install-frpc.sh \
  | bash -s -- --server-addr <公网IP> --token <上一步的token>
```

脚本会自动探测一个空闲端口作为这台机器的 ssh 远程端口，装完打印一段 `[[machines]]` 配置。

> 说明：自动探测通过从内网机器连 frps 的端口判断空闲；若云安全组未对该机器放行端口范围，可能不准，此时用 `--ssh-port <端口>` 手动指定最稳。

### 3. 本机管理工具

```bash
# 依赖：Python 3.11+，rich + prompt_toolkit（装进独立 venv，不污染系统）
python3 -m venv ~/.local/share/easyfrp/venv
~/.local/share/easyfrp/venv/bin/pip install rich prompt_toolkit

# 配置：复制模板并填写
mkdir -p ~/.config/easyfrp
cp config.example.toml ~/.config/easyfrp/config.toml
# 编辑它，填入 frps 信息 + 各台机器（把 install-frpc.sh 打印的 [[machines]] 片段粘进去）

# 入口命令（把 <repo> 换成本机路径）
cat > ~/.local/bin/frp <<'SH'
#!/bin/sh
exec "$HOME/.local/share/easyfrp/venv/bin/python" "$HOME/path/to/EasyFrp/easyfrp.py" "$@"
SH
chmod +x ~/.local/bin/frp
```

### 4. 使用

```bash
frp            # 启动后先选机器，再进入映射管理
frp -m 106     # 直接指定机器名，跳过选择
```

管理界面里：

| 输入 | 作用 |
| ---- | ---- |
| `编号` | 浏览器打开该服务 `http://公网IP:远程端口` |
| `a` | 新增映射（自动查重 + 分配端口 + 避开占用） |
| `e` 或 `e 编号` | 改备注（回车保持、`-` 清空） |
| `d` | 删除映射 |
| `m` | 切换到另一台机器 |
| `r` / 回车 | 刷新 |
| `q` | 退出 |

## 配置说明（config.toml）

```toml
[frps]
host = "公网IP"           # frps 服务器地址
ssh_port = 22             # frps 所在机器 ssh 端口（用于探测已占用端口）
user = "root"
key = "~/.ssh/id_rsa"
port_range = [10000, 20000]

[commands]                # 编号回车时的访问命令模板
tcp = "open http://{host}:{port}"
# ...

[commands.names]          # 按映射名定制（可选）
# mysql-xxx = "mysql -h {host} -P {port} -u root -p"

[[machines]]              # 每台 frpc 机器一条
name = "106"
ssh_port = 10022
proxies_dir = "/www/server/frp/proxies"
frpc_toml = "/www/server/frp/frpc.toml"
```

占位符：`{host}` `{port}` `{name}` `{desc}` `{key}` `{user}`。

## 说明

- 备注以 `# desc: ...` 注释写进每个 toml 顶部，frp 会忽略，不影响运行。
- 新增映射分配端口时，工具会 ssh 到 frps 查真实监听端口，自动跳过被其他进程占用的端口。

## License

[MIT](LICENSE)