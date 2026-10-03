#!/usr/bin/env bash
#===============================================================================
# install-artix-post.sh — post-install Artix
#
# - aucun elogind
# - seatd
# - UKI
# - greetd + gtkgreet + cage
# - cage installé via paru
# - paru installé au début
# - NVIDIA optionnel
# - firewalld activé et configuré
# - SSD/NVMe/eMMC = mq-deadline, HDD = bfq
#===============================================================================
set -Eeuo pipefail

LOG_FILE="$HOME/install-artix-post.log"
SESSION_NAME="xfce-wayfire"

ASSUME_YES=0
NO_REBOOT=0
FORCE_NVIDIA="auto"
NVIDIA=0
MODE="install"

KERNEL_PARAMS_DEFAULT="rw loglevel=3 vt.global_cursor_default=0 nouveau.modeset=0 module_blacklist=nouveau nvidia_drm.modeset=1 nvidia_drm.fbdev=1"

usage() {
    cat <<'EOF'
Usage : bash install-artix-post.sh [options]

Options :
  --check       vérifie
  --yes         répond oui
  --no-reboot   ne redémarre pas
  --nvidia      force NVIDIA
  --no-nvidia   désactive NVIDIA
  -h, --help    aide
EOF
}

for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        --yes|-y) ASSUME_YES=1 ;;
        --no-reboot) NO_REBOOT=1 ;;
        --nvidia) FORCE_NVIDIA="yes" ;;
        --no-nvidia) FORCE_NVIDIA="no" ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

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

