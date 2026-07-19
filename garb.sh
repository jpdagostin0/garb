#!/bin/bash
# Version Info
GARB_VERSION="1.0"
GARB_CONFIG_VERSION="1"
GARB_CONFIG_LOCATION="config.sh"
#GARB_BYPASS_SYSTEMCHECK=1

# Defaults
DEFAULT_BOOTEND=1048576
DEFAULT_FILESYSTEM="xfs"
DEFAULT_CHECKSITE="gentoo.org"
DEFAULT_NAMESERVER="1.1.1.1"
DEFAULT_MOUNT="/mnt/gentoo"
DEFAULT_PROFILE="desktop-openrc"
DEFAULT_BOOTLOADER="grub"
DEFAULT_LOCALE="$(locale | grep LANG | awk -F= '{print $2}') UTF-8"

# Variables
GARB_INTERNET=1
GARB_BUILD_CONFIG=0
RESOLV_NAMESERVER="$(grep nameserver /etc/resolv.conf | awk '{print $2}')"

# Checks if the variable exists or prompts
# $1 variable to read
# $2 prompt text
checkp() {
    local -n var="$1"
    if [[ -z "$var" ]]; then
        echo "$1 not set... prompting"
        read -p "$2" var
        echo "$1 set to $var"
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
        echo "$1 not set... using default ($var)"
        write_config "$1" "$var"
    fi
}

# Writes to config (if allowed)
# $1 var
# $2 value
write_config() {
    if [[ $1 == CONFIG_* ]]; then
        if [[ GARB_BUILD_CONFIG -eq 1 ]]; then
            echo "Writing to config..."
            echo "$1=$2" >> $GARB_CONFIG_LOCATION
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
        echo "Could not ping $RESOLV_NAMESERVER"
        askab "nmtui" "export GARB_INTERNET=0"
    fi

    # Internet check
    curl -fs $DEFAULT_CHECKSITE
    
    STATUS="$?"
    if [[ $STATUS -ne 0 ]]; then
        echo "Could not access $DEFAULT_CHECKSITE"
        askab "nmtui" "export GARB_INTERNET=0"
    fi
}

prepare_disks() {
    header "Preparing Disks"
    DEVICE="/dev/$CONFIG_DISK"
    wipefs -a "$DEVICE"
    sgdisk --zap-all "$DEVICE"

    if [[ $CONFIG_UEFI -eq 1 ]]; then
        parted -s "$DEVICE" mklabel gpt
        parted -s "$DEVICE" mkpart ESP 1MiB "$DEFAULT_BOOTEND"KiB
        parted -s "$DEVICE" set 1 esp on
    else
        parted -s "$DEVICE" mklabel mbr
        parted -s "$DEVICE" mkpart primary 1MiB "$DEFAULT_BOOTEND"KiB
    fi
    
    EOSWAP=$((DEFAULT_BOOTEND + CONFIG_SWAPSIZE))

    parted -s "$DEVICE" mkpart primary linux-swap "$DEFAULT_BOOTEND"KiB "$EOSWAP"KiB
    parted -s "$DEVICE" mkpart primary "$EOSWAP"KiB 100%
    partprobe "$DEVICE"
    
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

    MKFS="mkfs.$DEFAULT_FILESYSTEM"

    if [[ $DEFAULT_FILESYSTEM == "zfs" ]]; then
        MKFS="zpool create"
    fi

    $MKFS "$PART3"
    mkswap "$PART2"

    if [[ $CONFIG_UEFI -eq 1 ]]; then
        mkfs.fat -F 32 "$PART1"
    else
        "$MKFS" "$PART1"
    fi

    mount_disks "$PART1" "$PART2" "$PART3"
}

# $1 bios, $2 swap, $3 primary
mount_disks() {
    swapon "$2"

    checks CONFIG_MOUNT $DEFAULT_MOUNT

    if [[ $CONFIG_UEFI -eq 1 ]]; then
        mkdir -p "$CONFIG_MOUNT/efi"
        mount "$3" "$CONFIG_MOUNT"
        mount "$1" "$CONFIG_MOUNT/efi"
    else
        mkdir -p "$CONFIG_MOUNT/boot"
        mount "$3" "$CONFIG_MOUNT"
        mount "$1" "$CONFIG_MOUNT/boot"
    fi

    cp $GARB_CONFIG_LOCATION $CONFIG_MOUNT
}

# $1 conf location
# $2 variable
# $3 value
set_conf_variable() {
    echo "$2=\"$3\"" >> $1
}

