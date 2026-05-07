param(
	[string]$Config = "Release",
	[string]$BuildDir = "build",
	[string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

cmake -S . -B $BuildDir -A $Arch
cmake --build $BuildDir --config $Config --parallel
