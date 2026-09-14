<#
.SYNOPSIS
    Builds the LibGhidraHost Ghidra extension against this host's Ghidra.
.DESCRIPTION
    A maintainer-path script. It has a network and is never run by the
    installer, which stays offline (spec SQ6).

    The prebuilt libghidra-extension-*.zip releases declare one exact Ghidra
    version and Ghidra rejects any mismatch, so a release zip is unusable on a
    host whose Ghidra differs by even a patch level. The source instead ships
    'version=@extversion@' and Ghidra's own support/buildExtension.gradle
    substitutes the version of the distribution being built against. Building
    locally therefore produces an extension stamped for THIS host.

    Assert-StampedExtensionVersion is what makes that trustworthy: a build that
    silently failed to substitute would otherwise ship a literal '@extversion@'.
.PARAMETER GhidraRoot
    Ghidra distribution to build against. Defaults to discovery.
.PARAMETER SourceRoot
    Checkout of 0xeb/libghidra at the pinned commit.
.PARAMETER DotSourceOnly
    Define the functions and return, so tests can load them without building.
.EXAMPLE
    .\tools\Build-LibGhidraExtension.ps1 -SourceRoot .vendor-cache\libghidra
#>
[CmdletBinding()]
# Write-Host is deliberate: this is a maintainer-run console tool, and its output -
# the stamped version and hash the gate is proving - is the point of running it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [string]$GhidraRoot,
    [string]$SourceRoot,
    [switch]$DotSourceOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-StampedExtensionVersion {
    <#
    .SYNOPSIS
        Asserts a built extension zip is stamped for the expected Ghidra version.
    .DESCRIPTION
        Three distinct failures, each reported separately because each has a
        different remedy: no extension.properties means the build produced
        something that is not a Ghidra extension; a surviving '@extversion@'
        means buildExtension.gradle never ran its ReplaceTokens filter; a
        different version means the build targeted another distribution.
    .PARAMETER ZipPath
        The built extension zip, from Gradle's dist/ directory.
    .PARAMETER ExpectedVersion
        The Ghidra version this host runs, e.g. '12.1.2'.
    .OUTPUTS
        [string] The stamped version, when it matches.
    .EXAMPLE
        Assert-StampedExtensionVersion -ZipPath dist\LibGhidraHost.zip -ExpectedVersion '12.1.2'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -like '*extension.properties' } |
            Select-Object -First 1
        if ($null -eq $entry) {
            throw ("'$ZipPath' contains no extension.properties. Gradle did not produce a " +
                'Ghidra extension; check the buildExtension task output.')
        }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }

    $found = ''
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*version\s*=\s*(.+?)\s*$') { $found = $Matches[1] }
    }

    if ($found -eq '@extversion@') {
        throw ("'$ZipPath' still carries the literal token '@extversion@'. Ghidra's " +
            'support/buildExtension.gradle did not run its ReplaceTokens filter, so this ' +
            'extension is not stamped for any Ghidra version and will be rejected.')
    }
    if ($found -ne $ExpectedVersion) {
        throw ("'$ZipPath' is stamped for Ghidra '$found' but this host runs " +
            "'$ExpectedVersion'. Ghidra matches that string exactly and will reject the " +
            'extension. Rebuild with -PGHIDRA_INSTALL_DIR pointing at this host''s Ghidra.')
    }
    return $found
}

function Invoke-ExtensionBuild {
    <#
    .SYNOPSIS
        Runs Gradle's buildExtension task and returns the built zip's path.
    .PARAMETER SourceRoot
        Checkout of 0xeb/libghidra at the pinned commit.
    .PARAMETER GhidraRoot
        Ghidra distribution to build against.
    .OUTPUTS
        [string] Path to the built zip under dist/.
    .EXAMPLE
        Invoke-ExtensionBuild -SourceRoot .vendor-cache\libghidra -GhidraRoot C:\ghidra
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$GhidraRoot
    )

    if (-not (Get-Command gradle -ErrorAction SilentlyContinue)) {
        throw ('Gradle is not on PATH. Ghidra 12.1.2 needs Gradle 8.5 or newer with no ' +
            'upper bound; install it with: choco install gradle')
    }
    $project = Join-Path $SourceRoot 'ghidra-extension'
    if (-not (Test-Path -LiteralPath $project)) {
        throw "No ghidra-extension directory under '$SourceRoot'."
    }
    Push-Location $project
    try {
        & gradle buildExtension "-PGHIDRA_INSTALL_DIR=$GhidraRoot" 2>&1 | Write-Verbose
        if ($LASTEXITCODE -ne 0) {
            throw ("gradle buildExtension failed with exit code $LASTEXITCODE. If it failed " +
                'to compile, the Ghidra Java API moved between this distribution and the ' +
                'one upstream targets - that is the real blocker, not the version stamp.')
        }
    } finally { Pop-Location }

    $zip = Get-ChildItem (Join-Path $project 'dist') -Filter '*.zip' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $zip) { throw "gradle succeeded but produced no zip under '$project\dist'." }
    return $zip.FullName
}

if ($DotSourceOnly) { return }

if (-not $GhidraRoot) { $GhidraRoot = Find-GhidraRoot }
$expected = Get-GhidraVersion -GhidraRoot $GhidraRoot
Write-Host "Building LibGhidraHost against Ghidra $expected at $GhidraRoot"
$built = Invoke-ExtensionBuild -SourceRoot $SourceRoot -GhidraRoot $GhidraRoot
$stamped = Assert-StampedExtensionVersion -ZipPath $built -ExpectedVersion $expected
Write-Host "PASS: '$built' is stamped version=$stamped"
Write-Host ("SHA-256: " + (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash)
