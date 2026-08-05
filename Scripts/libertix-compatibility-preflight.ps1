#requires -Version 5.1

[CmdletBinding()]
param(
    [int]$MinimumLinuxSizeGB = 20,
    [int]$MinimumMemoryMB = 2048,
    [int]$LowMemoryThresholdMB = 4096,
    [ValidateSet("en", "fr", "es", "ja")]
    [string]$LanguageCode = "en"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
& "$env:SystemRoot\System32\chcp.com" 65001 > $null
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)

function Write-Result {
    param([string]$Name, [object]$Value)
    $text = [string]$Value
    $text = $text.Replace("`r", " ").Replace("`n", " ")
    Write-Output ("{0}={1}" -f $Name, $text)
}

function Stop-Compatibility {
    param([string]$Code, [object[]]$FormatArguments = @())
    $template = $errorMessages[$LanguageCode][$Code]
    if ([string]::IsNullOrWhiteSpace($template)) {
        $template = $errorMessages.en[$Code]
    }
    if ([string]::IsNullOrWhiteSpace($template)) {
        throw "[$Code] $Code"
    }
    throw "[$Code] $($template -f $FormatArguments)"
}

$checkMessages = @{
    en = @{
        COMPAT_010_PRIVILEGES = "Checking administrator privileges"
        COMPAT_020_PLATFORM = "Checking Windows, architecture, and memory"
        COMPAT_030_FIRMWARE = "Checking firmware and Secure Boot"
        COMPAT_040_STORAGE = "Checking the system disk and storage controller"
        COMPAT_050_FILESYSTEM = "Checking NTFS, BitLocker, and shrinkable space"
    }
    fr = @{
        COMPAT_010_PRIVILEGES = "Vérification des droits administrateur"
        COMPAT_020_PLATFORM = "Vérification de Windows, de l'architecture et de la mémoire"
        COMPAT_030_FIRMWARE = "Vérification du firmware et du démarrage sécurisé"
        COMPAT_040_STORAGE = "Vérification du disque système et du contrôleur"
        COMPAT_050_FILESYSTEM = "Vérification de NTFS, BitLocker et de l'espace réductible"
    }
    es = @{
        COMPAT_010_PRIVILEGES = "Comprobación de los privilegios de administrador"
        COMPAT_020_PLATFORM = "Comprobación de Windows, la arquitectura y la memoria"
        COMPAT_030_FIRMWARE = "Comprobación del firmware y del arranque seguro"
        COMPAT_040_STORAGE = "Comprobación del disco del sistema y del controlador de almacenamiento"
        COMPAT_050_FILESYSTEM = "Comprobación de NTFS, BitLocker y del espacio reducible"
    }
    ja = @{
        COMPAT_010_PRIVILEGES = "管理者権限を確認しています"
        COMPAT_020_PLATFORM = "Windows、アーキテクチャ、メモリを確認しています"
        COMPAT_030_FIRMWARE = "ファームウェアとセキュア ブートを確認しています"
        COMPAT_040_STORAGE = "システム ディスクとストレージ コントローラーを確認しています"
        COMPAT_050_FILESYSTEM = "NTFS、BitLocker、縮小可能な領域を確認しています"
    }
}

$warningMessages = @{
    en = @{
        LOW_MEMORY = "Limited memory ({0} MB): Libertix will use low-memory mode without copying the entire live system to RAM."
        BITLOCKER = "BitLocker is active; Libertix will decrypt it only after your final confirmation."
        MULTIPLE_DISKS = "{0} internal disks are visible; the live system will require an exact match with the Windows disk."
    }
    fr = @{
        LOW_MEMORY = "Mémoire limitée ({0} Mio): Libertix utilisera le mode faible mémoire sans copie intégrale du live en RAM."
        BITLOCKER = "BitLocker est actif; Libertix le déchiffrera uniquement après votre confirmation finale."
        MULTIPLE_DISKS = "{0} disques internes sont visibles; le live exigera une correspondance exacte avec le disque Windows."
    }
    es = @{
        LOW_MEMORY = "Memoria limitada ({0} MB): Libertix usará el modo de poca memoria sin copiar todo el sistema live en la RAM."
        BITLOCKER = "BitLocker está activo; Libertix solo lo descifrará después de su confirmación final."
        MULTIPLE_DISKS = "Hay {0} discos internos visibles; el sistema live exigirá una coincidencia exacta con el disco de Windows."
    }
    ja = @{
        LOW_MEMORY = "メモリが限られています ({0} MB)。Libertix はライブ システム全体を RAM にコピーせず、低メモリ モードを使用します。"
        BITLOCKER = "BitLocker が有効です。Libertix は最終確認後にのみ暗号化を解除します。"
        MULTIPLE_DISKS = "{0} 台の内蔵ディスクが検出されました。ライブ システムでは Windows ディスクとの完全一致が必要です。"
    }
}

