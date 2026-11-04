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
$env:FX_DEBUG_TRACE = "1"
$env:FX_DEBUG_TRACE_FILE = "C:\Users\zcg\AppData\Local\Temp\fx_trace.log"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "conhost.exe"
$psi.Arguments = "`"$fx`""
$psi.WorkingDirectory = "D:\Projects\zigprojects\fx"
$psi.UseShellExecute = $true
$psi.EnvironmentVariables["MAGPIE_API_KEY"] = "magpie"
$psi.EnvironmentVariables["FX_DEBUG_TRACE"] = "1"
$global:fxProc = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 5

# /provider + 两次 Enter 进列表，过滤 mag，回车切换
[System.Windows.Forms.SendKeys]::SendWait("/provider")
Start-Sleep -Milliseconds 700
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Milliseconds 700
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Milliseconds 1200
[System.Windows.Forms.SendKeys]::SendWait("mag")
Start-Sleep -Milliseconds 800
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 8
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_trace1.png"
Write-Host "saved, pid=$($global:fxProc.Id)"
