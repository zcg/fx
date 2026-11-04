$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$pid_ = 26772
$wid = 31525052

function Send-Key([string]$key) {
  $json = @{ pid = $pid_; window_id = $wid; key = $key; delivery_mode = 'foreground' } | ConvertTo-Json -Compress
  $json | cua-driver press_key 2>&1 | Out-Null
  Start-Sleep -Milliseconds 350
}
function Send-Clipboard([string]$text) {
  Set-Clipboard -Value $text
  Start-Sleep -Milliseconds 250
  Send-Key 'CTRL+V'
  Start-Sleep -Milliseconds 400
}
function Save-Shot([string]$path) {
  $b = New-Object System.Drawing.Bitmap([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen(0, 0, 0, 0, $b.Size)
  $g.Dispose()
  $b.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $b.Dispose()
}

$focus = @{ pid = $pid_; window_id = $wid } | ConvertTo-Json -Compress
$focus | cua-driver bring_to_front 2>&1 | Out-Null
Start-Sleep -Milliseconds 600

# Clear the composer and the open picker.
Send-Key 'ESC'
Start-Sleep -Milliseconds 400
Send-Key 'ESC'
Start-Sleep -Milliseconds 400
Send-Key 'CTRL+U'
Start-Sleep -Milliseconds 400
Send-Key 'CTRL+A'
Start-Sleep -Milliseconds 200
Send-Key 'BACKSPACE'
Start-Sleep -Milliseconds 400
Save-Shot 'C:\Users\zcg\AppData\Local\Temp\fx_c1.png'

# Type the whole command with its filter at once, so the picker opens already
# narrowed to magpie and Enter picks it.
Send-Clipboard '/provider magpie'
Start-Sleep -Milliseconds 900
Save-Shot 'C:\Users\zcg\AppData\Local\Temp\fx_c2.png'
Send-Key 'ENTER'
Start-Sleep -Seconds 9
Save-Shot 'C:\Users\zcg\AppData\Local\Temp\fx_c3.png'
Write-Host 'switch attempted'