# Blocking messages are what the user sees when the machine is refused. They must
# follow the language chosen in Libertix, exactly like the check and warning
# catalogues above. Keyed by error code; the English entry is the fallback.
$errorMessages = @{
    en = @{
        COMPAT_E_ADMIN_REQUIRED = "Libertix must be run as administrator."
        COMPAT_E_OS_UNSUPPORTED = "Only client editions of Windows are supported."
        COMPAT_E_ARCH_UNSUPPORTED = "This version of Libertix requires 64-bit Windows (AMD64); ARM64 and x86 are not supported."
        COMPAT_E_RAM_TOO_LOW = "At least {0} MiB of RAM is required; {1} MiB was detected."
        COMPAT_E_FIRMWARE_UNKNOWN = "Windows cannot determine the firmware type."
        COMPAT_E_FIRMWARE_NOT_SUPPORTED = "The detected firmware is neither BIOS nor UEFI."
        COMPAT_E_SECURE_BOOT_STATE = "The Secure Boot state cannot be read: {0}"
        COMPAT_E_SECURE_BOOT_DB_INVALID = "The Secure Boot certificate database is invalid."
        COMPAT_E_SECURE_BOOT_CERT_INVALID = "A Secure Boot certificate cannot be decoded."
        COMPAT_E_SECURE_BOOT_THIRD_PARTY_CA = "Secure Boot is enabled but no compatible Microsoft third-party UEFI authority is enrolled."
        COMPAT_E_NVRAM_WRITE = "The firmware did not read back a temporary NVRAM variable correctly."
        COMPAT_E_NVRAM_TEST_FAILED = "The NVRAM/BootNext test failed and was rolled back: {0}"
        COMPAT_E_BOOTCURRENT_READ = "The firmware does not expose a valid BootCurrent value."
        COMPAT_E_BOOTNEXT_WRITE = "The firmware refuses or alters BootNext."
        COMPAT_E_SYSTEM_DRIVE = "The Windows system volume is invalid."
        COMPAT_E_SYSTEM_DISK_UNRESOLVED = "The Windows volume does not resolve to a single simple partition."
        COMPAT_E_DISK_NOT_WRITABLE = "The system disk is offline or read-only."
        COMPAT_E_STORAGE_BUS_UNSUPPORTED = "The system disk uses the '{0}' bus, which the Libertix live system does not support reliably."
        COMPAT_E_STORAGE_BUS_UNKNOWN = "The '{0}' storage bus is not in the list tested by Libertix."
        COMPAT_E_INTEL_RST_RAID = "Intel RST/VMD/Optane/VROC is active. The Linux live system may not see the disk; switch the controller to AHCI using your vendor's procedure without breaking Windows."
        COMPAT_E_AMD_RAID = "An AMD RAID controller is active and is not supported by this Libertix live system."
        COMPAT_E_HARDWARE_RAID = "A hardware RAID controller was detected; Libertix cannot guarantee its Linux geometry."
        COMPAT_E_SECTOR_SIZE_UNSUPPORTED = "Sector sizes of {0}/{1} bytes are not supported."
        COMPAT_E_PARTITION_STYLE = "{0} firmware requires a {1} disk; this disk is {2}."
        COMPAT_E_MBR_PRIMARY_LIMIT = "The MBR disk already has four partitions; no primary Linux partition can be added."
        COMPAT_E_RECOVERY_LAYOUT = "Exactly one Windows recovery partition is required; {0} were detected."
        COMPAT_E_ESP_LAYOUT = "Exactly one EFI system partition is required; {0} were detected."
        COMPAT_E_NTFS_HEALTH = "The Windows volume must be a healthy NTFS volume; detected state: {0}/{1}."
        COMPAT_E_NTFS_SCAN = "The NTFS scan did not confirm a healthy file system: {0}"
        COMPAT_E_NTFS_SCAN_FAILED = "The NTFS scan failed: {0}"
        COMPAT_E_SHRINK_SPACE = "Windows can only free {0} GiB; at least {1} GiB is required."
        COMPAT_E_BITLOCKER_STATUS = "The BitLocker state cannot be read: {0}"
        COMPAT_E_BITLOCKER_UNREADABLE = "Windows could not fully read the BitLocker state."
    }
    fr = @{
        COMPAT_E_ADMIN_REQUIRED = "Libertix doit être lancé en administrateur."
        COMPAT_E_OS_UNSUPPORTED = "Seules les éditions clientes de Windows sont prises en charge."
        COMPAT_E_ARCH_UNSUPPORTED = "Cette version de Libertix nécessite Windows x86-64 (AMD64); ARM64 et x86 ne sont pas pris en charge."
        COMPAT_E_RAM_TOO_LOW = "Au moins {0} Mio de RAM sont nécessaires; {1} Mio ont été détectés."
        COMPAT_E_FIRMWARE_UNKNOWN = "Windows ne peut pas déterminer le type de firmware."
        COMPAT_E_FIRMWARE_NOT_SUPPORTED = "Le firmware détecté n'est ni BIOS ni UEFI."
        COMPAT_E_SECURE_BOOT_STATE = "L'état Secure Boot ne peut pas être lu : {0}"
        COMPAT_E_SECURE_BOOT_DB_INVALID = "La base de certificats Secure Boot est invalide."
        COMPAT_E_SECURE_BOOT_CERT_INVALID = "Un certificat Secure Boot ne peut pas être décodé."
        COMPAT_E_SECURE_BOOT_THIRD_PARTY_CA = "Secure Boot est actif mais aucune autorité Microsoft UEFI tierce compatible n'est inscrite."
        COMPAT_E_NVRAM_WRITE = "Le firmware n'a pas relu correctement une variable NVRAM temporaire."
        COMPAT_E_NVRAM_TEST_FAILED = "Le test NVRAM/BootNext a échoué et a été restauré : {0}"
        COMPAT_E_BOOTCURRENT_READ = "Le firmware n'expose pas une valeur BootCurrent valide."
        COMPAT_E_BOOTNEXT_WRITE = "Le firmware refuse ou altère BootNext."
        COMPAT_E_SYSTEM_DRIVE = "Le volume système Windows est invalide."
        COMPAT_E_SYSTEM_DISK_UNRESOLVED = "Le volume Windows ne correspond pas à une partition simple unique."
        COMPAT_E_DISK_NOT_WRITABLE = "Le disque système est hors ligne ou en lecture seule."
        COMPAT_E_STORAGE_BUS_UNSUPPORTED = "Le disque système utilise le bus '{0}', qui n'est pas pris en charge de manière fiable par le live Libertix."
        COMPAT_E_STORAGE_BUS_UNKNOWN = "Le bus de stockage '{0}' n'est pas dans la liste testée par Libertix."
        COMPAT_E_INTEL_RST_RAID = "Intel RST/VMD/Optane/VROC est actif. Le live Linux peut ne pas voir le disque; passez le contrôleur en AHCI selon la procédure du constructeur sans casser Windows."
        COMPAT_E_AMD_RAID = "Un contrôleur AMD RAID est actif et n'est pas pris en charge par ce live Libertix."
        COMPAT_E_HARDWARE_RAID = "Un contrôleur RAID matériel a été détecté; sa géométrie Linux n'est pas garantie par Libertix."
        COMPAT_E_SECTOR_SIZE_UNSUPPORTED = "Les secteurs {0}/{1} octets ne sont pas pris en charge."
        COMPAT_E_PARTITION_STYLE = "Le firmware {0} nécessite un disque {1}; le disque est {2}."
        COMPAT_E_MBR_PRIMARY_LIMIT = "Le disque MBR possède déjà quatre partitions; aucune partition primaire Linux ne peut être ajoutée."
        COMPAT_E_RECOVERY_LAYOUT = "Une partition de récupération Windows unique est requise; {0} ont été détectées."
        COMPAT_E_ESP_LAYOUT = "Une partition système EFI unique est requise; {0} ont été détectées."
        COMPAT_E_NTFS_HEALTH = "Le volume Windows doit être un NTFS sain; état détecté : {0}/{1}."
        COMPAT_E_NTFS_SCAN = "L'analyse NTFS n'a pas confirmé un système de fichiers sain : {0}"
        COMPAT_E_NTFS_SCAN_FAILED = "L'analyse NTFS a échoué : {0}"
        COMPAT_E_SHRINK_SPACE = "Windows ne peut libérer que {0} Gio; au moins {1} Gio sont requis."
        COMPAT_E_BITLOCKER_STATUS = "L'état BitLocker est illisible : {0}"
        COMPAT_E_BITLOCKER_UNREADABLE = "Windows n'a pas pu lire complètement l'état BitLocker."
    }
    es = @{
        COMPAT_E_ADMIN_REQUIRED = "Libertix debe ejecutarse como administrador."
        COMPAT_E_OS_UNSUPPORTED = "Solo se admiten las ediciones cliente de Windows."
        COMPAT_E_ARCH_UNSUPPORTED = "Esta versión de Libertix requiere Windows de 64 bits (AMD64); ARM64 y x86 no son compatibles."
        COMPAT_E_RAM_TOO_LOW = "Se requieren al menos {0} MiB de RAM; se detectaron {1} MiB."
        COMPAT_E_FIRMWARE_UNKNOWN = "Windows no puede determinar el tipo de firmware."
        COMPAT_E_FIRMWARE_NOT_SUPPORTED = "El firmware detectado no es ni BIOS ni UEFI."
        COMPAT_E_SECURE_BOOT_STATE = "No se puede leer el estado de Arranque seguro: {0}"
        COMPAT_E_SECURE_BOOT_DB_INVALID = "La base de datos de certificados de Arranque seguro no es válida."
        COMPAT_E_SECURE_BOOT_CERT_INVALID = "No se puede descodificar un certificado de Arranque seguro."
        COMPAT_E_SECURE_BOOT_THIRD_PARTY_CA = "El Arranque seguro está activo pero no hay ninguna autoridad UEFI de terceros de Microsoft compatible inscrita."
        COMPAT_E_NVRAM_WRITE = "El firmware no releyó correctamente una variable NVRAM temporal."
        COMPAT_E_NVRAM_TEST_FAILED = "La prueba NVRAM/BootNext falló y se restauró: {0}"
        COMPAT_E_BOOTCURRENT_READ = "El firmware no expone un valor BootCurrent válido."
        COMPAT_E_BOOTNEXT_WRITE = "El firmware rechaza o altera BootNext."
        COMPAT_E_SYSTEM_DRIVE = "El volumen del sistema de Windows no es válido."
        COMPAT_E_SYSTEM_DISK_UNRESOLVED = "El volumen de Windows no corresponde a una única partición simple."
        COMPAT_E_DISK_NOT_WRITABLE = "El disco del sistema está sin conexión o es de solo lectura."
        COMPAT_E_STORAGE_BUS_UNSUPPORTED = "El disco del sistema usa el bus '{0}', que el sistema live de Libertix no admite de forma fiable."
        COMPAT_E_STORAGE_BUS_UNKNOWN = "El bus de almacenamiento '{0}' no está en la lista probada por Libertix."
        COMPAT_E_INTEL_RST_RAID = "Intel RST/VMD/Optane/VROC está activo. Es posible que el live de Linux no vea el disco; cambie la controladora a AHCI siguiendo el procedimiento del fabricante sin dañar Windows."
        COMPAT_E_AMD_RAID = "Hay una controladora AMD RAID activa que este sistema live de Libertix no admite."
        COMPAT_E_HARDWARE_RAID = "Se detectó una controladora RAID por hardware; Libertix no puede garantizar su geometría en Linux."
        COMPAT_E_SECTOR_SIZE_UNSUPPORTED = "Los sectores de {0}/{1} bytes no son compatibles."
        COMPAT_E_PARTITION_STYLE = "El firmware {0} requiere un disco {1}; el disco es {2}."
        COMPAT_E_MBR_PRIMARY_LIMIT = "El disco MBR ya tiene cuatro particiones; no se puede añadir ninguna partición primaria de Linux."
        COMPAT_E_RECOVERY_LAYOUT = "Se requiere exactamente una partición de recuperación de Windows; se detectaron {0}."
        COMPAT_E_ESP_LAYOUT = "Se requiere exactamente una partición de sistema EFI; se detectaron {0}."
        COMPAT_E_NTFS_HEALTH = "El volumen de Windows debe ser un NTFS en buen estado; estado detectado: {0}/{1}."
        COMPAT_E_NTFS_SCAN = "El análisis NTFS no confirmó un sistema de archivos en buen estado: {0}"
        COMPAT_E_NTFS_SCAN_FAILED = "El análisis NTFS falló: {0}"
        COMPAT_E_SHRINK_SPACE = "Windows solo puede liberar {0} GiB; se requieren al menos {1} GiB."
        COMPAT_E_BITLOCKER_STATUS = "No se puede leer el estado de BitLocker: {0}"
        COMPAT_E_BITLOCKER_UNREADABLE = "Windows no pudo leer completamente el estado de BitLocker."
    }
    ja = @{
        COMPAT_E_ADMIN_REQUIRED = "Libertix は管理者として実行する必要があります。"
        COMPAT_E_OS_UNSUPPORTED = "サポートされているのは Windows のクライアント エディションのみです。"
        COMPAT_E_ARCH_UNSUPPORTED = "このバージョンの Libertix は 64 ビット版 Windows (AMD64) が必要です。ARM64 と x86 はサポートされていません。"
        COMPAT_E_RAM_TOO_LOW = "少なくとも {0} MiB の RAM が必要ですが、{1} MiB しか検出されませんでした。"
        COMPAT_E_FIRMWARE_UNKNOWN = "Windows がファームウェアの種類を判別できません。"
        COMPAT_E_FIRMWARE_NOT_SUPPORTED = "検出されたファームウェアは BIOS でも UEFI でもありません。"
        COMPAT_E_SECURE_BOOT_STATE = "セキュア ブートの状態を読み取れません: {0}"
        COMPAT_E_SECURE_BOOT_DB_INVALID = "セキュア ブートの証明書データベースが無効です。"
        COMPAT_E_SECURE_BOOT_CERT_INVALID = "セキュア ブート証明書をデコードできません。"
        COMPAT_E_SECURE_BOOT_THIRD_PARTY_CA = "セキュア ブートは有効ですが、互換性のある Microsoft サードパーティ UEFI 証明機関が登録されていません。"
        COMPAT_E_NVRAM_WRITE = "ファームウェアが一時的な NVRAM 変数を正しく読み戻しませんでした。"
        COMPAT_E_NVRAM_TEST_FAILED = "NVRAM/BootNext テストが失敗し、元に戻されました: {0}"
        COMPAT_E_BOOTCURRENT_READ = "ファームウェアが有効な BootCurrent 値を公開していません。"
        COMPAT_E_BOOTNEXT_WRITE = "ファームウェアが BootNext を拒否または変更します。"
        COMPAT_E_SYSTEM_DRIVE = "Windows のシステム ボリュームが無効です。"
        COMPAT_E_SYSTEM_DISK_UNRESOLVED = "Windows ボリュームが単一のシンプル パーティションに対応していません。"
        COMPAT_E_DISK_NOT_WRITABLE = "システム ディスクがオフラインまたは読み取り専用です。"
        COMPAT_E_STORAGE_BUS_UNSUPPORTED = "システム ディスクは '{0}' バスを使用しており、Libertix ライブ システムでは確実にサポートできません。"
        COMPAT_E_STORAGE_BUS_UNKNOWN = "ストレージ バス '{0}' は Libertix がテストした一覧に含まれていません。"
        COMPAT_E_INTEL_RST_RAID = "Intel RST/VMD/Optane/VROC が有効です。Linux ライブ環境がディスクを認識できない可能性があります。Windows を壊さないよう、メーカーの手順に従ってコントローラーを AHCI に切り替えてください。"
        COMPAT_E_AMD_RAID = "AMD RAID コントローラーが有効ですが、この Libertix ライブ システムではサポートされていません。"
        COMPAT_E_HARDWARE_RAID = "ハードウェア RAID コントローラーが検出されました。Libertix は Linux 側のジオメトリを保証できません。"
        COMPAT_E_SECTOR_SIZE_UNSUPPORTED = "{0}/{1} バイトのセクターはサポートされていません。"
        COMPAT_E_PARTITION_STYLE = "{0} ファームウェアには {1} ディスクが必要ですが、このディスクは {2} です。"
        COMPAT_E_MBR_PRIMARY_LIMIT = "MBR ディスクには既に 4 つのパーティションがあり、Linux 用の基本パーティションを追加できません。"
        COMPAT_E_RECOVERY_LAYOUT = "Windows 回復パーティションはちょうど 1 つ必要ですが、{0} 個検出されました。"
        COMPAT_E_ESP_LAYOUT = "EFI システム パーティションはちょうど 1 つ必要ですが、{0} 個検出されました。"
        COMPAT_E_NTFS_HEALTH = "Windows ボリュームは正常な NTFS である必要があります。検出された状態: {0}/{1}。"
        COMPAT_E_NTFS_SCAN = "NTFS スキャンで正常なファイル システムを確認できませんでした: {0}"
        COMPAT_E_NTFS_SCAN_FAILED = "NTFS スキャンに失敗しました: {0}"
        COMPAT_E_SHRINK_SPACE = "Windows は {0} GiB しか解放できません。少なくとも {1} GiB が必要です。"
        COMPAT_E_BITLOCKER_STATUS = "BitLocker の状態を読み取れません: {0}"
        COMPAT_E_BITLOCKER_UNREADABLE = "Windows が BitLocker の状態を完全に読み取れませんでした。"
    }
}

