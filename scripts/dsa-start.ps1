#Requires -Version 5.1
<#
.SYNOPSIS
    DSA 一键启动 / 停止 / 重启 / 状态查询。

.DESCRIPTION
    服务的启动方式统一由计划任务 DSA-Service 承担：

    * 手动启动：本脚本调用 Start-ScheduledTask
    * 开机自启：同一任务的"登录时"触发器

    两者共用同一个任务，因此不会出现"手动启一个、自启又启一个"的重复实例
    （任务设置 MultipleInstances=IgnoreNew 进一步兜底）。

    任务本身执行 scripts\run-service.cmd，该文件用 pythonw.exe 启动服务：
    pythonw 是 GUI 子系统程序，不创建控制台，因此不会被"关闭控制台窗口"
    这类控制台事件杀掉（曾实测到日志以裸 ^C 结尾、服务随即消失）。

    服务以 `main.py --serve-only` 运行：提供 Web 工作台并自动恢复已启用的定时
    任务，但启动时不会立即执行全量分析，所以不会开机就烧 token。

.PARAMETER Action
    start（默认）| stop | restart | status

.PARAMETER NoBrowser
    start/restart 完成后不自动打开浏览器。

.PARAMETER TimeoutSeconds
    等待服务就绪的最长秒数，默认 180（首次启动可能需要在构建前端）。

.EXAMPLE
    .\scripts\dsa-start.ps1                 # 启动（已在运行则直接打开浏览器）
    .\scripts\dsa-start.ps1 -Action stop    # 停止
    .\scripts\dsa-start.ps1 -Action status  # 查看状态
#>
[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'restart', 'status')]
    [string]$Action = 'start',

    [switch]$NoBrowser,

    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ServiceLog = Join-Path $RepoRoot 'logs\service.log'
$ServiceTaskName = 'DSA-Service'

function Write-Step { param([string]$Message) Write-Host "  $Message" -ForegroundColor Gray }
function Write-Ok   { param([string]$Message) Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  $Message" -ForegroundColor Red }

function Get-WebPort {
    $envFile = Join-Path $RepoRoot '.env'
    if (Test-Path $envFile) {
        $match = Select-String -Path $envFile -Pattern '^\s*WEBUI_PORT\s*=\s*(\d+)' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($match) { return [int]$match.Matches[0].Groups[1].Value }
    }
    return 8000
}

function Get-ServiceTask {
    Get-ScheduledTask -TaskName $ServiceTaskName -ErrorAction SilentlyContinue
}

function Get-DsaProcesses {
    # 服务由 pythonw.exe 启动（GUI 子系统，无控制台），找不到 pythonw 时回退 python.exe。
    # 同时要求命令行里带 main.py，避免误伤其它 Python 程序。
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'main\.py' }
}

