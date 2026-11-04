$ErrorActionPreference = 'Continue'
$pid_ = 26772
$wid = 31525052
$json = @{ pid = $pid_; window_id = $wid } | ConvertTo-Json -Compress

Write-Host "=== bring_to_front ==="
$json | cua-driver bring_to_front 2>&1 | Select-Object -First 6

Start-Sleep -Seconds 2

Write-Host "=== state ==="
$state = $json | cua-driver get_window_state 2>&1 | Out-String
$parsed = $state | ConvertFrom-Json
Write-Host "bounds: $($parsed.window_bounds | ConvertTo-Json -Compress)"
Write-Host "screenshot_error: $($parsed.screenshot_error)"
Write-Host "elements: $($parsed.element_count)"
