#!/usr/bin/env bash
# build.sh — Usage: ./build.sh <github-username>
set -euo pipefail

GH_USER="${1:-}"
if [ -z "$GH_USER" ]; then
    echo "Usage: ./build.sh <your-github-username>"
    exit 1
fi

KERNEL_VER="6.18.57"
BUSYBOX_VER="1.37.0"
DROPBEAR_VER="2026.94"
WORKDIR="$(pwd)/build"
ROOTFS="${WORKDIR}/rootfs"

mkdir -p "$WORKDIR" "$ROOTFS"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,root/.ssh,var/run}
chmod 700 "$ROOTFS/root" "$ROOTFS/root/.ssh"

echo "[1/6] Fetching SSH public keys from GitHub user: ${GH_USER}..."
curl -fsSL "https://github.com/${GH_USER}.keys" -o "${ROOTFS}/root/.ssh/authorized_keys"
if [ ! -s "${ROOTFS}/root/.ssh/authorized_keys" ]; then
    echo "Error: No public SSH keys found at https://github.com/${GH_USER}.keys"
    exit 1
fi
chmod 600 "${ROOTFS}/root/.ssh/authorized_keys"

echo "[2/6] Compiling static PID 1 init daemon..."
musl-gcc -O2 -static -s src/init.c -o "${ROOTFS}/init"
chmod +x "${ROOTFS}/init"

echo "[3/6] Building static BusyBox..."
cd "$WORKDIR"
[ ! -f "busybox-${BUSYBOX_VER}.tar.bz2" ] && curl -LO "https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2"
tar -xf "busybox-${BUSYBOX_VER}.tar.bz2"
cd "busybox-${BUSYBOX_VER}"
make defconfig
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
make -j"$(nproc)" CC=musl-gcc
make CONFIG_PREFIX="$ROOTFS" install

echo "[4/6] Building static Dropbear SSH ${DROPBEAR_VER}..."
cd "$WORKDIR"
[ ! -f "dropbear-${DROPBEAR_VER}.tar.bz2" ] && curl -LO "https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VER}.tar.bz2"
tar -xf "dropbear-${DROPBEAR_VER}.tar.bz2"
cd "dropbear-${DROPBEAR_VER}"
./configure CC=musl-gcc --enable-static --disable-zlib --disable-wtmp --disable-lastlog
make -j"$(nproc)" PROGRAMS="dropbear dbclient dropbearkey scp" MULTI=1 strip
cp dropbearmulti "${ROOTFS}/usr/sbin/dropbear"
ln -sf /usr/sbin/dropbear "${ROOTFS}/usr/bin/ssh"
ln -sf /usr/sbin/dropbear "${ROOTFS}/usr/bin/scp"

echo "[5/6] Configuring rootfs & copying overlays..."
cd "$WORKDIR/.."
cp -r overlay/* "$ROOTFS/"
chmod +x "$ROOTFS/sbin/"*
echo "root:x:0:0:root:/root:/bin/sh" > "${ROOTFS}/etc/passwd"
echo "root:x:0:" > "${ROOTFS}/etc/group"
mkdir -p "${ROOTFS}/usr/share/udhcpc"
cp "${WORKDIR}/busybox-${BUSYBOX_VER}/examples/udhcp/simple.script" "${ROOTFS}/usr/share/udhcpc/default.script"
chmod +x "${ROOTFS}/usr/share/udhcpc/default.script"

# Pack initramfs archive
(cd "$ROOTFS" && find . -print0 | cpio --null -ov --format=newc | gzip -9 > "${WORKDIR}/initramfs.cpio.gz")

echo "[6/6] Compiling Linux Kernel ${KERNEL_VER} & Generating Bootable ISO..."
cd "$WORKDIR"
[ ! -f "linux-${KERNEL_VER}.tar.xz" ] && curl -LO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VER}.tar.xz"
tar -xf "linux-${KERNEL_VER}.tar.xz"
cd "linux-${KERNEL_VER}"
make tinyconfig
./scripts/kconfig/merge_config.sh -m .config ../../config/kernel.fragment
make olddefconfig
make -j"$(nproc)" bzImage

# Package into hybrid BIOS/UEFI ISO via isolinux/xorriso
ISO_DIR="${WORKDIR}/iso"
mkdir -p "${ISO_DIR}/boot/isolinux"
cp arch/x86/boot/bzImage "${ISO_DIR}/boot/vmlinuz"
cp "${WORKDIR}/initramfs.cpio.gz" "${ISO_DIR}/boot/initramfs.cpio.gz"
cp /usr/lib/ISOLINUX/isolinux.bin "${ISO_DIR}/boot/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${ISO_DIR}/boot/isolinux/"

cat <<EOF > "${ISO_DIR}/boot/isolinux/isolinux.cfg"
DEFAULT nanonode
TIMEOUT 10
LABEL nanonode
    KERNEL /boot/vmlinuz
    INITRD /boot/initramfs.cpio.gz
    APPEND quiet console=tty0 console=ttyS0,115200n8
EOF

xorriso -as mkisofs \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c boot/isolinux/boot.cat \
    -b boot/isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -o "${WORKDIR}/../nanonode-${GH_USER}.iso" "$ISO_DIR"

echo "Done! Bootable image created: nanonode-${GH_USER}.iso"