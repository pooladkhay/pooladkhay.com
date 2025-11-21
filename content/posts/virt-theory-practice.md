+++
title = "Virtualization: From Popek and Goldberg to Intel VT-x"
date = 2025-11-20
updated = 2025-11-20
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

A description of the theory behind modern virtualization and how it is implemented in practice, specifically in the context of Intel VT-x (VMX) technology.

<!-- more -->

## Intro

In the dawn of computing, time-sharing and virtualization realized to be practical solutions to three critical needs:

- _System utilization_: making expensive computers more cost-effective by sharing them,
- _Isolation_: preventing interference between users,
- _Security_: allowing users with different clearance levels to work on the same machine.

_Compatibility_ was another issue, and a famous example is [IBM System/360](https://en.wikipedia.org/wiki/IBM_System/360) which was an attempt to merge various incompatible lines of business and scientific-oriented machines into a single family of computers. That eventually led to [IBM System/360 Model 67](https://en.wikipedia.org/wiki/IBM_System/360_Model_67) along with its hypervisor and operating system [CP/CMS](https://en.wikipedia.org/wiki/CP/CMS).<br>
CP, the _Control Program_, created the virtual machine environment and provided each user with a simulated stand-alone System/360 computer.<br>
CMS, the _Cambridge Monitor System_ [^1] was a lightweight single-user operating system, for interactive time-sharing use. By running many copies of CMS in CP's virtual machines - instead of multiple copies of large, traditional multi-tasking OS - the overhead per user was less. This allowed a great number of simultaneous users to share a single S/360.<br>
And bear in mind that we are talking about 1960s!

Now we are in this era where some systems support virtualization natively and some don't. For a few organizations - the U.S. Air Force and the Atomic Energy Commission to be more specific - this was of high importance which was why they were funding research to find a new, verifiable way to build secure systems.

In 1974 Gerald J. Popek and Robert P. Goldberg published a seminal paper on [_Formal Requirements for Virtualizable Third Generation Architectures_](https://dl.acm.org/doi/10.1145/361011.361073).

Here is the papers abstract:
{% quote(cite="Gerald J. Popek and Robert P. Goldberg") %}
Virtual machine systems have been implemented on a limited number of third generation computer systems, e.g. CP-67 on the IBM 360/67. From previous empirical studies, it is known that certain third generation computer systems, e.g. the DEC PDP-10, cannot support a virtual machine system. In this paper, model of a third-generation-like computer system is developed. Formal techniques are used to derive precise sufficient conditions to test whether such an architecture can support virtual machines.
{% end %}

In this blog post, I don’t plan to go into the formal proofs—that’s what the paper is for. Instead, I’ll give an intuitive explanation of virtualization and how Intel turned a non-classically-virtualizable architecture into a virtualizable one.

## Requirements

Popek and Goldberg define a Virtual Machine to be an _efficient_, _isolated_ _duplicate_ of the real machine and they explain these notions through the idea of a _Virtual Machine Monitor_ (VMM).

The VMM software has three essential characteristics:

1. To provide an _essentially identical_ environment to the guests. This excludes resource availability such as amount of memory and timing requirements due to the intervening level of software and because of the effect of any other virtual machines concurrently existing on the same hardware.
2. To be _efficient_, meaning that a statistically dominant subset of the virtual processor's instructions must be executed directly by the real processor, with no software intervention by the VMM. This statement rules out traditional emulators and complete software interpreters (simulators) from the virtual machine umbrella.
3. To have _control over the system resources_ in such a way that it is not possible for a program running under VMM in the created environment to access any resource not explicitly allocated to it, and it is possible for the VMM to regain control of resources already allocated.

### The model

Then they define a simplified version of a third-generation machine as a 4-tuple while assuming that I/O instructions and interrupts don't exist [^2]:

$S = (E, M, P, R)$

- $S$ represents the current state of the real machine, not a virtual machine.
- $E$ (Executable storage) represents the contents of the machine's memory (RAM).
- $M$ (Mode) represents the two possible modes of operation in this model: _Supervisor_ and _User_.
- $P$ (Program counter) is a register that holds the memory address of the next instruction to be executed.
- $R$ (Relocation-bounds register) represents the set of privileged registers that define the current accessible address space. They control which parts of the memory ($E$) the program is allowed to see and modify.<br>
  In modern terms, this would be registers and that hold page table information.

### Instructions

In this model, instructions act on the state of the machine transitioning it from one state to another one, and live under one of three main categories:

- **Privileged instructions**: Any instruction that traps [^3] to the Supervisor mode when executed in the User mode.
- **Sensitive instructions**
  - _Control sensitive_: Any instruction that when executed, changes the mode ($M$) of the processor or the value of the Relocation-bounds register ($R$) or both.<br>Intuitively, we can think of the _Control sensitive_ group as instructions that **change** the privileged state of the processor or **write** to some memory location that is not allocated to them.<br>An example is `LIDT` that changes the value of the interrupt descriptor table register.
  - _Behavior sensitive_: Any instruction that the effect of its execution depends on the mode ($M$) of the processor or on the value of the Relocation-bounds register ($R$) or both.<br>We can think of them as instructions that **reveal** the privileged state of the processor or **read** from a memory location that is not allocated to them.<br>An example is `SIDR` which can be used to reveal the interrupt descriptor table base address and limit.

- **Innocuous instructions**: Any instruction that is neither Privileged nor Sensitive.

### Main Theorem

Now that we are familiar with the model of the machine and various types of instructions, we are ready to get to the actual requirement for virtualization:

{% quote(cite="Theorem 1 - Gerald J. Popek and Robert P. Goldberg") %}
For any conventional third generation computer, a virtual machine monitor (VMM) may be constructed if the set of sensitive instructions for that computer is a subset of the set of privileged instructions.
{% end %}

We can build and run a classic VMM [^4] on any machine where all sensitive instructions are privileged, i.e. executing them would trap and transfer control back to the VMM.<br>
This simple but foundational rule ensures that guests cannot access or modify the state of the VMM or other guests on the machine.

But what about efficiency?<br>
I'm glad you asked! The requirement is that all _Innocuous instructions_ be executed directly on the CPU without any intervention from the VMM.

If a machine satisfies these rules, we can build an _efficient_ VMM such that guests run in an _essentially identical_ environment to the host while the VMM maintains _control over the system resources_.

## x86 is in trouble!

As you might have already guessed, the x86 instruction set architecture of the Intel Pentium processor contained 18 instructions that were sensitive but not privileged [^5]. As a result, it was not possible to build an efficient VMM for it.

### Sensitive register instructions

[more details]

Read or change sensitive registers or memory locations such as a clock register or interrupt registers:

- [`SGDT`](https://www.felixcloutier.com/x86/sgdt), [`SIDT`](https://www.felixcloutier.com/x86/sidt), [`SLDT`](https://www.felixcloutier.com/x86/sldt)
- [`SMSW`](https://www.felixcloutier.com/x86/smsw)
- [`PUSHF`](https://www.felixcloutier.com/x86/pushf:pushfd:pushfq), [`POPF`](https://www.felixcloutier.com/x86/popf:popfd:popfq)

### Protection system instructions

[more details]

Reference the storage protection system, memory or address relocation system:

- [`LAR`](https://www.felixcloutier.com/x86/lar), [`LSL`](https://www.felixcloutier.com/x86/lsl), [`VERR`](https://www.felixcloutier.com/x86/verr:verw), [`VERW`](https://www.felixcloutier.com/x86/verr:verw)
- [`POP`](https://www.felixcloutier.com/x86/pop)
- [`PUSH`](https://www.felixcloutier.com/x86/push)
- [`CALL`](https://www.felixcloutier.com/x86/call) (far variant), [`JMP`](https://www.felixcloutier.com/x86/jmp) (far variant), [`RET`](https://www.felixcloutier.com/x86/ret) (far variant), [`INT n`](https://www.felixcloutier.com/x86/intn:into:int3:int1)
- [`STR`](https://www.felixcloutier.com/x86/str)
- [`MOV`](https://www.felixcloutier.com/x86/mov) (segment registers)

## Enter VT-x extension

---

[^1]: also _Console Monitor System_ but eventually renamed to [_Conversational Monitor System_](https://en.wikipedia.org/wiki/Conversational_Monitor_System).

[^2]: [Formal virtualization requirements for the ARM architecture](https://dl.acm.org/doi/10.1016/j.sysarc.2013.02.003) published in 2013 builds on Popek and Goldberg's work and extends their machine model to modern architectures with paged virtual memory, I/O and interrupts.

[^3]: When a trap happens, the processor automatically saves the current state of the machine and passes the control to a pre-specified routine by changing the processor mode, the relocation-bounds register, and the program counter.

[^4]: I say classic because some machines, like the PDP-10, are not classically virtualizable. However, based on Popek and Goldberg’s second theorem, a hybrid virtual machine monitor (HVM) can still be constructed for them under another set of constraints which are beyond the scope of this post.

[^5]: ["Analysis of the Intel Pentium's Ability to Support a Secure Virtual Machine Monitor"](http://www.usenix.org/events/sec2000/robin.html) by John Scott Robin and Cynthia E. Irvine.
