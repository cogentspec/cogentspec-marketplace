$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'NativeHost.cs') -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
$json=[CogentSpecQwenWeb.Protocol]::Json
$request=@{protocol='cogentspec-qwen-web-command-v1';command='$qwenweb';requestId=[Guid]::NewGuid().ToString();contextKey=('ctx-'+('a'*64))}
$script:calls=0
$connect=[Func[string,Collections.Generic.Dictionary[string,object]]]{param($context)
 if($context -cne ('ctx-'+('a'*64))){throw 'Wrong context'}
 $script:calls++
 $proof=[Collections.Generic.Dictionary[string,object]]::new()
 foreach($entry in @{browserNavigationProtocol='cogentspec-qwenweb-navigation-v1';status='ready';contextKey=$context;contextIsolated=$true;accountState='signed_in';mcpState='not_required';projectDataConnection='authenticated_desktop_bridge';presenceVerified=$true;defaultDirectoryReady=$true;browserOpened=$false;workspaceUrl='PRIVATE_WORKSPACE_URL';userMessage='PRIVATE_FIXTURE_DO_NOT_FORWARD'}.GetEnumerator()){$proof.Add($entry.Key,$entry.Value)}
 return ,$proof
}
$bytes=[Text.Encoding]::UTF8.GetBytes($json.Serialize($request))
$stream=[IO.MemoryStream]::new()
[CogentSpecQwenWeb.Protocol]::Write($stream,$request);$stream.Position=0
$read=[CogentSpecQwenWeb.Protocol]::Read($stream)
$proof=[CogentSpecQwenWeb.Protocol]::Execute($read,$connect)
$text=$json.Serialize($proof)
if($text -match 'ctx-|PRIVATE_FIXTURE|cgw_|cga_'){throw 'Private material escaped'}
if(($text | ConvertFrom-Json).status -ne 'ready' -or $script:calls -ne 1){throw 'Handshake not verified'}
$stream.Dispose()
foreach($change in @(@{command='powershell.exe'},@{contextKey='ctx-invalid'},@{protocol='wrong'},@{requestId='invalid'},@{helperPath='C:\arbitrary.ps1'})){
 $bad=$request.Clone();foreach($entry in $change.GetEnumerator()){$bad[$entry.Key]=$entry.Value}
 $rejected=$false
 try{[void][CogentSpecQwenWeb.Protocol]::Execute([Text.Encoding]::UTF8.GetBytes($json.Serialize($bad)),$connect)}catch{$rejected=$true}
 if(-not $rejected -or $script:calls -ne 1){throw 'Unsafe request reached execution'}
}
foreach($bytes in @([byte[]]@(1,0),[byte[]]@(0,0,0,0),[byte[]]@(1,8,0,0),[byte[]]@(2,0,0,0,123))){
 $stream=[IO.MemoryStream]::new($bytes);$rejected=$false
 try{[void][CogentSpecQwenWeb.Protocol]::Read($stream)}catch{$rejected=$true}
 if(-not $rejected){throw 'Malformed framing accepted'};$stream.Dispose()
}
$falseProof=[Func[string,Collections.Generic.Dictionary[string,object]]]{param($context)
 $proof=$connect.Invoke($context);$proof['presenceVerified']=$false;return ,$proof
}
$answer=[CogentSpecQwenWeb.Protocol]::Execute([Text.Encoding]::UTF8.GetBytes($json.Serialize($request)),$falseProof)
if(($json.Serialize($answer)|ConvertFrom-Json).status -eq 'ready'){throw 'Unverified connection reported success'}
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'register-native-host.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Registration script syntax failed'}
@{status='passed';nativeHostRegistered=$false;credentialsRead=$false;browserOpened=$false;invalidRequestsRejected=5;invalidFramesRejected=4} | ConvertTo-Json -Compress
