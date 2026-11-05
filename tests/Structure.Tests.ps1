# Structural checks only: never invoke a real entry point or import app helpers.
BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config/entrypoints.psd1')
    $entrypointCases = @(
        foreach ($name in ($manifest.Keys | Sort-Object)) {
            @{ WrapperName = $name; TargetPath = $manifest[$name] }
        }
    )
}

BeforeAll {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $entrypoints = Import-PowerShellDataFile -LiteralPath (Join-Path $projectRoot 'config/entrypoints.psd1')
}

Describe 'First-party project structure' {
    It 'has every root PowerShell entry point in the compatibility manifest, and no stale entries' {
        $rootFiles = @(Get-ChildItem -LiteralPath $projectRoot -File -Filter '*.ps1' | Select-Object -ExpandProperty Name | Sort-Object)
        $manifestFiles = @($entrypoints.Keys | Sort-Object)
        $manifestFiles.Count | Should -BeGreaterThan 0
        @(Compare-Object -ReferenceObject $rootFiles -DifferenceObject $manifestFiles) | Should -HaveCount 0
    }

    It 'maps each wrapper to a distinct implementation' {
        @($entrypoints.Values | Sort-Object -Unique).Count | Should -Be $entrypoints.Count
    }

    It 'retains exactly the three import-safe compatibility bridges in src' {
        $bridges = @($entrypoints.Keys | Where-Object { $entrypoints[$_] -like 'src/*' } | Sort-Object)
        @((Compare-Object -ReferenceObject @('common.ps1', 'ui-input.ps1', 'window-util.ps1') -DifferenceObject $bridges)) | Should -HaveCount 0
    }

    It 'keeps <Directory> in its dedicated project folder' -ForEach @(
        @{ Directory = 'src' }
        @{ Directory = 'scripts' }
        @{ Directory = 'config' }
        @{ Directory = 'tools' }
        @{ Directory = 'tests' }
    ) {
        Test-Path -LiteralPath (Join-Path $projectRoot $Directory) -PathType Container | Should -BeTrue
    }

    It 'maps <WrapperName> to an existing, contained implementation with the same name' -ForEach $entrypointCases {
        $WrapperName | Should -Match '^[^\\/]+\.ps1$'
        $TargetPath | Should -Match '^(?:src/[^/]+|scripts/(?:apps|groups|login|operations|setup|tools)/[^/]+)\.ps1$'
        $TargetPath | Should -Not -Match '(?:^|/)\.\.?(?:/|$)'
        $implementation = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $TargetPath))
        $implementation.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        [System.IO.Path]::GetFileName($implementation) | Should -BeExactly $WrapperName
        Test-Path -LiteralPath $implementation -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $projectRoot $WrapperName) -PathType Leaf | Should -BeTrue
    }

    It 'has <WrapperName> statically forward to its declared manifest target' -ForEach $entrypointCases {
        $wrapper = Join-Path $projectRoot $WrapperName
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$errors)
        @($errors) | Should -HaveCount 0
        $targetJoins = @($ast.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CommandAst] -or $node.GetCommandName() -ne 'Join-Path') { return $false }
            $elements = $node.CommandElements
            if ($elements.Count -ne 3) { return $false }
            return ($elements[1] -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $elements[1].VariablePath.UserPath -eq 'PSScriptRoot' -and
                $elements[2] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $elements[2].Value -eq $TargetPath)
        }, $true))
        $targetJoins | Should -HaveCount 1
        $invocations = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.InvocationOperator -in @(
                    [System.Management.Automation.Language.TokenKind]::Ampersand,
                    [System.Management.Automation.Language.TokenKind]::Dot
                )
        }, $true))
        $invocations.Count | Should -BeGreaterThan 0
    }
}
