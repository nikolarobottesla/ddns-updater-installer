<#
.SYNOPSIS
    Installs the latest qdm12/ddns-updater Windows binary like a regular program.

.DESCRIPTION
    Downloads the newest Windows release from GitHub (with SHA-256 verification),
    installs it into a program directory, generates a DuckDNS config.json that
    maintains both IPv4 (A) and IPv6 (AAAA) records by prompting for the domain
    and token, registers a Windows background service that starts automatically
    at boot, creates Start menu shortcuts to run, update and uninstall, and
    registers an Add/Remove Programs entry.

    The executable is a console program, so WinSW (a small, pinned service
    wrapper) is downloaded from GitHub to host it as a real Windows service.
    Service management requires administrator rights; the script relaunches
    itself with a UAC prompt when needed.

    Run this script once with no arguments to install. Afterwards use the
    "Update DDNS Updater" and "Uninstall DDNS Updater" shortcuts, or re-run this
    script with -Action Update / -Action Uninstall.

.PARAMETER Action
    Install (default), Update, Uninstall or Run. "Run" opens the web UI when the
    service is running, and launches the executable directly when -NoService
    was used.

.PARAMETER InstallDir
    Where the executable is installed. Defaults to the registry value recorded
    by a previous install, the directory this script sits in when it contains
    ddns-updater.exe, or %LOCALAPPDATA%\Programs\DDNS-Updater.

.PARAMETER DataDir
    Where config.json and updates.json are kept. Defaults to <InstallDir>\data.

.PARAMETER NoPath
    Do not add the install directory to the current user's PATH.

.PARAMETER NoService
    Skip creating the Windows service. The program then only runs from the
    "Run" shortcut and is not started at boot.

.PARAMETER StartMenuFolder
    Internal. Start menu folder resolved before UAC elevation.

.PARAMETER SettingsKey
    Internal. Settings registry key resolved before UAC elevation.

.PARAMETER UninstallKey
    Internal. Uninstall registry key resolved before UAC elevation.

.PARAMETER UserSid
    Internal. SID of the original user, used to update the correct user PATH
    when the elevated process runs under different credentials.

.PARAMETER Elevated
    Internal flag used by the UAC self-elevation relaunch.

.PARAMETER SkipChecksum
    Skip SHA-256 verification against the release checksums.txt.

.PARAMETER Force
    Re-download/reinstall even when already up to date, and overwrite an
    existing config.json without asking.

.PARAMETER Domain
    DuckDNS domain to write to the config instead of prompting.

.PARAMETER Token
    DuckDNS token to write to the config instead of prompting. Note that
    command-line arguments may be visible to other processes. The token is
    validated against the DuckDNS UUID format before it is saved.

.EXAMPLE
    .\install-windows.ps1

.EXAMPLE
    .\install-windows.ps1 -InstallDir 'C:\Program Files\DDNS-Updater' -Force
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update', 'Uninstall', 'Run')]
    [string]$Action = 'Install',

    [string]$InstallDir,

    [string]$DataDir,

    [switch]$NoPath,

    [switch]$NoService,

    [switch]$SkipChecksum,

    [switch]$Force,

    [string]$Domain,

    [string]$Token,

    [string]$StartMenuFolder,

    [string]$SettingsKey,

    [string]$UninstallKey,

    [string]$UserSid,

    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 renders a progress bar for every chunk of a download,
# which can make Invoke-WebRequest many times slower. Disable it for this process.
$ProgressPreference = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT') {
    throw 'This installer targets Windows only.'
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning 'Could not force TLS 1.2; continuing with the system default.'
}

