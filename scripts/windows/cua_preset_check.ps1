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
Start-Sleep -Milliseconds 300
Send-Key 'CTRL+A'
Start-Sleep -Milliseconds 200
Send-Key 'BACKSPACE'
Start-Sleep -Milliseconds 500

# Filter for a preset that the profile has not added: anthropic.
Send-Clipboard '/provider anthropic'
Start-Sleep -Milliseconds 1200
Save-Shot 'C:\Users\zcg\AppData\Local\Temp\fx_preset_anthropic.png'
Write-Host 'filtered'