setup_makeconf() {
    header "Setting up portage/make.conf"
    MAKECONF=$CONFIG_MOUNT/etc/portage/make.conf
    CPUCORES=$(nproc)

    checks CONFIG_COMMON_FLAGS "-march=native -O2 -pipe"
    checks CONFIG_CFLAGS "\${COMMON_FLAGS}"
    checks CONFIG_CXXFLAGS "\${COMMON_FLAGS}"
    checks CONFIG_RUSTFLAGS "\${COMMON_FLAGS}"
    checks CONFIG_LICENSES "*"

    rm $MAKECONF

    set_conf_variable $MAKECONF "COMMON_FLAGS" $CONFIG_COMMON_FLAGS
    set_conf_variable $MAKECONF "CFLAGS" $CONFIG_CFLAGS
    set_conf_variable $MAKECONF "CXXFLAGS" $CONFIG_CXXFLAGS
    set_conf_variable $MAKECONF "RUSTFLAGS" $CONFIG_RUSTFLAGS
    set_conf_variable $MAKECONF "ACCEPT_LICENSE" $CONFIG_LICENSES

    MAX_JOBS_BY_RAM=$((MEM_KB / 2097152))
    MAX_JOBS_BY_CPU=$CPUCORES

    if [[ MAX_JOBS_BY_CPU -lt MAX_JOBS_BY_RAM ]]; then
        checks CONFIG_JOBS $MAX_JOBS_BY_CPU
    else
        checks CONFIG_JOBS $MAX_JOBS_BY_RAM
    fi

    set_conf_variable $MAKECONF "MAKEOPTS" "-j$CONFIG_JOBS -l$((CONFIG_JOBS + 1))"
}

setup_stagefile() {
    header "Stage 3 Setup"
    if hash chronyc 2>/dev/null; then
        chronyc -a makestep > /dev/null 2>&1
    fi

    S3LATEST=$(curl -fs "https://distfiles.gentoo.org/releases/$CONFIG_ARCH/autobuilds/latest-stage3-$CONFIG_ARCH-$CONFIG_PROFILE.txt" | sed -n '6p' | awk '{print $1}')
    S3DL="https://distfiles-cdn-origin.gentoo.org/releases/$CONFIG_ARCH/autobuilds/$S3LATEST"
    curl "$S3DL" -o stage3.tar.xz
    tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C $CONFIG_MOUNT
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

    checks CONFIG_TIMEZONE $(curl -fSsL https://ipinfo.io/json | grep timezone | sed 's/[^a-zA-Z0-9/_ ]//g' | awk '{print $2}')
    checks CONFIG_LOCALE $DEFAULT_LOCALE

    cp --dereference $GARB_CONFIG_LOCATION $CONFIG_MOUNT/config.sh
    cp --dereference /etc/resolv.conf $CONFIG_MOUNT/etc/
}

chroot_work() {
    source /etc/profile
    source /config.sh
    emerge-webrsync
    emerge --ask --oneshot app-portage/cpuid2cpuflags
    echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

    if [[ -f "/usr/share/zoneinfo" ]]; then
        ln -sf "../../usr/share/zoneinfo/$CONFIG_TIMEZONE" /etc/localtime
    fi

    if [[ -f "/etc/locale.gen" ]]; then
        echo $CONFIG_LOCALE >> /etc/locale.gen
        locale-gen
    fi

    env-update && source /etc/profile && source /config.sh

    emerge sys-kernel/linux-firmware sys-firmware/sof-firmware

    lscpu | grep Intel >> /dev/null
    if [[ $? -eq 0 ]]; then
        emerge sys-firmware/intel-microcode
    fi

    echo "sys-kernel/installkernel grub dracut" >> /etc/portage/package.use/installkernel

    emerge sys-kernel/installkernel
}

enable_chroot() {
    header "Working inside chroot"
    export -f chroot_work
    chroot "$CONFIG_MOUNT" /bin/bash -c "chroot_work"
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
        echo "Device not found: /dev/$CONFIG_DISK"
        exit
    fi

    if [[ -d /sys/firmware/efi ]]; then
        checks CONFIG_UEFI 1
    else
        checks CONFIG_UEFI 0
    fi

    checks CONFIG_FILESYSTEM $DEFAULT_FILESYSTEM
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

    SUGGESTED_SWAP_SIZE=$MEM_KB

    # 4G minimum
    if [[ $MEM_KB -lt 4194304 ]]; then
        SUGGESTED_SWAP_SIZE=4194304
    fi
    
    # 8G maximum
    if [[8392704 -lt $MEM_KB ]]; then
        SUGGESTED_SWAP_SIZE=8392704
    fi

    # Suggest default
    checks CONFIG_SWAPSIZE $SUGGESTED_SWAP_SIZE

    checks CONFIG_PROFILE $DEFAULT_PROFILE
    checks CONFIG_ARCH "amd64"
}

system_checks() {
    header "Checking compatibility"
    if [[ $USER != "root" ]]; then
        echo "Please run as root"
        exit
    fi

    if [[ $(uname -m) != "x86_64" ]]; then
        echo "Only x86-64 CPUs are supported"
        exit
    fi

    if [[ ! -d /sys/firmware/efi ]]; then
        echo "Only UEFI is supported"
        exit
    fi

    echo "Compatible System..."
}

splash() {
    header "Gentoo Auto Ricing Bootstrap"
    echo "Created by JP D'Agostino"
    echo "GARB is public domain"
    echo "--"
    echo "Version $GARB_VERSION"
    echo "Config Version $GARB_CONFIG_VERSION"
    echo "Config File $GARB_CONFIG_LOCATION"
}

splash
if [[ -z $GARB_BYPASS_SYSTEMCHECK ]]; then
    system_checks
fi
test_net
load_config
prepare_disks
setup_stagefile
setup_makeconf
setup_chroot
enable_chroot