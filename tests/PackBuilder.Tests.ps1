$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wolfhouse-pack-tests-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool] $Condition, [string] $Message = 'Expected condition to be true.')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message = '')
    if ($Expected -ne $Actual) {
        if (-not $Message) { $Message = "Expected '$Expected' but got '$Actual'." }
        throw $Message
    }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $MessageFragment)
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notlike "*$MessageFragment*") {
            throw "Expected error containing '$MessageFragment' but got '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected an error containing '$MessageFragment', but no error was thrown."
}

function Test-ZipEntry {
    param([string] $ZipPath, [string] $EntryName)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $normalizedName = $EntryName -replace '\\', '/'
        return $null -ne ($archive.Entries | Where-Object { $_.FullName -eq $normalizedName } | Select-Object -First 1)
    }
    finally {
        $archive.Dispose()
    }
}

function Invoke-Test {
    param([string] $Name, [scriptblock] $Action)
    try {
        & $Action
        $script:Passed++
        Write-Host "PASS: $Name"
    }
    catch {
        $script:Failed++
        Write-Host "FAIL: $Name"
        Write-Host "  $($_.Exception.Message)"
    }
}

function Write-PackMetadata {
    param([string] $PackRoot, [string] $Shape)
    $pack = if ($Shape -eq 'array') {
        @{ description = 'test source'; min_format = @(88, 0); max_format = @(88, 0) }
    }
    else {
        @{ description = 'test source'; min_format = 88; max_format = 88 }
    }
    @{ pack = $pack } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PackRoot 'pack.mcmeta') -Encoding UTF8
}

function New-PackFixture {
    param([string[]] $Formats)

    $fixtureRoot = Join-Path $script:TestRoot ([guid]::NewGuid().ToString('N'))
    $projectRoot = Join-Path $fixtureRoot 'Master'
    $buddyRoot = Join-Path $fixtureRoot 'BuddyPack\resource-pack'
    $teamsRoot = Join-Path $fixtureRoot 'WolfTeams\resourcepack'
    $buddyAsset = Join-Path $buddyRoot 'assets\buddypack\models\item\example.json'
    $teamsAsset = Join-Path $teamsRoot 'assets\wolfteams\textures\item\example.png'

    New-Item -ItemType Directory -Path (Split-Path $buddyAsset), (Split-Path $teamsAsset), $projectRoot -Force | Out-Null
    Write-PackMetadata -PackRoot $buddyRoot -Shape $Formats[0]
    Write-PackMetadata -PackRoot $teamsRoot -Shape $Formats[1]
    '{"parent":"minecraft:item/generated"}' | Set-Content -LiteralPath $buddyAsset -Encoding UTF8
    [System.IO.File]::WriteAllBytes($teamsAsset, [byte[]](1, 2, 3, 4))
    '{"pack":{"min_format":88,"max_format":88,"description":"fixture"}}' | Set-Content -LiteralPath (Join-Path $projectRoot 'pack.mcmeta') -Encoding UTF8
    [System.IO.File]::WriteAllBytes((Join-Path $projectRoot 'pack.png'), [byte[]](5, 6, 7, 8))

    $config = [ordered]@{
        packFormat = 88
        resourcePackId = '38fc313c-e7c0-4b09-95ef-bf4f49e8f72d'
        prompt = 'Fixture prompt'
        downloadUrlMarker = 'UPLOAD_DIRECT_DOWNLOAD_URL_HERE'
        sources = @(
            [ordered]@{ name = 'BuddyPack'; path = '../BuddyPack/resource-pack' },
            [ordered]@{ name = 'WolfTeams'; path = '../WolfTeams/resourcepack' }
        )
    }
    $configPath = Join-Path $projectRoot 'pack-sources.json'
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

    [pscustomobject]@{
        ProjectRoot = $projectRoot
        ConfigPath = $configPath
        BuddyRoot = $buddyRoot
        TeamsRoot = $teamsRoot
        BuddyAsset = $buddyAsset
    }
}