function Write-Check {
    param([string]$Code)
    $message = $checkMessages[$LanguageCode][$Code]
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $checkMessages.en[$Code]
    }
    Write-Output ("CHECK={0}: {1}" -f $Code, $message)
}

function Write-LocalizedWarning {
    param([string]$Key, [object[]]$FormatArguments = @())
    $message = $warningMessages[$LanguageCode][$Key]
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $warningMessages.en[$Key]
    }
    Write-Result "WARNING" ($message -f $FormatArguments)
}

function Get-FirmwareMode {
    if (-not ("LibertixCompatibilityFirmware" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LibertixCompatibilityFirmware {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFirmwareType(out uint firmwareType);
}
"@
    }
    [uint32]$type = 0
    if (-not [LibertixCompatibilityFirmware]::GetFirmwareType([ref]$type)) {
        Stop-Compatibility "COMPAT_E_FIRMWARE_UNKNOWN"
    }
    switch ($type) {
        1 { "BIOS" }
        2 { "UEFI" }
        default { Stop-Compatibility "COMPAT_E_FIRMWARE_NOT_SUPPORTED" }
    }
}

function Get-BitLockerState {
    param([string]$DriveLetter)
    $escaped = $DriveLetter.Replace("'", "''")
    try {
        $volume = Get-CimInstance `
            -Namespace "root/CIMV2/Security/MicrosoftVolumeEncryption" `
            -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$escaped'" `
            -ErrorAction Stop
    } catch {
        Stop-Compatibility "COMPAT_E_BITLOCKER_STATUS" @($_.Exception.Message)
    }
    if (-not $volume) {
        return [pscustomobject]@{ Safe = $true; State = "NotEncryptable" }
    }
    $conversion = Invoke-CimMethod -InputObject $volume -MethodName GetConversionStatus -ErrorAction Stop
    $protection = Invoke-CimMethod -InputObject $volume -MethodName GetProtectionStatus -ErrorAction Stop
    if ($conversion.ReturnValue -ne 0 -or $protection.ReturnValue -ne 0) {
        Stop-Compatibility "COMPAT_E_BITLOCKER_UNREADABLE"
    }
    $safe = (
        [int]$conversion.ConversionStatus -eq 0 -and
        [int]$conversion.EncryptionPercentage -eq 0 -and
        [int]$protection.ProtectionStatus -eq 0
    )
    [pscustomobject]@{
        Safe = $safe
        State = if ($safe) { "FullyDecrypted" } else { "EncryptedOrProtected" }
    }
}

function Get-SecureBootDbCertificates {
    $db = Get-SecureBootUEFI -Name db -ErrorAction Stop
    [byte[]]$bytes = $db.Bytes
    $x509SignatureType = [Guid]"a5c059a1-94e4-4aa7-87b5-ab155c2bf072"
    $certificates = New-Object System.Collections.Generic.List[Security.Cryptography.X509Certificates.X509Certificate2]
    $offset = 0
    while ($offset + 28 -le $bytes.Length) {
        $guidBytes = New-Object byte[] 16
        [Array]::Copy($bytes, $offset, $guidBytes, 0, 16)
        $signatureType = New-Object Guid (,$guidBytes)
        $listSize = [BitConverter]::ToUInt32($bytes, $offset + 16)
        $headerSize = [BitConverter]::ToUInt32($bytes, $offset + 20)
        $signatureSize = [BitConverter]::ToUInt32($bytes, $offset + 24)
        if ($listSize -lt 28 -or $offset + $listSize -gt $bytes.Length -or $signatureSize -lt 16) {
            Stop-Compatibility "COMPAT_E_SECURE_BOOT_DB_INVALID"
        }
        if ($signatureType -eq $x509SignatureType) {
            $signatureOffset = $offset + 28 + $headerSize
            $listEnd = $offset + $listSize
            while ($signatureOffset + $signatureSize -le $listEnd) {
                $certificateBytes = New-Object byte[] ([int]$signatureSize - 16)
                [Array]::Copy($bytes, $signatureOffset + 16, $certificateBytes, 0, $certificateBytes.Length)
                try {
                    $certificates.Add((New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,$certificateBytes)))
                } catch {
                    Stop-Compatibility "COMPAT_E_SECURE_BOOT_CERT_INVALID"
                }
                $signatureOffset += $signatureSize
            }
        }
        $offset += $listSize
    }
    return $certificates
}

