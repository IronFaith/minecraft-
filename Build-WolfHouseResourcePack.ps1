[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\WolfHousePackBuilder.psm1'
$configPath = Join-Path $projectRoot 'pack-sources.json'

try {
    Import-Module $modulePath -Force
    $result = Invoke-WolfHousePackBuild -ProjectRoot $projectRoot -ConfigPath $configPath

    if ($result.Changed) {
        Write-Host "Created WolfHouse resource-pack revision r$($result.Revision)."
    }
    else {
        Write-Host "No resource changes found; keeping revision r$($result.Revision)."
    }
    Write-Host "Assets: $($result.AssetCount)"
    Write-Host "ZIP: $($result.ZipPath)"
    Write-Host "SHA-1: $($result.Sha1)"
    Write-Host "SHA-256: $($result.Sha256)"
    Write-Host "Report: $($result.ReportPath)"
    Write-Host "Server template: $($result.ServerPropertiesPath)"
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
