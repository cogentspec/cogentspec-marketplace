$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot 'popout-window-normalizer.ps1'
. $scriptPath

function Assert-NormalizerTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$outer = [pscustomobject]@{ Left = 40; Top = 333; Right = 961; Bottom = 944 }
$frame = [pscustomobject]@{ Left = 50; Top = 333; Right = 951; Bottom = 934 }
$work = [pscustomobject]@{ Left = 0; Top = 0; Right = 1920; Bottom = 1020 }
$request = Get-NormalizedOuterRequest -Outer $outer -Frame $frame -WorkArea $work -TargetWidth 900 -TargetHeight 600
Assert-NormalizerTest ($request.x -eq 40) 'The left frame inset was not preserved.'
Assert-NormalizerTest ($request.y -eq 333) 'The top frame position changed unexpectedly.'
Assert-NormalizerTest ($request.width -eq 920) 'The outer width does not preserve both frame insets.'
Assert-NormalizerTest ($request.height -eq 610) 'The outer height does not preserve the bottom frame inset.'

$offscreenOuter = [pscustomobject]@{ Left = -6; Top = 563; Right = 699; Bottom = 1000 }
$offscreenFrame = [pscustomobject]@{ Left = -6; Top = 563; Right = 699; Bottom = 1000 }
$clamped = Get-NormalizedOuterRequest -Outer $offscreenOuter -Frame $offscreenFrame -WorkArea $work -TargetWidth 900 -TargetHeight 600
Assert-NormalizerTest ($clamped.x -eq 0) 'The normalized window was not clamped to the work-area left edge.'
Assert-NormalizerTest ($clamped.y -eq 420) 'The normalized window was not clamped to the work-area bottom edge.'
Assert-NormalizerTest ($clamped.width -eq 900 -and $clamped.height -eq 600) 'A frameless window did not keep the requested size.'

$source = Get-Content -Raw -LiteralPath $scriptPath
$sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $scriptPath).Hash
$packagedCopies = @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\cogentspec\skills\cogentspec\scripts\popout-window-normalizer.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\cogentstack\skills\cogentstack\scripts\popout-window-normalizer.ps1')
)
foreach ($packagedCopy in $packagedCopies) {
    Assert-NormalizerTest (Test-Path -LiteralPath $packagedCopy) "Missing packaged normalizer: $packagedCopy"
    $copyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedCopy).Hash
    Assert-NormalizerTest ($copyHash -eq $sourceHash) "Packaged normalizer differs from the tested source: $packagedCopy"
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($packagedCopy, [ref]$tokens, [ref]$errors)
    Assert-NormalizerTest ($errors.Count -eq 0) "Packaged normalizer has a PowerShell parse error: $packagedCopy"
}
foreach ($marker in @(
    'SWP_NOACTIVATE',
    'NOZORDER',
    'NOOWNERZORDER',
    'verified_retained_popout',
    'single_signed_claude_window_candidate',
    'clamped_by_application',
    'OpenAI(?: OpCo)?',
    'Anthropic,? PBC',
    'Restore-NormalizerWindows'
)) {
    Assert-NormalizerTest ($source.Contains($marker)) "Missing normalizer safeguard: $marker"
}
foreach ($forbidden in @('SetForegroundWindow', 'SendInput', 'keybd_event', 'mouse_event', 'SetWindowLong')) {
    Assert-NormalizerTest (-not $source.Contains($forbidden)) "The normalizer must not use $forbidden."
}

[ordered]@{
    status = 'valid'
    fixtureTests = 2
    safetyMarkers = 9
    forbiddenInputApis = 5
    packagedCopies = $packagedCopies.Count
} | ConvertTo-Json -Depth 4
