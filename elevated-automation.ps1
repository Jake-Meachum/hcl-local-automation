param(
  [Parameter(Mandatory = $true)][string]$WorkDir
)

$ErrorActionPreference = 'Continue'

trap {
  try {
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
    Set-Content -Path (Join-Path $WorkDir 'error.txt') -Value ("trap: " + $_.Exception.Message + " line " + $_.InvocationInfo.ScriptLineNumber) -Encoding UTF8
  } catch { }
  exit 1
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Set-Content -Path (Join-Path $WorkDir 'start.txt') -Value ("start pid=$PID user=" + [Security.Principal.WindowsIdentity]::GetCurrent().Name + " time=" + (Get-Date -Format o)) -Encoding UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class GuiAuto2 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("imm32.dll")] public static extern IntPtr ImmGetContext(IntPtr hWnd);
  [DllImport("imm32.dll")] public static extern bool ImmSetConversionStatus(IntPtr hIMC, uint fdwConversion, uint fdwSentence);
  [DllImport("imm32.dll")] public static extern bool ImmReleaseContext(IntPtr hWnd, IntPtr hIMC);
  public static bool SetEnglishMode(IntPtr hwnd) {
    IntPtr himc = ImmGetContext(hwnd);
    if (himc == IntPtr.Zero) return false;
    bool ok = ImmSetConversionStatus(himc, 0u, 0u);
    ImmReleaseContext(hwnd, himc);
    return ok;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayout(string pwszKLID, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  public static void ForceEnglishLayout(IntPtr hwnd) {
    IntPtr hkl = LoadKeyboardLayout("00000409", 1);
    if (hkl != IntPtr.Zero) {
      PostMessage(hwnd, 0x0050, IntPtr.Zero, hkl);
    }
  }
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive; public IntPtr hwndFocus; public IntPtr hwndCapture;
    public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
    public RECT rcCaret;
  }
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO info);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  public static IntPtr GetFocusHwnd() {
    IntPtr fg = GetForegroundWindow();
    uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
    GUITHREADINFO gti = new GUITHREADINFO();
    gti.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    if (GetGUIThreadInfo(tid, ref gti) && gti.hwndFocus != IntPtr.Zero) return gti.hwndFocus;
    return fg;
  }
  public static void ForceEnglish(IntPtr hwnd) {
    IntPtr himc = ImmGetContext(hwnd);
    if (himc != IntPtr.Zero) { ImmSetConversionStatus(himc, 0u, 0u); ImmReleaseContext(hwnd, himc); }
    IntPtr hkl = LoadKeyboardLayout("00000409", 1);
    if (hkl != IntPtr.Zero) { SendMessage(hwnd, 0x0050, IntPtr.Zero, hkl); }
  }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; }
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  public static void SendUnicode(string text) {
    foreach (char c in text) {
      INPUT down = new INPUT(); down.type = 1; down.ki.wVk = 0; down.ki.wScan = (ushort)c; down.ki.dwFlags = 0x0004;
      INPUT up = new INPUT(); up.type = 1; up.ki.wVk = 0; up.ki.wScan = (ushort)c; up.ki.dwFlags = 0x0006;
      SendInput(2, new INPUT[] { down, up }, Marshal.SizeOf(typeof(INPUT)));
    }
  }
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

# 物理像素坐标（避免 DPI 缩放导致截图/点击错位）
[void][GuiAuto2]::SetProcessDPIAware()
# 隐藏助手自身的控制台窗口，避免抢焦点
$console = [GuiAuto2]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { [void][GuiAuto2]::ShowWindow($console, 0) }

function Get-GuiWindows {
  $script:found = New-Object System.Collections.ArrayList
  $cb = [GuiAuto2+EnumProc]{
    param($h, $l)
    if ([GuiAuto2]::IsWindowVisible($h)) {
      $sb = New-Object System.Text.StringBuilder 512
      [void][GuiAuto2]::GetWindowText($h, $sb, $sb.Capacity)
      $t = $sb.ToString()
      if ($t.Length -gt 0) {
        $r = New-Object GuiAuto2+RECT
        [void][GuiAuto2]::GetWindowRect($h, [ref]$r)
        [void]$script:found.Add([pscustomobject]@{
          handle = [long]$h; title = $t; left = $r.Left; top = $r.Top
          width = $r.Right - $r.Left; height = $r.Bottom - $r.Top
        })
      }
    }
    return $true
  }
  [void][GuiAuto2]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:found
}