function New-CollisionFixture {
    param([string] $RelativePath)

    $fixture = New-PackFixture -Formats @('scalar', 'array')
    foreach ($root in @($fixture.BuddyRoot, $fixture.TeamsRoot)) {
        $path = Join-Path $root ($RelativePath -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        '{"providers":[]}' | Set-Content -LiteralPath $path -Encoding UTF8
    }
    $fixture
}

try {
    $modulePath = Join-Path (Split-Path $PSScriptRoot) 'src\WolfHousePackBuilder.psm1'
    Import-Module $modulePath -Force

    Invoke-Test 'inventory accepts both pack metadata shapes and lists registered assets' {
        $fixture = New-PackFixture -Formats @('scalar', 'array')
        $config = Read-PackConfiguration -ConfigPath $fixture.ConfigPath
        $inventory = @(Get-AssetInventory -Config $config -ProjectRoot $fixture.ProjectRoot)
        Assert-Equal 2 $inventory.Count
        Assert-True ($inventory.RelativePath -contains 'assets/buddypack/models/item/example.json')
        Assert-True ($inventory.RelativePath -contains 'assets/wolfteams/textures/item/example.png')
        Assert-Equal 88 (Get-PackFormatMajor -PackRoot $fixture.BuddyRoot)
        Assert-Equal 88 (Get-PackFormatMajor -PackRoot $fixture.TeamsRoot)
    }

    Invoke-Test 'duplicate destination assets stop the build' {
        $fixture = New-CollisionFixture -RelativePath 'assets/minecraft/font/default.json'
        Assert-Throws {
            $config = Read-PackConfiguration -ConfigPath $fixture.ConfigPath
            Get-AssetInventory -Config $config -ProjectRoot $fixture.ProjectRoot
        } 'Asset collision'
    }

    Invoke-Test 'build produces a correctly revisioned root-level release' {
        $fixture = New-PackFixture -Formats @('scalar', 'array')
        $first = Invoke-WolfHousePackBuild -ProjectRoot $fixture.ProjectRoot -ConfigPath $fixture.ConfigPath
        Assert-Equal 1 $first.Revision
        Assert-Equal $true $first.Changed
        Assert-Equal 40 $first.Sha1.Length
        Assert-Equal 64 $first.Sha256.Length
        Assert-True (Test-ZipEntry $first.ZipPath 'pack.mcmeta') 'ZIP is missing root pack.mcmeta.'
        Assert-True (Test-ZipEntry $first.ZipPath 'pack.png') 'ZIP is missing root pack.png.'
        Assert-True (Test-ZipEntry $first.ZipPath 'assets/buddypack/models/item/example.json') 'ZIP is missing the BuddyPack fixture asset.'
        Assert-True (Test-ZipEntry $first.ZipPath 'assets/wolfteams/textures/item/example.png') 'ZIP is missing the WolfTeams fixture asset.'
        Assert-True (-not (Test-ZipEntry $first.ZipPath 'WolfHouse-ResourcePack/pack.mcmeta')) 'ZIP contains an unwanted enclosing folder.'

        $same = Invoke-WolfHousePackBuild -ProjectRoot $fixture.ProjectRoot -ConfigPath $fixture.ConfigPath
        Assert-Equal 1 $same.Revision
        Assert-Equal $false $same.Changed
        Assert-Equal $first.Sha1 $same.Sha1

        Set-Content -LiteralPath $fixture.BuddyAsset -Value '{"changed":true}' -NoNewline
        $changed = Invoke-WolfHousePackBuild -ProjectRoot $fixture.ProjectRoot -ConfigPath $fixture.ConfigPath
        Assert-Equal 2 $changed.Revision
        Assert-Equal $true $changed.Changed
    }
}
finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($script:TestRoot)
    if ($resolvedTestRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Host "$($script:Passed) passed, $($script:Failed) failed"
if ($script:Failed -gt 0) { exit 1 }
