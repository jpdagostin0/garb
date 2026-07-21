#!/bin/bash
# Version Info
GARB_VERSION="1"
GARB_CONFIG_VERSION="1"
GARB_CONFIG_LOCATION="config.sh"
GARB_LOGFILE="garb_$(date +%s).log"
GARB_ONLINE="https://raw.githubusercontent.com/jpdagostin0/garb/refs/heads/main/garb.sh"
#GARB_BYPASS_SYSTEMCHECK=1

# Defaults
DEFAULT_BOOTEND=1048576 # ~1GB
DEFAULT_FILESYSTEM="xfs"
DEFAULT_CHECKSITE="gentoo.org"
DEFAULT_NAMESERVER="1.1.1.1"
DEFAULT_MOUNT="/mnt/gentoo"
DEFAULT_PROFILE="desktop-openrc"
DEFAULT_BOOTLOADER="grub"
DEFAULT_HOSTNAME="gentoo"
DEFAULT_KERNEL="gentoo-kernel-bin"
DEFAULT_LOCALE="$LANG UTF-8"

# Variables
GARB_INTERNET=1
GARB_BUILD_CONFIG=0
RESOLV_NAMESERVER="$(grep nameserver /etc/resolv.conf | awk '{print $2}')"

# $1 what to write as info
pinfo() {
    echo "[GARB] [INFO]" "$1"
    echo "[GARB] [INFO]" "$1" >> $GARB_LOGFILE
}

pwarn() {
    echo -e "\033[33m[GARB] [WARN]" "$1" "\033[0m"
    echo "[GARB] [WARN]" "$1" >> $GARB_LOGFILE
}

perror() {
    echo -e "\033[31m[GARB] [ERROR]" "$1" "\033[0m"
    echo "[GARB] [ERROR]" "$1" >> $GARB_LOGFILE
}

nicerr() {
    if [[ $? -ne 0 ]]; then
        perror "$1"
    fi
}

# Checks if the variable exists or prompts
# $1 variable to read
# $2 prompt text
checkp() {
    local -n var="$1"
    if [[ -z "$var" ]]; then
        pwarn "$1 not set... prompting"
        read -p "$2" var
        pinfo "$1 set to $var"
        write_config "$1" "$var"
    fi
}

# Checks if the variable exists or sets default
# $1 variable to read
# $2 default
checks() {
    local -n var="$1"
    if [[ -z "$var" ]]; then
        var="$2"
        export "$1"
        pwarn "$1 not set... using default ($var)"
        write_config "$1" "$var"
    fi
}

# $1 conf location
# $2 variable
# $3 value
set_conf_variable() {
    echo "$2=\"$3\"" >> "$1"
}

# Writes to config (if allowed)
# $1 variable
# $2 value
write_config() {
    if [[ $1 == CONFIG_* ]]; then
        if [[ GARB_BUILD_CONFIG -eq 1 ]]; then
            pinfo "Writing to config..."
            set_conf_variable "$GARB_CONFIG_LOCATION" "$1" "$2"
        fi
    fi
}

# Sets a header for the script
# $1 text
header() {
    BLOCK="#"
    COLUMNS=$(tput cols)
    LEN=$(echo "$1" | wc -c)
    PAD=4
    BLOCKS=$((($COLUMNS - $LEN - $PAD) / 2))
    b=$(printf "%*s" "$BLOCKS" "" | tr ' ' "$BLOCK") 
    printf "%s %s %s\n" "$b" "$1" "$b"; 
}

# Ask the user to run $1, otherwise $2
askab() {
    pinfo "Run $1, otherwise run $2"
    read -r -p "Run $1 [Y/n] " response
    if [[ "$response" =~ ^([nN])$ ]]
    then
        eval "$2"
    else
        eval "$1"
    fi
}

