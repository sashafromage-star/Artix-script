#!/usr/bin/env bash
#===============================================================================
#  clean-desktop-stack.sh
#  Retire uniquement le stack "bureau" : X11/XWayland, XFCE, Wayfire,
#  écran de connexion ly, portails, configs associées.
#
#  PRÉSERVE intégralement :
#    - pilote NVIDIA, noyau, mkinitcpio, rEFInd, blacklist-nouveau
#    - dbus, seatd, connmand, ntpd, cronie, TRIM
#    - **PipeWire / WirePlumber / pavucontrol et toutes leurs configs**
#
#  Options :
#    --remove-fonts     retire noto-fonts, noto-fonts-emoji, ttf-liberation
#    --remove-browser   retire firefox et firefox-i18n-fr
#    --remove-xdg       retire xdg-user-dirs/xdg-utils
#    --remove-ntfs      retire ntfs-3g/exfatprogs
#    --purge-xdg-dirs   supprime ~/Images, ~/Documents… (créés par xdg-user-dirs)
#===============================================================================
set -Eeuo pipefail

LOG="$HOME/clean-desktop-stack.log"
C_RED=$'\e[1;31m'; C_GRN=$'\e[1;32m'; C_YEL=$'\e[1;33m'; C_BLU=$'\e[1;34m'; C_RST=$'\e[0m'
info() { printf '%s[ .. ]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[ !! ]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step() { printf '\n%s=== %s ===%s\n' "$C_BLU" "$*" "$C_RST"; }

RM_FONTS=0; RM_BROWSER=0; RM_XDG=0; RM_NTFS=0; RM_XDG_DIRS=0
for a in "$@"; do case "$a" in
    --remove-fonts)    RM_FONTS=1 ;;
    --remove-browser)  RM_BROWSER=1 ;;
    --remove-xdg)      RM_XDG=1 ;;
    --remove-ntfs)     RM_NTFS=1 ;;
    --purge-xdg-dirs)  RM_XDG_DIRS=1 ;;
    --remove-pipewire)
        die "L'option --remove-pipewire a été retirée : PipeWire et l'audio ne font pas partie du stack bureau et sont volontairement préservés." ;;
    -h|--help)
        sed -n 's/^#    //p' "$0"; exit 0 ;;
    *) die "Option inconnue : $a" ;;
esac; done

[ "$EUID" -ne 0 ] || die "À lancer avec ton utilisateur (sudo est utilisé)."
[ -f /etc/artix-release ] || die "Ce n'est pas un système Artix."
[ -d /etc/runit/runsvdir/default ] || die "runit introuvable."

exec > >(tee -a "$LOG") 2>&1
info "Journal : $LOG"

sudo -v || die "sudo échoue (utilisateur pas dans wheel ?)."
( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit 0; done ) &
KEEPALIVE=$!
trap 'kill "$KEEPALIVE" 2>/dev/null || true' EXIT

find_service() {
    [ -d "/etc/runit/sv/$1" ] && { printf '%s' "$1"; return; }
    find /etc/runit/sv -maxdepth 1 -name "$1*" -printf '%f\n' 2>/dev/null | sort | head -n1
}

#-------------------------------------------------------------------------------
step "1. Écran de connexion : désactivation de ly, restauration d'agetty-tty2"

ly_sv=$(find_service ly || true)
if [ -n "$ly_sv" ] && [ -L "/etc/runit/runsvdir/default/$ly_sv" ]; then
    sudo rm -f "/etc/runit/runsvdir/default/$ly_sv"
    ok "service $ly_sv désactivé"
else
    ok "service ly non actif"
fi

if [ ! -e /etc/runit/runsvdir/default/agetty-tty2 ]; then
    if [ -d /etc/runit/sv/agetty-tty2 ]; then
        sudo ln -sfn /etc/runit/sv/agetty-tty2 /etc/runit/runsvdir/default/agetty-tty2
        ok "agetty-tty2 restauré sur tty2"
    else
        warn "service agetty-tty2 introuvable dans /etc/runit/sv"
    fi
