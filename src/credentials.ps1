function ConvertFrom-DpapiHexString {
    param([Parameter(Mandatory = $true)][string]$Hex)
    $text = $Hex.Trim()
    if ($text.Length -eq 0 -or $text.Length % 2 -ne 0 -or $text -notmatch '\A[0-9a-fA-F]+\z') {
        throw 'The encrypted credential store is not valid DPAPI hexadecimal data.'
    }
    Add-Type -AssemblyName System.Security
    $bytes = New-Object byte[] ($text.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($text.Substring($i * 2, 2), 16)
    }
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
        $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::Unicode.GetString($plain) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
}

function Get-StoredCredentials {
    $path = Join-Path $ProjectRoot 'secrets/credentials.sec'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($path).Trim()
        try {
            $secure = ConvertTo-SecureString -String $raw -ErrorAction Stop
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $json = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        }
        catch { $json = ConvertFrom-DpapiHexString -Hex $raw }
        return ($json | ConvertFrom-Json -ErrorAction Stop)
    }
    catch { throw 'The local credential store could not be decrypted or parsed for this Windows user.' }
}

function Protect-PrivateFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $acl = New-Object Security.AccessControl.FileSecurity
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $acl.SetSecurityDescriptorSddlForm("D:P(A;;FA;;;$user)(A;;FA;;;SY)",
        [Security.AccessControl.AccessControlSections]::Access)
    # Write the DACL only; Set-Acl can attempt an audit/SACL write requiring elevation.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [IO.FileSystemAclExtensions]::SetAccessControl((New-Object IO.FileInfo($Path)), $acl)
    }
    else { [IO.File]::SetAccessControl($Path, $acl) }
}

function Write-PrivateTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $destination = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        # Restrict the empty staging file before placing any credential material in it.
        [IO.File]::WriteAllText($temporary, '')
        Protect-PrivateFile -Path $temporary
        [IO.File]::WriteAllText($temporary, $Text, [Text.Encoding]::ASCII)
        if ([IO.File]::Exists($destination)) {
            Protect-PrivateFile -Path $destination
            [IO.File]::Replace($temporary, $destination, [System.Management.Automation.Language.NullString]::Value)
        }
        else { [IO.File]::Move($temporary, $destination) }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Save-StoredCredentials {
    param([Parameter(Mandatory = $true)]$Store)
    $json = $Store | ConvertTo-Json -Depth 16 -ErrorAction Stop
    $secure = ConvertTo-SecureString -String $json -AsPlainText -Force -ErrorAction Stop
    $encrypted = ConvertFrom-SecureString -SecureString $secure -ErrorAction Stop
    Write-PrivateTextFile -Path (Join-Path $ProjectRoot 'secrets/credentials.sec') -Text $encrypted
}

function Get-OnePasswordCliPath {
    $command = Get-Command op.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Packages/AgileBits.1Password.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe/op.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Get-OnePasswordIbkrCredentials {
    param([string]$ItemId = 'qhhuqifb3anutix6qbca6emena')
    try {
        $executable = Get-OnePasswordCliPath
        if (-not $executable) { return $null }
        $raw = & $executable item get $ItemId --format json 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $item = $raw | ConvertFrom-Json -ErrorAction Stop
        $username = ($item.fields | Where-Object { $_.id -eq 'username' } | Select-Object -First 1).value
        $password = ($item.fields | Where-Object { $_.id -eq 'password' } | Select-Object -First 1).value
        if ($username -and $password) { return @{ Username = $username; Password = $password } }
    }
    catch { return $null }
    return $null
}

function Get-CredentialFieldValue {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [ValidateSet('username', 'password')][string]$Field = 'password'
    )
    $value = $Entry.$Field
    if ($value) { return [string]$value }
    if ($Field -eq 'password' -and $Entry.notes) {
        if ([string]$Entry.notes -match '(?im)^\s*(?:交易(?:密码|mm)|密码|password)\s*[:：=]?\s+(\S+)\s*$' -or
                [string]$Entry.notes -match '(?im)^\s*(?:交易(?:密码|mm)|密码|password)\s*[:：=]\s*(\S+)\s*$') {
            return $Matches[1]
        }
    }
    throw "No $Field is available in the requested credential entry."
}

function ConvertTo-JavaPropertyValue {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $builder = New-Object Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        switch ([int]$character) {
            9 { [void]$builder.Append('\t') }
            10 { [void]$builder.Append('\n') }
            13 { [void]$builder.Append('\r') }
            12 { [void]$builder.Append('\f') }
            32 { [void]$builder.Append('\ ') }
            92 { [void]$builder.Append('\\') }
            default {
                if ([int]$character -lt 32 -or [int]$character -gt 126) {
                    [void]$builder.Append(('\u{0:x4}' -f [int]$character))
                }
                else { [void]$builder.Append($character) }
            }
        }
    }
    return $builder.ToString()
}

function New-IbcConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$LogName = 'ibgateway',
        [ValidateSet('live', 'paper')][string]$TradingMode = 'live'
    )
    $credentials = $null
    $source = 'local encrypted store'
    try {
        $store = Get-StoredCredentials
        $entry = if ($TradingMode -eq 'paper') { $store.ibkr_tws_gateway_paper } else { $store.ibkr_tws_gateway }
        if ($entry -and $entry.username -and $entry.password) {
            $credentials = @{ Username = $entry.username; Password = $entry.password }
        }
    }
    catch { Write-AppLog 'WARNING: local credential store unavailable; trying 1Password.' $LogName }
    if (-not $credentials -and $TradingMode -eq 'paper') { throw 'Dedicated IBKR paper credentials unavailable; live credentials are never used for paper startup.' }
    if (-not $credentials) {
        $credentials = Get-OnePasswordIbkrCredentials
        $source = '1Password CLI'
    }
    if (-not $credentials -or -not $credentials.Username -or -not $credentials.Password) { return $false }
    # IBC trims property values after loading; these inputs cannot round-trip exactly.
    foreach ($value in @([string]$credentials.Username, [string]$credentials.Password)) {
        if ($value -cne $value.Trim() -or $value -match '[\x00-\x1f\x7f]') {
            throw 'IBC credentials cannot contain control characters or surrounding whitespace.'
        }
    }
    $content = @(
        '# Generated for IBC; contains plaintext credentials. Do not commit.'
        'FIX=no'
        ('IbLoginId=' + (ConvertTo-JavaPropertyValue -Value $credentials.Username))
        ('IbPassword=' + (ConvertTo-JavaPropertyValue -Value $credentials.Password))
        ('TradingMode=' + $TradingMode)
        'SecondFactorDevice=Passkey'
    ) -join "`r`n"
    if ($TradingMode -eq 'paper') { $content += "`r`nOverrideTwsApiPort=4001`r`n" }
    Write-PrivateTextFile -Path $Path -Text ($content + "`r`n")
    Write-AppLog "IBC configuration written from $source." $LogName
    return $true
}
