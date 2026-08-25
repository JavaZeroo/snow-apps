Set-StrictMode -Version Latest

$script:SnowRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:SnowQtVersion = "6.11.1"
$script:SnowMsvcToolset = "14.51"
$script:SnowRustToolchain = "1.97.1"
$script:SnowRustTargetByArch = @{
    x64   = "x86_64-pc-windows-msvc"
    arm64 = "aarch64-pc-windows-msvc"
}

function Resolve-SnowRustTarget {
    param([ValidateSet("x64", "arm64")][string]$Arch = "x64")
    return $script:SnowRustTargetByArch[$Arch]
}

function Resolve-SnowQtDir {
    param(
        [string]$Qt6Dir = "",
        [string]$Preset = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($Qt6Dir)) {
        $candidates = @($Qt6Dir)
    }
    else {
        $explicitCandidates = @(
            $env:SNOW_QT_STATIC_DIR,
            $env:Qt6_DIR,
            $(if (-not [string]::IsNullOrWhiteSpace($env:QTDIR)) {
                Join-Path $env:QTDIR "lib\cmake\Qt6"
            })
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $searchRoots = @(
            $env:SNOW_QT_ROOT,
            $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
                Join-Path $env:ProgramFiles "Qt"
            }),
            $(if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
                Join-Path ${env:ProgramFiles(x86)} "Qt"
            }),
            "C:\Qt"
        ) | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            (Test-Path -LiteralPath $_ -PathType Container)
        }
        $discoveredCandidates = foreach ($root in $searchRoots) {
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $script:SnowQtVersion } |
                ForEach-Object {
                    Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
                        ForEach-Object { Join-Path $_.FullName "lib\cmake\Qt6" }
                }
        }
        if (-not [string]::IsNullOrWhiteSpace($Preset)) {
            $preferDebugKit = $Preset -eq "windows-msvc-debug"
            $discoveredCandidates = @($discoveredCandidates) | Sort-Object `
                @{ Expression = {
                    $isDebugKit = $_ -match '(?i)debug'
                    if ($isDebugKit -eq $preferDebugKit) { 0 } else { 1 }
                } }, `
                @{ Expression = { $_ } }
        }
        $candidates = @($explicitCandidates + $discoveredCandidates) | Select-Object -Unique
    }

    foreach ($candidate in $candidates) {
        try {
            $resolved = [System.IO.Path]::GetFullPath($candidate)
        }
        catch {
            continue
        }
        $config = Join-Path $resolved "Qt6Config.cmake"
        if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { continue }
        $versionFiles = @(
            (Join-Path $resolved "Qt6ConfigVersion.cmake"),
            (Join-Path $resolved "Qt6ConfigVersionImpl.cmake")
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        $versionText = ($versionFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
        if ($versionText -match 'PACKAGE_VERSION\s+"6\.11\.1"') { return $resolved }
    }
    if (-not [string]::IsNullOrWhiteSpace($Qt6Dir)) {
        throw "Qt $script:SnowQtVersion CMake package was not found at the explicit Qt6Dir: $Qt6Dir"
    }
    throw "Qt $script:SnowQtVersion CMake package was not found. Set SNOW_QT_STATIC_DIR, Qt6_DIR, QTDIR, or SNOW_QT_ROOT."
}

function Set-SnowQtEnvironment {
    param(
        [string]$Qt6Dir = "",
        [string]$Preset = ""
    )

    $qtDir = Resolve-SnowQtDir -Qt6Dir $Qt6Dir -Preset $Preset
    $env:SNOW_QT_STATIC_DIR = $qtDir
    $env:Qt6_DIR = $qtDir
    $env:QTDIR = [System.IO.Path]::GetFullPath((Join-Path $qtDir "..\..\.."))
    # Qt installations bundle a MinGW toolchain, and CI images often ship a
    # standalone one (C:\mingw64, msys64). That compiler is incompatible with
    # this project's MSVC-only triplets and causes CMake to select gcc for
    # OpenCV's MLAS GNU assembly sources, which the GNU assembler then
    # rejects. Drop every MinGW directory, not just the one Qt bundles.
    $env:Path = @($env:Path -split ';' | Where-Object {
        $_ -and $_ -notmatch '(?i)(^|[\\/])mingw[^\\/]*([\\/]|$)'
    }) -join ';'
    $env:Path = "$(Join-Path $env:QTDIR 'bin');$env:Path"
    return $qtDir
}

function Add-SnowMsvcToolsToPath {
    param([ValidateSet("x64", "arm64")][string]$Arch = "x64")

    $vswhereCommand = Get-Command "vswhere.exe" -ErrorAction SilentlyContinue
    $vswhere = @(
        @(
            $(if ($vswhereCommand) { $vswhereCommand.Source }),
            $(if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
                Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
            }),
            $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
                Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe"
            })
        ) | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            (Test-Path -LiteralPath $_ -PathType Leaf)
        }
    )
    $visualStudioRoot = @($env:VSINSTALLDIR) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        (Test-Path -LiteralPath (Join-Path $_ "VC\Tools\MSVC") -PathType Container)
    } | Select-Object -First 1
    if (-not $visualStudioRoot -and $vswhere) {
        $visualStudioRoot = & $vswhere[0] -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 1
    }
    if (-not $visualStudioRoot) {
        throw "A Visual Studio installation with the MSVC x64 component was not found. Install the required Build Tools or set VSINSTALLDIR."
    }

    $env:VSINSTALLDIR = [System.IO.Path]::GetFullPath($visualStudioRoot)
    $env:VCINSTALLDIR = Join-Path $env:VSINSTALLDIR "VC"
    $msvcTools = Get-ChildItem -LiteralPath (Join-Path $env:VCINSTALLDIR "Tools\MSVC") -Directory |
        Where-Object { $_.Name -match '^14\.51' } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $msvcTools) {
        throw "MSVC toolset $script:SnowMsvcToolset was not found under $env:VCINSTALLDIR."
    }

    $env:VCToolsInstallDir = "$($msvcTools.FullName)\"
    $msvcBin = Join-Path $msvcTools.FullName "bin\Hostx64\$Arch"
    if (-not (Test-Path -LiteralPath (Join-Path $msvcBin "cl.exe") -PathType Leaf)) {
        throw "MSVC $Arch cross tools were not found under $msvcBin. Install the Visual Studio MSVC $Arch component."
    }
    $env:Path = "$msvcBin;$env:Path"

    $sdkRoot = $env:WindowsSdkDir
    $sdkVersion = $env:WindowsSDKVersion
    if ([string]::IsNullOrWhiteSpace($sdkRoot) -or [string]::IsNullOrWhiteSpace($sdkVersion)) {
        $sdkIncludeRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Include"
        $sdkInclude = Get-ChildItem -LiteralPath $sdkIncludeRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($sdkInclude) {
            $sdkRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10"
            $sdkVersion = $sdkInclude.Name
        }
    }
    if ([string]::IsNullOrWhiteSpace($sdkRoot) -or [string]::IsNullOrWhiteSpace($sdkVersion)) {
        throw "A Windows 10 SDK was not found. Install one or set WindowsSdkDir and WindowsSDKVersion."
    }
    $env:WindowsSdkDir = "$([System.IO.Path]::GetFullPath($sdkRoot))\"
    $env:WindowsSDKVersion = "$sdkVersion\"
    $sdkBin = Join-Path $env:WindowsSdkDir "bin\$sdkVersion\$Arch"
    if (-not (Test-Path -LiteralPath (Join-Path $sdkBin "rc.exe") -PathType Leaf)) {
        throw "Windows SDK resource compiler was not found under $sdkBin."
    }
    $env:Path = "$sdkBin;$env:Path"
    $sdkIncludeRoot = Join-Path $env:WindowsSdkDir "Include\$sdkVersion"
    $env:INCLUDE = @(
        (Join-Path $msvcTools.FullName "include"),
        (Join-Path $sdkIncludeRoot "ucrt"),
        (Join-Path $sdkIncludeRoot "shared"),
        (Join-Path $sdkIncludeRoot "um"),
        (Join-Path $sdkIncludeRoot "winrt"),
        (Join-Path $sdkIncludeRoot "cppwinrt")
    ) -join ";"
    $env:LIB = @(
        (Join-Path $msvcTools.FullName "lib\$Arch"),
        (Join-Path $env:WindowsSdkDir "Lib\$sdkVersion\um\$Arch"),
        (Join-Path $env:WindowsSdkDir "Lib\$sdkVersion\ucrt\$Arch")
    ) -join ";"
    return $msvcBin
}

