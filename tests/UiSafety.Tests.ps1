BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    # Import compiles the native type only. These tests call its PURE predicates,
    # never window enumeration, screenshots, focus, input or credential access.
    . (Join-Path $RepositoryRoot 'src/ui-input.ps1')
    $script:UiSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'src/ui-input.ps1') -Raw
    $script:TosSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/login/login-thinkorswim.ps1') -Raw
    $script:FutuSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/login/login-futubull.ps1') -Raw
    $script:ZsqhSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/login/login-zsqh-clients.ps1') -Raw
    function Get-SafetyAst {
        param([string]$Source)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
        if ($errors) { throw ($errors.Message -join '; ') }
        return $ast
    }
    $script:TosAst = Get-SafetyAst $TosSource
    $script:FutuAst = Get-SafetyAst $FutuSource
    $script:ZsqhAst = Get-SafetyAst $ZsqhSource
    function Get-ReferenceFingerprint {
        param($Ast, [string]$Name)
        $assignment = $Ast.Find({ param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq $Name
        }, $true)
        $literal = $assignment.Right.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
        return [string]$literal.Value
    }
    $script:Welcome = Get-ReferenceFingerprint $TosAst 'WelcomeFingerprint'
    $script:WelcomeEmpty = Get-ReferenceFingerprint $TosAst 'WelcomeEmptyFingerprint'
    $script:Password = Get-ReferenceFingerprint $TosAst 'PasswordFingerprint'
}

Describe 'Pure UI safety predicates' {
    It 'requires the exact intended root HWND, not merely a sibling in one process' {
        [UiInput]::SameRoot([IntPtr]42, [IntPtr]42) | Should -BeTrue
        [UiInput]::SameRoot([IntPtr]42, [IntPtr]43) | Should -BeFalse
        [UiInput]::SameRoot([IntPtr]::Zero, [IntPtr]::Zero) | Should -BeFalse
    }
    It 'rejects negative, edge and out-of-bounds relative click points' {
        $rect = New-Object 'UiInput+RECT'
        $rect.Left = -100; $rect.Top = 20; $rect.Right = 749; $rect.Bottom = 1070
        [UiInput]::ContainsRelativePoint($rect, 0, 0) | Should -BeTrue
        [UiInput]::ContainsRelativePoint($rect, 848, 1049) | Should -BeTrue
        [UiInput]::ContainsRelativePoint($rect, -1, 10) | Should -BeFalse
        [UiInput]::ContainsRelativePoint($rect, 849, 10) | Should -BeFalse
        [UiInput]::ContainsRelativePoint($rect, 10, 1050) | Should -BeFalse
    }
    It 'rejects degenerate window geometry' {
        $rect = New-Object 'UiInput+RECT'
        [UiInput]::ContainsRelativePoint($rect, 0, 0) | Should -BeFalse
        $rect.Right = -1
        [UiInput]::ContainsRelativePoint($rect, 0, 0) | Should -BeFalse
    }
}