SUDO_KEEPALIVE_PID=""
cleanup() {
    if [ -n "$SUDO_KEEPALIVE_PID" ]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

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

confirm_yn() {
    local q=$1 def=${2:-n} a hint timeout=120

    if [ "$ASSUME_YES" -eq 1 ]; then
        [ "$def" = "o" ] && return 0 || return 1
    fi

    if [ "$def" = "o" ]; then
        hint="O/n"
    else
        hint="o/N"
    fi

    if [ ! -e /dev/tty ]; then
        [ "$def" = "o" ] && return 0 || return 1
    fi

    printf '%s [%s] : ' "$q" "$hint" >/dev/tty
    IFS= read -r -t "$timeout" a </dev/tty || a=""
    a=${a:-$def}

    case "${a,,}" in
        o|oui|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

pkg_installed() { pacman -Q "$1" >/dev/null 2>&1; }
pkg_available() { pacman -Si "$1" >/dev/null 2>&1 || pacman -Q "$1" >/dev/null 2>&1; }

install_pkg_official_or_paru() {
    local p=$1

    if pkg_installed "$p"; then
        return 0
    fi

    if pkg_available "$p"; then
        if retry 2 sudo pacman -S --needed --noconfirm "$p"; then
            return 0
        fi
    fi

    if command -v paru >/dev/null 2>&1; then
        if retry 2 paru -S --needed --noconfirm "$p"; then
            return 0
        fi
    fi

    return 1
}

find_service() {
    local prefix=$1 f

    if [ -d "/etc/runit/sv/$prefix" ]; then
        printf '%s' "$prefix"
        return 0
    fi

    for f in /etc/runit/sv/"$prefix"*; do
        if [ -d "$f" ]; then
            basename "$f"
            return 0
        fi
    done

    return 1
}

enable_service() {
    local sv=$1
    if [ ! -d "/etc/runit/sv/$sv" ]; then
        return 1
    fi
    sudo ln -sfn "/etc/runit/sv/$sv" "/etc/runit/runsvdir/default/$sv"
}

install_sudoers() {
    local name=$1 content=$2 tmp
    tmp=$(mktemp)
    printf '%s\n' "$content" >"$tmp"

    if sudo visudo -cf "$tmp" >/dev/null; then
        sudo install -m 440 -o root -g root "$tmp" "/etc/sudoers.d/$name"
        rm -f "$tmp"
        return 0
    else
        rm -f "$tmp"
        die "Règle sudoers invalide : $name"
    fi
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

detect_nvidia_pci() {
    local v
    for v in /sys/bus/pci/devices/*/vendor; do
        if [ -r "$v" ] && [ "$(cat "$v")" = "0x10de" ]; then
            return 0
        fi
    done
    return 1
}

initialize_environment() {
    if [ "$FORCE_NVIDIA" = "yes" ]; then
        NVIDIA=1
    elif [ "$FORCE_NVIDIA" = "no" ]; then
        NVIDIA=0
    else
        if detect_nvidia_pci; then
            NVIDIA=1
        else
            NVIDIA=0
        fi
    fi
}

start_logging() {
    : >"$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Journal : $LOG_FILE"
}

#-------------------------------------------------------------------------------
# Installation
#-------------------------------------------------------------------------------
preflight() {
    step "Préflight"

    [ "$EUID" -ne 0 ] || die "Lance ce script en utilisateur normal."
    [ -f /etc/artix-release ] || die "Pas Artix."
    [ -d /etc/runit/runsvdir/default ] || die "runit introuvable."

    sudo -v || die "sudo ne fonctionne pas."

    (
        while true; do
            sudo -n true 2>/dev/null
            sleep 50
            kill -0 "$$" 2>/dev/null || exit 0
        done
    ) >/dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!

    if ! check_network; then
        die "Pas de connexion Internet."
    fi

    initialize_environment

    if [ "$NVIDIA" -eq 1 ]; then
        info "NVIDIA activé."
    else
        info "NVIDIA désactivé."
    fi

    if ! getent group seat >/dev/null 2>&1; then
        sudo groupadd -r seat
    fi

    if ! getent group seatd >/dev/null 2>&1; then
        sudo groupadd -r seatd
    fi

    if ! id -nG | grep -qw seat; then
        sudo gpasswd -a "$USER" seat || true
        warn "Groupe seat ajouté : effectif après reboot/login."
    fi

    if ! id -nG | grep -qw seatd; then
        sudo gpasswd -a "$USER" seatd || true
        warn "Groupe seatd ajouté : effectif après reboot/login."
    fi

    ok "Préflight OK"
}

remove_unwanted() {
    step "Nettoyage : elogind, ly, sddm, xorg-server, ufw"

    local p
    for p in elogind elogind-runit libelogind ly ly-runit sddm sddm-runit xorg-server ufw; do
        if pkg_installed "$p"; then
            sudo pacman -Rns --noconfirm "$p" || warn "Impossible de supprimer $p"
        fi
    done

    sudo rm -f /etc/runit/runsvdir/default/elogind
    sudo rm -f /etc/runit/runsvdir/default/ly*
    sudo rm -f /etc/runit/runsvdir/default/sddm
    sudo rm -f /etc/runit/runsvdir/default/agetty-tty2
    sudo rm -f /etc/runit/runsvdir/default/ufw

    if [ -f /etc/pam.d/system-login ]; then
        sudo sed -i '/pam_elogind/d' /etc/pam.d/system-login || true
    fi

    if pacman -Q | grep -Eiq 'elogind|libelogind'; then
        warn "Des paquets elogind/logind semblent encore présents."
    else
        ok "Aucun paquet elogind détecté."
    fi
}

update_system() {
    step "Mise à jour"
    retry 3 sudo pacman -Syu --noconfirm
    ok "Système à jour"
}

install_base_deps() {
    step "Dépendances de base"
    retry 3 sudo pacman -S --needed --noconfirm base-devel git binutils linux-zen-headers
    ok "base-devel/git/binutils installés"
}

install_paru() {
    step "AUR helper : paru"

    if command -v paru >/dev/null 2>&1; then
        ok "paru déjà installé."
        return 0
    fi

    local tmp="$HOME/.cache/aurbuild"
    mkdir -p "$tmp"

    rm -rf "$tmp/paru-bin"
    git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"

    if (cd "$tmp/paru-bin" && makepkg -si --noconfirm); then
        ok "paru-bin installé."
    else
        warn "paru-bin a échoué, tentative de paru source."
        rm -rf "$tmp/paru"
        git clone --depth 1 https://aur.archlinux.org/paru.git "$tmp/paru"
        (cd "$tmp/paru" && makepkg -si --noconfirm) || die "Impossible d'installer paru."
    fi

    command -v paru >/dev/null 2>&1 || die "paru introuvable après installation."

    mkdir -p "$HOME/.config/paru"
    cat >"$HOME/.config/paru/paru.conf" <<'EOF'
[options]
SudoLoop
UseAsk
RemoveMake
SkipReview
EOF

    ok "paru configuré."
}

install_auris() {
    step "AURIS (si disponible)"

    if command -v paru >/dev/null 2>&1; then
        if paru -Si auris >/dev/null 2>&1; then
            paru -S --needed --noconfirm auris || warn "Installation de auris impossible."
        else
            warn "AURIS introuvable dans l'AUR. Si tu parlais d'un autre paquet, adapte le nom."
        fi
    else
        warn "paru absent : AURIS non installé."
    fi
}

setup_io_scheduler() {
    step "Ordonnanceurs I/O"

    sudo mkdir -p /etc/udev/rules.d /etc/modules-load.d

    sudo tee /etc/udev/rules.d/60-ioscheduler.rules >/dev/null <<'EOF'
# SSD / NVMe / eMMC = mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]|sd[a-z][a-z]|mmcblk[0-9]|nvme[0-9]*n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"

# HDD mécaniques = bfq
ACTION=="add|change", KERNEL=="sd[a-z]|sd[a-z][a-z]|mmcblk[0-9]|nvme[0-9]*n[0-9]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF

    printf 'bfq\n' | sudo tee /etc/modules-load.d/bfq.conf >/dev/null

    ok "SSD/NVMe/eMMC -> mq-deadline, HDD -> bfq"
}

setup_firewalld() {
    step "firewalld"

    install_pkg_official_or_paru firewalld || warn "firewalld officiel/AUR non installé."
    install_pkg_official_or_paru firewalld-runit || true

    if ! pkg_installed firewalld; then
        die "firewalld n'a pas pu être installé."
    fi

    sudo mkdir -p /etc/firewalld

    if [ -f /etc/firewalld/firewalld.conf ]; then
        if grep -Eq '^[#[:space:]]*DefaultZone=' /etc/firewalld/firewalld.conf; then
            sudo sed -i -E 's/^[#[:space:]]*DefaultZone=.*/DefaultZone=public/' /etc/firewalld/firewalld.conf
        else
            echo 'DefaultZone=public' | sudo tee -a /etc/firewalld/firewalld.conf >/dev/null
        fi

        if grep -Eq '^[#[:space:]]*FirewallBackend=' /etc/firewalld/firewalld.conf; then
            sudo sed -i -E 's/^[#[:space:]]*FirewallBackend=.*/FirewallBackend=nftables/' /etc/firewalld/firewalld.conf
        else
            echo 'FirewallBackend=nftables' | sudo tee -a /etc/firewalld/firewalld.conf >/dev/null
        fi
    else
        sudo tee /etc/firewalld/firewalld.conf >/dev/null <<'EOF'
DefaultZone=public
FirewallBackend=nftables
EOF
    fi

    local fw_bin
    fw_bin=$(command -v firewalld || true)

    if [ ! -d /etc/runit/sv/firewalld ] && [ -n "$fw_bin" ]; then
        sudo mkdir -p /etc/runit/sv/firewalld
        sudo tee /etc/runit/sv/firewalld/run >/dev/null <<EOF
#!/bin/sh
exec $fw_bin --nofork
EOF
        sudo chmod +x /etc/runit/sv/firewalld/run
    fi

    local sv
    sv=$(find_service firewalld || true)

    if [ -z "$sv" ]; then
        die "Service firewalld introuvable."
    fi

    enable_service "$sv" || die "Impossible d'activer firewalld."

    if command -v sv >/dev/null 2>&1; then
        sudo sv up "$sv" || true
    fi

    ok "firewalld activé (zone par défaut : public, backend : nftables)."
}

install_nvidia() {
    step "NVIDIA"

    if [ "$NVIDIA" -eq 0 ]; then
        ok "NVIDIA désactivé."
        return 0
    fi

    local pkg=""
    local cand
    for cand in nvidia-open-dkms nvidia-dkms; do
        if pkg_available "$cand"; then
            pkg="$cand"
            break
        fi
    done

    [ -n "$pkg" ] || die "Aucun paquet NVIDIA DKMS trouvé."

    retry 3 sudo pacman -S --needed --noconfirm "$pkg" nvidia-utils dkms || die "Installation NVIDIA impossible."

    sudo mkdir -p /etc/modprobe.d
    sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

    local dk
    dk=$(sudo dkms status 2>&1 || true)
    if ! grep -Eiq 'nvidia.*/.*: installed' <<<"$dk"; then
        sudo dkms autoinstall || die "DKMS NVIDIA a échoué."
    fi

    if ! modinfo nvidia >/dev/null 2>&1; then
        die "Module NVIDIA introuvable."
    fi

    ok "NVIDIA installé."
}

ensure_uki_helper() {
    step "UKI helper"

    if [ ! -f /etc/uki/cmdline ]; then
        local root_dev root_partuuid
        root_dev=$(findmnt -no SOURCE /)
        root_partuuid=$(sudo blkid -s PARTUUID -o value "$root_dev")
        sudo mkdir -p /etc/uki
        printf 'root=PARTUUID=%s %s\n' "$root_partuuid" "$KERNEL_PARAMS_DEFAULT" | sudo tee /etc/uki/cmdline >/dev/null
    fi

    if [ ! -x /usr/local/bin/artix-uki-update ]; then
        sudo tee /usr/local/bin/artix-uki-update >/dev/null <<'EOF'
#!/bin/sh
set -eu

ESP=/boot/efi
KERNEL=/boot/vmlinuz-linux-zen
INITRD=/boot/initramfs-linux-zen.img
OUT="$ESP/EFI/Linux/artix-linux-zen.efi"
CMDLINE_FILE=/etc/uki/cmdline

[ -f "$CMDLINE_FILE" ] || { echo "cmdline UKI manquante" >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "Noyau manquant" >&2; exit 1; }

if [ ! -f "$INITRD" ] || [ "$KERNEL" -nt "$INITRD" ]; then
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
    --add-section .initrd="$INITRD" \
    --change-section-vma .initrd=0x3000000 \
    "$KERNEL" "$OUT.tmp"

mv -f "$OUT.tmp" "$OUT"
EOF
        sudo chmod +x /usr/local/bin/artix-uki-update
    fi

    ok "UKI helper prêt."
}

configure_initramfs_and_uki() {
    step "mkinitcpio + UKI"

    local mk=/etc/mkinitcpio.conf
    [ -f "$mk" ] || die "$mk introuvable."

    if [ ! -f "${mk}.bak-post" ]; then
        sudo cp -a "$mk" "${mk}.bak-post"
    fi

    if [ "$NVIDIA" -eq 1 ]; then
        if grep -Eq '^MODULES=\(' "$mk"; then
            sudo sed -i -E 's/^MODULES=\(.*\)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' "$mk"
        else
            printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' | sudo tee -a "$mk" >/dev/null
        fi
    else
        if grep -Eq '^MODULES=.*nvidia' "$mk"; then
            sudo sed -i -E 's/^MODULES=\(.*\)/MODULES=()/' "$mk"
        fi
    fi

    if grep -Eq '^HOOKS=\(' "$mk"; then
        sudo sed -i -E '/^HOOKS=/ s/(^HOOKS=\(|[[:space:]])kms([[:space:]]|\))/\1\2/g' "$mk"
        sudo sed -i -E '/^HOOKS=/ { s/[[:space:]]+/ /g; s/\( /\(/; s/ \)/\)/; }' "$mk"

        if ! grep -Eq '^HOOKS=.*microcode' "$mk"; then
            if grep -Eq '^HOOKS=.*autodetect' "$mk"; then
                sudo sed -i -E '/^HOOKS=/ s/autodetect/autodetect microcode/' "$mk"
            elif grep -Eq '^HOOKS=.*base' "$mk"; then
                sudo sed -i -E '/^HOOKS=/ s/base/base microcode/' "$mk"
            else
                sudo sed -i -E '/^HOOKS=/ s/^HOOKS=\(/HOOKS=(microcode /' "$mk"
            fi
        fi
    else
        printf 'HOOKS=(base udev autodetect microcode modconf keyboard keymap consolefont block filesystems fsck)\n' | sudo tee -a "$mk" >/dev/null
    fi

    local out
    out=$(sudo mkinitcpio -P 2>&1) || {
        printf '%s\n' "$out"
        die "mkinitcpio -P a échoué."
    }

    printf '%s\n' "$out"

    if grep -q 'ERROR' <<<"$out"; then
        warn "mkinitcpio a signalé des erreurs. Vérifie la sortie ci-dessus."
    fi

    sudo /usr/local/bin/artix-uki-update

    [ -f /boot/efi/EFI/Linux/artix-linux-zen.efi ] || die "UKI absent après mise à jour."

    ok "initramfs + UKI mis à jour."
}

install_desktop() {
    step "Bureau léger + greetd/gtkgreet/cage"

    local core_pkgs=(
        xfce4-session
        xfce4-panel
        xfdesktop
        xfce4-settings
        thunar
        xfce4-appfinder
        xfce4-terminal
        wayfire
        xorg-xwayland
        swaylock
        swayidle
        grim
        slurp
        wl-clipboard
        pipewire
        pipewire-pulse
        pipewire-alsa
        wireplumber
        udisks2
        gvfs
        polkit-gnome
        xdg-user-dirs
        xdg-utils
        ttf-liberation
    )

    local greetd_pkgs=(
        greetd
        greetd-runit
        gtkgreet
    )

    local aur_pkgs=(
        cage
    )

    local optional_pkgs=(
        wcm
        wlr-randr
        pavucontrol
        cronie
        cronie-runit
    )

    local p

    for p in "${core_pkgs[@]}"; do
        install_pkg_official_or_paru "$p" || warn "Paquet non installé : $p"
    done

    for p in "${greetd_pkgs[@]}"; do
        install_pkg_official_or_paru "$p" || warn "Paquet non installé : $p"
    done

    # cage explicitement via paru
    for p in "${aur_pkgs[@]}"; do
        if command -v paru >/dev/null 2>&1; then
            retry 2 paru -S --needed --noconfirm "$p" || warn "Paquet AUR non installé : $p"
        else
            warn "paru absent : impossible d'installer $p"
        fi
    done

    for p in "${optional_pkgs[@]}"; do
        install_pkg_official_or_paru "$p" || true
    done

    for p in xfce4-session wayfire xorg-xwayland greetd gtkgreet cage; do
        pkg_installed "$p" || die "Paquet critique manquant : $p"
    done

    if [ -x /usr/bin/startxfce4 ] && grep -qa -- '--wayland' /usr/bin/startxfce4 2>/dev/null; then
        ok "startxfce4 supporte --wayland."
    else
        warn "startxfce4 ne semble pas supporter --wayland. Le script utilisera un fallback Wayfire."
    fi

    ok "Bureau et greetd installés."
}

write_session_files() {
    step "Session Wayfire/Xfce"

    sudo mkdir -p /usr/local/bin /usr/share/wayland-sessions

    sudo tee /usr/local/bin/start-xfce-wayfire >/dev/null <<'EOF'
#!/bin/sh
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=xfce
export XDG_CURRENT_DESKTOP=XFCE

if [ -z "$XDG_RUNTIME_DIR" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
fi

if [ -e /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]; then
    export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
fi

pkill -u "$(id -u)" -x pipewire-pulse 2>/dev/null
pkill -u "$(id -u)" -x wireplumber 2>/dev/null
pkill -u "$(id -u)" -x pipewire 2>/dev/null
sleep 0.5

exec dbus-run-session -- sh -c "
/usr/bin/pipewire &
/usr/bin/pipewire-pulse &
/usr/bin/wireplumber &

if [ -x /usr/bin/startxfce4 ] && grep -qa -- --wayland /usr/bin/startxfce4 2>/dev/null; then
    exec /usr/bin/startxfce4 --wayland wayfire
else
    /usr/bin/xfce4-session &
    exec /usr/bin/wayfire
fi
"
EOF

    sudo chmod +x /usr/local/bin/start-xfce-wayfire

    sudo tee "/usr/share/wayland-sessions/$SESSION_NAME.desktop" >/dev/null <<EOF
[Desktop Entry]
Name=Xfce (Wayfire)
Comment=Xfce sur Wayland avec Wayfire
Exec=/usr/local/bin/start-xfce-wayfire
TryExec=/usr/local/bin/start-xfce-wayfire
Type=Application
DesktopNames=XFCE
EOF

    sudo tee /usr/local/bin/screenshot >/dev/null <<'EOF'
#!/bin/sh
[ -f "$HOME/.config/user-dirs.dirs" ] && . "$HOME/.config/user-dirs.dirs"
DIR="${XDG_PICTURES_DIR:-$HOME/Pictures}/Captures"
mkdir -p "$DIR"
FILE="$DIR/$(date +%Y-%m-%d_%H-%M-%S).png"

case "$1" in
    full)
        grim "$FILE"
        ;;
    area)
        geo=$(slurp) || exit 0
        grim -g "$geo" "$FILE"
        ;;
    clip)
        grim - | wl-copy -t image/png
        ;;
    clip-area)
        geo=$(slurp) || exit 0
        grim -g "$geo" - | wl-copy -t image/png
        ;;
esac
EOF

    sudo chmod +x /usr/local/bin/screenshot

    ok "Session et screenshots installés."
}

