[CmdletBinding()]
param(
    [string]$QtVersion = "6.11.1",
    [Parameter(Mandatory = $true)][string]$InstallPrefix,
    [string]$SourceDirectory = "",
    [ValidateSet("Debug", "Release")][string]$Configuration = "Release",
    [string]$QtMirrorBaseUrl = "https://qt.mirror.constant.com/official_releases",
    # Required when cross-compiling (e.g. building for ARM64 from an x64
    # host): the install prefix of a Qt already built for the host
    # architecture, so qtbase can run moc/rcc/uic during the build instead of
    # the not-yet-built, non-executable target-architecture copies. Qt 6
    # spells this -qt-host-path and wants the prefix, not its bin directory.
    [string]$HostQtPath = ""
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = (Get-Location).Path
    )

    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed ($LASTEXITCODE): $Command $($Arguments -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromHours(2)
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        Write-Output "Downloading $Uri"
        $response = $client.GetAsync(
            $Uri,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode()
        $contentLength = $response.Content.Headers.ContentLength
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $buffer = [byte[]]::new(1024 * 1024)
        $downloaded = [int64]0
        $lastLog = [DateTime]::UtcNow
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $downloaded += $read
            $now = [DateTime]::UtcNow
            if (($now - $lastLog).TotalSeconds -ge 2) {
                $downloadedMiB = [math]::Round($downloaded / 1MB, 1)
                if ($contentLength) {
                    $percent = [math]::Round(($downloaded * 100.0) / $contentLength, 1)
                    $totalMiB = [math]::Round($contentLength / 1MB, 1)
                    Write-Progress -Activity "Downloading Qt $QtVersion sources" `
                        -Status "$downloadedMiB / $totalMiB MiB ($percent%)" `
                        -PercentComplete $percent
                    Write-Output "Qt source download: $downloadedMiB / $totalMiB MiB ($percent%)"
                }
                else {
                    Write-Progress -Activity "Downloading Qt $QtVersion sources" `
                        -Status "$downloadedMiB MiB received"
                    Write-Output "Qt source download: $downloadedMiB MiB received"
                }
                $lastLog = $now
            }
        }
        Write-Progress -Activity "Downloading Qt $QtVersion sources" -Completed
        Write-Output "Qt source download complete: $([math]::Round($downloaded / 1MB, 1)) MiB"
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
}

$installPrefix = [System.IO.Path]::GetFullPath($InstallPrefix)
$qtConfig = Join-Path $installPrefix "lib\cmake\Qt6\Qt6Config.cmake"
if (Test-Path -LiteralPath $qtConfig -PathType Leaf) {
    Write-Output "Static Qt $QtVersion ($Configuration) is already available at $installPrefix"
    exit 0
}

if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $SourceDirectory = Join-Path $env:RUNNER_TEMP "qt-everywhere-src-$QtVersion"
}
$sourceDirectory = [System.IO.Path]::GetFullPath($SourceDirectory)
$configurationArgument = if ($Configuration -eq "Debug") { "-debug" } else { "-release" }
$archivePath = Join-Path ([System.IO.Path]::GetDirectoryName($sourceDirectory)) "qt-everywhere-src-$QtVersion.tar.xz"
$sourceRelativePath = "qt/$($QtVersion.Substring(0, $QtVersion.LastIndexOf('.')))/$QtVersion/single/qt-everywhere-src-$QtVersion.tar.xz"
$sourceUrls = @(
    "$($QtMirrorBaseUrl.TrimEnd('/'))/$sourceRelativePath",
    "https://download.qt.io/official_releases/$sourceRelativePath"
) | Select-Object -Unique

if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        $downloaded = $false
        foreach ($sourceUrl in $sourceUrls) {
            try {
                Save-RemoteFile -Uri $sourceUrl -Destination $archivePath
                $downloaded = $true
                break
            }
            catch {
                Write-Warning "Qt source mirror failed ($sourceUrl): $($_.Exception.Message)"
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $downloaded) {
            throw "All Qt source mirrors failed."
        }
    }
    $sourceParent = Split-Path -Parent $sourceDirectory
    $extractedSourceDirectory = Join-Path $sourceParent "qt-everywhere-src-$QtVersion"
    New-Item -ItemType Directory -Force -Path $sourceParent | Out-Null
    if (-not (Test-Path -LiteralPath $extractedSourceDirectory -PathType Container)) {
        Invoke-Checked -Command "tar" -Arguments @("-xf", $archivePath, "-C", $sourceParent)
    }
    if ($sourceDirectory -ne $extractedSourceDirectory -and
        (Test-Path -LiteralPath $extractedSourceDirectory -PathType Container)) {
        Move-Item -LiteralPath $extractedSourceDirectory -Destination $sourceDirectory
    }
    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        throw "Qt source archive did not produce the expected directory: $sourceDirectory"
    }
}

New-Item -ItemType Directory -Force -Path $installPrefix | Out-Null
$configureArguments = @(
    "-static",
    $configurationArgument,
    "-static-runtime",
    "-opensource",
    "-confirm-license",
    "-prefix", $installPrefix,
    "-nomake", "tests",
    "-nomake", "examples",
    # Qt probes Program Files for database client libraries and links
    # whatever it finds, which on a cross build means host-architecture
    # import libraries: an x64 libpq.lib pulled into the ARM64 build failed
    # with 33 unresolved externals after an hour of compiling. Snow Shot
    # uses no Qt SQL driver, so turn off every one that needs an external
    # client library. sqlite stays: it is bundled, and qthelp needs it.
    "-no-feature-sql-psql",
    "-no-feature-sql-mysql",
    "-no-feature-sql-odbc",
    "-no-feature-sql-oci",
    "-no-feature-sql-db2",
    "-no-feature-sql-ibase",
    "-no-feature-sql-mimer",
    "-skip", "qt3d",
    "-skip", "qtactiveqt",
    "-skip", "qtandroidextras",
    "-skip", "qtconnectivity",
    "-skip", "qtdatavis3d",
    "-skip", "qtgraphs",
    "-skip", "qtgrpc",
    "-skip", "qtlocation",
    "-skip", "qtmultimedia",
    "-skip", "qtnetworkauth",
    "-skip", "qtopcua",
    "-skip", "qtpositioning",
    "-skip", "qtquick3d",
    "-skip", "qtquick3dphysics",
    "-skip", "qtquicktimeline",
    "-skip", "qtremoteobjects",
    "-skip", "qtscxml",
    "-skip", "qtsensors",
    "-skip", "qtserialbus",
    "-skip", "qtserialport",
    "-skip", "qtspeech",
    "-skip", "qtvirtualkeyboard",
    "-skip", "qtwebchannel",
    "-skip", "qtwebengine",
    "-skip", "qtwebsockets",
    "-skip", "qtwebview"
)
if (-not [string]::IsNullOrWhiteSpace($HostQtPath)) {
    $hostQtPath = [System.IO.Path]::GetFullPath($HostQtPath)
    if (-not (Test-Path -LiteralPath (Join-Path $hostQtPath "bin\moc.exe") -PathType Leaf)) {
        throw "HostQtPath is not a Qt install prefix with host tools: $hostQtPath"
    }
    $configureArguments += @("-qt-host-path", $hostQtPath)
}
Invoke-Checked -Command (Join-Path $sourceDirectory "configure.bat") -Arguments $configureArguments -WorkingDirectory $sourceDirectory
$buildFile = Join-Path $sourceDirectory "build.ninja"
if (-not (Test-Path -LiteralPath $buildFile -PathType Leaf)) {
    throw "Qt configure did not produce $buildFile. Review the configure output above."
}

# configure ignores a feature it does not recognise, and an SQL driver left
# on only fails when its host-architecture import library reaches the
# linker, an hour into the build. Confirm against the generated cache
# instead, while a mistake still costs minutes.
$qtCmakeCache = Join-Path $sourceDirectory "CMakeCache.txt"
if (-not (Test-Path -LiteralPath $qtCmakeCache -PathType Leaf)) {
    throw "Qt configure did not produce $qtCmakeCache"
}
$qtCacheText = Get-Content -LiteralPath $qtCmakeCache -Raw
foreach ($driver in @("psql", "mysql", "odbc", "oci", "db2", "ibase", "mimer")) {
    if ($qtCacheText -notmatch "(?m)^FEATURE_sql_$driver(:[^=]*)?=(OFF|FALSE|0)$") {
        $observed = @([regex]::Matches($qtCacheText, "(?m)^FEATURE_sql_.*$") |
            ForEach-Object { $_.Value }) -join "; "
        throw ("Qt configure left the $driver SQL driver enabled, so -no-feature-sql-$driver " +
            "was not applied. FEATURE_sql_* entries in the cache: $observed")
    }
}

Invoke-Checked -Command "cmake" -Arguments @("--build", ".", "--parallel") -WorkingDirectory $sourceDirectory
Invoke-Checked -Command "cmake" -Arguments @("--install", ".") -WorkingDirectory $sourceDirectory

if (-not (Test-Path -LiteralPath $qtConfig -PathType Leaf)) {
    throw "Qt $QtVersion installation did not produce $qtConfig"
}
Write-Output "Static Qt $QtVersion ($Configuration) installed at $installPrefix"
