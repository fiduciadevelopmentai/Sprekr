[CmdletBinding()]
param([ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug')

$ErrorActionPreference = 'Stop'
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
& (Join-Path $PSScriptRoot 'doctor-windows.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Push-Location $windowsRoot
try {
    dotnet restore .\Sprekr.sln --locked-mode --configfile .\NuGet.Config
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dotnet run --project .\src\Sprekr.Windows.App\Sprekr.Windows.App.csproj --configuration $Configuration --no-restore
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
