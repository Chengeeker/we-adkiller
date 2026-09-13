[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist')
)

$ErrorActionPreference = 'Stop'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$uiAutomationClient = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationClient.dll'
$uiAutomationTypes = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationTypes.dll'

foreach ($path in @($csc, $uiAutomationClient, $uiAutomationTypes)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "找不到构建依赖: $path"
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$commonArgs = @(
    '/nologo',
    '/target:exe',
    '/optimize+',
    '/reference:System.dll',
    '/reference:System.Core.dll',
    "/reference:$uiAutomationClient",
    "/reference:$uiAutomationTypes"
)

$sources = @(
    @{ Name = 'AdCleaner'; Source = 'AdCleaner.cs' },
    @{ Name = 'UiProbe'; Source = 'UiProbe.cs' },
    @{ Name = 'UiClick'; Source = 'UiClick.cs' }
)

foreach ($item in $sources) {
    $sourcePath = Join-Path $PSScriptRoot $item.Source
    $outputPath = Join-Path $OutputDirectory ($item.Name + '.exe')
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "找不到源文件: $sourcePath"
    }
    & $csc @commonArgs "/out:$outputPath" $sourcePath
    if ($LASTEXITCODE -ne 0) {
        throw "编译失败: $sourcePath"
    }
    Write-Output "BUILT: $outputPath"
}
