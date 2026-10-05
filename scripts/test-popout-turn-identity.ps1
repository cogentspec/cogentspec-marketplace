$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/open-chatgpt-popup.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Popout helper has parser errors.' }
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ChatGptUserTurnRuntimeId' }, $true)
Invoke-Expression $function.Extent.Text
$noticeFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ChatGptMissingClientNotice' }, $true)
Invoke-Expression $noticeFunction.Extent.Text
if (-not (Test-ChatGptMissingClientNotice @('Error submitting message', 'no-client-found'))) { throw 'Missing-client notice was missed.' }
if (Test-ChatGptMissingClientNotice @('You said:', 'Why no-client-found?', 'ChatGPT said:', 'A no-client-found error can occur.')) { throw 'Transcript prose must not be a host error.' }
if (Test-ChatGptMissingClientNotice @('Error submitting message', 'network-error')) { throw 'Unrelated error must not trigger saved-client recovery.' }

class FixtureElement {
    [object]$Current
    [FixtureElement]$Parent
    [int[]]$RuntimeId
    FixtureElement([string]$ClassName, [int]$Id, [FixtureElement]$Parent) {
        $this.Current = [pscustomobject]@{ ClassName = $ClassName }
        $this.RuntimeId = @(42, $Id)
        $this.Parent = $Parent
    }
    [int[]] GetRuntimeId() { return $this.RuntimeId }
}
class FixtureWalker {
    [FixtureElement] GetParent([FixtureElement]$Element) { return $Element.Parent }
}
$walker = [FixtureWalker]::new()
$turn = [FixtureElement]::new('relative shrink-0', 100, $null)
$bubble = [FixtureElement]::new('bg-user-message text-user-message', 101, $turn)
$streamingText = [FixtureElement]::new('', 102, $bubble)
$before = Get-ChatGptUserTurnRuntimeId $streamingText $walker
for ($generation = 1; $generation -le 60; $generation++) {
    # Simulate text AND bubble replacements over a minute of rendering.
    $replacementBubble = [FixtureElement]::new('bg-user-message text-user-message', (200 + $generation), $turn)
    $replacementText = [FixtureElement]::new('', (300 + $generation), $replacementBubble)
    $after = Get-ChatGptUserTurnRuntimeId $replacementText $walker
    if ($before -ne $after) { throw 'Rendering changed the verified turn identity.' }
}
$otherTurn = [FixtureElement]::new('relative shrink-0', 500, $null)
$otherBubble = [FixtureElement]::new('bg-user-message', 501, $otherTurn)
if ((Get-ChatGptUserTurnRuntimeId $otherBubble $walker) -eq $before) { throw 'Different chat turn inherited identity.' }
$unknown = [FixtureElement]::new('unrecognized-layout', 600, $null)
if (Get-ChatGptUserTurnRuntimeId $unknown $walker) { throw 'Unknown layout must fail closed.' }
if (-not $before) { throw 'Known user turn was not resolved.' }
'PASS: stable through 60 text/bubble rebuilds; different turn distinct; unknown layout unverified.'
