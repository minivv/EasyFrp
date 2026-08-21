#!/usr/bin/env python3
"""EasyFrp — 交互式管理多台内网 frpc 机器的端口映射。

架构
----
- 一台公网 frps 服务器 + 若干台各自直连 frps 的内网 frpc 机器。
- 每台 frpc 机器都把自己的 ssh(22) 通过 frp 暴露成 frps 上一个唯一的 remotePort，
  本工具通过 `ssh -p <remotePort> user@frps_host` 管理对应机器。
- 新增映射时自动 ssh 到 frps 探测已占用端口，避开冲突。

用法
----
    frp            # 启动后先选机器，再进入该机器的映射管理

依赖：rich + prompt_toolkit（见 README 安装章节）。要求 Python 3.11+。
"""

import argparse
import re
import subprocess
import sys
import time
import tomllib
from pathlib import Path

from rich import box
from rich.console import Console
from rich.prompt import Confirm
from rich.table import Table
from prompt_toolkit import HTML, PromptSession
from prompt_toolkit.history import InMemoryHistory

console = Console()
_pts = PromptSession(history=InMemoryHistory())

CONFIG_PATH = Path.home() / ".config" / "easyfrp" / "config.toml"

NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
IP_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
DESC_RE = re.compile(r"^\s*#\s*desc\s*:\s*(.*)$")

FILE_MARKER = "__EASYFRP_FILE__:"

# 通用默认值（不写死具体 IP / token，全部来自 config.toml）
DEFAULT_SSH_PORT = 22
DEFAULT_PORT_RANGE = [10000, 20000]
DEFAULT_PROXIES_DIR = "/opt/easyfrp/proxies"
DEFAULT_FRPC_TOML = "/opt/easyfrp/frpc.toml"
# sleep 1 让当前 SSH 会话（可能走 frp 隧道本身）先退出，再后台重启，
# 避免重启瞬间把执行命令的连接也一并掐断
DEFAULT_RESTART = "nohup sh -c 'sleep 1; systemctl restart frpc' >/dev/null 2>&1 &"

# 默认访问命令模板（按 type），config 未覆盖时使用
DEFAULT_COMMANDS = {
    "tcp": "open http://{host}:{port}",
    "http": "open http://{host}:{port}",
    "https": "open https://{host}:{port}",
    "udp": "",
}


# ---------------------------------------------------------------------------
# 配置加载
# ---------------------------------------------------------------------------
def expand(path):
    if isinstance(path, str) and path.startswith("~/"):
        return Path(path).expanduser().resolve().as_posix()
    return path


def load_config(path) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)


def build_cfg(server: dict, commands: dict, machine: dict) -> dict:
    """把 frps + 当前 machine 合并进程原有的 cfg 结构，供后续函数使用。"""
    return {
        "host": server.get("host", ""),                      # frps 公网地址（访问/ssh 目标主机）
        "port": int(machine.get("ssh_port", 0)),             # 当前机器 ssh 经 frps 的 remotePort
        "frps_ssh_port": int(server.get("ssh_port", DEFAULT_SSH_PORT)),
        "user": machine.get("user") or server.get("user", "root"),
        "key": machine.get("key") or server.get("key", "~/.ssh/id_rsa"),
        "proxies_dir": machine.get("proxies_dir", DEFAULT_PROXIES_DIR),
        "frpc_toml": machine.get("frpc_toml", DEFAULT_FRPC_TOML),
        "restart_cmd": machine.get("restart_cmd") or DEFAULT_RESTART,
        "port_range": list(server.get("port_range", DEFAULT_PORT_RANGE)),
        "type": "tcp",
        "local_ip": "",
        "commands": commands,
    }


# ---------------------------------------------------------------------------
# SSH 执行
# ---------------------------------------------------------------------------
def ssh_cmd(cfg, remote_cmd, input_text=None, check=True, ssh_port=None):
    port = ssh_port if ssh_port is not None else cfg["port"]
    cmd = [
        "ssh",
        "-p", str(port),
        "-i", expand(cfg["key"]),
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        f'{cfg["user"]}@{cfg["host"]}',
        remote_cmd,
    ]
    proc = subprocess.run(
        cmd, input=input_text, capture_output=True, text=True,
        stdin=subprocess.DEVNULL if input_text is None else None,
    )
    if check and proc.returncode != 0:
        console.print(f"[red][错误] SSH 执行失败（exit={proc.returncode}）：\n{proc.stderr.strip()}[/red]")
        sys.exit(1)
    return proc.stdout