$script:RepoOwner = 'qdm12'
$script:RepoName = 'ddns-updater'
$script:LatestReleaseUrl = "https://api.github.com/repos/$script:RepoOwner/$script:RepoName/releases/latest"
$script:AppName = 'DDNS Updater'
$script:InstallerVersion = '1.2.0'
$script:ExeName = 'ddns-updater.exe'
$script:InstallerName = 'DDNS-Updater-Install.ps1'
$script:PowerShellExe = (Get-Process -Id $PID).Path
if (-not $script:PowerShellExe) {
    $script:PowerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-InstallDirectory {
    if ($InstallDir) {
        return [IO.Path]::GetFullPath($InstallDir)
    }
    $saved = Get-ItemProperty -Path $script:SettingsKey -Name InstallDir -ErrorAction SilentlyContinue
    if ($saved -and $saved.InstallDir) {
        return $saved.InstallDir
    }
    $nearbyExe = Join-Path $PSScriptRoot $script:ExeName
    if (Test-Path -LiteralPath $nearbyExe) {
        return $PSScriptRoot
    }
    return Join-Path $env:LOCALAPPDATA 'Programs\DDNS-Updater'
}

function Request-Elevation {
    if ($Elevated) {
        throw 'Administrator privileges are required to manage the Windows service. Run PowerShell as Administrator, or use -NoService to skip the service.'
    }

    # Forward the already-resolved per-user paths so the elevated process does
    # not pick up a different user's profile when UAC uses another account.
    $forwardedArguments = [System.Collections.Generic.List[string]]::new()
    $forwardedArguments.Add(('-Action {0}' -f $Action))
    $forwardedArguments.Add(('-InstallDir "{0}"' -f $script:InstallDir))
    $forwardedArguments.Add(('-DataDir "{0}"' -f $script:DataDir))
    $forwardedArguments.Add(('-StartMenuFolder "{0}"' -f $script:StartMenuFolder))
    $forwardedArguments.Add(('-SettingsKey "{0}"' -f $script:SettingsKey))
    $forwardedArguments.Add(('-UninstallKey "{0}"' -f $script:UninstallKey))
    $forwardedArguments.Add(('-UserSid "{0}"' -f $script:UserSid))
    if ($NoPath) { $forwardedArguments.Add('-NoPath') }
    if ($NoService) { $forwardedArguments.Add('-NoService') }
    if ($SkipChecksum) { $forwardedArguments.Add('-SkipChecksum') }
    if ($Force) { $forwardedArguments.Add('-Force') }
    if ($Domain) { $forwardedArguments.Add(('-Domain "{0}"' -f $Domain)) }
    if ($Token) { $forwardedArguments.Add(('-Token "{0}"' -f $Token)) }
    $forwardedArguments.Add('-Elevated')

    $elevationArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $PSCommandPath, ($forwardedArguments -join ' ')
    Write-Host 'Requesting administrator privileges to manage the Windows service ...'
    try {
        $elevatedProcess = Start-Process -FilePath $script:PowerShellExe -ArgumentList $elevationArguments -Verb RunAs -Wait -PassThru
    } catch {
        throw 'Administrator privileges are required to manage the Windows service, and the UAC prompt was declined. Re-run with -NoService to install without a service.'
    }
    if ($null -ne $elevatedProcess.ExitCode -and $elevatedProcess.ExitCode -ne 0) {
        throw "The elevated install failed with exit code $($elevatedProcess.ExitCode). Check the output in the elevated window for details."
    }
    exit 0
}

# Resolve all per-user locations before elevating. If a standard user approves
# UAC with different credentials, the elevated process runs as that admin and
# its APPDATA, LOCALAPPDATA and HKCU would otherwise point to the wrong profile.
if (-not $UserSid) {
    $UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
if (-not $SettingsKey) { $SettingsKey = 'HKCU:\Software\DDNS-Updater' }
if (-not $UninstallKey) { $UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DDNS-Updater' }
# Anchor registry keys to the original user's SID. Passing a literal HKCU: path
# through elevation would resolve to the admin's hive instead of the user's.
if ($SettingsKey -match '^HKCU:\\(.*)$') {
    $SettingsKey = "Registry::HKEY_USERS\$UserSid\$($Matches[1])"
}
if ($UninstallKey -match '^HKCU:\\(.*)$') {
    $UninstallKey = "Registry::HKEY_USERS\$UserSid\$($Matches[1])"
}
if (-not $StartMenuFolder) {
    $StartMenuFolder = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DDNS Updater'
}
$script:SettingsKey = $SettingsKey
$script:UninstallKey = $UninstallKey
$script:StartMenuFolder = $StartMenuFolder
$script:UserSid = $UserSid
# In the elevated process HKCU is the admin's hive, so target the original
# user's Environment key directly when changing their PATH.
$script:UserEnvironmentKey = if ($Elevated) { "Registry::HKEY_USERS\$UserSid\Environment" } else { $null }

$script:InstallDir = Resolve-InstallDirectory
if ($DataDir) {
    $script:DataDir = [IO.Path]::GetFullPath($DataDir)
} else {
    $script:DataDir = Join-Path $script:InstallDir 'data'
}
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:ExePath = Join-Path $script:InstallDir $script:ExeName
$script:InstalledScript = Join-Path $script:InstallDir $script:InstallerName

$managesService = ($Action -eq 'Uninstall') -or
    (($Action -eq 'Install' -or $Action -eq 'Update') -and -not $NoService)
if ($managesService -and -not (Test-IsAdministrator)) {
    Request-Elevation
}

$script:ServiceId = 'DDNSUpdater'
$script:ServiceDisplayName = 'DDNS Updater'
$script:ServiceExePath = Join-Path $script:InstallDir 'ddns-updater-service.exe'
$script:ServiceConfigPath = Join-Path $script:InstallDir 'ddns-updater-service.xml'
$script:ServiceLogDir = Join-Path $script:InstallDir 'logs'
$script:WinSwVersion = '2.12.0'
$script:WinSwDownloadBase = "https://github.com/winsw/winsw/releases/download/v$script:WinSwVersion"
$script:WinSwHashes = @{
    'WinSW-x64.exe' = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'
    'WinSW-x86.exe' = '0c21327463a43a61f2efb227ec4afd2467fde91618cc725148c1099001ca91ae'
}

$programFilesPaths = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
foreach ($programFilesPath in $programFilesPaths) {
    if (($script:InstallDir).StartsWith($programFilesPath, [StringComparison]::OrdinalIgnoreCase) -and
        -not (Test-IsAdministrator)) {
        throw "Installing under '$programFilesPath' requires an elevated PowerShell. Run as Administrator or omit -InstallDir."
    }
}

function Get-LatestRelease {
    $headers = @{
        'User-Agent' = 'ddns-updater-windows-installer'
        'Accept'     = 'application/vnd.github+json'
    }
    return Invoke-RestMethod -Uri $script:LatestReleaseUrl -Headers $headers
}

function Get-TargetArchitecture {
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) {
        $architecture = $env:PROCESSOR_ARCHITEW6432
    }
    switch ($architecture) {
        'AMD64' { return 'amd64' }
        'x86' { return '386' }
        'ARM64' { return 'arm64' }
        default { throw "Unsupported Windows architecture '$architecture'." }
    }
}

function Get-ServiceWrapperAssetInfo {
    $architecture = Get-TargetArchitecture
    # WinSW has no ARM64 build; the x64 build runs under Windows ARM64 emulation.
    $assetName = if ($architecture -eq '386') { 'WinSW-x86.exe' } else { 'WinSW-x64.exe' }
    return @{
        Name         = $assetName
        Url          = "$script:WinSwDownloadBase/$assetName"
        ExpectedHash = $script:WinSwHashes[$assetName]
    }
}

function Save-ServiceWrapper {
    $assetInfo = Get-ServiceWrapperAssetInfo
    $temporaryWrapper = Join-Path $script:InstallDir ('.ddns-updater-service-{0}.exe' -f [guid]::NewGuid().ToString('N'))
    try {
        Write-Host "Downloading the service wrapper ($($assetInfo.Name)) ..."
        Invoke-WebRequest -Uri $assetInfo.Url -OutFile $temporaryWrapper -UseBasicParsing
        if (-not $SkipChecksum) {
            $actualHash = (Get-FileHash -LiteralPath $temporaryWrapper -Algorithm SHA256).Hash
            if ($actualHash -ine $assetInfo.ExpectedHash) {
                throw "Service wrapper SHA-256 mismatch. Expected $($assetInfo.ExpectedHash) but got $actualHash."
            }
        }
        Move-Item -LiteralPath $temporaryWrapper -Destination $script:ServiceExePath -Force
    } catch {
        Remove-Item -LiteralPath $temporaryWrapper -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Grant-ServiceAccountPermissions {
    & icacls $script:InstallDir '/grant' 'SYSTEM:(OI)(CI)F' '/T' '/Q' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Could not grant SYSTEM access to the install directory; the service may not be able to save updates.json.'
    }
}

function New-ServiceWrapperConfig {
    $runArguments = '--datadir "{0}" --config-filepath "{1}"' -f $script:DataDir, $script:ConfigPath
    $escapedArguments = [System.Security.SecurityElement]::Escape($runArguments)
    $escapedLogPath = [System.Security.SecurityElement]::Escape($script:ServiceLogDir)
    $configXml = @"
<?xml version="1.0" encoding="utf-8"?>
<service>
  <id>$script:ServiceId</id>
  <name>$($script:ServiceDisplayName)</name>
  <description>Keeps the DuckDNS records updated with this computer's public IP address.</description>
  <executable>%BASE%\$script:ExeName</executable>
  <arguments>$escapedArguments</arguments>
  <workingdirectory>%BASE%</workingdirectory>
  <logpath>$escapedLogPath</logpath>
  <log mode="roll" />
  <onfailure action="restart" delay="10 sec" />
  <resetfailure>1 hour</resetfailure>
  <stoptimeout>10sec</stoptimeout>
  <startmode>Automatic</startmode>
</service>
"@
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($script:ServiceConfigPath, $configXml, $utf8WithoutBom)
}

function Get-ManagedService {
    return Get-Service -Name $script:ServiceId -ErrorAction SilentlyContinue
}

function Invoke-ServiceWrapperCommand {
    param([ValidateSet('install', 'uninstall', 'start', 'stop')][string]$Command)

    if (-not (Test-Path -LiteralPath $script:ServiceExePath)) {
        return @{ ExitCode = 1; Output = 'The service wrapper executable is missing.' }
    }

    Push-Location -LiteralPath $script:InstallDir
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawOutput = & $script:ServiceExePath $Command 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
        Pop-Location
    }
    return @{ ExitCode = $exitCode; Output = $rawOutput.Trim() }
}

function Stop-BackgroundService {
    $service = Get-ManagedService
    if (-not $service) {
        return
    }
    if ($service.Status -eq 'Running') {
        Write-Host "Stopping the $($script:ServiceDisplayName) service ..."
        $result = Invoke-ServiceWrapperCommand -Command 'stop'
        if ($result.ExitCode -ne 0) {
            Stop-Service -Name $script:ServiceId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-BackgroundService {
    $service = Get-ManagedService
    if (-not $service) {
        Write-Warning 'The Windows service is not installed.'
        return
    }
    if ($service.Status -eq 'Running') {
        return
    }
    $result = Invoke-ServiceWrapperCommand -Command 'start'
    if ($result.ExitCode -ne 0) {
        Start-Service -Name $script:ServiceId -ErrorAction Stop
    }
    $startedService = Get-ManagedService
    if (-not $startedService -or $startedService.Status -ne 'Running') {
        Write-Warning "The service did not reach the Running state. Check '$($script:ServiceLogDir)' for details."
        return
    }
    Write-Host "Started the $($script:ServiceDisplayName) service."
}

function Remove-ManagedServiceWithSc {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & sc.exe delete $script:ServiceId 2>&1
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

function Install-BackgroundService {
    Write-Host 'Configuring the Windows background service ...'
    if (Get-ManagedService) {
        Stop-BackgroundService
        $null = Invoke-ServiceWrapperCommand -Command 'uninstall'
        if (Get-ManagedService) {
            Remove-ManagedServiceWithSc
        }
    }

    Save-ServiceWrapper
    Grant-ServiceAccountPermissions
    New-ServiceWrapperConfig

    $installResult = Invoke-ServiceWrapperCommand -Command 'install'
    if (-not (Get-ManagedService)) {
        throw "Could not install the Windows service. WinSW output: $($installResult.Output)"
    }
    Set-Service -Name $script:ServiceId -StartupType Automatic -ErrorAction SilentlyContinue
    Start-BackgroundService
    Write-Host "Service '$($script:ServiceDisplayName)' installed with Automatic start."
}

function Uninstall-BackgroundService {
    if (-not (Get-ManagedService)) {
        return
    }
    Write-Host "Removing the $($script:ServiceDisplayName) service ..."
    Stop-BackgroundService
    $null = Invoke-ServiceWrapperCommand -Command 'uninstall'
    if (Get-ManagedService) {
        Remove-ManagedServiceWithSc
    }
    if (Get-ManagedService) {
        Write-Warning "Could not remove the service '$($script:ServiceId)'. Remove it manually with: sc.exe delete $($script:ServiceId)"
    }
}

function Get-ReleaseAssetInfo {
    param($Release, [string]$Architecture)

    $pattern = '^ddns-updater_.+_windows_' + [regex]::Escape($Architecture) + '\.exe$'
    $executable = $Release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $executable) {
        throw "No Windows $Architecture executable found in release $($Release.tag_name)."
    }
    $checksums = $Release.assets | Where-Object { $_.name -eq 'checksums.txt' } | Select-Object -First 1

    return @{
        Executable = $executable
        Checksums  = $checksums
        Version    = $Release.tag_name
    }
}

function Save-ReleaseExecutable {
    param($AssetInfo, [string]$DestinationDirectory)

    $temporaryExe = Join-Path $DestinationDirectory ('.ddns-updater-{0}.exe' -f [guid]::NewGuid().ToString('N'))
    try {
        Write-Host "Downloading $($AssetInfo.Executable.name) ..."
        Invoke-WebRequest -Uri $AssetInfo.Executable.browser_download_url -OutFile $temporaryExe -UseBasicParsing

        if (-not $SkipChecksum) {
            if (-not $AssetInfo.Checksums) {
                throw 'checksums.txt is missing from the release; use -SkipChecksum to bypass verification.'
            }
            $checksumContent = (Invoke-WebRequest -Uri $AssetInfo.Checksums.browser_download_url -UseBasicParsing).Content
            # Windows PowerShell 5.1 returns byte[] for application/octet-stream responses,
            # which is what GitHub serves release assets as. PowerShell 7 returns a string.
            if ($checksumContent -is [byte[]]) {
                $checksumText = [Text.Encoding]::UTF8.GetString($checksumContent)
            } else {
                $checksumText = [string]$checksumContent
            }
            $entryPattern = '\s' + [regex]::Escape($AssetInfo.Executable.name) + '$'
            $entry = ($checksumText -split "`r?`n" | Where-Object { $_.TrimEnd() -match $entryPattern } | Select-Object -First 1)
            if (-not $entry) {
                throw "No checksum entry found for $($AssetInfo.Executable.name)."
            }
            $expectedHash = ($entry -split '\s+')[0]
            $actualHash = (Get-FileHash -LiteralPath $temporaryExe -Algorithm SHA256).Hash
            if ($actualHash -ine $expectedHash) {
                throw "SHA-256 mismatch. Expected $expectedHash but got $actualHash."
            }
            Write-Host 'SHA-256 checksum verified.'
        }

        return $temporaryExe
    } catch {
        Remove-Item -LiteralPath $temporaryExe -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Read-DuckDnsDomain {
    param([string]$InitialValue)

    while ($true) {
        if ($InitialValue) {
            $rawValue = $InitialValue
        } else {
            $rawValue = Read-Host 'DuckDNS domain (e.g. myhome.duckdns.org, comma-separate for multiple)'
        }
        $InitialValue = $null

        if ([string]::IsNullOrWhiteSpace($rawValue)) {
            Write-Warning 'A domain is required.'
            continue
        }

        $parts = $rawValue -split ',' | ForEach-Object { $_.Trim().TrimEnd('.') } | Where-Object { $_ }
        $normalized = foreach ($part in $parts) {
            if ($part -match '\.duckdns\.org$') { $part } else { "$part.duckdns.org" }
        }
        $domainPattern = '^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.duckdns\.org$'
        $invalid = $normalized | Where-Object { $_ -notmatch $domainPattern }
        if ($invalid) {
            Write-Warning ('Invalid DuckDNS domain: {0}' -f ($invalid -join ', '))
            continue
        }
        return ($normalized -join ',')
    }
}

function Read-DuckDnsToken {
    param([string]$InitialValue)

    # DuckDNS tokens are lowercase UUIDs and upstream validates this format.
    # Check it here so a failed paste cannot be written to config.json.
    $tokenPattern = '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
    $formatHint = 'Expected a 36-character DuckDNS token, for example xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (hex digits and hyphens). Check that the paste completed.'
    $wasProvided = $PSBoundParameters.ContainsKey('InitialValue')

    while ($true) {
        if ($wasProvided) {
            $value = $InitialValue
        } else {
            # Echo the input so the user can see immediately whether a paste
            # worked. -AsSecureString masked a literal Ctrl+V (U+0016) as
            # asterisks and let that single character be saved as the token.
            $value = Read-Host 'DuckDNS token'
        }
        $InitialValue = $null

        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($wasProvided) { throw 'The DuckDNS token parameter is empty.' }
            Write-Warning 'A token is required.'
            continue
        }

        $value = $value.Trim().ToLowerInvariant()
        if ($value -notmatch $tokenPattern) {
            if ($wasProvided) { throw "The DuckDNS token parameter is invalid. $formatHint" }
            Write-Warning "That does not look like a DuckDNS token. $formatHint"
            continue
        }
        return $value
    }
}

function New-DdnsConfigFile {
    param([string]$ConfigFilePath)

    if (Test-Path -LiteralPath $ConfigFilePath) {
        if (-not $Force) {
            $answer = Read-Host "Configuration already exists at $ConfigFilePath. Overwrite? [y/N]"
            if ($answer -notmatch '^[Yy]') {
                Write-Host 'Keeping the existing configuration.'
                return $false
            }
        }
        $backupPath = '{0}.bak-{1}' -f $ConfigFilePath, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $ConfigFilePath -Destination $backupPath -Force
        Write-Host "Backed up the previous configuration to $backupPath"
    }

    $selectedDomain = Read-DuckDnsDomain -InitialValue $Domain
    $selectedToken = Read-DuckDnsToken -InitialValue $Token
    # Each DuckDNS setting maintains a single record family, so use one entry for
    # IPv4 (A) and one for IPv6 (AAAA) to keep both records updated.
    $configObject = [ordered]@{
        settings = @(
            [ordered]@{
                provider   = 'duckdns'
                domain     = $selectedDomain
                token      = $selectedToken
                ip_version = 'ipv4'
            }
            [ordered]@{
                provider    = 'duckdns'
                domain      = $selectedDomain
                token       = $selectedToken
                ip_version  = 'ipv6'
                ipv6_suffix = ''
            }
        )
    }
    $json = $configObject | ConvertTo-Json -Depth 10
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($ConfigFilePath, $json + [Environment]::NewLine, $utf8WithoutBom)
    Write-Host "Wrote the DuckDNS configuration to $ConfigFilePath"
    return $true
}

function New-Shortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments,
        [string]$Description,
        [string]$IconLocation,
        [string]$WorkingDirectory
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    $shortcut.Description = $Description
    if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
    if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
    $shortcut.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

function New-ProgramShortcuts {
    [IO.Directory]::CreateDirectory($script:StartMenuFolder) | Out-Null
    $shortcutLocations = @($script:StartMenuFolder)

    $runArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Run' -f $script:InstalledScript
    $updateArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Update' -f $script:InstalledScript
    $uninstallArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Uninstall' -f $script:InstalledScript

    foreach ($location in $shortcutLocations) {
        New-Shortcut -ShortcutPath (Join-Path $location 'DDNS Updater.lnk') `
            -TargetPath $script:PowerShellExe -Arguments $runArguments `
            -Description 'Run DDNS Updater and open its web UI' -IconLocation "$($script:ExePath),0" `
            -WorkingDirectory $script:InstallDir

        New-Shortcut -ShortcutPath (Join-Path $location 'Update DDNS Updater.lnk') `
            -TargetPath $script:PowerShellExe -Arguments $updateArguments `
            -Description 'Update DDNS Updater to the latest release' `
            -IconLocation "$($script:PowerShellExe),0"

        New-Shortcut -ShortcutPath (Join-Path $location 'Uninstall DDNS Updater.lnk') `
            -TargetPath $script:PowerShellExe -Arguments $uninstallArguments `
            -Description 'Uninstall DDNS Updater' `
            -IconLocation "$($script:PowerShellExe),0"
    }
}

function Remove-ProgramShortcuts {
    $shortcutNames = @('DDNS Updater.lnk', 'Update DDNS Updater.lnk', 'Uninstall DDNS Updater.lnk')
    # Keep Desktop in the removal list so updates/uninstalls clean up shortcuts from older installs.
    $shortcutLocations = @($script:StartMenuFolder, [Environment]::GetFolderPath('Desktop'))
    foreach ($location in $shortcutLocations) {
        foreach ($shortcutName in $shortcutNames) {
            $shortcutPath = Join-Path $location $shortcutName
            if (Test-Path -LiteralPath $shortcutPath) {
                Remove-Item -LiteralPath $shortcutPath -Force
            }
        }
    }
    if ((Test-Path -LiteralPath $script:StartMenuFolder) -and
        -not (Get-ChildItem -LiteralPath $script:StartMenuFolder -Force)) {
        Remove-Item -LiteralPath $script:StartMenuFolder -Force
    }
}

function Register-ProgramMetadata {
    param([string]$Version, [string]$ExecutablePath)

    New-Item -Path $script:SettingsKey -Force | Out-Null
    Set-ItemProperty -Path $script:SettingsKey -Name InstallDir -Value $script:InstallDir
    Set-ItemProperty -Path $script:SettingsKey -Name DataDir -Value $script:DataDir

    New-Item -Path $script:UninstallKey -Force | Out-Null
    $uninstallCommand = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Action Uninstall' -f $script:PowerShellExe, $script:InstalledScript
    $metadata = [ordered]@{
        DisplayName         = $script:AppName
        DisplayVersion      = $Version.TrimStart([char]'v')
        Publisher           = 'qdm12'
        DisplayIcon         = "$ExecutablePath,0"
        InstallLocation     = $script:InstallDir
        URLInfoAbout        = 'https://github.com/qdm12/ddns-updater'
        UninstallString     = $uninstallCommand
        QuietUninstallString = $uninstallCommand
        EstimatedSize       = [int]((Get-Item -LiteralPath $ExecutablePath).Length / 1KB)
    }
    foreach ($name in $metadata.Keys) {
        Set-ItemProperty -Path $script:UninstallKey -Name $name -Value $metadata[$name]
    }
}

function Unregister-ProgramMetadata {
    Remove-Item -Path $script:UninstallKey -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $script:SettingsKey -Force -ErrorAction SilentlyContinue
}

function Get-InstalledVersion {
    $entry = Get-ItemProperty -Path $script:UninstallKey -ErrorAction SilentlyContinue
    if ($entry -and $entry.DisplayVersion) {
        return $entry.DisplayVersion
    }
    return ''
}

function Get-TargetUserPath {
    if ($script:UserEnvironmentKey) {
        return (Get-ItemProperty -LiteralPath $script:UserEnvironmentKey -Name Path -ErrorAction SilentlyContinue).Path
    }
    return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-TargetUserPath {
    param([string]$Value)

    if ($script:UserEnvironmentKey) {
        if (-not (Test-Path -LiteralPath $script:UserEnvironmentKey)) {
            New-Item -Path $script:UserEnvironmentKey -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $script:UserEnvironmentKey -Name Path -Value $Value
    } else {
        [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
    }
}

function Add-InstallDirectoryToUserPath {
    $userPath = Get-TargetUserPath
    if ([string]::IsNullOrWhiteSpace($userPath)) { $userPath = '' }
    $entries = @($userPath -split ';' | Where-Object { $_.Trim() })
    if ($entries -notcontains $script:InstallDir) {
        $entries += $script:InstallDir
        Set-TargetUserPath -Value ($entries -join ';')
        Write-Host 'Added the install directory to your user PATH (new terminals only).'
    }
}

function Remove-InstallDirectoryFromUserPath {
    $userPath = Get-TargetUserPath
    if ([string]::IsNullOrWhiteSpace($userPath)) { return }
    $entries = @($userPath -split ';' | Where-Object { $_.Trim() -and $_ -ne $script:InstallDir })
    Set-TargetUserPath -Value ($entries -join ';')
}

function Stop-DdnsProcess {
    $runningProcesses = Get-Process -Name 'ddns-updater' -ErrorAction SilentlyContinue
    if (-not $runningProcesses) {
        return $false
    }
    Write-Host 'Stopping the running DDNS Updater ...'
    $runningProcesses | Stop-Process -Force
    $runningProcesses | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    return $true
}

function Start-DdnsProcess {
    $runArguments = '--datadir "{0}" --config-filepath "{1}"' -f $script:DataDir, $script:ConfigPath
    Start-Process -FilePath $script:ExePath -ArgumentList $runArguments -WorkingDirectory $script:InstallDir | Out-Null
    Write-Host 'Restarted DDNS Updater.'
}

function Invoke-RunShortcut {
    $service = Get-ManagedService
    if (-not $service) {
        Start-Process -FilePath $script:ExePath -ArgumentList ('--datadir "{0}" --config-filepath "{1}"' -f $script:DataDir, $script:ConfigPath) -WorkingDirectory $script:InstallDir | Out-Null
        Write-Host 'DDNS Updater started. Web UI: http://localhost:8000'
        return
    }

    if ($service.Status -ne 'Running') {
        try {
            Start-Service -Name $script:ServiceId -ErrorAction Stop
        } catch {
            Write-Warning "The service is stopped and could not be started: $($_.Exception.Message)"
            Write-Warning "Start it from an elevated PowerShell with: Start-Service $($script:ServiceId)"
            return
        }
    }
    Start-Process 'http://localhost:8000'
    Write-Host 'DDNS Updater is running as a service; opened the web UI.'
}

function Start-DeferredCleanup {
    param([string]$Path, [int]$ProcessIdToWait)

    $cleanupPath = Join-Path ([IO.Path]::GetTempPath()) ('ddns-updater-cleanup-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
    $cleanupBody = @'
param([int]$TargetPid, [string]$Path)
$processToWait = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
if ($null -ne $processToWait) {
    $processToWait.WaitForExit()
}
Start-Sleep -Milliseconds 750
Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
'@
    [IO.File]::WriteAllText($cleanupPath, $cleanupBody, [System.Text.UTF8Encoding]::new($false))
    $cleanupArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -TargetPid {1} -Path "{2}"' -f $cleanupPath, $ProcessIdToWait, $Path
    Start-Process -FilePath $script:PowerShellExe -ArgumentList $cleanupArguments | Out-Null
}

function Install-DdnsUpdater {
    Write-Host "$($script:AppName) installer v$($script:InstallerVersion)"
    Write-Host "Installing $($script:AppName) into $($script:InstallDir)"
    [IO.Directory]::CreateDirectory($script:InstallDir) | Out-Null
    [IO.Directory]::CreateDirectory($script:DataDir) | Out-Null

    $release = Get-LatestRelease
    $architecture = Get-TargetArchitecture
    $assetInfo = Get-ReleaseAssetInfo -Release $release -Architecture $architecture
    if (Get-ManagedService) {
        Stop-BackgroundService
    }
    $temporaryExe = Save-ReleaseExecutable -AssetInfo $assetInfo -DestinationDirectory $script:InstallDir
    try {
        if (Test-Path -LiteralPath $script:ExePath) {
            $null = Stop-DdnsProcess
        }
        Move-Item -LiteralPath $temporaryExe -Destination $script:ExePath -Force
    } catch {
        Remove-Item -LiteralPath $temporaryExe -Force -ErrorAction SilentlyContinue
        throw
    }

    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($script:InstalledScript)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledScript -Force
    }

    New-DdnsConfigFile -ConfigFilePath $script:ConfigPath
    if ($NoService) {
        Uninstall-BackgroundService
    } else {
        Install-BackgroundService
    }
    Register-ProgramMetadata -Version $assetInfo.Version -ExecutablePath $script:ExePath
    New-ProgramShortcuts
    if (-not $NoPath) {
        Add-InstallDirectoryToUserPath
    }

    Write-Host ''
    Write-Host "Installed $($script:AppName) $($assetInfo.Version) ($architecture)."
    if ($NoService) {
        Write-Host 'Use the "DDNS Updater" shortcut to run it. Web UI: http://localhost:8000'
    } else {
        Write-Host "The '$($script:ServiceDisplayName)' service is running and starts automatically at boot."
        Write-Host 'Use the "DDNS Updater" shortcut to open the web UI: http://localhost:8000'
    }
}

function Update-DdnsUpdater {
    Write-Host "$($script:AppName) installer v$($script:InstallerVersion)"
    if (-not (Test-Path -LiteralPath $script:ExePath)) {
        throw "DDNS Updater is not installed at $($script:InstallDir). Run the installer first."
    }

    # Refresh the installed copy of this script so the Start menu shortcuts run
    # the current logic. Guard against copying the file onto itself when Update
    # is invoked through the installed script.
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($script:InstalledScript)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledScript -Force
    }

    $release = Get-LatestRelease
    $architecture = Get-TargetArchitecture
    $assetInfo = Get-ReleaseAssetInfo -Release $release -Architecture $architecture
    $latestVersion = $assetInfo.Version.TrimStart([char]'v')
    $installedVersion = Get-InstalledVersion
    $updateBinary = ($installedVersion -ne $latestVersion) -or $Force

    # Offer to regenerate the config so changes to config generation (such as
    # adding the IPv6 record) can be applied to an existing install.
    $configUpdated = New-DdnsConfigFile -ConfigFilePath $script:ConfigPath

    if (-not $updateBinary -and -not $configUpdated) {
        Write-Host "Already up to date ($installedVersion). Use -Force to reinstall."
        return
    }

    $managedService = Get-ManagedService
    $serviceWasRunning = ($null -ne $managedService -and $managedService.Status -eq 'Running')
    if ($managedService) {
        Stop-BackgroundService
    }
    $wasRunning = Stop-DdnsProcess

    if ($updateBinary) {
        $temporaryExe = Save-ReleaseExecutable -AssetInfo $assetInfo -DestinationDirectory $script:InstallDir
        try {
            Move-Item -LiteralPath $temporaryExe -Destination $script:ExePath -Force
        } catch {
            Remove-Item -LiteralPath $temporaryExe -Force -ErrorAction SilentlyContinue
            throw
        }
        Write-Host "Updated $($script:AppName) to $latestVersion."
        if ($managedService) {
            New-ServiceWrapperConfig
        } elseif (-not $NoService) {
            Install-BackgroundService
            $managedService = Get-ManagedService
        }
    }

    # Restart so the new binary and/or regenerated config is picked up.
    if ($serviceWasRunning) {
        Start-BackgroundService
    } elseif ($wasRunning -and -not $managedService) {
        Start-DdnsProcess
    }

    Register-ProgramMetadata -Version $assetInfo.Version -ExecutablePath $script:ExePath
    New-ProgramShortcuts
}

function Uninstall-DdnsUpdater {
    Uninstall-BackgroundService
    $null = Stop-DdnsProcess
    Remove-ProgramShortcuts
    Unregister-ProgramMetadata
    Remove-InstallDirectoryFromUserPath

    if (Test-Path -LiteralPath $script:InstallDir) {
        Remove-Item -LiteralPath $script:InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:InstallDir) {
            Start-DeferredCleanup -Path $script:InstallDir -ProcessIdToWait $PID
            Write-Host 'Remaining files will be removed once this window closes.'
        }
    }
    Write-Host "$($script:AppName) has been uninstalled."
}

switch ($Action) {
    'Install' { Install-DdnsUpdater }
    'Update' { Update-DdnsUpdater }
    'Uninstall' { Uninstall-DdnsUpdater }
    'Run' { Invoke-RunShortcut }
}
