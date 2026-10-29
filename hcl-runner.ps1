param(
  [Parameter(Mandatory = $true)][string]$PlanFile,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [int]$BootTimeoutSec = 300,
  [int]$ConsoleTimeoutSec = 240,
  [switch]$ForceConfigure,
  [switch]$NoGuiOpen,
  [switch]$SkipStart,
  [switch]$DryRun
)

# ============================================================================
# HCL 本地全自动执行器（提权运行，模型只调用一次）
#   打开工程 -> 启动设备 -> 从 HCL 日志发现控制台端口 -> TCP 下发配置
#   -> 执行验收命令（含断言） -> 保存配置/工程 -> 输出紧凑报告
# 设计目标：把判断、重试、断言全部放到本地脚本，模型只需一次调用+读摘要
# ============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class HclRunner {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayout(string pwszKLID, uint flags);
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$logPath = Join-Path $OutDir 'runner.log'
$reportJson = Join-Path $OutDir 'runner-report.json'
$reportMd = Join-Path $OutDir 'runner-report.md'
$hclLog = 'C:\Program Files (x86)\HCL\Log\HCLLog\HCL.log'
$hclExe = 'C:\Program Files (x86)\HCL\H3C Cloud Lab.exe'
$hclIni = Join-Path $env:APPDATA 'H3C\HCL.ini'

$state = [ordered]@{
  startedAt = (Get-Date).ToString('o')
  plan = $PlanFile
  stages = [ordered]@{}
  devices = [ordered]@{}
  success = $false
}
$errors = New-Object System.Collections.ArrayList

function Log([string]$message) {
  $line = (Get-Date).ToString('HH:mm:ss') + ' ' + $message
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
  Write-Host $line
}

