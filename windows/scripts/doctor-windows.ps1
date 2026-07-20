[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$failures = 0

function Test-Requirement {
    param([string]$Name, [bool]$Passed, [string]$Detail, [string]$Recovery)
    if ($Passed) {
        Write-Host "[OK]   $Name - $Detail" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Name - $Detail" -ForegroundColor Red
        Write-Host "       $Recovery" -ForegroundColor Yellow
        $script:failures++
    }
}

Write-Host 'Sprekr Windows doctor (alleen status; geen gebruikersinhoud)' -ForegroundColor Cyan

$isWindows11 = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and [Environment]::OSVersion.Version.Build -ge 22000
Test-Requirement 'Windows 11' $isWindows11 ([Environment]::OSVersion.VersionString) 'Gebruik een actuele Windows 11-versie. Windows 10 wordt niet ondersteund.'

$isX64 = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::X64
Test-Requirement 'x64-architectuur' $isX64 ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) 'Gebruik Windows 11 x64. ARM64 en x86 worden niet ondersteund in v1.'

$sdkVersion = ''
try { $sdkVersion = (& dotnet --version 2>$null).Trim() } catch { }
Test-Requirement '.NET SDK 10.0.302' ($sdkVersion -eq '10.0.302') $(if ($sdkVersion) { $sdkVersion } else { 'niet gevonden' }) 'Installeer .NET SDK 10.0.302 x64 vanaf https://dotnet.microsoft.com/download/dotnet/10.0.'

$drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($env:LOCALAPPDATA).Substring(0, 1))
$freeBytes = [int64]$drive.Free
Test-Requirement 'Vrije ruimte' ($freeBytes -ge 1500000000) ("{0:N1} GB vrij" -f ($freeBytes / 1GB)) 'Maak minimaal 1,5 GB vrij op het station van %LOCALAPPDATA%.'

$privacyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
$microphoneValue = (Get-ItemProperty -Path $privacyKey -Name Value -ErrorAction SilentlyContinue).Value
$microphoneAllowed = $microphoneValue -ne 'Deny'
Test-Requirement 'Microfoontoegang' $microphoneAllowed $(if ($microphoneValue) { $microphoneValue } else { 'nog niet gekozen' }) 'Open Instellingen > Privacy en beveiliging > Microfoon en sta desktop-apps toe.'

$lockFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot '..') -Filter packages.lock.json -Recurse -ErrorAction SilentlyContinue
Test-Requirement 'NuGet-lockbestanden' ($lockFiles.Count -ge 2) ("{0} gevonden" -f $lockFiles.Count) 'Clone de volledige standaardbranch opnieuw; lockbestanden ontbreken.'

if ($failures -gt 0) {
    Write-Host "$failures vereiste(n) niet gereed." -ForegroundColor Red
    exit 1
}

Write-Host 'Windows-bronomgeving is gereed.' -ForegroundColor Green
