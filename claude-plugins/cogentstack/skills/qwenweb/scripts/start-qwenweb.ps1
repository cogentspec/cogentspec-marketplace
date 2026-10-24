[CmdletBinding()]
param([string]$ContextKey = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$core = Join-Path $PSScriptRoot '..\..\cogentstack\scripts\start-workspace-beacon.ps1'
& $core -ContextKey $ContextKey -Surface qwen-web -Experience web
