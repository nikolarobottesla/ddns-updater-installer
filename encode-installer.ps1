<#
.SYNOPSIS
    Encodes install-windows.ps1 and injects a copy/paste command into README.md.

.DESCRIPTION
    Reads the installer, base64-encodes its bytes, and builds a one-line PowerShell
    command that writes the decoded installer to a temporary file and runs it with
    -ExecutionPolicy Bypass. The command is placed between the README markers so
    running this script repeatedly is idempotent.

.PARAMETER InstallerPath
    Path to install-windows.ps1.

.PARAMETER ReadmePath
    Path to README.md.

.PARAMETER Check
    Do not write anything; fail if README.md is out of date.
#>
[CmdletBinding()]
param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'install-windows.ps1'),
    [string]$ReadmePath = (Join-Path $PSScriptRoot 'README.md'),
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$beginMarker = '<!-- BEGIN WINDOWS INSTALL COMMAND -->'
$endMarker = '<!-- END WINDOWS INSTALL COMMAND -->'

$installerBytes = [IO.File]::ReadAllBytes($InstallerPath)
$encodedInstaller = [Convert]::ToBase64String($installerBytes)

$commandTemplate = @'
$p='__ENCODED_INSTALLER__'; $t=Join-Path $env:TEMP 'ddns-updater-installer.ps1'; [IO.File]::WriteAllText($t,[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)),[Text.UTF8Encoding]::new($false)); try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$t" } finally { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
'@
$command = $commandTemplate.Replace('__ENCODED_INSTALLER__', $encodedInstaller)

$block = @(
    $beginMarker
    '```powershell'
    $command
    '```'
    $endMarker
) -join "`n"

$readme = [IO.File]::ReadAllText($ReadmePath)
$pattern = '(?s)' + [regex]::Escape($beginMarker) + '.*?' + [regex]::Escape($endMarker)
$matchEvaluator = [Text.RegularExpressions.MatchEvaluator] { param($match) $block }

if ([regex]::IsMatch($readme, $pattern)) {
    $updatedReadme = [regex]::Replace($readme, $pattern, $matchEvaluator)
} else {
    $updatedReadme = $readme.TrimEnd([char]13, [char]10) + "`n`n" + $block
}
if (-not $updatedReadme.EndsWith("`n")) {
    $updatedReadme += "`n"
}

if ($Check) {
    if ($updatedReadme -cne $readme) {
        throw 'README.md is out of date. Run ./encode-installer.ps1 and commit the result.'
    }
    return
}

[IO.File]::WriteAllText($ReadmePath, $updatedReadme, [Text.UTF8Encoding]::new($false))
Write-Host "Updated $ReadmePath with the encoded installer command ($($command.Length) characters)."
