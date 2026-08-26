Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-PackConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Pack configuration was not found: $ConfigPath"
    }

    $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    if (-not $config.packFormat) {
        throw "Pack configuration must define packFormat."
    }
    if (@($config.sources).Count -eq 0) {
        throw "Pack configuration must register at least one source."
    }
    $config
}

function Get-PackFormatMajor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackRoot
    )

    $metadataPath = Join-Path $PackRoot 'pack.mcmeta'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Resource-pack metadata was not found: $metadataPath"
    }

    $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
    if (-not $metadata.pack -or $null -eq $metadata.pack.min_format -or $null -eq $metadata.pack.max_format) {
        throw "Resource-pack metadata must define pack.min_format and pack.max_format: $metadataPath"
    }

    $minimum = [int]@($metadata.pack.min_format)[0]
    $maximum = [int]@($metadata.pack.max_format)[0]
    if ($minimum -ne $maximum) {
        throw "Resource-pack format range must target one major format: $metadataPath declares $minimum through $maximum."
    }
    $minimum
}

function Get-AssetInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Config,

        [Parameter(Mandatory = $true)]
        [string] $ProjectRoot
    )

    $resolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    $ownersByPath = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $sourceNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $inventory = New-Object 'System.Collections.Generic.List[object]'

    foreach ($source in @($Config.sources)) {
        $owner = [string]$source.name
        if ([string]::IsNullOrWhiteSpace($owner)) {
            throw "Every resource-pack source must have a name."
        }
        if (-not $sourceNames.Add($owner)) {
            throw "Resource-pack source name is registered more than once: $owner"
        }

        $sourcePath = [string]$source.path
        if ([string]::IsNullOrWhiteSpace($sourcePath)) {
            throw "Resource-pack source '$owner' must have a path."
        }
        $packRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedProjectRoot $sourcePath))
        if (-not (Test-Path -LiteralPath $packRoot -PathType Container)) {
            throw "Resource-pack source '$owner' was not found: $packRoot"
        }

        $format = Get-PackFormatMajor -PackRoot $packRoot
        if ($format -ne [int]$Config.packFormat) {
            throw "Resource-pack source '$owner' uses format $format; expected $($Config.packFormat)."
        }

        $assetsRoot = Join-Path $packRoot 'assets'
        if (-not (Test-Path -LiteralPath $assetsRoot -PathType Container)) {
            throw "Resource-pack source '$owner' has no assets directory: $assetsRoot"
        }
        $trimCharacters = [char[]]@([char]92, [char]47)
        $assetsRoot = [System.IO.Path]::GetFullPath($assetsRoot).TrimEnd($trimCharacters)

        foreach ($file in @(Get-ChildItem -LiteralPath $assetsRoot -Recurse -File | Sort-Object FullName)) {
            $relativeAssetPath = $file.FullName.Substring($assetsRoot.Length).TrimStart($trimCharacters).Replace('\', '/')
            $destinationPath = "assets/$relativeAssetPath"
            if ($ownersByPath.ContainsKey($destinationPath)) {
                $firstOwner = $ownersByPath[$destinationPath]
                throw "Asset collision at ${destinationPath}: $firstOwner and $owner both provide this path."
            }
            $ownersByPath.Add($destinationPath, $owner)

            $inventory.Add([pscustomobject]@{
                Owner = $owner
                SourcePath = $file.FullName
                RelativePath = $destinationPath
                Length = [long]$file.Length
                Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
            })
        }
    }

    $inventory.ToArray()
}

