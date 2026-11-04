$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$pid_ = 26772
$wid = 31525052

function Send-Text([string]$text) {
  $json = @{ pid = $pid_; window_id = $wid; text = $text; delivery_mode = 'foreground' } | ConvertTo-Json -Compress
  $json | cua-driver type_text 2>&1 | Out-String | Write-Host
}
function Send-Key([string]$key) {
  $json = @{ pid = $pid_; window_id = $wid; key = $key; delivery_mode = 'foreground' } | ConvertTo-Json -Compress
  $json | cua-driver press_key 2>&1 | Out-String | Write-Host
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
Start-Sleep -Milliseconds 800

Send-Text 'cd D:\Projects\zigprojects\fx; $env:MAGPIE_API_KEY="magpie"; .\zig-out\bin\fx.exe'
Start-Sleep -Milliseconds 600
Send-Key 'ENTER'
Start-Sleep -Seconds 7
Save-Shot 'C:\Users\zcg\AppData\Local\Temp\fx_cua1.png'
Write-Host 'shot saved'
