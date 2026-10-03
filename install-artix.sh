#!/usr/bin/env bash
#===============================================================================
#  install-artix.sh : Installation d'Artix Linux (runit) jusqu'au redémarrage
#
#  Cible   : UEFI + GPT, noyau linux-zen, rEFInd, seatd + pam_rundir, ConnMan
#  Couvre  : parties 1 et 2 du guide (ISO live -> chroot -> prêt à redémarrer)
#  Exclu   : NVIDIA, Xfce/Wayfire, ly (à faire après le redémarrage)
#
#  Usage   : en root, depuis l'ISO live Artix base runit, démarrée en UEFI :
#              su -                      (mot de passe : artix)
#              bash install-artix.sh
#
#  Seules questions posées : nom d'utilisateur, nom de la machine, mots de
#  passe (utilisateur et root). Le reste est automatique.
#
#  ATTENTION : le disque cible est ENTIÈREMENT effacé (Windows compris).
#  Il est trouvé automatiquement par son modèle (voir DISK_MODEL_MATCH), ou
#  imposé avec :  DISK=/dev/sdX bash install-artix.sh
#===============================================================================

set -Eeuo pipefail

#-------------------------------------------------------------------------------
# Configuration (modifiable)
#-------------------------------------------------------------------------------
DISK_MODEL_MATCH="870 EVO"        # modèle du disque cible, cherché automatiquement
DISK="${DISK:-}"                  # ou imposé : DISK=/dev/sdX bash install-artix.sh
DO_DISCARD="${DO_DISCARD:-no}"    # yes = TRIM complet du SSD avant partitionnement
COUNTDOWN="${COUNTDOWN:-10}"      # secondes avant l'effacement (0 = immédiat)
AUTO_REBOOT="${AUTO_REBOOT:-no}"  # yes = redémarrage automatique à la fin
DEFAULT_HOSTNAME="artix"
TIMEZONE="Europe/Paris"
KEYMAP="fr"
LOCALE="fr_FR.UTF-8"
ESP_SIZE="512MiB"
# Options noyau : nouveau bloqué, paramètres NVIDIA prêts pour la partie 3
KERNEL_PARAMS="rw nouveau.modeset=0 module_blacklist=nouveau nvidia_drm.modeset=1 nvidia_drm.fbdev=1"

LOG_FILE="/root/install-artix.log"
CHROOT_SCRIPT="/root/install-artix.sh"
ENV_FILE="/root/install-artix.env"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

#-------------------------------------------------------------------------------
# Affichage
#-------------------------------------------------------------------------------
if [ -t 2 ]; then
    C_RED=$'\e[1;31m'; C_GRN=$'\e[1;32m'; C_YEL=$'\e[1;33m'; C_BLU=$'\e[1;34m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi

