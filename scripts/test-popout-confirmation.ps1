$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$helper = Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/start-cogentstack-bridge.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Launcher has parser errors.' }
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Confirm-StandalonePopoutConnection' }, $true)
Invoke-Expression $function.Extent.Text
# All credential, inspection, filesystem and service boundaries are fixtures.
function Read-DesktopBridgeToken { return 'fixture-only' }
function Read-FreshPopoutInspection { param($HelperPath) return $script:cachedInspection }
function Join-Path { param($Path, $ChildPath) return 'fixture-popup-helper.ps1' }
function Test-Path { param($LiteralPath, $PathType) return $true }
function Invoke-CogentSpecNativeCommand { param($FilePath, $ArgumentList, $TimeoutSeconds) return $script:inspection }
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
    $script:submitted = $Body | ConvertFrom-Json
    return @{ confirmed = $script:serverConfirmed }
}
$context = 'ctx-' + ('a' * 64)
$fingerprint = 'b' * 64
$thread = '11111111-1111-4111-8111-111111111111'
$script:submitted = $null
$script:cachedInspection = $null
$script:serverConfirmed = $true
$script:inspection = @{ TimedOut = $true; ExitCode = -1; Output = '' }
$result = Confirm-StandalonePopoutConnection chatgpt $context $thread
if ($result.confirmed -or $result.reason -ne 'popout_inspection_timed_out' -or $script:submitted) { throw 'Timeout must stay unconfirmed without submitting.' }
$script:inspection = @{ TimedOut = $false; ExitCode = 0; Output = (@{ status='ready'; publisherVerified=$true; popupVerified=$true; conversationState='identified'; currentConversationKey=('c' * 64); chatFingerprint=$fingerprint } | ConvertTo-Json -Compress) }
$result = Confirm-StandalonePopoutConnection chatgpt $context $thread
if ($result.confirmed -or $script:submitted) { throw 'A mismatched current chat must not submit confirmation.' }
$script:inspection.Output = (@{ status='ready'; publisherVerified=$true; popupVerified=$true; conversationState='identified'; currentConversationKey=$fingerprint; chatFingerprint=$fingerprint; popupVisible=$false } | ConvertTo-Json -Compress)
$result = Confirm-StandalonePopoutConnection chatgpt $context $thread
if (-not $result.confirmed -or $script:submitted.contextKey -ne $context -or $script:submitted.threadId -ne $thread -or $script:submitted.chatFingerprint -ne $fingerprint) { throw 'Exact identified hidden chat must submit only its verified binding.' }
$script:serverConfirmed = $false
$result = Confirm-StandalonePopoutConnection chatgpt $context $thread
if ($result.confirmed -or $result.reason -ne 'server_rejected_confirmation') { throw 'Server rejection must remain unconfirmed.' }
$script:serverConfirmed = $true
$script:cachedInspection = $script:inspection.Output | ConvertFrom-Json
$script:inspection = @{ TimedOut=$true; ExitCode=-1; Output='' }
$result = Confirm-StandalonePopoutConnection chatgpt $context $thread
if (-not $result.confirmed) { throw 'Fresh verified watcher observation must avoid a duplicate cold inspection, but still require server confirmation.' }
'PASS: timeout/mismatch never submit; hidden exact chat confirms; server rejection stays disconnected.'
