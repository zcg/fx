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
Start-Sleep -Milliseconds 900

Send-Key 'CTRL+SHIFT+T'
Start-Sleep -Seconds 4
Send-Clipboard '$env:MAGPIE_API_KEY="magpie"; & "D:\Projects\zigprojects\fx\zig-out\bin\fx.exe"'
Send-Key 'ENTER'
Start-Sleep -Seconds 10

# /model: the menu should open on the current connection's catalog.
Send-Clipboard '/model'
Start-Sleep -Milliseconds 1200
Send-Key 'ENTER'
Start-Sleep -Seconds 5
Save-Shot 'C:\Users\zcg\AppData\Local\Temp\fx_model_all.png'

# Tab: move to the next connection tab.
Send-Key 'TAB'
Start-Sleep -Milliseconds 900
Save-Shot 'C:\Users\zcg\AppData\Local\Temp\fx_model_tab2.png'

Send-Key 'TAB'
Start-Sleep -Milliseconds 900
Save-Shot 'C:\Users\zcg\AppData\Local\Temp\fx_model_tab3.png'

Write-Host "shots written"
