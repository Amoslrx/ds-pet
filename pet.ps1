#Requires -Version 5.1
# ============================================================
# DS娘桌宠 v6 · 原生桌面宠物 (DS Maid Desktop Pet)
# ------------------------------------------------------------
# 双击「启动桌宠.bat」运行。
# 操作：
#   左键拖动   -> 移动位置；单击 -> 随机说可爱的话
#   滚轮       -> 放大 / 缩小（先点一下桌宠获得焦点）
#   双击       -> 恢复初始大小
#   右键单击   -> 关闭桌宠
#   全局按 F8  -> 显示 DeepSeek 余额（松开隐藏）
# v6 变更：改为 OnPaint 直接绘制帧（彻底解决闪烁）；去掉 +/- 最小化/退出按钮；
#          右键关闭桌宠。
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AppDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ImgPath = Join-Path $script:AppDir 'ds-cutout.png'
$script:ErrLog  = Join-Path $script:AppDir '.pet-errors.log'

function Log-Err {
  param($m)
  try { Add-Content -Path $script:ErrLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8 } catch {}
}
Log-Err '=== pet.ps1 v6 启动 ==='

# ---- 隐藏自己的控制台窗口（不影响桌宠窗体） ----
try {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public class ConHider {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
  $ch = [ConHider]::GetConsoleWindow()
  if ($ch -ne [IntPtr]::Zero) { [ConHider]::ShowWindow($ch, 0) | Out-Null }
  Log-Err 'console hidden'
} catch { Log-Err ('ConHider: ' + $_.Exception.Message) }

# ---- 原生 API（热键 / 键盘状态 / alpha 硬边 / 品红吸附） ----
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class PetApi {
  [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  public static void HardenAlpha(Bitmap bmp, byte threshold) {
    Rectangle rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
    BitmapData data = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    try {
      int len = data.Stride * data.Height;
      byte[] buf = new byte[len];
      Marshal.Copy(data.Scan0, buf, 0, len);
      for (int i = 3; i < len; i += 4) {
        byte a = buf[i];
        if (a > 0 && a < 255) buf[i] = (a >= threshold) ? (byte)255 : (byte)0;
      }
      Marshal.Copy(buf, 0, data.Scan0, len);
    } finally { bmp.UnlockBits(data); }
  }
  public static void SnapMagenta(Bitmap bmp) {
    Rectangle rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
    BitmapData data = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    try {
      int len = data.Stride * data.Height;
      byte[] buf = new byte[len];
      Marshal.Copy(data.Scan0, buf, 0, len);
      for (int i = 0; i < len; i += 4) {
        byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
        if (r > 190 && b > 190 && g < 170) { buf[i] = 255; buf[i + 1] = 0; buf[i + 2] = 255; }
      }
      Marshal.Copy(buf, 0, data.Scan0, len);
    } finally { bmp.UnlockBits(data); }
  }
}
'@

# 子类窗体：OnPaint 直接绘制帧 + 拦截 WM_HOTKEY + 双缓冲
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing @'
using System;
using System.Drawing;
using System.Windows.Forms;
public class PetForm : Form {
  public Action HotKeyPressed;
  public Action<Graphics> FramePainter;
  public PetForm() { this.DoubleBuffered = true; }
  protected override void OnPaint(PaintEventArgs e) {
    Action<Graphics> p = FramePainter;
    if (p != null) p(e.Graphics);
    base.OnPaint(e);
  }
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x0312) {
      Action a = HotKeyPressed;
      if (a != null) a();
    }
    base.WndProc(ref m);
  }
}
'@

$script:PetImg = $null
try {
  $script:PetImg = [System.Drawing.Image]::FromFile($script:ImgPath)
  Log-Err ('image loaded: ' + $script:ImgPath)
} catch {
  Log-Err ('image load failed: ' + $_.Exception.Message)
  [System.Windows.Forms.MessageBox]::Show("图片加载失败：$($_.Exception.Message)", 'DS娘桌宠', 'OK', 'Error') | Out-Null
  exit 1
}

$script:NodeExe = 'C:\Program Files\nodejs\node.exe'
if (-not (Test-Path $script:NodeExe)) {
  $script:NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
}

