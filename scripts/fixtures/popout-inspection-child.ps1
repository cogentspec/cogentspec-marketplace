param($Mode,$TimingSink,$PreferredWindowHandle,[scriptblock]$WindowVerified)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# A real .ps1 invocation supplies the production scope boundary. Deliberately
# do not initialize any watcher $script: variables in this helper's scope.
# Keep the former callback argument so reintroducing it reproduces the failure.
if ($WindowVerified -and $inspectionFixture.popupVerified) {
    & $WindowVerified $inspectionFixture.popupWindowHandle $inspectionFixture.popupProcessId
}
if ($throwInspection) { throw 'Accessibility temporarily unavailable' }
$inspectionFixture | ConvertTo-Json -Compress
