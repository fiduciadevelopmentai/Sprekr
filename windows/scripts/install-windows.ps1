[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\Sprekr'),
    [ValidateSet('Release')][string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
& (Join-Path $PSScriptRoot 'doctor-windows.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Start de Sprekr-installer niet als administrator. De installatie hoort volledig onder je eigen %LOCALAPPDATA%.'
}

$allowedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs')).TrimEnd('\') + '\'
$destinationFull = [IO.Path]::GetFullPath($Destination)
if (-not ($destinationFull + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "De installatiebestemming moet onder $allowedRoot staan."
}

$staging = Join-Path $env:TEMP ("Sprekr-install-" + [guid]::NewGuid().ToString('N'))
$backup = "$destinationFull.previous"
try {
    Push-Location $windowsRoot
    try {
        dotnet restore .\Sprekr.sln --locked-mode --configfile .\NuGet.Config
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        dotnet publish .\src\Sprekr.Windows.App\Sprekr.Windows.App.csproj --configuration $Configuration --runtime win-x64 --self-contained true --no-restore --output $staging
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } finally { Pop-Location }

    if (Test-Path $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    if (Test-Path $destinationFull) { Move-Item -LiteralPath $destinationFull -Destination $backup }
    New-Item -ItemType Directory -Path (Split-Path $destinationFull -Parent) -Force | Out-Null
    Move-Item -LiteralPath $staging -Destination $destinationFull

    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $shortcutPath = Join-Path $startMenu 'Sprekr.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $destinationFull 'Sprekr.exe'
    $shortcut.WorkingDirectory = $destinationFull
    $shortcut.Description = 'Sprekr — offline spraak-naar-tekst'
    $shortcut.Save()

    if (Test-Path $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    Write-Host "Sprekr is geïnstalleerd in $destinationFull" -ForegroundColor Green
    Write-Host 'Modellen, History, Dictionary en instellingen blijven apart onder %LOCALAPPDATA%\Sprekr.'
} catch {
    if (-not (Test-Path $destinationFull) -and (Test-Path $backup)) { Move-Item -LiteralPath $backup -Destination $destinationFull }
    throw
} finally {
    if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