function Find-Win([string]$match) {
  if ([string]::IsNullOrWhiteSpace($match)) { return $null }
  if ($match.StartsWith('=')) {
    $exact = $match.Substring(1)
    return (Get-GuiWindows | Where-Object { $_.title -eq $exact } | Sort-Object { $_.width * $_.height } -Descending | Select-Object -First 1)
  }
  Get-GuiWindows | Where-Object { $_.title -like "*$match*" } |
    Sort-Object { $_.width * $_.height } -Descending | Select-Object -First 1
}

function Get-ForegroundTitle {
  $h = [GuiAuto2]::GetForegroundWindow()
  $sb = New-Object System.Text.StringBuilder 512
  [void][GuiAuto2]::GetWindowText($h, $sb, $sb.Capacity)
  return $sb.ToString()
}

function Focus-Win($w) {
  [GuiAuto2]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero) | Out-Null
  [GuiAuto2]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero) | Out-Null
  [void][GuiAuto2]::ShowWindow([IntPtr]$w.handle, 9)
  [void][GuiAuto2]::SetForegroundWindow([IntPtr]$w.handle)
  Start-Sleep -Milliseconds 450
  return (Get-ForegroundTitle)
}

function Get-WindowScale($w) {
  try {
    $dpi = [GuiAuto2]::GetDpiForWindow([IntPtr]$w.handle)
    if ($dpi -ge 96) { return $dpi / 96.0 }
  } catch { }
  return 1.0
}

function Save-WinShot($w, [string]$path) {
  $null = Focus-Win $w
  Start-Sleep -Milliseconds 300
  $scale = Get-WindowScale $w
  $r = New-Object GuiAuto2+RECT
  [void][GuiAuto2]::GetWindowRect([IntPtr]$w.handle, [ref]$r)
  $left = [int][Math]::Round($r.Left * $scale)
  $top = [int][Math]::Round($r.Top * $scale)
  $width = [int][Math]::Round(($r.Right - $r.Left) * $scale)
  $height = [int][Math]::Round(($r.Bottom - $r.Top) * $scale)
  if ($width -le 0 -or $height -le 0) { throw "invalid window rect" }
  $bmp = New-Object System.Drawing.Bitmap $width, $height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose()
  $bmp.Dispose()
  return "$path|$width x $height|$left,$top|scale=$scale"
}

function Save-WinShotNoFocus($w, [string]$path) {
  $scale = Get-WindowScale $w
  $r = New-Object GuiAuto2+RECT
  [void][GuiAuto2]::GetWindowRect([IntPtr]$w.handle, [ref]$r)
  $left = [int][Math]::Round($r.Left * $scale)
  $top = [int][Math]::Round($r.Top * $scale)
  $width = [int][Math]::Round(($r.Right - $r.Left) * $scale)
  $height = [int][Math]::Round(($r.Bottom - $r.Top) * $scale)
  if ($width -le 0 -or $height -le 0) { throw "invalid window rect" }
  Start-Sleep -Milliseconds 200
  $bmp = New-Object System.Drawing.Bitmap $width, $height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose()
  $bmp.Dispose()
  return "$path|$width x $height|$left,$top|scale=$scale"
}

function Read-PipeText($pipe, [int]$timeoutMs) {
  $buf = New-Object byte[] 8192
  $sb = New-Object System.Text.StringBuilder
  $end = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $end) {
    try {
      $task = $pipe.ReadAsync($buf, 0, $buf.Length)
      $remaining = [Math]::Max(20, [int](($end - (Get-Date)).TotalMilliseconds))
      if ($task.Wait($remaining)) {
        $n = $task.Result
        if ($n -gt 0) { [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n)) }
      }
    } catch { break }
  }
  return $sb.ToString()
}

