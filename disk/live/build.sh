#!/usr/bin/bash
# Called by the Containerfile. Boot setup follows AlmaLinux atomic-ci's
# .github/actions/build-iso/live/build.sh.
set -xeuo pipefail

: "${IMAGE_REF:?}"
ISO_LABEL="almalinux-k8s-installer"

# /root is a symlink into /var, which is empty in the image
mkdir -p "$(realpath /root)"

dnf install -y \
    dracut-live \
    grub2-efi-x64-cdboot \
    isomd5sum \
    squashfs-tools \
    xorriso
dnf clean all

### Boot

# The initramfs has to be able to find and mount the squashfs in the ISO
KERNEL="$(basename /usr/lib/modules/*)"
DRACUT_NO_XATTR=1 dracut --force --zstd --reproducible --no-hostonly \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    "/usr/lib/modules/${KERNEL}/initramfs.img" "${KERNEL}"

# image-builder takes shim and grub from /boot/efi, bootc images keep them in the bootupd directory
mkdir -p /boot/efi/EFI
cp -av /usr/lib/bootupd/updates/EFI/. /boot/efi/EFI/

mkdir -p /usr/lib/image-builder/bootc
cat > /usr/lib/image-builder/bootc/iso.yaml <<EOYAML
label: "${ISO_LABEL}"
grub2:
  timeout: 5
  entries:
    - name: "Install almalinux-k8s node"
      linux: "/images/pxeboot/vmlinuz root=live:CDLABEL=${ISO_LABEL} rd.live.image enforcing=0 quiet loglevel=3"
      initrd: "/images/pxeboot/initrd.img"
    - name: "Install almalinux-k8s node (basic graphics mode)"
      linux: "/images/pxeboot/vmlinuz root=live:CDLABEL=${ISO_LABEL} rd.live.image enforcing=0 quiet loglevel=3 nomodeset"
      initrd: "/images/pxeboot/initrd.img"
EOYAML

### Live system

# Not booted from a bootc deployment, so it can't update itself
systemctl disable bootc-fetch-apply-updates.timer rpm-ostreed-automatic.timer || :

# / is an overlay backed by RAM, which podman can't stack its own overlays on,
# and ostree needs room in /var/tmp while installing. Give both their own tmpfs.
for dir in /var/lib/containers /var/tmp; do
    unit="$(systemd-escape --path "${dir}").mount"
    cat > "/usr/lib/systemd/system/${unit}" <<EOUNIT
[Unit]
Description=Live system tmpfs for ${dir}

[Mount]
What=tmpfs
Where=${dir}
Type=tmpfs
Options=size=75%,nr_inodes=1m

[Install]
WantedBy=local-fs.target
EOUNIT
    systemctl enable "${unit}"
done

### Installer

install -m 0755 /ctx/k8s-node-installer /usr/libexec/k8s-node-installer
sed "s|@IMAGE_REF@|${IMAGE_REF}|" /ctx/k8s-node-installer.service \
    > /usr/lib/systemd/system/k8s-node-installer.service
systemctl enable k8s-node-installer.service
