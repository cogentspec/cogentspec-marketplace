function Invoke-ErpInstallationWork([string]$Token) {
    $claimed = Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'claim'; protocol = 1; workDirectory = $script:ErpWorkDirectory }
    foreach ($installed in @($claimed.installed)) {
        # Credential work remains in its existing protected, project-bound transport.
        $contextQuery = "context=$([Uri]::EscapeDataString([string]$installed.context))"
        try { Invoke-InitialCredentialSetup -Token $Token } catch { }
        try {
            $proof = Invoke-ErpProjectRunner -Project $installed.project -InspectOnly
            Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'verify'; id = $installed.id; claim = $installed.claim; proof = $proof } | Out-Null
        } catch { }
    }
    if (-not $claimed.job) { return }
    $job = $claimed.job
    try {
        $contextQuery = "context=$([Uri]::EscapeDataString([string]$job.context_key))"
        if ($job.mode -in @('reconnect','check')) {
            $proof = Invoke-ErpProjectRunner -Project $job.project -InspectOnly:($job.mode -eq 'check')
            Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'complete'; id = $job.id; claim = $job.claim; proof = $proof } | Out-Null
            return
        }
        $project = $job.project
        if (-not $project -or $project.status -ne 'created') {
            if ($job.draft.folderStatus -ne 'ready') {
                $folder = & (Join-Path $PSScriptRoot 'create-specification-project.ps1') -Mode create -RequestId ([string]$job.draft_id) -ContextKey ([string]$job.context_key)
                $folderResult = ($folder -join "`n") | ConvertFrom-Json
                if ($folderResult.status -ne 'specification_created') { throw 'The approved project folder is not ready.' }
            }
            $prepared = Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'foundation'; id = $job.id; claim = $job.claim }
            $project = $prepared.project
            $foundation = & (Join-Path $PSScriptRoot 'fulfil-project.ps1') -Mode create -RequestId ([string]$project.id) -ContextKey ([string]$job.context_key)
            $foundationResult = ($foundation -join "`n") | ConvertFrom-Json
            if ($foundationResult.status -ne 'created') { throw 'The approved ERP foundation is not ready.' }
        }
        $proof = Invoke-ErpProjectRunner -Project $project
        Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'complete'; id = $job.id; claim = $job.claim; proof = $proof } | Out-Null
    } catch {
        Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'fail'; id = $job.id; claim = $job.claim } | Out-Null
    }
}

function Invoke-ErpProjectRunner($Project, [switch]$InspectOnly) {
    $process = $null
    try {
        $node = Get-Command node.exe, node -ErrorAction Stop | Select-Object -First 1
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $node.Source
        $start.Arguments = '"' + (Join-Path $PSScriptRoot 'install-erp-project.mjs') + '"'
        if ($InspectOnly) { $start.Arguments += ' --inspect' }
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process; $process.StartInfo = $start
        [void]$process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write(($Project | ConvertTo-Json -Depth 8 -Compress)); $process.StandardInput.Close()
        if (-not $process.WaitForExit(1200000)) { $process.Kill(); throw 'Installation timed out.' }
        if ($process.ExitCode -ne 0) { throw 'Installation failed.' }
        return ($outTask.Result | ConvertFrom-Json)
    } finally { if ($process) { $process.Dispose() } }
}
