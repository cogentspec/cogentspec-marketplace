[CmdletBinding()]
param([string]$ContextKey = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$core = Join-Path $PSScriptRoot '..\..\cogentspec\scripts\start-workspace-beacon.ps1'
& $core -ContextKey $ContextKey -Surface chatgpt -Experience desktop-ui