write_user_config() {
    step "Configuration utilisateur"

    mkdir -p "$HOME/.config/swaylock"

    cat >"$HOME/.config/swaylock/config" <<'EOF'
daemonize
ignore-empty-password
show-failed-attempts
color=1e1e2e
EOF

    local polkit_agent=""
    local cand
    for cand in /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 /usr/libexec/polkit-gnome-authentication-agent-1; do
        if [ -x "$cand" ]; then
            polkit_agent="$cand"
            break
        fi
    done

    local polkit_line="# polkit agent introuvable"
    if [ -n "$polkit_agent" ]; then
        polkit_line="polkit = $polkit_agent"
    fi

    cat >"$HOME/.config/wayfire.ini" <<EOF
[autostart]
autostart_wf_shell = false
session = xfce4-session
${polkit_line}
idle = swayidle -w timeout 300 swaylock before-sleep swaylock

[input]
xkb_layout = fr

[idle]
dpms_timeout = 600

[command]
binding_terminal = <super> KEY_ENTER
command_terminal = xfce4-terminal

binding_launcher = <super> KEY_D
command_launcher = xfce4-appfinder

binding_files = <super> KEY_E
command_files = thunar

binding_lock = <super> KEY_L
command_lock = swaylock

binding_logout = <super> <shift> KEY_E
command_logout = xfce4-session-logout

binding_exit = <ctrl> <alt> KEY_BACKSPACE
command_exit = pkill -x wayfire

binding_shot_full = KEY_PRINT
command_shot_full = screenshot full

binding_shot_area = <shift> KEY_PRINT
command_shot_area = screenshot area

binding_shot_clip = <ctrl> KEY_PRINT
command_shot_clip = screenshot clip

binding_shot_clip_area = <ctrl> <shift> KEY_PRINT
command_shot_clip_area = screenshot clip-area

repeatable_binding_volume_up = KEY_VOLUMEUP
command_volume_up = wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+

repeatable_binding_volume_down = KEY_VOLUMEDOWN
command_volume_down = wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-

binding_mute = KEY_MUTE
command_mute = wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
EOF

    if command -v xdg-user-dirs-update >/dev/null 2>&1; then
        LANG=fr_FR.UTF-8 xdg-user-dirs-update || true
    fi

    ok "wayfire.ini et swaylock configurés."
}