def restart_frpc(cfg):
    console.print("[dim]正在重启 frpc ...[/dim]")
    ssh_cmd(cfg, cfg["restart_cmd"], check=False)
    console.print("[dim]重启命令已下发，约 2 秒后 frpc 恢复[/dim]")


# ---------------------------------------------------------------------------
# 读取远端 proxies
# ---------------------------------------------------------------------------
def fetch_raw_files(cfg) -> dict:
    """返回 {文件路径: 原始内容}，含 proxies 目录下所有 toml 与 frpc 主配置。"""
    remote = (
        f'for f in {cfg["proxies_dir"]}/*.toml; do '
        f'[ -f "$f" ] || continue; echo "{FILE_MARKER}$f"; cat "$f"; echo; done; '
        f'echo "{FILE_MARKER}{cfg["frpc_toml"]}"; cat {cfg["frpc_toml"]} 2>/dev/null; echo'
    )
    out = ssh_cmd(cfg, remote)
    files = {}
    cur = None
    buf = []
    for line in out.splitlines():
        if line.startswith(FILE_MARKER):
            if cur is not None:
                files[cur] = "\n".join(buf) + "\n"
            cur = line[len(FILE_MARKER):]
            buf = []
        else:
            buf.append(line)
    if cur is not None:
        files[cur] = "\n".join(buf) + "\n"
    return files


def extract_desc(content: str) -> str:
    for line in content.splitlines():
        m = DESC_RE.match(line)
        if m:
            return m.group(1).strip()
    return ""


def parse_proxies(files: dict) -> list:
    proxies = []
    for path, content in files.items():
        desc = extract_desc(content)
        try:
            data = tomllib.loads(content)
        except tomllib.TOMLDecodeError:
            continue
        for p in data.get("proxies", []):
            p = dict(p)
            p["_file"] = path
            p["_desc"] = p.get("_desc") or desc
            proxies.append(p)
    return proxies


def load_proxies(cfg) -> list:
    return parse_proxies(fetch_raw_files(cfg))


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
def used_names(proxies):
    return {p.get("name") for p in proxies}


def used_remote_ports(proxies):
    return {int(p["remotePort"]) for p in proxies if "remotePort" in p}


def alloc_remote_port(cfg, used_ports):
    start, end = cfg["port_range"]
    for port in range(start, end + 1):
        if port not in used_ports:
            return port
    console.print(f"[red][错误] 端口范围 {start}-{end} 已全部占用[/red]")
    sys.exit(1)


def fetch_frps_used_ports(cfg):
    """ssh 到 frps 服务器，查询 port_range 内已被占用的 TCP 端口；失败返回空集合。"""
    lo, hi = cfg["port_range"]
    remote = "ss -tlnH 2>/dev/null | awk '{n=split($4,a,\":\"); print a[n]}' | sort -n | uniq"
    try:
        out = ssh_cmd(cfg, remote, check=False, ssh_port=cfg["frps_ssh_port"])
    except Exception:
        return set()
    ports = set()
    for line in out.splitlines():
        line = line.strip()
        if line.isdigit() and lo <= int(line) <= hi:
            ports.add(int(line))
    return ports


def resolve_command(cfg, p) -> str:
    name = p.get("name", "")
    typ = p.get("type", "tcp")
    names = cfg.get("commands", {}).get("names", {})
    if name in names:
        return names[name]
    per_type = cfg.get("commands", {})
    if typ in per_type:
        return per_type[typ]
    return DEFAULT_COMMANDS.get(typ, "")


def run_visit(cfg, p):
    cmd_tmpl = resolve_command(cfg, p)
    if not cmd_tmpl:
        console.print(f"[yellow][提示] 「{p.get('name')}」类型 {p.get('type')} 无默认访问方式，"
                      f"可在配置里为它指定 commands[/yellow]")
        return
    mapping = {
        "host": cfg["host"],
        "port": str(p.get("remotePort", "")),
        "name": p.get("name", ""),
        "desc": p.get("_desc", ""),
        "key": expand(cfg["key"]),
        "user": cfg["user"],
    }
    cmd = cmd_tmpl
    for k, v in mapping.items():
        cmd = cmd.replace("{" + k + "}", v)
    console.print(f"\n[dim][访问] {cmd}[/dim]")
    try:
        subprocess.run(cmd, shell=True)
    except KeyboardInterrupt:
        console.print()


