#!/usr/bin/env bash
# install-frps.sh — 一键安装 frps 服务端（公网服务器上运行）
#
# 用法（把 <user>/<repo> 换成你的仓库）：
#   curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/<user>/<repo>/main/install-frps.sh | bash
#
# 可选参数（均可加在 "bash" 之后，用 -s -- 传参）：
#   --version <v>         frp 版本，默认 0.71.0
#   --dir <path>          安装目录，默认 /opt/easyfrp
#   --bind-port <p>       frp 通信端口，默认 7000
#   --dash-port <p>       dashboard 端口，默认 7500
#   --dash-user <u>       dashboard 用户名，默认 admin
#   --dash-pass <p>       dashboard 密码（默认自动生成）
#   --token <t>           认证 token（默认自动生成，务必保存）
#   --allow-start <p>     允许绑定的端口范围起点，默认 10000
#   --allow-end <p>       允许绑定的端口范围终点，默认 20000
#   --no-gh-proxy         直连 GitHub 下载（默认走 gh-proxy 加速）
#   --uninstall           卸载（逐步 y 确认：停服务、删服务、删目录）
#
# 也可用环境变量传参：FRP_VERSION / FRPS_DIR / BIND_PORT / DASH_PORT /
#   DASH_USER / DASH_PASS / AUTH_TOKEN / ALLOW_START / ALLOW_END / GH_PROXY

set -euo pipefail

FRP_VERSION="${FRP_VERSION:-0.71.0}"
FRPS_DIR="${FRPS_DIR:-/opt/easyfrp}"
BIND_PORT="${BIND_PORT:-7000}"
DASH_PORT="${DASH_PORT:-7500}"
DASH_USER="${DASH_USER:-admin}"
DASH_PASS="${DASH_PASS:-}"
AUTH_TOKEN="${AUTH_TOKEN:-}"
ALLOW_START="${ALLOW_START:-10000}"
ALLOW_END="${ALLOW_END:-20000}"
GH_PROXY="${GH_PROXY:-https://gh-proxy.org/}"
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) FRP_VERSION="$2"; shift 2;;
    --dir) FRPS_DIR="$2"; shift 2;;
    --bind-port) BIND_PORT="$2"; shift 2;;
    --dash-port) DASH_PORT="$2"; shift 2;;
    --dash-user) DASH_USER="$2"; shift 2;;
    --dash-pass) DASH_PASS="$2"; shift 2;;
    --token) AUTH_TOKEN="$2"; shift 2;;
    --allow-start) ALLOW_START="$2"; shift 2;;
    --allow-end) ALLOW_END="$2"; shift 2;;
    --no-gh-proxy) GH_PROXY=""; shift 1;;
    --uninstall) UNINSTALL=1; shift 1;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

rand_hex() {
  openssl rand -hex "$1" 2>/dev/null \
    || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-$(( $1 * 2 ))
}

confirm() {
  local ans=""
  printf "%s [y/N]: " "$1"
  read -r ans < /dev/tty 2>/dev/null || return 1
  [[ "$ans" =~ ^[Yy]$ ]]
}

do_uninstall() {
  echo "===== 卸载 frps ====="
  if systemctl list-unit-files 2>/dev/null | grep -q '^frps\.service'; then
    if confirm "停止并删除 frps 服务？"; then
      systemctl disable --now frps 2>/dev/null || true
      rm -f /etc/systemd/system/frps.service
      systemctl daemon-reload
      echo "  已删除 frps 服务"
    else
      echo "  跳过服务删除"
    fi
  else
    echo "  未找到 frps 服务"
  fi
  if [[ -d "$FRPS_DIR" ]]; then
    if confirm "删除安装目录 $FRPS_DIR（含 frps 二进制与配置）？"; then
      rm -rf "$FRPS_DIR"
      echo "  已删除 $FRPS_DIR"
    else
      echo "  跳过目录删除"
    fi
  else
    echo "  未找到安装目录 $FRPS_DIR"
  fi
  echo "卸载流程结束"
}

if [[ "$UNINSTALL" == 1 ]]; then
  do_uninstall
  exit 0
fi

[[ -n "$AUTH_TOKEN" ]] || AUTH_TOKEN="$(rand_hex 32)"
[[ -n "$DASH_PASS" ]] || DASH_PASS="$(rand_hex 16)"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="amd64";;
  aarch64|arm64) ARCH="arm64";;
  *) echo "不支持的架构: $ARCH"; exit 1;;
esac

echo "==> 安装 frps v${FRP_VERSION} (linux/${ARCH}) 到 ${FRPS_DIR}"
mkdir -p "$FRPS_DIR"
TMP="$(mktemp -d)"
URL="${GH_PROXY}https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
echo "==> 下载 $URL"
curl -fsSL "$URL" -o "$TMP/frp.tar.gz"
tar -xzf "$TMP/frp.tar.gz" -C "$TMP" --strip-components=1
install -m 755 "$TMP/frps" "$FRPS_DIR/frps"
rm -rf "$TMP"

cat > "$FRPS_DIR/frps.toml" <<EOF
bindPort = $BIND_PORT

auth.method = "token"
auth.token = "$AUTH_TOKEN"

webServer.addr = "0.0.0.0"
webServer.port = $DASH_PORT
webServer.user = "$DASH_USER"
webServer.password = "$DASH_PASS"

allowPorts = [
  { start = $ALLOW_START, end = $ALLOW_END }
]
EOF

cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frps
After=network.target

[Service]
Type=simple
ExecStart=$FRPS_DIR/frps -c $FRPS_DIR/frps.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frps
systemctl status frps --no-pager -l || true

echo ""
echo "================ frps 安装完成 ================"
echo "目录:        $FRPS_DIR"
echo "bindPort:    $BIND_PORT"
echo "auth.token:  $AUTH_TOKEN"
echo "dashboard:   http://<公网IP>:$DASH_PORT  (账号 $DASH_USER / 密码 $DASH_PASS)"
echo "allowPorts:  $ALLOW_START - $ALLOW_END"
echo ""
echo "请记好上面的 token，下一步在内网机器上跑 install-frpc.sh 要用。"
echo "记得在云安全组放行：$BIND_PORT、$DASH_PORT、$ALLOW_START-$ALLOW_END 的 TCP。"