function Initialize-NvramApi {
    if (([System.Management.Automation.PSTypeName]"LibertixCompatibilityNvram").Type) { return }
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LibertixCompatibilityNvram {
    private const UInt32 TOKEN_ADJUST_PRIVILEGES = 0x20;
    private const UInt32 TOKEN_QUERY = 0x8;
    private const UInt32 SE_PRIVILEGE_ENABLED = 0x2;
    [StructLayout(LayoutKind.Sequential)] private struct LUID { public UInt32 LowPart; public Int32 HighPart; }
    [StructLayout(LayoutKind.Sequential)] private struct TOKEN_PRIVILEGES { public UInt32 Count; public LUID Luid; public UInt32 Attributes; }
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr p, UInt32 a, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] private static extern bool LookupPrivilegeValue(string s, string n, out LUID l);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool AdjustTokenPrivileges(IntPtr t, bool d, ref TOKEN_PRIVILEGES n, UInt32 b, IntPtr p, IntPtr r);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern UInt32 GetFirmwareEnvironmentVariable(string n, string g, byte[] b, UInt32 s);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetFirmwareEnvironmentVariableEx(string n, string g, byte[] b, UInt32 s, UInt32 a);
    public static int LastError() { return Marshal.GetLastWin32Error(); }
    public static void EnablePrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES(); tp.Count = 1; tp.Luid = luid; tp.Attributes = SE_PRIVILEGE_ENABLED;
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            int error = Marshal.GetLastWin32Error(); if (error != 0) throw new System.ComponentModel.Win32Exception(error);
        } finally { CloseHandle(token); }
    }
}
"@
}