configure_privileges() {
    step "Privilèges shutdown/USB"

    local cmds="" c p helper

    for c in poweroff reboot halt shutdown; do
        p=$(command -v "$c" || true)
        if [ -n "$p" ] && [[ ",$cmds," != *",$p,"* ]]; then
            cmds="${cmds:+$cmds,}$p"
        fi
    done

    if [ -x /usr/lib/xfce4/session/xfsm-shutdown-helper ]; then
        helper="/usr/lib/xfce4/session/xfsm-shutdown-helper"
        cmds="${cmds:+$cmds,}$helper"
    fi

    if [ -n "$cmds" ]; then
        install_sudoers 20-shutdown "%wheel ALL=(root) NOPASSWD: $cmds"
    fi

    sudo mkdir -p /etc/polkit-1/rules.d
    sudo tee /etc/polkit-1/rules.d/50-udisks-wheel.rules >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel") &&
        action.id.indexOf("org.freedesktop.udisks2.") == 0) {
        return polkit.Result.YES;
    }
});
EOF

    ok "Privilèges configurés."
}

setup_greetd() {
    step "greetd + gtkgreet + cage"

    sudo mkdir -p /etc/greetd /var/lib/greetd

    local cage_bin gtkgreet_bin greetd_bin
    cage_bin=$(command -v cage || true)
    gtkgreet_bin=$(command -v gtkgreet || true)
    greetd_bin=$(command -v greetd || true)

    [ -n "$cage_bin" ] || die "cage introuvable."
    [ -n "$gtkgreet_bin" ] || die "gtkgreet introuvable."
    [ -n "$greetd_bin" ] || die "greetd introuvable."

    local greet_cmd="$cage_bin -s -- $gtkgreet_bin"

    if [ -f /etc/greetd/config.toml ]; then
        sudo cp -a /etc/greetd/config.toml "/etc/greetd/config.toml.bak-$(date +%Y%m%d-%H%M%S)"
    fi

    sudo tee /etc/greetd/config.toml >/dev/null <<EOF
[terminal]
vt = 7

[default_session]
command = "$greet_cmd"
user = "greeter"
EOF

    local nologin_bin="/usr/bin/nologin"
    [ -x "$nologin_bin" ] || nologin_bin="/bin/false"

    if ! getent group greeter >/dev/null 2>&1; then
        sudo groupadd --system greeter || true
    fi

    if ! getent passwd greeter >/dev/null 2>&1; then
        sudo useradd --system --gid greeter --home-dir /var/lib/greetd --shell "$nologin_bin" greeter || true
    fi

    sudo chown -R greeter:greeter /var/lib/greetd || true

    local g
    for g in seat seatd video; do
        if getent group "$g" >/dev/null 2>&1; then
            sudo usermod -aG "$g" greeter || true
        fi
    done

    if [ ! -f /etc/pam.d/greetd ]; then
        sudo tee /etc/pam.d/greetd >/dev/null <<'EOF'
auth include system-login
account include system-login
password include system-login
session include system-login
EOF
    fi

    local sv
    sv=$(find_service greetd || true)

    if [ -z "$sv" ]; then
        sudo mkdir -p /etc/runit/sv/greetd
        sudo tee /etc/runit/sv/greetd/run >/dev/null <<EOF
#!/bin/sh
exec $greetd_bin --config /etc/greetd/config.toml
EOF
        sudo chmod +x /etc/runit/sv/greetd/run
        sv="greetd"
    fi

    enable_service "$sv" || die "Impossible d'activer greetd."

    ok "greetd activé."
}

