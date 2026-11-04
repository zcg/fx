$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Save-Shot([string]$path) {
  $b = New-Object System.Drawing.Bitmap([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen(0, 0, 0, 0, $b.Size)
  $g.Dispose()
  $b.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $b.Dispose()
}

# 强制 CapsLock 关闭
$caps = [System.Windows.Forms.Control]::IsKeyLocked([System.Windows.Forms.Keys]::CapsLock)
if ($caps) { [System.Windows.Forms.SendKeys]::SendWait("{CAPSLOCK}") ; Start-Sleep -Milliseconds 200 }

$fx = "D:\Projects\zigprojects\fx\zig-out\bin\fx.exe"
$env:MAGPIE_API_KEY = "magpie"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "conhost.exe"
$psi.Arguments = "`"$fx`""
$psi.WorkingDirectory = "D:\Projects\zigprojects\fx"
$psi.UseShellExecute = $true
$global:fxProc = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 5

# /provider 然后逐键过滤（避免大小写问题：picker 模糊匹配大小写不敏感，用 MAG 也能匹配 magpie）
[System.Windows.Forms.SendKeys]::SendWait("/provider ")
Start-Sleep -Milliseconds 1000
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_x1.png"

# 列表应全部显示。用 DOWN 导航: vercel->codex->grok->openrouter->magpie 需 4 次 DOWN
# 但之前 DOWN 无效。先试 tab provider 提示 -> 实际试 DOWN
[System.Windows.Forms.SendKeys]::SendWait("{DOWN}")
Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait("{DOWN}")
Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait("{DOWN}")
Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait("{DOWN}")
Start-Sleep -Milliseconds 600
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_x2.png"
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 4
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_x3.png"
Write-Host "x1 x2 x3 saved, pid=$($global:fxProc.Id)"