test_net() {
    header "Testing Network"

    # Route check
    DEFAULT_ROUTE=$(ip route | grep default | wc -l)
    if [[ $DEFAULT_ROUTE -eq 0 ]]; then
        echo "No default route configured"
        askab "nmtui" "export GARB_INTERNET=0"
    fi

    # Ping check
    checks RESOLV_NAMESERVER "$DEFAULT_NAMESERVER"
    ping -q -n -c 4 $RESOLV_NAMESERVER
    
    STATUS="$?"
    if [[ $STATUS -ne 0 ]]; then
        perror "Could not ping $RESOLV_NAMESERVER"
        askab "nmtui" "export GARB_INTERNET=0"
    fi

    # Internet check
    curl -fs $DEFAULT_CHECKSITE
    
    STATUS="$?"
    if [[ $STATUS -ne 0 ]]; then
        perror "Could not access $DEFAULT_CHECKSITE"
        askab "nmtui" "export GARB_INTERNET=0"
    fi
}

check_update() {
    header "Checking for GARB Updates"
    CURRENT_VER=$(cat "$0" | sha256sum | awk '{print $1}')
    SCRIPT_DATA=$(curl -fSsL $GARB_ONLINE )
    NEXT_VER=$(echo "$SCRIPT_DATA" | sha256sum | awk '{print $1}')

    if [[ $CURRENT_VER != $NEXT_VER ]]; then
        pinfo "Updates are available!"
        if [[ ! -f "$0" || ! -w "$0" ]]; then
            pwarn "Not running from a writable script file... skipping update"
            return
        fi
        pinfo "Loading updates automatically"
        echo "$SCRIPT_DATA" > "$0.tmp" && mv "$0.tmp" "$0"
        chmod +x "$0"
        exec "$0" "$@"
    fi
}

prepare_disks() {
    DEVICE="/dev/$CONFIG_DISK"
    wipefs -a "$DEVICE"
    sgdisk --zap-all "$DEVICE"

    if [[ $CONFIG_UEFI -eq 1 ]]; then
        parted -s "$DEVICE" mklabel gpt
        parted -s "$DEVICE" mkpart ESP 1MiB "$DEFAULT_BOOTEND"KiB
        parted -s "$DEVICE" set 1 esp on
    else
        parted -s "$DEVICE" mklabel msdos
        parted -s "$DEVICE" mkpart primary 1MiB "$DEFAULT_BOOTEND"KiB
    fi
    
    EOSWAP=$((DEFAULT_BOOTEND + CONFIG_SWAPSIZE))

    parted -s "$DEVICE" mkpart primary linux-swap "$DEFAULT_BOOTEND"KiB "$EOSWAP"KiB
    parted -s "$DEVICE" mkpart primary "$EOSWAP"KiB 100%
    partprobe "$DEVICE"
    udevadm settle
    
    PART1="${DEVICE}1"
    PART2="${DEVICE}2"
    PART3="${DEVICE}3"

    if [[ $DEVICE == /dev/nvme* ]]; then
        PART1="${DEVICE}p1"
        PART2="${DEVICE}p2"
        PART3="${DEVICE}p3"
    fi

    if [[ $DEVICE == /dev/mmcblk* ]]; then
        PART1="${DEVICE}p1"
        PART2="${DEVICE}p2"
        PART3="${DEVICE}p3"
    fi

    case $CONFIG_FILESYSTEM in
        ext4) MKFS="mkfs.ext4 -F" ;;
        xfs) MKFS="mkfs.xfs -f" ;;
        btrfs) MKFS="mkfs.btrfs -f" ;;
    esac

    $MKFS "$PART3"
    mkswap "$PART2"

    if [[ $CONFIG_UEFI -eq 1 ]]; then
        mkfs.fat -F 32 "$PART1"
    else
        $MKFS "$PART1"
    fi

    mount_disks "$PART1" "$PART2" "$PART3"
}

# $1 bios, $2 swap, $3 primary
mount_disks() {
    swapon "$2"

    if [[ $CONFIG_UEFI -eq 1 ]]; then
        mkdir -p "$CONFIG_MOUNT"
        mount "$3" "$CONFIG_MOUNT"
        mkdir -p "$CONFIG_MOUNT/efi"
        mount "$1" "$CONFIG_MOUNT/efi"
    else
        mkdir -p "$CONFIG_MOUNT"
        mount "$3" "$CONFIG_MOUNT"
        mkdir -p "$CONFIG_MOUNT/boot"
        mount "$1" "$CONFIG_MOUNT/boot"
    fi
}