$script:PHRASES = @(
  '唔…需要帮忙吗？(´｡• ᵕ •｡`)'
  '今天也要加油鸭！(๑•̀ㅂ•́)و✧'
  '代码写完啦吗？写完就奖励你摸摸头~'
  '本娘正在全力运转中…ヽ(･ω･｡)ﾉ'
  '喵~ 有什么心事都可以告诉我哦'
  '小心 bug 出没！(っ˘̩╭╮˘̩)っ'
  '抱抱~ 你做得已经很棒啦！'
  'DeepSeek 娘今天也很可爱呢！'
  '喝口奶茶继续战斗吧！(๑´ㅂ`๑)'
  '想听笑话吗？…其实我自己就是个笑话(≧∇≦)ﾉ'
  '认真思考中，请稍候…(｡•̀ᴗ-)✧'
  '你认真的样子真好看！'
  '累了就休息一下下嘛~'
  '叮！灵感 +1 ✨'
)

# ---------- 状态 ----------
$script:scale        = 0.30        # 默认宽约 230px（原图 767px）
$script:minScale     = 0.08
$script:maxScale     = 2.0
$script:phrase       = $null
$script:phraseHideAt = 0
$script:bal          = $null
$script:balVisible   = $false
$script:bobPhase     = 0.0
$script:dragging     = $false
$script:dragStartX   = 0
$script:dragStartY   = 0
$script:dragStartAnchorX = 0
$script:dragStartAnchorY = 0
$script:dragMoved    = $false
$script:anchorX      = 0
$script:anchorY      = 0
$script:canvas       = $null
$script:canvasW      = 0
$script:canvasH      = 0
$script:margin       = 16.0
$script:bubbleH      = 60.0
$script:bobRange     = 6.0
$script:scaledImg    = $null
$script:balPS        = $null
$script:balHandle    = $null
$script:hotkeyOk     = $false
$script:bgQueue      = New-Object System.Collections.Queue
$script:lastEnqueued = $null

$script:Magenta = [System.Drawing.Color]::Magenta

# ---------- 窗体（颜色键控透明 + OnPaint 绘制） ----------
$form = New-Object PetForm
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.TransparencyKey = $script:Magenta
$form.BackColor       = $script:Magenta
$form.KeyPreview      = $true

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$script:anchorX = $wa.Right - 140
$script:anchorY = $wa.Bottom - 24
Log-Err ('form created, screen ' + $wa.Width + 'x' + $wa.Height)

# OnPaint：把当前帧画到窗体上（不再换 BackgroundImage，杜绝闪烁）
$form.FramePainter = [Action[System.Drawing.Graphics]]{
  param($gr)
  try {
    if ($script:canvas) { $gr.DrawImageUnscaled($script:canvas, 0, 0) }
  } catch { Log-Err ('Paint: ' + $_.Exception.Message) }
}

# ---------- 绘图辅助（全部硬边，避免品红混色） ----------
function New-RoundedPath {
  param([double]$x, [double]$y, [double]$w, [double]$h, [double]$r)
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc([float]$x, [float]$y, [float]$d, [float]$d, 180, 90)
  $p.AddArc([float]($x + $w - $d), [float]$y, [float]$d, [float]$d, 270, 90)
  $p.AddArc([float]($x + $w - $d), [float]($y + $h - $d), [float]$d, [float]$d, 0, 90)
  $p.AddArc([float]$x, [float]($y + $h - $d), [float]$d, [float]$d, 90, 90)
  $p.CloseFigure()
  return $p
}

# 测量气泡尺寸：宽度不超过画布，长文本自动换行增高
function Measure-Bubble {
  param($mg, [string]$text, [int]$cw)
  try {
    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
    $wrapW = [Math]::Max(60, [Math]::Min(330, ($cw - 40)))
    $size = $mg.MeasureString($text, $font, $wrapW)
    $bw2 = [int][Math]::Ceiling($size.Width) + 26
    $bhh = [int][Math]::Ceiling($size.Height) + 18
    $bw2 = [Math]::Max(64, [Math]::Min($bw2, ($cw - 8)))
    $font.Dispose()
    return @($bw2, $bhh)
  } catch { Log-Err ('Measure-Bubble: ' + $_.Exception.Message); return @(120, 40) }
}

