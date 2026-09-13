[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Apply', 'ExtendPage', 'RestorePrevious', 'Restore')]
    [string]$Mode = 'Plan',
    [Parameter(Mandatory = $true)]
    [string]$DllPath,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'

$originalHash = '8F7406A8A465E851EE10EAECCCB572D0E5B4E00D480C770938C714C396097B74'
$primaryPatchedHash = 'E83A63EB167F77BC2A3EDF8F5E0E7669DDFA0603240F0740F04BB27BD48E7789'
$extendedPatchedHash = '0DD1EAC8610D2A9CF8A14E1F892A806E38A6F008731F056C33AA8147F527E2CC'
$originalBytes = [byte[]](0x85, 0xF6, 0x0F, 0x95, 0xC0)
$patchedBytes = [byte[]](0x31, 0xC0, 0x90, 0x90, 0x90)
$primaryPatchOffsets = [int64[]](0x5619AEA, 0x561A41A)
$pagePatchOffset = [int64]0x3C079DA
$allPatchOffsets = [int64[]]($primaryPatchOffsets + $pagePatchOffset)

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

function Read-BytesAt([string]$Path, [int64]$Offset) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $result = New-Object byte[] $originalBytes.Length
        $read = $stream.Read($result, 0, $result.Length)
        if ($read -ne $result.Length) {
            throw "无法读取补丁位置 0x$('{0:X}' -f $Offset)。"
        }
        return $result
    }
    finally {
        $stream.Dispose()
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

function Test-BytesEqual([byte[]]$Left, [byte[]]$Right) {
    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) {
            return $false
        }
    }
    return $true
}

if (-not (Test-Path -LiteralPath $DllPath -PathType Leaf)) {
    throw "找不到 DLL: $DllPath"
}
$DllPath = (Resolve-Path -LiteralPath $DllPath).Path

$currentHash = Get-Sha256 $DllPath
$states = @()
foreach ($offset in $allPatchOffsets) {
    $bytes = Read-BytesAt $DllPath $offset
    $states += (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
}

Write-Output "DLL: $DllPath"
Write-Output "SHA256: $currentHash"
Write-Output ("Patch offsets: " + (($allPatchOffsets | ForEach-Object { '0x{0:X}' -f $_ }) -join ', '))
Write-Output ("Current bytes: " + ($states -join ' | '))

if ($Mode -eq 'Plan') {
    if ($currentHash -ne $originalHash) {
        throw '当前 DLL 不是已验证的原版文件，停止计划。'
    }
    foreach ($offset in $allPatchOffsets) {
        $bytes = Read-BytesAt $DllPath $offset
        if (-not (Test-BytesEqual $bytes $originalBytes)) {
            throw "补丁位置 0x$('{0:X}' -f $offset) 的原始字节不匹配，停止计划。"
        }
    }
    Write-Output 'PLAN_OK: 三处位置均为预期原始字节；未修改文件。'
    return
}

if ($Mode -eq 'Apply') {
    Assert-TargetStopped $DllPath
    if ($currentHash -ne $originalHash) {
        throw '当前 DLL 不是已验证的原版文件，拒绝修改。'
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
    if ((Get-Sha256 $BackupPath) -ne $originalHash) {
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
    $afterHash = Get-Sha256 $DllPath
    Write-Output "APPLIED: $afterHash"
    Write-Output "BACKUP: $BackupPath"
    return
}

if ($Mode -eq 'ExtendPage') {
    Assert-TargetStopped $DllPath
    if ($currentHash -ne $primaryPatchedHash) {
        throw '当前 DLL 不是已验证的前两处补丁状态，拒绝追加页面候选补丁。'
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
    $afterHash = Get-Sha256 $DllPath
    Write-Output "EXTENDED: $afterHash"
    Write-Output "PREVIOUS_BACKUP: $BackupPath"
    return
}

if ($Mode -eq 'RestorePrevious') {
    Assert-TargetStopped $DllPath
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'RestorePrevious 必须提供 -BackupPath。'
    }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw "找不到追加前备份: $BackupPath"
    }
    if ((Get-Sha256 $BackupPath) -ne $primaryPatchedHash) {
        throw '追加前备份哈希不是预期的前两处补丁状态，拒绝恢复。'
    }
    foreach ($offset in $primaryPatchOffsets) {
        if (-not (Test-BytesEqual (Read-BytesAt $DllPath $offset) $patchedBytes)) {
            throw "当前 DLL 在 0x$('{0:X}' -f $offset) 不是预期的已补丁字节，拒绝覆盖。"
        }
    }
    if (-not (Test-BytesEqual (Read-BytesAt $DllPath $pagePatchOffset) $patchedBytes)) {
        throw "当前 DLL 在页面候选位置 0x$('{0:X}' -f $pagePatchOffset) 不是追加补丁字节，拒绝覆盖。"
    }
    Copy-Item -LiteralPath $BackupPath -Destination $DllPath -Force
    if ((Get-Sha256 $DllPath) -ne $primaryPatchedHash) {
        throw '撤销页面候选补丁后哈希不一致。'
    }
    return
}

if ($Mode -eq 'Restore') {
    Assert-TargetStopped $DllPath
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'Restore 必须提供 -BackupPath。'
    }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw "找不到备份: $BackupPath"
    }
    if ((Get-Sha256 $BackupPath) -ne $originalHash) {
        throw '备份哈希不是预期的原版哈希，拒绝恢复。'
    }
    foreach ($offset in $primaryPatchOffsets) {
        if (-not (Test-BytesEqual (Read-BytesAt $DllPath $offset) $patchedBytes)) {
            throw "当前 DLL 在 0x$('{0:X}' -f $offset) 不是本补丁写入的字节，拒绝覆盖。"
        }
    }
    $pageBytes = Read-BytesAt $DllPath $pagePatchOffset
    if (-not (Test-BytesEqual $pageBytes $patchedBytes) -and -not (Test-BytesEqual $pageBytes $originalBytes)) {
        throw "当前 DLL 在页面候选位置 0x$('{0:X}' -f $pagePatchOffset) 不是可识别状态，拒绝覆盖。"
    }
    Copy-Item -LiteralPath $BackupPath -Destination $DllPath -Force
    if ((Get-Sha256 $DllPath) -ne $originalHash) {
        throw '恢复后哈希不一致。'
    }
    return
}
