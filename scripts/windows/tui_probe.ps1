$ErrorActionPreference = "Stop"
# 启动 fx TUI 于独立窗口，注入 /provider，等待，截图
$fx = "D:\Projects\zigprojects\fx\zig-out\bin\fx.exe"
$workdir = "D:\Projects\zigprojects\fx"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "conhost.exe"
$psi.Arguments = "`"$fx`""
$psi.WorkingDirectory = $workdir
$psi.UseShellExecute = $true
$env:MAGPIE_API_KEY = "magpie"
[System.Environment]::SetEnvironmentVariable("MAGPIE_API_KEY", "magpie", "Process")
$p = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 4

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

# 激活窗口并发送 /provider
[System.Windows.Forms.SendKeys]::SendWait("/provider")
Start-Sleep -Milliseconds 800
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 2
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_provider_menu.png"
Write-Host "shot saved"