def ask_prompt(prompt, default=""):
    """prompt_toolkit 行编辑输入。返回值已 strip。"""
    if default:
        return (_pts.prompt(HTML(f"<ansicyan>{prompt}</ansicyan>: "), default=default) or "").strip()
    return (_pts.prompt(HTML(f"<ansicyan>{prompt}</ansicyan>: ")) or "").strip()


# ---------------------------------------------------------------------------
# 交互：新增 / 删除 / 改备注
# ---------------------------------------------------------------------------
def collect_add(cfg, proxies):
    names = used_names(proxies)
    used_ports = used_remote_ports(proxies)
    frps_ports = fetch_frps_used_ports(cfg)
    if frps_ports:
        extra = sorted(frps_ports - used_ports)
        if extra:
            console.print(f"[dim]已排除 frps 上被其他进程占用的端口：{extra}[/dim]")
        used_ports |= frps_ports

    while True:
        name = ask_prompt("映射名称 name（例 ssh-106）")
        if not NAME_RE.match(name):
            console.print("[red]name 只能包含字母、数字、下划线、连字符[/red]")
        elif name in names:
            console.print(f"[red]name「{name}」已存在，请换一个[/red]")
        else:
            break

    desc = ask_prompt("备注 desc（用途说明，可回车跳过）")

    while True:
        typ = ask_prompt("类型 type", default=cfg.get("type", "tcp"))
        if typ in ("tcp", "udp", "http", "https"):
            break
        console.print("[red]type 仅支持 tcp / udp / http / https[/red]")

    while True:
        lip = ask_prompt("内网 IP localIP", default=cfg.get("local_ip") or "")
        if IP_RE.match(lip):
            break
        console.print("[red]localIP 格式不正确，示例 172.200.171.106[/red]")

    while True:
        v = ask_prompt("内网端口 localPort")
        if v.isdigit() and 1 <= int(v) <= 65535:
            lpt = int(v)
            break
        console.print("[red]localPort 需为 1-65535 的整数[/red]")

    lo, hi = cfg["port_range"]
    if typ in ("http", "https"):
        rpt = None
    else:
        auto = alloc_remote_port(cfg, used_ports)
        while True:
            v = ask_prompt("远程端口 remotePort（回车自动分配）", default=str(auto))
            if v == "":
                rpt = auto
                break
            if not v.isdigit():
                console.print("[red]请输入数字[/red]")
                continue
            rpt = int(v)
            if rpt in used_ports:
                console.print(f"[red]remotePort {rpt} 已被占用[/red]")
            elif not (lo <= rpt <= hi):
                console.print(f"[red]remotePort 需在 {lo}-{hi} 内[/red]")
            else:
                break

    return dict(name=name, desc=desc, type=typ, localIP=lip, localPort=lpt,
                remotePort=rpt)


def build_toml(p):
    lines = []
    if p.get("desc"):
        lines.append(f"# desc: {p['desc']}")
        lines.append("")
    lines += ["[[proxies]]", f'name = "{p["name"]}"', f'type = "{p["type"]}"',
              f'localIP = "{p["localIP"]}"', f'localPort = {p["localPort"]}']
    if p["remotePort"] is not None:
        lines.append(f'remotePort = {p["remotePort"]}')
    return "\n".join(lines) + "\n"


def do_add(cfg):
    proxies = load_proxies(cfg)
    info = collect_add(cfg, proxies)
    toml = build_toml(info)
    path = f'{cfg["proxies_dir"]}/{info["name"]}.toml'

    console.print()
    console.print("[bold]即将新增映射：[/bold]")
    console.print(f"  文件:  {path}")
    if info["desc"]:
        console.print(f"  备注:  {info['desc']}")
    console.print(f"  内容:  {info['type']}  {info['localIP']}:{info['localPort']} -> "
                  f"{info['remotePort'] if info['remotePort'] is not None else '(http/https 无远程端口)'}")
    if Confirm.ask("确认写入并重启 frpc？"):
        ssh_cmd(cfg, f'mkdir -p {cfg["proxies_dir"]} && cat > {path}', input_text=toml)
        console.print("[dim]已写入文件，[/dim]", end="")
        restart_frpc(cfg)
        console.print(f"[green]完成 ✅  已新增 {info['name']}[/green]")
    else:
        console.print("[dim]已取消[/dim]")