setup_cron() {
    step "TRIM hebdomadaire"

    local cron_sv
    cron_sv=$(find_service cronie || find_service cron || true)

    if [ -z "$cron_sv" ] && command -v crond >/dev/null 2>&1; then
        sudo mkdir -p /etc/runit/sv/cronie
        sudo tee /etc/runit/sv/cronie/run >/dev/null <<EOF
#!/bin/sh
exec $(command -v crond) -f
EOF
        sudo chmod +x /etc/runit/sv/cronie/run
        cron_sv="cronie"
    fi

    if [ -n "$cron_sv" ]; then
        enable_service "$cron_sv" || warn "Impossible d'activer $cron_sv."
    fi

    sudo mkdir -p /etc/cron.weekly
    sudo tee /etc/cron.weekly/fstrim >/dev/null <<'EOF'
#!/bin/sh
/usr/bin/fstrim -av
EOF
    sudo chmod +x /etc/cron.weekly/fstrim

    ok "TRIM configuré."
}

finish() {
    step "Terminé"

    cat <<EOF
Installation post-install terminée.

Au reboot :
1. rEFInd lance l'UKI Artix.
2. greetd/gtkgreet démarre via cage.
3. Choisis la session Xfce (Wayfire).

Firewalld : zone par défaut = public
I/O : SSD/NVMe/eMMC = mq-deadline, HDD = bfq

Journal : $LOG_FILE
EOF

    if [ "$NO_REBOOT" -eq 1 ]; then
        ok "Redémarrage désactivé."
        return 0
    fi

    if confirm_yn "Redémarrer maintenant ?" o; then
        sync
        info "Redémarrage dans 5 secondes…"
        sleep 5
        sudo reboot
    fi
}

