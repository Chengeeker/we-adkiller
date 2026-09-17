[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Apply', 'ExtendPage', 'RestorePrevious', 'Restore')]
    [string]$Mode = 'Plan',
    [Parameter(Mandatory = $true)]
    [string]$DllPath,
    [string]$BackupPath,
    [string]$ExpectedOriginalHash
)

$ErrorActionPreference = 'Stop'

$profileScript = Join-Path $PSScriptRoot 'PatchProfile.ps1'
if (-not (Test-Path -LiteralPath $profileScript -PathType Leaf)) {
    throw "找不到定位模块: $profileScript"
}
. $profileScript

function Get-TargetRoot([string]$Path) {
    $versionDirectory = [System.IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrWhiteSpace($versionDirectory)) {
        throw "无法从 DLL 路径确定安装目录: $Path"
    }
    $root = [System.IO.Path]::GetDirectoryName($versionDirectory)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "无法从 DLL 路径确定安装根目录: $Path"
    }
    return $root
}

function Get-TargetProcesses([string]$Path) {
    $targetRoot = Get-TargetRoot $Path
    $normalizedRoot = [System.IO.Path]::GetFullPath($targetRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $matches = @()

    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $module = $process.MainModule
            $executablePath = if ($null -eq $module) { '' } else { $module.FileName }
            if (-not [string]::IsNullOrEmpty($executablePath) -and
                $executablePath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matches += $process
            }
        }
        catch {
            # Some system processes deny module inspection.
        }
    }
    return $matches
}

function Assert-TargetStopped([string]$Path) {
    $running = @(Get-TargetProcesses $Path)
    if ($running.Count -gt 0) {
        $ids = ($running | ForEach-Object { $_.Id }) -join ', '
        throw "目标客户端仍在运行（PID: $ids）。请先正常退出。"
    }
}

if (-not (Test-Path -LiteralPath $DllPath -PathType Leaf)) {
    throw "找不到 DLL: $DllPath"
}
$DllPath = (Resolve-Path -LiteralPath $DllPath).Path

$profile = Get-PatchProfile $DllPath $ExpectedOriginalHash
$currentHash = $profile.CurrentHash
$originalBytes = $script:OriginalPatchBytes
$patchedBytes = $script:PatchedPatchBytes
$primaryPatchOffsets = $profile.PrimaryPatchOffsets
$pagePatchOffset = $profile.PagePatchOffset
$allPatchOffsets = $profile.AllPatchOffsets
$states = @()
foreach ($offset in $allPatchOffsets) {
    $bytes = Read-BytesAt $DllPath $offset
    $states += (Convert-ToHex $bytes)
}

Write-Output "DLL: $DllPath"
Write-Output "SHA256: $currentHash"
Write-Output "Profile: $($profile.Name)"
Write-Output "Confidence: $($profile.Confidence)"
Write-Output "State: $($profile.CurrentState)"
Write-Output ("Patch offsets: " + (($allPatchOffsets | ForEach-Object { '0x{0:X}' -f $_ }) -join ', '))
Write-Output ("Current bytes: " + ($states -join ' | '))

if ($Mode -eq 'Plan') {
    if ($profile.CurrentState -ne 'Original') {
        throw "当前 DLL 状态为 $($profile.CurrentState)，不是可部署的原版状态；停止计划。"
    }
    foreach ($offset in $allPatchOffsets) {
        $bytes = Read-BytesAt $DllPath $offset
        if (-not (Test-BytesEqual $bytes $originalBytes)) {
            throw "补丁位置 0x$('{0:X}' -f $offset) 的原始字节不匹配，停止计划。"
        }
    }
    Write-Output 'PLAN_OK: 三处位置均已通过自适应校验；未修改文件。'
    return
}

if ($Mode -eq 'Apply') {
    Assert-TargetStopped $DllPath
    if ($profile.CurrentState -ne 'Original') {
        throw "当前 DLL 状态为 $($profile.CurrentState)，拒绝修改。"
    }

    foreach ($offset in $allPatchOffsets) {
        $bytes = Read-BytesAt $DllPath $offset
        if (-not (Test-BytesEqual $bytes $originalBytes)) {
            throw "补丁位置 0x$('{0:X}' -f $offset) 的原始字节不匹配，拒绝修改。"
        }
    }

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $BackupPath = Join-Path $PSScriptRoot ("..\backups\apply-$stamp\target.dll.original")
    }
    $backupDirectory = Split-Path -Parent $BackupPath
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    Copy-Item -LiteralPath $DllPath -Destination $BackupPath -Force
    if ((Get-Sha256 $BackupPath) -ne $currentHash) {
        throw '原版备份哈希不一致，拒绝继续修改。'
    }

    foreach ($offset in $primaryPatchOffsets) {
        Write-BytesAt $DllPath $offset $patchedBytes
    }
    foreach ($offset in $primaryPatchOffsets) {
        if (-not (Test-BytesEqual (Read-BytesAt $DllPath $offset) $patchedBytes)) {
            throw "写入后校验失败：0x$('{0:X}' -f $offset)。"
        }
    }
    $afterProfile = Get-PatchProfile $DllPath $currentHash
    if ($afterProfile.CurrentState -ne 'PrimaryPatched' -or
        -not (Test-ProfileOffsetsEqual $profile $afterProfile)) {
        throw '写入后自适应状态校验失败，拒绝报告成功。'
    }
    $afterHash = Get-Sha256 $DllPath
    Write-Output "APPLIED: $afterHash"
    Write-Output "BACKUP: $BackupPath"
    return
}

