#!/usr/bin/env bash
#===============================================================================
# install-artix.sh — Installation Artix runit, UKI, elogind
#
# Ajouts :
# - boot UKI via rEFInd
# - ordonnanceur I/O : SSD/NVMe/eMMC = mq-deadline, HDD = bfq
#===============================================================================
set -Eeuo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
DISK_MODEL_MATCH="870 EVO"
DISK="${DISK:-}"
DO_DISCARD="${DO_DISCARD:-no}"
COUNTDOWN="${COUNTDOWN:-10}"
AUTO_REBOOT="${AUTO_REBOOT:-no}"

DEFAULT_HOSTNAME="artix"
TIMEZONE="Europe/Paris"
KEYMAP="fr"
LOCALE="fr_FR.UTF-8"
ESP_SIZE="512MiB"

KERNEL_PARAMS="rw loglevel=3 vt.global_cursor_default=0 nouveau.modeset=0 module_blacklist=nouveau nvidia_drm.modeset=1 nvidia_drm.fbdev=1"

LOG_FILE="/root/install-artix.log"
CHROOT_SCRIPT="/root/install-artix.sh"
ENV_FILE="/root/install-artix.env"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

#-------------------------------------------------------------------------------
# Affichage
#-------------------------------------------------------------------------------
if [ -t 2 ]; then
    C_RED=$'\e[1;31m'
    C_GRN=$'\e[1;32m'
    C_YEL=$'\e[1;33m'
    C_BLU=$'\e[1;34m'
    C_RST=$'\e[0m'
else
    C_RED=""
    C_GRN=""
    C_YEL=""
    C_BLU=""
    C_RST=""
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
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

#-------------------------------------------------------------------------------
# Utilitaires
#-------------------------------------------------------------------------------
retry() {
    local n=$1 i
    shift
    for ((i = 1; i <= n; i++)); do
        if "$@"; then
            return 0
        fi
        warn "Tentative $i/$n échouée : $*"
        sleep 3
    done
    return 1
}

ask() {
    local __var=$1 __q=$2 __def=${3-} __ans=""
    if [ -n "$__def" ]; then
        printf '%s [%s] : ' "$__q" "$__def" >/dev/tty
    else
        printf '%s : ' "$__q" >/dev/tty
    fi
    IFS= read -r __ans </dev/tty || true
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

ask_secret() {
    local __var=$1 __q=$2 __a __b
    while true; do
        printf '%s : ' "$__q" >/dev/tty
        IFS= read -rs __a </dev/tty || true
        printf '\n' >/dev/tty
        if [ -z "$__a" ]; then
            warn "Le mot de passe ne peut pas être vide."
            continue
        fi
        printf 'Confirme : ' >/dev/tty
        IFS= read -rs __b </dev/tty || true
        printf '\n' >/dev/tty
        if [ "$__a" = "$__b" ]; then
            break
        fi
        warn "Les mots de passe ne correspondent pas."
    done
    printf -v "$__var" '%s' "$__a"
}

part_name() {
    case "$1" in
        *[0-9]) printf '%sp%s' "$1" "$2" ;;
        *)      printf '%s%s'  "$1" "$2" ;;
    esac
}

check_network() {
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --head --max-time 10 https://artixlinux.org >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=10 https://artixlinux.org >/dev/null 2>&1; then
            return 0
        fi
    fi

    ping -c 2 -W 3 artixlinux.org >/dev/null 2>&1
}

usage() {
    cat <<'EOF'
Usage : bash install-artix.sh

Installation Artix :
- UEFI + GPT
- linux-zen en UKI
- rEFInd boot sur UKI
- elogind (elogind-runit)
- zram configuré par install-artix-post.sh
- ordonnanceurs I/O : SSD/NVMe/eMMC = mq-deadline, HDD = bfq

Variables :
DISK=/dev/sdX     impose le disque
DO_DISCARD=yes    TRIM complet avant partitionnement
COUNTDOWN=0       pas de compte à rebours
AUTO_REBOOT=yes   redémarre à la fin
EOF
}

