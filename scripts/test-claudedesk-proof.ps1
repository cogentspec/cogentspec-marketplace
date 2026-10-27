[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('claudedesk-proof-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixture)
$count = 0
try {
    foreach ($plugin in @('cogentspec', 'cogentstack')) {
        $path = Join-Path $root "claude-plugins\$plugin\skills\claudedesk\scripts\start-claudedesk-bridge.ps1"
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Test-BridgePresenceReady','Confirm-CurrentConversationConnection') }, $false)) {
            Invoke-Expression $function.Extent.Text
        }
        $ContextKey = 'ctx-' + ('a' * 64)
        $SessionId = '11111111-2222-4333-8444-555555555555'
        $ready = Join-Path $fixture 'ready.json'
        foreach ($patch in @(@{}, @{processId=2}, @{contextKey='ctx-'+('b'*64)}, @{pluginId='other'}, @{pluginVersion='0.0.1'}, @{threadId='99999999-2222-4333-8444-555555555555'}, @{serverAcknowledged=$false}, @{acknowledgedAt=[DateTime]::UtcNow.AddSeconds(-20).ToString('o')}, @{acknowledgedAt=[DateTime]::UtcNow.AddSeconds(20).ToString('o')})) {
            $marker = @{processId=123;contextKey=$ContextKey;pluginId=$plugin;pluginVersion='0.4.80';threadId=$SessionId;serverAcknowledged=$true;acknowledgedAt=[DateTime]::UtcNow.ToString('o')}
            foreach ($key in $patch.Keys) { $marker[$key] = $patch[$key] }
            $marker | ConvertTo-Json -Compress | Set-Content -LiteralPath $ready -Encoding UTF8
            $actual = Test-BridgePresenceReady $ready 123 $ContextKey $plugin '0.4.80' $SessionId
            if ($actual -ne ($patch.Count -eq 0)) { throw "Readiness proof accepted a foreign or stale marker for $plugin" }
            $count++
        }
        foreach ($patch in @(@{}, @{SurfaceName='chatgpt'}, @{ExperienceName='split-screen'}, @{ConnectedContextKey='ctx-'+('b'*64)}, @{ConnectedThreadId='99999999-2222-4333-8444-555555555555'}, @{PresenceVerified=$false}, @{ContextIsolated=$false})) {
            $values = @{SurfaceName='claude-desktop';ExperienceName='desktop-ui';ConnectedContextKey=$ContextKey;ConnectedThreadId=$SessionId;PresenceVerified=$true;ContextIsolated=$true}
            foreach ($key in $patch.Keys) { $values[$key] = $patch[$key] }
            $actual = Confirm-CurrentConversationConnection @values
            if ($actual.confirmed -ne ($patch.Count -eq 0)) { throw "ClaudeDesk accepted another destination/session proof for $plugin" }
            $count++
        }
    }
    @{passed=$count;failed=0} | ConvertTo-Json -Compress
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'claudedesk-proof-*') { throw 'Unsafe proof fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