if ($Mode -eq 'ExtendPage') {
    Assert-TargetStopped $DllPath
    if ($profile.CurrentState -ne 'PrimaryPatched') {
        throw "当前 DLL 状态为 $($profile.CurrentState)，不是前两处补丁状态，拒绝追加页面候选补丁。"
    }

    foreach ($offset in $primaryPatchOffsets) {
        if (-not (Test-BytesEqual (Read-BytesAt $DllPath $offset) $patchedBytes)) {
            throw "当前 DLL 在 0x$('{0:X}' -f $offset) 不是预期的已补丁字节，拒绝追加修改。"
        }
    }
    if (-not (Test-BytesEqual (Read-BytesAt $DllPath $pagePatchOffset) $originalBytes)) {
        throw "页面候选位置 0x$('{0:X}' -f $pagePatchOffset) 不是预期原始字节，拒绝追加修改。"
    }

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $BackupPath = Join-Path $PSScriptRoot ("..\backups\before-page-$stamp\target.dll.previous")
    }
    $backupDirectory = Split-Path -Parent $BackupPath
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    Copy-Item -LiteralPath $DllPath -Destination $BackupPath -Force
    if ((Get-Sha256 $BackupPath) -ne $currentHash) {
        throw '追加前备份哈希不一致，拒绝继续修改。'
    }

    Write-BytesAt $DllPath $pagePatchOffset $patchedBytes
    if (-not (Test-BytesEqual (Read-BytesAt $DllPath $pagePatchOffset) $patchedBytes)) {
        throw '页面候选补丁写入后校验失败。'
    }
    $afterProfile = Get-PatchProfile $DllPath $profile.OriginalHash
    if ($afterProfile.CurrentState -ne 'ExtendedPatched' -or
        -not (Test-ProfileOffsetsEqual $profile $afterProfile)) {
        throw '追加后自适应状态校验失败，拒绝报告成功。'
    }
    $afterHash = Get-Sha256 $DllPath
    Write-Output "EXTENDED: $afterHash"
    Write-Output "PREVIOUS_BACKUP: $BackupPath"
    return
}

if ($Mode -eq 'RestorePrevious') {
    Assert-TargetStopped $DllPath
    if ($profile.CurrentState -ne 'ExtendedPatched') {
        throw "当前 DLL 状态为 $($profile.CurrentState)，不是完整补丁状态，拒绝撤销页面候选。"
    }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'RestorePrevious 必须提供 -BackupPath。'
    }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw "找不到追加前备份: $BackupPath"
    }
    $backupProfile = Get-PatchProfile $BackupPath $profile.OriginalHash
    if ($backupProfile.CurrentState -ne 'PrimaryPatched' -or
        -not (Test-ProfileOffsetsEqual $profile $backupProfile)) {
        throw '追加前备份不是同一补丁 profile 的前两处状态，拒绝恢复。'
    }
    Copy-Item -LiteralPath $BackupPath -Destination $DllPath -Force
    $afterProfile = Get-PatchProfile $DllPath $profile.OriginalHash
    if ($afterProfile.CurrentState -ne 'PrimaryPatched' -or
        -not (Test-ProfileOffsetsEqual $profile $afterProfile)) {
        throw '撤销页面候选补丁后状态不一致。'
    }
    return
}

if ($Mode -eq 'Restore') {
    Assert-TargetStopped $DllPath
    if ($profile.CurrentState -ne 'PrimaryPatched' -and $profile.CurrentState -ne 'ExtendedPatched') {
        throw "当前 DLL 状态为 $($profile.CurrentState)，不是可恢复的补丁状态。"
    }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'Restore 必须提供 -BackupPath。'
    }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw "找不到备份: $BackupPath"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedOriginalHash) -and
        (Get-Sha256 $BackupPath) -ne $ExpectedOriginalHash) {
        throw '备份哈希与状态记录不一致，拒绝恢复。'
    }
    $backupProfile = Get-PatchProfile $BackupPath $ExpectedOriginalHash
    if ($backupProfile.CurrentState -ne 'Original' -or
        -not (Test-ProfileOffsetsEqual $profile $backupProfile)) {
        throw '备份不是同一补丁 profile 的原版状态，拒绝恢复。'
    }
    Copy-Item -LiteralPath $BackupPath -Destination $DllPath -Force
    $afterProfile = Get-PatchProfile $DllPath $ExpectedOriginalHash
    if ($afterProfile.CurrentState -ne 'Original' -or
        (Get-Sha256 $DllPath) -ne (Get-Sha256 $BackupPath)) {
        throw '恢复后自适应状态或哈希不一致。'
    }
    return
}
