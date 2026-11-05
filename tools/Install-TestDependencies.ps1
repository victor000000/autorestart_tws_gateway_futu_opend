#Requires -Version 5.1
<#
.SYNOPSIS
Explicitly download the pinned, project-local test dependencies from PSGallery.
.DESCRIPTION
This is the only test command that accesses the network. It does not install a
NuGet provider, register/trust a repository, change execution policy, or import
the downloaded modules. The default destination is ignored .tools/Modules.
#>
[CmdletBinding()]
param(
    [string]$ModulesPath
)

$ErrorActionPreference = 'Stop'
if (-not $ModulesPath) {
    $ModulesPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.tools/Modules'
}
$ModulesPath = [System.IO.Path]::GetFullPath($ModulesPath)
$dependencies = @(
    @{ Name = 'Pester'; Version = '5.7.1' }
    @{ Name = 'PSScriptAnalyzer'; Version = '1.24.0' }
)

# Direct package downloads avoid PowerShellGet/NuGet bootstrap prompts on PS 5.1.
# TLS is changed for this process only and restored before returning.
$previousProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $ModulesPath -Force | Out-Null
    foreach ($dependency in $dependencies) {
        $name = $dependency.Name
        $version = $dependency.Version
        $moduleDirectory = Join-Path $ModulesPath $name
        $versionDirectory = Join-Path $moduleDirectory $version
        $manifestPath = Join-Path $versionDirectory "$name.psd1"
        if (Test-Path -LiteralPath $versionDirectory) {
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                throw "Incomplete dependency at '$versionDirectory'. Remove that directory and rerun this bootstrap."
            }
            $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
            if ([version]$manifest.ModuleVersion -ne [version]$version) {
                throw "Unexpected module version in '$manifestPath'; expected $version."
            }
            Write-Host "$name $version is already available at $versionDirectory"
            continue
        }

        # Each download and extraction has its own new, empty directory. Never
        # execute scripts from package staging directories or change into them.
        $workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('trading-app-tests-' + [guid]::NewGuid().ToString('N'))
        $downloadDirectory = Join-Path $workspace 'download'
        $extractionDirectory = Join-Path $workspace 'extract'
        New-Item -ItemType Directory -Path $downloadDirectory, $extractionDirectory | Out-Null
        try {
            $archive = Join-Path $downloadDirectory "$name.$version.zip"
            $uri = 'https://www.powershellgallery.com/api/v2/package/{0}/{1}' -f $name, $version
            Write-Host "Downloading $name $version from PSGallery..."
            Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing -ErrorAction Stop
            Expand-Archive -LiteralPath $archive -DestinationPath $extractionDirectory -ErrorAction Stop
            $downloadedManifest = Join-Path $extractionDirectory "$name.psd1"
            if (-not (Test-Path -LiteralPath $downloadedManifest -PathType Leaf)) {
                throw "PSGallery package $name $version did not contain its expected manifest."
            }
            $manifest = Import-PowerShellDataFile -LiteralPath $downloadedManifest
            if ([version]$manifest.ModuleVersion -ne [version]$version) {
                throw "PSGallery package $name has unexpected version '$($manifest.ModuleVersion)'."
            }
            New-Item -ItemType Directory -Path $moduleDirectory -Force | Out-Null
            Move-Item -LiteralPath $extractionDirectory -Destination $versionDirectory -ErrorAction Stop
            Write-Host "Installed $name $version to $versionDirectory"
        }
        finally {
            if (Test-Path -LiteralPath $workspace) {
                Remove-Item -LiteralPath $workspace -Recurse -Force
            }
        }
    }
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
}

Write-Host 'Dependencies are ready. Run tools/Test-Project.ps1; it never downloads dependencies.'