install_all() {
    preflight
    start_logging
    remove_unwanted
    update_system
    install_base_deps
    install_paru
    install_auris
    setup_io_scheduler
    setup_firewalld
    install_nvidia
    ensure_uki_helper
    configure_initramfs_and_uki
    install_desktop
    write_session_files
    write_user_config
    configure_privileges
    setup_greetd
    setup_cron
    finish
}

#-------------------------------------------------------------------------------
# Checks simples
#-------------------------------------------------------------------------------
CHK_OK=0
CHK_WARN=0

chk() {
    local label=$1
    shift

    if "$@" >/dev/null 2>&1; then
        CHK_OK=$((CHK_OK + 1))
        printf '  %s✔%s %s\n' "$C_GRN" "$C_RST" "$label"
    else
        CHK_WARN=$((CHK_WARN + 1))
        printf '  %s✘%s %s\n' "$C_RED" "$C_RST" "$label"
    fi
}

chk_soft() {
    local label=$1
    shift

    if "$@" >/dev/null 2>&1; then
        CHK_OK=$((CHK_OK + 1))
        printf '  %s✔%s %s\n' "$C_GRN" "$C_RST" "$label"
    else
        printf '  %s~%s %s (avertissement)\n' "$C_YEL" "$C_RST" "$label"
    fi
}

