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
function Send-Text([string]$text) {
  Set-Clipboard -Value $text
  [System.Windows.Forms.SendKeys]::SendWait("^v")
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

# /provider magpie -> Enter 切换
Send-Text "/provider magpie"
Start-Sleep -Milliseconds 1200
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 4
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_w1.png"

# /model -> Enter 看模型列表
Send-Text "/model"
Start-Sleep -Milliseconds 800
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 5
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_w2.png"
Write-Host "w1 w2 saved, pid=$($global:fxProc.Id)"
