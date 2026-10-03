#!/usr/bin/env bash
#===============================================================================
#  install-artix-post.sh : Configuration d'Artix après le premier redémarrage
#
#  Couvre : parties 3 à 8 du guide
#           pilote NVIDIA, Xfce sur Wayland + Wayfire, audio PipeWire, ly,
#           règles sudo/polkit, TRIM hebdomadaire
#
#  Usage  : connecté en console (tty1) avec ton UTILISATEUR (pas root) :
#             bash install-artix-post.sh            installation complète
#             bash install-artix-post.sh --check    vérifications (à relancer
#                                                   depuis la session Xfce)
#
#  Le script est relançable : chaque étape vérifie avant d'agir.
#===============================================================================

set -Eeuo pipefail

#-------------------------------------------------------------------------------
# Configuration (modifiable)
#-------------------------------------------------------------------------------
LOG_FILE="$HOME/install-artix-post.log"
SESSION_NAME="xfce-wayfire"

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
    printf 'Tu peux relancer le script : les étapes déjà faites sont revérifiées sans dégât.\n' >&2
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

SUDO_KEEPALIVE_PID=""
cleanup() {
    if [ -n "$SUDO_KEEPALIVE_PID" ]; then kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

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

confirm_yn() { # confirm_yn <question> <o|n : défaut>
    local q=$1 def=${2:-n} a hint="o/N"
    [ "$def" = "o" ] && hint="O/n"
    while true; do
        printf '%s [%s] : ' "$q" "$hint" >/dev/tty
        IFS= read -r a </dev/tty || a=""
        a=${a:-$def}
        case "${a,,}" in
            o|oui|y|yes) return 0 ;;
            n|non|no)    return 1 ;;
        esac
    done
}

backup_if_exists() { # backup_if_exists <fichier> : copie datée, une fois par fichier et par seconde
    if [ -f "$1" ]; then
        cp -a "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)"
    fi
}

# Installe un fichier sudoers uniquement s'il est valide (un fichier invalide casserait sudo)
install_sudoers() { # install_sudoers <nom> <contenu>
    local name=$1 content=$2 tmp
    tmp=$(mktemp)
    printf '%s\n' "$content" >"$tmp"
    if sudo visudo -cf "$tmp" >/dev/null; then
        sudo install -m 440 -o root -g root "$tmp" "/etc/sudoers.d/$name"
        rm -f "$tmp"
    else
        rm -f "$tmp"
        die "Règle sudoers invalide, non installée : $content"
    fi
}

pkg_available() { pacman -Si "$1" >/dev/null 2>&1; }

find_service() { # find_service <préfixe> : nom du service runit (exact en priorité)
    if [ -d "/etc/runit/sv/$1" ]; then printf '%s' "$1"; return 0; fi
    local f
    f=$(find /etc/runit/sv -maxdepth 1 -name "$1*" -printf '%f\n' 2>/dev/null | sort | head -n1 || true)
    printf '%s' "$f"
}

enable_service() { # enable_service <nom>
    sudo ln -sfn "/etc/runit/sv/$1" "/etc/runit/runsvdir/default/$1"
}

usage() {
    cat <<'EOF'
Usage : bash install-artix-post.sh [--check]

  (sans option)  Installation complète : NVIDIA, Xfce + Wayfire, PipeWire, ly,
                 règles sudo/polkit, TRIM hebdomadaire. Termine en proposant
                 d'activer ly et de redémarrer.
  --check        Vérifie l'installation (relance-le depuis un terminal de la
                 session Xfce pour les tests complets).

À lancer avec ton utilisateur (pas root), depuis la console tty1.
EOF
}

#===============================================================================
# Vérifications (partagées entre l'installation et --check)
#===============================================================================
CHK_OK=0
CHK_FAIL=0
chk() { # chk <libellé> <commande...>
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then
        CHK_OK=$((CHK_OK + 1))
        printf '  %s✔%s %s\n' "$C_GRN" "$C_RST" "$label"
    else
        CHK_FAIL=$((CHK_FAIL + 1))
        printf '  %s✘%s %s\n' "$C_RED" "$C_RST" "$label"
    fi
}

