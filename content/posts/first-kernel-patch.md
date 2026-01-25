+++
title = "my first patch to the linux kernel"
date = 2026-01-23
updated = 2026-01-23
draft = false

[taxonomies]
categories = ["posts"]
tags= ["linux", "kvm", "virtualization", "intel vt-x"]

[extra]
lang = "en"
toc = true
comment = true
copy = true
math = true
mermaid = false
outdate_alert = false
outdate_alert_days = 120
display_tags = true
truncate_summary = false
featured = false
+++

How a sign-extension bug in C made me pull my hair for days but became my first patch to the Linux kernel!

<!-- more -->

## Intro

A while ago, I started tipping my toe into virtualization. It's a topic that many people have heard of or are using on a daily basis but a few know how it works under the hood, myself included.

I like to learn by reinventing the wheel, and naturally, to learn virtualization I started by trying to build a [Type-2 hypervisor](https://en.wikipedia.org/wiki/Hypervisor#Classification). This approach is similar to how [KVM](https://en.wikipedia.org/wiki/Kernel-based_Virtual_Machine) (Linux) or [bhyve](https://en.wikipedia.org/wiki/Bhyve) (FreeBSD) are built.

Since virtualization is hardware assisted these days [^1], the hypervisor needs to communicate directly with the CPU by running certain privileged instructions; which means a Type-2 hypervisor is essentially a [Kernel Module](https://en.wikipedia.org/wiki/Loadable_kernel_module) that exposes an API [^2] to the user-space where a Virtual Machine Monitor (VMM) [^3] like [QEMU](https://www.qemu.org/) or [Firecracker](https://firecracker-microvm.github.io/) is running and orchestrating VMs by utilizing that API.

I believe the process that led me to realize there was a bug in the kernel code (more specifically, in the KVM selftests) is more interesting than the bug itself and has significant learning potentials, which is why I thought it was worth writing a blog post about it.

## Linux and x86 TR register

---

[^1]: Check out my previous post for more details: [virtualization: theory to silicon](https://pooladkhay.com/posts/virt-theory-silicon/)

[^2]: KVM API documentation: [https://docs.kernel.org/virt/kvm/api.html](https://docs.kernel.org/virt/kvm/api.html)

[^3]: Hypervisor and Virtual Machine Monitor (VMM) are generally interchangeable terms, while some might differentiate them slightly (e.g. VMM as user-space part of a kernel-space hypervisor).
