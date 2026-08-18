#Requires -Version 5.1
# ============================================================
# DS娘桌宠 v2 · 原生桌面宠物 (DS Maid Desktop Pet)
# ------------------------------------------------------------
# 双击「启动桌宠.bat」运行。
# 操作：
#   左键拖动   -> 移动位置
#   右键拖动   -> 旋转（绕脚底中心）
#   滚轮       -> 放大 / 缩小
#   单击(左键) -> 随机说一句可爱的话
#   双击       -> 恢复初始大小与角度
#   按住 F8    -> 显示 DeepSeek 余额（先点击桌宠获得焦点）
#   右下角「-」 -> 最小化（只剩 + 和 -）
#   最小化时「+」-> 恢复显示；「-」-> 退出桌宠
# v2 修复：更小默认尺寸、流畅渲染（复用画布+Invalidate）、
#          单实例保护、异常隔离防崩溃、图片去光晕。
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AppDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ImgPath = Join-Path $script:AppDir 'ds-cutout.png'
$script:ErrLog  = Join-Path $script:AppDir '.pet-errors.log'

# ---- 单实例保护 ----
$script:Mutex = New-Object System.Threading.Mutex($false, 'DSMaidPetMutex')
if (-not $script:Mutex.WaitOne(0)) { exit 0 }

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
} catch {}

function Log-Err {
  param($m)
  try { Add-Content -Path $script:ErrLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) } catch {}
}

$script:PetImg = $null
try {
  $script:PetImg = [System.Drawing.Image]::FromFile($script:ImgPath)
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
$script:rot          = 0.0
$script:scale        = 0.30        # 默认宽约 230px（原图 767px）
$script:minScale     = 0.08
$script:maxScale     = 2.0
$script:minimized    = $false
$script:phrase       = $null
$script:phraseHideAt = 0
$script:bal          = $null
$script:balVisible   = $false
$script:bobPhase     = 0.0
$script:dragging     = $false
$script:dragMode     = 'none'
$script:dragStartX   = 0
$script:dragStartY   = 0
$script:dragStartAnchorX = 0
$script:dragStartAnchorY = 0
$script:dragStartRot = 0.0
$script:dragMoved    = $false
$script:anchorX      = 0
$script:anchorY      = 0
$script:canvas       = $null
$script:canvasW      = 0
$script:canvasH      = 0
$script:margin       = 20.0
$script:bubbleH      = 58.0
$script:plusRect     = $null
$script:minusRect    = $null
$script:scaledImg    = $null
$script:balPS        = $null
$script:balHandle    = $null

$script:Magenta = [System.Drawing.Color]::Magenta

# ---------- 窗体 ----------
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.TransparencyKey = $script:Magenta
$form.BackColor       = $script:Magenta
$form.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::None
$form.KeyPreview      = $true

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$script:anchorX = $wa.Right - 140
$script:anchorY = $wa.Bottom - 24

# ---------- 绘图辅助 ----------
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

function Draw-CircleButton {
  param($g, [System.Drawing.Rectangle]$rect, [string]$glyph, [System.Drawing.Color]$fill)
  try {
    $brush = New-Object System.Drawing.SolidBrush($fill)
    $pen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 160, 180, 220), 2)
    $g.FillEllipse($brush, $rect)
    $g.DrawEllipse($pen, $rect)
    $font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $tb   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 70, 90, 140))
    $sf   = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString($glyph, $font, $tb, [System.Drawing.RectangleF]$rect, $sf)
    $sf.Dispose(); $tb.Dispose(); $font.Dispose(); $pen.Dispose(); $brush.Dispose()
  } catch { Log-Err ('Draw-CircleButton: ' + $_.Exception.Message) }
}

function Draw-Bubble {
  param($g, [string]$text, [double]$headX, [double]$headY, [bool]$isBal, [int]$cw)
  try {
    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
    $size = $g.MeasureString($text, $font, 330)
    $bw2  = [int][Math]::Ceiling($size.Width) + 26
    $bhh  = [int][Math]::Ceiling($size.Height) + 14
    $bw2  = [Math]::Max(64, [Math]::Min(360, $bw2))
    $bx   = $headX - $bw2 / 2.0
    $by   = $headY - 16.0 - $bhh
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
    $rect = New-Object System.Drawing.RectangleF([float]($bx + 13), [float]($by + 7), [float]($bw2 - 26), [float]($bhh - 12))
    $g.DrawString($text, $font, $fgBr, $rect)
    $fgBr.Dispose(); $font.Dispose()
  } catch { Log-Err ('Draw-Bubble: ' + $_.Exception.Message) }
}

# ---------- 缩放缓存 ----------
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
    $script:scaledImg = $bmp
  } catch { Log-Err ('Build-Scaled: ' + $_.Exception.Message) }
}

