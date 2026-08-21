#!/usr/bin/env bash
# install-frpc.sh — 一键安装 frpc 客户端（内网机器上运行）
#
# 用法（把 <user>/<repo> 换成你的仓库）：
#   curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/<user>/<repo>/main/install-frpc.sh \
#     | bash -s -- --server-addr 你的公网IP --token 你的token
#
# 必填：
#   --server-addr <ip/域名>   frps 服务器地址
#   --token <t>               与 frps 一致的认证 token
#
# 可选：
#   --server-port <p>          frps 通信端口，默认 7000
#   --ssh-port <p>             本机 ssh 经 frps 暴露的远程端口（默认自动探测空闲端口）
#   --ssh-local-port <p>       本机 ssh 端口，默认 22
#   --allow-start <p>          探测空闲端口的范围起点，默认 10000
#   --allow-end <p>            探测空闲端口的范围终点，默认 20000
#   --version <v>              frp 版本，默认 0.71.0
#   --dir <path>               安装目录，默认 /opt/easyfrp
#   --no-gh-proxy              直连 GitHub 下载（默认走 gh-proxy 加速）
#
# 部署完成后会打印一段 [[machines]] 配置，粘贴进本机 EasyFrp 的 config.toml 即可管理。

set -euo pipefail

FRP_VERSION="${FRP_VERSION:-0.71.0}"
FRPC_DIR="${FRPC_DIR:-/opt/easyfrp}"
SERVER_ADDR=""
SERVER_PORT="${SERVER_PORT:-7000}"
AUTH_TOKEN=""
SSH_PORT=""
SSH_LOCAL_PORT="${SSH_LOCAL_PORT:-22}"
ALLOW_START="${ALLOW_START:-10000}"
ALLOW_END="${ALLOW_END:-20000}"
GH_PROXY="${GH_PROXY:-https://gh-proxy.org/}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-addr) SERVER_ADDR="$2"; shift 2;;
    --token) AUTH_TOKEN="$2"; shift 2;;
    --server-port) SERVER_PORT="$2"; shift 2;;
    --ssh-port) SSH_PORT="$2"; shift 2;;
    --ssh-local-port) SSH_LOCAL_PORT="$2"; shift 2;;
    --allow-start) ALLOW_START="$2"; shift 2;;
    --allow-end) ALLOW_END="$2"; shift 2;;
    --version) FRP_VERSION="$2"; shift 2;;
    --dir) FRPC_DIR="$2"; shift 2;;
    --no-gh-proxy) GH_PROXY=""; shift 1;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

[[ -n "$SERVER_ADDR" ]] || { echo "错误：缺少 --server-addr"; exit 1; }
[[ -n "$AUTH_TOKEN" ]] || { echo "错误：缺少 --token"; exit 1; }

probe_port() {
  local host="$1" p="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w1 "$host" "$p" 2>/dev/null
  else
    (echo >/dev/tcp/"$host"/"$p") 2>/dev/null
  fi
}

find_free_port() {
  local host="$1" p
  for p in $(seq "$ALLOW_START" "$ALLOW_END"); do
    if ! probe_port "$host" "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="amd64";;
  aarch64|arm64) ARCH="arm64";;
  *) echo "不支持的架构: $ARCH"; exit 1;;
esac

if [[ -z "$SSH_PORT" ]]; then
  echo "==> 自动探测 ${SERVER_ADDR}:${ALLOW_START}-${ALLOW_END} 的空闲端口..."
  SSH_PORT="$(find_free_port "$SERVER_ADDR")" || { echo "错误：未找到空闲端口，请用 --ssh-port 手动指定"; exit 1; }
  echo "==> 探测到空闲端口: $SSH_PORT（作为本机 ssh 的远程端口）"
fi

echo "==> 安装 frpc v${FRP_VERSION} (linux/${ARCH}) 到 ${FRPC_DIR}"
mkdir -p "$FRPC_DIR/proxies"
TMP="$(mktemp -d)"
URL="${GH_PROXY}https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
echo "==> 下载 $URL"
curl -fsSL "$URL" -o "$TMP/frp.tar.gz"
tar -xzf "$TMP/frp.tar.gz" -C "$TMP" --strip-components=1
install -m 755 "$TMP/frpc" "$FRPC_DIR/frpc"
rm -rf "$TMP"

cat > "$FRPC_DIR/frpc.toml" <<EOF
serverAddr = "$SERVER_ADDR"
serverPort = $SERVER_PORT

auth.method = "token"
auth.token = "$AUTH_TOKEN"

includes = ["$FRPC_DIR/proxies/*.toml"]
EOF

HOSTNAME_SHORT="$(hostname | tr -cd 'A-Za-z0-9_-')"
cat > "$FRPC_DIR/proxies/ssh.toml" <<EOF
[[proxies]]
name = "ssh-$HOSTNAME_SHORT"
type = "tcp"
localIP = "127.0.0.1"
localPort = $SSH_LOCAL_PORT
remotePort = $SSH_PORT
EOF

cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=frpc
After=network.target

[Service]
Type=simple
ExecStart=$FRPC_DIR/frpc -c $FRPC_DIR/frpc.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frpc
systemctl status frpc --no-pager -l || true

echo ""
echo "================ frpc 安装完成 ================"
echo "目录:            $FRPC_DIR"
echo "本机 ssh 远程端口: $SSH_PORT （即 ${SERVER_ADDR}:${SSH_PORT} → 本机:${SSH_LOCAL_PORT}）"
echo ""
echo "在本机 EasyFrp 的 config.toml 追加以下配置即可管理这台机器："
echo ""
echo "[[machines]]"
echo "name = \"$HOSTNAME_SHORT\""
echo "ssh_port = $SSH_PORT"
echo "proxies_dir = \"$FRPC_DIR/proxies\""
echo "frpc_toml = \"$FRPC_DIR/frpc.toml\""