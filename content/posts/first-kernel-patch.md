+++
title = "my first patch to the linux kernel"
date = 2026-03-19
updated = 2026-05-14
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

How an undefined behavior in C made me pull my hair out for days but became my first patch to the Linux kernel!

<!-- more -->

## Intro

A while ago, I started dipping my toe into virtualization. It's a topic that many people have heard of or are using on a daily basis but a few know and think about how it works under the hood.

I like to learn by reinventing the wheel, and naturally, to learn virtualization I started by trying to build a [Type-2 hypervisor](https://en.wikipedia.org/wiki/Hypervisor#Classification). This approach is similar to how [KVM](https://en.wikipedia.org/wiki/Kernel-based_Virtual_Machine) (Linux) or [bhyve](https://en.wikipedia.org/wiki/Bhyve) (FreeBSD) are built.

My experimental hypervisor (and VMM) is still a work-in-progress and is available on my Github: [pooladkhay/evmm](https://github.com/pooladkhay/evmm).

Since virtualization is hardware assisted these days [^1], the hypervisor needs to communicate directly with the CPU by running certain privileged instructions; which means a Type-2 hypervisor is essentially a [Kernel Module](https://en.wikipedia.org/wiki/Loadable_kernel_module) that exposes an API [^2] to the user-space where a Virtual Machine Monitor (VMM) [^3] like [QEMU](https://www.qemu.org/) or [Firecracker](https://firecracker-microvm.github.io/) is running and orchestrating VMs by utilizing that API.

In this post, I want to describe exactly how I found that bug. But to make it a bit more educational, I'm going to set the stage first and talk about a few core concepts so you can see exactly where the bug emerges.

## x86 Task State Segment (TSS)

The x86 architecture in protected mode (32-bit mode) envisions a task switching mechanism that is facilitated by the hardware. The architecture defines a Task State Segment (TSS) which is a region in the memory that holds information about a task (General purpose registers, segment registers, etc.). The idea was that any given task or thread would have its own TSS, and when the switch happens, a specific register (Task Register or TR) would get updated to point to the new task [^4].

This was abandoned in favor of software-defined task switching which gives more granular control and portability to the operating system kernel.

But the TSS was not entirely abandoned. In modern days (64-bit systems) the kernel uses a TSS-per-core approach where the main job of TSS is to hold a few stack pointers that are very critical for the kernel and CPU's normal operation. More specifically, it holds the kernel stack of the current thread which is used when the system wants to switch from user-space to the kernel-space.<br>
It also holds a few known good stacks for critical events like Non-Maskable Interrupts (NMIs) and Double Faults. These are events that if not handled correctly, can cause a triple fault and crash a CPU core or cause an immediate system reboot.

We know that memory access is generally considered to be expensive and caching values somewhere on the CPU die is the preferred approach if possible. This is where the TR register comes into the picture. It has a visible part which is a 16-bit offset that we have already discussed as well as a hidden part that holds direct information about the TSS (Base address, Limit, and Access rights). This saves the CPU the trouble of indexing into the GDT to eventually find the TSS every time it's needed.

## Why do hypervisors care?

A hypervisor is essentially a task switcher where tasks are operating systems. In order for multiple operating systems to run on the same silicon chip, the hypervisor must swap the entire state of the CPU which includes updating the hidden part of the TR register as well.

In a previous blog post [^1] I described how Intel implemented their virtualization extension (VT-x) and how each vCPU (vCore) is given its own VMCS (Virtual Machine Control Structure) block where its state is saved to or restored from by the hardware when switching between host and guest OSes.

I suggest reading that post if you're interested in the topic but VMCS consists of four main areas:

- Host-state area
- Guest-state area
- Control fields
- VM-exit information area

Host-state area has two fields which correspond to the visible part and one of the hidden parts (base address) the TR register:

- `HOST_TR_SELECTOR` (16 bits)
- `HOST_TR_BASE` (natural width [^5])

While guest-state area has four (one visible plus all three hidden parts):

- `GUEST_TR_SELECTOR` (16 bits)
- `GUEST_TR_BASE` (natural width [^5])
- `GUEST_TR_LIMIT` (32 bits)
- `GUEST_TR_ACCESS_RIGHTS` (32 bits)

The reason is that the hardware assumes the host OS to be a modern 64-bit operating system where TR limit and Access Rights are fixed known values (`0x67` and `0x11` respectively). But the guest OS can be virtually any operating system with any constraints.

Naturally, it is the hypervisor's job to set these values on initial run and to update them when needed (e.g. when the kernel thread that is running a vCPU is migrated to another physical CPU core, the hypervisor must update the host state to match the new core).

To set these values, I ["borrowed"](https://elixir.bootlin.com/linux/v6.19.8/source/tools/testing/selftests/kvm/lib/x86/vmx.c#L276) some code from the linux kernel tree (KVM selftests):

```C
vmwrite(HOST_TR_BASE,
		get_desc64_base((struct desc64 *)(get_gdt().address + get_tr())));
```

This piece of code does the following:

- Gets the address of GDT.
- Indexes into it using the value of TR register.
- Parses the TSS segment descriptor and extracts the memory address of TSS.
- Writes the address into the `HOST_TR_BASE` section of the VMCS using the special `VMWRITE` instruction [^6].

So far, so good!

If for any reason this operation fails to extract and write the correct address, upon the next context switch from user-space to kernel-space (or next NMI or next Double fault), when the CPU hardware tries to read the kernel stack from the TSS to update the Stack Pointer register, it either receives garbage or an unmapped address. Either way, the CPU will eventually face a double fault (a fault that happens when trying to handle another fault like a page fault) and when trying to use one of the known good stacks for handling the double fault, it will fail again which will make it a triple fault and BOOM! The core dies or we get a sudden reboot.

## Symptoms

Now lets talk about the issue that I was facing.

I started developing my hypervisor on a virtualized instance of Fedora, to avoid crashing my machine in case something went wrong. By the time I realized something is indeed wrong, I had already developed the ability to put the CPU in VMX operation, run a hardcoded loop in VMX non-root mode that would use the [`VMCALL`](https://www.felixcloutier.com/x86/vmcall) instruction to trap into the hypervisor (VMX root) and ask it to print a message, then resume the loop ([`VMRESUME`](https://www.felixcloutier.com/x86/vmlaunch:vmresume)).

Additionally, VMCS was programmed to trap external interrupts (e.g. timer ticks). Upon an exit, the hypervisor would check if we (the current kernel thread) needs to be rescheduled, keeping the kernel scheduler happy.

I was using [preempt notifier api](https://www.kernel.org/doc/html/latest/driver-api/basics.html#c.preempt_notifier_register) which lets threads provide two custom functions (`sched_in` and `sched_out`) that are called by the scheduler when it's about to deschedule the thread as well as right before rescheduling it. These functions are then responsible for cleanups and initialization work that is required.

In my case, `sched_out` would unload the VMCS from the current core, and `sched_in` would load it on the new core [^7] while reinitializing it using a series of `VMWRITE`s [^6] to match the new core's state.

On my virtualized dev environment with only three vCPUs, everything was working just fine. Until I decided to give it a try on my main machine [^8] where the hypervisor would talk to an actual physical CPU.

And BOOM!

Seconds after running the loop, the system crashed, in a very unpredictable way. I was logging the core switches and didn't find any meaningful correlation between the last core number and the crash. Additionally, sometimes it would last longer and sometimes it was immediate. After investigating kernel logs a few times, I saw a pattern in the sequence of events that caused the system to eventually hang:

- The Fatal VM-Exit: An NMI triggered a VM-Exit on CPU 5 and naturally the hardware tried to locate a valid kernel stack from TSS to handle the privilege transition.
- Core Death: CPU 5 hit a fatal Page Fault attempting to read an unmapped memory address, resulting in a [Kernel Oops](https://en.wikipedia.org/wiki/Linux_kernel_oops). CPU 5 was left completely paralyzed with interrupts disabled.
- IPI Lockup: CPU 6 attempted a routine system-wide update (kernel text patching) requiring an [Inter-Processor Interrupt (IPI)](https://en.wikipedia.org/wiki/Inter-processor_interrupt) acknowledgment from all cores. CPU 6 became permanently stuck in an infinite loop waiting for the dead CPU 5 to respond.
- Cascading Paralysis: As other cores (3, 8, 11, etc.) attempted standard cross-core communications (like memory map TLB flushes and RCU synchronizations), they too fell into the IPI trap, waiting indefinitely for CPU 5.
- Terminal State: The RCU subsystem starved, peripheral drivers (like Wi-Fi) crashed from timeouts, and the system entered a total, unrecoverable deadlock.

So why no triple faults?!

The Kernel Oops killed the active task and halted operations on CPU 5. However, it left CPU 5 in a "zombie" state. Alive enough to keep the motherboard powered on, but with its interrupts disabled, making it entirely unresponsive to the rest of the system.

## The quest

Soon I realized that the hypervisor works absolutely fine [^9] when pinned to one core (e.g. via [`taskset`](https://man7.org/linux/man-pages/man1/taskset.1.html) command), so there must be something happening while moving between cores. Additionally, I didn't dare to question the code I stole from the Linux kernel source, and I was trying hard to find an issue in the code I wrote myself. This eventually led to rewriting a portion of the hypervisor code with an alternative method which would achieve the same goal.

For example, from reading Intel's Software Developer Manual (SDM) [^10], I knew that when moving from core A to core B, core A must run the [`VMCLEAR`](https://www.felixcloutier.com/x86/vmclear) instruction to unload the VMCS, and only then can core B load the VMCS using the [`VMPTRLD`](https://www.felixcloutier.com/x86/vmptrld) to be able to execute the guest code. For that, I was using `smp_call_function_single` which relies on [IPI](https://en.wikipedia.org/wiki/Inter-processor_interrupt)s to run a piece of code on another CPU, that I replaced with the preempt notifiers.

Eventually, (*while pulling my hair out*) I realized I have eliminated all possible parts of the hypervisor that played a role in moving between cores.

Then there was another clue!

While running the hypervisor on my virtual dev environment (QEMU + Fedora) I observed that by increasing the number of vCores, I can reproduce the issue and there is also a new behavior. Sometimes the VM reboots immediately (instead of freezing) and after the reboot, there is no trace of any logs related to the previous session. And I concluded that a triple fault has happened.

This turned my attention to the TR and TSS. I started looking for alternative ways of setting the `HOST_TR_BASE` and realized that the KVM itself (not KVM selftests) uses a [different method](https://elixir.bootlin.com/linux/v6.19.8/source/arch/x86/kvm/vmx/vmx.c#L1562):

```C
/*
 * Linux uses per-cpu TSS and GDT, so set these when switching
 * processors.  See 22.2.4.
 */
vmcs_writel(HOST_TR_BASE, (unsigned long)&get_cpu_entry_area(cpu)->tss.x86_tss);
```

And that was it! Using this method to set `HOST_TR_BASE` fixed my hypervisor and helped me keep whatever sanity I had left.

## The smoking gun

Remember that piece of code I took from the kernel source. It used the `get_desc64_base` function to extract and write the address of TSS into the `HOST_TR_BASE`. This function has this definition:

```C
static inline uint64_t get_desc64_base(const struct desc64 *desc)
{
    return ((uint64_t)desc->base3 << 32) |
		(desc->base0 | ((desc->base1) << 16) | ((desc->base2) << 24));
}
```

TSS segment descriptor has four fields that must be stitched together to form the address of the TSS [^11].

- `base0` is `uint16_t`.
- `base1` is `uint8_t`.
- `base2` is `uint8_t`.
- `base3` is `uint32_t`.

The C standard [^12] dictates Integer Promotion. Whenever a type smaller than an `int` is used in an expression, the compiler automatically promotes it to a standard `int` (which is a 32-bit signed integer on modern x86-64 architectures) before performing the operation.

{% quote(cite="Section 6.3.1.1") %}
If an `int` can represent all values of the original type (as restricted by the width, for a bit-field), the value is converted to an `int`; otherwise, it is converted to an `unsigned int`. These are called the integer promotions. All other types are unchanged by the integer promotions.
{% end %}

This promotion has a consequence: (see the [Update](#update) section)<br>
~if the resulting value after promotion has a `1` in its most significant bit (32nd bit), this value considered negative by the compiler and if casted to a larger type like a `uint64_t` in our case, sign extension happens.~

Lets see an example:

We have an 8-bit unsigned integer (`uint8_t`) with `11001100` bit pattern. If we left-shift it by 24, it still can be represented by an `int` which is 32 bits long. So the compiler generates this value: `11001100000000000000000000000000` and considers it to be an `int` which is a signed type.

Now if we try to perform any operation on this value, it would follow the protocol for signed values. In our case, we are `OR`ing it with a `uint64_t`. So the compiler would cast our `int` (a 32-bit signed value) into `uint64_t` (a 64-bit unsigned value), which is where the sign-extension happens which would turn our value to `11111111111111111111111111111111_11001100000000000000000000000000` before `OR` happens.

Saw the problem?<br>
Because the upper 32 bits are sign-extended to all `1`s (Hex: `0xFFFFFFFF`), the bitwise `OR` operation completely destroys `base3` (In a bitwise `OR`, `1 | X` equals `1`). Therefore, whatever data was in `base3` is permanently overwritten by the `1`s from the sign extension.

Here is an actual example with "real" addresses:

```
base0 = 0x5000
base1 = 0xd6
base2 = 0xf8
base3 = 0xfffffe7c

Expected return: 0xfffffe7cf8d65000
Actual return:   0xfffffffff8d65000
```

This also explains when the problem would happen: Only and only if `base2` has a `1` as its most significant bit. Any other value would not corrupt the resulting address.

<img src="/blog-img/hide-the-pain.webp" alt="hide-the-pain" width="480"/>

## The Kernel patch

The fix is actually very simple. We must cast values to unsigned types before the bit-shift operation:

```C
static inline uint64_t get_desc64_base(const struct desc64 *desc)
{
    return (uint64_t)desc->base3 << 32 |
           (uint64_t)desc->base2 << 24 |
           (uint64_t)desc->base1 << 16 |
           (uint64_t)desc->base0;
}
```

This will prevent the sign-extension from happening.

Finally, this is the patch I sent, which was approved and merged:<br>
[https://lore.kernel.org/kvm/20251222174207.107331-1-mj@pooladkhay.com/](https://lore.kernel.org/kvm/20251222174207.107331-1-mj@pooladkhay.com/)

## Outro

I would say the main takeaway is to never trust any code. Kernel developers are also human (at least for now) which leads me to a quick note on AI!

You may wonder whether I tried asking an LLM for help or not. Well, I did. In fact it was very helpful in some tasks like summarizing kernel logs and extracting the gist of them. But when it came to debugging based on all the clues that were available, it concluded that my code didn't have any bugs, and that the CPU hardware was faulty.

CASE CLOSED.

## Update

After this post made its way to [Hacker News](https://news.ycombinator.com/item?id=47444909), `fonheponho` pointed out a crucial flaw in my root cause analysis.

While the patch correctly fixes the bug, I blamed the wrong part of the C standard for the crash. The issue isn't "sign extension" during the cast to `uint64_t` [^13]. The real issue is an [Undefined Behavior (UB)](https://en.wikipedia.org/wiki/Undefined_behavior) triggered by an invalid bitwise left-shift, one step earlier.

Here is the correct sequence of events:

1. **Integer promotion**: Just as I mentioned, `desc->base2` (a `uint8_t`) is promoted to a signed `int`, because `int` can represent all values of an 8-bit unsigned integer.

2. **The illegal shift**: The C standard's rules for `E1 << E2` state that if `E1` has a signed type and a non-negative value, the result is valid only if $E1 \times 2^{E2}$ is representable in the result type. If it isn't (as is the case when we shift a `1` into the sign bit of a 32-bit `int`) the behavior is undefined. The UB happens here, inside the shift itself, before any cast occurs.

3. **The manifestation**: With UB already invoked, the C standard makes no guarantees about what follows. The "sign extension" I described, where the upper 32 bits become all `1`s during the subsequent cast to `uint64_t`, is simply what GCC on x86 produces, probably because the underlying `SHL` instruction naturally yields that bit pattern and the compiler inserts no special handling. A different compiler, or even a different optimization level, could have produced something else entirely.

The fix remains exactly the same: casting `desc->base2` to `uint64_t` before the shift forces the operation onto an unsigned 64-bit integer, where the shift is well-defined and no bits are lost.

Thanks to the HN community for keeping me technically honest!

---

[^1]: Check out my previous post for more details: [virtualization: theory to silicon](https://pooladkhay.com/posts/virt-theory-silicon/)

[^2]: KVM API documentation: [https://docs.kernel.org/virt/kvm/api.html](https://docs.kernel.org/virt/kvm/api.html)

[^3]: Hypervisor and Virtual Machine Monitor (VMM) are generally interchangeable terms, while some might differentiate them slightly (e.g. VMM as user-space part of a kernel-space hypervisor).

[^4]: TR register does not directly point to TSS. It holds an offset that is used to index into a region of memory called the Global Descriptor Table (GDT). This offset is where the TSS segment descriptor lives, and is the entity that actually holds the address of the TSS.<br>
At this point I hope you're asking "WTF Intel?!"<br>
Well, these design decisions were made back in the 80s where memory was scarce, paging hadn't been fully adopted yet, and segmentation was "the way" of managing memory and privilege levels.

[^5]: 32 bits on 32-bit machines and 64 bits on 64-bit machines.

[^6]: It's not possible to write to and read from the VMCS using usual memory read and write operations. There are special instructions to do so: [`VMREAD`](https://www.felixcloutier.com/x86/vmread) and [`VMWRITE`](https://www.felixcloutier.com/x86/vmwrite).

[^7]: Yes, this path must be optimized since this loading and unloading is relatively heavy. And hypervisors usually pin threads to cores to avoid paying this fee.

[^8]: It's an Intel Core i7-12700H with 14 Cores (6 Performance, 8 Efficient) and a total of 20 threads.

[^9]: Looking back, that was purely luck. Continue reading to know why...

[^10]: Volume 3C of the [SDM](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html) covers the virtual machine extension (VMX).

[^11]: Another remnant of old hardware design that is kept for backward compatibility purposes, but "WTF Intel?!" indeed.

[^12]: [https://www.open-std.org/JTC1/SC22/WG14/www/docs/n1570.pdf](https://www.open-std.org/JTC1/SC22/WG14/www/docs/n1570.pdf)

[^13]: Sign-extension is an ISA concept, not a C one.