function Test-PortListening {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Test-ServiceReady {
    param([int]$Port)
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" -UseBasicParsing -TimeoutSec 5
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Show-LogTail {
    param([int]$Lines = 15)
    if (Test-Path $ServiceLog) {
        Get-Content $ServiceLog -Tail $Lines | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host '    （日志文件不存在）'
    }
}

function Start-DsaService {
    param([int]$Port)

    if (-not (Get-ServiceTask)) {
        Write-Fail "计划任务 $ServiceTaskName 不存在，无法启动。"
        Write-Step '请先注册该任务，再重试。'
        return $false
    }

    Write-Step "启动计划任务: $ServiceTaskName"
    try {
        Start-ScheduledTask -TaskName $ServiceTaskName
    } catch {
        Write-Fail "启动任务失败: $($_.Exception.Message)"
        return $false
    }

    Write-Step '等待服务就绪…'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $graceEnd = (Get-Date).AddSeconds(20)
    $processSeen = $false

    while ((Get-Date) -lt $deadline) {
        if (@(Get-DsaProcesses).Count -gt 0) { $processSeen = $true }

        if (Test-ServiceReady -Port $Port) {
            Write-Ok "服务已就绪: http://127.0.0.1:$Port"
            Write-Step "日志: $ServiceLog"
            return $true
        }

        # 宽限期内始终没有服务进程 => 启动失败，直接报错并给出日志末尾
        if (-not $processSeen -and (Get-Date) -gt $graceEnd) {
            Write-Fail '服务进程未能启动，末尾日志：'
            Show-LogTail
            return $false
        }
        Start-Sleep -Seconds 2
    }

    Write-Warn "等待 $TimeoutSeconds 秒后仍未就绪，服务可能仍在启动（首次可能需要构建前端）。"
    Write-Step "可稍后访问 http://127.0.0.1:$Port，或查看日志: $ServiceLog"
    return $false
}

function Stop-DsaService {
    $task = Get-ServiceTask
    $procs = @(Get-DsaProcesses)
    $port = Get-WebPort

    if (-not $task -and $procs.Count -eq 0) {
        Write-Step '服务未在运行。'
        return $true
    }

    if ($task -and $task.State -eq 'Running') {
        Write-Step "停止计划任务: $ServiceTaskName"
        try {
            Stop-ScheduledTask -TaskName $ServiceTaskName
        } catch {
            Write-Warn "停止任务返回: $($_.Exception.Message)"
        }
    }

    # Stop-ScheduledTask 不保证回收全部子进程，这里按进程名兜底清理
    Start-Sleep -Seconds 2
    foreach ($p in @(Get-DsaProcesses)) {
        Write-Step "清理残留进程 PID $($p.ProcessId)…"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    if (Test-PortListening -Port $port) {
        Write-Warn "端口 $port 仍被占用，可能还有残留进程。"
        return $false
    }
    Write-Ok '服务已停止。'
    return $true
}

function Show-DsaStatus {
    $port = Get-WebPort
    $procs = @(Get-DsaProcesses)
    $task = Get-ServiceTask

    Write-Host ''
    Write-Host '  DSA 服务状态' -ForegroundColor Cyan

    if ($task) {
        $logon = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count -gt 0
        $autostart = if ($logon) { '已启用' } else { '未配置' }
        Write-Host "    任务: $ServiceTaskName  状态=$($task.State)  登录自启=$autostart"
    } else {
        Write-Host '    任务: 未注册（无开机自启，启动器也无法启动）'
    }

    if ($procs.Count -eq 0) {
        Write-Host '    进程: 未运行'
    } else {
        foreach ($p in $procs) { Write-Host "    进程: $($p.Name) PID $($p.ProcessId)" }
    }
    Write-Host "    端口: $(if (Test-PortListening -Port $port) { "$port 监听中" } else { "$port 未监听" })"
    Write-Host "    地址: http://127.0.0.1:$port"
    Write-Host "    日志: $ServiceLog"
    Write-Host ''
}

function Open-DsaBrowser {
    param([int]$Port)
    if ($NoBrowser) { return }
    Write-Step "打开浏览器: http://127.0.0.1:$Port"
    Start-Process "http://127.0.0.1:$Port" | Out-Null
}

# ---------------------------- 主流程 ----------------------------

$port = Get-WebPort
Write-Host ''
Write-Host '  DSA 一键启动器' -ForegroundColor Cyan
Write-Host "  仓库: $RepoRoot" -ForegroundColor DarkGray
Write-Host ''

switch ($Action) {
    'status' {
        Show-DsaStatus
        exit 0
    }
    'stop' {
        if (Stop-DsaService) { exit 0 } else { exit 1 }
    }
    'restart' {
        Write-Step '先停止现有服务…'
        [void](Stop-DsaService)
        Write-Host ''
        if (Start-DsaService -Port $port) { Open-DsaBrowser -Port $port; exit 0 } else { exit 1 }
    }
    'start' {
        if (@(Get-DsaProcesses).Count -gt 0 -or (Test-PortListening -Port $port)) {
            Write-Ok '服务已在运行，跳过启动。'
            if (Test-ServiceReady -Port $port) {
                Write-Ok "健康检查通过: http://127.0.0.1:$port"
            } else {
                Write-Warn '服务进程存在但健康检查未通过，可能仍在启动中。'
            }
            Open-DsaBrowser -Port $port
            exit 0
        }
        if (Start-DsaService -Port $port) { Open-DsaBrowser -Port $port; exit 0 } else { exit 1 }
    }
}