function Draw-Bubble {
  param($g, [string]$text, [double]$headX, [double]$headY, [bool]$isBal, [int]$cw, [int]$bw2, [int]$bhh)
  try {
    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
    $bx   = $headX - $bw2 / 2.0
    $by   = $headY - 10.0 - $bhh
    $bx   = [Math]::Max(4.0, [Math]::Min(($cw - $bw2 - 4.0), $bx))
    $by   = [Math]::Max(4.0, $by)
    if ($isBal) {
      $bg = [System.Drawing.Color]::FromArgb(255, 255, 246, 230)
      $bd = [System.Drawing.Color]::FromArgb(255, 255, 227, 184)
      $fg = [System.Drawing.Color]::FromArgb(255, 138, 90, 0)
    } else {
      $bg = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
      $bd = [System.Drawing.Color]::FromArgb(255, 205, 217, 245)
      $fg = [System.Drawing.Color]::FromArgb(255, 58, 74, 107)
    }
    $path  = New-RoundedPath $bx $by $bw2 $bhh 12
    $bgBr  = New-Object System.Drawing.SolidBrush($bg)
    $bdPen = New-Object System.Drawing.Pen($bd, 2)
    $g.FillPath($bgBr, $path)
    $g.DrawPath($bdPen, $path)
    $path.Dispose(); $bdPen.Dispose(); $bgBr.Dispose()
    # 尾巴
    $tx = $headX
    $ty = $by + $bhh - 2
    $tail = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tail.AddPolygon(@(
      (New-Object System.Drawing.Point([int]$tx, [int]$ty)),
      (New-Object System.Drawing.Point([int]($tx - 9), [int]($ty + 15))),
      (New-Object System.Drawing.Point([int]($tx + 9), [int]($ty + 15)))
    ))
    $tailBr = New-Object System.Drawing.SolidBrush($bg)
    $g.FillPath($tailBr, $tail)
    $tail.Dispose(); $tailBr.Dispose()
    $fgBr = New-Object System.Drawing.SolidBrush($fg)
    $rect = New-Object System.Drawing.RectangleF([float]($bx + 13), [float]($by + 8), [float]($bw2 - 26), [float]($bhh - 14))
    $g.DrawString($text, $font, $fgBr, $rect)
    $fgBr.Dispose(); $font.Dispose()
  } catch { Log-Err ('Draw-Bubble: ' + $_.Exception.Message) }
}

# ---------- 缩放缓存（alpha 硬边，杜绝品红混边） ----------
function Build-Scaled {
  try {
    if ($script:scaledImg) { $script:scaledImg.Dispose() }
    $w = [Math]::Max(8, [int][Math]::Round($script:PetImg.Width * $script:scale))
    $h = [Math]::Max(8, [int][Math]::Round($script:PetImg.Height * $script:scale))
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($script:PetImg, 0, 0, $w, $h)
    $g.Dispose()
    [PetApi]::HardenAlpha($bmp, 128)
    $script:scaledImg = $bmp
  } catch { Log-Err ('Build-Scaled: ' + $_.Exception.Message) }
}

# ---------- 渲染（每帧新画布；硬边 + SnapMagenta；无旋转；含浮动；气泡自适应） ----------
function Render {
  try {
    if (-not $script:scaledImg) { Build-Scaled }
    $sw = $script:scaledImg.Width
    $sh = $script:scaledImg.Height
    $margin  = $script:margin
    $bob = [Math]::Sin($script:bobPhase) * $script:bobRange
    $cw = [int][Math]::Ceiling($sw + $margin * 2)
    # 当前气泡文字
    $text  = $null
    $isBal = $false
    if ($script:balVisible -and $script:bal) { $text = $script:bal; $isBal = $true }
    elseif ($script:phrase)                   { $text = $script:phrase }
    # 测量气泡（宽不超画布、长文本换行增高）
    $bw2 = 0
    $bhh = 0
    if ($text) {
      $measureBmp = New-Object System.Drawing.Bitmap(8, 8)
      $mg = [System.Drawing.Graphics]::FromImage($measureBmp)
      $dims = Measure-Bubble $mg $text $cw
      $mg.Dispose()
      $measureBmp.Dispose()
      $bw2 = $dims[0]
      $bhh = $dims[1]
    }
    # 头部位置（气泡下方 + 浮动余量），画布高度随气泡自适应
    $headY = $margin + $bhh + $script:bobRange + 10
    $ch = [int][Math]::Ceiling($headY + $sh + $margin + $script:bobRange)
    $bmp = New-Object System.Drawing.Bitmap($cw, $ch)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $g.Clear($script:Magenta)
    $g.DrawImage($script:scaledImg, [float]$margin, [float]($headY + $bob), [float]$sw, [float]$sh)
    $headX = $margin + $sw / 2.0
    if ($text) { Draw-Bubble $g $text $headX ($headY + $bob) $isBal $cw $bw2 $bhh }
    $g.Dispose()
    [PetApi]::SnapMagenta($bmp)
    $script:canvas = $bmp
    $script:canvasW = $cw
    $script:canvasH = $ch
  } catch { Log-Err ('Render: ' + $_.Exception.Message) }
}

