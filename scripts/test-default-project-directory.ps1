[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\cogentspec\skills\cogentspec\scripts\ensure-default-project-directory.ps1')
function Assert-DirectoryTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('cogentspec-default-directory-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$originalAcl = $null
$blockedPath = ''
try {
    $profile = Join-Path $fixtureRoot 'New Windows Profile'
    [void][IO.Directory]::CreateDirectory($profile)
    $result = Initialize-CogentSpecDefaultProjectDirectory -ProfileDirectory $profile
    $expected = Join-Path $profile 'CogentSpec\projects'
    Assert-DirectoryTest ($result.status -eq 'ready' -and $result.created -and $result.writable -and $result.directory -eq $expected) 'First use did not create and verify the exact default.'
    Assert-DirectoryTest (@(Get-ChildItem -LiteralPath $expected -Force).Count -eq 0) 'The write check left a probe or created a project.'
    $sentinel = Join-Path $expected 'keep-this-file.txt'
    [IO.File]::WriteAllText($sentinel, 'Existing user content.')
    $again = Initialize-CogentSpecDefaultProjectDirectory -ProfileDirectory $profile
    Assert-DirectoryTest ($again.status -eq 'ready' -and -not $again.created) 'Existing directory was not reused.'
    Assert-DirectoryTest ([IO.File]::ReadAllText($sentinel) -ceq 'Existing user content.') 'Existing contents were modified.'
    Assert-DirectoryTest (@(Get-ChildItem -LiteralPath $expected -Force).Count -eq 1) 'Repeated verification left temporary files.'
    $blockedPath = $expected
    $originalAcl = [IO.Directory]::GetAccessControl($blockedPath)
    $deniedAcl = [IO.Directory]::GetAccessControl($blockedPath)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.AccessControl.FileSystemRights]::Write,
        [Security.AccessControl.AccessControlType]::Deny)
    $deniedAcl.AddAccessRule($rule)
    [IO.Directory]::SetAccessControl($blockedPath, $deniedAcl)
    try {
        $blocked = Initialize-CogentSpecDefaultProjectDirectory -ProfileDirectory $profile
        Assert-DirectoryTest ($blocked.status -eq 'default_directory_unavailable' -and $blocked.reason -eq 'default_directory_not_writable' -and -not $blocked.writable) 'An unwritable folder was reported ready.'
    } finally {
        $originalAcl.SetSecurityDescriptorSddlForm($originalAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access), [Security.AccessControl.AccessControlSections]::Access)
        [IO.Directory]::SetAccessControl($blockedPath, $originalAcl)
        $originalAcl = $null
    }
    $collisionProfile = Join-Path $fixtureRoot 'Collision Profile'
    [void][IO.Directory]::CreateDirectory($collisionProfile)
    $collisionFile = Join-Path $collisionProfile 'CogentSpec'
    [IO.File]::WriteAllText($collisionFile, 'Do not replace.')
    $collision = Initialize-CogentSpecDefaultProjectDirectory -ProfileDirectory $collisionProfile
    Assert-DirectoryTest ($collision.status -eq 'default_directory_unavailable' -and $collision.reason -eq 'unsafe_default_directory') 'A file collision was not rejected.'
    Assert-DirectoryTest ([IO.File]::ReadAllText($collisionFile) -ceq 'Do not replace.') 'A conflicting file was overwritten.'
    foreach ($invalid in @('', 'relative', 'C:\', (Join-Path $fixtureRoot 'missing-profile'), (Join-Path $profile '..\escaped'))) {
        $failure = Initialize-CogentSpecDefaultProjectDirectory -ProfileDirectory $invalid
        Assert-DirectoryTest ($failure.status -eq 'default_directory_unavailable') 'An unsafe or unavailable profile was accepted.'
    }
    $junctionProfile = Join-Path $fixtureRoot 'Junction Profile'
    $other = Join-Path $fixtureRoot 'Elsewhere'
    [void][IO.Directory]::CreateDirectory($junctionProfile)
    [void][IO.Directory]::CreateDirectory($other)
    $junction = Join-Path $junctionProfile 'CogentSpec'
    [void](New-Item -ItemType Junction -Path $junction -Target $other)
    try {
        $redirected = Initialize-CogentSpecDefaultProjectDirectory -ProfileDirectory $junctionProfile
        Assert-DirectoryTest ($redirected.status -eq 'default_directory_unavailable' -and $redirected.reason -eq 'unsafe_default_directory') 'A junction was followed.'
        Assert-DirectoryTest (-not (Test-Path -LiteralPath (Join-Path $other 'projects'))) 'Preparation escaped the intended profile through a junction.'
    } finally { [IO.Directory]::Delete($junction) }
    [ordered]@{status='valid';firstTimeCreation=$true;existingContentsPreserved=$true;writeProbeCleaned=$true;permissionFailureVerified=$true;fileCollisionRejected=$true;unsafeProfilesRejected=$true;junctionRejected=$true;projectCreated=$false} | ConvertTo-Json -Compress
} finally {
    if ($null -ne $originalAcl -and $blockedPath) {
        $originalAcl.SetSecurityDescriptorSddlForm($originalAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access), [Security.AccessControl.AccessControlSections]::Access)
        [IO.Directory]::SetAccessControl($blockedPath, $originalAcl)
    }
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^cogentspec-default-directory-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { throw 'Unsafe test cleanup target.' }
}
