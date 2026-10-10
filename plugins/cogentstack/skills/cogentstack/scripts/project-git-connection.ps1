Set-StrictMode -Version Latest

# Captures credential-helper output only in memory, never through the generic
# native-command helper (which can capture stdout in temporary files).
function Invoke-PrivateGitProcess([string]$Root, [string[]]$Arguments, [string]$InputText = '', [bool]$Interactive = $false, [string]$AuthHeader = '', [string]$AuthHost = '') {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Command git.exe -ErrorAction Stop).Source
    $info.WorkingDirectory = $Root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ([string]$key -match '^(GIT_TRACE|GCM_TRACE|GIT_CONFIG_|GIT_CURL_VERBOSE|GIT_ASKPASS|SSH_ASKPASS)') { $info.EnvironmentVariables.Remove([string]$key) }
    }
    $info.EnvironmentVariables['GCM_CREDENTIAL_STORE'] = 'wincredman'
    $info.EnvironmentVariables['GCM_PROVIDER'] = 'auto'
    $info.EnvironmentVariables['GCM_ALLOW_UNSAFE_REMOTES'] = 'false'
    $info.EnvironmentVariables['GCM_INTERACTIVE'] = $(if ($Interactive) { 'true' } else { 'false' })
    $info.EnvironmentVariables['GCM_GUI_PROMPT'] = 'true'
    $info.EnvironmentVariables['GCM_GITHUB_AUTHMODES'] = 'browser'
    $info.EnvironmentVariables['GCM_GITLAB_AUTHMODES'] = 'browser'
    $info.EnvironmentVariables['GCM_TRACE'] = '0'
    $info.EnvironmentVariables['GCM_TRACE_SECRETS'] = '0'
    $info.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $info.EnvironmentVariables['GIT_SSL_NO_VERIFY'] = 'false'
    if ($AuthHeader) {
        if ($AuthHost -notin @('github.com', 'gitlab.com')) { throw 'Unsupported Git authentication host.' }
        # Use exactly the credential whose account was verified above. These
        # per-process settings are never written to Git config or command lines.
        $keys = @('http.extraHeader', "http.https://$AuthHost/.extraHeader", 'credential.helper', 'http.followRedirects', 'http.sslVerify')
        $values = @('', $AuthHeader, '', 'false', 'true')
        $info.EnvironmentVariables['GIT_CONFIG_COUNT'] = '5'
        for ($index = 0; $index -lt 5; $index++) {
            $info.EnvironmentVariables["GIT_CONFIG_KEY_$index"] = $keys[$index]
            $info.EnvironmentVariables["GIT_CONFIG_VALUE_$index"] = $values[$index]
        }
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($(if ($Interactive) { 180000 } else { 30000 }))) {
            $process.Kill()
            throw 'Git operation timed out. Close any unfinished sign-in window and retry.'
        }
        $process.WaitForExit()
        # Never return stderr: credential helpers and Git can include private data.
        [void]$stderr.GetAwaiter().GetResult()
        return @{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult().Trim() }
    } finally { $process.Dispose() }
}

function Get-ApprovedGitRemote([string]$Value) {
    if ($Value.Length -gt 240 -or $Value -cnotmatch '^https://(github\.com|gitlab\.com)/([A-Za-z0-9_-][A-Za-z0-9_.-]*(/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+)$') { return $null }
    $providerHost = $Matches[1]; $path = $Matches[2] -replace '\.git$', ''
    if ($providerHost -eq 'github.com' -and $path.Split('/').Count -ne 2) { return $null }
    return @{ HostName = $providerHost; Path = $path }
}

