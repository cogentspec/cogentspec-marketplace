$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'NativeHost.cs') -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
$count = 0
foreach ($text in @('{"accepted":true}', '{"state":"hidden"}', '{"state":"closed"}')) {
    $memory = [IO.MemoryStream]::new()
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    [CogentSpecBrowser.Framing]::Write($memory, $bytes)
    $memory.Position = 0
    $actual = [CogentSpecBrowser.Framing]::Read($memory)
    if ([Text.Encoding]::UTF8.GetString($actual) -ne $text) {throw 'Framing round trip failed'}
    $memory.Dispose(); $count++
}
foreach ($bad in @([byte[]]@(1,0), [byte[]]@(0,0,0,0), [byte[]]@(1,0,1,0), [byte[]]@(2,0,0,0,123))) {
    $memory = [IO.MemoryStream]::new($bad)
    $failed = $false
    try {[void][CogentSpecBrowser.Framing]::Read($memory)} catch {$failed = $true}
    if (-not $failed) {throw 'Invalid frame accepted'}
    $memory.Dispose(); $count++
}
Add-Type -AssemblyName System.Web.Extensions
$json = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
$sample = $json.DeserializeObject('{"workspaceTabs":[{"id":1,"windowId":1,"active":true}]}')
if ($sample.workspaceTabs -isnot [Collections.ArrayList] -and $sample.workspaceTabs -isnot [object[]]) {throw 'Unexpected JSON array representation'}
@{status='passed'; assertions=$count; hostMainInvoked=$false; nativeWindowCallsPerformed=$false} | ConvertTo-Json -Compress
