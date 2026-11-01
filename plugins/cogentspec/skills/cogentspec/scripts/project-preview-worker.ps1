Set-StrictMode -Version Latest

function Invoke-ProjectPreviewUploads([string]$Token) {
    $listing = Invoke-BridgeApi -Method Get -Path "/api/plugin/project-preview-uploads?$contextQuery" -Token $Token
    foreach ($upload in @($listing.uploads)) {
        $node = Get-Command node.exe, node -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $node) { return }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = [string]$node.Source
        $start.Arguments = '"' + (Join-Path $PSScriptRoot 'project-preview-upload.mjs') + '"'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        try {
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine((@{ context = $ContextKey; token = $Token; upload = $upload } | ConvertTo-Json -Depth 6 -Compress))
            $process.StandardInput.Close()
            $deadline = [DateTime]::UtcNow.AddSeconds(180)
            while (-not $process.WaitForExit(1500)) {
                if ([DateTime]::UtcNow -ge $deadline) { $process.Kill(); break }
                # Keep presence current while the broker verifies the uploaded app.
                try { Invoke-BridgeApi -Method Get -Path "/api/plugin/desktop-actions?$contextQuery" -Token $Token | Out-Null } catch { }
            }
            $stdout.GetAwaiter().GetResult() | Out-Null
            $stderr.GetAwaiter().GetResult() | Out-Null
        } finally { $process.Dispose() }
    }
}