# ---------- 定位 + 帧入队（OnPaint 读取当前帧，无需换 BackgroundImage） ----------
function Apply {
  try {
    $cw = $script:canvasW
    $ch = $script:canvasH
    $newX = [int]($script:anchorX - $cw / 2.0)
    $newY = [int]($script:anchorY - ($ch - $script:margin - $script:bobRange))
    $newX = [Math]::Max($wa.Left, [Math]::Min(($wa.Right - $cw), $newX))
    $newY = [Math]::Max($wa.Top, [Math]::Min(($wa.Bottom - $ch), $newY))
    if ($form.Location.X -ne $newX -or $form.Location.Y -ne $newY) {
      $form.Location = New-Object System.Drawing.Point($newX, $newY)
    }
    if ($form.Size.Width -ne $cw -or $form.Size.Height -ne $ch) {
      $form.Size = New-Object System.Drawing.Size($cw, $ch)
    }
    if ($script:canvas -and $script:canvas -ne $script:lastEnqueued) {
      $script:bgQueue.Enqueue($script:canvas)
      $script:lastEnqueued = $script:canvas
      while ($script:bgQueue.Count -gt 2) {
        $old = $script:bgQueue.Dequeue()
        try { $old.Dispose() } catch {}
      }
    }
    $form.Invalidate()
  } catch { Log-Err ('Apply: ' + $_.Exception.Message) }
}

# ---------- 余额 ----------
function Start-BalanceFetch {
  $key = $null
  $credPath = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
  if (Test-Path $credPath) {
    $line = Get-Content -Path $credPath -ErrorAction SilentlyContinue |
      Where-Object { $_ -match '^\s*DEEPSEEK_API_KEY\s*:' } |
      Select-Object -First 1
    if ($line) {
      $key = ($line -split ':', 2)[1].Trim().Trim('"', "'")
    }
  }
  if (-not $key) {
    $script:bal = '😿 未找到 DEEPSEEK_API_KEY'
    return
  }
  if (-not $script:NodeExe) {
    $script:bal = '😿 未找到 node.exe，无法查询余额'
    return
  }
  $script:bal = '💭 正在查询余额…'
  $node = $script:NodeExe
  $script:balPS = [powershell]::Create()
  $null = $script:balPS.AddScript({
    param($k, $nodeExe)
    $env:DSK_BALANCE_KEY = $k
    try {
      $code = "const c=new AbortController();const t=setTimeout(()=>c.abort(),15000);fetch('https://api.deepseek.com/user/balance',{headers:{Authorization:'Bearer '+process.env.DSK_BALANCE_KEY},signal:c.signal}).then(r=>r.json()).then(j=>{clearTimeout(t);console.log(JSON.stringify(j))}).catch(e=>{clearTimeout(t);console.error(e&&e.message||String(e));process.exit(1)})"
      $out = & $nodeExe -e $code 2>&1
      $outText = ($out | Out-String).Trim()
      $json = $null
      try { $json = $outText | ConvertFrom-Json } catch {}
      if ($json -and $json.balance_infos -and @($json.balance_infos).Count -gt 0) {
        $b = @($json.balance_infos)[0]
        return "💰 DeepSeek 余额 $($b.total_balance) $($b.currency)（充值 $($b.topped_up_balance) · 赠送 $($b.granted_balance)）"
      }
      return "😿 余额查询失败：$outText"
    } finally {
      Remove-Item Env:DSK_BALANCE_KEY -ErrorAction SilentlyContinue
    }
  }).AddArgument($key).AddArgument($node)
  $script:balHandle = $script:balPS.BeginInvoke()
}

# ---------- 鼠标 ----------
$form.Add_MouseDown({
  param($s, $e)
  try {
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { return }
    $form.Activate()
    $script:dragging = $true
    $script:dragMoved = $false
    $script:dragStartX = $e.X
    $script:dragStartY = $e.Y
    $script:dragStartAnchorX = $script:anchorX
    $script:dragStartAnchorY = $script:anchorY
    $form.Capture = $true
  } catch { Log-Err ('MouseDown: ' + $_.Exception.Message) }
})

$form.Add_MouseMove({
  param($s, $e)
  try {
    if (-not $script:dragging) { return }
    $dx = $e.X - $script:dragStartX
    $dy = $e.Y - $script:dragStartY
    if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 4) { $script:dragMoved = $true }
    $script:anchorX = $script:dragStartAnchorX + $dx
    $script:anchorY = $script:dragStartAnchorY + $dy
    Apply
  } catch { Log-Err ('MouseMove: ' + $_.Exception.Message) }
})

