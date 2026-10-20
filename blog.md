---
title: "Kubernetes on Immutable AlmaLinux with bootc"
date: 2026-10-20
draft: true
tags: [kubernetes, bootc, almalinux, homelab, raspberry-pi, ansible, cilium]
---

# Kubernetes on Immutable AlmaLinux with bootc


For more than the past 10 years, I've been running servers at home, and have been using plain Docker
containers for a lot of that time, but never managed to find the headspace to figure out Kubernetes on my own.
I could spin up a k3s cluster, _maybe_ get one or two things running, but it never stuck.

In the last two or three years, I've gotten a chance to get into Kubernetes in a work environment. The work
environment comes with the benefit of being able to spend some work time on it, and also some people who can
help answer questions that might come up along the way. (…besides the modern answer of "ask an LLM".)

Last December, I was at Micro Center, and I bought 4 Raspberry Pi 5s (about a month before they increased the
price) and a case to hold them all in a nice cluster. I figured I'd use it for running Kubernetes to prep
for my CKA exam. I built a kubeadm cluster, got a couple things running in it, but kind of let
it get stale. I was also bringing it places with me, and had made some architectural decisions at the start
that I wasn't in love with anymore.

This was about the time that I started learning about [bootc](https://bootc.dev/bootc/), and it felt like an
obvious choice to build my Kubernetes nodes with bootc. I also didn't love how the "you need 3 control planes
for HA" math worked with a 4-node cluster, so I also enlisted the help of two other systems running Proxmox to
run additional control-plane and worker nodes. A huge advantage to bootc for this is that my ARM installation
is functionally identical to my x86 installations.

Today, I run a 9-node Kubernetes cluster at home: 3 control plane nodes and 6 workers. There's one control plane
in the pi-cluster, and one VM on each of two hypervisors. Now that I've gone bootc for my Kubernetes nodes,
I'm never going to even consider any alternatives. Keeping the nodes' operating systems patched, consistent
and recoverable has always been the least fun part, and bootc makes it incredibly easy.

This post walks through
[almalinux-k8s-bootc-cluster](https://github.com/joshgordon/almalinux-k8s-bootc-cluster), my attempt to treat
the node OS the same way I treat everything that runs *on* the cluster: as a container image, built in CI,
versioned, and rolled out deliberately.

## Background

### What is bootc?

The bootc project lets you build a bootable operating system from an ordinary OCI container image. You write a
`Containerfile`, `FROM` a bootc base image, install packages with `dnf`, copy in config files, and push the
result to a registry like any other image. A machine running bootc then *boots* that image.

A few properties fall out of that:

- **The OS is immutable.** `/usr` is read-only at runtime. Changes come from
    building a new image, not from running `dnf install` on the host. `/etc` and `/var` stay writable for
    machine-local state.
- **Updates are atomic.** `bootc upgrade` pulls the new image and stages it as
    a new deployment alongside the current one. The switch happens at reboot; nothing is half-applied.
- **Rollback is one command.** The previous deployment sticks around, so
    `bootc rollback` and a reboot gets you back to the last known-good OS.
- **Every node is identical.** If two machines are on the same image digest,
    they have the same packages, the same kernel, the same config.
- **Your existing tooling works.** It's just a container image: build it with
    Podman or Buildah, store it in any registry, sign it with cosign, keep it current with Renovate.

Under the hood it builds on the same ostree/composefs technology as Fedora CoreOS and Silverblue, but the
interface is a `Containerfile` instead of a custom manifest format.

### Why AlmaLinux?

[AlmaLinux](https://almalinux.org/) is a community-run, RHEL-compatible distribution, and the AlmaLinux
project publishes bootc base images for AlmaLinux 10 — including a Raspberry Pi variant
(`quay.io/almalinuxorg/almalinux-bootc-rpi:10`). That gave me one distro and one image definition across both
architectures in the cluster. They also publish [atomic-ci](https://github.com/AlmaLinux/atomic-ci), a set of
reusable GitHub Actions workflows for building, rechunking and signing bootc images, which this repo uses.

We had briefly evaluated running Kubernetes on something like Talos - but our security tooling requirements
always prevented us from actually pursuing that path. My team hasn't fully evaluated this solution, but we
think we can have immutable OS images for our k8s clusters while still keeping the Cybersecurity team happy.


### Cilium

[Cilium](https://cilium.io/) is the cluster's network plugin (CNI). It uses
eBPF in the kernel for pod networking, and in this setup it also:

- **Replaces kube-proxy**, handling Service load balancing in eBPF instead of
  iptables.
- **Announces the control plane VIP** using L2 announcements (ARP), so there's
  no need for keepalived, kube-vip or an external load balancer in front of
  the API servers.

## Why put these together?

Kubernetes nodes are about the best possible fit for an immutable OS. A node needs a handful of things — a
kernel with the right modules and sysctls, a container runtime, the kubelet, and some storage tooling — and
should otherwise be as boring and interchangeable as possible. Everything interesting runs in containers
anyway.

With bootc, the "node config" is a single `Containerfile` in git:

- Kubernetes packages are pinned to a minor version via a build arg, and
    Renovate opens a PR when a new version ships.
- containerd, kernel modules (`overlay`, `br_netfilter`), sysctls, and the
    host dependencies for [Longhorn](https://longhorn.io/) storage (iSCSI, NFS, cryptsetup) are all baked in.
- CI rebuilds the image daily, so base OS security updates land without me
    touching anything.
- Nodes stage updates automatically but don't reboot without intervention. I've been running
    [Kured](https://kured.dev/) to reboot nodes whenever they have image updates, and that's been working
    beautifully. If an update goes badly, `bootc rollback` is right there.

## What's in the repo

At a high level:

| Piece | What it does |
|---|---|
| `image/Containerfile` | The node image: AlmaLinux 10 bootc + Kubernetes, containerd, Cilium CLI, Longhorn deps, cloud-init |
| `.github/workflows/build.yml` | Builds amd64 and arm64 natively, rechunks, pushes a multi-arch image to GHCR, signs it |
| `.github/workflows/disk-images.yml` | Builds a qcow2 VM disk and a network installer ISO from the image |
| `ansible/bootstrap_bootc_cluster.yml` | Switches hosts to the image and stands up an HA cluster with kubeadm + Cilium |
| `ansible/apply-oidc-login.yml` | Turns on OIDC login for the API server |
| `ansible/get-kubeconfig.yml` | Writes a local kubeconfig that logs in through OIDC via the VIP |
| `renovate.json` | Keeps base images, Kubernetes and cilium-cli current |

### One image, two architectures

The same image tag runs on x86 VMs and Raspberry Pi 5s. The `Containerfile`
picks a base per architecture: the stock AlmaLinux bootc image on amd64, and
the Raspberry Pi bootc image on arm64 with its kernel swapped for a BCM2712
(Pi 5) build from
[almalinux-rpi5-kernel](https://github.com/joshgordon/almalinux-rpi5-kernel). I quickly found that the AlmaLinux default kernel for the rpi image was missing some Pi 5-specific kernel config that Cilium needs, and getting it to re-build the whole kernel was the easiest solution.

## Building a cluster

### Getting the image onto machines

There are a few ways to get a host running the image:

- **qcow2 disk** for VMs, configured with cloud-init user-data.
- **Installer ISO** for bare metal: a small live system that asks for
  hostname, network, user and SSH keys (it can pull keys from a GitHub
  username), then runs `bootc install to-disk`.
- **`bootc switch`** from any existing AlmaLinux bootc host — which is the
  first thing the playbook does anyway.

Fresh installs from an older disk image upgrade themselves to the latest
image on first boot, so a months-old ISO still lands on a current OS.

The qcow2 and ISO are on the
[Releases](https://github.com/joshgordon/almalinux-k8s-bootc-cluster/releases) page.

### Bootstrapping Kubernetes and Cilium

Once you've configured and started your VMs or physical hardware, it's time to configure Kubernetes and Cilium.

First, confirm that you have Ansible installed and can SSH into your new machines. Then, prepare an Ansible
inventory. Here's the one from the test cluster I just provisioned:

```yaml
all:
  vars:
    control_plane_vip: "10.3.14.126"
  hosts:
    testk8s-cp01:
      ansible_host: 10.3.14.66
    testk8s-cp02:
      ansible_host: 10.3.14.67
    testk8s-cp03:
      ansible_host: 10.3.14.68
    testk8s-wk01:
      ansible_host: 10.3.14.69
    testk8s-wk02:
      ansible_host: 10.3.14.70
    testk8s-wk03:
      ansible_host: 10.3.14.71
  children:
    k8s_cluster:
      children:
        k8s_control_plane:
          hosts:
            testk8s-cp01:
            testk8s-cp02:
            testk8s-cp03:
        k8s_workers:
          hosts:
            testk8s-wk01:
            testk8s-wk02:
            testk8s-wk03:
```

Obviously you'll need to put the IPs that you provisioned your VMs with in place of my test VMs' IPs. You'll
also want to pick an open IP address in your subnet to assign to the control plane VIP.

_**time to run**_ - from the ansible/ directory in the repo:

```console
$ ansible-playbook -i inventories/testcluster.yml bootstrap_bootc_cluster.yml

PLAY [Initialize bootc image] **************************************************
....

PLAY RECAP *********************************************************************
testk8s-cp01               : ok=28   changed=12   unreachable=0    failed=0    skipped=4    rescued=0    ignored=0
testk8s-cp02               : ok=7    changed=3    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
testk8s-cp03               : ok=7    changed=3    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
testk8s-wk01               : ok=5    changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
testk8s-wk02               : ok=5    changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
testk8s-wk03               : ok=5    changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```

This playbook will bootstrap a kubeadm cluster on the first control plane, add the rest of the control planes,
add the worker nodes, bootstrap Cilium, and stand up an L2 load balancer within Cilium. It configures Cilium
such that it knows all the API server endpoints that it can use, so it will survive a cold start.

After that's run, you can log into your first control plane node, elevate to root, and confirm that your
cluster is created:

```console
[root@testk8s-cp01 ~]# kubectl get nodes
NAME                        STATUS   ROLES           AGE     VERSION
testk8s-cp01.k8s.internal   Ready    control-plane   6m14s   v1.36.5
testk8s-cp02.k8s.internal   Ready    control-plane   5m4s    v1.36.5
testk8s-cp03.k8s.internal   Ready    control-plane   4m15s   v1.36.5
testk8s-wk01.k8s.internal   Ready    <none>          3m53s   v1.36.5
testk8s-wk02.k8s.internal   Ready    <none>          3m53s   v1.36.5
testk8s-wk03.k8s.internal   Ready    <none>          3m53s   v1.36.5
```

### Configuring OIDC login

I have started using [Authentik](https://goauthentik.io/) for as many services as I can. Kubernetes is no
exception. The first time I configured this, I was shocked at how simple it is.

I have a playbook in this repo to bootstrap the kube-apiserver pieces of OIDC auth. Creating the application
in Authentik is left as an exercise for the reader.

Add your JWT issuer URL, audience, and an OIDC group for Kubernetes admins to apply as the ClusterRoleBinding. These go in the `vars` section of
your inventory:

```yaml
all:
  vars:
    jwt_issuer_url: "https://authentik.company/application/o/k8s/"
    jwt_issuer_aud: "<your ClientID from your OIDC app>"
    oidc_admin_group: "k8s-admins"
```


Run the playbook:

```console
$ ansible-playbook -i inventories/testcluster.yml apply-oidc-login.yml

PLAY [Write the authentication config] *****************************************

TASK [Gathering Facts] *********************************************************
....

PLAY RECAP *********************************************************************
testk8s-cp01               : ok=14   changed=5    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
testk8s-cp02               : ok=9    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
testk8s-cp03               : ok=9    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

The last step is to get a kubeconfig so you can log in. There's a playbook for this as well. You'll need
[kubelogin](https://github.com/int128/kubelogin) for this config to work.

```console
$ ansible-playbook -i inventories/testcluster.yml get-kubeconfig.yml

PLAY [Write a kubeconfig for the cluster] ***********************************************************************

TASK [Check the issuer is set] **********************************************************************************
ok: [testk8s-cp01]

TASK [Read the cluster CA certificate] **************************************************************************
ok: [testk8s-cp01]

TASK [Write the kubeconfig] *************************************************************************************
changed: [testk8s-cp01 -> localhost]

TASK [Show how to use it] ***************************************************************************************
ok: [testk8s-cp01] => {
    "msg": "KUBECONFIG=/Users/josh/.kube/testcluster.yaml kubectl get nodes"
}

PLAY RECAP ******************************************************************************************************
testk8s-cp01               : ok=4    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0

$ KUBECONFIG=/Users/josh/.kube/testcluster.yaml kubectl get nodes
NAME                        STATUS   ROLES           AGE   VERSION
testk8s-cp01.k8s.internal   Ready    control-plane   16m   v1.36.5
testk8s-cp02.k8s.internal   Ready    control-plane   15m   v1.36.5
testk8s-cp03.k8s.internal   Ready    control-plane   14m   v1.36.5
testk8s-wk01.k8s.internal   Ready    <none>          14m   v1.36.5
testk8s-wk02.k8s.internal   Ready    <none>          14m   v1.36.5
testk8s-wk03.k8s.internal   Ready    <none>          14m   v1.36.5
```


## Day-2: updates and rollbacks

Because nodes stage new images on their own, applying an update is just a rolling reboot:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh <node> sudo systemctl reboot
kubectl uncordon <node>
```

`sudo bootc status` shows what's booted and what's staged, and
`sudo bootc rollback` puts the previous deployment back.

I have installed [Kured](https://kured.dev/) on my cluster - it watches for `/var/run/reboot-required` and
drains, reboots, and uncordons the nodes automatically when they ask for a reboot. Since bootc creates that
file when it stages an update, nodes pick up new images on their own.

### Kubernetes upgrades

Kubernetes upgrades are still a thing I'm trying to figure out. I haven't done an upgrade yet, and am waiting
on Cilium to support 1.37 before I attempt an upgrade.

## Wrapping up

Hopefully this has inspired you to give bootc a look. My Kubernetes cluster has been silently humming, and
keeping things running very nicely.

The repo is at
[github.com/joshgordon/almalinux-k8s-bootc-cluster](https://github.com/joshgordon/almalinux-k8s-bootc-cluster),
and the image is published at
`ghcr.io/joshgordon/almalinux-k8s-bootc-cluster:latest`.

If you're interested in rolling this yourself, I would recommend forking my repo and using your own base
image. I can't make promises that the upgrades I decide to roll in won't break your environment, and don't
take any responsibility for your stuff breaking if you decide to use my images.