function Get-InputFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Inventory,

        [Parameter(Mandatory = $true)]
        [string] $MetadataPath,

        [Parameter(Mandatory = $true)]
        [string] $IconPath
    )

    foreach ($requiredFile in @($MetadataPath, $IconPath)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required master-pack file was not found: $requiredFile"
        }
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $metadataHash = (Get-FileHash -LiteralPath $MetadataPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $iconHash = (Get-FileHash -LiteralPath $IconPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $lines.Add("pack.mcmeta|$metadataHash")
    $lines.Add("pack.png|$iconHash")
    foreach ($item in @($Inventory | Sort-Object RelativePath, Owner)) {
        $lines.Add("$($item.RelativePath)|$($item.Owner)|$($item.Length)|$($item.Sha256)")
    }

    $payload = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        ([System.BitConverter]::ToString($algorithm.ComputeHash($payload)) -replace '-', '').ToUpperInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-ReleasePaths {
    param([string] $ProjectRoot, [int] $Revision)

    $distRoot = Join-Path $ProjectRoot 'dist'
    $baseName = "WolfHouse-ResourcePack-r$Revision"
    [pscustomobject]@{
        DistRoot = $distRoot
        BaseName = $baseName
        ZipPath = Join-Path $distRoot "$baseName.zip"
        Sha1Path = Join-Path $distRoot "$baseName.sha1"
        Sha256Path = Join-Path $distRoot "$baseName.sha256"
        ReportPath = Join-Path $distRoot "$baseName-build-report.txt"
        ServerPropertiesPath = Join-Path $distRoot "$baseName-server.properties.txt"
    }
}

function Test-ReleaseFilesExist {
    param([object] $Paths)
    foreach ($path in @($Paths.ZipPath, $Paths.Sha1Path, $Paths.Sha256Path, $Paths.ReportPath, $Paths.ServerPropertiesPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    }
    $true
}

function Remove-SafeBuildDirectory {
    param([string] $BuildDirectory, [string] $BuildRoot)

    if (-not (Test-Path -LiteralPath $BuildDirectory)) { return }
    $resolvedBuildRoot = [System.IO.Path]::GetFullPath($BuildRoot).TrimEnd([char[]]@([char]92, [char]47)) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedTarget = [System.IO.Path]::GetFullPath($BuildDirectory)
    if (-not $resolvedTarget.StartsWith($resolvedBuildRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a staging directory outside the build root: $resolvedTarget"
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}

function Test-PackArchive {
    param([string] $ZipPath, [object[]] $Inventory)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName) { [void]$entries.Add(($entry.FullName -replace '\\', '/')) }
        }
        foreach ($required in @('pack.mcmeta', 'pack.png')) {
            if (-not $entries.Contains($required)) {
                throw "Generated ZIP is missing required root file: $required"
            }
        }
        foreach ($item in $Inventory) {
            if (-not $entries.Contains($item.RelativePath)) {
                throw "Generated ZIP is missing asset: $($item.RelativePath)"
            }
        }
        foreach ($entryName in $entries) {
            if ($entryName -ne 'pack.mcmeta' -and $entryName -ne 'pack.png' -and -not $entryName.StartsWith('assets/', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Generated ZIP contains an unexpected root entry: $entryName"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function New-PackArchive {
    param([string] $StagingRoot, [string] $ZipPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $trimCharacters = [char[]]@([char]92, [char]47)
        $resolvedStagingRoot = [System.IO.Path]::GetFullPath($StagingRoot).TrimEnd($trimCharacters)
        foreach ($file in @(Get-ChildItem -LiteralPath $resolvedStagingRoot -Recurse -File | Sort-Object FullName)) {
            $entryName = $file.FullName.Substring($resolvedStagingRoot.Length).TrimStart($trimCharacters).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $file.FullName,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            )
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Write-ReleaseFiles {
    param(
        [object] $Paths,
        [object] $Config,
        [object[]] $Inventory,
        [int] $Revision,
        [string] $Fingerprint,
        [string] $Sha1,
        [string] $Sha256
    )

    $sourceCounts = @($Inventory | Group-Object Owner | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count }
    })
    $zipInfo = Get-Item -LiteralPath $Paths.ZipPath
    $reportLines = New-Object 'System.Collections.Generic.List[string]'
    $reportLines.Add("WolfHouse Resource Pack r$Revision")
    $reportLines.Add("ZIP: $($Paths.ZipPath)")
    $reportLines.Add("Size: $($zipInfo.Length) bytes")
    $reportLines.Add("Files: $($Inventory.Count) assets + 2 root files")
    foreach ($sourceCount in $sourceCounts) {
        $reportLines.Add("Source: $($sourceCount.Name) = $($sourceCount.Count) files")
    }
    $reportLines.Add("SHA-1: $Sha1")
    $reportLines.Add("SHA-256: $Sha256")
    $reportLines.Add("Input fingerprint: $Fingerprint")
    $reportLines | Set-Content -LiteralPath $Paths.ReportPath -Encoding UTF8

    $Sha1.ToLowerInvariant() | Set-Content -LiteralPath $Paths.Sha1Path -Encoding ASCII
    $Sha256.ToLowerInvariant() | Set-Content -LiteralPath $Paths.Sha256Path -Encoding ASCII

    $promptJson = [ordered]@{ text = [string]$Config.prompt; color = 'gold' } | ConvertTo-Json -Compress
    @(
        'require-resource-pack=true'
        "resource-pack=$($Config.downloadUrlMarker)"
        "resource-pack-id=$($Config.resourcePackId)"
        "resource-pack-prompt=$promptJson"
        "resource-pack-sha1=$($Sha1.ToLowerInvariant())"
    ) | Set-Content -LiteralPath $Paths.ServerPropertiesPath -Encoding UTF8

    $sourceCounts
}

function Invoke-WolfHousePackBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $resolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    $config = Read-PackConfiguration -ConfigPath $ConfigPath
    $inventory = @(Get-AssetInventory -Config $config -ProjectRoot $resolvedProjectRoot)
    $metadataPath = Join-Path $resolvedProjectRoot 'pack.mcmeta'
    $iconPath = Join-Path $resolvedProjectRoot 'pack.png'
    $fingerprint = Get-InputFingerprint -Inventory $inventory -MetadataPath $metadataPath -IconPath $iconPath

    $statePath = Join-Path $resolvedProjectRoot 'release-state.json'
    $state = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    }

    $changed = $true
    if ($state -and [string]$state.fingerprint -eq $fingerprint) {
        $revision = [int]$state.revision
        $changed = $false
    }
    elseif ($state) {
        $revision = [int]$state.revision + 1
    }
    else {
        $revision = 1
    }

    $paths = Get-ReleasePaths -ProjectRoot $resolvedProjectRoot -Revision $revision
    if (-not $changed -and (Test-ReleaseFilesExist -Paths $paths)) {
        return [pscustomobject]@{
            Changed = $false
            Revision = $revision
            ZipPath = $paths.ZipPath
            Sha1 = [string]$state.sha1
            Sha256 = [string]$state.sha256
            ReportPath = $paths.ReportPath
            ServerPropertiesPath = $paths.ServerPropertiesPath
            AssetCount = $inventory.Count
        }
    }
    if ($changed -and (Test-Path -LiteralPath $paths.ZipPath)) {
        throw "Release artifact already exists for new revision r${revision}: $($paths.ZipPath)"
    }

    New-Item -ItemType Directory -Path $paths.DistRoot -Force | Out-Null
    $buildRoot = Join-Path $resolvedProjectRoot '.build'
    New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
    $stagingRoot = Join-Path $buildRoot ("r{0}-{1}" -f $revision, [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    try {
        Copy-Item -LiteralPath $metadataPath -Destination (Join-Path $stagingRoot 'pack.mcmeta')
        Copy-Item -LiteralPath $iconPath -Destination (Join-Path $stagingRoot 'pack.png')
        foreach ($item in $inventory) {
            $destination = Join-Path $stagingRoot ($item.RelativePath.Replace('/', '\'))
            New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
            Copy-Item -LiteralPath $item.SourcePath -Destination $destination
        }

        New-PackArchive -StagingRoot $stagingRoot -ZipPath $paths.ZipPath
        Test-PackArchive -ZipPath $paths.ZipPath -Inventory $inventory

        $sha1 = (Get-FileHash -LiteralPath $paths.ZipPath -Algorithm SHA1).Hash.ToUpperInvariant()
        $sha256 = (Get-FileHash -LiteralPath $paths.ZipPath -Algorithm SHA256).Hash.ToUpperInvariant()
        $sourceCounts = @(Write-ReleaseFiles -Paths $paths -Config $config -Inventory $inventory -Revision $revision -Fingerprint $fingerprint -Sha1 $sha1 -Sha256 $sha256)

        $newState = [ordered]@{
            revision = $revision
            fingerprint = $fingerprint
            zipFile = [System.IO.Path]::GetFileName($paths.ZipPath)
            sha1 = $sha1
            sha256 = $sha256
            builtAtUtc = [DateTime]::UtcNow.ToString('o')
            sources = @($sourceCounts)
        }
        $newState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

        [pscustomobject]@{
            Changed = $changed
            Revision = $revision
            ZipPath = $paths.ZipPath
            Sha1 = $sha1
            Sha256 = $sha256
            ReportPath = $paths.ReportPath
            ServerPropertiesPath = $paths.ServerPropertiesPath
            AssetCount = $inventory.Count
        }
    }
    finally {
        Remove-SafeBuildDirectory -BuildDirectory $stagingRoot -BuildRoot $buildRoot
    }
}

Export-ModuleMember -Function Read-PackConfiguration, Get-PackFormatMajor, Get-AssetInventory, Get-InputFingerprint, Invoke-WolfHousePackBuild