chk_soft() { # contrôle non bloquant (avertissement seulement)
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then
        CHK_OK=$((CHK_OK + 1))
        printf '  %s✔%s %s\n' "$C_GRN" "$C_RST" "$label"
    else
        printf '  %s~%s %s (avertissement, non bloquant)\n' "$C_YEL" "$C_RST" "$label"
    fi
}

c_pkg()     { pacman -Q "$1"; }
c_file()    { [ -f "$1" ]; }
c_exec()    { [ -x "$1" ]; }
c_linked()  { [ -L "/etc/runit/runsvdir/default/$1" ]; }
c_absent()  { [ ! -e "/etc/runit/runsvdir/default/$1" ]; }
c_modeset() { [ "$(cat /sys/module/nvidia_drm/parameters/modeset)" = "Y" ]; }
c_fbdev()   { [ "$(cat /sys/module/nvidia_drm/parameters/fbdev)" = "Y" ]; }
c_nonouveau() { local m; m=$(lsmod); ! grep -q '^nouveau' <<<"$m"; }
c_noxserver() { local p; p=$(pacman -Qq); ! grep -qE '^(xorg-server|xlibre-xserver|xf86-)' <<<"$p"; }
c_inseat()  { local g; g=$(id -nG); grep -qw seat <<<"$g"; }
c_online()  { local s; s=$(connmanctl state); grep -qE 'State = (online|ready)' <<<"$s"; }
c_ucode()   { pacman -Q intel-ucode >/dev/null 2>&1 || pacman -Q amd-ucode >/dev/null 2>&1; }
c_hook_ucode() { grep -Eq '^HOOKS=.*\<microcode\>' /etc/mkinitcpio.conf || grep -Rqs 'microcode' /etc/mkinitcpio.conf.d/; }
c_initramfs_nvidia() { local l; l=$(sudo lsinitcpio /boot/initramfs-linux-zen.img); grep -q 'nvidia_drm' <<<"$l"; }
c_wayland() { [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; }
c_runtime() { [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR:-}" ]; }
c_swayidle() { pgrep -x swayidle; }
c_seatsock() { [ -S /run/seatd.sock ]; }
c_pipewire() { wpctl status; }
c_menuentry() { sudo grep -qs 'menuentry "Artix Linux' /boot/efi/EFI/refind/refind.conf /boot/efi/EFI/BOOT/refind.conf; }

# Vérifications qui ne demandent pas de session graphique
static_checks() {
    printf '%sPaquets%s\n' "$C_BLU" "$C_RST"
    local p
    for p in linux-zen-headers nvidia-open-dkms nvidia-utils xfce4-session xfce4-panel xfdesktop wayfire \
             xorg-xwayland swaylock swayidle pipewire wireplumber ly ly-runit cronie; do
        chk "$p installé" c_pkg "$p"
    done
    chk_soft "microcode installé (intel-ucode ou amd-ucode)" c_ucode
    chk "hook mkinitcpio « microcode » présent" c_hook_ucode
    chk "initramfs-linux-zen contient nvidia_drm" c_initramfs_nvidia

    printf '%sFichiers de session%s\n' "$C_BLU" "$C_RST"
    chk "/usr/local/bin/start-xfce-wayfire exécutable" c_exec /usr/local/bin/start-xfce-wayfire
    chk "/usr/local/bin/screenshot exécutable" c_exec /usr/local/bin/screenshot
    chk "session Wayland « Xfce (Wayfire) » pour ly" c_file "/usr/share/wayland-sessions/$SESSION_NAME.desktop"
    chk "fichier de configuration wayfire.ini" c_file "$HOME/.config/wayfire.ini"
    chk "fichier de configuration swaylock" c_file "$HOME/.config/swaylock/config"
    chk "blacklist nouveau" c_file /etc/modprobe.d/blacklist-nouveau.conf
    chk "règle polkit udisks (wheel)" c_file /etc/polkit-1/rules.d/50-udisks-wheel.rules
    chk "TRIM hebdomadaire (cron.weekly/fstrim)" c_exec /etc/cron.weekly/fstrim
    chk "entrée rEFInd « Artix Linux » dans refind.conf" c_menuentry

    printf '%sServices runit%s\n' "$C_BLU" "$C_RST"
    local s cron_sv
    for s in dbus seatd connmand ntpd; do
        chk "service $s activé" c_linked "$s"
    done
    cron_sv=$(find_service cronie)
    chk "service cron (${cron_sv:-introuvable}) activé" c_linked "${cron_sv:-cronie}"
    chk "aucun X natif installé (xorg-server, xf86-*)" c_noxserver
}

#===============================================================================
# INSTALLATION
#===============================================================================
preflight() {
    step "Vérifications préalables"

    [ "$EUID" -ne 0 ] || die "Lance ce script avec ton utilisateur, pas en root (il utilise sudo quand il faut)."
    [ -f /etc/artix-release ] || die "Ce n'est pas un système Artix."
    [ -d /etc/runit/runsvdir/default ] || die "runit introuvable : ce script est prévu pour Artix runit."

    case "$(tty 2>/dev/null || true)" in
        /dev/tty2) die "Lance le script depuis tty1 (Ctrl+Alt+F1) : tty2 sera repris par ly." ;;
    esac

    local groups_now
    groups_now=$(id -nG)
    if ! grep -qw seat <<<"$groups_now"; then
        die "Ton utilisateur n'est pas dans le groupe seat (le script d'installation de base devait l'ajouter)."
    fi

    info "Mot de passe sudo demandé une seule fois (maintenu pendant le script)."
    sudo -v || die "sudo ne fonctionne pas pour $USER (membre de wheel ?)."
    ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit 0; done ) >/dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!

    ping -c 2 -W 3 artixlinux.org >/dev/null 2>&1 \
        || die "Pas de connexion Internet. Vérifie ConnMan : connmanctl state"

    pacman -Q linux-zen-headers >/dev/null 2>&1 || die "linux-zen-headers absent (nécessaire à DKMS)."
    case "$(uname -r)" in
        *zen*) ;;
        *) warn "Le noyau en cours n'est pas linux-zen ($(uname -r)) : sélectionne bien l'entrée Artix dans rEFInd." ;;
    esac

    local has_nvidia=0 v
    for v in /sys/bus/pci/devices/*/vendor; do
        if [ -r "$v" ] && [ "$(cat "$v")" = "0x10de" ]; then has_nvidia=1; break; fi
    done
    if [ "$has_nvidia" -eq 0 ]; then
        warn "Aucune carte NVIDIA détectée sur le bus PCI."
        confirm_yn "Installer quand même le pilote NVIDIA ?" n || die "Arrêt à ta demande."
    fi
    ok "Utilisateur $USER, réseau, noyau et GPU vérifiés"
}

start_logging() {
    : >"$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Journal : $LOG_FILE"
}

update_system() {
    step "3.1 Mise à jour du système"
    retry 3 sudo pacman -Syu --noconfirm
    ok "Système à jour"
}

install_nvidia() {
    step "3.2 Pilote NVIDIA (nvidia-open-dkms)"

    pkg_available nvidia-open-dkms || die "nvidia-open-dkms introuvable dans les dépôts Artix."
    retry 3 sudo pacman -S --needed --noconfirm nvidia-open-dkms nvidia-utils

    local dk
    dk=$(sudo dkms status 2>&1 || true)
    printf '%s\n' "$dk"
    if ! grep -qi 'nvidia.*installed' <<<"$dk"; then
        warn "DKMS n'indique pas le module NVIDIA comme installé : tentative de construction."
        sudo dkms autoinstall || die "La construction DKMS du module NVIDIA a échoué (voir le journal ci-dessus)."
        dk=$(sudo dkms status 2>&1 || true)
        grep -qi 'nvidia.*installed' <<<"$dk" || die "Module NVIDIA non installé après dkms autoinstall."
    fi
    ok "Module NVIDIA construit par DKMS"

    # Blocage de nouveau en plus des paramètres du noyau
    sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    ok "nouveau bloqué (modprobe.d)"
}

prepare_initramfs() {
    step "3.2 Modules NVIDIA dans l'initramfs, hooks kms / microcode"

    local mk=/etc/mkinitcpio.conf
    [ -f "$mk" ] || die "$mk introuvable."
    [ -f "$mk.bak-pre-nvidia" ] || sudo cp -a "$mk" "$mk.bak-pre-nvidia"

    if grep -Eq '^MODULES=\(' "$mk" && grep -Eq '^HOOKS=\(' "$mk"; then
        sudo sed -i -E 's/^MODULES=\(.*\)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' "$mk"
        sudo sed -i -E '/^HOOKS=/ { s/\<kms\>//; s/  +/ /g; s/ \)/)/ }' "$mk"
        if ! grep -Eq '^HOOKS=.*\<microcode\>' "$mk"; then
            sudo sed -i -E '/^HOOKS=/ s/autodetect/autodetect microcode/' "$mk"
        fi

        grep -Eq '^MODULES=\(nvidia nvidia_modeset nvidia_uvm nvidia_drm\)' "$mk" \
            || die "MODULES n'a pas pu être modifié dans $mk : édite-le à la main (voir le guide, étape 3.2)."
        local hooks_line
        hooks_line=$(grep -E '^HOOKS=' "$mk")
        if grep -qw kms <<<"$hooks_line"; then
            die "Le hook kms est toujours présent dans HOOKS de $mk : retire-le à la main."
        fi
        grep -Eq '^HOOKS=.*\<microcode\>' "$mk" \
            || die "Le hook microcode n'a pas pu être ajouté à HOOKS de $mk : ajoute-le après autodetect."
    else
        warn "$mk n'a pas de lignes MODULES/HOOKS actives : utilisation d'un fichier drop-in."
        sudo mkdir -p /etc/mkinitcpio.conf.d
        sudo tee /etc/mkinitcpio.conf.d/10-nvidia.conf >/dev/null <<'EOF'
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
HOOKS=(base udev autodetect microcode modconf keyboard keymap consolefont block filesystems fsck)
EOF
    fi
    grep -E '^(MODULES|HOOKS)=' "$mk" || true
    ok "mkinitcpio prêt"

    step "3.3 Régénération des initramfs"
    local out
    out=$(sudo mkinitcpio -P 2>&1) || { printf '%s\n' "$out"; die "mkinitcpio -P a échoué."; }
    printf '%s\n' "$out"
    if grep -q 'ERROR' <<<"$out"; then
        die "mkinitcpio a signalé des erreurs (voir ci-dessus)."
    fi

    local l
    l=$(sudo lsinitcpio /boot/initramfs-linux-zen.img)
    grep -q 'nvidia_drm' <<<"$l" || die "nvidia_drm absent de l'initramfs linux-zen : le pilote ne sera pas chargé tôt."
    if grep -q 'nouveau' <<<"$l"; then
        warn "nouveau est présent dans l'initramfs (bloqué par les paramètres noyau et modprobe.d)."
    fi
    ok "initramfs régénéré, nvidia_drm inclus"
}

block_default_sessions() {
    step "4.1 Sessions Xfce par défaut bloquées (NoExtract)"
    if ! grep -q '^NoExtract.*xfce-wayland' /etc/pacman.conf; then
        sudo sed -i '/^\[options\]/a NoExtract = usr/share/xsessions/xfce.desktop usr/share/wayland-sessions/xfce-wayland.desktop' /etc/pacman.conf
    fi
    grep -q '^NoExtract.*xfce-wayland' /etc/pacman.conf || die "NoExtract n'a pas pu être ajouté à /etc/pacman.conf."
    ok "xfce.desktop et xfce-wayland.desktop ne seront pas installés"
}

install_packages() {
    step "4.2 Installation des paquets (Xfce, Wayfire, audio, ly, cron…)"

    local required=(
        # Xfce
        xfce4-session xfce4-panel xfdesktop xfce4-settings thunar thunar-volman tumbler
        xfce4-appfinder xfce4-terminal xfce4-notifyd
        # Wayfire et outils Wayland
        wayfire xorg-xwayland swaylock swayidle grim slurp wl-clipboard
        # Audio
        pipewire pipewire-pulse pipewire-alsa wireplumber
        # Système, portails, Qt, disques, navigateur
        gvfs udisks2 polkit-gnome xdg-desktop-portal-gtk qt6-wayland xdg-user-dirs xdg-utils
        noto-fonts firefox
        # Écran de connexion et maintenance
        ly ly-runit cronie cronie-runit
    )
    local optional=(
        wcm wlr-randr pavucontrol ntfs-3g exfatprogs noto-fonts-emoji ttf-liberation firefox-i18n-fr
    )

    local p missing=() to_install=()
    for p in "${required[@]}"; do
        if pkg_available "$p"; then to_install+=("$p"); else missing+=("$p"); fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "Paquets indispensables introuvables dans les dépôts : ${missing[*]}"
    fi
    for p in "${optional[@]}"; do
        if pkg_available "$p"; then
            to_install+=("$p")
        else
            warn "Paquet optionnel introuvable, ignoré : $p"
        fi
    done

    retry 3 sudo pacman -S --needed --noconfirm "${to_install[@]}"

    grep -q -- '--wayland' /usr/bin/startxfce4 \
        || die "Ce startxfce4 ne gère pas --wayland (Xfce 4.20 ou plus requis)."
    command -v wayfire >/dev/null || die "wayfire introuvable après installation."
    [ -x /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 ] \
        || warn "Agent polkit-gnome introuvable à l'emplacement attendu (fenêtres d'authentification indisponibles)."
    ok "Paquets installés"
}

write_session_files() {
    step "4.3 à 4.5 Script de session, entrée ly, captures d'écran"

    sudo tee /usr/local/bin/start-xfce-wayfire >/dev/null <<'EOF'
#!/bin/sh
# Session Xfce sur Wayland avec Wayfire (NVIDIA, seatd, sans logind)

export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=xfce
export XDG_CURRENT_DESKTOP=XFCE

# Filet de sécurité si pam_rundir n'a pas créé XDG_RUNTIME_DIR
if [ -z "$XDG_RUNTIME_DIR" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
fi

# NVIDIA : le curseur matériel peut être invisible ou scintiller avec wlroots.
# Si ton curseur est correct sans cette ligne, tu peux la supprimer.
export WLR_NO_HARDWARE_CURSORS=1

# Nettoyage d'éventuels restes d'une session précédente
pkill -u "$(id -u)" -x pipewire-pulse 2>/dev/null
pkill -u "$(id -u)" -x wireplumber 2>/dev/null
pkill -u "$(id -u)" -x pipewire 2>/dev/null
sleep 0.5

# Bus D-Bus de session + PipeWire + Xfce/Wayfire
exec dbus-run-session -- sh -c '
    /usr/bin/pipewire &
    /usr/bin/pipewire-pulse &
    /usr/bin/wireplumber &
    exec startxfce4 --wayland wayfire
'
EOF
    sudo chmod +x /usr/local/bin/start-xfce-wayfire

    sudo tee "/usr/share/wayland-sessions/$SESSION_NAME.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=Xfce (Wayfire)
Comment=Xfce sur Wayland avec le compositeur Wayfire
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
  full)      grim "$FILE" ;;
  area)      geo=$(slurp) || exit 0; grim -g "$geo" "$FILE" ;;
  clip)      grim - | wl-copy -t image/png ;;
  clip-area) geo=$(slurp) || exit 0; grim -g "$geo" - | wl-copy -t image/png ;;
esac
EOF
    sudo chmod +x /usr/local/bin/screenshot
    ok "Session « Xfce (Wayfire) » et captures d'écran installées"
}

write_user_config() {
    step "4.6 Configuration de Wayfire et de swaylock (dans $HOME)"

    mkdir -p "$HOME/.config/swaylock"
    backup_if_exists "$HOME/.config/swaylock/config"
    cat >"$HOME/.config/swaylock/config" <<'EOF'
daemonize
ignore-empty-password
show-failed-attempts
color=1e1e2e
EOF

    backup_if_exists "$HOME/.config/wayfire.ini"
    cat >"$HOME/.config/wayfire.ini" <<'EOF'
[autostart]
autostart_wf_shell = false
session = xfce4-session
polkit = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
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
    cp -f "$HOME/.config/wayfire.ini" "$HOME/.config/wayfire.ini.bak"

    # Dossiers utilisateur (Images, Documents…) dans la langue du système
    LANG=fr_FR.UTF-8 xdg-user-dirs-update || warn "xdg-user-dirs-update a échoué (à relancer dans la session)."
    ok "wayfire.ini, swaylock et dossiers utilisateur en place (sauvegarde : wayfire.ini.bak)"
}

configure_privileges() {
    step "4.7 Éteindre / redémarrer et montage USB (sans logind)"

    # Éteindre / Redémarrer pour les membres de wheel
    local cmds="" helper c p
    for c in poweroff reboot halt shutdown; do
        p=$(command -v "$c" || true)
        if [ -n "$p" ] && [[ ",$cmds," != *",$p,"* ]]; then cmds="${cmds:+$cmds,}$p"; fi
    done
    if [ -x /usr/lib/xfce4/session/xfsm-shutdown-helper ]; then
        helper=/usr/lib/xfce4/session/xfsm-shutdown-helper
        cmds="${cmds:+$cmds,}$helper"
    fi
    if [ -n "$cmds" ]; then
        install_sudoers 20-shutdown "%wheel ALL=(root) NOPASSWD: $cmds"
        ok "sudo sans mot de passe pour : $cmds"
    else
        warn "Aucune commande d'extinction trouvée : règle sudoers non créée."
    fi

    # Montage des clés USB sans mot de passe (polkit)
    sudo mkdir -p /etc/polkit-1/rules.d
    sudo tee /etc/polkit-1/rules.d/50-udisks-wheel.rules >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel") &&
        action.id.indexOf("org.freedesktop.udisks2.") == 0) {
        return polkit.Result.YES;
    }
});
EOF
    ok "Règle polkit udisks installée"
}

setup_ly_pam() {
    step "5.2 pam_rundir pour ly"
    if [ -f /etc/pam.d/ly ]; then
        if ! grep -qE 'pam_rundir|include +(login|system-login|system-local-login)' /etc/pam.d/ly; then
            echo 'session optional pam_rundir.so' | sudo tee -a /etc/pam.d/ly >/dev/null
            ok "pam_rundir ajouté à /etc/pam.d/ly"
        else
            ok "ly passe déjà par la pile PAM de login (pam_rundir pris en compte)"
        fi
    else
        warn "/etc/pam.d/ly introuvable : vérifie après installation de ly."
    fi
    grep -q pam_rundir /etc/pam.d/system-login || die "pam_rundir absent de /etc/pam.d/system-login."
}

setup_maintenance() {
    step "8.1 TRIM hebdomadaire (cronie + anacron)"
    local cron_sv
    cron_sv=$(find_service cronie)
    if [ -z "$cron_sv" ]; then
        cron_sv=$(find_service cron)
    fi
    [ -n "$cron_sv" ] || die "Service cron introuvable dans /etc/runit/sv (cronie-runit installé ?)."
    enable_service "$cron_sv"

    sudo tee /etc/cron.weekly/fstrim >/dev/null <<'EOF'
#!/bin/sh
/usr/bin/fstrim -av
EOF
    sudo chmod +x /etc/cron.weekly/fstrim
    ok "Service $cron_sv activé, TRIM hebdomadaire programmé"
}

enable_ly() {
    local ly_sv
    ly_sv=$(find_service ly)
    [ -n "$ly_sv" ] || die "Service ly introuvable dans /etc/runit/sv (ly-runit installé ?)."
    sudo rm -f /etc/runit/runsvdir/default/agetty-tty2
    enable_service "$ly_sv"
    [ -L "/etc/runit/runsvdir/default/$ly_sv" ] || die "Le lien du service ly n'a pas été créé."
    [ ! -e /etc/runit/runsvdir/default/agetty-tty2 ] || die "agetty-tty2 n'a pas pu être retiré."
    ok "ly ($ly_sv) activé sur tty2, agetty-tty2 retiré"
}

finish() {
    step "Vérification statique"
    CHK_OK=0; CHK_FAIL=0
    static_checks
    printf '\n  %s contrôles réussis, %s échoués\n' "$CHK_OK" "$CHK_FAIL"
    if [ "$CHK_FAIL" -gt 0 ]; then
        die "Des contrôles ont échoué : corrige-les avant d'activer ly (ou envoie-moi la liste)."
    fi

    step "Terminé"
    cat <<EOF

Tout est installé et configuré.

  Il reste à activer ly (écran de connexion) puis à redémarrer.
  Au redémarrage :
    1. Dans le menu rEFInd, choisis "Artix Linux (linux-zen)".
    2. Sur ly, choisis la session « Xfce (Wayfire) » (flèches gauche/droite).
    3. Une fois dans la session, ouvre un terminal et lance :
         bash install-artix-post.sh --check

  Journal : $LOG_FILE
EOF
    sleep 1
    if confirm_yn "Activer ly et redémarrer maintenant ?" o; then
        step "Activation de ly"
        enable_ly
        sync
        info "Redémarrage dans 5 secondes (Ctrl+C pour annuler)…"
        sleep 5
        sudo reboot
    else
        cat <<'EOF'

ly n'est PAS encore activé. Quand tu es prêt (depuis tty1) :

  sudo rm -f /etc/runit/runsvdir/default/agetty-tty2
  sudo ln -sfn /etc/runit/sv/ly /etc/runit/runsvdir/default/ly
  sudo reboot

(Si le service ne s'appelle pas « ly » : ls /etc/runit/sv | grep -i '^ly')
EOF
    fi
}

install_all() {
    preflight
    start_logging
    update_system
    install_nvidia
    prepare_initramfs
    block_default_sessions
    install_packages
    write_session_files
    write_user_config
    configure_privileges
    setup_ly_pam
    setup_maintenance
    finish
}

#===============================================================================
# --check : vérifications complètes
#===============================================================================
run_checks() {
    CHK_OK=0; CHK_FAIL=0
    printf '%sVérification de l'"'"'installation%s\n\n' "$C_BLU" "$C_RST"

    static_checks

    printf '%sBoot et pilote NVIDIA%s\n' "$C_BLU" "$C_RST"
    chk "noyau linux-zen en cours d'exécution ($(uname -r))" bash -c "uname -r | grep -q zen"
    chk "nvidia_drm modeset = Y" c_modeset
    chk "nvidia_drm fbdev = Y" c_fbdev
    chk "nouveau non chargé" c_nonouveau
    chk "nvidia-smi répond" nvidia-smi
    chk "ConnMan en ligne" c_online

    printf '%sServices de connexion%s\n' "$C_BLU" "$C_RST"
    local ly_sv
    ly_sv=$(find_service ly)
    chk "service ly (${ly_sv:-introuvable}) activé" c_linked "${ly_sv:-ly}"
    chk "agetty-tty2 retiré" c_absent agetty-tty2
    chk "socket seatd présent" c_seatsock
    chk "utilisateur dans le groupe seat" c_inseat

    if c_wayland; then
        printf '%sSession Wayland en cours%s\n' "$C_BLU" "$C_RST"
        chk "XDG_RUNTIME_DIR défini et existant (${XDG_RUNTIME_DIR:-vide})" c_runtime
        chk "WAYLAND_DISPLAY défini (${WAYLAND_DISPLAY:-vide})" test -n "${WAYLAND_DISPLAY:-}"
        chk "PipeWire / WirePlumber actifs" c_pipewire
        chk "swayidle actif" c_swayidle
    else
        printf '\n%s(i) Pas de session Wayland détectée : les tests de session (XDG_RUNTIME_DIR, PipeWire,%s\n' "$C_YEL" "$C_RST"
        printf '%s    swayidle) seront faits en relançant --check depuis la session Xfce.%s\n' "$C_YEL" "$C_RST"
    fi

    printf '\n  %s contrôles réussis, %s échoués\n' "$CHK_OK" "$CHK_FAIL"
    if [ "$CHK_FAIL" -eq 0 ]; then exit 0; else exit 1; fi
}

#===============================================================================
# Point d'entrée
#===============================================================================
case "${1:-}" in
    "")        install_all ;;
    --check)   run_checks ;;
    -h|--help) usage ;;
    *)         usage; exit 1 ;;
esac