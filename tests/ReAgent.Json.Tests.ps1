BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Json.psm1" -Force
}

Describe 'Merge-JsonFile' {
    It 'creates the file when it does not exist' {
        $p = Join-Path $TestDrive 'settings.json'
        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.enabled' = $true }
        (Get-Content $p -Raw | ConvertFrom-Json).'ui.mcp.enabled' | Should -BeTrue
    }

    It 'creates missing parent directories' {
        $p = Join-Path $TestDrive 'a\b\settings.json'
        Merge-JsonFile -Path $p -Values @{ x = 1 }
        Test-Path $p | Should -BeTrue
    }

    It 'preserves keys it did not write' {
        $p = Join-Path $TestDrive 'settings2.json'
        '{ "analysis.mode": "full", "ui.theme": "dark" }' | Set-Content $p
        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.enabled' = $true }
        $r = Get-Content $p -Raw | ConvertFrom-Json
        $r.'analysis.mode' | Should -Be 'full'
        $r.'ui.theme' | Should -Be 'dark'
        $r.'ui.mcp.enabled' | Should -BeTrue
    }

    It 'overwrites only the keys it was given' {
        $p = Join-Path $TestDrive 'settings3.json'
        '{ "ui.mcp.port": 1111, "keep": "me" }' | Set-Content $p
        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.port' = 24642 }
        $r = Get-Content $p -Raw | ConvertFrom-Json
        $r.'ui.mcp.port' | Should -Be 24642
        $r.keep | Should -Be 'me'
    }

    It 'writes a backup before modifying an existing file' {
        $p = Join-Path $TestDrive 'settings4.json'
        '{ "a": 1 }' | Set-Content $p
        Merge-JsonFile -Path $p -Values @{ b = 2 }
        (Get-ChildItem $TestDrive -Filter 'settings4.json.bak-*').Count |
            Should -BeGreaterThan 0
    }

    It 'does not create a backup when every requested value is already current' {
        $p = Join-Path $TestDrive 'current.json'
        '{ "ui.mcp.enabled": true }' | Set-Content $p

        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.enabled' = $true }

        @(Get-ChildItem $TestDrive -Filter 'current.json.bak-*').Count | Should -Be 0
    }

    It 'does not rewrite an already-current settings file' {
        $p = Join-Path $TestDrive 'current-time.json'
        '{ "ui.mcp.enabled": true }' | Set-Content $p
        $before = (Get-Item -LiteralPath $p).LastWriteTimeUtc
        Start-Sleep -Milliseconds 1100

        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.enabled' = $true }

        (Get-Item -LiteralPath $p).LastWriteTimeUtc | Should -Be $before
    }

    It 'does not create parent directories under WhatIf' {
        $p = Join-Path $TestDrive 'absent\settings.json'

        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.enabled' = $true } -WhatIf

        Test-Path -LiteralPath (Split-Path -Parent $p) | Should -BeFalse
    }

    It 'handles an empty file, which Binary Ninja ships as {}' {
        $p = Join-Path $TestDrive 'empty.json'
        '' | Set-Content $p
        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.enabled' = $true }
        (Get-Content $p -Raw | ConvertFrom-Json).'ui.mcp.enabled' | Should -BeTrue
    }

    It 'refuses to write when the existing file is not valid JSON' {
        $p = Join-Path $TestDrive 'broken.json'
        'this is not json' | Set-Content $p
        { Merge-JsonFile -Path $p -Values @{ a = 1 } } | Should -Throw '*not valid JSON*'
    }

    It 'leaves the original untouched when it refuses' {
        $p = Join-Path $TestDrive 'broken2.json'
        'not json at all' | Set-Content $p
        { Merge-JsonFile -Path $p -Values @{ a = 1 } } | Should -Throw
        (Get-Content $p -Raw).Trim() | Should -Be 'not json at all'
    }
}