function Invoke-ProjectGitConnection([string]$Root, $Payload) {
    $operation = [string]$Payload.connectionOperation
    $provider = [string]$Payload.provider
    if ($operation -notin @('check', 'connect', 'disconnect', 'save_remote', 'push') -or $provider -notin @('github', 'gitlab')) { throw 'Invalid approved Git connection action.' }
    $providerHost = if ($provider -eq 'github') { 'github.com' } else { 'gitlab.com' }
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Git for Windows is not available to the Bridge. Install it, then restart the Bridge with $cogentspec.' }
    $manager = Invoke-PrivateGitProcess $Root @('credential-manager', '--version')
    if ($manager.ExitCode -ne 0) { throw 'Git Credential Manager is not available to the Bridge. Enable it in Git for Windows, then restart the Bridge with $cogentspec.' }
    $result = [ordered]@{ provider = $provider; account = ''; machine = [Environment]::MachineName; state = 'unavailable'; remoteUrl = ''; branch = ''; head = ''; visibility = 'unknown'; canPush = $false; checkedAt = [DateTimeOffset]::UtcNow.ToString('O') }
    if ($operation -eq 'save_remote') {
        $approvedRemote = Get-ApprovedGitRemote ([string]$Payload.remoteUrl)
        if (-not $approvedRemote -or $approvedRemote.HostName -ne $providerHost) { throw 'The repository address does not match the approved provider.' }
        $exists = Invoke-PrivateGitProcess $Root @('remote', 'get-url', 'origin')
        $change = if ($exists.ExitCode -eq 0) { Invoke-PrivateGitProcess $Root @('remote', 'set-url', 'origin', [string]$Payload.remoteUrl) } else { Invoke-PrivateGitProcess $Root @('remote', 'add', 'origin', [string]$Payload.remoteUrl) }
        if ($change.ExitCode -ne 0) { throw 'The repository address could not be saved.' }
    }
    $remote = Invoke-PrivateGitProcess $Root @('remote', 'get-url', 'origin')
    $parsed = Get-ApprovedGitRemote $remote.Output
    if ($parsed -and $parsed.HostName -eq $providerHost) { $result.remoteUrl = $remote.Output }
    $result.branch = (Invoke-PrivateGitProcess $Root @('branch', '--show-current')).Output
    $result.head = (Invoke-PrivateGitProcess $Root @('rev-parse', '--verify', 'HEAD')).Output
    if ($result.head -notmatch '^[0-9a-f]{40,64}$') { $result.head = '' }
    $inputText = "protocol=https`nhost=$providerHost`n`n"
    $credential = $null
    try {
        $credential = Invoke-PrivateGitProcess $Root @('credential-manager', 'get') $inputText ($operation -eq 'connect')
        if ($credential.ExitCode -ne 0) {
            if ($operation -eq 'connect') { throw 'Git Credential Manager is installed, but sign-in did not complete. Retry Connect / sign in and complete the provider window. No repository push was attempted.' }
            if ($operation -in @('push', 'disconnect')) { throw 'Git authentication is no longer available. Check the account before retrying.' }
            return $result
        }
        $values = @{}
        foreach ($line in ($credential.Output -split "`r?`n")) { if ($line -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
        if (-not $values['password']) { throw 'Git Credential Manager did not provide a usable connection.' }
        $headers = @{ Authorization = "Bearer $($values['password'])"; 'User-Agent' = 'CogentSpec-Desktop-Bridge'; Accept = 'application/json' }
        try {
            $apiBase = if ($provider -eq 'github') { 'https://api.github.com' } else { 'https://gitlab.com/api/v4' }
            $user = Invoke-RestMethod -Uri "$apiBase/user" -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
            $result.account = if ($provider -eq 'github') { [string]$user.login } else { [string]$user.username }
            if ($result.account -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Invalid account response.' }
            $result.state = 'verified'
            if ($result.remoteUrl) {
                $repoPath = if ($provider -eq 'github') { "/repos/$($parsed.Path)" } else { '/projects/' + [Uri]::EscapeDataString($parsed.Path) }
                try {
                    $repo = Invoke-RestMethod -Uri "$apiBase$repoPath" -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
                    if ($provider -eq 'github') {
                        $result.visibility = if ($repo.private) { 'private' } else { 'public' }
                        $result.canPush = $repo.PSObject.Properties['permissions'] -and $repo.permissions.PSObject.Properties['push'] -and $repo.permissions.push -eq $true
                    } else {
                        $result.visibility = [string]$repo.visibility
                        $levels = @()
                        if ($repo.PSObject.Properties['permissions']) {
                            foreach ($permission in @('project_access', 'group_access')) {
                                if ($repo.permissions.PSObject.Properties[$permission] -and $repo.permissions.$permission) { $levels += [int]$repo.permissions.$permission.access_level }
                            }
                        }
                        $result.canPush = @($levels | Where-Object { $_ -ge 30 }).Count -gt 0
                    }
                } catch { $result.visibility = 'unknown'; $result.canPush = $false }
            }
        } catch { throw 'The provider could not verify this account. Check your connection or sign in again.' }
        if ($operation -eq 'disconnect') {
            if ($result.account -cne [string]$Payload.account) { throw 'The connected account changed. Check and confirm the account again.' }
            $username = [string]$values['username']
            if ($username -notmatch '^[A-Za-z0-9_.@-]+$') { throw 'The stored account could not be safely identified.' }
            $erase = Invoke-PrivateGitProcess $Root @('credential-manager', 'erase') "protocol=https`nhost=$providerHost`nusername=$username`n`n"
            if ($erase.ExitCode -ne 0) { throw 'Could not disconnect the account. Check Git Credential Manager.' }
            $result.state = 'disconnected'; $result.account = ''; $result.canPush = $false
            return $result
        }
        if ($operation -eq 'push') {
            foreach ($field in @('remoteUrl', 'branch', 'head', 'account', 'visibility', 'machine')) {
                if ([string]$result[$field] -cne [string]$Payload.$field) { throw 'The Git account, destination or saved commit changed. Review and confirm again.' }
            }
            if (-not $result.canPush -or -not $result.remoteUrl -or -not $result.head -or -not $result.branch) { throw 'Push access could not be verified.' }
            if ((Invoke-PrivateGitProcess $Root @('check-ref-format', '--branch', $result.branch)).ExitCode -ne 0) { throw 'The destination branch is invalid.' }
            # Reject insteadOf rewriting; use an explicit URL, not pushurl/refspec config.
            $effective = Invoke-PrivateGitProcess $Root @('ls-remote', '--get-url', $result.remoteUrl)
            if ($effective.Output -cne $result.remoteUrl) { throw 'Git URL rewriting must be removed before this destination can be verified.' }
            $authArgs = @('-c', 'push.followTags=false', '-c', 'push.recurseSubmodules=no')
            $authHeader = 'Authorization: Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($values['username']):$($values['password'])"))
            $refspec = "$($result.head):refs/heads/$($result.branch)"
            $check = Invoke-PrivateGitProcess -Root $Root -Arguments ($authArgs + @('push', '--dry-run', '--no-verify', '--', $result.remoteUrl, $refspec)) -AuthHeader $authHeader -AuthHost $providerHost
            if ($check.ExitCode -ne 0) { throw 'Push preflight failed. Check branch permissions and remote changes; no force push was attempted.' }
            $push = Invoke-PrivateGitProcess -Root $Root -Arguments ($authArgs + @('push', '--', $result.remoteUrl, $refspec)) -AuthHeader $authHeader -AuthHost $providerHost
            if ($push.ExitCode -ne 0) { throw 'Push did not complete. Check the repository before retrying; no force push was attempted.' }
        }
        return $result
    } finally { $credential = $null; $values = $null; $headers = $null; $authHeader = $null }
}