setup_makeconf() {
    header "Setting up portage/make.conf"
    MAKECONF=$CONFIG_MOUNT/etc/portage/make.conf

    rm $MAKECONF

    set_conf_variable "$MAKECONF" "COMMON_FLAGS" "$CONFIG_COMMON_FLAGS"
    set_conf_variable "$MAKECONF" "CFLAGS" "$CONFIG_CFLAGS"
    set_conf_variable "$MAKECONF" "CXXFLAGS" "$CONFIG_CXXFLAGS"
    set_conf_variable "$MAKECONF" "RUSTFLAGS" "$CONFIG_RUSTFLAGS"
    set_conf_variable "$MAKECONF" "ACCEPT_LICENSE" "$CONFIG_LICENSES"

    set_conf_variable "$MAKECONF" "MAKEOPTS" "-j$CONFIG_JOBS -l$((CONFIG_JOBS + 1))"
}

setup_stagefile() {
    header "Stage 3 Setup"
    if hash chronyc 2>/dev/null; then
        chronyc -a makestep > /dev/null 2>&1
    fi

    pinfo "Getting latest release information"
    S3LATEST=$(curl -fsSL "https://distfiles.gentoo.org/releases/$CONFIG_ARCH/autobuilds/latest-stage3-$CONFIG_ARCH-$CONFIG_PROFILE.txt" | awk '!/^(#|-|H)/ && NF {print $1; exit}')
    S3DL="https://distfiles-cdn-origin.gentoo.org/releases/$CONFIG_ARCH/autobuilds/$S3LATEST"

    pinfo "Pulling tarball and metadata"
    curl -fsSL "$S3DL" -o stage3.tar.xz
    nicerr "Failed to download tarball"
    curl -fsSL "$S3DL.DIGESTS" -o stage3.tar.xz.DIGESTS
    nicerr "Failed to download DIGESTS"
    curl -fsSL "$S3DL.DIGESTS.asc" -o stage3.tar.xz.DIGESTS.asc
    nicerr "Failed to download DIGESTS.asc"

    if [[ -f /usr/share/openpgp-keys/gentoo-release.asc ]]; then
        if ! gpg --import /usr/share/openpgp-keys/gentoo-release.asc; then
            pwarn "Failed to import Gentoo release key!"
        fi

        if ! gpg --verify stage3.tar.xz.DIGESTS.asc stage3.tar.xz.DIGESTS; then
            pwarn "Stage3 DIGESTS signature verification failed!"
        fi
    else
        pwarn "Gentoo release key not found... skipping GPG verification"
    fi

    EXPECTED_SHA=$(awk '/^[0-9a-f]{64}[[:space:]]+/ && /tar\.xz$/ {print $1; exit}' stage3.tar.xz.DIGESTS)
    ACTUAL_SHA=$(sha256sum stage3.tar.xz | awk '{print $1}')
    if [[ -z "$EXPECTED_SHA" || "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
        pwarn "Stage3 checksum mismatch!"
    fi

    tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C "$CONFIG_MOUNT"
}

setup_chroot() {
    header "Configuring chroot"
    mount --types proc /proc "$CONFIG_MOUNT/proc"
    mount --rbind /sys "$CONFIG_MOUNT/sys"
    mount --make-rslave "$CONFIG_MOUNT/sys"
    mount --rbind /dev "$CONFIG_MOUNT/dev"
    mount --make-rslave "$CONFIG_MOUNT/dev"
    mount --bind /run "$CONFIG_MOUNT/run"
    mount --make-slave "$CONFIG_MOUNT/run"

    cp --dereference $GARB_CONFIG_LOCATION $CONFIG_MOUNT/config.sh
    cp --dereference /etc/resolv.conf $CONFIG_MOUNT/etc/

    if [[ -d /etc/NetworkManager/system-connections ]]; then
        mkdir -p "$CONFIG_MOUNT/etc/NetworkManager/system-connections"
        cp -a /etc/NetworkManager/system-connections/. "$CONFIG_MOUNT/etc/NetworkManager/system-connections/"
        chmod 700 "$CONFIG_MOUNT/etc/NetworkManager/system-connections"
        chmod 600 "$CONFIG_MOUNT/etc/NetworkManager/system-connections/"* 2>/dev/null
    fi
}

default_personal_fn() {
    local SRC="$HOME/.local/src"
 
    # $1 name
    mci_this() {
        cd "$1" || return 1
        sudo make clean install
        cd ..
    }
 
    find_battery() {
        local power_supply
        for power_supply in /sys/class/power_supply/*; do
            [ -r "$power_supply/type" ] || continue
            [ "$(cat "$power_supply/type")" = Battery ] || continue
            if [ -r "$power_supply/scope" ] && [ "$(cat "$power_supply/scope")" = Device ]; then
                continue
            fi
            basename "$power_supply"
            return 0
        done
        return 1
    }
 
    slstatus_args() {
        local bat
        bat=$(find_battery) || bat=
 
        echo 'static const struct arg args[] = {'
        echo '    /* function       format          argument */'
        echo "    { run_command,    \"%s | \",       \"$HOME/.local/bin/nmstat\" },"
        echo "    { run_command,    \"vol %s | \",   \"$HOME/.local/bin/pwvol\" },"
        if [ -n "$bat" ]; then
            echo "    { battery_perc,   \"bat %s%% \",   \"$bat\" },"
            echo "    { battery_state,  \"%s | \",       \"$bat\" },"
        fi
        echo '    { datetime,       "%s",           "%a %d %b  %H:%M" },'
        echo '};'
    }
 
    printf '%s\n' "$CONFIG_PASSWORD" | sudo -S -v
    ( while sudo -n true 2>/dev/null; do
        sleep 50; kill -0 "$$" 2>/dev/null || exit
    done ) &
    local keepalive=$!
    trap 'kill "$keepalive" 2>/dev/null' RETURN

    sudo usermod -a -G video $CONFIG_USERNAME
 
    cd
    wget "https://gratisography.com/wp-content/uploads/2023/04/gratisography-heavenly-sky-free-stock-photo-1170x775.jpg" -O ~/wallpaper.jpg
    sudo emerge --sync
 
    sudo mkdir -p /etc/portage/package.use
    echo "*/* elogind" | sudo tee /etc/portage/package.use/00elogind
    printf '%s\n' \
        '*/* pipewire' \
        'media-video/pipewire sound-server pipewire-alsa dbus extra' \
        'media-video/wireplumber elogind' \
        | sudo tee /etc/portage/package.use/00pipewire
 
    sudo emerge --update --deep --newuse @world
    sudo emerge --noreplace \
        x11-base/xorg-server x11-apps/xinit x11-apps/xrandr x11-apps/xset \
        x11-libs/libX11 x11-libs/libXft x11-libs/libXinerama x11-libs/libXrandr \
        x11-libs/libXext x11-libs/libXfixes x11-libs/libXcomposite \
        x11-libs/libXmu x11-libs/libXScrnSaver \
        media-libs/freetype media-fonts/dejavu media-fonts/terminus-font \
        media-gfx/feh x11-misc/xss-lock x11-misc/xprintidle x11-misc/xclip \
        x11-misc/dunst x11-libs/libnotify x11-misc/picom \
        sys-auth/elogind sys-apps/dbus \
        media-video/pipewire media-video/wireplumber media-libs/libpulse \
        dev-vcs/git dev-build/make dev-build/autoconf dev-build/automake \
        dev-build/libtool dev-util/pkgconf sys-libs/pam sys-power/acpilight
    sudo rc-update add elogind boot
    sudo rc-update add dbus default
    sudo rc-service dbus start
 
    mkdir -p "$SRC" "$HOME/.local/bin"
    cd "$SRC"
    git clone https://git.suckless.org/dwm
    mci_this dwm
    git clone https://git.suckless.org/dmenu
    mci_this dmenu
    git clone https://git.suckless.org/st
    mci_this st
 
    cat >"$HOME/.local/bin/pwvol" <<'EOF'
#!/bin/sh
wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '
    /MUTED/ { print "mute"; exit }
            { printf "%d%%\n", $2 * 100 }'
EOF
 
    cat >"$HOME/.local/bin/nmstat" <<'EOF'
#!/bin/sh
active=$(nmcli -t -f TYPE,NAME connection show --active 2>/dev/null)
 
# substr past the first colon, so SSIDs with spaces or escaped colons survive
ssid=$(printf '%s\n' "$active" | awk -F: '
    $1 == "802-11-wireless" {
        n = substr($0, index($0, ":") + 1)
        gsub(/\\:/, ":", n)
        print n
        exit
    }')
 
if [ -n "$ssid" ]; then
    # --rescan no, or nmcli kicks off a fresh AP scan on every single poll
    sig=$(nmcli -t -f IN-USE,SIGNAL device wifi list --rescan no 2>/dev/null |
          awk -F: '$1 == "*" { print $2; exit }')
    [ -n "$sig" ] && printf '%s %s%%\n' "$ssid" "$sig" || printf '%s\n' "$ssid"
elif printf '%s\n' "$active" | grep -q '^802-3-ethernet:'; then
    echo eth
else
    echo down
fi
EOF
    chmod +x "$HOME/.local/bin/pwvol" "$HOME/.local/bin/nmstat"
 
    git clone https://git.suckless.org/slstatus
    ( cd "$SRC/slstatus" || exit 1
      sed -e 's/^const unsigned int interval = .*/const unsigned int interval = 2000;/' \
          -e '/^static const struct arg args\[\] = {/,/^};/d' config.def.h >config.h
      slstatus_args >>config.h )
    mci_this slstatus
 
    git clone https://github.com/google/xsecurelock.git
    ( cd "$SRC/xsecurelock" || exit 1
        sh autogen.sh &&
        ./configure --with-pam-service-name=system-auth &&
        make &&
        sudo make install )
 
    cat >"$HOME/.xinitrc" <<'EOF'
#!/bin/sh
if [ -d /etc/X11/xinit/xinitrc.d ]; then
    for f in /etc/X11/xinit/xinitrc.d/?*; do
        [ -x "$f" ] && . "$f"
    done
    unset f
fi
xrandr --auto
feh --bg-scale ~/wallpaper.jpg &
gentoo-pipewire-launcher restart &
xset s 300 5
xss-lock -n /usr/local/libexec/xsecurelock/dimmer -l -- xsecurelock &
picom &
dunst &
slstatus &
exec dwm
EOF
    chmod +x "$HOME/.xinitrc"
}

# Because config.sh is sourced, it should be fine to just write something and set CONFIG_PERSONAL_FUNCTION
DEFAULT_PERSONAL_FUNCTION="default_personal_fn"

chroot_work() {
    # Runs a command with interactive recovery on failure
    try() {
        while ! "$@"; do
            echo "Command failed: $*"
            read -r -p "[r]etry, [s]hell, [i]gnore, [a]bort? " response
            case "$response" in
                [rR]) ;;
                [sS]) /bin/bash ;;
                [iI]) return 0 ;;
                *) exit 1 ;;
            esac
        done
    }

    source /etc/profile
    source /config.sh
    set -e
    try emerge-webrsync
    try emerge --oneshot app-portage/cpuid2cpuflags
    echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

    if [[ -d "/usr/share/zoneinfo" ]]; then
        ln -sf "../../usr/share/zoneinfo/$CONFIG_TIMEZONE" /etc/localtime
    fi

    if [[ -f "/etc/locale.gen" ]]; then
        echo $CONFIG_LOCALE >> /etc/locale.gen
        try locale-gen
    fi

    env-update && source /etc/profile && source /config.sh

    try emerge sys-kernel/linux-firmware sys-firmware/sof-firmware

    if lscpu | grep -q Intel; then
        try emerge sys-firmware/intel-microcode
    fi

    echo "sys-kernel/installkernel grub dracut" >> /etc/portage/package.use/installkernel

    try emerge sys-kernel/installkernel

    mkdir -p /boot/grub

    if [[ $CONFIG_UEFI -eq 1 ]]; then
        try grub-install --target=x86_64-efi --efi-directory=/efi --recheck
    else
        try grub-install --recheck "/dev/$CONFIG_DISK"
    fi

    try emerge sys-kernel/"$CONFIG_KERNEL"

    {
        ROOT_SRC=$(findmnt -no SOURCE /)
        ROOT_FSTYPE=$(findmnt -no FSTYPE /)
        echo "UUID=$(blkid -s UUID -o value "$ROOT_SRC") / $ROOT_FSTYPE noatime 0 1"

        if [[ $CONFIG_UEFI -eq 1 ]]; then
            EFI_SRC=$(findmnt -no SOURCE /efi)
            echo "UUID=$(blkid -s UUID -o value "$EFI_SRC") /efi vfat noatime 0 2"
        else
            BOOT_SRC=$(findmnt -no SOURCE /boot)
            BOOT_FSTYPE=$(findmnt -no FSTYPE /boot)
            echo "UUID=$(blkid -s UUID -o value "$BOOT_SRC") /boot $BOOT_FSTYPE noatime 0 2"
        fi

        SWAP_SRC=$(swapon --noheadings --show=NAME | grep '^/dev/' | grep -v zram | head -n1)
        echo "UUID=$(blkid -s UUID -o value "$SWAP_SRC") none swap sw 0 0"
    } > /etc/fstab

    try grub-mkconfig -o /boot/grub/grub.cfg

    echo "$CONFIG_HOSTNAME" > /etc/hostname
    echo "hostname=\"$CONFIG_HOSTNAME\"" > /etc/conf.d/hostname

    echo "root:$CONFIG_ROOTPASS" | chpasswd
    try useradd -m -G wheel,users -s /bin/bash "$CONFIG_USERNAME"
    echo "$CONFIG_USERNAME:$CONFIG_PASSWORD" | chpasswd

    try emerge app-admin/sudo
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    try emerge net-misc/networkmanager app-admin/sysklogd net-misc/chrony sys-process/cronie
    try rc-update add NetworkManager default
    try rc-update add sysklogd default
    try rc-update add chronyd default
    try rc-update add cronie default

    try emerge app-portage/gentoolkit
    try eclean-dist
    try eclean-pkg

    echo "Launching personal function..."
}

