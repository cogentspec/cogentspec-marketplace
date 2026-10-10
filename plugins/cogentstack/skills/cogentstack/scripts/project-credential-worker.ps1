function Invoke-InitialCredentialSetup([string]$Token) {
    # This result must never be sent to Write-Output, transcripts or AI-facing helper output.
    $claimed = Invoke-BridgeApi -Method Post -Path "/api/plugin/project-credentials?$contextQuery" -Token $Token -Body @{ action = 'claim' }
    if (-not $claimed.job) { return }
    $job = $claimed.job
    $state = 'failed'
    try {
        $current = Invoke-BridgeApi -Method Post -Path "/api/plugin/project-credentials?$contextQuery" -Token $Token -Body @{
            action = 'verify'; id = [string]$job.id; claim = [string]$job.claim; projectId = [string]$job.projectId
            runtimeId = [string]$job.runtimeId; selectionRevision = [string]$job.selectionRevision
        }
        if (-not $current.valid) { throw 'Project selection changed.' }
        $node = Get-Command node.exe, node -ErrorAction Stop | Select-Object -First 1
        $runner = Join-Path $PSScriptRoot 'provision-project-credentials.mjs'
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $node.Source
        $start.Arguments = '"' + $runner + '"'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        [void]$process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $payloadBytes = [Text.Encoding]::UTF8.GetBytes(($job | ConvertTo-Json -Depth 8 -Compress))
        try { $process.StandardInput.BaseStream.Write($payloadBytes, 0, $payloadBytes.Length); $process.StandardInput.BaseStream.Flush() }
        finally { [Array]::Clear($payloadBytes, 0, $payloadBytes.Length); $process.StandardInput.BaseStream.Close() }
        if (-not $process.WaitForExit(75000)) { $process.Kill(); throw 'Setup timed out.' }
        $result = $outTask.Result | ConvertFrom-Json
        if ($process.ExitCode -eq 0 -and $result.state -in @('applied','setup_required','existing_account','failed')) { $state = [string]$result.state }
    } catch { $state = 'failed' }
    finally { if ($null -ne (Get-Variable process -ErrorAction SilentlyContinue)) { if ($process) { $process.Dispose() } }; $job.password = $null }
    Invoke-BridgeApi -Method Post -Path "/api/plugin/project-credentials?$contextQuery" -Token $Token -Body @{
        action = 'complete'; id = [string]$job.id; claim = [string]$job.claim; projectId = [string]$job.projectId
        runtimeId = [string]$job.runtimeId; selectionRevision = [string]$job.selectionRevision; state = $state
    } | Out-Null
}
