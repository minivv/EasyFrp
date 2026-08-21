# install-frpc.ps1 — 一键安装 frpc 客户端（Windows 内网机器上运行）
#
# 安装：
#   powershell -ExecutionPolicy Bypass -File install-frpc.ps1 -ServerAddr 你的公网IP -Token 你的token
# 卸载（逐步 y 确认）：
#   powershell -ExecutionPolicy Bypass -File install-frpc.ps1 -Uninstall

param(
    [string]$ServerAddr = "",
    [string]$Token = "",
    [int]$ServerPort = 7000,
    [int]$SshPort = 0,
    [int]$SshLocalPort = 22,
    [int]$AllowStart = 10000,
    [int]$AllowEnd = 20000,
    [string]$Version = "0.71.0",
    [string]$Dir = "$env:ProgramFiles\easyfrp",
    [switch]$NoGhProxy,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Confirm-Step {
    param([string]$Msg)
    $r = Read-Host "$Msg [y/N]"
    return ($r -match '^[yY]$')
}

function Test-Port {
    param([string]$HostName, [int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1000)
        if ($ok) { $null = $client.EndConnect($iar) }
        $client.Close()
        return $ok
    } catch {
        return $false
    }
}

function Find-FreePort {
    param([string]$HostName)
    for ($p = $AllowStart; $p -le $AllowEnd; $p++) {
        if (-not (Test-Port $HostName $p)) { return $p }
    }
    return 0
}

if ($Uninstall) {
    Write-Host "===== 卸载 frpc ====="
    schtasks /Query /TN "EasyFrp" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        if (Confirm-Step "删除计划任务 EasyFrp？") {
            schtasks /Delete /TN "EasyFrp" /F | Out-Null
            Write-Host "  已删除计划任务"
        } else {
            Write-Host "  跳过计划任务删除"
        }
    } else {
        Write-Host "  未找到计划任务 EasyFrp"
    }
    if (Test-Path $Dir) {
        if (Confirm-Step "删除安装目录 $Dir（含 frpc.exe 与配置）？") {
            Remove-Item -Recurse -Force $Dir
            Write-Host "  已删除 $Dir"
        } else {
            Write-Host "  跳过目录删除"
        }
    } else {
        Write-Host "  未找到安装目录 $Dir"
    }
    Write-Host "卸载流程结束"
    exit 0
}

if (-not $ServerAddr) { Write-Host "错误：缺少 -ServerAddr"; exit 1 }
if (-not $Token) { Write-Host "错误：缺少 -Token"; exit 1 }

$proc = $env:PROCESSOR_ARCHITECTURE
switch ($proc) {
    "AMD64"   { $arch = "amd64" }
    "ARM64"   { $arch = "arm64" }
    default   { Write-Host "不支持的架构: $proc"; exit 1 }
}

if ($SshPort -eq 0) {
    Write-Host "==> 自动探测 ${ServerAddr}:${AllowStart}-${AllowEnd} 的空闲端口..."
    $SshPort = Find-FreePort $ServerAddr
    if ($SshPort -eq 0) { Write-Host "错误：未找到空闲端口，请用 -SshPort 手动指定"; exit 1 }
    Write-Host "==> 探测到空闲端口: $SshPort（作为本机 ssh 的远程端口）"
}

$base = if ($NoGhProxy) { "https://github.com" } else { "https://gh-proxy.org/https://github.com" }
$url = "$base/fatedier/frp/releases/download/v$Version/frp_${Version}_windows_${arch}.zip"
Write-Host "==> 下载 $url"
$tmp = Join-Path $env:TEMP "frp_${Version}.zip"
curl.exe -fsSL $url -o $tmp
if ($LASTEXITCODE -ne 0) { Write-Host "下载失败"; exit 1 }

New-Item -ItemType Directory -Force -Path "$Dir\proxies" | Out-Null
$expand = Join-Path $env:TEMP "frp_expand"
if (Test-Path $expand) { Remove-Item -Recurse -Force $expand }
Expand-Archive -Path $tmp -DestinationPath $expand -Force
$srcFrpc = Get-ChildItem -Recurse -Path $expand -Filter "frpc.exe" | Select-Object -First 1
Copy-Item $srcFrpc.FullName "$Dir\frpc.exe" -Force
Remove-Item -Recurse -Force $expand
Remove-Item -Force $tmp

$dirUnix = $Dir -replace '\\', '/'
$frpcToml = @"
serverAddr = "$ServerAddr"
serverPort = $ServerPort

auth.method = "token"
auth.token = "$Token"

includes = ["$dirUnix/proxies/*.toml"]
"@
Write-Utf8NoBom "$Dir\frpc.toml" $frpcToml

$hostname = $env:COMPUTERNAME
$sshToml = @"
[[proxies]]
name = "ssh-$hostname"
type = "tcp"
localIP = "127.0.0.1"
localPort = $SshLocalPort
remotePort = $SshPort
"@
Write-Utf8NoBom "$Dir\proxies\ssh.toml" $sshToml

$exe = "$Dir\frpc.exe"
$cfg = "$Dir\frpc.toml"
$tr = '"' + $exe + '" -c "' + $cfg + '"'
schtasks /Create /TN "EasyFrp" /TR $tr /SC ONSTART /RU SYSTEM /F | Out-Null
schtasks /Run /TN "EasyFrp" | Out-Null

Write-Host ""
Write-Host "================ frpc 安装完成 ================"
Write-Host "系统:            Windows"
Write-Host "目录:            $Dir"
Write-Host "本机 ssh 远程端口: $SshPort （即 ${ServerAddr}:${SshPort} → 本机:${SshLocalPort}）"
Write-Host ""
Write-Host "在本机 EasyFrp 的 config.toml 追加以下配置即可管理这台机器："
Write-Host ""
Write-Host '[[machines]]'
Write-Host "name = \"$hostname\""
Write-Host "ssh_port = $SshPort"
Write-Host "proxies_dir = \"$dirUnix/proxies\""
Write-Host "frpc_toml = \"$dirUnix/frpc.toml\""