[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "dist\NMEA2000Diagnostics.exe"
}

if ($PSVersionTable.PSEdition -eq "Core") {
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -OutputPath $OutputPath
    if ($LASTEXITCODE -ne 0) {
        throw "The Windows PowerShell build failed with exit code $LASTEXITCODE."
    }
    return
}

$appSource = Join-Path $PSScriptRoot "NMEA2000Diagnostics.ps1"
$hostSource = Join-Path $PSScriptRoot "build\PortableHost.cs"
$manifest = Join-Path $PSScriptRoot "build\app.manifest"
$compiler = Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
$automationAssembly = [System.Management.Automation.PowerShell].Assembly.Location
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

foreach ($requiredFile in @($appSource, $hostSource, $manifest, $compiler)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required build file not found: $requiredFile"
    }
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($appSource, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}

[void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($OutputPath))

$compilerArguments = @(
    "/nologo"
    "/target:winexe"
    "/platform:anycpu"
    "/optimize+"
    "/debug-"
    "/reference:$automationAssembly"
    "/reference:System.Windows.Forms.dll"
    "/reference:System.Core.dll"
    "/win32manifest:$manifest"
    "/resource:$appSource,NMEA2000Diagnostics.ps1"
    "/out:$OutputPath"
    $hostSource
)

& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) {
    throw "C# compilation failed with exit code $LASTEXITCODE."
}

$artifact = Get-Item -LiteralPath $OutputPath
$hash = Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
Write-Output ("Built: {0} ({1:N0} bytes)" -f $artifact.FullName, $artifact.Length)
Write-Output ("SHA256: {0}" -f $hash.Hash)
