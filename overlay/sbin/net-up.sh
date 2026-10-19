#!/bin/sh
# overlay/sbin/net-up

ip link set lo up

# Populate device nodes and load NIC drivers if modular
mdev -s

for iface in /sys/class/net/*; do
    dev=$(basename "$iface")
    [ "$dev" = "lo" ] && continue
    echo "[net] Bringing up interface: $dev"
    ip link set "$dev" up
    udhcpc -i "$dev" -t 5 -T 2 -n -q -s /usr/share/udhcpc/default.script && break
done

mkdir -p /etc/dropbear
echo "----------------------------------------"
echo "SSH Ready! Connect using your GitHub key:"
ip -4 addr show scope global | awk '/inet / {print "  ssh root@" $2}' | cut -d'/' -f1
echo "To install permanently to disk, run: install-to-disk /dev/sda"
echo "----------------------------------------"