function Get-NvramVariable {
    param([string]$Name, [string]$Guid)
    $buffer = New-Object byte[] 65536
    $size = [LibertixCompatibilityNvram]::GetFirmwareEnvironmentVariable($Name, $Guid, $buffer, [uint32]$buffer.Length)
    if ($size -eq 0) {
        return [pscustomobject]@{ Exists = $false; Bytes = $null; Error = [LibertixCompatibilityNvram]::LastError() }
    }
    $result = New-Object byte[] $size
    [Array]::Copy($buffer, $result, $size)
    [pscustomobject]@{ Exists = $true; Bytes = $result; Error = 0 }
}

function Set-NvramVariable {
    param([string]$Name, [string]$Guid, [AllowNull()][byte[]]$Bytes)
    $size = if ($null -eq $Bytes) { 0 } else { $Bytes.Length }
    if (-not [LibertixCompatibilityNvram]::SetFirmwareEnvironmentVariableEx(
        $Name, $Guid, $Bytes, [uint32]$size, [uint32]7)) {
        throw "SetFirmwareEnvironmentVariableEx($Name) failed with Win32 error $([LibertixCompatibilityNvram]::LastError())."
    }
}

function Test-NvramAndBootNext {
    Initialize-NvramApi
    [LibertixCompatibilityNvram]::EnablePrivilege()
    $global = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $probeGuid = "{E68B6B91-06D7-47A1-AE68-550B498FEE24}"
    $probeName = "LibertixCompatibilityProbe"
    $originalProbe = Get-NvramVariable -Name $probeName -Guid $probeGuid
    $originalBootNext = Get-NvramVariable -Name "BootNext" -Guid $global
    try {
        [byte[]]$probeBytes = [Text.Encoding]::ASCII.GetBytes("libertix-nvram-probe")
        Set-NvramVariable -Name $probeName -Guid $probeGuid -Bytes $probeBytes
        $readBack = Get-NvramVariable -Name $probeName -Guid $probeGuid
        if (-not $readBack.Exists -or [Convert]::ToBase64String($readBack.Bytes) -ne [Convert]::ToBase64String($probeBytes)) {
            Stop-Compatibility "COMPAT_E_NVRAM_WRITE"
        }

        $bootCurrent = Get-NvramVariable -Name "BootCurrent" -Guid $global
        if (-not $bootCurrent.Exists -or $bootCurrent.Bytes.Length -ne 2) {
            Stop-Compatibility "COMPAT_E_BOOTCURRENT_READ"
        }
        Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $bootCurrent.Bytes
        $bootNext = Get-NvramVariable -Name "BootNext" -Guid $global
        if (-not $bootNext.Exists -or [BitConverter]::ToUInt16($bootNext.Bytes, 0) -ne [BitConverter]::ToUInt16($bootCurrent.Bytes, 0)) {
            Stop-Compatibility "COMPAT_E_BOOTNEXT_WRITE"
        }
    } finally {
        if ($originalProbe.Exists) { Set-NvramVariable -Name $probeName -Guid $probeGuid -Bytes $originalProbe.Bytes }
        else { Set-NvramVariable -Name $probeName -Guid $probeGuid -Bytes $null }
        if ($originalBootNext.Exists) { Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $originalBootNext.Bytes }
        else { Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $null }
    }
}

