[CmdletBinding()]
param(
    [string]$DllPath,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'

$localDirectory = Join-Path $PSScriptRoot '.local'
$statePath = Join-Path $localDirectory 'state.json'
$patchScript = Join-Path $PSScriptRoot 'tools\PatchAds.ps1'
$originalHash = '8F7406A8A465E851EE10EAECCCB572D0E5B4E00D480C770938C714C396097B74'
$primaryPatchedHash = 'E83A63EB167F77BC2A3EDF8F5E0E7669DDFA0603240F0740F04BB27BD48E7789'
$extendedPatchedHash = '0DD1EAC8610D2A9CF8A14E1F892A806E38A6F008731F056C33AA8147F527E2CC'

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}
$originalBytes = [byte[]](0x85, 0xF6, 0x0F, 0x95, 0xC0)
$primaryPatchOffsets = [int64[]](0x5619AEA, 0x561A41A)
$pagePatchOffset = [int64]0x3C079DA
$allPatchOffsets = [int64[]]($primaryPatchOffsets + $pagePatchOffset)

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
}

function Select-File([string]$Title, [string]$Filter) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Title = $Title
        $dialog.Filter = $Filter
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            throw '未选择文件，操作已取消。'
        }
        return $dialog.FileName
    }
    finally {
        $dialog.Dispose()
    }
}

function Find-LatestBackup {
    $roots = @((Join-Path $PSScriptRoot '.local'), (Join-Path $PSScriptRoot 'backups'))
    $files = foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            Get-ChildItem -LiteralPath $root -Filter '*.original' -File -Recurse -ErrorAction SilentlyContinue
        }
    }
    return $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Test-OriginalBackup([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    try {
        return ((Get-Sha256 $Path) -eq $originalHash)
    }
    catch {
        return $false
    }
}

function Write-BytesAt([string]$Path, [int64]$Offset, [byte[]]$Bytes) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    try {
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush()
    }
    finally {
        $stream.Dispose()
    }
}

function New-RecoveredOriginalBackup([string]$SourcePath, [string]$CurrentHash) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $directory = Join-Path $localDirectory ("backups\recovered-$stamp")
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $backupPath = Join-Path $directory 'target.dll.original'
    Copy-Item -LiteralPath $SourcePath -Destination $backupPath -Force

    $offsets = if ($CurrentHash -eq $primaryPatchedHash) { $primaryPatchOffsets } else { $allPatchOffsets }
    foreach ($offset in $offsets) {
        Write-BytesAt $backupPath $offset $originalBytes
    }
    if (-not (Test-OriginalBackup $backupPath)) {
        throw '无法从当前已知补丁状态重建原版备份，已停止。'
    }
    return $backupPath
}

function Resolve-Dll([string]$RequestedPath, $State) {
    $candidate = $RequestedPath
    if ([string]::IsNullOrWhiteSpace($candidate) -and $null -ne $State) {
        $candidate = [string]$State.DllPath
    }
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        Write-Host '未找到本机路径记录，请选择安装目录中当前使用的目标 DLL。'
        $candidate = Select-File '选择要恢复的目标 DLL' '动态库 (*.dll)|*.dll|所有文件 (*.*)|*.*'
    }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    if ([System.IO.Path]::GetExtension($resolved) -ine '.dll') {
        throw '所选文件不是 DLL。'
    }
    return $resolved
}

function Resolve-Backup([string]$RequestedPath, $State, [string]$TargetDll, [string]$CurrentHash) {
    $candidate = $RequestedPath
    if ([string]::IsNullOrWhiteSpace($candidate) -and $null -ne $State) {
        $candidate = [string]$State.OriginalBackupPath
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = Find-LatestBackup
    }
    if (-not (Test-OriginalBackup $candidate) -and
        ($CurrentHash -eq $primaryPatchedHash -or $CurrentHash -eq $extendedPatchedHash)) {
        $candidate = New-RecoveredOriginalBackup $TargetDll $CurrentHash
        Write-Host "已从已验证的补丁文件重建原版备份: $candidate"
    }
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        Write-Host '未找到原版备份，请选择 Deploy.cmd 成功部署后生成的 .original 文件；不要选择当前 DLL。'
        $candidate = Select-File '选择原版备份文件' '原版备份 (*.original)|*.original|所有文件 (*.*)|*.*'
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

try {
    if (-not (Test-Path -LiteralPath $patchScript -PathType Leaf)) {
        throw "找不到补丁脚本: $patchScript"
    }
    $state = Read-State
    $targetDll = Resolve-Dll $DllPath $state
    $currentHash = Get-Sha256 $targetDll
    if ($currentHash -eq $originalHash) {
        Write-Host '当前文件已经是原版，无需恢复。'
        return
    }
    $originalBackup = Resolve-Backup $BackupPath $state $targetDll $currentHash
    & $patchScript -Mode Restore -DllPath $targetDll -BackupPath $originalBackup
    Write-Host '已恢复原版文件。'
}
catch {
    Write-Error $_
    exit 1
}
