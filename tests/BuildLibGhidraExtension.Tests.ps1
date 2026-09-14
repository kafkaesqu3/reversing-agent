BeforeAll {
    . "$PSScriptRoot/../tools/Build-LibGhidraExtension.ps1" -DotSourceOnly

    function New-FixtureZip {
        # Pure test fixture factory: builds and returns a zip path, no ShouldProcess needed.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '')]
        param([string]$VersionLine)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("ext-" + [guid]::NewGuid())
        $inner = Join-Path $dir 'LibGhidraHost'
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        $props = "name=LibGhidraHost`nauthor=libghidra`n$VersionLine`n"
        [IO.File]::WriteAllText((Join-Path $inner 'extension.properties'), $props)
        $zip = "$dir.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip)
        Remove-Item -LiteralPath $dir -Recurse -Force
        return $zip
    }
}

Describe 'Assert-StampedExtensionVersion' {
    It 'returns the version when the build stamped the expected one' {
        $zip = New-FixtureZip -VersionLine 'version=12.1.2'
        try {
            Assert-StampedExtensionVersion -ZipPath $zip -ExpectedVersion '12.1.2' |
                Should -Be '12.1.2'
        } finally { Remove-Item -LiteralPath $zip -Force }
    }

    It 'throws when the token was never substituted' {
        # THE failure this gate exists to catch: the build ran but Ghidra's
        # buildExtension.gradle never applied ReplaceTokens, so the extension
        # would ship claiming a literal '@extversion@' and Ghidra would reject it.
        $zip = New-FixtureZip -VersionLine 'version=@extversion@'
        try {
            { Assert-StampedExtensionVersion -ZipPath $zip -ExpectedVersion '12.1.2' } |
                Should -Throw '*@extversion@*'
        } finally { Remove-Item -LiteralPath $zip -Force }
    }

    It 'throws when the stamp is a different Ghidra version' {
        # Reproduces the prebuilt-release situation: a 12.1.3 extension on a 12.1.2 host.
        $zip = New-FixtureZip -VersionLine 'version=12.1.3'
        try {
            { Assert-StampedExtensionVersion -ZipPath $zip -ExpectedVersion '12.1.2' } |
                Should -Throw '*12.1.3*'
        } finally { Remove-Item -LiteralPath $zip -Force }
    }

    It 'throws when the zip carries no extension.properties at all' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("ext-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $dir 'LibGhidraHost') -Force | Out-Null
        $zip = "$dir.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip)
        Remove-Item -LiteralPath $dir -Recurse -Force
        try {
            { Assert-StampedExtensionVersion -ZipPath $zip -ExpectedVersion '12.1.2' } |
                Should -Throw '*extension.properties*'
        } finally { Remove-Item -LiteralPath $zip -Force }
    }
}
