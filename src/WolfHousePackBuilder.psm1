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

Export-ModuleMember -Function Read-PackConfiguration, Get-PackFormatMajor, Get-AssetInventory