# 单实例锁：避免两个执行器互相杀 HCL / 删工程目录（会导致设备启动失败）
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*hcl-runner.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object {
      try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Log ("killed stale runner pid " + $_.ProcessId) } catch { }
    }
} catch { }
$lockFile = Join-Path $OutDir 'runner.lock'
if (Test-Path -LiteralPath $lockFile) {
  $oldPid = 0
  try { $oldPid = [int]((Get-Content -LiteralPath $lockFile -Raw).Trim()) } catch { }
  $alive = $false
  if ($oldPid -gt 0) {
    try {
      $oldProc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $oldPid) -ErrorAction SilentlyContinue
      if ($oldProc -and $oldProc.CommandLine -like '*hcl-runner.ps1*') { $alive = $true }
    } catch { }
  }
  if ($alive) {
    Log ("another runner is active (pid $oldPid), abort")
    throw "another runner is active (pid $oldPid)"
  }
  Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
  Log ("stale lock removed (pid $oldPid)")
}
Set-Content -LiteralPath $lockFile -Value $PID -Encoding ASCII
function Read-Text($stream, [int]$ms) {
  $buf = New-Object byte[] 16384
  $sb = New-Object System.Text.StringBuilder
  $end = (Get-Date).AddMilliseconds($ms)
  while ((Get-Date) -lt $end) {
    if ($stream.DataAvailable) {
      $n = $stream.Read($buf, 0, $buf.Length)
      if ($n -gt 0) { [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n)) }
    } else { Start-Sleep -Milliseconds 60 }
  }
  return $sb.ToString()
}
function Send-Line($stream, [string]$text, [int]$pauseMs = 250) {
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($text + "`r`n")
  $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
  Start-Sleep -Milliseconds $pauseMs
}
function Get-Windows {
  $found = New-Object System.Collections.ArrayList
  foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) {
    try {
      $h = [IntPtr]$proc.MainWindowHandle
      if ($h -eq [IntPtr]::Zero) { continue }
      $title = $proc.MainWindowTitle
      if ([string]::IsNullOrWhiteSpace($title)) { continue }
      $r = New-Object HclRunner+RECT
      [void][HclRunner]::GetWindowRect($h, [ref]$r)
      [void]$found.Add([pscustomobject]@{
        handle = [long]$h; title = $title; left = $r.Left; top = $r.Top
        width = $r.Right - $r.Left; height = $r.Bottom - $r.Top
      })
    } catch { }
  }
  return $found
}
function Find-WindowExact([string]$title) {
  Get-Windows | Where-Object { $_.title -eq $title } | Select-Object -First 1
}
function Find-WindowLike([string]$match) {
  Get-Windows | Where-Object { $_.title -like "*$match*" } | Sort-Object { $_.width * $_.height } -Descending | Select-Object -First 1
}
function Get-Scale($w) {
  try { $dpi = [HclRunner]::GetDpiForWindow([IntPtr]$w.handle); if ($dpi -ge 96) { return $dpi / 96.0 } } catch { }
  return 1.0
}
function Focus-Window($w) {
  if ($null -eq $w) { return }
  [HclRunner]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero) | Out-Null
  [HclRunner]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero) | Out-Null
  [void][HclRunner]::ShowWindow([IntPtr]$w.handle, 9)
  [void][HclRunner]::SetForegroundWindow([IntPtr]$w.handle)
  Start-Sleep -Milliseconds 400
}
function Click-Relative($w, [int]$relx, [int]$rely) {
  Focus-Window $w
  $x = $w.left + $relx
  $y = $w.top + $rely
  [void][HclRunner]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 120
  [HclRunner]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
  Start-Sleep -Milliseconds 60
  [HclRunner]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
  Start-Sleep -Milliseconds 200
}
function DoubleClick-Relative($w, [int]$relx, [int]$rely) {
  Focus-Window $w
  $x = $w.left + $relx
  $y = $w.top + $rely
  [void][HclRunner]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 120
  [HclRunner]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
  [HclRunner]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
  Start-Sleep -Milliseconds 90
  [HclRunner]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
  [HclRunner]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
  Start-Sleep -Milliseconds 200
}
function Send-Keys([string]$keys) {
  [System.Windows.Forms.SendKeys]::SendWait($keys)
  Start-Sleep -Milliseconds 400
}
function ConvertTo-QtEscaped([string]$value) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $value.ToCharArray()) {
    $code = [int][char]$ch
    if ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($code -ge 32 -and $code -lt 127) { [void]$sb.Append($ch) }
    else { [void]$sb.Append('\x' + $code.ToString('x4')) }
  }
  return $sb.ToString()
}
function Set-HclRecent([string]$netPath) {
  if (-not (Test-Path -LiteralPath $hclIni)) { throw "HCL.ini not found: $hclIni" }
  $text = Get-Content -LiteralPath $hclIni -Raw -Encoding UTF8
  $escaped = ConvertTo-QtEscaped $netPath.ToLower()
  $newLine = '0\path=' + $escaped
  $match = [regex]::Match($text, '(?m)^0\\path=.*$')
  if ($match.Success) {
    $text = $text.Substring(0, $match.Index) + $newLine + $text.Substring($match.Index + $match.Length)
  } elseif ($text -match '(?m)^\[Recent\.files\]\s*$') {
    $sectionMatch = [regex]::Match($text, '(?m)^\[Recent\.files\]\s*$')
    $text = $text.Substring(0, $sectionMatch.Index + $sectionMatch.Length) + "`r`n" + $newLine + $text.Substring($sectionMatch.Index + $sectionMatch.Length)
  } else {
    $text = $text.TrimEnd() + "`r`n`r`n[Recent.files]`r`n" + $newLine + "`r`n"
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($hclIni, $text, $utf8NoBom)
  Log "HCL.ini recent[0] -> $netPath"
}
function Set-HclProjectDirectory([string]$dir) {
  $text = Get-Content -LiteralPath $hclIni -Raw -Encoding UTF8
  $escaped = ConvertTo-QtEscaped $dir
  $match = [regex]::Match($text, '(?m)^project_directory\s*=\s*.*$')
  if ($match.Success) {
    $text = $text.Substring(0, $match.Index) + ('project_directory=' + $escaped) + $text.Substring($match.Index + $match.Length)
  } else {
    $text = $text -replace '(?m)^\[HCL\]\s*$', ("[HCL]`r`nproject_directory=" + $escaped)
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($hclIni, $text, $utf8NoBom)
  Log "HCL.ini project_directory -> $dir"
}
function Get-HclProjectDirectoryLine {
  $text = Get-Content -LiteralPath $hclIni -Raw -Encoding UTF8
  $match = [regex]::Match($text, '(?m)^project_directory\s*=\s*.*$')
  if ($match.Success) { return $match.Value }
  return $null
}
function Restore-HclProjectDirectory([string]$line) {
  if ([string]::IsNullOrWhiteSpace($line)) { return }
  $text = Get-Content -LiteralPath $hclIni -Raw -Encoding UTF8
  $match = [regex]::Match($text, '(?m)^project_directory\s*=\s*.*$')
  if ($match.Success) {
    $text = $text.Substring(0, $match.Index) + $line + $text.Substring($match.Index + $match.Length)
    [System.IO.File]::WriteAllText($hclIni, $text, (New-Object System.Text.UTF8Encoding($false)))
    Log 'HCL.ini project_directory restored'
  }
}
function Stop-HclProcesses {
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'H3C Cloud|HCL|Simware|putty' } | ForEach-Object {
    try { $_.Kill() } catch { }
  }
  Start-Sleep -Seconds 3
}
function ConvertTo-PortsObject($map) {
  $out = [ordered]@{}
  if ($null -ne $map) { foreach ($k in @($map.Keys)) { $out["device$k"] = $map[$k] } }
  return $out
}
function Get-HomeWindow {
  Get-Windows | Where-Object {
    ($_.title -eq 'HCL' -or $_.title -eq '对话框' -or $_.title -eq '首页' -or $_.title -eq 'H3C Cloud Lab') -and $_.width -gt 600
  } | Sort-Object { $_.width * $_.height } -Descending | Select-Object -First 1
}
function Get-TelnetPorts([datetime]$since) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $hclLog)) { return $map }
  $lines = Get-Content -LiteralPath $hclLog -Tail 400 -ErrorAction SilentlyContinue
  foreach ($line in $lines) {
    if ($line -notmatch 'create_telnet_server') { continue }
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
      $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
      if ($ts -lt $since.AddSeconds(-5)) { continue }
    }
    if ($line -match 'device(\d+),\s*telnet_port:(\d+)') {
      $map[[int]$Matches[1]] = [int]$Matches[2]
    }
  }
  return $map
}
function Open-Console([int]$port) {
  $c = New-Object System.Net.Sockets.TcpClient
  $c.Connect('127.0.0.1', $port)
  return @{ client = $c; stream = $c.GetStream() }
}
function Wait-ConsoleReady([int]$port, [int]$timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $conn = Open-Console $port
      Start-Sleep -Milliseconds 400
      $out = Read-Text $conn.stream 800
      $conn.stream.Write([byte[]](0x03), 0, 1); $conn.stream.Flush()
      Start-Sleep -Milliseconds 300
      $conn.stream.Write([byte[]](0x0d, 0x0a), 0, 2); $conn.stream.Flush()
      Start-Sleep -Milliseconds 600
      $out += Read-Text $conn.stream 900
      if ($out -match '(?m)<[^<>\r\n]{1,40}>\s*$' -or $out -match 'Press ENTER to get started') {
        $conn.client.Close()
        return $true
      }
      $conn.client.Close()
    } catch { }
    Start-Sleep -Seconds 5
  }
  return $false
}
function Send-CommandsToConsole([int]$port, [string[]]$commands) {
  $conn = Open-Console $port
  $s = $conn.stream
  Start-Sleep -Milliseconds 400
  $null = Read-Text $s 700
  Send-Line $s 'screen-length disable' 300
  $null = Read-Text $s 400
  $errors = New-Object System.Collections.ArrayList
  foreach ($cmd in $commands) {
    Send-Line $s $cmd 320
    $resp = Read-Text $s 500
    if ($resp -match 'Unrecognized command|Too many parameters|Incomplete command|Wrong parameter') {
      $detail = ($resp -split "`r?`n" | Where-Object { $_ -match 'Unrecognized|Too many|Incomplete|Wrong parameter' } | Select-Object -First 1)
      [void]$errors.Add(($cmd + ' => ' + $detail))
    }
  }
  Start-Sleep -Milliseconds 600
  $tail = Read-Text $s 1000
  $conn.client.Close()
  return @{ errors = $errors; tail = $tail }
}
function Query-Console([int]$port, [string[]]$commands, [int]$waitMs = 1200) {
  $conn = Open-Console $port
  $s = $conn.stream
  Start-Sleep -Milliseconds 400
  $null = Read-Text $s 600
  Send-Line $s 'screen-length disable' 300
  $null = Read-Text $s 400
  $results = [ordered]@{}
  foreach ($cmd in $commands) {
    Send-Line $s $cmd 450
    $text = Read-Text $s $waitMs
    $results[$cmd] = $text
  }
  $conn.client.Close()
  return $results
}
function Save-DeviceConfig([int]$port) {
  $conn = Open-Console $port
  $s = $conn.stream
  Start-Sleep -Milliseconds 400
  $null = Read-Text $s 600
  Send-Line $s 'save' 900
  $p1 = Read-Text $s 1200
  Send-Line $s 'y' 900
  $p2 = Read-Text $s 1200
  Send-Line $s '' 1200
  $p3 = Read-Text $s 1800
  $conn.client.Close()
  $all = $p1 + $p2 + $p3
  return @{ saved = ($all -match 'Saved the current configuration|successfully'); raw = $all }
}

