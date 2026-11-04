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

# 列表还开着。输入 mag 过滤
[System.Windows.Forms.SendKeys]::SendWait("mag")
Start-Sleep -Milliseconds 800
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_f1.png"
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 3
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_f2.png"
Write-Host "f1 f2 saved"
