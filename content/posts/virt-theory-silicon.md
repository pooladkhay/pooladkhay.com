+++
title = "virtualization: theory to silicon"
date = 2025-11-20
updated = 2025-12-26
draft = false

[taxonomies]
categories = ["posts"]
tags= ["virtualization", "intel vt-x", "paper"]

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

A description of the modern virtualization; starting from Popek and Goldberg and getting all the way to the implementation of the Intel VT-x (VMX) extension.

<!-- more -->

## Intro

It's not a stretch to claim that virtualization is the technology that makes the modern digital world possible!<br>
According to [Wikipedia](https://en.wikipedia.org/wiki/Virtualization):

{% quote() %}
Virtualization (abbreviated v12n) is a series of technologies that allows dividing of physical computing resources into a series of virtual machines, operating systems, processes or containers.
{% end %}

Unless you are reading a printed copy of this post, you are already using and benefiting from some form of virtualization. The operating system on your device virtualizes CPU and memory, making them available to processes like your web browser and giving each the illusion that it owns and controls the entire hardware. This abstraction also isolates processes so they cannot interfere with one another.

If you use public cloud services such as Google Cloud or AWS, virtualization plays an even more prominent role. The classic example is a Virtual Machine (VM) instance, but in practice, nearly all serverless and managed services are also backed by VMs which are isolated, fully featured operating system instances that share the same underlying hardware.

This blog post focuses on full hardware virtualization (the technology that gives rise to VMs), by drawing some historical context, then giving an intuitive explanation of the theory behind it, and finally how Intel turned a non-classically-virtualizable architecture into a virtualizable one.

## Historical context

In the dawn of computing, time-sharing and virtualization realized to be practical solutions to three critical needs:

- _System utilization_: making expensive computers more cost-effective by sharing them,
- _Isolation_: preventing interference between users,
- _Security_: allowing users with different clearance levels to work on the same machine.

_Compatibility_ was another issue, and a famous example is [IBM System/360](https://en.wikipedia.org/wiki/IBM_System/360) which was an attempt to merge various incompatible lines of business and scientific-oriented machines into a single family of computers. That eventually led to [IBM System/360 Model 67](https://en.wikipedia.org/wiki/IBM_System/360_Model_67) along with its hypervisor and operating system [CP/CMS](https://en.wikipedia.org/wiki/CP/CMS).

CP, the _Control Program_, created the virtual machine environment and provided each user with a simulated stand-alone System/360 computer. And CMS, the _Cambridge Monitor System_ [^1] was a lightweight single-user operating system, that ran on top of CP's virtual machines.
This allowed a great number of simultaneous users to share a single physical S/360 machine. And bear in mind that we are talking about 1960s!

Now we are in this era where some systems support virtualization natively and some don't. For a few organizations - the U.S. Air Force and the Atomic Energy Commission to be more specific - this was of high importance which was why they were funding research to find a new, verifiable way to build secure systems.

In 1974 Gerald J. Popek and Robert P. Goldberg published a [seminal paper](https://dl.acm.org/doi/10.1145/361011.361073) on _Formal Requirements for Virtualizable Third Generation [^2] Architectures_, with this abstract:
{% quote(cite="Gerald J. Popek and Robert P. Goldberg") %}
Virtual machine systems have been implemented on a limited number of third generation computer systems, e.g. CP-67 on the IBM 360/67. From previous empirical studies, it is known that certain third generation computer systems, e.g. the DEC PDP-10, cannot support a virtual machine system. In this paper, model of a third-generation-like computer system is developed. Formal techniques are used to derive precise sufficient conditions to test whether such an architecture can support virtual machines.
{% end %}

## Theory

Popek and Goldberg define a Virtual Machine to be an _efficient_, _isolated_ _duplicate_ of the real machine and they explain these notions through the idea of a _Virtual Machine Monitor_ (VMM).

The VMM software has three main characteristics:

1. To provide an _essentially identical_ environment to the guests. This excludes resource availability such as amount of memory and timing requirements due to the intervening level of software and because of the effect of any other virtual machines concurrently existing on the same hardware.
2. To be _efficient_, meaning that a statistically dominant subset of the virtual processor's instructions must be executed directly by the real processor, with no software intervention by the VMM. This statement rules out traditional emulators and complete software interpreters (simulators) from the virtual machine umbrella.
3. To have _control over the system resources_ in such a way that it is not possible for a program running under VMM in the created environment to access any resource not explicitly allocated to it, and it is possible for the VMM to regain control of resources already allocated.

### The model

Then they define a simplified version of a third-generation machine as a 4-tuple while assuming that I/O instructions and interrupts don't exist [^3]:

$S = (E, M, P, R)$

- $S$ represents the current state of the real machine (not a virtual machine).
- $E$ (Executable storage) represents the contents of the machine's memory (RAM).
- $M$ (Mode) represents the two possible modes of operation in this model: _Supervisor_ and _User_.
- $P$ (Program counter) is a register that holds the memory address of the next instruction to be executed.
- $R$ (Relocation-bounds register) represents the set of privileged registers that define the current accessible address space. They control which parts of the memory ($E$) the program (virtual OS) is allowed to see and modify.<br>
  In modern terms, this would be registers and that hold page table information (e.g. CR3 register on x86, and segment registers when executing in protected mode).

Describing an abstracted model of a machine is a very powerful tool in the sense that it lets us reason about the behavior of the machine without needing to know the exact state of the hardware or the actual physical implementation.

### Instructions

In this model, instructions act on the state of the machine transitioning it from one state to another one, and live under one of three main categories:

- **Privileged instructions**: Any instruction that traps [^4] to the Supervisor mode when executed in the User mode.
- **Sensitive instructions**
  - **Control sensitive**: Any instruction that when executed, changes the mode ($M$) of the processor or the value of the Relocation-bounds register ($R$) or both.<br>Intuitively, we can think of the control sensitive group as instructions that **change** the privileged state of the processor or **write** to some memory location that is not allocated to them.<br>An example is `LIDT` instruction on x86 that changes the value of the interrupt descriptor table register.
  - **Behavior sensitive**: Any instruction that the effect of its execution depends on the mode ($M$) of the processor or on the value of the Relocation-bounds register ($R$) or both.<br>We can think of them as instructions that **reveal** the privileged state of the processor or **read** from a memory location that is not allocated to them.<br>An example is `SIDR` instruction on x86 which can be used to reveal the interrupt descriptor table base address and limit.

- **Innocuous instructions**: Any instruction that is neither Privileged nor Sensitive.

This categorization helps with reasoning about the effect(s) of executing a given instruction.

### Main Theorem

Now that we are familiar with the model of the machine and various types of instructions, we are ready to get to the actual requirement for virtualization:

{% quote(cite="Theorem 1") %}
For any conventional third generation computer, a virtual machine monitor (VMM) may be constructed if the set of sensitive instructions for that computer is a subset of the set of privileged instructions.
{% end %}

Intuitively, this means that we can build and run a classic VMM [^5] on any machine where all sensitive instructions are privileged, i.e. executing them would trap and transfer control back to the VMM.<br>
This simple but foundational rule ensures that guests cannot access or modify the state of the VMM or other guests on the machine, and are bound to the resources that were specifically allocated to them.

But what about efficiency? I'm glad you asked!

To be efficient, the requirement is that all _Innocuous instructions_ which are the majority of instructions, be executed directly on the CPU without any traps or interventions from the VMM.

If a machine satisfies these rules, we can build an _efficient_ VMM such that guests run in an _essentially identical_ environment to the host while the VMM maintains _control over the system resources_.

## Practice

The x86 instruction set architecture contains 18 instructions that are sensitive but not privileged [^6]. As a result, based on the Popek and Goldberg's work, it's not possible to build an efficient classic [^5] VMM for it.

### Rings of power

Before getting into the solution, lets make sure we're all on the same page regarding the x86 protection rings and how CPU operates from that perspective.

The architecture defines four protection rings: 0, 1, 2, and 3. Ring 0 is the most and Ring 3 is the least privileged. Modern operating systems only use Ring 0 and 3, where the OS kernel runs in Ring 0 and user-space programs run in Ring 3.

To be able to run multiple operating systems on a x86 CPU, all four Rings must be virtualized so that the resulting environment is identical to the physical hardware.

You may ask why can't we just run the host kernel in Ring 0 and guest kernel(s) on a lower Ring like 1 and call it a day?! Well, that's a valid question but it's not that simple!

### x86 is in trouble

In reality, a few of the non-privileged sensitive instruction do become privileged in rings lower that 0, which is what we want, but some of them still don't behave! And again we are left with sensitive instructions that are not privileged, hence the architecture doesn't satisfy Popek and Goldberg's requirements, even in lower rings.

An example is the [`POPF`](https://www.felixcloutier.com/x86/popf:popfd:popfq) which is a _Control sensitive_ instruction that pops the top of stack into the [FLAGS](https://en.wikipedia.org/wiki/FLAGS_register) register. OS kernels use this instruction regularly but it silently fails (updates math flags e.g. ZF, but ignores interrupt flag) when executed in a Ring lower than 0.

To better illustrate the problem, lets also consider these three instructions that you might already be familiar with: [`SGDT`](https://www.felixcloutier.com/x86/sgdt), [`SIDT`](https://www.felixcloutier.com/x86/sidt), and [`SLDT`](https://www.felixcloutier.com/x86/sldt).

If the OS in a VM (virtual OS) uses `SGDT`, `SLDT`, or `SIDT` to reference the contents of the GDTR (Global Descriptor Table Register), LDTR (Local Descriptor Table Register), or IDTR (Interrupt Descriptor Table Register) the register contents that are applicable to the host OS, VMM, or another virtual OS will be revealed. This could cause a problem if the virtual OS tries to use these values for its own operations.<br>
Therefore, each virtual OS must be provided with a separate set of IDTR, LDTR, and GDTR registers.

Unfortunately, in practice, it's not possible to have dedicated sensitive registers per virtual OS. This would mean that the CPU die must physically include these registers, which would translate into having a hard limit on the number of VMs a given CPU can support, as well as making each CPU way more expensive.

But fear not my child [^7] as there is a better solution!

What if we stayed at Ring 0 where kernels expect to find themselves, but made all sensitive instructions privileged?<br>
(And I hope you’re asking: "_But if the kernel is already in Ring 0, where would it trap to?_")

### Enter VT-x extension

In [2005](<https://en.wikipedia.org/wiki/X86_virtualization#Intel_virtualization_(VT-x)>), with the launch of two Pentium 4 models (662 and 672) Intel announced the VT-x (VMX) extension.

When software enables the extension by executing the [`VMXON`](https://www.felixcloutier.com/x86/vmxon) instruction, CPU enters the "**VMX Root**" mode. From an operational point of view, it is _almost_ identical to how the CPU was operating before, but it introduces a new, orthogonal state: "**VMX Non-Root**" mode.

In the VMX Non-Root mode, the virtualization holes are plugged: Sensitive instructions become privileged and trigger traps, while the Guest OS still has full access to the four protection rings, letting it run in Ring 0 and run its user-space programs in Ring 3 as it would normally do.<br>
In this mode, instructions that would cause a user-space program to trap into the kernel (Ring 3 to 0) e.g. [`SYSCALL`](https://www.felixcloutier.com/x86/syscall), still behave the same way, but executing a sensitive instructions would trap into the VMX Root mode and transfer control back to the VMM/hypervisor.

And with that, the architecture now conforms to the [Main Theorem](#main-theorem)!

### VMCS (the leash)

In the [x86 is in trouble](#x86-is-in-trouble) section we concluded that each virtual operating system must be provided with a separate set of sensitive registers to operate independently, and that it's not feasible to have these registers baked into the silicon.

To facilitate that, Intel introduced the notion of VMCS (Virtual Machine Control Structure) that is a region of memory allocated by the hypervisor before entering VMX non-root mode.<br>
VMCS consists of four main areas:

- Host-state area
- Guest-state area
- Control fields
- VM-exit information area

The idea is relatively simple: Prior to entering the VMX non-root mode, hypervisor saves the current state of the CPU in the _Host-state area_, loads the desired state of the guest into the _Guest-state area_, and finally defines the expected behavior for the CPU while in non-root mode (e.g. which instructions or events should cause a switch to the VMX root mode) into the _Control fields_ of the VMCS.

When exiting from non-root to root mode, the guest state is saved back to the VMCS, host state is loaded into the CPU registers, and the reason of exit is written into the VM-exit information area. The exit information is later used by the hypervisor to decide what would be the next appropriate action to take before switching back to the guest.

By allocating a VMCS per virtual CPU (vCPU), the hypervisor controls/virtualizes the physical CPU, making it possible to run multiple operating systems in isolation and giving each the illusion that they have a few dedicated CPU cores, while operating on a limited number of actual physical cores [^8].

## Outro

All other major CPU vendors have implemented the same theory and concepts but in slightly different ways. AMD has **AMD-V**, Arm has **EL2**, and RISC-V has **H-extension**.

Every tool and piece of technology that we take for granted today, didn't appear over night. Yes, sometimes it was an accidental discovery but most of the times it's about people who were trying to solve a specific problem that eventually came up with an idea. Further more, original ideas are a lot simpler than the complexity we observe today, since they don't include years and years of time and effort that has refined and reshaped them.

Personally, I have always found the history and theory behind a tool way more interesting than the tool itself. It gives me the ability to see the beauty and simplicity behind the idea and not to get overwhelmed by the current complex state of it, which ultimately translates into being able to easily understand and reason about it.

Hopefully, next time a Cloud provider asks you to choose the number of vCPUs for a VM, you have a better idea of what's going on under the hood.

## Further reading

[Virtual Machines](https://www.oreilly.com/library/view/virtual-machines/9781558609105/) by Jim Smith and Ravi Nair.

---

[^1]: also _Console Monitor System_ but eventually renamed to [_Conversational Monitor System_](https://en.wikipedia.org/wiki/Conversational_Monitor_System).

[^2]: [More](https://www.geeksforgeeks.org/computer-science-fundamentals/third-generation-of-computers/) about third generation of computers.

[^3]: [Formal virtualization requirements for the ARM architecture](https://dl.acm.org/doi/10.1016/j.sysarc.2013.02.003) published in 2013 builds on Popek and Goldberg's work and extends their machine model to modern architectures with paged virtual memory, I/O and interrupts.

[^4]: When a trap happens, the processor automatically saves the current state of the machine and passes the control to a pre-specified routine by changing the processor mode, the relocation-bounds register, and the program counter.

[^5]: I say classic because some machines, like the PDP-10, are not classically virtualizable. However, based on Popek and Goldberg’s second theorem, a hybrid virtual machine monitor (HVM) can still be constructed for them under another set of constraints. Additionally, there are other methods like binary translation where the VMM intercepts and rewrites guest OS code at runtime which are beyond the scope of this post.

[^6]: ["Analysis of the Intel Pentium's Ability to Support a Secure Virtual Machine Monitor"](http://www.usenix.org/events/sec2000/robin.html) by John Scott Robin and Cynthia E. Irvine.

[^7]: I'm not really your father, sorry for disappointing you and for the tacky humor.

[^8]: This concept is very similar to how an operating system internally switches between multiple processes. The main difference is that an operating system does the virtualizes at Ring 3 (user-space), while hypervisors virtualize all four rings with some help form the hardware itself.
