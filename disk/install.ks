# Kickstart for the installer ISO (AlmaLinux boot.iso + this file, via mkksiso).
#
# %pre asks on the console (tty5) for the hostname, a static network setup, a
# username and SSH keys. It brings the address up straight away, so the GitHub
# key lookup and the image pull work without DHCP, then writes the matching
# kickstart commands to /tmp/ks-user.ks for the %include below. There are no
# storage directives, so Anaconda asks which disk to install to rather than
# wiping one on its own.

ostreecontainer --url=ghcr.io/joshgordon/almalinux-k8s-bootc-cluster:latest --transport=registry --no-signature-verification

%pre --interpreter=/bin/bash --erroronfail
exec < /dev/tty5 > /dev/tty5 2>&1
chvt 5

octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
ipv4="(${octet}\.){3}${octet}"
ipv4_re="^${ipv4}\$"

ask() {  # ask <var> <prompt> <regex> [default]
  local reply
  while :; do
    read -rp "$2${4:+ [$4]}: " reply || exit 1
    reply=${reply:-$4}
    [[ "$reply" =~ $3 ]] && break
    echo "  Invalid value."
  done
  printf -v "$1" '%s' "$reply"
}

prefix_to_mask() {
  local bits=$(( 0xffffffff ^ ((1 << (32 - $1)) - 1) ))
  echo "$(( bits >> 24 & 255 )).$(( bits >> 16 & 255 )).$(( bits >> 8 & 255 )).$(( bits & 255 ))"
}

echo
echo "=== almalinux-k8s node setup ==="
echo

ask hostname "Hostname (FQDN)" '^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,252}[a-zA-Z0-9])?$'

echo
echo "Network interfaces:"
default_if=""
for path in /sys/class/net/*; do
  dev=${path##*/}
  [[ "$dev" == lo || ! -e "$path/device" ]] && continue
  carrier=$(cat "$path/carrier" 2>/dev/null)
  [[ "$carrier" == 1 ]] && state="link up" || state="no link"
  [[ -z "$default_if" && "$carrier" == 1 ]] && default_if=$dev
  echo "  $dev  $(cat "$path/address")  $state"
done
ask iface "Interface" '^[a-zA-Z0-9._-]+$' "$default_if"
ask ip "IP address" "$ipv4_re"
ask prefix "Prefix length" '^([1-9]|[12][0-9]|3[0-2])$' 24
ask gateway "Gateway" "$ipv4_re"
ask dns "DNS servers (comma-separated)" "^${ipv4}(,${ipv4})*\$" "$gateway"

# Bring the address up now for the key lookup and the image pull.
nmcli connection add type ethernet ifname "$iface" con-name ks-static \
  ipv4.method manual ipv4.addresses "${ip}/${prefix}" ipv4.gateway "$gateway" \
  ipv4.dns "${dns//,/ }" ipv6.method disabled >/dev/null
nmcli connection up ks-static >/dev/null || echo "  Couldn't bring up ${iface}; continuing."

echo
ask user "Username to create" '^[a-z_][a-z0-9_-]{0,31}$'
while [[ "$user" == root ]]; do
  echo "  Pick a user other than root."
  ask user "Username to create" '^[a-z_][a-z0-9_-]{0,31}$'
done

keys=""
while [[ -z "$keys" ]]; do
  read -rp "GitHub username to import SSH keys from (blank to paste a key): " ghuser || exit 1
  if [[ -n "$ghuser" ]]; then
    keys=$(curl -fsSL --max-time 20 "https://github.com/${ghuser}.keys") || echo "  Couldn't fetch keys for ${ghuser}."
    [[ -z "$keys" ]] && echo "  No keys found for ${ghuser}."
  else
    read -rp "SSH public key: " keys || exit 1
    [[ "$keys" =~ ^(ssh-|ecdsa-|sk-) ]] || { echo "  That doesn't look like a public key."; keys=""; }
  fi
done

{
  echo "network --device=${iface} --bootproto=static --ip=${ip} --netmask=$(prefix_to_mask "$prefix") --gateway=${gateway} --nameserver=${dns} --noipv6 --hostname=${hostname} --onboot=yes --activate"
  echo "user --name=${user} --groups=wheel --lock"
  while read -r key; do
    [[ -n "$key" ]] && echo "sshkey --username=${user} \"${key}\""
  done <<< "$keys"
  echo "%post"
  echo "echo '${user} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${user}"
  echo "chmod 0440 /etc/sudoers.d/${user}"
  echo "%end"
} > /tmp/ks-user.ks

echo
echo "  Host:    ${hostname}"
echo "  Network: ${iface} ${ip}/${prefix} via ${gateway}, DNS ${dns}"
echo "  User:    ${user} with $(grep -c ^sshkey /tmp/ks-user.ks) SSH key(s)"
echo
read -rp "Press Enter to continue the install..." _
%end

%include /tmp/ks-user.ks

# No DHCP anywhere: don't let NetworkManager auto-create DHCP profiles for
# other ports, and keep cloud-init (no data source on bare metal) away from
# the network config.
%post
cat > /etc/NetworkManager/conf.d/90-no-auto-default.conf <<'EOF'
[main]
no-auto-default=*
EOF
cat > /etc/cloud/cloud.cfg.d/90-iso-install.cfg <<'EOF'
network: {config: disabled}
EOF
%end