# ---------------------------------------------------------------------------
trap {
  try { Log ("FATAL: " + $_.Exception.Message) } catch { }
  try { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue } catch { }
  exit 2
}
$plan = Get-Content -LiteralPath $PlanFile -Raw -Encoding UTF8 | ConvertFrom-Json
$projectNet = [string]$plan.project
if (-not (Test-Path -LiteralPath $projectNet)) { throw "project not found: $projectNet" }
$projectName = [System.IO.Path]::GetFileNameWithoutExtension($projectNet)
$runStart = Get-Date
Log "PLAN project=$projectNet name=$projectName"

if ($DryRun) {
  $devNames = @($plan.devices.PSObject.Properties.Name)
  Log ('DRY RUN OK: devices=' + ($devNames -join ',') + ' consoleTimeoutSec=' + $ConsoleTimeoutSec)
  Set-Content -LiteralPath (Join-Path $OutDir 'runner-dryrun.json') -Value ($plan | ConvertTo-Json -Depth 10) -Encoding UTF8
  exit 0
}

# ---------- 阶段 1：确保目标工程已打开 ----------
$stage = [ordered]@{ startedAt = (Get-Date).ToString('o') }
$projectWin = Find-WindowLike $projectName
if ($null -eq $projectWin) {
  if ($NoGuiOpen) { throw 'project window not found and -NoGuiOpen specified' }
  $origProjDirLine = Get-HclProjectDirectoryLine
  Log 'project window not found, preparing isolated HCL project directory'
  $hclProjectsTemp = Join-Path (Split-Path -Parent (Split-Path -Parent $OutDir)) '.task\hcl-projects'
  # 先停 HCL，再删除/复制目录（顺序错误会让正在启动的设备写备份失败）
  Stop-HclProcesses
  Remove-Item -LiteralPath $hclProjectsTemp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $hclProjectsTemp | Out-Null
  $targetProjectDir = Join-Path $hclProjectsTemp $projectName
  Copy-Item -LiteralPath (Split-Path -Parent $projectNet) -Destination $targetProjectDir -Recurse -Force
  # HCL 启动设备时会在工程根目录写备份，预建目录避免 FileNotFoundError
  New-Item -ItemType Directory -Force -Path (Join-Path $targetProjectDir 'backupFileNameDirqwertyuiop') | Out-Null
  Log "project copied to isolated dir: $hclProjectsTemp"
  Set-HclProjectDirectory $hclProjectsTemp
  Start-Process -FilePath $hclExe -WorkingDirectory (Split-Path -Parent $hclExe) | Out-Null
  $homeWin = $null
  $deadline = (Get-Date).AddSeconds(150)
  $tick = 0
  while ((Get-Date) -lt $deadline) {
    $homeWin = Get-HomeWindow
    if ($null -ne $homeWin) { break }
    $tick++
    if ($tick % 5 -eq 0) {
      $all = Get-Windows | Where-Object { $_.title -match 'HCL|对话框|首页' } | ForEach-Object { $_.title + '(' + $_.width + 'x' + $_.height + ')' }
      Log ("waiting home window... candidates: " + ($all -join '; '))
    }
    Start-Sleep -Seconds 2
  }
  if ($null -eq $homeWin) { throw 'HCL home window not found' }
  Log ("home window: " + $homeWin.title + " " + $homeWin.width + "x" + $homeWin.height)
  Start-Sleep -Seconds 10
  # 我的工程只有本工程一个，逐候选坐标点"打开"
  $candidates = @(
    @{ x = 578; y = 114 },
    @{ x = 590; y = 98 },
    @{ x = 590; y = 130 },
    @{ x = 578; y = 146 }
  )
  foreach ($cand in $candidates) {
    Log ("try open my-project at " + $cand.x + "," + $cand.y)
    Click-Relative $homeWin $cand.x $cand.y
    $deadline = (Get-Date).AddSeconds(22)
    while ((Get-Date) -lt $deadline) {
      $projectWin = Find-WindowLike $projectName
      if ($null -ne $projectWin) { break }
      Start-Sleep -Seconds 2
    }
    if ($null -ne $projectWin) { break }
  }
  Restore-HclProjectDirectory $origProjDirLine
}
if ($null -eq $projectWin) { throw "project window not found after open: $projectName" }
Log ("project window: " + $projectWin.title)
$stage['projectWindow'] = $projectWin.title
$state['stages']['openProject'] = $stage
$openDone = Get-Date

