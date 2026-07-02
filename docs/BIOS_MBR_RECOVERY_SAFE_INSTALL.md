# Installation BIOS/MBR sans toucher a la partition Recovery

Etat du document : strategie implementee et validee sur la VM Proxmox `500` le 2026-07-02.

## Objectif

Installer Linux Mint sur une machine Windows 10 en mode BIOS/MBR sans supprimer ni restaurer la partition de recuperation Windows.

La contrainte principale est la limite MBR : quatre partitions primaires maximum.

Disposition attendue apres installation :

```text
/dev/sda1  Windows System Reserved
/dev/sda2  Windows NTFS
/dev/sda3  Linux Mint ext4
/dev/sda4  Windows Recovery
```

La partition Recovery reste `/dev/sda4`. Elle ne doit pas etre supprimee, deplacee ou restauree.

## Probleme observe avec la suppression de la partition live

L'idee initiale etait :

1. Windows reduit `/dev/sda2`.
2. Libertix cree une partition FAT32 temporaire `/dev/sda3`.
3. Le live boote depuis `/dev/sda3` avec `toram`.
4. Le live monte Windows pour lire `mint.iso`.
5. Le live supprime `/dev/sda3`.
6. Le live cree une nouvelle partition ext4 dans le trou libere.
7. Mint est installe dans cette nouvelle partition.

Ce chemin a echoue en test reel sur VM Proxmox `500`.

Le script live arrivait bien a booter et a trouver `mint.iso`, mais apres `parted rm 3`, le noyau gardait encore l'ancienne vue `/dev/sda3`. Meme quand la table MBR disque ne contenait plus l'entree 3, le kernel exposait toujours la partition.

Conclusion technique :

- `blockdev --rereadpt /dev/sda` peut echouer si une partition du meme disque est montee.
- `partx -d -n 3 /dev/sda` ou `delpart /dev/sda 3` ne devrait echouer que si `/dev/sda3` a encore un opener/holder.
- Le montage Windows `/dev/sda2` n'etait pas la seule cause : un essai avec Windows demonte a encore laisse `/dev/sda3` visible cote kernel.
- Le suspect restant est un holder direct ou cache sur la partition live : live-boot, loop, reference residuelle du medium, ou effet d'un ancien `umount -l`.

Pour cette raison, le chemin actuel ne depend plus de la suppression/recreation de l'entree MBR.

## Strategie actuelle : reutiliser la partition live comme partition Linux finale

La solution la plus robuste est de ne jamais supprimer l'entree MBR `/dev/sda3`.

Windows cree directement la partition live FAT32 a la taille Linux finale, par exemple 20 GB. Ensuite le live boote depuis cette partition en RAM, la demonte strictement, puis reformate la meme partition en ext4.

On garde donc toujours quatre entrees MBR maximum :

```text
Avant Libertix :
/dev/sda1  Windows System Reserved
/dev/sda2  Windows NTFS
/dev/sda4  Windows Recovery

Apres preparation Windows :
/dev/sda1  Windows System Reserved
/dev/sda2  Windows NTFS reduite
/dev/sda3  FAT32 LINUXGATE, taille finale Linux
/dev/sda4  Windows Recovery

Apres installation live :
/dev/sda1  Windows System Reserved
/dev/sda2  Windows NTFS
/dev/sda3  Linux Mint ext4
/dev/sda4  Windows Recovery
```

Il n'y a plus de suppression de `/dev/sda3`. La partition change de role :

```text
FAT32 live boot -> ext4 Linux Mint
```

## Etapes cote Windows

Code principal : `Pages/ApplyChanges.xaml.cs`.

1. Libertix lit l'espace reductible de Windows avec DiskPart.
2. Libertix reduit la partition Windows de la taille Linux demandee :

```text
shrink desired=<linux_size_mb>
```

3. Libertix cree une partition primaire FAT32 dans l'espace libre, avec la taille finale Linux :

```text
create partition primary size=<linux_size_mb>
format fs=fat32 quick label=LINUXGATE
assign letter=Z
```

4. Libertix telecharge l'ISO live custom depuis le filepool local :

```text
http://192.168.1.170:8000/filepool/libertix-installer-bios.iso
```

5. Libertix telecharge l'ISO Mint dans le dossier temporaire Windows :

```text
%TEMP%\Libertix\mint.iso
```

6. Libertix copie les fichiers de boot live sur `Z:`.
7. Libertix ecrit `Z:\config.txt`, avec notamment :

```text
ISO_WINDOWS_PATH="%TEMP%\Libertix\mint.iso"
ISO_FILENAME="mint.iso"
LINUX_SIZE_GB=<taille demandee>
USERNAME=<utilisateur>
HOSTNAME=<nom machine>
```

8. Libertix installe GRUB4DOS sur la partition FAT32.
9. Libertix cree une entree Windows Boot Manager `Install Linux`.
10. Libertix ajoute cette entree au menu de boot, force l'affichage du selecteur, demande le menu moderne Windows 10, garde Windows en premier/par defaut et laisse 30 secondes pour choisir :