Describe 'Pure fingerprint discrimination' {
    It 'retains the original 360-byte reference fingerprints' {
        (ConvertFrom-UiFingerprintString $Welcome).Length | Should -Be 360
        (ConvertFrom-UiFingerprintString $WelcomeEmpty).Length | Should -Be 360
        (ConvertFrom-UiFingerprintString $Password).Length | Should -Be 360
        (ConvertFrom-UiFingerprintString (Get-ReferenceFingerprint $FutuAst 'LoginScreenFingerprint')).Length | Should -Be 360
    }
    It 'roundtrips exact hex and computes a mean absolute distance' {
        ConvertTo-UiFingerprintString (ConvertFrom-UiFingerprintString '00107fff') | Should -BeExactly '00107fff'
        Get-UiFingerprintDistance -A ([byte[]](0, 10)) -B ([byte[]](10, 30)) | Should -Be 15
    }
    It 'rejects malformed fingerprints and missing or mismatched captures' {
        { ConvertFrom-UiFingerprintString '001' } | Should -Throw
        { ConvertFrom-UiFingerprintString 'zz' } | Should -Throw
        Test-UiFingerprintMatch -Fingerprint $null -ExpectedFingerprint $Welcome | Should -BeFalse
        Test-UiFingerprintMatch -Fingerprint ([byte[]](0, 1)) -ExpectedFingerprint $Welcome | Should -BeFalse
    }
    It 'documents why the old Welcome threshold incorrectly accepted Password' {
        $distance = Get-UiFingerprintDistance -A (ConvertFrom-UiFingerprintString $Welcome) -B (ConvertFrom-UiFingerprintString $Password)
        $distance | Should -BeLessThan 12
        $distance | Should -BeGreaterThan 6
    }
    It 'keeps the empty Login ID layout distinct from the password step' {
        # Build 1994.0.53 omits the Remember row while the Login ID is empty, so
        # that layout sits close to the password step. The references must still
        # separate in both directions or a password would be typed too early.
        $emptyBytes = ConvertFrom-UiFingerprintString $WelcomeEmpty
        $passwordBytes = ConvertFrom-UiFingerprintString $Password
        $distance = Get-UiFingerprintDistance -A $emptyBytes -B $passwordBytes
        $distance | Should -BeGreaterThan 1.5
        Test-UiFingerprintMatch $emptyBytes $WelcomeEmpty -RejectedFingerprint $Password -MaxDistance 6 | Should -BeTrue
        Test-UiFingerprintMatch $passwordBytes $Password -RejectedFingerprint $WelcomeEmpty -MaxDistance 6 | Should -BeTrue
        Test-UiFingerprintMatch $passwordBytes $WelcomeEmpty -RejectedFingerprint $Password -MaxDistance 6 | Should -BeFalse
        Test-UiFingerprintMatch $emptyBytes $Password -RejectedFingerprint $WelcomeEmpty -MaxDistance 6 | Should -BeFalse
    }
    It 'accepts each exact step and rejects the other even at the old threshold' {
        $welcomeBytes = ConvertFrom-UiFingerprintString $Welcome
        $passwordBytes = ConvertFrom-UiFingerprintString $Password
        Test-UiFingerprintMatch $welcomeBytes $Welcome -RejectedFingerprint $Password -MaxDistance 12 | Should -BeTrue
        Test-UiFingerprintMatch $passwordBytes $Password -RejectedFingerprint $Welcome -MaxDistance 6 | Should -BeTrue
        Test-UiFingerprintMatch $passwordBytes $Welcome -RejectedFingerprint $Password -MaxDistance 12 | Should -BeFalse
        Test-UiFingerprintMatch $welcomeBytes $Password -RejectedFingerprint $Welcome -MaxDistance 12 | Should -BeFalse
    }
    It 'fails closed when two references are equally near' {
        Test-UiFingerprintMatch -Fingerprint ([byte[]](5, 5)) -ExpectedFingerprint '0000' -RejectedFingerprint '0a0a' | Should -BeFalse
    }
}

Describe 'Static native input guard ordering' {
    It 'checks hover state, geometry, foreground, cursor and exact hit before mouse-down' {
        $click = [regex]::Match($UiSource, '(?s)public static bool Click\(.*?(?=\[StructLayout)').Value
        $move = $click.IndexOf('!SetCursorPos(x, y)')
        $wait = $click.IndexOf('Thread.Sleep(150)')
        $validate = $click.IndexOf('!validateState()')
        $recheck = $click.IndexOf('!GetWindowRect(hwnd, out current)')
        $hit = $click.LastIndexOf('!IsPointOnWindow(hwnd, x, y)')
        $down = $click.IndexOf('mouse_event(0x0002')
        $move | Should -BeGreaterThan -1
        $wait | Should -BeGreaterThan $move
        $validate | Should -BeGreaterThan $wait
        $recheck | Should -BeGreaterThan $validate
        $hit | Should -BeGreaterThan $recheck
        $down | Should -BeGreaterThan $hit
        $click | Should -Match '!ContainsRelativePoint\(current, relX, relY\)'
        $click | Should -Match '!IsForegroundWindow\(hwnd\)'
        $click | Should -Match 'cursor.X != x \|\| cursor.Y != y'
    }
    It 'uses root HWND equality rather than PID equality for hit-testing' {
        $hitTest = [regex]::Match($UiSource, '(?s)public static bool IsPointOnWindow\(.*?(?=public static bool IsForegroundWindow)').Value
        $hitTest | Should -Match 'SameRoot\(RootWindow\(hwnd\), RootWindow\(hit\)\)'
        $hitTest | Should -Not -Match 'GetWindowThreadProcessId'
    }
    It 'checks target foreground immediately before every native keyboard batch' {
        foreach ($name in 'TypeUnicode', 'PressKey', 'PressKeyWithCtrl') {
            $method = [regex]::Match($UiSource, ('(?s)public static int ' + $name + '\(.*?\n    \}')).Value
            $method | Should -Match 'RequireForeground\(target\);\s*return \(int\)SendInput'
        }
    }
}