# ---------- 阶段 2：启动全部设备 ----------
$stage = [ordered]@{ startedAt = (Get-Date).ToString('o') }
$existingPorts = Get-TelnetPorts $openDone
if ($existingPorts.Count -ge 1 -or $SkipStart) {
  Log 'devices already have consoles or -SkipStart, skip start'
  $stage['skipped'] = $true
} else {
  Log 'clicking start-all'
  Click-Relative $projectWin 605 48
  Start-Sleep -Seconds 2
  $expected = @()
  if ($plan.devices) { $expected = @($plan.devices.PSObject.Properties | ForEach-Object { [int]$_.Value.id }) }
  $deadline = (Get-Date).AddSeconds($BootTimeoutSec)
  $ports = @{}
  while ((Get-Date) -lt $deadline) {
    $ports = Get-TelnetPorts $runStart
    if ($expected.Count -gt 0) {
      $got = @($expected | Where-Object { $ports.ContainsKey($_) })
      if ($got.Count -ge $expected.Count) { break }
    } elseif ($ports.Count -ge 1) { break }
    Start-Sleep -Seconds 4
  }
  $stage['ports'] = ConvertTo-PortsObject $ports
}
$ports = Get-TelnetPorts $runStart
if ($ports.Count -eq 0) { $ports = Get-TelnetPorts $openDone }
if ($ports.Count -eq 0) { $ports = Get-TelnetPorts (Get-Date).AddDays(-1) }
$stage['portsFinal'] = ConvertTo-PortsObject $ports
$state['stages']['startDevices'] = $stage
Log ('console ports: ' + (($ports.GetEnumerator() | ForEach-Object { "device$($_.Key)=$($_.Value)" }) -join ', '))

