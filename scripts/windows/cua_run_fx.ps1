$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$pid_ = 26772
$wid = 31525052

function Send-Key([string]$key) {
  $json = @{ pid = $pid_; window_id = $wid; key = $key; delivery_mode = 'foreground' } | ConvertTo-Json -Compress
  $json | cua-driver press_key 2>&1 | Out-Null
  Start-Sleep -Milliseconds 400
}
function Send-Clipboard([string]$text) {
  # Clipboard paste, because the driver's per-character typing drops the "e"
  # key: "Projects" arrives as "Projcts" and "fx.exe" as "fx.x".
  Set-Clipboard -Value $text
  Start-Sleep -Milliseconds 300
  Send-Key 'CTRL+V'
  Start-Sleep -Milliseconds 500
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
Start-Sleep -Milliseconds 1000

Send-Key 'CTRL+SHIFT+T'
Start-Sleep -Seconds 4

Send-Clipboard 'Set-Location D:\Projects\zigprojects\fx'
Send-Key 'ENTER'
Start-Sleep -Milliseconds 900

Send-Clipboard '$env:MAGPIE_API_KEY="magpie"; & "D:\Projects\zigprojects\fx\zig-out\bin\fx.exe"'
Send-Key 'ENTER'
Start-Sleep -Seconds 10

Save-Shot 'C:\Users\zcg\AppData\Local\Temp\fx_run3.png'
Write-Host 'started'
