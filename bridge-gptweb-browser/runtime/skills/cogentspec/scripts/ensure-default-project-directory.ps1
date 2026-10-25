# Internal Bridge helper: the only automatic target is the Windows profile's
# CogentSpec\projects directory. Custom parents remain approved project actions.
function Initialize-CogentSpecDefaultProjectDirectory {
    [CmdletBinding()]
    param([string]$ProfileDirectory = [Environment]::GetFolderPath('UserProfile'))

    $directory = ''
    $reason = 'profile_directory_unavailable'
    $created = $false
    try {
        if (-not $ProfileDirectory -or $ProfileDirectory -notmatch '^[A-Za-z]:\\' -or
            $ProfileDirectory -match '(^|\\)\.\.?($|\\)' -or
            $ProfileDirectory.Substring(2).Contains(':')) { throw 'Invalid profile location.' }
        $profile = [IO.Path]::GetFullPath($ProfileDirectory).TrimEnd('\')
        if ($profile -eq [IO.Path]::GetPathRoot($profile).TrimEnd('\') -or
            -not (Test-Path -LiteralPath $profile -PathType Container)) { throw 'Profile location is unavailable.' }
        $directory = Join-Path $profile 'CogentSpec\projects'
        # Reject files and reparse points in the existing target chain; never
        # follow a junction/symlink outside the intended profile-owned location.
        $reason = 'unsafe_default_directory'
        $cursor = $directory
        while ($cursor) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (-not $item.PSIsContainer -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe directory component.' }
            }
            $parent = Split-Path -Parent $cursor
            if (-not $parent -or $parent -eq $cursor) { break }
            $cursor = $parent
        }
        $reason = 'default_directory_creation_failed'
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($directory)
            $created = $true
        }
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Default directory is unsafe.' }
        $reason = 'default_directory_not_writable'
        # Exclusive, random probe: never truncate a user's file. DeleteOnClose
        # removes only this probe, including if the write or flush fails.
        $probePath = Join-Path $directory ('.cogentspec-write-check-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $probe = [IO.FileStream]::new($probePath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
        try { $probe.WriteByte(0); $probe.Flush() }
        finally { $probe.Dispose() }
        return [pscustomobject]@{
            status = 'ready'; directory = $directory; created = $created; writable = $true
        }
    } catch {
        return [pscustomobject]@{
            status = 'default_directory_unavailable'; directory = $directory
            created = $created; writable = $false; reason = $reason
            userMessage = 'CogentSpec could not prepare its default projects folder. Check the Windows profile location and folder permissions, then run the Bridge command again. No project was created.'
        }
    }
}
