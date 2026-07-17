[CmdletBinding()]
param(
    [switch]$PurgeData,
    [string]$ConfirmPurge
)

$ErrorActionPreference = 'Stop'
$installRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\Sprekr'))
$dataRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Sprekr'))
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Sprekr.lnk'

if (Test-Path $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
if (Test-Path $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Sprekr' -ErrorAction SilentlyContinue

if ($PurgeData) {
    if ($ConfirmPurge -cne 'Sprekr') {
        throw 'Purge geweigerd. Gebruik -PurgeData -ConfirmPurge Sprekr om modellen, instellingen, versleutelde History/Dictionary en DPAPI-sleutels permanent te verwijderen.'
    }
    if (Test-Path $dataRoot) { Remove-Item -LiteralPath $dataRoot -Recurse -Force }
    Write-Host 'Sprekr en de lokale Windows-gebruikersdata zijn permanent verwijderd.' -ForegroundColor Yellow
} else {
    Write-Host 'Sprekr is verwijderd. Lokale modellen, instellingen, History, Dictionary en sleutels zijn behouden.' -ForegroundColor Green
}
