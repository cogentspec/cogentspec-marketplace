Set-StrictMode -Version Latest

function Invoke-ProjectSourceChecks([string]$Token) {
    # The server chooses only registered, owned project folders requested by the UI.
    # This worker hashes files; it never executes a project's scripts or changes selection.
    $listing = Invoke-BridgeApi -Method Get -Path "/api/plugin/project-source-checks?$contextQuery" -Token $Token
    foreach ($check in @($listing.checks)) {
        $body = @{ checkId = [string]$check.id; projectId = [string]$check.projectId; available = $false }
        try {
            $node = Get-Command node.exe, node -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $node) { throw 'A local source check is unavailable.' }
            $helper = Join-Path $PSScriptRoot 'project-source-fingerprint.mjs'
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = [string]$node.Source
            $start.Arguments = '"' + $helper + '"'
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardInput = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $start
            try {
                [void]$process.Start()
                $payload = @{ targetPath = [string]$check.targetPath; projectId = [string]$check.projectId } | ConvertTo-Json -Compress
                $process.StandardInput.WriteLine($payload)
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(12000)) { $process.Kill(); throw 'The source check timed out.' }
                if ($process.ExitCode -ne 0) { throw 'The project source check did not finish.' }
                $result = $process.StandardOutput.ReadToEnd()
                if ($result.Length -gt 2048) { throw 'Invalid fingerprint.' }
                $fingerprint = $result | ConvertFrom-Json
            } finally { $process.Dispose() }
            if ([string]$fingerprint.protocol -ne 'cogentspec-project-source-v1' -or [string]$fingerprint.sourceDigest -notmatch '^[a-f0-9]{64}$') { throw 'Invalid fingerprint.' }
            $body.available = $true
            $body.protocol = [string]$fingerprint.protocol
            $body.sourceDigest = [string]$fingerprint.sourceDigest
            $body.files = [int]$fingerprint.files
        } catch { }
        Invoke-BridgeApi -Method Post -Path "/api/plugin/project-source-checks?$contextQuery" -Token $Token -Body $body | Out-Null
    }
}