def do_rm(cfg, plist):
    v = ask_prompt("要删除的编号")
    if not v.isdigit() or not (1 <= int(v) <= len(plist)):
        console.print("[red]编号无效[/red]")
        return
    target = plist[int(v) - 1]
    console.print("[bold]将删除映射：[/bold]")
    console.print(f"    {target.get('name')}  "
                  f"{target.get('type','tcp')}  "
                  f"{target.get('localIP')}:{target.get('localPort')} -> "
                  f"{target.get('remotePort')}")
    if Confirm.ask("确认删除并重启 frpc？"):
        path = target["_file"]
        ssh_cmd(cfg, f'rm -f {path}')
        console.print("[dim]已删除文件，[/dim]", end="")
        restart_frpc(cfg)
        console.print(f"[green]完成 ✅  已删除 {target['name']}[/green]")
    else:
        console.print("[dim]已取消[/dim]")


def set_desc_for(cfg, target, files, new_desc):
    path = target["_file"]
    content = files.get(path)
    if content is None:
        console.print(f"[red]未读取到文件内容：{path}[/red]")
        return
    new_desc = (new_desc or "").replace("\n", " ").strip()
    new_line = f"# desc: {new_desc}" if new_desc else ""
    lines = content.rstrip("\n").splitlines()
    if any(DESC_RE.match(l) for l in lines):
        lines = [(new_line if DESC_RE.match(l) else l) for l in lines]
    else:
        lines.insert(0, new_line)
    lines = [l for l in lines if l != ""] or [""]
    new_content = "\n".join(lines) + "\n"

    name = target.get("name", "?")
    console.print(f"[bold]将更新 {name} 的备注为：{new_desc or '(清空)'}[/bold]")
    if Confirm.ask("确认写入并重启 frpc？"):
        ssh_cmd(cfg, f'cat > {path}', input_text=new_content)
        console.print("[dim]已写入，[/dim]", end="")
        restart_frpc(cfg)
        console.print(f"[green]完成 ✅  已更新 {name} 备注[/green]")
    else:
        console.print("[dim]已取消[/dim]")


def ask_new_desc(cur):
    if cur:
        raw = ask_prompt("新备注（回车保持，输入 - 清空）", default=cur)
        if raw == cur:
            return None
        return "" if raw == "-" else raw
    raw = ask_prompt("新备注（回车跳过）")
    return None if not raw else raw


def edit_desc_interactive(cfg, name):
    files = fetch_raw_files(cfg)
    proxies = parse_proxies(files)
    target = next((p for p in proxies if p.get("name") == name), None)
    if target is None:
        console.print(f"[red]未找到「{name}」[/red]")
        return
    new_desc = ask_new_desc(target.get("_desc", ""))
    if new_desc is None:
        console.print("[dim]未修改[/dim]")
        return
    set_desc_for(cfg, target, files, new_desc)


# ---------------------------------------------------------------------------
# 主交互循环
# ---------------------------------------------------------------------------
def render_list(plist, host=""):
    title = f"共 {len(plist)} 个映射"
    if host:
        title += f"  ·  公网 {host}"
    table = Table(title=title, header_style="bold cyan",
                  box=box.SIMPLE_HEAVY, title_style="bold")
    table.add_column("#", justify="right", style="dim")
    table.add_column("remote", justify="right", style="magenta")
    table.add_column("name", style="bold white")
    table.add_column("type", style="green")
    table.add_column("local", style="dim")
    table.add_column("desc", style="yellow", no_wrap=True)
    for i, p in enumerate(plist, 1):
        rpt = p.get("remotePort")
        table.add_row(
            str(i),
            str(rpt) if rpt is not None else "-",
            p.get("name", "?"),
            p.get("type", "tcp"),
            f"{p.get('localIP', '?')}:{p.get('localPort', '?')}",
            p.get("_desc", "") or "",
        )
    console.print(table)


