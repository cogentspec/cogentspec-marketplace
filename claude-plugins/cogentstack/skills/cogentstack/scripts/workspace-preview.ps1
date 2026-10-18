function New-CogentSpecPreviewResult {
    param(
        [ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,
        [ValidateSet('chatgpt','claude-desktop')][string]$Surface,
        [ValidateSet('legacy','popout','desktop-ui','web','split-screen')][string]$Experience
    )
    $freeWeb = $Experience -ceq 'web'
    $mode = if ($Experience -ceq 'legacy') { 'popout' } else { $Experience }
    $url = if ($freeWeb) { 'https://cogentspec.com/workspace' } else { 'https://cogentspec.app/stack' }
    $url += '?surface=' + [Uri]::EscapeDataString($Surface) + '&context=' + [Uri]::EscapeDataString($ContextKey) + '&experience=' + $mode
    if (-not $freeWeb) { $url += '&preview=1' }
    return [ordered]@{
        status = if ($freeWeb) { 'free_web_available' } else { 'preview' }
        reason = 'licence_required'; licenceState = 'inactive'; preview = (-not $freeWeb)
        canUsePaidWorkspace = $false; connected = $false; currentConversationConnected = $false
        accountState = 'signed_in'; bridge = 'not_started'; browserOpened = $false
        contextKey = $ContextKey; credentialPreserved = $true
        previewUrl = $url; workspaceUrl = $url; webWorkspaceUrl = $url
        userMessage = if ($freeWeb) { 'This account has no active paid licence. The free Web Bridge remains available through your CogentSpec account. No paid connection was activated.' }
            else { 'This account has no active CogentSpec licence. Open the work area in read-only preview to explore its features. Paid project actions remain unavailable; no licensed Bridge connection was activated.' }
    }
}