function Invoke-Step($step) {
  $out = @{ action = [string]$step.action; ok = $false; detail = '' }
  switch ([string]$step.action) {
    'focus' {
      $w = Find-Win ([string]$step.title)
      if (-not $w) { throw "window not found: $($step.title)" }
      $out.foreground = Focus-Win $w
      $out.ok = $true
      break
    }
    'keys' {
      if (-not [string]::IsNullOrWhiteSpace([string]$step.title)) {
        $w = Find-Win ([string]$step.title)
        if ($w) { $null = Focus-Win $w }
      }
      [System.Windows.Forms.SendKeys]::SendWait([string]$step.keys)
      Start-Sleep -Milliseconds 150
      $out.foreground = Get-ForegroundTitle
      $out.ok = $true
      break
    }
    'paste' {
      if (-not [string]::IsNullOrWhiteSpace([string]$step.title)) {
        $w = Find-Win ([string]$step.title)
        if ($w) { $null = Focus-Win $w }
      }
      Set-Clipboard -Value ([string]$step.text)
      Start-Sleep -Milliseconds 120
      [System.Windows.Forms.SendKeys]::SendWait('^v')
      Start-Sleep -Milliseconds 150
      $out.foreground = Get-ForegroundTitle
      $out.ok = $true
      break
    }
    'type' {
      if (-not [string]::IsNullOrWhiteSpace([string]$step.title)) {
        $w = Find-Win ([string]$step.title)
        if ($w) { $null = Focus-Win $w }
      }
      [System.Windows.Forms.SendKeys]::SendWait([string]$step.text)
      Start-Sleep -Milliseconds 150
      $out.foreground = Get-ForegroundTitle
      $out.ok = $true
      break
    }
    'unicodetext' {
      if (-not [string]::IsNullOrWhiteSpace([string]$step.title)) {
        $w = Find-Win ([string]$step.title)
        if ($w) { $null = Focus-Win $w }
      }
      [GuiAuto2]::SendUnicode([string]$step.text)
      Start-Sleep -Milliseconds 200
      $out.foreground = Get-ForegroundTitle
      $out.ok = $true
      break
    }
    'imeenglish' {
      $focus = [GuiAuto2]::GetFocusHwnd()
      [GuiAuto2]::ForceEnglish($focus)
      $out.detail = "focus-hwnd=$focus"
      $out.ok = $true
      break
    }
    'type2' {
      if (-not [string]::IsNullOrWhiteSpace([string]$step.title)) {
        $w = Find-Win ([string]$step.title)
        if ($w) { $null = Focus-Win $w }
      }
      $focus = [GuiAuto2]::GetFocusHwnd()
      [GuiAuto2]::ForceEnglish($focus)
      Start-Sleep -Milliseconds 150
      foreach ($ch in ([string]$step.text).ToCharArray()) {
        if ($ch -eq ' ') {
          $scan = [byte][GuiAuto2]::MapVirtualKey(0x20, 0)
          [GuiAuto2]::keybd_event(0x20, $scan, 0, [UIntPtr]::Zero) | Out-Null
          [GuiAuto2]::keybd_event(0x20, $scan, 2, [UIntPtr]::Zero) | Out-Null
        } elseif ($ch -eq "`n") {
          [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        } else {
          [System.Windows.Forms.SendKeys]::SendWait([string]$ch)
        }
        Start-Sleep -Milliseconds 25
      }
      $out.foreground = Get-ForegroundTitle
      $out.ok = $true
      break
    }
    'click' { $null = Invoke-MouseStep $step 'click'; $out.ok = $true; $out.foreground = Get-ForegroundTitle; break }
    'rightclick' { $null = Invoke-MouseStep $step 'rightclick'; $out.ok = $true; $out.foreground = Get-ForegroundTitle; break }
    'doubleclick' { $null = Invoke-MouseStep $step 'doubleclick'; $out.ok = $true; $out.foreground = Get-ForegroundTitle; break }
    'sleep' {
      Start-Sleep -Milliseconds ([int]$step.ms)
      $out.ok = $true
      break
    }
    'shot' {
      $w = Find-Win ([string]$step.title)
      if (-not $w) { throw "window not found: $($step.title)" }
      $out.detail = Save-WinShot $w ([string]$step.path)
      $out.foreground = Get-ForegroundTitle
      $out.ok = $true
      break
    }
    'snapshot' {
      $w = Find-Win ([string]$step.title)
      if (-not $w) { throw "window not found: $($step.title)" }
      $out.detail = Save-WinShotNoFocus $w ([string]$step.path)
      $out.ok = $true
      break
    }
    'clickraw' {
      [void][GuiAuto2]::SetCursorPos([int]$step.x, [int]$step.y)
      Start-Sleep -Milliseconds 120
      [GuiAuto2]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
      Start-Sleep -Milliseconds 60
      [GuiAuto2]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
      $out.ok = $true
      break
    }
    'list' {
      $out.windows = @(Get-GuiWindows | Select-Object title, left, top, width, height)
      $out.ok = $true
      break
    }
    'pipeconsole' {
      $pipeName = [string]$step.pipe
      $commands = @($step.commands)
      $p = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
      $p.Connect(2500)
      $p.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Byte
      $sb = New-Object System.Text.StringBuilder
      Start-Sleep -Milliseconds 400
      [void]$sb.Append((Read-PipeText $p 1000))
      foreach ($cmd in $commands) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$cmd + "`r`n")
        try { $p.Write($bytes, 0, $bytes.Length); $p.Flush() } catch { break }
        Start-Sleep -Milliseconds 350
        [void]$sb.Append((Read-PipeText $p 900))
      }
      try { $p.Dispose() } catch { }
      $out.detail = $sb.ToString()
      $out.ok = $true
      break
    }
    default { throw "unknown step action: $($step.action)" }
  }
  return $out
}