# ---------- 画布复用 ----------
function EnsureCanvas {
  param([int]$cw, [int]$ch)
  if ($script:canvas -and $script:canvasW -eq $cw -and $script:canvasH -eq $ch) { return }
  $old = $script:canvas
  $script:canvas = New-Object System.Drawing.Bitmap($cw, $ch)
  $script:canvasW = $cw
  $script:canvasH = $ch
  if ($form.BackgroundImage -eq $old) {
    $form.BackgroundImage = $script:canvas
    if ($old) { $old.Dispose() }
  } elseif ($old) {
    $old.Dispose()
  }
}

# ---------- 渲染 ----------
function Render {
  try {
    if (-not $script:scaledImg) { Build-Scaled }
    if ($script:minimized) {
      $cw = 118; $ch = 50
      EnsureCanvas $cw $ch
      $g = [System.Drawing.Graphics]::FromImage($script:canvas)
      $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $g.Clear($script:Magenta)
      $script:plusRect  = New-Object System.Drawing.Rectangle(34, 10, 32, 32)
      $script:minusRect = New-Object System.Drawing.Rectangle(80, 10, 32, 32)
      Draw-CircleButton $g $script:plusRect  '+' ([System.Drawing.Color]::FromArgb(255, 224, 234, 255))
      Draw-CircleButton $g $script:minusRect '-' ([System.Drawing.Color]::FromArgb(255, 255, 228, 228))
      $g.Dispose()
    } else {
      $sw = $script:scaledImg.Width
      $sh = $script:scaledImg.Height
      $rad = $script:rot * [Math]::PI / 180.0
      $cosr = [Math]::Cos($rad)
      $sinr = [Math]::Sin($rad)
      # 旋转后包围盒（绕脚底中心 origin）
      $c1x = -$sw / 2.0 * $cosr
      $c1y = -$sw / 2.0 * $sinr
      $c2x =  $sw / 2.0 * $cosr
      $c2y =  $sw / 2.0 * $sinr
      $c3x = -$sw / 2.0 * $cosr + $sh * $sinr
      $c3y = -$sw / 2.0 * $sinr - $sh * $cosr
      $c4x =  $sw / 2.0 * $cosr + $sh * $sinr
      $c4y =  $sw / 2.0 * $sinr - $sh * $cosr
      $minX = [Math]::Min([Math]::Min($c1x, $c2x), [Math]::Min($c3x, $c4x))
      $maxX = [Math]::Max([Math]::Max($c1x, $c2x), [Math]::Max($c3x, $c4x))
      $minY = [Math]::Min([Math]::Min($c1y, $c2y), [Math]::Min($c3y, $c4y))
      $maxY = [Math]::Max([Math]::Max($c1y, $c2y), [Math]::Max($c3y, $c4y))
      $margin  = $script:margin
      $bubbleH = $script:bubbleH
      $cw = [int][Math]::Ceiling(($maxX - $minX) + $margin * 2)
      $ch = [int][Math]::Ceiling(($maxY - $minY) + $margin * 2 + $bubbleH)
      $cx = $margin - $minX
      $cy = $margin + $bubbleH - $minY
      EnsureCanvas $cw $ch
      $g = [System.Drawing.Graphics]::FromImage($script:canvas)
      $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $g.Clear($script:Magenta)
      $bob = 0.0
      $g.TranslateTransform([float]$cx, [float]($cy + $bob))
      $g.RotateTransform([float]$script:rot)
      $g.DrawImage($script:scaledImg, [float](-$sw / 2.0), [float](-$sh), [float]$sw, [float]$sh)
      $g.ResetTransform()
      # 头部位置
      $headX = $cx + $sh * $sinr
      $headY = ($cy + $bob) - $sh * $cosr
      # 气泡
      $text  = $null
      $isBal = $false
      if ($script:balVisible -and $script:bal) { $text = $script:bal; $isBal = $true }
      elseif ($script:phrase)                   { $text = $script:phrase }
      if ($text) { Draw-Bubble $g $text $headX $headY $isBal $cw }
      # 右下角「-」按钮
      $script:plusRect = $null
      $br = 14
      $bxc = $cw - 22
      $byc = $ch - 22
      $mRect = New-Object System.Drawing.Rectangle(($bxc - $br), ($byc - $br), ($br * 2), ($br * 2))
      Draw-CircleButton $g $mRect '-' ([System.Drawing.Color]::FromArgb(255, 255, 228, 228))
      $script:minusRect = $mRect
      $g.Dispose()
    }
  } catch { Log-Err ('Render: ' + $_.Exception.Message) }
}