c_pkg()      { pacman -Q "$1"; }
c_file()     { [ -f "$1" ]; }
c_exec()     { [ -x "$1" ]; }
c_linked()   { [ -L "/etc/runit/runsvdir/default/$1" ]; }
c_absent()   { [ ! -e "/etc/runit/runsvdir/default/$1" ]; }
c_paru()     { command -v paru; }
c_no_elogind() { ! pacman -Q | grep -Eiq 'elogind|libelogind'; }
c_modeset()  { [ "$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null)" = "Y" ]; }
c_fbdev()    { [ "$(cat /sys/module/nvidia_drm/parameters/fbdev 2>/dev/null)" = "Y" ]; }

run_checks() {
    initialize_environment

    step "Vérifications"

    chk "paru installé" c_paru
    chk "firewalld installé" c_pkg firewalld
    chk "firewalld activé" c_linked firewalld
    chk "greetd installé" c_pkg greetd
    chk "gtkgreet installé" c_pkg gtkgreet
    chk "cage installé" c_pkg cage
    chk "wayfire installé" c_pkg wayfire
    chk "xfce4-session installé" c_pkg xfce4-session
    chk "xorg-xwayland installé" c_pkg xorg-xwayland

    chk "UKI présent" c_file /boot/efi/EFI/Linux/artix-linux-zen.efi
    chk "greetd activé" c_linked greetd
    chk "seatd activé" c_linked seatd
    chk "ly absent" c_absent ly
    chk "sddm absent" c_absent sddm
    chk "elogind absent" c_no_elogind

    chk "règle udev I/O présente" c_file /etc/udev/rules.d/60-ioscheduler.rules
    chk_soft "chargement bfq configuré" c_file /etc/modules-load.d/bfq.conf

    if [ "$NVIDIA" -eq 1 ]; then
        chk_soft "nvidia_drm modeset = Y" c_modeset
        chk_soft "nvidia_drm fbdev = Y" c_fbdev
    fi

    printf '\n%s contrôles réussis, %s avertissements/échecs\n' "$CHK_OK" "$CHK_WARN"

    exit 0
}

case "$MODE" in
    install) install_all ;;
    check) run_checks ;;
    *) usage; exit 1 ;;
esac
