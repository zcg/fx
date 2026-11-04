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

# 等切换彻底完成（同步拉取需要几秒），然后 /model
Start-Sleep -Seconds 6
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_z1.png"
[System.Windows.Forms.SendKeys]::SendWait("/model")
Start-Sleep -Milliseconds 900
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 5
Save-Shot "C:\Users\zcg\AppData\Local\Temp\fx_z2.png"
Write-Host "z1 z2 saved"
