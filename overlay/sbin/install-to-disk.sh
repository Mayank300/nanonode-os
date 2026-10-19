#!/bin/sh
# overlay/sbin/install-to-disk
set -e

TARGET_DISK="$1"
if [ -z "$TARGET_DISK" ] || [ ! -b "$TARGET_DISK" ]; then
    echo "Usage: install-to-disk /dev/sdX (or /dev/nvme0n1)"
    exit 1
fi

echo "[!] Formatting $TARGET_DISK and installing NanoNode OS..."

# 1. Create a single bootable Linux partition
dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 status=none
printf "o\nn\np\n1\n\n\na\nw\n" | fdisk "$TARGET_DISK" >/dev/null

# Handle /dev/sda1 vs /dev/nvme0n1p1 naming
PART="${TARGET_DISK}1"
[ ! -b "$PART" ] && PART="${TARGET_DISK}p1"

mkfs.ext4 -F -L "NANONODE" "$PART"

# 2. Mount target disk and copy kernel + initramfs from live media
mkdir -p /mnt/target /mnt/bootmedia
mount "$PART" /mnt/target
mount -o ro /dev/sr0 /mnt/bootmedia 2>/dev/null || mount -o ro /dev/sdb1 /mnt/bootmedia

mkdir -p /mnt/target/boot/extlinux /mnt/target/persist
cp /mnt/bootmedia/boot/vmlinuz /mnt/target/boot/vmlinuz
cp /mnt/bootmedia/boot/initramfs.cpio.gz /mnt/target/boot/initramfs.cpio.gz

# 3. Install Syslinux/Extlinux MBR & Bootloader config
dd if=/usr/share/syslinux/mbr.bin of="$TARGET_DISK" bs=440 count=1 status=none
extlinux --install /mnt/target/boot/extlinux

cat <<EOF > /mnt/target/boot/extlinux/extlinux.conf
DEFAULT nanonode
TIMEOUT 10
LABEL nanonode
    KERNEL /boot/vmlinuz
    INITRD /boot/initramfs.cpio.gz
    APPEND quiet console=tty0 console=ttyS0,115200n8
EOF

umount /mnt/target /mnt/bootmedia
sync
echo "[+] Installation complete! Remove USB media and run 'reboot -f'."