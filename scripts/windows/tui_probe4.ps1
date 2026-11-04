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
[System.Environment]::SetEnvironmentVariable("MAGPIE_API_KEY", "magpie", "Process")
$env:MAGPIE_API_KEY = "magpie"

# 启动 TUI（独立 conhost 窗口）
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "conhost.exe"
$psi.Arguments = "`"$fx`""
$psi.WorkingDirectory = "D:\Projects\zigprojects\fx"
$psi.UseShellExecute = $true
$global:fxProc = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 5

# /provider 然后回车进入命令
[System.Windows.Forms.SendKeys]::SendWait("/provider")
Start-Sleep -Milliseconds 600
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 3
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_p1.png"

# 若还在补全上，再回车进入
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 3
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_p2.png"
Write-Host "probes saved, fx pid=$($global:fxProc.Id)"