# ---------- 阶段 3：等待控制台就绪并配置/验收 ----------
$stage = [ordered]@{ startedAt = (Get-Date).ToString('o'); devices = [ordered]@{} }
$devices = $plan.devices
foreach ($prop in $devices.PSObject.Properties) {
  $name = $prop.Name
  $spec = $prop.Value
  $id = [int]$spec.id
  if (-not $ports.ContainsKey($id)) {
    Log "[$name] no console port, skip"
    [void]$errors.Add("$name no console port")
    $stage['devices'][$name] = @{ ok = $false; reason = 'no console port' }
    continue
  }
  $port = [int]$ports[$id]
  Log "[$name] console port $port"
  $dev = [ordered]@{ port = $port }
  if (Wait-ConsoleReady $port $ConsoleTimeoutSec) {
    $dev['ready'] = $true
    Log "[$name] console ready"
  } else {
    $dev['ready'] = $false
    [void]$errors.Add("$name console not ready")
    Log "[$name] console NOT ready"
    $stage['devices'][$name] = $dev
    continue
  }

  # 判断是否已配置（sysname 判定）
  $already = $false
  if (-not $ForceConfigure) {
    $chk = Query-Console $port @('display current-configuration | include sysname') 1500
    $text = ($chk.Values | Out-String)
    if ($text -match ('sysname\s+' + [regex]::Escape($name))) { $already = $true }
  }
  $dev['alreadyConfigured'] = $already
  if ($already) {
    Log "[$name] already configured, skip config commands"
  } elseif ($spec.commands -and $spec.commands.Count -gt 0) {
    Log "[$name] applying $($spec.commands.Count) commands"
    $apply = Send-CommandsToConsole $port @($spec.commands)
    $dev['configErrors'] = @($apply.errors)
    if ($apply.errors.Count -gt 0) {
      foreach ($e in $apply.errors) { [void]$errors.Add("$name config: $e") }
      Log "[$name] config errors: $($apply.errors.Count)"
    } else {
      Log "[$name] config applied without detected errors"
    }
  }

  # 验收命令
  $dev['verify'] = [ordered]@{}
  if ($spec.verify -and $spec.verify.Count -gt 0) {
    $verify = Query-Console $port @($spec.verify) 1600
    foreach ($key in $verify.Keys) {
      $clean = ($verify[$key] -split "`r?`n" | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }) -join "`n"
      $dev['verify'][$key] = $clean
    }
    Log "[$name] verify done: $($spec.verify.Count) commands"
  }

  # 本地断言校验（无需模型看图）
  $dev['checks'] = @()
  if ($spec.checks) {
    $allText = (@($dev['verify'].Values) -join "`n")
    $checkResults = @()
    foreach ($pattern in @($spec.checks)) {
      $ok = [bool]($allText -match $pattern)
      $checkResults += @{ pattern = $pattern; ok = $ok }
      if (-not $ok) { [void]$errors.Add("$name check failed: $pattern") }
    }
    $dev['checks'] = $checkResults
    $passed = @($checkResults | Where-Object { $_.ok }).Count
    Log "[$name] checks passed: $passed/$($checkResults.Count)"
  }

  # 保存
  if ($spec.save -eq $true) {
    $save = Save-DeviceConfig $port
    $dev['saved'] = $save.saved
    if (-not $save.saved) { [void]$errors.Add("$name save failed") }
    Log "[$name] save=$($save.saved)"
  }
  $stage['devices'][$name] = $dev
}
$stage['finishedAt'] = (Get-Date).ToString('o')
$state['stages']['configureAndVerify'] = $stage