try {
    Write-Check "COMPAT_010_PRIVILEGES"
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Compatibility "COMPAT_E_ADMIN_REQUIRED"
    }

    Write-Check "COMPAT_020_PLATFORM"
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ([int]$os.ProductType -ne 1) {
        Stop-Compatibility "COMPAT_E_OS_UNSUPPORTED"
    }
    $architecture = [string]$os.OSArchitecture
    if ($architecture -notmatch "64" -or $env:PROCESSOR_ARCHITECTURE -notmatch "AMD64") {
        Stop-Compatibility "COMPAT_E_ARCH_UNSUPPORTED"
    }
    [long]$memoryBytes = [long]$os.TotalVisibleMemorySize * 1024L
    [long]$memoryMB = [math]::Floor($memoryBytes / 1MB)
    if ($memoryMB -lt $MinimumMemoryMB) {
        Stop-Compatibility "COMPAT_E_RAM_TOO_LOW" @($MinimumMemoryMB, $memoryMB)
    }
    $lowMemory = $memoryMB -lt $LowMemoryThresholdMB
    if ($lowMemory) {
        Write-LocalizedWarning "LOW_MEMORY" @($memoryMB)
    }

    Write-Check "COMPAT_030_FIRMWARE"
    $firmware = Get-FirmwareMode
    $secureBootEnabled = $false
    $nvramPassed = $false
    if ($firmware -eq "UEFI") {
        try { $secureBootEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
        catch { Stop-Compatibility "COMPAT_E_SECURE_BOOT_STATE" @($_.Exception.Message) }
        if ($secureBootEnabled) {
            $subjects = @(Get-SecureBootDbCertificates | ForEach-Object { $_.Subject })
            $thirdPartyCa = @($subjects | Where-Object {
                $_ -match "CN=Microsoft Corporation UEFI CA 2011(?:,|$)" -or
                $_ -match "CN=Microsoft(?: Corporation)? UEFI CA 2023(?:,|$)"
            }).Count -gt 0
            if (-not $thirdPartyCa) {
                Stop-Compatibility "COMPAT_E_SECURE_BOOT_THIRD_PARTY_CA"
            }
        }
        try { Test-NvramAndBootNext; $nvramPassed = $true }
        catch {
            if ($_.Exception.Message -match "^\[(COMPAT_[A-Z0-9_]+)\]\s*(.*)$") { throw }
            Stop-Compatibility "COMPAT_E_NVRAM_TEST_FAILED" @($_.Exception.Message)
        }
    }

    Write-Check "COMPAT_040_STORAGE"
    $systemDrive = [Environment]::GetEnvironmentVariable("SystemDrive").TrimEnd("\")
    if ($systemDrive -notmatch "^[A-Za-z]:$") {
        Stop-Compatibility "COMPAT_E_SYSTEM_DRIVE"
    }
    $systemPartition = @(Get-Partition -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction Stop)
    if ($systemPartition.Count -ne 1) {
        Stop-Compatibility "COMPAT_E_SYSTEM_DISK_UNRESOLVED"
    }
    $partition = $systemPartition[0]
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if ($disk.IsOffline -or $disk.IsReadOnly) {
        Stop-Compatibility "COMPAT_E_DISK_NOT_WRITABLE"
    }
    $busType = [string]$disk.BusType
    if ($busType -match "RAID|iSCSI|USB|File Backed Virtual|Spaces") {
        Stop-Compatibility "COMPAT_E_STORAGE_BUS_UNSUPPORTED" @($busType)
    }
    if ($busType -notmatch "^(SATA|ATA|NVMe|SAS|SCSI|MMC)$") {
        Stop-Compatibility "COMPAT_E_STORAGE_BUS_UNKNOWN" @($busType)
    }

    $controllerNames = @(
        Get-CimInstance Win32_IDEController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
        Get-CimInstance Win32_SCSIController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
    ) | Where-Object { $_ }
    $controllerText = $controllerNames -join " | "
    if ($controllerText -match "(?i)Intel.*(RST|Rapid Storage|VMD|Volume Management|Optane|VROC|RAID)") {
        Stop-Compatibility "COMPAT_E_INTEL_RST_RAID"
    }
    if ($controllerText -match "(?i)AMD.*RAID") {
        Stop-Compatibility "COMPAT_E_AMD_RAID"
    }
    if ($controllerText -match "(?i)(MegaRAID|Smart Array|PERC|Adaptec|Broadcom.*RAID|LSI.*RAID)") {
        Stop-Compatibility "COMPAT_E_HARDWARE_RAID"
    }
    if ($disk.LogicalSectorSize -notin @(512, 4096) -or $disk.PhysicalSectorSize -notin @(512, 4096)) {
        Stop-Compatibility "COMPAT_E_SECTOR_SIZE_UNSUPPORTED" @($disk.LogicalSectorSize, $disk.PhysicalSectorSize)
    }
    $expectedStyle = if ($firmware -eq "UEFI") { "GPT" } else { "MBR" }
    if ([string]$disk.PartitionStyle -ne $expectedStyle) {
        Stop-Compatibility "COMPAT_E_PARTITION_STYLE" @($firmware, $expectedStyle, $disk.PartitionStyle)
    }

    $allPartitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
    if ($firmware -eq "BIOS" -and $allPartitions.Count -ge 4) {
        Stop-Compatibility "COMPAT_E_MBR_PRIMARY_LIMIT"
    }
    $recovery = @($allPartitions | Where-Object {
        $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -or
        [int]$_.MbrType -eq 39 -or $_.Type -match "Recovery"
    })
    if ($recovery.Count -ne 1) {
        Stop-Compatibility "COMPAT_E_RECOVERY_LAYOUT" @($recovery.Count)
    }
    if ($firmware -eq "UEFI") {
        $esp = @($allPartitions | Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" })
        if ($esp.Count -ne 1) {
            Stop-Compatibility "COMPAT_E_ESP_LAYOUT" @($esp.Count)
        }
    }

    Write-Check "COMPAT_050_FILESYSTEM"
    $volume = Get-Volume -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction Stop
    if ([string]$volume.FileSystem -ne "NTFS" -or [string]$volume.HealthStatus -ne "Healthy") {
        Stop-Compatibility "COMPAT_E_NTFS_HEALTH" @($volume.FileSystem, $volume.HealthStatus)
    }
    try {
        $scan = Repair-Volume -DriveLetter $systemDrive.Substring(0, 1) -Scan -ErrorAction Stop
        if ($null -ne $scan -and [string]$scan -notmatch "NoErrorsFound|No Error|Aucune") {
            Stop-Compatibility "COMPAT_E_NTFS_SCAN" @($scan)
        }
    } catch {
        if ($_.Exception.Message -match "^\[COMPAT_") { throw }
        Stop-Compatibility "COMPAT_E_NTFS_SCAN_FAILED" @($_.Exception.Message)
    }
    $supportedSize = Get-PartitionSupportedSize -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction Stop
    [long]$shrinkAvailable = [long]$partition.Size - [long]$supportedSize.SizeMin
    [long]$requiredShrink = ([long]$MinimumLinuxSizeGB + 2L) * 1GB
    if ($shrinkAvailable -lt $requiredShrink) {
        Stop-Compatibility "COMPAT_E_SHRINK_SPACE" @([math]::Round($shrinkAvailable / 1GB, 1), [math]::Round($requiredShrink / 1GB, 1))
    }
    $bitLocker = Get-BitLockerState -DriveLetter $systemDrive
    if (-not $bitLocker.Safe) {
        Write-LocalizedWarning "BITLOCKER"
    }
    $fixedDisks = @(Get-Disk | Where-Object { $_.BusType -notin @("USB", "File Backed Virtual") })
    if ($fixedDisks.Count -gt 1) {
        Write-LocalizedWarning "MULTIPLE_DISKS" @($fixedDisks.Count)
    }

    Write-Result "PREFLIGHT_OK" "true"
    Write-Result "FIRMWARE" $firmware
    Write-Result "ARCHITECTURE" "AMD64"
    Write-Result "MEMORY_BYTES" $memoryBytes
    Write-Result "LOW_MEMORY_MODE" $lowMemory.ToString().ToLowerInvariant()
    Write-Result "SYSTEM_DISK_NUMBER" $disk.Number
    Write-Result "SYSTEM_DISK_UNIQUE_ID" $disk.UniqueId
    Write-Result "SYSTEM_DISK_SIZE" $disk.Size
    Write-Result "PARTITION_STYLE" $disk.PartitionStyle
    Write-Result "STORAGE_BUS_TYPE" $busType
    Write-Result "LOGICAL_SECTOR_SIZE" $disk.LogicalSectorSize
    Write-Result "PHYSICAL_SECTOR_SIZE" $disk.PhysicalSectorSize
    Write-Result "SHRINK_AVAILABLE_BYTES" $shrinkAvailable
    Write-Result "BITLOCKER_SAFE" $bitLocker.Safe.ToString().ToLowerInvariant()
    Write-Result "BITLOCKER_STATE" $bitLocker.State
    Write-Result "SECURE_BOOT_ENABLED" $secureBootEnabled.ToString().ToLowerInvariant()
    Write-Result "NVRAM_PROBE_PASSED" $nvramPassed.ToString().ToLowerInvariant()
    exit 0
} catch {
    $code = "COMPAT_E_UNEXPECTED"
    $message = $_.Exception.Message
    $compatibilityError = [regex]::Match(
        $message,
        "^\[(COMPAT_[A-Z0-9_]+)\]\s*(.*)$")
    if ($compatibilityError.Success) {
        $code = $compatibilityError.Groups[1].Value
        $message = $compatibilityError.Groups[2].Value
    }
    Write-Result "PREFLIGHT_OK" "false"
    Write-Result "ERROR_CODE" $code
    Write-Result "ERROR_MESSAGE" $message
    Write-Result "ERROR_TYPE" $_.Exception.GetType().FullName
    Write-Result "ERROR_POSITION" $_.InvocationInfo.PositionMessage
    Write-Result "ERROR_STACK" $_.ScriptStackTrace
    exit 1
}
