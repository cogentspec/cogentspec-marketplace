Set-StrictMode -Version Latest

function Test-CogentSpecSandboxIdentity([string]$IdentityName) {
    return ($IdentityName.Split('\')[-1] -match '^CodexSandbox')
}

function Get-CogentSpecExecutionPermissionFailure {
    # CurrentUser DPAPI belongs to the installing Windows user, not the
    # dedicated Codex sandbox account. Do not attempt credential access here.
    if (Test-CogentSpecSandboxIdentity ([Security.Principal.WindowsIdentity]::GetCurrent().Name)) {
        return [ordered]@{
            status = 'execution_permission_required'
            reason = 'windows_user_execution_required'
            userMessage = 'CogentSpec needs permission to run its connection helper as your Windows user with service access. Your Bridge installation has not been changed.'
            credentialRead = $false
            networkAttempted = $false
        }
    }
    return $null
}

function Invoke-CogentSpecNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(0, 3600)]
        [int]$TimeoutSeconds = 0
    )

    if ($TimeoutSeconds -gt 0) {
        $captureRoot = Join-Path ([IO.Path]::GetTempPath()) ("cogentspec-native-" + [Guid]::NewGuid().ToString('N'))
        $standardOutputPath = Join-Path $captureRoot 'stdout.txt'
        $standardErrorPath = Join-Path $captureRoot 'stderr.txt'
        $process = $null
        try {
            [void](New-Item -ItemType Directory -Path $captureRoot -Force)
            $launchFilePath = $FilePath
            $launchArgumentList = $ArgumentList
            if ([IO.Path]::GetExtension($FilePath) -ieq '.ps1') {
                $launchFilePath = (Get-Process -Id $PID -ErrorAction Stop).Path
                $launchArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath) + $ArgumentList
            }
            $process = Start-Process `
                -FilePath $launchFilePath `
                -ArgumentList $launchArgumentList `
                -WindowStyle Hidden `
                -PassThru `
                -RedirectStandardOutput $standardOutputPath `
                -RedirectStandardError $standardErrorPath
            $completed = $process.WaitForExit($TimeoutSeconds * 1000)
            if (-not $completed) {
                & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
                return [pscustomobject]@{
                    ExitCode = -1
                    Output = ''
                    TimedOut = $true
                }
            }
            $process.WaitForExit()
            $standardOutput = if (Test-Path -LiteralPath $standardOutputPath -PathType Leaf) {
                Get-Content -Raw -LiteralPath $standardOutputPath
            } else { '' }
            $standardError = if (Test-Path -LiteralPath $standardErrorPath -PathType Leaf) {
                Get-Content -Raw -LiteralPath $standardErrorPath
            } else { '' }
            return [pscustomobject]@{
                ExitCode = [int]$process.ExitCode
                Output = (@($standardOutput, $standardError) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join [Environment]::NewLine
                TimedOut = $false
            }
        } finally {
            if ($process) { $process.Dispose() }
            if (Test-Path -LiteralPath $captureRoot -PathType Container) {
                Remove-Item -LiteralPath $captureRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $nativeOutput = ''
    $nativeExitCode = -1
    try {
        # Windows PowerShell 5.1 promotes native stderr records according to
        # ErrorActionPreference. Capture both streams without allowing a warning
        # from a successful process to skip the real exit-code check.
        $ErrorActionPreference = 'Continue'
        $nativeOutput = & $FilePath @ArgumentList 2>&1 | Out-String
        $nativeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = [int]$nativeExitCode
        Output = $nativeOutput.Trim()
        TimedOut = $false
    }
}
