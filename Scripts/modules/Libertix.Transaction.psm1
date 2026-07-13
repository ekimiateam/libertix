Set-StrictMode -Version Latest

function Get-InstallerManifestRelativePaths {
    return @(
        "EFI\BOOT\BOOTX64.EFI", "EFI\BOOT\grubx64.efi", "EFI\BOOT\mmx64.efi",
        "EFI\BOOT\grub.cfg", "EFI\debian\shimx64.efi", "EFI\debian\grubx64.efi",
        "EFI\debian\mmx64.efi", "EFI\debian\grub.cfg",
        "EFI\LibertixInstaller\shimx64.efi", "EFI\LibertixInstaller\grubx64.efi",
        "EFI\LibertixInstaller\mmx64.efi", "EFI\LibertixInstaller\grub.cfg",
        "boot\grub\grub.cfg", "live\vmlinuz", "live\initrd.img",
        "live\filesystem.squashfs", "config.txt"
    )
}

function Get-FileHashManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths
    )
    $manifest = @{}
    foreach ($relativePath in $RelativePaths) {
        $fullPath = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Prepared installer verification failed; missing $relativePath"
        }
        if ((Get-Item -LiteralPath $fullPath -ErrorAction Stop).Length -le 0) {
            throw "Prepared installer verification failed; empty $relativePath"
        }
        $manifest[$relativePath] = (
            Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
    }
    return $manifest
}

Export-ModuleMember -Function Get-InstallerManifestRelativePaths, Get-FileHashManifest