def run(cfg):
    while True:
        files = fetch_raw_files(cfg)
        proxies = parse_proxies(files)
        plist = sorted(proxies, key=lambda x: x.get("name", ""))
        if not plist:
            console.print("[dim]当前没有任何映射[/dim]")
        else:
            render_list(plist, cfg["host"])

        console.print()
        console.print("[bold]编号[/bold]=浏览器打开  [bold]a[/bold]=新增  "
                      "[bold]e[/bold]=改备注  [bold]d[/bold]=删除  "
                      "[bold]r[/bold]=刷新  [bold]m[/bold]=切机器  [bold]q[/bold]=退出")
        try:
            v = ask_prompt("easyfrp> ")
        except (EOFError, KeyboardInterrupt):
            console.print()
            return
        v = v or ""

        if v in ("q", "quit", "exit"):
            return
        if v in ("m", "machine", "switch"):
            return "SWITCH"
        if v == "" or v in ("r", "refresh"):
            continue
        if v in ("a", "add", "+"):
            do_add(cfg)
            time.sleep(3)
            continue
        if v in ("d", "del", "rm", "-"):
            do_rm(cfg, plist)
            time.sleep(3)
            continue
        if v == "e" or v == "edit":
            v = "e " + ask_prompt("要改备注的编号")
        if v.startswith("e ") or v.startswith("edit "):
            tail = v.split(maxsplit=1)[1].strip()
            if tail.isdigit() and 1 <= int(tail) <= len(plist):
                edit_desc_interactive(cfg, plist[int(tail) - 1].get("name"))
            else:
                console.print("[red]编号无效[/red]")
            time.sleep(3)
            continue
        if v.isdigit():
            n = int(v)
            if 1 <= n <= len(plist):
                run_visit(cfg, plist[n - 1])
            else:
                console.print(f"[red]编号需在 1-{len(plist)} 之间[/red]")
        else:
            console.print("[dim]编号 / a 新增 / e 改备注 / d 删除 / m 切机器 / q 退出[/dim]")


# ---------------------------------------------------------------------------
# 机器选择
# ---------------------------------------------------------------------------
def select_machine(machines):
    if not machines:
        console.print("[red]config.toml 里没有配置 [[machines]]，请先添加[/red]")
        sys.exit(1)
    if len(machines) == 1:
        return machines[0]
    table = Table(title="选择要管理的 frpc 机器", header_style="bold cyan",
                  box=box.SIMPLE_HEAVY)
    table.add_column("#", justify="right", style="dim")
    table.add_column("name", style="bold white")
    table.add_column("ssh", style="magenta")
    for i, m in enumerate(machines, 1):
        table.add_row(str(i), m.get("name", "?"), str(m.get("ssh_port", "?")))
    console.print(table)
    while True:
        v = ask_prompt("选机器编号")
        if v.isdigit() and 1 <= int(v) <= len(machines):
            return machines[int(v) - 1]
        console.print(f"[red]编号需在 1-{len(machines)} 之间[/red]")


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        prog="easyfrp",
        description="交互式管理多台内网 frpc 机器的端口映射")
    ap.add_argument("--config", help="配置文件路径（默认 ~/.config/easyfrp/config.toml）")
    ap.add_argument("--machine", "-m", help="直接指定机器名，跳过选择")
    args = ap.parse_args()

    cfg_file = args.config or CONFIG_PATH
    if not Path(cfg_file).exists():
        console.print(f"[red]未找到配置文件 {cfg_file}[/red]")
        console.print("[dim]首次使用请把 config.example.toml 复制为 "
                      "~/.config/easyfrp/config.toml 并填写[/dim]")
        sys.exit(1)

    data = load_config(cfg_file)
    server = data.get("frps", {})
    commands = data.get("commands", {})
    machines = data.get("machines", [])

    if args.machine:
        machine = next((m for m in machines if m.get("name") == args.machine), None)
        if machine is None:
            console.print(f"[red]未找到名为「{args.machine}」的机器[/red]")
            sys.exit(1)
    else:
        machine = select_machine(machines)

    while True:
        cfg = build_cfg(server, commands, machine)
        if run(cfg) == "SWITCH":
            machine = select_machine(machines)
            continue
        break


if __name__ == "__main__":
    main()