info() { printf '%s[ .. ]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[ !! ]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step() { printf '\n%s=== %s ===%s\n' "$C_BLU" "$*" "$C_RST"; }

on_error() {
    local code=$1 line=$2 cmd=$3
    printf '\n%s[ERR ]%s Échec (code %s), ligne %s : %s\n' "$C_RED" "$C_RST" "$code" "$line" "$cmd" >&2
    printf 'Journal : %s\n' "$LOG_FILE" >&2
    printf 'Tu peux relancer le script : il repart de zéro (le disque sera de nouveau effacé).\n' >&2
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

#-------------------------------------------------------------------------------
# Utilitaires
#-------------------------------------------------------------------------------
retry() { # retry <n> <commande...>
    local n=$1 i; shift
    for ((i = 1; i <= n; i++)); do
        if "$@"; then return 0; fi
        warn "Tentative $i/$n échouée : $*"
        sleep 3
    done
    return 1
}

# Les questions passent par /dev/tty : elles restent lisibles même quand la
# sortie est redirigée vers le journal.
ask() { # ask <variable> <question> [défaut]
    local __var=$1 __q=$2 __def=${3-} __ans=""
    if [ -n "$__def" ]; then
        printf '%s [%s] : ' "$__q" "$__def" >/dev/tty
    else
        printf '%s : ' "$__q" >/dev/tty
    fi
    IFS= read -r __ans </dev/tty || true
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

ask_secret() { # ask_secret <variable> <question>
    local __var=$1 __q=$2 __a __b
    while true; do
        printf '%s : ' "$__q" >/dev/tty
        IFS= read -rs __a </dev/tty || true
        printf '\n' >/dev/tty
        if [ -z "$__a" ]; then warn "Le mot de passe ne peut pas être vide."; continue; fi
        printf 'Confirme : ' >/dev/tty
        IFS= read -rs __b </dev/tty || true
        printf '\n' >/dev/tty
        if [ "$__a" = "$__b" ]; then break; fi
        warn "Les mots de passe ne correspondent pas."
    done
    printf -v "$__var" '%s' "$__a"
}

part_name() { # part_name <disque> <n> : /dev/sda -> /dev/sda1, /dev/nvme0n1 -> /dev/nvme0n1p1
    case "$1" in
        *[0-9]) printf '%sp%s' "$1" "$2" ;;
        *)      printf '%s%s'  "$1" "$2" ;;
    esac
}

usage() {
    cat <<'EOF'
Usage : bash install-artix.sh

À lancer en root depuis l'ISO live Artix (base runit) démarrée en UEFI.
Le script pose seulement : nom d'utilisateur, nom de la machine et mots de
passe (utilisateur et root). Il trouve le disque tout seul (modèle 870 EVO),
puis partitionne, installe le système de base, configure le chroot (langue,
comptes, rEFInd, services runit) et s'arrête avant le redémarrage.

Variables facultatives :
  DISK=/dev/sdX     impose le disque cible
  DO_DISCARD=yes    TRIM complet du SSD avant partitionnement
  COUNTDOWN=0       supprime le compte à rebours avant l'effacement
  AUTO_REBOOT=yes   redémarre automatiquement à la fin
EOF
}

#===============================================================================
# ÉTAPE 1 : depuis l'ISO live
#===============================================================================
preflight() {
    step "Vérifications préalables"

    [ "$EUID" -eq 0 ] || die "Lance ce script en root (« su - », mot de passe : artix)."
    [ -f "$SELF" ] || die "Lance le script depuis un fichier (bash install-artix.sh), pas depuis un tube."
    [ -d /sys/firmware/efi/efivars ] || die "Pas de mode UEFI détecté. Redémarre l'ISO en UEFI (Secure Boot désactivé)."

    local c
    for c in lsblk sfdisk wipefs mkfs.fat mkfs.ext4 basestrap fstabgen artix-chroot blkid findmnt udevadm; do
        command -v "$c" >/dev/null 2>&1 || die "Commande manquante : $c (es-tu bien sur l'ISO Artix ?)"
    done

    loadkeys "$KEYMAP" 2>/dev/null || warn "loadkeys $KEYMAP a échoué (clavier du live inchangé)."

    if ! ping -c 2 -W 3 artixlinux.org >/dev/null 2>&1; then
        die "Pas de connexion Internet. Branche un câble Ethernet (ou configure le Wi-Fi avec connmanctl) et relance."
    fi
    ok "UEFI, réseau et outils OK"

    if command -v sv >/dev/null 2>&1; then
        SVDIR=/run/runit/service sv up ntpd >/dev/null 2>&1 || true
    fi
    info "Date système : $(date)"

    case "$(awk -F': *' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)" in
        GenuineIntel) UCODE="intel-ucode" ;;
        AuthenticAMD) UCODE="amd-ucode" ;;
        *)            UCODE=""; warn "Processeur non reconnu : aucun microcode ne sera installé." ;;
    esac
    ok "Microcode : ${UCODE:-aucun}"
}

