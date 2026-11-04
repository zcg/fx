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

$fx = "D:\Projects\zigprojects\fx\zig-out\bin\fx.exe"
$env:MAGPIE_API_KEY = "magpie"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "conhost.exe"
$psi.Arguments = "`"$fx`""
$psi.WorkingDirectory = "D:\Projects\zigprojects\fx"
$psi.UseShellExecute = $true
$global:fxProc = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 5

# /provider -> Enter (补全) -> Enter (进入列表)
[System.Windows.Forms.SendKeys]::SendWait("/provider")
Start-Sleep -Milliseconds 700
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Milliseconds 700
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Milliseconds 1500
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_s1.png"

# 过滤 mag 回车切换
[System.Windows.Forms.SendKeys]::SendWait("mag")
Start-Sleep -Milliseconds 700
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 3
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_s2.png"

# /model 回车
[System.Windows.Forms.SendKeys]::SendWait("/model")
Start-Sleep -Milliseconds 700
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 4
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_s3.png"
Write-Host "s1 s2 s3 saved, pid=$($global:fxProc.Id)"
