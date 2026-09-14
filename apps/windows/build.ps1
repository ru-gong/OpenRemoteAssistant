# SPDX-License-Identifier: GPL-3.0-only
param(
    [ValidateSet('build', 'test', 'publish')][string]$Action = 'build',
    [string]$Configuration = 'Debug',
    [string]$Dotnet = 'dotnet'
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'src/OpenRemoteAssistant.Win/OpenRemoteAssistant.Win.csproj'
switch ($Action) {
    'build' { & $Dotnet build $project -c $Configuration }
    'test' {
        & $Dotnet test (Join-Path $PSScriptRoot 'tests/OpenRemoteAssistant.Tests/OpenRemoteAssistant.Tests.csproj') -c $Configuration
    }
    'publish' {
        $destination = Join-Path $PSScriptRoot 'dist'
        & $Dotnet publish $project -c Release -r win-x64 --self-contained true `
            -p:PublishSingleFile=true -p:PublishTrimmed=false `
            -p:IncludeNativeLibrariesForSelfExtract=true -o $destination
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        foreach ($name in @('README.md', 'LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md', 'licenses', 'docs')) {
            Copy-Item (Join-Path $PSScriptRoot $name) $destination -Recurse -Force
        }
    }
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