```text
bcdedit /displayorder {current} {guid}
bcdedit /set {current} bootmenupolicy Standard
bcdedit /set {bootmgr} displaybootmenu yes
bcdedit /timeout 30
bcdedit /default {current}
```

Il n'utilise plus `bcdedit /bootsequence {guid}`. Le choix `Install Linux` n'est donc pas force automatiquement. Si l'utilisateur ne choisit rien, Windows redemarre par defaut apres le timeout.

`bootmenupolicy Standard` demande le selecteur graphique moderne de Windows 10. Sur certains boots BIOS/bootsector, Windows peut quand meme afficher le selecteur texte legacy ; dans ce cas le comportement fonctionnel reste le meme : Windows est l'entree par defaut et `Install Linux` doit etre choisi manuellement.

11. Apres preparation reussie, Libertix programme un redemarrage automatique apres 5 secondes :

```text
shutdown /r /t 5
```

Le bouton `Redemarrer` reste visible comme fallback manuel, mais le chemin normal redemarre tout seul vers le selecteur Windows Boot Manager.

## Etapes cote live Linux

Code principal : `gen-iso.sh`.

1. Le live boote avec `toram`.
2. Systemd lance `libertix-install.service`.
3. Le service lance `/install-mint.sh` et copie les logs vers la console et `/run/libertix/install.log`.
4. Le script lit `/run/live/medium/config.txt`.
5. Le script identifie le disque cible :

```text
DISK=/dev/sda
```

6. Le script identifie la partition Windows, normalement :

```text
WINDOWS_PART=/dev/sda2
```

7. Le script identifie la partition live, normalement :

```text
LIVE_PART=/dev/sda3
```

8. Le script monte Windows en lecture seule uniquement pour verifier que l'ISO Mint existe :

```bash
mount -t ntfs-3g -o ro "$WINDOWS_PART" /mnt/windows
```

9. Le script verifie :

```text
/mnt/windows/<chemin relatif depuis ISO_WINDOWS_PATH>
```

Exemple :

```text
/mnt/windows/Users/admin/AppData/Local/Temp/Libertix/mint.iso
```

10. Le script demonte Windows avant toute action sur la partition live :

```bash
umount /mnt/windows
```

11. Le script demonte strictement les partitions du disque cible. Il n'utilise plus `umount -l`.

Important : avec `toram`, `/run/live/medium` est un `tmpfs` en RAM. Il peut rester occupe par le loop squashfs du live, mais il ne correspond plus a `/dev/sda3`. Le script ne le demonte donc plus aveuglement. Il parcourt les montages et ne demonte que les sources qui sont de vrais block devices appartenant a `$DISK`.

12. Si `/dev/sda3` est bien la partition live sur le disque cible, le script la reutilise :

```text
NEW_PART=/dev/sda3
```

13. Le script change le type MBR de la partition en Linux `0x83` :

```bash
sfdisk --part-type /dev/sda 3 83
```

14. Le script efface les signatures FAT32 :

```bash
wipefs -a /dev/sda3
```

15. Le script formate la meme partition en ext4 :

```bash
mkfs.ext4 -F /dev/sda3
```

16. Le script monte la cible :

```bash
mount /dev/sda3 /mnt/target
```

17. Le script remonte Windows en lecture seule pour lire `mint.iso` :

```bash
mount -t ntfs-3g -o ro /dev/sda2 /mnt/windows
```

18. Le script monte l'ISO Mint en loop read-only :

```bash
mount -o loop,ro "$ISO_SOURCE" /mnt/iso
```

19. Le script extrait le systeme Mint :

```bash
unsquashfs -f -d /mnt/target /mnt/iso/casper/filesystem.squashfs
```

20. Le script chroot dans `/mnt/target`, installe/configure le boot Linux, l'utilisateur, le hostname et les fichiers systeme necessaires.

## Pourquoi cette methode evite le probleme kernel

La suppression/recreation de partition demande au kernel d'oublier puis de relire une entree MBR. Sur un live qui boote depuis cette meme partition, cela peut echouer si la partition a encore un holder.

La nouvelle methode ne demande pas au kernel d'oublier `/dev/sda3`.

Elle garde le meme device kernel :

```text
/dev/sda3
```

Et change seulement :

```text
FAT32 -> ext4
type MBR FAT32 -> Linux 0x83
contenu live -> contenu Mint
```

Donc on evite :

- `parted rm 3`
- `delpart /dev/sda 3`
- `partx --delete --nr 3:3 /dev/sda`
- `blockdev --rereadpt /dev/sda` comme condition de reussite

## Garde-fous

- La partition Recovery `/dev/sda4` n'est pas supprimee.
- Le script refuse de continuer sur MBR plein si aucune partition live reutilisable n'est detectee.
- Le live monte Windows en lecture seule pour lire `mint.iso`.
- Le live demonte Windows avant de reformater la partition live.
- Le chemin actif n'utilise pas `umount -l`.
- Les erreurs critiques de partitionnement doivent arreter le script avec diagnostics.