else
    ok "agetty-tty2 déjà en place"
fi

#-------------------------------------------------------------------------------
step "2. /etc/pam.d/ly : retrait de la ligne pam_rundir ajoutée par le script"

if [ -f /etc/pam.d/ly ]; then
    if grep -qE '^session[[:space:]]+optional[[:space:]]+pam_rundir\.so' /etc/pam.d/ly; then
        sudo cp -a /etc/pam.d/ly "/etc/pam.d/ly.bak-clean-$(date +%Y%m%d-%H%M%S)"
        sudo sed -i -E '/^session[[:space:]]+optional[[:space:]]+pam_rundir\.so/d' /etc/pam.d/ly
        ok "ligne pam_rundir retirée de /etc/pam.d/ly"
    else
        ok "aucune ligne pam_rundir à retirer"
    fi
fi

#-------------------------------------------------------------------------------
step "3. Fichiers système créés par le script"

n=0
for f in \
    /usr/local/bin/start-xfce-wayfire \
    /usr/local/bin/screenshot \
    /usr/share/wayland-sessions/xfce-wayfire.desktop
do
    if [ -e "$f" ]; then sudo rm -f "$f"; ok "supprimé : $f"; n=1; fi
done
[ "$n" -eq 0 ] && ok "aucun fichier système à supprimer"

#-------------------------------------------------------------------------------
step "4. Configs utilisateur du bureau (PipeWire NON touché)"

for f in \
    "$HOME/.config/wayfire.ini" \
    "$HOME/.config/wayfire.ini.bak" \
    "$HOME/.config/swaylock/config"
do
    [ -e "$f" ] && rm -f "$f" && ok "supprimé : $f"
done
find "$HOME/.config" -maxdepth 1 -name 'wayfire.ini.bak-*' -delete 2>/dev/null || true
rmdir "$HOME/.config/swaylock" 2>/dev/null || true

# Confirmation explicite : on ne touche pas aux configs audio
for d in "$HOME/.config/pipewire" "$HOME/.config/wireplumber" "$HOME/.local/state/wireplumber"; do
    [ -e "$d" ] && ok "préservé : $d"
done
[ -f "$HOME/.config/pavucontrol.ini" ] && ok "préservé : ~/.config/pavucontrol.ini"

if [ -d "$HOME/.config/xfce4" ]; then
    warn "~/.config/xfce4/ conservé. Pour le retirer : rm -rf ~/.config/xfce4"
fi

#-------------------------------------------------------------------------------
step "5. /etc/pacman.conf : retrait de la ligne NoExtract du script"

if grep -q '^NoExtract.*xfce-wayland' /etc/pacman.conf; then
    sudo cp -a /etc/pacman.conf "/etc/pacman.conf.bak-clean-$(date +%Y%m%d-%H%M%S)"
    sudo sed -i '/^NoExtract.*xfce-wayland/d' /etc/pacman.conf
    ok "ligne NoExtract retirée"
else
    ok "aucune ligne NoExtract à retirer"
fi

#-------------------------------------------------------------------------------
step "6. Règles sudo / polkit ajoutées par le script (bureau)"

for f in /etc/sudoers.d/20-shutdown /etc/polkit-1/rules.d/50-udisks-wheel.rules; do
    [ -e "$f" ] && sudo rm -f "$f" && ok "supprimé : $f"
done

#-------------------------------------------------------------------------------
step "7. Paquets du stack bureau"

# Cœur du stack : TOUJOURS retiré. PipeWire/WirePlumber/pavucontrol ABSENTS.
to_remove=(
    # Écran de connexion
    ly ly-runit
    # XFCE
    xfce4-session xfce4-panel xfdesktop xfce4-settings thunar thunar-volman tumbler
    xfce4-appfinder xfce4-terminal xfce4-notifyd
    # Wayfire + wcm
    wayfire wcm
    # Outils Wayland
    xorg-xwayland swaylock swayidle grim slurp wl-clipboard wlr-randr
    # Portails, polkit, disques
    xdg-desktop-portal-gtk polkit-gnome gvfs udisks2 qt6-wayland
)