$form.Add_MouseUp({
  param($s, $e)
  try {
    $btn = $e.Button
    if ($btn -eq [System.Windows.Forms.MouseButtons]::Right) {
      # 右键单击关闭桌宠
      $form.Close()
      return
    }
    if (-not $script:dragging) { return }
    $moved = $script:dragMoved
    $script:dragging = $false
    $form.Capture = $false
    if (-not $moved) {
      $script:phrase = $script:PHRASES | Get-Random
      $script:phraseHideAt = [Environment]::TickCount + 3600
      Render
      Apply
    }
  } catch { Log-Err ('MouseUp: ' + $_.Exception.Message) }
})

$form.Add_MouseWheel({
  param($s, $e)
  try {
    Log-Err ('wheel delta=' + $e.Delta + ' oldScale=' + $script:scale)
    # 标准映射：Delta>0（向前滚/远离自己）→ 放大；Delta<0（向后滚）→ 缩小
    $factor = 1.12
    if ($e.Delta -lt 0) { $factor = 0.89 }
    $script:scale = [Math]::Max($script:minScale, [Math]::Min($script:maxScale, $script:scale * $factor))
    Build-Scaled
    Render
    Apply
  } catch { Log-Err ('MouseWheel: ' + $_.Exception.Message) }
})

$form.Add_MouseDoubleClick({
  param($s, $e)
  try {
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:scale = 0.30
      Build-Scaled
      Render
      Apply
    }
  } catch { Log-Err ('DoubleClick: ' + $_.Exception.Message) }
})

# ---------- 定时器（浮动动画 + 轻量逻辑 + F8 松开检测） ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({
  try {
    $script:bobPhase += 0.13
    if ($script:phrase -and ([Environment]::TickCount -gt $script:phraseHideAt)) {
      $script:phrase = $null
    }
    if ($script:balVisible -and (([PetApi]::GetAsyncKeyState(0x77) -band 0x8000) -eq 0)) {
      $script:balVisible = $false
    }
    if ($script:balHandle) {
      if ($script:balHandle.IsCompleted) {
        try {
          $r = $script:balPS.EndInvoke($script:balHandle)
          $script:bal = $r
        } catch {
          $script:bal = '😿 余额查询出错'
        }
        $script:balPS.Dispose()
        $script:balPS = $null
        $script:balHandle = $null
      }
    }
    Render
    Apply
  } catch { Log-Err ('Timer: ' + $_.Exception.Message) }
})
$timer.Start()

# ---------- 全局 F8 热键 ----------
$form.HotKeyPressed = [System.Action]{
  try {
    if (-not $script:balPS) { Start-BalanceFetch }
    $script:balVisible = $true
    Render
    Apply
  } catch { Log-Err ('HotKey: ' + $_.Exception.Message) }
}
try {
  $null = $form.Handle
  $script:hotkeyOk = [PetApi]::RegisterHotKey($form.Handle, 1, 0x4000, 0x77)
  Log-Err ('RegisterHotKey F8 -> ' + $script:hotkeyOk)
} catch { Log-Err ('RegisterHotKey: ' + $_.Exception.Message) }

# ---------- 启动 ----------
try {
  Build-Scaled
  Log-Err ('scaled: ' + $script:scaledImg.Width + 'x' + $script:scaledImg.Height)
  $script:phrase = '点我说话~ 滚轮缩放，按住 F8 看余额，右键关闭我哦！'
  $script:phraseHideAt = [Environment]::TickCount + 6500
  Render
  Log-Err ('rendered canvas: ' + $script:canvasW + 'x' + $script:canvasH)
  Apply
  Log-Err 'initial Apply done'
  [System.Windows.Forms.Application]::Run($form)
  Log-Err 'Run exited (pet closed)'
} catch { Log-Err ('Startup: ' + $_.Exception.Message) }

# ---------- 清理 ----------
$timer.Stop()
$timer.Dispose()
try { if ($script:hotkeyOk) { [PetApi]::UnregisterHotKey($form.Handle, 1) | Out-Null } } catch {}
if ($script:balPS) { $script:balPS.Dispose() }
if ($script:scaledImg) { $script:scaledImg.Dispose() }
while ($script:bgQueue.Count -gt 0) { $old = $script:bgQueue.Dequeue(); try { $old.Dispose() } catch {} }
if ($script:canvas) { $script:canvas.Dispose() }
if ($script:PetImg) { $script:PetImg.Dispose() }
