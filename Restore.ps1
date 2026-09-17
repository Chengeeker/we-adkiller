[CmdletBinding()]
param(
    [string]$DllPath,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'

$localDirectory = Join-Path $PSScriptRoot '.local'
$statePath = Join-Path $localDirectory 'state.json'
$patchScript = Join-Path $PSScriptRoot 'tools\PatchAds.ps1'
$profileScript = Join-Path $PSScriptRoot 'tools\PatchProfile.ps1'
if (-not (Test-Path -LiteralPath $profileScript -PathType Leaf)) {
    throw "找不到定位模块: $profileScript"
}
. $profileScript

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

function New-RecoveredOriginalBackup([string]$SourcePath, $Profile) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $directory = Join-Path $localDirectory ("backups\recovered-$stamp")
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $backupPath = Join-Path $directory 'target.dll.original'
    Copy-Item -LiteralPath $SourcePath -Destination $backupPath -Force

    foreach ($offset in $Profile.AllPatchOffsets) {
        Write-BytesAt $backupPath $offset $script:OriginalPatchBytes
    }
    $recoveredProfile = Get-PatchProfile $backupPath ''
    if ($recoveredProfile.CurrentState -ne 'Original' -or
        -not (Test-ProfileOffsetsEqual $Profile $recoveredProfile)) {
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

function Resolve-Backup([string]$RequestedPath, $State, [string]$TargetDll, $TargetProfile, [string]$ExpectedOriginalHash) {
    $candidate = $RequestedPath
    if ([string]::IsNullOrWhiteSpace($candidate) -and $null -ne $State) {
        $candidate = [string]$State.OriginalBackupPath
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = Find-LatestBackup
    }
    if (-not (Test-OriginalBackup $candidate $TargetProfile $ExpectedOriginalHash) -and
        ($TargetProfile.CurrentState -eq 'PrimaryPatched' -or $TargetProfile.CurrentState -eq 'ExtendedPatched')) {
        $candidate = New-RecoveredOriginalBackup $TargetDll $TargetProfile
        Write-Host "已从已验证的补丁文件重建原版备份: $candidate"
    }
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        Write-Host '未找到原版备份，请选择 Deploy.cmd 成功部署后生成的 .original 文件；不要选择当前 DLL。'
        $candidate = Select-File '选择原版备份文件' '原版备份 (*.original)|*.original|所有文件 (*.*)|*.*'
    }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    if (-not (Test-OriginalBackup $resolved $TargetProfile $ExpectedOriginalHash)) {
        throw '所选文件不是同一 profile 的可验证原版备份，拒绝恢复。'
    }
    return $resolved
}

try {
    if (-not (Test-Path -LiteralPath $patchScript -PathType Leaf)) {
        throw "找不到补丁脚本: $patchScript"
    }
    $state = Read-State
    $targetDll = Resolve-Dll $DllPath $state
    $expectedOriginalHash = if ($null -ne $state) { [string]$state.OriginalHash } else { '' }
    $profile = Get-PatchProfile $targetDll $expectedOriginalHash
    if ($profile.CurrentState -eq 'Original') {
        Write-Host '当前文件已经是原版，无需恢复。'
        return
    }
    $originalBackup = Resolve-Backup $BackupPath $state $targetDll $profile $expectedOriginalHash
    $backupHash = Get-Sha256 $originalBackup
    & $patchScript -Mode Restore -DllPath $targetDll -BackupPath $originalBackup -ExpectedOriginalHash $backupHash
    Write-Host '已恢复原版文件。'
}
catch {
    Write-Error $_
    exit 1
}
