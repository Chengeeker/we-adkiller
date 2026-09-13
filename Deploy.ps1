[CmdletBinding()]
param(
    [string]$DllPath
)

$ErrorActionPreference = 'Stop'

$localDirectory = Join-Path $PSScriptRoot '.local'
$statePath = Join-Path $localDirectory 'state.json'
$patchScript = Join-Path $PSScriptRoot 'tools\PatchAds.ps1'
$originalHash = '8F7406A8A465E851EE10EAECCCB572D0E5B4E00D480C770938C714C396097B74'
$primaryPatchedHash = 'E83A63EB167F77BC2A3EDF8F5E0E7669DDFA0603240F0740F04BB27BD48E7789'
$extendedPatchedHash = '0DD1EAC8610D2A9CF8A14E1F892A806E38A6F008731F056C33AA8147F527E2CC'
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

function Test-OriginalBackup([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    try {
        return ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant() -eq $originalHash)
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
    $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetDll).Hash.ToUpperInvariant()
    $originalBackup = $null
    $previousBackup = $null

    if ($currentHash -eq $extendedPatchedHash) {
        Write-Host '当前状态已经是完整部署状态。'
        if ($null -ne $state) {
            $originalBackup = [string]$state.OriginalBackupPath
            $previousBackup = [string]$state.PreviousBackupPath
        }
        if ([string]::IsNullOrWhiteSpace($originalBackup)) {
            $originalBackup = Find-LatestBackup '*.original'
        }
        if (-not (Test-OriginalBackup $originalBackup)) {
            $originalBackup = New-RecoveredOriginalBackup $targetDll $currentHash
            Write-Host "已从已验证的补丁文件重建原版备份: $originalBackup"
        }
        if ([string]::IsNullOrWhiteSpace($previousBackup)) {
            $previousBackup = Find-LatestBackup '*.previous'
        }
    }
    elseif ($currentHash -eq $originalHash) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $originalBackup = New-BackupPath 'original' $stamp
        $previousBackup = Join-Path $localDirectory ("backups\page-$stamp\target.dll.previous")
        & $patchScript -Mode Plan -DllPath $targetDll
        & $patchScript -Mode Apply -DllPath $targetDll -BackupPath $originalBackup
        & $patchScript -Mode ExtendPage -DllPath $targetDll -BackupPath $previousBackup
    }
    elseif ($currentHash -eq $primaryPatchedHash) {
        if ($null -ne $state) {
            $originalBackup = [string]$state.OriginalBackupPath
        }
        if (-not (Test-OriginalBackup $originalBackup)) {
            $originalBackup = Find-LatestBackup '*.original'
        }
        if (-not (Test-OriginalBackup $originalBackup)) {
            $originalBackup = New-RecoveredOriginalBackup $targetDll $currentHash
            Write-Host "已从已验证的补丁文件重建原版备份: $originalBackup"
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $previousBackup = Join-Path $localDirectory ("backups\page-$stamp\target.dll.previous")
        & $patchScript -Mode ExtendPage -DllPath $targetDll -BackupPath $previousBackup
    }
    else {
        throw "目标文件哈希不在已验证状态列表中: $currentHash"
    }

    Save-State @{
        SchemaVersion = 1
        DllPath = $targetDll
        OriginalBackupPath = $originalBackup
        PreviousBackupPath = $previousBackup
        LastAction = 'deployed'
    }
    Write-Host '部署完成。请启动客户端并检查目标页面。'
}
catch {
    Write-Error $_
    exit 1
}