find_target_disk() {
    step "Choix automatique du disque"
    lsblk -dpo NAME,SIZE,MODEL,TRAN,RM -e 1,7,11
    echo

    if [ -z "$DISK" ]; then
        local matches count
        matches=$(lsblk -dpno NAME,MODEL -e 1,7,11 2>/dev/null | awk -v pat="$DISK_MODEL_MATCH" 'index($0, pat) {print $1}') || true
        count=$(grep -c . <<<"$matches" || true)
        if [ "${count:-0}" -ne 1 ]; then
            die "Impossible de choisir le disque automatiquement : $count disque(s) « $DISK_MODEL_MATCH » trouvé(s). Relance en le précisant : DISK=/dev/sdX bash install-artix.sh"
        fi
        DISK="$matches"
    fi

    [ -b "$DISK" ] || die "$DISK n'est pas un périphérique bloc."
    [ "$(lsblk -dno TYPE "$DISK")" = "disk" ] || die "$DISK n'est pas un disque entier (donne /dev/sda, pas /dev/sda1)."

    # Refuser le disque de démarrage (clé USB live)
    local bootsrc bootdisk=""
    bootsrc=$(findmnt -no SOURCE /run/artix/bootmnt 2>/dev/null || true)
    if [ -n "$bootsrc" ]; then
        bootdisk=$(lsblk -no PKNAME "$bootsrc" 2>/dev/null | head -n1 || true)
        if [ "$bootsrc" = "$DISK" ] || { [ -n "$bootdisk" ] && [ "/dev/$bootdisk" = "$DISK" ]; }; then
            die "$DISK est le disque de démarrage (clé USB live). Impose un autre disque : DISK=/dev/sdX bash install-artix.sh"
        fi
    fi

    echo
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "$DISK"
    echo

    local fstypes
    fstypes=$(lsblk -nro FSTYPE "$DISK" || true)
    WINDOWS=0
    if grep -qiE 'ntfs|bitlocker' <<<"$fstypes"; then
        WINDOWS=1
        warn "Une installation WINDOWS (NTFS / BitLocker) a été détectée sur $DISK : elle sera DÉTRUITE."
    elif grep -qE '[[:alnum:]]' <<<"$fstypes"; then
        warn "$DISK contient des données : elles seront DÉTRUITES."
    fi

    ESP_PART=$(part_name "$DISK" 1)
    ROOT_PART=$(part_name "$DISK" 2)
}