enable_chroot() {
    header "Working inside chroot"
    export -f chroot_work
    chroot "$CONFIG_MOUNT" /bin/bash -c "chroot_work"

    { declare -p $(compgen -v CONFIG_)
      declare -f "$CONFIG_PERSONAL_FUNCTION"
      printf '%s\n' "$CONFIG_PERSONAL_FUNCTION"
    } | chroot "$CONFIG_MOUNT" sudo -u "$CONFIG_USERNAME" -H bash -s
}

cleanup_reboot() {
    header "Cleaning Up"
    swapoff -a
    umount -R "$CONFIG_MOUNT"
    pinfo "Installation completed"
    askab "shutdown -r now" "exit"
}

load_config() {
    header "Loading Config"
    if [[ -f "$GARB_CONFIG_LOCATION" ]]; then
        source "$GARB_CONFIG_LOCATION"
    else
        touch "$GARB_CONFIG_LOCATION"
        export GARB_BUILD_CONFIG=1
    fi
    checkp CONFIG_USERNAME "Enter new username: "
    checkp CONFIG_PASSWORD "Enter password for $CONFIG_USERNAME: "
    checks CONFIG_ROOTPASS "$CONFIG_PASSWORD"

    if [[ -z $CONFIG_DISK ]]; then
        lsblk
        checkp CONFIG_DISK "Name of disk device: /dev/"
    fi

    if [[ ! -b "/dev/$CONFIG_DISK" ]]; then
        perror "Device not found: /dev/$CONFIG_DISK"
        exit
    fi

    if [[ -d /sys/firmware/efi ]]; then
        checks CONFIG_UEFI 1
    else
        checks CONFIG_UEFI 0
        pwarn "This setup is not officially supported"
    fi

    checks CONFIG_FILESYSTEM $DEFAULT_FILESYSTEM
    if [[ ! $CONFIG_FILESYSTEM =~ ^(ext4|xfs|btrfs)$ ]]; then
        echo "Unsupported filesystem: $CONFIG_FILESYSTEM (supported: ext4, xfs, btrfs)"
        exit 1
    fi
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

    SUGGESTED_SWAP_SIZE=$MEM_KB

    # 4G minimum
    if [[ $MEM_KB -lt 4194304 ]]; then
        SUGGESTED_SWAP_SIZE=4194304
    fi
    
    # 8G maximum
    if [[ 8392704 -lt $MEM_KB ]]; then
        SUGGESTED_SWAP_SIZE=8392704
    fi
    SUGGESTED_SWAP_SIZE=$(( ((SUGGESTED_SWAP_SIZE + 1023) / 1024) * 1024 ))

    # Suggest default
    checks CONFIG_SWAPSIZE $SUGGESTED_SWAP_SIZE

    checks CONFIG_PROFILE $DEFAULT_PROFILE
    checks CONFIG_ARCH "amd64"
    checks CONFIG_HOSTNAME $DEFAULT_HOSTNAME
    checks CONFIG_KERNEL $DEFAULT_KERNEL

    DETECTED_TIMEZONE=$(curl -fSsL https://ipapi.co/timezone) || DETECTED_TIMEZONE="UTC"
    nicerr "Failed to automatically fetch timezone, using UTC"
    checks CONFIG_TIMEZONE "$DETECTED_TIMEZONE"
    checks CONFIG_LOCALE $DEFAULT_LOCALE
    checks CONFIG_MOUNT $DEFAULT_MOUNT

    checks CONFIG_COMMON_FLAGS "-march=native -O2 -pipe"
    checks CONFIG_CFLAGS "\${COMMON_FLAGS}"
    checks CONFIG_CXXFLAGS "\${COMMON_FLAGS}"
    checks CONFIG_RUSTFLAGS "\${COMMON_FLAGS}"
    checks CONFIG_LICENSES "*"

    checks CONFIG_PERSONAL_FUNCTION $DEFAULT_PERSONAL_FUNCTION

    CPUCORES=$(nproc)

    MAX_JOBS_BY_RAM=$((MEM_KB / 2097152))
    MAX_JOBS_BY_CPU=$CPUCORES

    if [[ MAX_JOBS_BY_CPU -lt MAX_JOBS_BY_RAM ]]; then
        checks CONFIG_JOBS $MAX_JOBS_BY_CPU
    else
        checks CONFIG_JOBS $MAX_JOBS_BY_RAM
    fi
}

system_checks() {
    header "Checking compatibility"
    if [[ $USER != "root" ]]; then
        perror "Please run as root"
        exit
    fi

    if [[ $(uname -m) != "x86_64" ]]; then
        pinfo "Your system: $(uname -sm)"
        perror "Only x86_64 systems are supported"
        exit
    fi

    if [[ ! -d /sys/firmware/efi ]]; then
        perror "Only UEFI is supported"
        exit
    fi

    pinfo "Compatible System..."
}

splash() {
    header "Gentoo Auto Ricing Bootstrap"
    echo "Created by JP D'Agostino"
    echo "GARB is public domain"
    echo "--"
    echo "Version $GARB_VERSION"
    echo "Config Version $GARB_CONFIG_VERSION"
    echo "Config File $GARB_CONFIG_LOCATION"
    echo "Logging to $GARB_LOGFILE"
}

splash
if [[ -z $GARB_BYPASS_SYSTEMCHECK ]]; then
    system_checks
fi
test_net
check_update
load_config
header "Preparing Disks"
pwarn "This will wipe all data off $CONFIG_DISK"
askab "prepare_disks" "exit"
setup_stagefile
setup_makeconf
setup_chroot
enable_chroot
cleanup_reboot