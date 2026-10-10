# Shared patch profile detection. This file is dot-sourced by the command scripts.

$script:KnownOriginalHash = '8F7406A8A465E851EE10EAECCCB572D0E5B4E00D480C770938C714C396097B74'
$script:KnownPrimaryPatchedHash = 'E83A63EB167F77BC2A3EDF8F5E0E7669DDFA0603240F0740F04BB27BD48E7789'
$script:KnownExtendedPatchedHash = '0DD1EAC8610D2A9CF8A14E1F892A806E38A6F008731F056C33AA8147F527E2CC'
$script:OriginalPatchBytes = [byte[]](0x85, 0xF6, 0x0F, 0x95, 0xC0)
$script:PatchedPatchBytes = [byte[]](0x31, 0xC0, 0x90, 0x90, 0x90)
$script:KnownPrimaryPatchOffsets = [int64[]](0x5619AEA, 0x561A41A)
$script:KnownPagePatchOffset = [int64]0x3C079DA
$script:KnownAllPatchOffsets = [int64[]]($script:KnownPrimaryPatchOffsets + $script:KnownPagePatchOffset)

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

function Test-BytesEqual([byte[]]$Left, [byte[]]$Right) {
    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) {
        return $false
    }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) {
            return $false
        }
    }
    return $true
}