ask_config() {
    find_target_disk

    [[ "$DO_DISCARD" =~ ^(yes|no)$ ]] || die "DO_DISCARD doit valoir yes ou no."
    [[ "$COUNTDOWN" =~ ^[0-9]+$ ]] || die "COUNTDOWN doit être un nombre de secondes."
    [[ "$AUTO_REBOOT" =~ ^(yes|no)$ ]] || die "AUTO_REBOOT doit valoir yes ou no."
    [ -f "/usr/share/zoneinfo/$TIMEZONE" ] || die "Fuseau horaire introuvable : $TIMEZONE"

    step "Utilisateur, nom de la machine et mots de passe"

    while true; do
        ask USERNAME "Nom d'utilisateur (minuscules)" ""
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then break; fi
        warn "Nom invalide : minuscules, chiffres, _ et -, en commençant par une lettre."
    done
    case "$USERNAME" in
        root|seat|wheel|audio|video) die "Nom d'utilisateur réservé : $USERNAME" ;;
    esac

    while true; do
        ask HOST_NAME "Nom de la machine" "$DEFAULT_HOSTNAME"
        if [[ "$HOST_NAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then break; fi
        warn "Nom de machine invalide (minuscules, chiffres et -)."
    done

    echo
    info "Les mots de passe sont saisis avec le clavier $KEYMAP (AZERTY). Évite les caractères exotiques."
    ask_secret ROOT_PW "Mot de passe root"
    ask_secret USER_PW "Mot de passe de $USERNAME"

    echo
    printf '%s\n' "================ RÉCAPITULATIF ================"
    printf '  Disque ............ %s (%s)\n' "$DISK" "$(lsblk -dno SIZE,MODEL "$DISK" | xargs)"
    printf '  Partitions ........ %s = ESP %s, %s = ROOT ext4 (reste du disque)\n' "$ESP_PART" "$ESP_SIZE" "$ROOT_PART"
    printf '  Utilisateur ....... %s (groupes wheel, audio, video, seat)\n' "$USERNAME"
    printf '  Nom de machine .... %s\n' "$HOST_NAME"
    printf '  Fuseau / langue ... %s / %s / clavier %s\n' "$TIMEZONE" "$LOCALE" "$KEYMAP"
    printf '  Microcode ......... %s\n' "${UCODE:-aucun}"
    printf '  TRIM complet ...... %s\n' "$DO_DISCARD"
    printf '%s\n' "==============================================="
    if [ "$WINDOWS" -eq 1 ]; then
        printf '%s  WINDOWS SERA SUPPRIMÉ DE %s%s\n' "$C_RED" "$DISK" "$C_RST"
    fi
    printf '%s  TOUT LE CONTENU DE %s VA ÊTRE EFFACÉ.%s\n\n' "$C_RED" "$DISK" "$C_RST"

    if [ "$COUNTDOWN" -gt 0 ]; then
        printf '%s  Début de l'"'"'installation dans %s secondes : Ctrl+C pour annuler.%s\n' "$C_YEL" "$COUNTDOWN" "$C_RST" >/dev/tty
        local i
        for ((i = COUNTDOWN; i > 0; i--)); do
            printf '\r  %3d ' "$i" >/dev/tty
            sleep 1
        done
        printf '\r      \n' >/dev/tty
    fi
}

start_logging() {
    : >"$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Journal de l'installation : $LOG_FILE"
}

prepare_mounts() {
    step "Préparation"
    if findmnt -rn /mnt >/dev/null 2>&1; then
        info "/mnt est monté : démontage"
        umount -R /mnt
    fi
    local mounted
    mounted=$(lsblk -nrpo MOUNTPOINT "$DISK" | grep -v '^$' || true)
    [ -z "$mounted" ] || die "Des partitions de $DISK sont utilisées ($mounted). Démonte-les d'abord."
    ok "Rien n'est monté sur $DISK"
}

partition_disk() {
    step "1.1 Partitionnement GPT de $DISK"

    if [ "$DO_DISCARD" = "yes" ]; then
        blkdiscard -f "$DISK" || warn "blkdiscard non supporté par ce disque (ignoré)."
    fi
    wipefs -af "$DISK"

    sfdisk --wipe always --wipe-partitions always "$DISK" <<EOF
label: gpt
size=${ESP_SIZE}, type=U, name="ESP"
type=L, name="ROOT"
EOF

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle || true
    local i
    for i in $(seq 1 20); do
        if [ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ]; then break; fi
        sleep 0.5
    done
    if [ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ]; then
        ok "Partitions créées : $ESP_PART et $ROOT_PART"
    else
        die "Partitions introuvables après partitionnement ($ESP_PART, $ROOT_PART)."
    fi
}

format_and_mount() {
    step "1.2 Formatage et montage"
    mkfs.fat -F 32 -n ESP "$ESP_PART"
    mkfs.ext4 -F -q -L ROOT "$ROOT_PART"

    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$ESP_PART" /mnt/boot/efi
    findmnt -rn /mnt/boot/efi >/dev/null || die "L'ESP n'est pas montée sur /mnt/boot/efi."
    ok "ROOT sur /mnt, ESP sur /mnt/boot/efi"
}

install_base() {
    step "1.4 Installation du système de base (peut être long)"
    local pkgs=(base base-devel runit seatd-runit pam_rundir dosfstools
                linux-zen linux-zen-headers linux-firmware)
    if [ -n "$UCODE" ]; then pkgs+=("$UCODE"); fi

    if ! retry 3 basestrap /mnt "${pkgs[@]}"; then
        die "basestrap a échoué 3 fois. Vérifie le réseau et les miroirs, puis relance."
    fi
    [ -f /mnt/boot/vmlinuz-linux-zen ] || die "Noyau linux-zen absent après basestrap."
    ok "Système de base installé"
}

generate_fstab() {
    step "1.5 fstab"
    fstabgen -U /mnt >>/mnt/etc/fstab
    sed -i 's/\brelatime\b/noatime/' /mnt/etc/fstab

    local n
    n=$(grep -cvE '^[[:space:]]*(#|$)' /mnt/etc/fstab || true)
    [ "${n:-0}" -ge 2 ] || die "fstab incomplet (attendu : ESP et ROOT)."
    cat /mnt/etc/fstab
    ok "fstab généré"
}

run_chroot() {
    step "Configuration dans le chroot (partie 2 du guide)"

    install -m 700 "$SELF" "/mnt${CHROOT_SCRIPT}"
    {
        printf 'DISK=%q\n'          "$DISK"
        printf 'ESP_PART=%q\n'      "$ESP_PART"
        printf 'ROOT_PART=%q\n'     "$ROOT_PART"
        printf 'USERNAME=%q\n'      "$USERNAME"
        printf 'HOST_NAME=%q\n'     "$HOST_NAME"
        printf 'TIMEZONE=%q\n'      "$TIMEZONE"
        printf 'KEYMAP=%q\n'        "$KEYMAP"
        printf 'LOCALE=%q\n'        "$LOCALE"
        printf 'KERNEL_PARAMS=%q\n' "$KERNEL_PARAMS"
    } >"/mnt${ENV_FILE}"
    chmod 600 "/mnt${ENV_FILE}"

    artix-chroot /mnt /bin/bash "$CHROOT_SCRIPT" --stage2
}

set_passwords() {
    step "Mots de passe"
    printf 'root:%s\n' "$ROOT_PW" | artix-chroot /mnt chpasswd
    printf '%s:%s\n' "$USERNAME" "$USER_PW" | artix-chroot /mnt chpasswd
    unset ROOT_PW USER_PW
    ok "Mots de passe de root et de $USERNAME définis"
}

finish() {
    step "Terminé"
    cp "$LOG_FILE" /mnt/root/install-artix.log 2>/dev/null || true
    rm -f "/mnt${CHROOT_SCRIPT}" "/mnt${ENV_FILE}"
    sync
    umount -R /mnt
    ok "Partitions démontées"

    cat <<EOF

L'installation de base est terminée.

  Prochaine étape : tape « reboot » et retire la clé USB.
    1. Dans le menu rEFInd, choisis "Artix Linux (linux-zen)".
    2. Connecte-toi en console avec ton utilisateur (${USERNAME}).
    3. Lance install-artix-post.sh (pilote NVIDIA, Xfce + Wayfire, ly).

  Journal d'installation : /root/install-artix.log (sur le nouveau système)
EOF
    if [ "$AUTO_REBOOT" = "yes" ]; then
        info "Redémarrage dans 5 secondes (Ctrl+C pour annuler)…"
        sleep 5
        reboot
    fi
}

stage1() {
    preflight
    ask_config
    start_logging
    prepare_mounts
    partition_disk
    format_and_mount
    install_base
    generate_fstab
    run_chroot
    set_passwords
    finish
}

#===============================================================================
# ÉTAPE 2 : dans le chroot (appelée automatiquement avec --stage2)
#===============================================================================
stage2() {
    [ -r "$ENV_FILE" ] || die "Fichier d'environnement introuvable : $ENV_FILE"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    export LC_ALL=C

    step "[chroot] 2.1 Fuseau horaire, langue, clavier, nom de machine"
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    hwclock --systohc || warn "hwclock --systohc a échoué (pas d'horloge matérielle ?)."

    pacman -S --needed --noconfirm nano sudo

    sed -i -e 's/^#\(fr_FR\.UTF-8 UTF-8\)/\1/' -e 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
    grep -q '^fr_FR\.UTF-8 UTF-8' /etc/locale.gen || die "fr_FR.UTF-8 introuvable dans /etc/locale.gen"
    locale-gen

    printf 'export LANG="%s"\nexport LC_COLLATE="C"\n' "$LOCALE" >/etc/locale.conf
    printf 'KEYMAP=%s\n' "$KEYMAP" >/etc/vconsole.conf
    printf '%s\n' "$HOST_NAME" >/etc/hostname
    printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$HOST_NAME" "$HOST_NAME" >/etc/hosts
    ok "Fuseau $TIMEZONE, langue $LOCALE, clavier $KEYMAP, machine $HOST_NAME"

    step "[chroot] 2.2 Optimisation de pacman"
    sed -i -e 's/^#Color$/Color/' -e 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    ok "Color et ParallelDownloads activés"

    step "[chroot] 2.3 pam_rundir"
    [ -f /etc/pam.d/system-login ] || die "/etc/pam.d/system-login introuvable."
    if ! grep -q pam_rundir /etc/pam.d/system-login; then
        echo 'session optional pam_rundir.so' >>/etc/pam.d/system-login
    fi
    grep -q pam_rundir /etc/pam.d/system-login || die "pam_rundir n'a pas pu être ajouté à system-login."
    ok "pam_rundir actif dans system-login"

    step "[chroot] 2.4 Comptes utilisateurs"
    getent group seat >/dev/null || groupadd -r seat
    useradd -m -G wheel,audio,video,seat -s /bin/bash "$USERNAME"

    if ! grep -Eq '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
        echo '@includedir /etc/sudoers.d' >>/etc/sudoers
    fi
    mkdir -p /etc/sudoers.d
    printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    if ! visudo -cf /etc/sudoers.d/10-wheel >/dev/null; then
        rm -f /etc/sudoers.d/10-wheel
        die "Fichier sudoers invalide (supprimé)."
    fi
    ok "Utilisateur $USERNAME créé ($(id -nG "$USERNAME"))"

    step "[chroot] 2.5 rEFInd"
    pacman -S --needed --noconfirm refind efibootmgr
    mountpoint -q /boot/efi || die "/boot/efi n'est pas monté dans le chroot."

    if ! refind-install; then
        warn "refind-install a échoué : nouvelle tentative en mode --usedefault (EFI/BOOT)."
        refind-install --usedefault "$ESP_PART"
    fi

    local rdir
    if [ -f /boot/efi/EFI/refind/refind.conf ]; then
        rdir=/boot/efi/EFI/refind
    elif [ -f /boot/efi/EFI/BOOT/refind.conf ]; then
        rdir=/boot/efi/EFI/BOOT
    else
        die "refind.conf introuvable sur l'ESP après refind-install."
    fi
    info "rEFInd installé dans $rdir"

    # Pilote ext4 (rEFInd doit lire /boot sur la partition ext4)
    if [ ! -f "$rdir/drivers_x64/ext4_x64.efi" ]; then
        mkdir -p "$rdir/drivers_x64"
        cp /usr/share/refind/drivers_x64/ext4_x64.efi "$rdir/drivers_x64/"
    fi
    [ -f "$rdir/drivers_x64/ext4_x64.efi" ] || die "Pilote ext4 de rEFInd introuvable."

    local root_partuuid
    root_partuuid=$(blkid -s PARTUUID -o value "$ROOT_PART")
    [ -n "$root_partuuid" ] || die "PARTUUID de $ROOT_PART introuvable."

    # Options de démarrage (refind_linux.conf)
    {
        printf '"Boot using default options"  "root=PARTUUID=%s %s"\n' "$root_partuuid" "$KERNEL_PARAMS"
        printf '"Boot to terminal"            "root=PARTUUID=%s %s 3"\n' "$root_partuuid" "$KERNEL_PARAMS"
    } >/boot/refind_linux.conf

    # Entrée explicite dans refind.conf
    local conf="$rdir/refind.conf" scan icon
    sed -i -E 's/^(default_selection)/#\1/' "$conf"
    scan=$(grep -E '^scanfor' "$conf" || true)
    if [ -n "$scan" ] && ! grep -q manual <<<"$scan"; then
        sed -i -E 's/^scanfor.*/scanfor internal,external,optical,manual/' "$conf"
    fi
    icon="${rdir#/boot/efi}/icons/os_arch.png"

    cat >>"$conf" <<EOF

# --- Artix Linux (linux-zen) ---
default_selection "Artix Linux"

menuentry "Artix Linux (linux-zen)" {
    icon     ${icon}
    volume   ROOT
    loader   /boot/vmlinuz-linux-zen
    initrd   /boot/initramfs-linux-zen.img
    options  "root=PARTUUID=${root_partuuid} ${KERNEL_PARAMS}"

    submenuentry "Mode terminal (niveau 3)" {
        add_options "3"
    }
    submenuentry "Initramfs de secours" {
        initrd /boot/initramfs-linux-zen-fallback.img
    }
}
EOF

    # Hook pacman : mise à jour de rEFInd sur l'ESP
    mkdir -p /etc/pacman.d/hooks
    cat >/etc/pacman.d/hooks/refind-update.hook <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = refind

[Action]
Description = Mise à jour de rEFInd sur l'ESP...
When = PostTransaction
Exec = /usr/bin/refind-install
EOF

    [ -f /boot/vmlinuz-linux-zen ] || die "/boot/vmlinuz-linux-zen manquant."
    [ -f /boot/initramfs-linux-zen.img ] || die "/boot/initramfs-linux-zen.img manquant."
    [ -f /boot/initramfs-linux-zen-fallback.img ] || warn "Initramfs de secours absent (l'entrée de secours ne fonctionnera pas)."
    ok "rEFInd configuré (entrée explicite + refind_linux.conf + hook)"

    step "[chroot] 2.6 Services runit"
    pacman -S --needed --noconfirm dbus-runit connman connman-runit ntp ntp-runit wpa_supplicant

    local s
    for s in dbus seatd connmand ntpd; do
        [ -d "/etc/runit/sv/$s" ] || die "Service runit introuvable : $s (vérifie : ls /etc/runit/sv)"
        ln -sfn "/etc/runit/sv/$s" "/etc/runit/runsvdir/default/$s"
    done
    ok "Services activés : dbus seatd connmand ntpd"
}

#===============================================================================
# Point d'entrée
#===============================================================================
case "${1:-}" in
    "")          stage1 ;;
    --stage2)    stage2 ;;
    -h|--help)   usage ;;
    *)           usage; exit 1 ;;
esac
