[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts'))

$ErrorActionPreference = 'Stop'
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$publish = Join-Path $OutputDirectory 'publish'
$zip = Join-Path $OutputDirectory 'Sprekr-windows-x64-development-unsigned.zip'

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (Test-Path $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }

Push-Location $windowsRoot
try {
    dotnet restore .\Sprekr.sln --locked-mode --configfile .\NuGet.Config
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dotnet publish .\src\Sprekr.Windows.App\Sprekr.Windows.App.csproj --configuration Release --runtime win-x64 --self-contained true --no-restore --output $publish
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally { Pop-Location }

Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$zip.sha256" -Value "$hash  $([IO.Path]::GetFileName($zip))" -Encoding ascii
Write-Host "Development-only unsigned build: $zip" -ForegroundColor Yellow
Write-Host "SHA-256: $hash"