function Set-SnowBuildEnvironment {
    param(
        [string]$Preset = "",
        [ValidateSet("x64", "arm64")][string]$Arch = "x64"
    )

    $qtDir = Set-SnowQtEnvironment -Preset $Preset
    $env:VCPKG_ROOT = Join-Path $script:SnowRepoRoot ".tools\vcpkg"
    Add-SnowMsvcToolsToPath -Arch $Arch | Out-Null
    $libclang = Join-Path $script:SnowRepoRoot ".tools\llvm\bin"
    if (Test-Path -LiteralPath (Join-Path $libclang "libclang.dll") -PathType Leaf) {
        $env:LIBCLANG_PATH = $libclang
    }
    $env:Path = "$(Join-Path $libclang '..');$env:Path"
    return [pscustomobject]@{
        RepoRoot = $script:SnowRepoRoot
        Qt6Dir = $qtDir
        QtVersion = $script:SnowQtVersion
        MsvcToolset = $script:SnowMsvcToolset
        RustToolchain = $script:SnowRustToolchain
        RustTarget = (Resolve-SnowRustTarget -Arch $Arch)
        VcpkgRoot = $env:VCPKG_ROOT
    }
}

function Resolve-SnowPreset {
    param(
        [ValidateSet("Debug", "Release", "Performance", "Fast")][string]$Configuration,
        [ValidateSet("x64", "arm64")][string]$Arch = "x64"
    )
    if ($Arch -eq "arm64" -and $Configuration -ne "Release") {
        throw "Only the Release configuration has an arm64 preset."
    }
    switch ($Configuration) {
        "Debug" { return "windows-msvc-debug" }
        "Release" { if ($Arch -eq "arm64") { return "snow-shot-msvc-release-arm64" } else { return "snow-shot-msvc-release" } }
        "Performance" { return "windows-msvc-performance" }
        "Fast" { return "snow-shot-msvc-fast" }
    }
}