#-------------------------------------------------------------------------------
# Live : vérifications
#-------------------------------------------------------------------------------
preflight() {
    step "Vérifications préalables"

    [ "$EUID" -eq 0 ] || die "Lance ce script en root."
    [ -f "$SELF" ] || die "Lance le script depuis un fichier, pas depuis un tube."
    [ -d /sys/firmware/efi/efivars ] || die "Pas de mode UEFI détecté."

    local c
    for c in lsblk sfdisk wipefs mkfs.fat mkfs.ext4 basestrap fstabgen artix-chroot blkid findmnt udevadm; do
        command -v "$c" >/dev/null 2>&1 || die "Commande manquante : $c"
    done

    loadkeys "$KEYMAP" 2>/dev/null || warn "loadkeys $KEYMAP a échoué."

    if ! check_network; then
        die "Pas de connexion Internet détectée."
    fi

    ok "UEFI, réseau et outils OK"

    if command -v sv >/dev/null 2>&1; then
        SVDIR=/run/runit/service sv up ntpd >/dev/null 2>&1 || true
    fi

    info "Date système : $(date)"

    case "$(awk -F': *' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)" in
        GenuineIntel) UCODE="intel-ucode" ;;
        AuthenticAMD) UCODE="amd-ucode" ;;
        *) UCODE=""; warn "Processeur non reconnu : aucun microcode." ;;
    esac

    ok "Microcode : ${UCODE:-aucun}"
}

find_target_disk() {
    step "Choix du disque"

    lsblk -dpo NAME,SIZE,MODEL,TRAN,RM -e 1,7,11
    echo

    if [ -z "$DISK" ]; then
        local matches count
        matches=$(lsblk -dpno NAME,MODEL -e 1,7,11 2>/dev/null | awk -v pat="$DISK_MODEL_MATCH" 'index($0, pat) {print $1}') || true
        count=$(grep -c . <<<"$matches" || true)

        if [ "${count:-0}" -ne 1 ]; then
            die "Impossible de choisir le disque automatiquement. Relance avec DISK=/dev/sdX"
        fi

        DISK="$matches"
    fi

    [ -b "$DISK" ] || die "$DISK n'est pas un périphérique bloc."
    [ "$(lsblk -dno TYPE "$DISK")" = "disk" ] || die "$DISK n'est pas un disque entier."

    local bootsrc bootdisk=""
    bootsrc=$(findmnt -no SOURCE /run/artix/bootmnt 2>/dev/null || true)
    if [ -n "$bootsrc" ]; then
        bootdisk=$(lsblk -no PKNAME "$bootsrc" 2>/dev/null | head -n1 || true)
        if [ "$bootsrc" = "$DISK" ] || { [ -n "$bootdisk" ] && [ "/dev/$bootdisk" = "$DISK" ]; }; then
            die "$DISK est le disque de démarrage live."
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
        warn "WINDOWS détecté sur $DISK : il sera détruit."
    elif grep -qE '[[:alnum:]]' <<<"$fstypes"; then
        warn "$DISK contient des données : elles seront détruites."
    fi

    ESP_PART=$(part_name "$DISK" 1)
    ROOT_PART=$(part_name "$DISK" 2)
}