function Invoke-MouseStep($step, [string]$kind) {
  $x = [int]$step.x
  $y = [int]$step.y
  if (-not [string]::IsNullOrWhiteSpace([string]$step.title)) {
    $w = Find-Win ([string]$step.title)
    if (-not $w) { throw "window not found: $($step.title)" }
    $null = Focus-Win $w
    $r = New-Object GuiAuto2+RECT
    [void][GuiAuto2]::GetWindowRect([IntPtr]$w.handle, [ref]$r)
    $x = $r.Left + [int]$step.relx
    $y = $r.Top + [int]$step.rely
  }
  [void][GuiAuto2]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 120
  switch ($kind) {
    'click' {
      [GuiAuto2]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
      Start-Sleep -Milliseconds 60
      [GuiAuto2]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
    }
    'rightclick' {
      [GuiAuto2]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
      Start-Sleep -Milliseconds 60
      [GuiAuto2]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
    }
    'doubleclick' {
      [GuiAuto2]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
      [GuiAuto2]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
      Start-Sleep -Milliseconds 90
      [GuiAuto2]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
      [GuiAuto2]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
    }
  }
  Start-Sleep -Milliseconds 120
  return "clicked $x,$y ($kind)"
}

Set-Content -Path (Join-Path $WorkDir 'ready.txt') -Value ("ready pid=" + $PID + " at " + (Get-Date -Format o)) -Encoding UTF8
$lastId = ''
$started = Get-Date
$exit = $false

while (-not $exit) {
  $cmdPath = Join-Path $WorkDir 'command.json'
  if (Test-Path -LiteralPath $cmdPath) {
    try { $cmd = Get-Content -LiteralPath $cmdPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cmd = $null }
    if ($cmd -ne $null -and $cmd.id -and ([string]$cmd.id -ne $lastId)) {
      $lastId = [string]$cmd.id
      $result = [ordered]@{ id = $lastId; ok = $false; detail = ''; foreground = '' }
      try {
        if ([string]$cmd.action -eq 'sequence') {
          $stepResults = @()
          $allOk = $true
          foreach ($step in @($cmd.steps)) {
            $r = Invoke-Step $step
            $stepResults += $r
            if (-not $r.ok) { $allOk = $false; break }
          }
          $result.steps = $stepResults
          $result.ok = $allOk
        } elseif ([string]$cmd.action -eq 'exit') {
          $result.ok = $true
          $result.detail = 'exiting'
          $exit = $true
        } else {
          $r = Invoke-Step $cmd
          foreach ($k in $r.Keys) { $result[$k] = $r[$k] }
          $result.ok = [bool]$r.ok
        }
      } catch {
        $result.ok = $false
        $result.detail = $_.Exception.Message
      }
      $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $WorkDir ("result-" + $lastId + ".json")) -Encoding UTF8
    }
  }
  if (((Get-Date) - $started).TotalMinutes -gt 30) { break }
  Start-Sleep -Milliseconds 250
}

Set-Content -Path (Join-Path $WorkDir 'stopped.txt') -Value ("stopped at " + (Get-Date -Format o)) -Encoding UTF8
