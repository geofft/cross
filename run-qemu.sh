#!/bin/sh
#
# usage: run-qemu.sh <arch> <command> [args...]

set -e -o pipefail

arch=$1; shift
[ -n "$arch" ]

cachedir=~/.cache/cross-qemu

case $arch in
  mipsel)
    kernel=http://deb.debian.org/debian/dists/stable/main/installer-mipsel/current/images/malta/netboot/vmlinux-4.9.0-3-4kc-malta
    initrd=http://deb.debian.org/debian/dists/stable/main/installer-mipsel/current/images/malta/netboot/initrd.gz
    # Workaround for https://bugs.debian.org/865314
    append=nokaslr
    ;;
  *)
    echo "Unknown architecture $arch"
    exit 1
    ;;
esac

mkdir -p "$cachedir/$arch"
wget -q -P "$cachedir/$arch" -N "$kernel" "$initrd"
kernel=$cachedir/$arch/${kernel##*/}
initrd=$cachedir/$arch/${initrd##*/}

if ! [ -e "$cachedir/id_rsa" ]; then
   ssh-keygen -b 2048 -t rsa -N "" -f "$cachedir/id_rsa"
fi

workdir=$(mktemp -d --tmpdir cross.XXXXXX)
cleanup () {
    if [ -e "$workdir/pid" ]; then
        kill "$(cat "$workdir/pid")"
    fi
    rm -r "$workdir"
}
trap cleanup 0

mkdir -p "$workdir/initrd/etc/ssh" "$workdir/initrd/.ssh"
echo "UsePrivilegeSeparation no" > "$workdir/initrd/etc/ssh/sshd_config"
cp "$cachedir/id_rsa" "$workdir/initrd/etc/ssh/ssh_host_rsa_key"
cp "$cachedir/id_rsa.pub" "$workdir/initrd/.ssh/authorized_keys"
cat > "$workdir/initrd/watch-for-ssh" << 'EOF'
#!/bin/sh
tail -f /var/log/syslog | while read line; do
  case "$line" in
    *sshd*) nc 10.0.2.2 12223 </dev/null
            exit 0 ;;
    *) ;;
  esac
done
EOF
chmod +x "$workdir/initrd/watch-for-ssh"
cat > "$workdir/initrd/preseed.cfg" << 'EOF'
d-i debian-installer/locale string en_US
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string tester
d-i netcfg/get_domain string
d-i anna/choose_modules string network-console
# Don't download and install installer components, we don't need them
d-i anna/standard_modules boolean false
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
# Using screen is an easy way of daemonizing, otherwise we hold onto an
# fd and end up blocking boot. There's a default /etc/screenrc that
# starts commands we don't want, so set SYSSCREENRC to empty string
d-i preseed/early_command string SYSSCREENRC= screen -d -m /watch-for-ssh
EOF

while getopts v: opt; do
    if [ "$opt" = "v" ]; then
        src=${OPTARG%%:*}
        dst=${OPTARG#*:}
        cp -a "$src" "$workdir/initrd/$dst"
    else
        exit 1
    fi
done
shift $((OPTIND-1))

(cat "$initrd" && cd "$workdir/initrd" && find . | cpio --quiet --format=newc --owner root -o | gzip) > "$workdir/initrd.gz"

# for debugging, replace the first line with -nographic -echr 2, which gives
# you a serial console. Use C-b c to get to the qemu console
qemu-system-mipsel -display none -daemonize -pidfile "$workdir/pid" -serial "file:$cachedir/qemu.log" \
                   -kernel "$kernel" \
                   -initrd "$workdir/initrd.gz" \
                   -append "$append console=ttyS0 auto=true priority=critical DEBIAN_FRONTEND=text" \
                   -m 2048 \
                   -net nic -net user,hostfwd=::12222-:22

nc -l -p 12223
ssh -i "$cachedir/id_rsa" -p 12222 -o NoHostAuthenticationForLocalhost=yes root@localhost "$@"
