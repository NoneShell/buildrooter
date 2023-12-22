#!/usr/bin/env bash

# create-image.sh creates a minimal Debian Linux image suitable for cross compiler.

set -eux

# Create a minimal Debian distribution in a directory.
DIR=chroot
PREINSTALL_PKGS=curl,tar,gcc,libc6-dev,time,strace,sudo,less,psmisc,policycoreutils,checkpolicy,libncurses5-dev,build-essential,bison,flex,gettext,texinfo,unzip,bzip2,locales,make,rsync,vim,subversion,file

# Variables affected by options
ARCH=$(uname -m)
RELEASE=wheezy
SEEK=2047

# Display help function
display_help() {
    echo "Usage: $0 [option...] " >&2
    echo
    echo "   -a, --arch                 Set architecture"
    echo "   -d, --distribution         Set on which debian distribution to create"
    echo "   -s, --seek                 Image size (MB), default 2048 (2G)"
    echo "   -h, --help                 Display help message"
    echo
}

while true; do
    if [ $# -eq 0 ];then
	echo $#
	break
    fi
    case "$1" in
        -h | --help)
            display_help
            exit 0
            ;;
        -a | --arch)
	    ARCH=$2
            shift 2
            ;;
        -d | --distribution)
	    RELEASE=$2
            shift 2
            ;;
        -s | --seek)
	    SEEK=$(($2 - 1))
            shift 2
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
        *)  # No more options
            break
            ;;
    esac
done

# Handle cases where qemu and Debian use different arch names
case "$ARCH" in
    ppc64le)
        DEBARCH=ppc64el
        ;;
    aarch64)
        DEBARCH=arm64
        ;;
    arm)
        DEBARCH=armel
        ;;
    x86_64)
        DEBARCH=amd64
        ;;
    *)
        DEBARCH=$ARCH
        ;;
esac

# Foreign architecture

FOREIGN=false
if [ $ARCH != $(uname -m) ]; then
    # i386 on an x86_64 host is exempted, as we can run i386 binaries natively
    if [ $ARCH != "i386" -o $(uname -m) != "x86_64" ]; then
        FOREIGN=true
    fi
fi

if [ $FOREIGN = "true" ]; then
    # Check for according qemu static binary
    if ! which qemu-$ARCH-static; then
        echo "Please install qemu static binary for architecture $ARCH (package 'qemu-user-static' on Debian/Ubuntu/Fedora)"
        exit 1
    fi
    # Check for according binfmt entry
    if [ ! -r /proc/sys/fs/binfmt_misc/qemu-$ARCH ]; then
        echo "binfmt entry /proc/sys/fs/binfmt_misc/qemu-$ARCH does not exist"
        exit 1
    fi
fi


sudo rm -rf $DIR
sudo mkdir -p $DIR
sudo chmod 0755 $DIR

# 1. debootstrap stage

DEBOOTSTRAP_PARAMS="--arch=$DEBARCH --include=$PREINSTALL_PKGS --components=main,contrib,non-free,non-free-firmware $RELEASE $DIR https://archive.debian.org/debian/"
if [ $FOREIGN = "true" ]; then
    DEBOOTSTRAP_PARAMS="--foreign $DEBOOTSTRAP_PARAMS"
fi

# riscv64 is hosted in the debian-ports repository
# debian-ports doesn't include non-free, so we exclude firmware-atheros
if [ $DEBARCH == "riscv64" ]; then
    DEBOOTSTRAP_PARAMS="--keyring /usr/share/keyrings/debian-ports-archive-keyring.gpg --exclude firmware-atheros $DEBOOTSTRAP_PARAMS http://deb.debian.org/debian-ports"
fi
# exec debootstrap
sudo --preserve-env=http_proxy,https_proxy,ftp_proxy,no_proxy debootstrap $DEBOOTSTRAP_PARAMS

# 2. debootstrap stage: only necessary if target != host architecture

if [ $FOREIGN = "true" ]; then
    sudo cp $(which qemu-$ARCH-static) $DIR/$(which qemu-$ARCH-static)
    sudo chroot $DIR /bin/bash -c "/debootstrap/debootstrap --second-stage"
fi

# Set some defaults and enable promtless ssh to the machine for root.
sudo sed -i '/^root/ { s/:x:/::/ }' $DIR/etc/passwd
echo 'T0:23:respawn:/sbin/getty -L ttyS0 115200 vt100' | sudo tee -a $DIR/etc/inittab
printf '\nauto eth0\niface eth0 inet dhcp\n' | sudo tee -a $DIR/etc/network/interfaces
echo '/dev/root / ext4 defaults 0 0' | sudo tee -a $DIR/etc/fstab
echo -en "127.0.0.1\tlocalhost\n" | sudo tee $DIR/etc/hosts
echo "nameserver 8.8.8.8" | sudo tee -a $DIR/etc/resolve.conf
echo "buildrooter" | sudo tee $DIR/etc/hostname
ssh-keygen -f $RELEASE.id_rsa -t rsa -N ''
sudo mkdir -p $DIR/root/.ssh/
cat $RELEASE.id_rsa.pub | sudo tee $DIR/root/.ssh/authorized_keys

# pause until input
read -p "Press any key to continue... " -n1 -s
# Build a disk image
dd if=/dev/zero of=$RELEASE.img bs=1M seek=$SEEK count=1
sudo mkfs.ext4 -F $RELEASE.img
sudo mkdir -p /mnt/$DIR
sudo mount -o loop $RELEASE.img /mnt/$DIR
sudo cp -a $DIR/. /mnt/$DIR/.
sudo umount /mnt/$DIR
