# UEFI BootNext et BootOrder

## Résumé

En UEFI, chaque entrée de boot est stockée dans une variable NVRAM `Boot####`.
`BootOrder` est la liste persistante des entrées que le firmware essaie dans l'ordre.
`BootNext` est une variable spéciale one-shot : si elle existe, le firmware tente cette entrée au
prochain démarrage seulement, puis la supprime avant de lancer le chargeur.

Sources principales :
- UEFI Specification 2.10, Boot Manager : https://uefi.org/specs/UEFI/2.10/03_Boot_Manager.html
- efibootmgr README : https://github.com/dell/efibootmgr/blob/master/README
- efibootmgr manpage Debian : https://manpages.debian.org/unstable/efibootmgr/efibootmgr.8.en.html
- Microsoft BCD UEFI settings : https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcd-system-store-settings-for-uefi

## BootNext

`BootNext` est prévu pour un démarrage temporaire. Sous Linux, `efibootmgr -n XXXX` écrit cette
variable. Au reboot suivant, le firmware tente `BootXXXX`, puis revient normalement à `BootOrder`.
L'intérêt est d'éviter de modifier durablement l'ordre de boot.

Limites pratiques :
- certains firmwares gèrent mal les écritures NVRAM ou les effacent;
- certains chemins EFI valides sur un firmware échouent sur un autre;
- Windows et certains firmwares peuvent resynchroniser ou nettoyer les entrées firmware;
- Secure Boot peut refuser le chargeur même si l'entrée UEFI existe.

## BootOrder

`BootOrder` est plus persistant : placer une entrée en premier force le firmware à essayer cette
entrée en priorité à chaque boot tant que l'ordre reste en place. C'est plus robuste pour certains
firmwares qui ignorent ou perdent `BootNext`, mais c'est aussi plus intrusif, car cela change l'état
durable de la machine.

## Choix actuel dans Libertix

Le premier essai utilise `BootNext` vers une entree firmware native qui cible le loader temporaire
`EFI\LibertixInstaller\BOOTX64.EFI` sur l'ESP Windows. Avant le redemarrage, Libertix relit
l'entree `Boot####`, le chemin du loader, les hashes des fichiers EFI et la valeur `BootNext`.

Si Windows revient sans marqueur du live, le garde de reprise lance une copie locale verifiee de
Libertix et demande a l'utilisateur s'il veut utiliser le seul fallback valide : une entree firmware
creee avec BCD et placee temporairement en tete de `BootOrder`. Ce n'est pas un chainload direct par
Windows Boot Manager. Le live supprime ses artefacts BCD/EFI avant toute modification de disque et le
mode `-Revert` restaure l'ordre firmware sauvegarde, les fichiers ESP et la partition temporaire.