function Read-BytesAt([string]$Path, [int64]$Offset, [int]$Length = 5) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $result = New-Object byte[] $Length
        $read = $stream.Read($result, 0, $result.Length)
        if ($read -ne $result.Length) {
            throw "无法读取文件偏移 0x$('{0:X}' -f $Offset)。"
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

function Convert-ToHex([byte[]]$Bytes) {
    return ($Bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
}

function Ensure-ByteScanner {
    if ($null -ne ('AdFilter.ByteScanner' -as [type])) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

namespace AdFilter {
    public static class ByteScanner {
        public static long[] Find(byte[] data, int[] pattern) {
            var hits = new List<long>();
            for (int i = 0; i <= data.Length - pattern.Length; i++) {
                if (pattern[0] >= 0 && data[i] != (byte)pattern[0]) continue;
                bool ok = true;
                for (int j = 1; j < pattern.Length; j++) {
                    if (pattern[j] >= 0 && data[i + j] != (byte)pattern[j]) {
                        ok = false;
                        break;
                    }
                }
                if (ok) hits.Add(i);
            }
            return hits.ToArray();
        }

        public static bool ContainsAscii(byte[] data, string value) {
            return Find(data, ToPattern(Encoding.ASCII.GetBytes(value))).Length > 0;
        }

        private static int[] ToPattern(byte[] bytes) {
            var result = new int[bytes.Length];
            for (int i = 0; i < bytes.Length; i++) result[i] = bytes[i];
            return result;
        }
    }
}
'@
}

function New-AdaptiveSignature([byte[]]$PatchBytes) {
    return [int[]](
        0x4C, 0x8B, 0x41, 0xF8, 0x48, 0x83, 0xC1, 0xF8,
        0x4C, 0x29, 0xC1, 0x48, 0x83, 0xF9, 0x20, 0x73,
        0x1F, 0x48, 0x83, 0xC0, 0x28, 0x48, 0x89, 0xC2,
        0x4C, 0x89, 0xC1, 0xE8, -1, -1, -1, -1,
        $PatchBytes[0], $PatchBytes[1], $PatchBytes[2], $PatchBytes[3], $PatchBytes[4],
        0x48, 0x81, 0xC4, 0xD0, 0x01, 0x00, 0x00, 0x5F,
        0x5E, 0x5D, 0xC3
    )
}

function Get-AdaptiveCandidateOffsets([byte[]]$Data) {
    Ensure-ByteScanner
    $starts = @()
    foreach ($variant in @($script:OriginalPatchBytes, $script:PatchedPatchBytes)) {
        $signature = New-AdaptiveSignature $variant
        $starts += [AdFilter.ByteScanner]::Find($Data, $signature)
    }
    return [int64[]]@($starts | ForEach-Object { [int64]$_ + 32 } | Sort-Object -Unique)
}

function Get-PatchState([byte[]]$PrimaryA, [byte[]]$PrimaryB, [byte[]]$Page) {
    $primaryAState = if (Test-BytesEqual $PrimaryA $script:OriginalPatchBytes) { 'Original' } elseif (Test-BytesEqual $PrimaryA $script:PatchedPatchBytes) { 'Patched' } else { 'Unknown' }
    $primaryBState = if (Test-BytesEqual $PrimaryB $script:OriginalPatchBytes) { 'Original' } elseif (Test-BytesEqual $PrimaryB $script:PatchedPatchBytes) { 'Patched' } else { 'Unknown' }
    $pageState = if (Test-BytesEqual $Page $script:OriginalPatchBytes) { 'Original' } elseif (Test-BytesEqual $Page $script:PatchedPatchBytes) { 'Patched' } else { 'Unknown' }

    if ($primaryAState -eq 'Unknown' -or $primaryBState -eq 'Unknown' -or $pageState -eq 'Unknown') {
        throw '检测到无法识别的补丁字节状态。'
    }
    if ($primaryAState -ne $primaryBState) {
        throw '两处主补丁状态不一致，拒绝继续。'
    }
    if ($primaryAState -eq 'Original' -and $pageState -eq 'Original') { return 'Original' }
    if ($primaryAState -eq 'Patched' -and $pageState -eq 'Original') { return 'PrimaryPatched' }
    if ($primaryAState -eq 'Patched' -and $pageState -eq 'Patched') { return 'ExtendedPatched' }
    throw '检测到不支持的混合补丁状态。'
}

function New-PatchProfile(
    [string]$Name,
    [string]$CurrentHash,
    [int64[]]$PrimaryOffsets,
    [int64]$PageOffset,
    [string]$CurrentState,
    [string]$Confidence,
    [string]$OriginalHash
) {
    return [pscustomobject]@{
        Name = $Name
        CurrentHash = $CurrentHash
        OriginalHash = $OriginalHash
        PrimaryPatchOffsets = [int64[]]$PrimaryOffsets
        PagePatchOffset = [int64]$PageOffset
        AllPatchOffsets = [int64[]]($PrimaryOffsets + $PageOffset)
        CurrentState = $CurrentState
        Confidence = $Confidence
    }
}

function Get-AdaptiveProfile([string]$Path, [string]$CurrentHash, [string]$ExpectedOriginalHash) {
    $data = [System.IO.File]::ReadAllBytes($Path)
    $candidateOffsets = Get-AdaptiveCandidateOffsets $data
    if ($candidateOffsets.Length -lt 10 -or $candidateOffsets.Length -gt 11) {
        throw "自适应签名候选数量为 $($candidateOffsets.Length)，当前仅支持 10 或 11 个；拒绝修改。"
    }

    $expectedClusterGaps = [int64[]](0x310, 0x310, 0x310, 0x320, 0x310, 0x310)
    for ($i = 0; $i -lt $expectedClusterGaps.Length; $i++) {
        $left = 2 + $i
        $right = $left + 1
        if (($candidateOffsets[$right] - $candidateOffsets[$left]) -ne $expectedClusterGaps[$i]) {
            throw '自适应候选集合的函数间距不匹配，拒绝修改。'
        }
    }

    $callTargets = @()
    foreach ($offset in $candidateOffsets) {
        $start = [int64]$offset - 32
        $relative = [BitConverter]::ToInt32($data, [int]($start + 28))
        $callTargets += [int64]$offset + [int64]$relative
    }
    if (@($callTargets | Sort-Object -Unique).Count -ne 1) {
        throw '自适应候选没有共同的调用目标，拒绝修改。'
    }

    Ensure-ByteScanner
    $anchors = @(
        'clicfg_unified_pc_sns_ad_supported',
        'clicfg_unified_pc_sns_ad_card_ad_supported',
        'clicfg_unified_pc_ad_vangogh_page_supported',
        'TimelineAdBaseCardCell',
        'SnsAdComponentBase'
    )
    foreach ($anchor in $anchors) {
        if (-not [AdFilter.ByteScanner]::ContainsAscii($data, $anchor)) {
            throw "缺少自适应语义锚点: $anchor"
        }
    }

    $primaryOffsets = [int64[]]($candidateOffsets[2], $candidateOffsets[5])
    $pageOffset = [int64]$candidateOffsets[1]
    $state = Get-PatchState (Read-BytesAt $Path $primaryOffsets[0]) (Read-BytesAt $Path $primaryOffsets[1]) (Read-BytesAt $Path $pageOffset)
    $originalHash = if ($state -eq 'Original') { $CurrentHash } else { $ExpectedOriginalHash }
    return New-PatchProfile 'Adaptive-structural' $CurrentHash $primaryOffsets $pageOffset $state "$($candidateOffsets.Length) candidates + 5 anchors + shared call target" $originalHash
}

function Get-PatchProfile([string]$Path, [string]$ExpectedOriginalHash) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到 DLL: $Path"
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $currentHash = Get-Sha256 $resolved

    if ($currentHash -eq $script:KnownOriginalHash) {
        return New-PatchProfile 'Known-4.1.13.65' $currentHash $script:KnownPrimaryPatchOffsets $script:KnownPagePatchOffset 'Original' 'exact SHA-256' $currentHash
    }
    if ($currentHash -eq $script:KnownPrimaryPatchedHash) {
        return New-PatchProfile 'Known-4.1.13.65' $currentHash $script:KnownPrimaryPatchOffsets $script:KnownPagePatchOffset 'PrimaryPatched' 'exact SHA-256' $ExpectedOriginalHash
    }
    if ($currentHash -eq $script:KnownExtendedPatchedHash) {
        return New-PatchProfile 'Known-4.1.13.65' $currentHash $script:KnownPrimaryPatchOffsets $script:KnownPagePatchOffset 'ExtendedPatched' 'exact SHA-256' $ExpectedOriginalHash
    }

    return Get-AdaptiveProfile $resolved $currentHash $ExpectedOriginalHash
}

function Test-ProfileOffsetsEqual($Left, $Right) {
    if ($Left.PagePatchOffset -ne $Right.PagePatchOffset -or $Left.PrimaryPatchOffsets.Count -ne $Right.PrimaryPatchOffsets.Count) {
        return $false
    }
    for ($i = 0; $i -lt $Left.PrimaryPatchOffsets.Count; $i++) {
        if ($Left.PrimaryPatchOffsets[$i] -ne $Right.PrimaryPatchOffsets[$i]) {
            return $false
        }
    }
    return $true
}

function Test-OriginalBackup([string]$BackupPath, $TargetProfile, [string]$ExpectedOriginalHash) {
    if ([string]::IsNullOrWhiteSpace($BackupPath) -or
        -not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        return $false
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedOriginalHash) -and
            (Get-Sha256 $BackupPath) -ne $ExpectedOriginalHash) {
            return $false
        }
        $backupProfile = Get-PatchProfile $BackupPath $ExpectedOriginalHash
        return ($backupProfile.CurrentState -eq 'Original' -and (Test-ProfileOffsetsEqual $backupProfile $TargetProfile))
    }
    catch {
        return $false
    }
}