Describe 'Static login contracts without executing worker scripts' {
    It 'gates every thinkorswim keyboard send with target HWND and a fresh state assertion' {
        $calls = @($TosAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -like 'Send-Ui*'
        }, $true))
        $calls.Count | Should -Be 4
        foreach ($call in $calls) {
            @($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Hwnd' }).Count | Should -Be 1
            $prefix = $TosSource.Substring(0, $call.Extent.StartOffset)
            $prefix | Should -Match 'Assert-TosLoginState[^\r\n]*\r?\n$'
        }
    }
    It 'requires a fresh screen callback on every coordinate-based login click' {
        foreach ($ast in $TosAst, $FutuAst) {
            $clicks = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-UiClick'
            }, $true))
            $clicks.Count | Should -BeGreaterThan 0
            foreach ($click in $clicks) {
                @($click.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ValidateState' }).Count | Should -Be 1
            }
        }
        $FutuSource | Should -Match '(?s)Show-UiWindow -Hwnd \$hwnd.*?-FromScreen.*?\$size = Get-UiWindowSize'
        $FutuSource | Should -Match '(?s)\$loginGuard = \{.*?-FromScreen\)\s*\}'
    }
    It 'never equates a changed Futubull login fingerprint with success' {
        $FutuSource | Should -Match 'if \(Test-FutubullMainWindow -Hwnd \$hwnd\)'
        $FutuSource | Should -Not -Match '\$loggedIn = \$true\s*\r?\n\s*break'
        $FutuSource | Should -Match '(?s)manual verification required.*?exit 1'
    }
    It 'waits for initial CN processes and never retries credential submission in polling loops' {
        foreach ($name in 'Q73N', 'AlgoMaster') {
            $fn = $ZsqhAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "AutoLogin-$name" }, $true)
            $fn.Extent.Text | Should -Match "Wait-AppProcess -Name $name -TimeoutSeconds"
            $submits = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq "Invoke-${name}Login" }, $true))
            $submits.Count | Should -Be 1
            $ancestor = $submits[0].Parent
            while ($ancestor -and $ancestor -ne $fn) {
                ($ancestor -is [System.Management.Automation.Language.LoopStatementAst]) | Should -BeFalse
                $ancestor = $ancestor.Parent
            }
        }
        $ZsqhSource | Should -Not -Match 'will use existing value|login window gone - logged in|no windows exposed - already logged in'
    }
    It 'recognizes an already-authenticated CN client without treating missing windows as success' {
        # Hidden top-level windows are enumerated, so the client's hide-to-tray
        # state is positive evidence; a missing window still fails.
        $ZsqhSource | Should -Match 'Get-ProcessWindowList -ProcessId \$ProcessId'
        $ZsqhSource | Should -Match '(?s)\$hiddenPolls\+\+\s*\r?\n\s*if \(\$hiddenPolls -ge 2\)'
        $ZsqhSource | Should -Match 'if \(-not \$login -or -not \$login\.Visible\) \{ throw'
    }
    It 'uses field-specific manual extraction, not SendKeys or a password fallback' {
        $manual = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/tools/type-secret.ps1') -Raw
        $manual | Should -Match 'Get-CredentialFieldValue -Entry \$e -Field \$Field'
        $manual | Should -Match 'Send-UiText -Text \$val'
        $manual | Should -Not -Match 'SendKeys|\$e\.notes'
    }
    It 'shares an exclusive login mutex and releases it in finally' {
        foreach ($source in $TosSource, $FutuSource, $ZsqhSource) {
            $source | Should -Match 'Enter-UiLoginLock'
            $source | Should -Match '(?s)finally\s*\{.*?ReleaseMutex\(\).*?Dispose\(\)'
        }
    }
}