## Automatisation UI de test

Un outil local automatise le parcours Libertix sur la VM Windows 10 BIOS :

```bash
cd /home/tpm28/Documents/Ekimia/auto_tests
.venv/bin/python tools/automate_libertix_vm500_ui.py --apply
```

Par defaut, sans `--apply`, l'outil s'arrete avant l'action destructive :

```bash
.venv/bin/python tools/automate_libertix_vm500_ui.py
```

Garde-fous de l'outil :

- il selectionne uniquement la VM `.env` dont l'OS contient `Windows 10 BIOS`;
- il refuse si l'hote attendu n'est pas `192.168.1.240`;
- il lance Libertix en mode eleve via tache planifiee interactive;
- il capture chaque ecran dans `auto_tests/captures/`;
- il ne lance le partitionnement que si `--apply` est passe explicitement.

## Probleme corrige pendant le test final

Un test intermediaire a echoue au stage `040-unmount-target-disk` avec :

```text
umount: /run/live/medium: target is busy.
```

Les logs ont montre :

```text
tmpfs /run/live/medium
/dev/loop0 /run/live/rootfs/filesystem.squashfs
/dev/loop0: (/run/live/medium/live/filesystem.squashfs)
```

Interpretation :

- `toram` avait bien copie le live en RAM.
- `/run/live/medium` etait un `tmpfs`, pas `/dev/sda3`.
- Le loop device lisait le squashfs depuis la RAM.
- Tenter de demonter `/run/live/medium` etait inutile et provoquait un faux echec.

Correctif applique :

- ne plus demonter `/run/live/medium`, `/lib/live/mount/medium` ou `/cdrom` aveuglement ;
- parcourir `findmnt` ;
- ne demonter que les sources qui sont des block devices appartenant a `$DISK` ;
- faire `cd /` avant le demontage strict ;
- garder les erreurs finales visibles via le runner et les logs NTFS.

## Etat de verification

Verifie le 2026-07-02 sur VM Proxmox `500` (`Libertix-Win10-BIOS`, snapshot `clean2`) :

- Build ISO BIOS via Docker local.
- ISO bootable BIOS verifiee par `file`.
- Build-id ISO verifie : `20260702-111523-nogit-dirty`.
- Options boot verifiees dans `isolinux.cfg` : `toram`, `console=tty1`, `console=ttyS0,115200n8`.
- Filepool HTTP local `192.168.1.170:8000` verifie avec `Content-Length: 236978176`.
- Synchronisation de `gen-iso.sh` vers `/root/smb/Libertix-source` verifiee par `git diff --check`.
- Reset VM 500 sur snapshot `clean2`.
- Validation API `win10-bios` : `FINAL_STATUS ok`.
- Automatisation UI : Libertix a prepare Windows, cree `Z:` FAT32 20 GB, telecharge l'ISO live et `mint.iso`, installe GRUB4DOS, ajoute et programme l'entree BCD `Install Linux`.
- Boot live avec build-id `20260702-111523-nogit-dirty`.
- Stages live observes :

```text
070-wipefs-live-part
080-mkfs-ext4
090-mount-target
100-remount-windows-ro
110-loop-mount-mint-iso
120-unsquashfs
130-target-system-config
```

- Boot final Linux Mint 22.2 Cinnamon 64-bit.
- Login utilisateur `admin` reussi.
- Verification depuis le terminal Mint :

```text
lsblk
sda    64G disk
|-sda1 50M part
|-sda2 43,4G part /mnt/windows
|-sda3 20G part /
|-sda4 536M part

df
/dev/sda3  20466256  7789148  11612148  41% /
/dev/sda2  45534088 29049192  16484896  64% /mnt/windows
```

Conclusion verifiee : la VM boote sur Mint installe dans `/dev/sda3`, la partition Windows reste `/dev/sda2`, et la partition Recovery `/dev/sda4` existe toujours. Le disque reste a quatre partitions primaires maximum.

## Verification du selecteur Windows Boot Manager

Verifie le 2026-07-02 sur VM Proxmox `500` apres ajout de `bootmenupolicy Standard` :

- `ApplyChanges.xaml.cs` construit le filepool avec `FilepoolConfig.BaseUrl`.
- `ChooseDistro.xaml.cs` construit `DISTROS_URL` avec `FilepoolConfig.DistrosUrl`.
- Libertix affiche le menu Windows Boot Manager au reboot.
- Windows est l'entree selectionnee par defaut.
- `Install Linux` est disponible en deuxieme choix et doit etre choisi manuellement.
- Si aucun choix n'est fait, Windows boote apres le timeout.

Inspection BCD depuis Windows apres le test :

```text
{bootmgr}
default                 {current}
displayorder            {current}
                        {Install Linux GUID}
timeout                 30
displaybootmenu         Yes

{current}
description             Windows 10
bootmenupolicy          Standard
```

Capture de preuve locale :

```text
/home/tpm28/Documents/Ekimia/auto_tests/captures/vm500-visual-menu-5s.png
```
