#!/bin/sh

set -e -x -o pipefail

arch=$1
[ -n "$arch" ]

workdir=$(mktemp -d --tmpdir cross.XXXXXX)
cleanup () {
    rm -r "$workdir"
}
#trap cleanup 0

# See the architecture-specific shell scripts in
# https://sources.debian.net/src/base-installer/1.169/kernel/
case $arch in
    mipsel)
         kernel=linux-image-4kc-malta
         # Workaround for https://bugs.debian.org/865314
         append=nokaslr
         ;;
    *)
         echo "unknown architecture $arch"
         exit 1
         ;;
esac

#XXX apt-get -y install qemu-user-static
debootstrap --arch="$arch" --include="$kernel",openssh-server --foreign stretch "$workdir/root" https://deb.debian.org/debian
cp "/tmp/qemu-user-static/usr/bin/qemu-$arch-static" "$workdir/root/usr/bin/qemu-$arch" #XXX
chroot "$workdir/root" /debootstrap/debootstrap --second-stage

cat >> "$workdir/root/etc/initramfs-tools/modules" << EOF
9p
9pnet_virtio
overlay
EOF
cat > "$workdir/root/etc/initramfs-tools/scripts/local-bottom/overlay" << "EOF"
#!/bin/sh
if [ "$1" = prereqs ]; then echo; exit; fi
set -e
mkdir /overlay
mount -t tmpfs tmpfs /overlay
mkdir /overlay/lower /overlay/upper /overlay/work /newroot
mount -t overlay -o lowerdir=/root,upperdir=/overlay/upper,workdir=/overlay/work overlay /newroot
mkdir /newroot/mnt/overlay
mount -o move /overlay /newroot/mnt/overlay
mount -o move /root /newroot/mnt/overlay/lower
mount -o move /newroot /root
EOF
chmod +x "$workdir/root/etc/initramfs-tools/scripts/local-bottom/overlay"

echo tester > "$workdir/root/etc/hostname"
rm "$workdir/root/etc/resolv.conf"
ln -s /run/systemd/resolve/resolv.conf "$workdir/root/etc/resolv.conf"
cat > "$workdir/root/etc/systemd/network/dhcp.network" << EOF
[Match]
Name=en*
[Network]
DHCP=v4
EOF
cat > "$workdir/root/etc/systemd/system/notify-boot.service" << EOF
[Unit]
Description=Notify host when sshd is running
Wants=sshd.service
After=sshd.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '> /dev/tcp/10.0.2.2/12223'

[Install]
WantedBy=multi-user.target
EOF
chroot "$workdir/root" systemctl enable systemd-networkd systemd-resolved notify-boot

LANG=C chroot "$workdir/root" update-initramfs -u

cat > "$workdir/qemu.sh" << EOF
#!/bin/sh

set -e

root=\$(dirname "\$0")/root
cachedir=~/.cache/cross-qemu
mkdir -p "\$cachedir"

if ! [ -e ~/.ssh/id_rsa.pub ]; then
    echo Please generate an SSH key
    exit 1
fi

mkdir -p "\$root/root/.ssh"
cp ~/.ssh/id_rsa.pub "\$root/root/.ssh/authorized_keys"

# XXX add fstab entries
# rust /rust 9p trans=virtio,version=9p2000.u 0 0
# XXX copy in authorized_keys

qemu-system-$arch -display none -daemonize -pidfile "\$cachedir/pid" -serial "file:\$cachedir/qemu.log" \\
                  -kernel "\$root/vmlinux" \\
                  -initrd "\$root/initrd.img" \\
                  -append "console=ttyS0 $append root=root rootfstype=9p rootflags=trans=virtio,version=9p2000.u" \\
                  -m 2048 \\
                  -virtfs local,path="\$root",security_model=passthrough,readonly,mount_tag=root \\
                  -net nic,model=virtio -net user,hostfwd=::12222-:22
nc -l -p 12223
ssh -p 12222 -o NoHostAuthenticationForLocalhost=yes root@localhost "\$@"
ret=\$?
kill "\$(cat "\$cachedir/pid")"
exit "\$ret"
EOF
chmod +x "$workdir/qemu.sh"

echo "$workdir"