function Invoke-SnowCMake {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    Push-Location $script:SnowRepoRoot
    try {
        & cmake @Arguments
        if ($LASTEXITCODE -ne 0) { throw "CMake failed ($LASTEXITCODE): cmake $($Arguments -join ' ')" }
    }
    finally { Pop-Location }
}

function Test-SnowCacheAlignment {
    param(
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][string]$Preset
    )
    if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) { return $false }
    $cache = Get-Content -LiteralPath $CachePath -Raw
    $qtNeedle = [regex]::Escape(($env:SNOW_QT_STATIC_DIR -replace '\\', '/'))
    $staticPresets = @("snow-shot-msvc-release", "snow-shot-msvc-fast", "snow-shot-msvc-release-arm64")
    $expectedTriplet = if ($Preset -eq "snow-shot-msvc-release-arm64") {
        "arm64-windows-static"
    }
    elseif ($Preset -in $staticPresets) {
        "x64-windows-static"
    }
    else {
        "x64-windows"
    }
    $qtAligned = $cache -match "(?m)^Qt6_DIR:PATH=$qtNeedle$"
    if ($Preset -in $staticPresets) {
        $qtAligned = $qtAligned -and $cache -match '(?m)^SNOW_QT_STATIC_DIR:PATH='
    }
    return $qtAligned -and
        $cache -match "(?m)^VCPKG_TARGET_TRIPLET:.*=$([regex]::Escape($expectedTriplet))$" -and
        $cache -match '(?m)^CMAKE_GENERATOR_TOOLSET:INTERNAL=host=x64,version=14\.51$'
}

function Resolve-SnowExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$Preset,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $configuration = if ($Preset -eq "windows-msvc-debug") { "Debug" } else { "Release" }
    $buildRoot = Join-Path $script:SnowRepoRoot "build\$Preset"
    $match = Get-ChildItem -LiteralPath $buildRoot -Filter $Name -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\$configuration\\" } |
        Sort-Object FullName |
        Select-Object -First 1
    if (-not $match) { throw "$Name was not found under $buildRoot ($configuration)." }
    return $match
}