[ "$RM_FONTS"   -eq 1 ] && to_remove+=( noto-fonts noto-fonts-emoji ttf-liberation )
[ "$RM_BROWSER" -eq 1 ] && to_remove+=( firefox firefox-i18n-fr )
[ "$RM_XDG"     -eq 1 ] && to_remove+=( xdg-user-dirs xdg-utils )
[ "$RM_NTFS"    -eq 1 ] && to_remove+=( ntfs-3g exfatprogs )

installed=()
for p in "${to_remove[@]}"; do
    pacman -Q "$p" >/dev/null 2>&1 && installed+=("$p")
done

if [ "${#installed[@]}" -eq 0 ]; then
    ok "aucun paquet du stack bureau installé"
else
    info "Retrait de ${#installed[@]} paquet(s) :"
    printf '    %s\n' "${installed[@]}"
    if ! sudo pacman -Rns --noconfirm "${installed[@]}"; then
        warn "certains paquets ont résisté (dépendances partagées) — retentative un par un…"
        for p in "${installed[@]}"; do
            sudo pacman -Rns --noconfirm "$p" 2>/dev/null \
                && ok "retiré : $p" || warn "non retiré : $p"
        done
    fi
fi

# Vérification que PipeWire est toujours là
printf '\n'
for p in pipewire pipewire-pulse pipewire-alsa wireplumber; do
    if pacman -Q "$p" >/dev/null 2>&1; then
        ok "audio préservé : $p ($(pacman -Q "$p"))"
    else
        warn "audio : $p n'était pas installé (rien à préserver)"
    fi
done

#-------------------------------------------------------------------------------
step "8. Orphelins"

or=$(pacman -Qdtq 2>/dev/null || true)
if [ -n "$or" ]; then
    info "Orphelins : $(printf '%s ' $or)"
    sudo pacman -Rns --noconfirm $or || warn "certains orphelins ont résisté"
else
    ok "aucun orphelin"
fi

#-------------------------------------------------------------------------------
if [ "$RM_XDG_DIRS" -eq 1 ]; then
    step "9. Dossiers XDG utilisateur"
    for d in Images Documents Téléchargements Musique Vidéos Public Modèles; do
        [ -d "$HOME/$d" ] && rmdir "$HOME/$d" 2>/dev/null && ok "retiré : ~/$d" || true
    done
    [ -f "$HOME/.config/user-dirs.dirs" ] && rm -f "$HOME/.config/user-dirs.dirs"
fi

#-------------------------------------------------------------------------------
step "Terminé"

cat <<EOF

État actuel : base TTY propre.
  ✔ ly désactivé, agetty-tty2 restauré (tty1..tty6 accessibles)
  ✔ Paquets XFCE / Wayfire / Wayland / XWayland / ly retirés
  ✔ Configs utilisateur wayfire / swaylock supprimées
  ✔ NoExtract, sudoers, polkit rule du script retirés

Préservés volontairement :
  ✔ nvidia-open-dkms, nvidia-utils, linux-zen, linux-zen-headers
  ✔ /etc/modprobe.d/blacklist-nouveau.conf, mkinitcpio (nvidia_drm, microcode)
  ✔ Entrée rEFInd
  ✔ dbus, seatd, connmand, ntpd (services)
  ✔ cronie + /etc/cron.weekly/fstrim
  ✔ **PipeWire / WirePlumber / pavucontrol et leurs configs**
  ✔ nvidia-open-dkms, linux-zen, headers, mkinitcpio

Journal : $LOG

Redémarre pour revenir à tty1 propre :
  sudo reboot
EOF