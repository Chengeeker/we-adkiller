[CmdletBinding()]
param(
    [string]$DllPath
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

function Select-Dll {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        Write-Host '首次运行需要选择目标版本 DLL；请选择版本目录中的 DLL 文件，不是 EXE。'
        $dialog.Title = '首次运行：选择目标版本 DLL（不是 EXE）'
        $dialog.Filter = '动态库 (*.dll)|*.dll|所有文件 (*.*)|*.*'
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            throw '未选择 DLL，操作已取消。'
        }
        return $dialog.FileName
    }
    finally {
        $dialog.Dispose()
    }
}

function Resolve-Dll([string]$RequestedPath, $State) {
    $candidate = $RequestedPath
    if ([string]::IsNullOrWhiteSpace($candidate) -and $null -ne $State) {
        $candidate = [string]$State.DllPath
    }
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $candidate = Select-Dll
    }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    if ([System.IO.Path]::GetExtension($resolved) -ine '.dll') {
        throw '所选文件不是 DLL。'
    }
    return $resolved
}

function Save-State($State) {
    New-Item -ItemType Directory -Path $localDirectory -Force | Out-Null
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Find-LatestBackup([string]$Pattern) {
    $roots = @($localDirectory, (Join-Path $PSScriptRoot 'backups'))
    $files = foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            Get-ChildItem -LiteralPath $root -Filter $Pattern -File -Recurse -ErrorAction SilentlyContinue
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

function New-BackupPath([string]$Kind, [string]$Stamp) {
    $directory = Join-Path $localDirectory ("backups\$Kind-$Stamp")
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $fileName = if ($Kind -eq 'original') { 'target.dll.original' } else { 'target.dll.previous' }
    return Join-Path $directory $fileName
}

try {
    if (-not (Test-Path -LiteralPath $patchScript -PathType Leaf)) {
        throw "找不到补丁脚本: $patchScript"
    }

    $state = Read-State
    $targetDll = Resolve-Dll $DllPath $state
    $expectedOriginalHash = if ($null -ne $state) { [string]$state.OriginalHash } else { '' }
    $profile = Get-PatchProfile $targetDll $expectedOriginalHash
    $currentHash = $profile.CurrentHash
    $originalBackup = $null
    $previousBackup = $null

    if ($profile.CurrentState -eq 'ExtendedPatched') {
        Write-Host "当前状态已经是完整部署状态（$($profile.Name)）。"
        if ($null -ne $state) {
            $originalBackup = [string]$state.OriginalBackupPath
            $previousBackup = [string]$state.PreviousBackupPath
        }
        if ([string]::IsNullOrWhiteSpace($originalBackup)) {
            $originalBackup = Find-LatestBackup '*.original'
        }
        if (-not (Test-OriginalBackup $originalBackup $profile $expectedOriginalHash)) {
            $originalBackup = New-RecoveredOriginalBackup $targetDll $profile
            Write-Host "已从已验证的补丁文件重建原版备份: $originalBackup"
        }
        if ([string]::IsNullOrWhiteSpace($previousBackup)) {
            $previousBackup = Find-LatestBackup '*.previous'
        }
    }
    elseif ($profile.CurrentState -eq 'Original') {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $originalBackup = New-BackupPath 'original' $stamp
        $previousBackup = Join-Path $localDirectory ("backups\page-$stamp\target.dll.previous")
        & $patchScript -Mode Plan -DllPath $targetDll
        & $patchScript -Mode Apply -DllPath $targetDll -BackupPath $originalBackup
        & $patchScript -Mode ExtendPage -DllPath $targetDll -BackupPath $previousBackup
    }
    elseif ($profile.CurrentState -eq 'PrimaryPatched') {
        if ($null -ne $state) {
            $originalBackup = [string]$state.OriginalBackupPath
        }
        if (-not (Test-OriginalBackup $originalBackup $profile $expectedOriginalHash)) {
            $originalBackup = Find-LatestBackup '*.original'
        }
        if (-not (Test-OriginalBackup $originalBackup $profile $expectedOriginalHash)) {
            $originalBackup = New-RecoveredOriginalBackup $targetDll $profile
            Write-Host "已从已验证的补丁文件重建原版备份: $originalBackup"
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $previousBackup = Join-Path $localDirectory ("backups\page-$stamp\target.dll.previous")
        & $patchScript -Mode ExtendPage -DllPath $targetDll -BackupPath $previousBackup
    }
    else {
        throw "目标文件状态无法安全识别: $currentHash"
    }

    $originalHash = if ([string]::IsNullOrWhiteSpace($originalBackup)) { '' } else { Get-Sha256 $originalBackup }
    Save-State @{
        SchemaVersion = 1
        DllPath = $targetDll
        OriginalBackupPath = $originalBackup
        PreviousBackupPath = $previousBackup
        OriginalHash = $originalHash
        PatchProfile = $profile.Name
        LastAction = 'deployed'
    }
    Write-Host '部署完成。请启动客户端并检查目标页面。'
}
catch {
    Write-Error $_
    exit 1
}
