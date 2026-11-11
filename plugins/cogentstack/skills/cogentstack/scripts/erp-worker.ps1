[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'erp-installation-worker.ps1')
. (Join-Path $PSScriptRoot 'project-credential-worker.ps1')
$contextQuery = ''
$script:ErpWorkDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'CogentSpec\projects'
$mutex = New-Object Threading.Mutex($false, 'Local\CogentSpec-ERP-installer-v1')
$owned = $false
function Invoke-BridgeApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $parameters = @{ Method=$Method; Uri=('https://cogentspec.com' + $Path); MaximumRedirection=0; TimeoutSec=15; Headers=@{Authorization="Bearer $Token";Accept='application/json'} }
    if ($Body) { $parameters.ContentType='application/json; charset=utf-8'; $parameters.Body=[Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress)) }
    return Invoke-RestMethod @parameters
}
try {
    $owned = $mutex.WaitOne(0)
    if (-not $owned) { exit 0 }
    while ($true) {
        $bytes = $null; $token = $null
        try {
            $managerRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\bridge-manager\v1'
            $current = Get-Content -LiteralPath (Join-Path $managerRoot 'current.json') -Raw | ConvertFrom-Json
            if ((Split-Path -Leaf $PSScriptRoot) -cne $current.version) { break }
            if ($current.version -notmatch '^[a-f0-9]{24}$') { throw 'Invalid ERP worker package.' }
            foreach ($entry in $current.hashes.PSObject.Properties) {
                if ($entry.Name -notmatch '^[a-z0-9-]+\.(ps1|mjs)$') { throw 'Invalid ERP worker package.' }
                $file = Join-Path $PSScriptRoot $entry.Name
                if ((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Invalid ERP worker package.' }
                if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value) { throw 'Changed ERP worker package.' }
            }
            if (-not (Test-Path -LiteralPath (Join-Path $managerRoot 'paused'))) {
                $credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
                $credential = Get-Content -LiteralPath $credentialPath -Raw | ConvertFrom-Json
                if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { Add-Type -AssemblyName System.Security }
                $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
                $token = [Text.Encoding]::UTF8.GetString($bytes)
                Invoke-ErpInstallationWork -Token $token
                $node = (Get-Command node.exe -ErrorAction Stop).Source
                $start = New-Object Diagnostics.ProcessStartInfo
                $start.FileName = $node
                $start.Arguments = '"' + (Join-Path $PSScriptRoot 'erp-customer-worker.mjs') + '"'
                $start.UseShellExecute = $false; $start.CreateNoWindow = $true
                $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
                $process = New-Object Diagnostics.Process
                $process.StartInfo = $start
                try {
                    [void]$process.Start()
                    $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
                    $process.StandardInput.Write(({token=$token} | ConvertTo-Json -Compress)); $process.StandardInput.Close()
                    if (-not $process.WaitForExit(2700000)) { $process.Kill(); throw 'Customer release helper timed out; inspect its recovery journal.' }
                    [void]$output.GetAwaiter().GetResult(); [void]$errors.GetAwaiter().GetResult()
                } finally { $process.Dispose() }
            }
        } catch { } finally { $token=$null; if ($bytes) { [Array]::Clear($bytes,0,$bytes.Length) } }
        Start-Sleep -Seconds 10
    }
} finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
