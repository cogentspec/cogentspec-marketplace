. (Join-Path $PSScriptRoot "erp-docker-setup.ps1")
$script:LastDockerSetupId=''
function Invoke-ErpInstallationWork([string]$Token) {
    $docker=Get-ErpDockerPrerequisite
    if($script:LastDockerSetupId){
        try {
            $setup=Read-ErpDockerSetup $script:LastDockerSetupId
            if($setup){$docker.requestId=$setup.id;$docker.phase=$setup.phase;$docker.reason=$setup.reason}
        } catch {$docker.requestId=$script:LastDockerSetupId;$docker.phase='failed';$docker.reason='finish_setup'}
    }
    $claimed = Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'claim'; protocol = 4; workDirectory = $script:ErpWorkDirectory; docker=$docker }
    if($claimed.PSObject.Properties['dockerSetup'] -and $claimed.dockerSetup){
        $script:LastDockerSetupId=[string]$claimed.dockerSetup.id
        Start-ErpDockerSetup $script:LastDockerSetupId ([string]$claimed.dockerSetup.action)
    }
    if ($claimed.PSObject.Properties['deletions']) {
        foreach ($deletion in @($claimed.deletions)) {
            # Only server-approved ERP deletions bound to this computer are returned.
            Invoke-ErpDeletion -Deletion $deletion
        }
    }
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
        $installationDeadline = if ($Project.projectType -eq 'erpnext_business_app') { 2400000 } else { 1200000 }
        if (-not $process.WaitForExit($installationDeadline)) { $process.Kill(); throw 'Installation timed out.' }
        if ($process.ExitCode -ne 0) { throw 'Installation failed.' }
        return ($outTask.Result | ConvertFrom-Json)
    } finally { if ($process) { $process.Dispose() } }
}

function Invoke-ErpDeletion($Deletion) {
    if ([string]$Deletion.requestId -notmatch '^[a-f0-9-]{36}$' -or [string]$Deletion.contextKey -notmatch '^(ctx-[a-f0-9]{64}|default)$') { throw 'The approved ERP deletion identity is invalid.' }
    $process = $null
    try {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $entry = Join-Path $PSScriptRoot 'erp-delete-project.ps1'
        $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $entry + '" -Mode delete -RequestId "' + $Deletion.requestId + '" -ContextKey "' + $Deletion.contextKey + '"'
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process; $process.StartInfo = $start; [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(900000)) { $process.Kill(); throw 'ERP removal was interrupted and requires confirmation before retrying.' }
        if ($process.ExitCode -ne 0) { throw 'ERP removal could not finish.' }
    } finally { if ($process) { $process.Dispose() } }
}