# ---------- 阶段 4：保存工程 ----------
$stage = [ordered]@{ startedAt = (Get-Date).ToString('o') }
try {
  $projectWin = Find-WindowLike $projectName
  if ($null -ne $projectWin) {
    Focus-Window $projectWin
    Start-Sleep -Milliseconds 500
    Send-Keys '^s'
    Start-Sleep -Seconds 4
    $stage['saved'] = $true
    Log 'project saved with Ctrl+S'
  }
} catch {
  $stage['saved'] = $false
  [void]$errors.Add('project save failed: ' + $_.Exception.Message)
}
$state['stages']['saveProject'] = $stage

# ---------- 汇总 ----------
$state['finishedAt'] = (Get-Date).ToString('o')
$state['durationSec'] = [int]((Get-Date) - $runStart).TotalSeconds
$state['errors'] = @($errors)
$state['success'] = ($errors.Count -eq 0)

$json = $state | ConvertTo-Json -Depth 12
Set-Content -LiteralPath $reportJson -Value $json -Encoding UTF8

$configStage = $state['stages']['configureAndVerify']
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# HCL 本地自动执行报告")
[void]$md.AppendLine("")
[void]$md.AppendLine("- 工程：``$projectNet``")
[void]$md.AppendLine("- 成功：$($state['success'])")
[void]$md.AppendLine("- 耗时：$($state['durationSec']) 秒")
[void]$md.AppendLine("- 错误数：$($errors.Count)")
[void]$md.AppendLine("")
[void]$md.AppendLine("## 控制台端口")
foreach ($kv in $ports.GetEnumerator()) { [void]$md.AppendLine("- device$($kv.Key) = $($kv.Value)") }
[void]$md.AppendLine("")
[void]$md.AppendLine("## 设备结果")
if ($null -ne $configStage -and $null -ne $configStage['devices']) {
  foreach ($name in $configStage['devices'].Keys) {
    $d = $configStage['devices'][$name]
    if ($d.Contains('ok') -and -not $d['ok']) {
      [void]$md.AppendLine("- $name ：失败（$($d['reason'])）")
      continue
    }
    [void]$md.AppendLine("- $name ：port=$($d['port']) ready=$($d['ready']) 已配置=$($d['alreadyConfigured']) save=$($d['saved']) 配置错误=$(@($d['configErrors']).Count)")
    if ($d['verify']) {
      foreach ($k in $d['verify'].Keys) {
        [void]$md.AppendLine("  - 验收 ``$k``：")
        foreach ($line in ($d['verify'][$k] -split "`n")) { [void]$md.AppendLine("    " + $line) }
      }
    }
  }
}
if ($errors.Count -gt 0) {
  [void]$md.AppendLine("")
  [void]$md.AppendLine("## 错误")
  foreach ($e in $errors) { [void]$md.AppendLine("- $e") }
}
Set-Content -LiteralPath $reportMd -Value $md.ToString() -Encoding UTF8

