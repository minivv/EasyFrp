# install-frpc.ps1 — one-click frpc client installer (run on an intranet Windows box)
#
# Install:
#   powershell -ExecutionPolicy Bypass -File install-frpc.ps1 -ServerAddr <ip> -Token <token>
# Uninstall (step-by-step confirm):
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

# 写入 Program Files + 注册计划任务需要管理员权限；非管理员则 UAC 提权重跑一次
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $passed = @()
    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            $passed += "-$key"
        } else {
            $passed += "-$key"
            $passed += "`"$val`""
        }
    }
    Start-Process powershell -Verb RunAs -ArgumentList (@("-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") + $passed)
    exit
}

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
    Write-Host "===== Uninstall frpc ====="
    if (Get-ScheduledTask -TaskName "EasyFrp" -ErrorAction SilentlyContinue) {
        if (Confirm-Step "Delete scheduled task EasyFrp?") {
            Unregister-ScheduledTask -TaskName "EasyFrp" -Confirm:$false
            Write-Host "  Scheduled task removed"
        } else {
            Write-Host "  Skipped"
        }
    } else {
        Write-Host "  Scheduled task EasyFrp not found"
    }
    if (Test-Path $Dir) {
        if (Confirm-Step "Delete install dir $Dir (frpc.exe + config)?") {
            Remove-Item -Recurse -Force $Dir
            Write-Host "  Removed $Dir"
        } else {
            Write-Host "  Skipped"
        }
    } else {
        Write-Host "  Install dir not found: $Dir"
    }
    Write-Host "Uninstall done"
    exit 0
}

if (-not $ServerAddr) { Write-Host "Error: missing -ServerAddr"; exit 1 }
if (-not $Token) { Write-Host "Error: missing -Token"; exit 1 }

$proc = $env:PROCESSOR_ARCHITECTURE
switch ($proc) {
    "AMD64" { $arch = "amd64" }
    "ARM64" { $arch = "arm64" }
    default { Write-Host "Unsupported architecture: $proc"; exit 1 }
}

if ($SshPort -eq 0) {
    Write-Host "==> Probing free port on ${ServerAddr}:${AllowStart}-${AllowEnd} ..."
    $SshPort = Find-FreePort $ServerAddr
    if ($SshPort -eq 0) { Write-Host "Error: no free port, use -SshPort"; exit 1 }
    Write-Host "==> Free port: $SshPort (ssh remote port)"
}

$base = if ($NoGhProxy) { "https://github.com" } else { "https://gh-proxy.org/https://github.com" }
$url = "$base/fatedier/frp/releases/download/v$Version/frp_${Version}_windows_${arch}.zip"
Write-Host "==> Download $url"
$tmp = Join-Path $env:TEMP "frp_${Version}.zip"
curl.exe -fsSL $url -o $tmp
if ($LASTEXITCODE -ne 0) { Write-Host "Download failed"; exit 1 }

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
$action = New-ScheduledTaskAction -Execute $exe -Argument "-c `"$cfg`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM"
Register-ScheduledTask -TaskName "EasyFrp" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "EasyFrp"

Write-Host ""
Write-Host "================ frpc installed ================"
Write-Host "OS:              Windows"
Write-Host "Dir:             $Dir"
Write-Host "SSH remote port: $SshPort (${ServerAddr}:${SshPort} -> localhost:${SshLocalPort})"
Write-Host ""
Write-Host "Add this to EasyFrp config.toml to manage this machine:"
Write-Host ""
Write-Host '[[machines]]'
Write-Host "name = `"$hostname`""
Write-Host "ssh_port = $SshPort"
Write-Host "proxies_dir = `"$dirUnix/proxies`""
Write-Host "frpc_toml = `"$dirUnix/frpc.toml`""