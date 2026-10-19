# almalinux-k8s-bootc-cluster

An immutable [bootc](https://containers.github.io/bootc/) image for running
Kubernetes nodes on AlmaLinux 10, plus an Ansible playbook that bootstraps a
highly available cluster from those nodes.

The same image runs on x86_64 VMs and Raspberry Pi 5 boards (arm64). Nodes
boot the OS as a container image, so the OS is updated by pulling a new image,
not by running package updates on each host.

```
ghcr.io/joshgordon/almalinux-k8s-bootc-cluster:latest
```

## Repository layout

| Path | Purpose |
|---|---|
| `image/Containerfile` | The node image |
| `image/*.conf`, `image/*.service`, `image/kubernetes.repo` | Files copied into the image |
| `ansible/bootstrap_bootc_cluster.yml` | Switches hosts to the image and builds the cluster |
| `ansible/inventories/prod.yml` | Hosts, groups and the control plane VIP |
| `.github/workflows/build.yml` | Builds, publishes and signs the image |
| `.github/workflows/disk-images.yml` | Builds a qcow2 VM disk and an installer ISO from the image |
| `.github/workflows/base-image-diff.yml` | Comments RPM changes on base image update PRs |
| `disk/` | bootc-image-builder config for the disk images |
| `renovate.json` | Keeps base images, Kubernetes and cilium-cli up to date |

## The image

The `Containerfile` picks a base per architecture:

- **amd64:** `quay.io/almalinuxorg/almalinux-bootc:10`
- **arm64:** `quay.io/almalinuxorg/almalinux-bootc-rpi:10`, with the stock
  Raspberry Pi kernel replaced by a BCM2712 (Pi 5) kernel from
  [almalinux-rpi5-kernel](https://github.com/joshgordon/almalinux-rpi5-kernel).
  The kernel and initramfs are copied into `/usr/lib/modules/<kver>/` where
  bootc expects them. `cgroup_disable=memory` is removed from the Pi device
  tree boot args so the memory cgroup works for the kubelet.

On top of the base, both architectures get:

- **Kubernetes:** `kubelet`, `kubeadm`, `kubectl` and `cri-tools` from
  `pkgs.k8s.io`, pinned to the minor version in the `k8s_version` build arg.
  The kubelet is enabled.
- **containerd** configured for the systemd cgroup driver, with
  `/var/lib/cni/bin` added to the CNI search path (because `/opt` is read-only
  on a bootc system).
- **Kernel settings:** `overlay` and `br_netfilter` modules, with bridge
  netfilter and IP forwarding turned on.
- **Longhorn prerequisites:** iSCSI initiator, NFS client and `cryptsetup`,
  along with the `iscsi_tcp` and `dm_crypt` modules. The image ships without
  `/etc/iscsi/initiatorname.iscsi`; `iscsi-initiatorname-regen.service`
  creates a unique one on first boot so cloned nodes don't share an iSCSI
  identity.
- **cilium-cli**, installed in `/usr/local/bin`, version pinned by the
  `CILIUM_CLI_VERSION` build arg.
- **cloud-init** and `growpart`, so VMs take their users, SSH keys and
  hostname from user-data and grow the root filesystem to fill the disk.
  On machines with no cloud-init data source, cloud-init does nothing.
- **EPEL and CRB** repositories enabled.
- **Automatic updates without automatic reboots.** A drop-in for
  `bootc-fetch-apply-updates.service` runs `bootc upgrade` without
  `--apply`, so new images are staged and take effect at the next reboot,
  which you control.

The build finishes with `bootc container lint`.

### Building locally

```bash
podman build --platform linux/amd64 -t almalinux-k8s:dev image/
```

## CI

`build.yml` runs on pushes to `main` that touch `image/` or the workflow, on
pull requests (build only, no push), every day at 06:00 UTC, and on demand.

1. Builds the image natively on an amd64 runner and on an arm64 runner.
2. Pushes `:latest-<arch>` and `:<YYYYMMDD>-<arch>` tags.
3. Combines them into multi-arch `:latest` and `:<YYYYMMDD>` tags.
4. Signs `:latest` with cosign (keyless, using GitHub's OIDC identity).

The daily run picks up package updates in the base images even when nothing in
this repo has changed.

### Dependency updates

Renovate keeps these up to date:

- The base image digests (pinned with `@sha256:`), grouped together and
  scheduled for weekday early mornings (America/Chicago). Digest-only updates
  merge automatically.
- The Pi 5 kernel image.
- The Kubernetes minor version and the cilium-cli version, from the
  `# renovate:` comments in the `Containerfile`.

When Renovate changes a base image digest, `base-image-diff.yml` starts both
the old and new images, compares their installed RPMs, and posts the
updated, added and removed packages as a comment on the PR. To run it on an
existing PR, use **Actions → Base image package diff → Run workflow** and enter
the PR number.

### Disk images

`disk-images.yml` builds two amd64 files, attached to the workflow run as
artifacts (kept for 90 days). It runs on the 1st of each month (08:00 UTC,
after that day's image build) and whenever `disk/` changes:

- **`almalinux-k8s-qcow2`:** a VM disk (`disk.qcow2`, 40 GiB virtual,
  sparse), made from the image with
  [bootc-image-builder](https://github.com/osbuild/bootc-image-builder). It
  has no users baked in; give the VM cloud-init user-data with your user, SSH
  key and passwordless sudo, as with the
  [old cloud-init bootstrap](#provisioning-hosts).
- **`almalinux-k8s-iso`:** a network installer (`install.iso`, about 1 GiB)
  for bare metal or VMs without cloud-init. It's AlmaLinux's own `boot.iso`
  with the kickstart in `disk/install.ks` added, and it pulls the node image
  from the registry during the install, so it always installs the current
  image. Before the installer starts, it asks on the console for the
  hostname, the network interface, a static address (IP, prefix length,
  gateway, DNS) or DHCP, a username, and SSH keys. For the keys, you can
  give a GitHub username to import that account's public keys, or paste a
  key. The network is brought up right away for the install, so a static
  address works without any DHCP server. The user gets
  passwordless sudo and no password, so it can only log in with those keys.
  The installer then asks which disk to install to.

Both boot straight into a node that's ready for the bootstrap playbook, with
updates coming from `ghcr.io/joshgordon/almalinux-k8s-bootc-cluster:latest`.
On their first boot, `bootc-first-boot-upgrade.service` upgrades to the
latest image and reboots if a newer one exists, so an older qcow2 or ISO
still ends up current. It only does this on a fresh install (no rollback
deployment yet), so existing nodes never reboot from it.

arm64 disk images aren't built, because the arm64 image only carries the
Raspberry Pi 5 kernel.

To rebuild them by hand: **Actions → Build disk images → Run workflow**.

## Bootstrapping a cluster

### Provisioning hosts

There are two ways to get hosts ready for the playbook:

- **From the disk images above.** Hosts are already running this image.
- **From the cloud-init bootstrap image.** Boot a VM from
  [`base-cloud-init`](https://github.com/joshgordon/immutable-os/tree/main/images/base-cloud-init)
  in the old [immutable-os](https://github.com/joshgordon/immutable-os) repo
  (`ghcr.io/joshgordon/immutable-os/base-cloud-init`). That's a minimal
  AlmaLinux bootc image with cloud-init and growpart. The playbook's first
  step then runs `bootc switch` to move it onto this image.

### Prerequisites

- Hosts running an AlmaLinux bootc image (see above), reachable over SSH by
  Ansible with sudo.
- A free IP on the node network to use as the control plane VIP.
- If the ghcr.io package is private, credentials on each host to pull it.

### Inventory

`ansible/inventories/prod.yml` defines:

- `control_plane_vip`: the address clients use for the Kubernetes API.
- `k8s_control_plane`: the control plane nodes. The first one listed
  initializes the cluster.
- `k8s_workers`: the worker nodes.

### Running it

```bash
cd ansible
ansible-playbook -i inventories/prod.yml bootstrap_bootc_cluster.yml
```

The playbook runs these steps in order, and skips any step that's already
done:

1. **Switch every host to the image** with `bootc switch` and reboot the
   hosts that changed.
2. **Initialize the first control plane node** with `kubeadm init`, without
   kube-proxy (Cilium replaces it). The VIP is added to that node's interface
   temporarily so `kubeadm` can reach the API through it before anything
   else announces it.
3. **Join the other control plane nodes** one at a time, then **join the
   workers**.
4. **Install Cilium** with kube-proxy replacement, L2 announcements and
   external IPs turned on.
5. **Hand the VIP over to Cilium.** The playbook creates a LoadBalancer
   Service for the API servers, an IP pool containing only the VIP, and an L2
   announcement policy limited to control plane nodes. Then it removes the
   temporary VIP from the first node.
6. **Wait for every node to be Ready**, then print the node list and the
   Cilium status.

#### How Cilium reaches the API server

Cilium announces the VIP, so it can't depend on the VIP to talk to the API
server. Otherwise, if the VIP were down, Cilium couldn't come up to bring it
back. The playbook passes Cilium the direct address of every control plane
node through `k8s.apiServerURLs`. It builds that list from each node's
`ansible_default_ipv4.address` fact, so it updates whenever the inventory
changes.

The facts are collected in the first play, which runs against `all`. If you
run with `--limit`, include every control plane host or this lookup will fail.

## Day-2 operations

- **OS and Kubernetes patch updates:** the nodes stage new images on their
  own. Drain and reboot each node to apply them:
  ```bash
  kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
  ssh <node> sudo systemctl reboot
  kubectl uncordon <node>
  ```
- **Check what's staged:** `sudo bootc status`.
- **Roll back:** `sudo bootc rollback`, then reboot.
- **Kubernetes minor upgrades:** a new `k8s_version` in the image only updates
  the packages. You still need to run the normal `kubeadm upgrade` steps.