ask_config() {
    find_target_disk

    [[ "$DO_DISCARD" =~ ^(yes|no)$ ]] || die "DO_DISCARD doit valoir yes ou no."
    [[ "$COUNTDOWN" =~ ^[0-9]+$ ]] || die "COUNTDOWN doit être un nombre."
    [[ "$AUTO_REBOOT" =~ ^(yes|no)$ ]] || die "AUTO_REBOOT doit valoir yes ou no."
    [ -f "/usr/share/zoneinfo/$TIMEZONE" ] || die "Fuseau horaire introuvable : $TIMEZONE"

    step "Utilisateur, hostname et mots de passe"

    while true; do
        ask USERNAME "Nom d'utilisateur" ""
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            break
        fi
        warn "Nom invalide."
    done

    case "$USERNAME" in
        root|wheel|audio|video) die "Nom réservé : $USERNAME" ;;
    esac

    while true; do
        ask HOST_NAME "Nom de la machine" "$DEFAULT_HOSTNAME"
        if [[ "$HOST_NAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
            break
        fi
        warn "Nom de machine invalide."
    done

    ask_secret ROOT_PW "Mot de passe root"
    ask_secret USER_PW "Mot de passe de $USERNAME"

    echo
    printf '%s\n' "================ RÉCAPITULATIF ================"
    printf '  Disque ............ %s\n' "$DISK"
    printf '  ESP ............... %s\n' "$ESP_PART"
    printf '  ROOT .............. %s\n' "$ROOT_PART"
    printf '  Utilisateur ....... %s\n' "$USERNAME"
    printf '  Hostname .......... %s\n' "$HOST_NAME"
    printf '  Timezone .......... %s\n' "$TIMEZONE"
    printf '  Locale ............ %s\n' "$LOCALE"
    printf '  Keymap ............ %s\n' "$KEYMAP"
    printf '  Microcode ......... %s\n' "${UCODE:-aucun}"
    printf '  TRIM complet ...... %s\n' "$DO_DISCARD"
    printf '%s\n' "==============================================="

    if [ "$WINDOWS" -eq 1 ]; then
        printf '%s  WINDOWS SERA SUPPRIMÉ DE %s%s\n' "$C_RED" "$DISK" "$C_RST"
    fi

    printf '%s  TOUT LE CONTENU DE %s VA ÊTRE EFFACÉ.%s\n' "$C_RED" "$DISK" "$C_RST"

    if [ "$COUNTDOWN" -gt 0 ]; then
        printf '%s  Début dans %s secondes : Ctrl+C pour annuler.%s\n' "$C_YEL" "$COUNTDOWN" "$C_RST" >/dev/tty
        local i
        for ((i = COUNTDOWN; i > 0; i--)); do
            printf '\r  %3d ' "$i" >/dev/tty
            sleep 1
        done
        printf '\r\n' >/dev/tty
    fi
}

start_logging() {
    : >"$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Journal : $LOG_FILE"
}

prepare_mounts() {
    step "Préparation des montages"

    if findmnt -rn /mnt >/dev/null 2>&1; then
        umount -R /mnt
    fi

    local mounted
    mounted=$(lsblk -nrpo MOUNTPOINT "$DISK" | grep -v '^$' || true)
    [ -z "$mounted" ] || die "Des partitions de $DISK sont montées."

    ok "Rien n'est monté sur $DISK"
}

partition_disk() {
    step "Partitionnement GPT"

    if [ "$DO_DISCARD" = "yes" ]; then
        blkdiscard -f "$DISK" || warn "blkdiscard non supporté."
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
        if [ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ]; then
            break
        fi
        sleep 0.5
    done

    if [ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ]; then
        ok "Partitions créées : $ESP_PART et $ROOT_PART"
    else
        die "Partitions introuvables."
    fi
}

format_and_mount() {
    step "Formatage et montage"

    mkfs.fat -F 32 -n ESP "$ESP_PART"
    mkfs.ext4 -F -q -L ROOT "$ROOT_PART"

    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$ESP_PART" /mnt/boot/efi

    findmnt -rn /mnt/boot/efi >/dev/null || die "ESP non montée."

    ok "ROOT sur /mnt, ESP sur /mnt/boot/efi"
}

install_base() {
    step "Installation de la base"

    local pkgs=(
        base
        runit
        mkinitcpio
        dosfstools
        linux-zen
        linux-zen-headers
        linux-firmware
        binutils
        elogind
        elogind-runit
    )

    if [ -n "$UCODE" ]; then
        pkgs+=("$UCODE")
    fi

    if ! retry 3 basestrap /mnt "${pkgs[@]}"; then
        die "basestrap a échoué."
    fi

    [ -f /mnt/boot/vmlinuz-linux-zen ] || die "Noyau linux-zen absent."

    ok "Base installée"
}

generate_fstab() {
    step "fstab"

    fstabgen -U /mnt >>/mnt/etc/fstab
    sed -i 's/\brelatime\b/noatime/' /mnt/etc/fstab

    local n
    n=$(grep -cvE '^[[:space:]]*(#|$)' /mnt/etc/fstab || true)
    [ "${n:-0}" -ge 2 ] || die "fstab incomplet."

    ok "fstab généré"
}

run_chroot() {
    step "Configuration chroot"

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

    ok "Mots de passe définis"
}

finish() {
    step "Terminé"

    cp "$LOG_FILE" /mnt/root/install-artix.log 2>/dev/null || true
    rm -f "/mnt${CHROOT_SCRIPT}" "/mnt${ENV_FILE}"

    sync
    umount -R /mnt

    ok "Partitions démontées"

    cat <<EOF
Installation de base terminée.

Redémarre, retire la clé USB, puis :
1. Choisis "Artix Linux (UKI linux-zen)" dans rEFInd.
2. Connecte-toi en console avec $USERNAME.
3. Lance install-artix-post.sh
EOF

    if [ "$AUTO_REBOOT" = "yes" ]; then
        info "Redémarrage dans 5 secondes…"
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

#-------------------------------------------------------------------------------
# UKI
#-------------------------------------------------------------------------------
EFI_STUB="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"

# Artix n'a pas systemd : on récupère uniquement le stub EFI depuis le paquet Arch.
EFI_STUB_MIRRORS=(
    "https://geo.mirror.pkgbuild.com"
    "https://fastly.mirror.pkgbuild.com"
    "https://mirrors.kernel.org/archlinux"
)

ensure_efi_stub() {
    [ -f "$EFI_STUB" ] && return 0

    info "Stub EFI systemd absent : récupération depuis un miroir Arch."

    command -v curl >/dev/null 2>&1 || die "curl introuvable."
    (command -v bsdtar || command -v tar) >/dev/null 2>&1 || die "bsdtar/tar introuvable."

    local tmp m base pkg="" found=0
    tmp=$(mktemp -d)

    for m in "${EFI_STUB_MIRRORS[@]}"; do
        base="$m/core/os/x86_64"

        pkg=$(curl -fsSL --max-time 30 "$base/" 2>/dev/null \
            | grep -oE 'systemd-[0-9][^"<>/]*-x86_64\.pkg\.tar\.zst' \
            | sort -Vu | tail -n1) || pkg=""
        [ -n "$pkg" ] || continue

        if curl -fsSL --max-time 300 -o "$tmp/$pkg" "$base/$pkg" \
            && { bsdtar -xf "$tmp/$pkg" -C "$tmp" "${EFI_STUB#/}" 2>/dev/null \
                || tar --zstd -xf "$tmp/$pkg" -C "$tmp" "${EFI_STUB#/}" 2>/dev/null; } \
            && [ "$(head -c2 "$tmp/${EFI_STUB#/}")" = "MZ" ]; then
            found=1
            break
        fi

        warn "Échec avec le miroir $m."
    done

    if [ "$found" -ne 1 ]; then
        rm -rf "$tmp"
        die "Impossible d'obtenir le stub EFI systemd."
    fi

    install -Dm644 "$tmp/${EFI_STUB#/}" "$EFI_STUB"
    rm -rf "$tmp"

    [ -f "$EFI_STUB" ] || die "Stub EFI introuvable après extraction."
    ok "Stub EFI installé : $EFI_STUB"
}

setup_uki() {
    step "[chroot] UKI"

    command -v objcopy >/dev/null 2>&1 || die "objcopy introuvable (binutils)."
    ensure_efi_stub
    mountpoint -q /boot/efi || die "/boot/efi non monté."

    mkdir -p /etc/uki /usr/local/bin /etc/pacman.d/hooks /boot/efi/EFI/Linux

    local root_partuuid
    root_partuuid=$(blkid -s PARTUUID -o value "$ROOT_PART")
    [ -n "$root_partuuid" ] || die "PARTUUID introuvable."

    printf 'root=PARTUUID=%s %s\n' "$root_partuuid" "$KERNEL_PARAMS" > /etc/uki/cmdline

    cat > /usr/local/bin/artix-uki-update <<'EOF'
#!/bin/sh
set -eu

ESP=/boot/efi
KERNEL=/boot/vmlinuz-linux-zen
INITRD=/boot/initramfs-linux-zen.img
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
OUT="$ESP/EFI/Linux/artix-linux-zen.efi"
CMDLINE_FILE=/etc/uki/cmdline

REBUILD=0
[ "${1:-}" = "--rebuild" ] && REBUILD=1

[ -f "$CMDLINE_FILE" ] || { echo "cmdline UKI manquante" >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "Noyau manquant" >&2; exit 1; }
[ -f "$STUB" ] || { echo "Stub EFI manquant : $STUB" >&2; exit 1; }

if [ "$REBUILD" -eq 1 ] || [ ! -f "$INITRD" ] || [ "$KERNEL" -nt "$INITRD" ]; then
    mkinitcpio -P
fi

if ! mountpoint -q "$ESP"; then
    mount "$ESP"
fi

mkdir -p "$ESP/EFI/Linux"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '%s' "$(cat "$CMDLINE_FILE")" > "$TMP/cmdline"

if command -v ukify >/dev/null 2>&1; then
    if ukify build \
        --linux="$KERNEL" \
        --initrd="$INITRD" \
        --cmdline="$(cat "$CMDLINE_FILE")" \
        --stub="$STUB" \
        --output="$OUT.tmp"; then
        mv -f "$OUT.tmp" "$OUT"
        exit 0
    fi
fi

objcopy \
    --add-section .osrel=/etc/os-release \
    --change-section-vma .osrel=0x20000 \
    --add-section .cmdline="$TMP/cmdline" \
    --change-section-vma .cmdline=0x30000 \
    --add-section .linux="$KERNEL" \
    --change-section-vma .linux=0x2000000 \
    --add-section .initrd="$INITRD" \
    --change-section-vma .initrd=0x4000000 \
    "$STUB" "$OUT.tmp"

mv -f "$OUT.tmp" "$OUT"
EOF

    chmod +x /usr/local/bin/artix-uki-update

    cat > /etc/pacman.d/hooks/zz-artix-uki.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux-zen

[Action]
Description = Mise à jour UKI Artix (noyau)...
When = PostTransaction
Exec = /usr/local/bin/artix-uki-update
EOF

    cat > /etc/pacman.d/hooks/zz-artix-uki-deps.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = nvidia-open-dkms
Target = nvidia-dkms
Target = nvidia-utils
Target = intel-ucode
Target = amd-ucode
Target = mkinitcpio

[Action]
Description = Reconstruction initramfs + UKI Artix (pilote/microcode)...
When = PostTransaction
Exec = /usr/local/bin/artix-uki-update --rebuild
EOF

    /usr/local/bin/artix-uki-update

    [ -f /boot/efi/EFI/Linux/artix-linux-zen.efi ] || die "UKI non créé."

    ok "UKI créé : /boot/efi/EFI/Linux/artix-linux-zen.efi"
}

#-------------------------------------------------------------------------------
# Ordonnanceurs I/O
#-------------------------------------------------------------------------------
setup_io_scheduler() {
    step "[chroot] Ordonnanceurs I/O"

    mkdir -p /etc/udev/rules.d /etc/modules-load.d

    cat > /etc/udev/rules.d/60-ioscheduler.rules <<'EOF'
# SSD / NVMe / eMMC = mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]|sd[a-z][a-z]|mmcblk[0-9]|nvme[0-9]*n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"

# HDD mécaniques = bfq
ACTION=="add|change", KERNEL=="sd[a-z]|sd[a-z][a-z]|mmcblk[0-9]|nvme[0-9]*n[0-9]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF

    printf 'bfq\n' > /etc/modules-load.d/bfq.conf

    ok "SSD/NVMe/eMMC -> mq-deadline, HDD -> bfq"
}

#-------------------------------------------------------------------------------
# chroot stage2
#-------------------------------------------------------------------------------
stage2() {
    [ -r "$ENV_FILE" ] || die "Environnement chroot introuvable."
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    export LC_ALL=C

    step "[chroot] Locale, timezone, hostname"

    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    hwclock --systohc || warn "hwclock a échoué."

    pacman -S --needed --noconfirm nano sudo

    sed -i -e 's/^#\(fr_FR\.UTF-8 UTF-8\)/\1/' -e 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
    grep -q '^fr_FR\.UTF-8 UTF-8' /etc/locale.gen || die "fr_FR.UTF-8 introuvable."

    locale-gen

    printf 'export LANG="%s"\nexport LC_COLLATE="C"\n' "$LOCALE" >/etc/locale.conf
    printf 'KEYMAP=%s\n' "$KEYMAP" >/etc/vconsole.conf
    printf '%s\n' "$HOST_NAME" >/etc/hostname

    printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$HOST_NAME" "$HOST_NAME" >/etc/hosts

    step "[chroot] pacman"
    sed -i -e 's/^#Color$/Color/' -e 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf

    setup_io_scheduler

    step "[chroot] PAM"
    [ -f /etc/pam.d/system-login ] || die "/etc/pam.d/system-login introuvable."
    if ! grep -q pam_elogind /etc/pam.d/system-login; then
        echo 'session optional pam_elogind.so' >>/etc/pam.d/system-login
    fi

    step "[chroot] Utilisateur"
    useradd -m -G wheel,audio,video -s /bin/bash "$USERNAME"

    if ! grep -Eq '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
        echo '@includedir /etc/sudoers.d' >>/etc/sudoers
    fi

    mkdir -p /etc/sudoers.d
    printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers.d/10-wheel >/dev/null || die "sudoers invalide."

    step "[chroot] rEFInd + UKI"

    pacman -S --needed --noconfirm refind efibootmgr

    if ! refind-install; then
        warn "refind-install a échoué, tentative --usedefault."
        refind-install --usedefault "$ESP_PART"
    fi

    local rdir
    if [ -f /boot/efi/EFI/refind/refind.conf ]; then
        rdir=/boot/efi/EFI/refind
    elif [ -f /boot/efi/EFI/BOOT/refind.conf ]; then
        rdir=/boot/efi/EFI/BOOT
    else
        die "refind.conf introuvable."
    fi

    setup_uki

    local conf="$rdir/refind.conf" icon
    icon="${rdir#/boot/efi}/icons/os_arch.png"

    sed -i -E 's/^(default_selection)/#\1/' "$conf"

    if grep -q '^scanfor' "$conf"; then
        sed -i -E 's/^scanfor.*/scanfor manual/' "$conf"
    else
        echo 'scanfor manual' >>"$conf"
    fi

    cat >>"$conf" <<EOF
# --- Artix Linux UKI ---
default_selection "Artix Linux"

menuentry "Artix Linux (UKI linux-zen)" {
    icon     ${icon}
    volume   ESP
    loader   /EFI/Linux/artix-linux-zen.efi
    ostype   Linux
}
EOF

    rm -f /boot/refind_linux.conf

    mkdir -p /etc/pacman.d/hooks
    cat >/etc/pacman.d/hooks/refind-update.hook <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = refind

[Action]
Description = Mise à jour rEFInd...
When = PostTransaction
Exec = /usr/bin/refind-install
EOF

    step "[chroot] Services runit"

    pacman -S --needed --noconfirm dbus-runit connman connman-runit ntp ntp-runit wpa_supplicant

    local s
    for s in dbus elogind connmand ntpd; do
        [ -d "/etc/runit/sv/$s" ] || die "Service introuvable : $s"
        ln -sfn "/etc/runit/sv/$s" "/etc/runit/runsvdir/default/$s"
    done

    ok "Configuration chroot terminée"
}

#-------------------------------------------------------------------------------
# Entrée
#-------------------------------------------------------------------------------
case "${1:-}" in
    "")        stage1 ;;
    --stage2)  stage2 ;;
    -h|--help) usage ;;
    *)         usage; exit 1 ;;
esac