# ---------- 定位 + 重绘 ----------
function Apply {
  try {
    $cw = $script:canvasW
    $ch = $script:canvasH
    $newX = [int]($script:anchorX - $cw / 2.0)
    if ($script:minimized) {
      $newY = [int]($script:anchorY - $ch)
    } else {
      $newY = [int]($script:anchorY - ($ch - $script:margin))
    }
    # 保持在屏幕内
    $newX = [Math]::Max($wa.Left, [Math]::Min(($wa.Right - $cw), $newX))
    $newY = [Math]::Max($wa.Top, [Math]::Min(($wa.Bottom - $ch), $newY))
    if ($form.Location.X -ne $newX -or $form.Location.Y -ne $newY) {
      $form.Location = New-Object System.Drawing.Point($newX, $newY)
    }
    if ($form.Size.Width -ne $cw -or $form.Size.Height -ne $ch) {
      $form.Size = New-Object System.Drawing.Size($cw, $ch)
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
  try {
    $p = New-Object System.Drawing.Point($e.X, $e.Y)
    if ($script:minusRect -and $script:minusRect.Contains($p)) {
      if ($script:minimized) {
        $form.Close()
      } else {
        $script:minimized = $true
        Render
        Apply
      }
      return
    }
    if ($script:plusRect -and $script:plusRect.Contains($p)) {
      $script:minimized = $false
      Render
      Apply
      return
    }
    $script:dragging = $true
    $script:dragMoved = $false
    $script:dragStartX = $e.X
    $script:dragStartY = $e.Y
    $script:dragStartAnchorX = $script:anchorX
    $script:dragStartAnchorY = $script:anchorY
    $script:dragStartRot = $script:rot
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
      $script:dragMode = 'rotate'
    } else {
      $script:dragMode = 'move'
    }
    $form.Capture = $true
  } catch { Log-Err ('MouseDown: ' + $_.Exception.Message) }
})

$form.Add_MouseMove({
  try {
    if (-not $script:dragging) { return }
    $dx = $e.X - $script:dragStartX
    $dy = $e.Y - $script:dragStartY
    if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 4) { $script:dragMoved = $true }
    if ($script:dragMode -eq 'move') {
      $script:anchorX = $script:dragStartAnchorX + $dx
      $script:anchorY = $script:dragStartAnchorY + $dy
      Apply
    } else {
      $ox = $script:canvasW / 2.0
      $oy = $script:canvasH - $script:margin
      $a0 = [Math]::Atan2($script:dragStartY - $oy, $script:dragStartX - $ox)
      $a1 = [Math]::Atan2($e.Y - $oy, $e.X - $ox)
      $script:rot = $script:dragStartRot + ($a1 - $a0) * 180.0 / [Math]::PI
      Render
      Apply
    }
  } catch { Log-Err ('MouseMove: ' + $_.Exception.Message) }
})

$form.Add_MouseUp({
  try {
    if (-not $script:dragging) { return }
    $moved = $script:dragMoved
    $mode  = $script:dragMode
    $btn   = $e.Button
    $script:dragging = $false
    $form.Capture = $false
    if ($mode -eq 'move' -and -not $moved -and $btn -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:phrase = $script:PHRASES | Get-Random
      $script:phraseHideAt = [Environment]::TickCount + 3600
      Render
      Apply
    }
  } catch { Log-Err ('MouseUp: ' + $_.Exception.Message) }
})

$form.Add_MouseWheel({
  try {
    $factor = 1.12
    if ($e.Delta -lt 0) { $factor = 0.89 }
    $script:scale = [Math]::Max($script:minScale, [Math]::Min($script:maxScale, $script:scale * $factor))
    Build-Scaled
    Render
    Apply
  } catch { Log-Err ('MouseWheel: ' + $_.Exception.Message) }
})

$form.Add_MouseDoubleClick({
  try {
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and -not $script:minimized) {
      $script:rot = 0.0
      $script:scale = 0.30
      Build-Scaled
      Render
      Apply
    }
  } catch { Log-Err ('DoubleClick: ' + $_.Exception.Message) }
})

$form.Add_KeyDown({
  try {
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F8 -and -not $e.Repeat) {
      $script:balVisible = $true
      if (-not $script:balPS) { Start-BalanceFetch }
      Render
      Apply
    }
  } catch { Log-Err ('KeyDown: ' + $_.Exception.Message) }
})

$form.Add_KeyUp({
  try {
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F8) {
      $script:balVisible = $false
      Render
      Apply
    }
  } catch { Log-Err ('KeyUp: ' + $_.Exception.Message) }
})

# ---------- 定时器（只做轻量逻辑，不重绘；仅在状态变化时重绘） ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
  try {
    $changed = $false
    $now = [Environment]::TickCount
    if ($script:phrase -and $now -gt $script:phraseHideAt) {
      $script:phrase = $null
      $changed = $true
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
        $changed = $true
      }
    }
    if ($changed) {
      Render
      Apply
    }
  } catch { Log-Err ('Timer: ' + $_.Exception.Message) }
})
$timer.Start()

# ---------- 启动 ----------
Build-Scaled
Render
$form.BackgroundImage = $script:canvas
Apply
$script:phrase = '点我说话~ 右键转圈圈，滚轮缩放，按住 F8 看余额哦！'
$script:phraseHideAt = [Environment]::TickCount + 6500
$form.Activate()
[System.Windows.Forms.Application]::Run($form)

# ---------- 清理 ----------
$timer.Stop()
$timer.Dispose()
if ($script:balPS) { $script:balPS.Dispose() }
if ($script:scaledImg) { $script:scaledImg.Dispose() }
if ($script:canvas) { $script:canvas.Dispose() }
if ($script:PetImg) { $script:PetImg.Dispose() }
if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch {} }