# 紧凑摘要（模型只需读这个文件，约 10 行）
$txt = New-Object System.Text.StringBuilder
[void]$txt.AppendLine(("success={0} duration={1}s errors={2}" -f $state['success'], $state['durationSec'], $errors.Count))
if ($null -ne $configStage -and $null -ne $configStage['devices']) {
  foreach ($name in $configStage['devices'].Keys) {
    $d = $configStage['devices'][$name]
    if ($d.Contains('ok') -and -not $d['ok']) {
      [void]$txt.AppendLine("$name FAIL " + $d['reason'])
      continue
    }
    $checks = @($d['checks'])
    $passed = @($checks | Where-Object { $_.ok }).Count
    $status = 'PASS'
    if (@($d['configErrors']).Count -gt 0 -or $passed -lt $checks.Count) { $status = 'FAIL' }
    [void]$txt.AppendLine(("{0} {1} port={2} checks={3}/{4} saved={5}" -f $name, $status, $d['port'], $passed, $checks.Count, $d['saved']))
  }
}
if ($errors.Count -gt 0) { [void]$txt.AppendLine('ERRORS: ' + (($errors | Select-Object -First 8) -join ' | ')) }
Set-Content -LiteralPath (Join-Path $OutDir 'runner-summary.txt') -Value $txt.ToString() -Encoding UTF8

Log ("DONE success=" + $state['success'] + " errors=" + $errors.Count + " duration=" + $state['durationSec'] + "s")
Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
if ($state['success']) { exit 0 } else { exit 2 }
