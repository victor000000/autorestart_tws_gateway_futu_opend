@{
    # Deliberate, actionable correctness/security checks, not the noisy default
    # style rules. Runtime Win32 automation and legacy parameter names are
    # outside this static policy; behavior is covered by offline fixtures.
    IncludeRules = @(
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingBrokenHashAlgorithms'
        'PSAvoidUsingDeprecatedManifestFields'
        'PSUseToExportFieldsInManifest'
        'PSAvoidUsingCmdletAliases'
        'PSUseCompatibleSyntax'
        'PSUseBOMForUnicodeEncodedFile'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
    }
    Severity = @('Error', 'Warning')
}
