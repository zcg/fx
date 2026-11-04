$ErrorActionPreference = 'Continue'
$pid_ = 26772
$wid = 31525052

$json = @{ pid = $pid_; window_id = $wid; query = "fx" } | ConvertTo-Json -Compress
$state = $json | cua-driver get_window_state 2>&1 | Out-String
$parsed = $state | ConvertFrom-Json
Write-Host "elements: $($parsed.element_count)"
Write-Host $parsed.tree_markdown
