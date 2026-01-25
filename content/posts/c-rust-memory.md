+++
title = "it’s all about memory"
date= 2024-06-28
# updated = 2025-01-01
draft = false

[taxonomies]
categories = ["posts"]
tags= ["c", "rust", "unsafe-rust"]

[extra]
lang = "en"
toc = true
comment = true
copy = true
math = false
mermaid = false
outdate_alert = false
outdate_alert_days = 120
display_tags = true
truncate_summary = false
featured = false
+++

A comparison of memory management in C vs. Rust.

<!-- more -->

## Intro

When talking about memory, it's always good to remind ourselves that we have the Stack and the Heap.
Stack is pretty straightforward, while Heap is its own beast. In fact, the word memory in "memory management" almost always refers to the Heap memory.

In C, the programmer is in charge of allocating and deallocating the memory which is proven to be very powerful and very dangerous at the same time, leading to in issues like [double-free](https://en.wikipedia.org/wiki/Dangling_pointer), [use-after-free](https://owasp.org/www-community/vulnerabilities/Doubly_freeing_memory) or even using a pointer before initialization, causing [Wild Pointers](https://en.wikipedia.org/wiki/Dangling_pointer#Cause_of_wild_pointers)!

(again) In C, it's completely legal to request a piece of memory (e.g. via `malloc`) and then give out multiple copies of the address of that memory.
Ignoring the possible data races that may occur, this also raises more serious questions:

- Who is in charge of freeing (deallocating) the memory when the program no longer needs it?
- When it's freed, how can we ensure there won't be another attempt to free that memory again? (remember there are multiple copies of that address out in the wild!)
- Last but not least, how can we ensure that no one will attempt to access that memory after it’s been freed?

Those are the types of questions/issues that Rust is trying to solve with its niche way of managing memory.

First, we'll see a simple program in C that deals with memory allocation and deallocation, and later we will try to rewrite the same program in Rust and see how those two compare.

## in C

Let's start with C:

```c,linenos
// #1
// main.c
// start...

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char const *argv[])
{

    int *s = (int *)malloc(sizeof(int));
    // ...checking if malloc succeeded...

    // Assigning the value 1 to the memory
    // location pointed to by `s`
    *s = 1;

    // `=` performs a bitwise copy
    int *s2 = s;

```

The `=` operator performs an assignment, and the type of assignment depends on the type of the variables involved. For primitive data types (integers, floating-point numbers, etc.), the `=` operator performs a bitwise copy. It copies the binary representation of the value from the right-hand side to the variable on the left-hand side (like `memcpy()`).

It would be fine if the value of `s` was an ordinary `int` or a `float` living on the Stack. But since both `s` and `s2` are pointers, and pointers are inherently unsigned integers, the `=` operator would perform a bitwise copy as if the value was an ordinary integer!

After the assignment, both `s` and `s2` would have the same value which is the address of an `int` value on the Heap.

The memory allocated by calling to `malloc()` could potentially be deallocated by calling `free()` on both `s` and `s2`.
Let's say `free(s)` was called. Now there is no way for the user of `s2` (which could be another thread or another function on the same thread) to realize that this variable should neither be freed nor used anymore.

Although this might seem like the kind of issue that could be easily prevented by the programmers being careful enough, time has proven that is not always the case, and big contributor to serious security bugs are still memory safety problems.

According to [a blog post by CISA](https://www.cisa.gov/news-events/news/urgent-need-memory-safety-software-products):

> Microsoft reported that “~70% of the vulnerabilities Microsoft assigns a CVE [Common Vulnerability and Exposure] each year continue to be memory safety issues.” Google likewise reported that “the Chromium project finds that around 70% of our serious security bugs are memory safety problems.” Mozilla reports that in an analysis of security vulnerabilities, that “of the 34 critical/high bugs, 32 were memory-related.”

![this-is-fine](/blog-img/this-is-fine.gif)

### Addresses

Let's print out some memory addresses and values to better understand what is where and where is what:

```c,linenos,linenostart=21
// #2
// main.c

    // Addresses of `s` and `s2` on the Stack
    printf("%p\n", &s);  // 0x16b446fc8
    printf("%p\n", &s2); // 0x16b446fc0

```

Now let's print out the values that are stored in `s` and `s2`:

```c,linenos,linenostart=28
// #3
// main.c

    // Values directly stored in `s` and `s2`
    printf("%p\n", s);  // 0x14fe060e0
    printf("%p\n", s2); // 0x14fe060e0
```

Both store the same values, the address of a memory location on the heap.

### Values and UB

Finally, let's print the values stored at the location to which `s` and `s2` are pointing, which is obviously `1`.
Additionally, it's completely legal to free a memory location and try to access it again, which is considered Undefined Behaviour (UB).

```c,linenos,linenostart=34
// #4
// main.c

    // Actual values stored on the heap
    printf("%d\n", *s);  // 1
    printf("%d\n", *s2); // 1

    free(s);

    // At this point both `s` and `s2` are considered "dangling pointers"

    printf("%d\n", *s);  // Undefined Behaviour (UB)
    printf("%d\n", *s2); // UB

    return 0;
}

// end of main.c
```

### Memory Layout

Here is a diagram to visually see how things are laid out in the memory. Stack usually uses higher addresses than heap, and grows downward.

| Variable | Memory Address  | Value           |
| -------- | --------------- | --------------- |
| ...      | ...             | ...             |
| **s**    | **0x16b446fc8** | **0x14fe060e0** |
| **s2**   | **0x16b446fc0** | **0x14fe060e0** |
| ...      | ...             | ...             |
| ...      | ...             | ...             |
|          | **0x14fe060e0** | **1**           |
| ...      | ...             | ...             |

## in Rust we trust

Rust has a very interesting way of managing memory. Essentially, each value has an owner who is responsible for clearing the memory location where the value is stored (i.e. giving back the memory to the OS) when it's no longer required.
Each value can only have one owner who is responsible for cleaning up the memory acquired by the values.

According to the Rust Book, there are three rules of ownership:

- Each value in Rust has an owner.
- There can only be one owner at a time.
- When the owner goes out of scope, the value will be dropped.

Then, there is borrowing which has its own set of rules:

- At any given time, you can have either one mutable reference or any number of immutable references to a value.
- References must always be valid.

The last point in the borrowing rules ensures that there are no references to a value (either mutable or immutable) lingering around after the value has been dropped (i.e., the memory location for the value has been deallocated/freed), hence no dangling pointers!
We have already seen that this is not the case with C.

I'm not going to dive more into this topic since it deserves its own series of posts. However, I encourage you to refer to the official Rust Book's chapter on [Ownership and Borrowing](https://doc.rust-lang.org/book/ch04-00-understanding-ownership.html).

### Boxing

Let's rewrite the same program in Rust which claims to be a memory-safe programming language.

_Spoiler Alert, It's not possible!! At least not with the "safe" side of Rust, as we will see shortly._

This time, we're going to slightly rearrange the code. First, we create `s`, print out different aspects of it, and then try to create `s2` and do the same:

```rust,linenos,hl_lines=5 16
// #5
// main.rs

fn main() {
    let s = Box::new(1_i32);

    // Address of `s` on the Stack
    println!("{:p}", &s); // 0x16af1e9d8

    // Value stored directly in `s`
    println!("{:p}", s); // 0x153e05f70

    // Actual value stored on the heap
    println!("{}", s); // 1

    let s2 = s;

    // Address of `s2` on the Stack
    println!("{:p}", &s2); // 0x16af1e9e0

    // Value stored directly in `s2`
    println!("{:p}", s2); // 0x153e05f70

    // Actual value stored on the heap
    println!("{}", s2); // 1
}
```

The `Box` is referred to as a _Smart Pointer_ and serves as Rust's mechanism for allocating memory on the heap. The signature of the `Box::new()` function is `pub fn new(x: T) -> Self`. Essentially, it accepts an arbitrary value of type `T` and returns a `Box<T>`. This can be interpreted as a pointer to some location on the heap, similar to what `malloc` did in C but with less effort and greater control and safety.
And that kind-of-weird-looking `1_i32` is just the number `1` represented in a 32-bit signed integer type.
So far, so good! nothing particularly interesting is happening in this program. It compiles and runs perfectly fine.

If you're interested in reading more about the Smart Pointers, please refer to the official Rust Book's chapter on [Smart Pointers](https://doc.rust-lang.org/book/ch15-00-smart-pointers.html).

### Moving

Now let's rearrange the code similar to the C one:

```rust,linenos,hl_lines=6
// #6
// main.rs

fn main() {
    let s = Box::new(1_i32);
    let s2 = s;

    // Addresses of `s` and `s2` on the Stack
    println!("{:p}", &s);
    println!("{:p}", &s2);

    // Values directly stored in `s` and `s2`
    println!("{:p}", s);
    println!("{:p}", s2);

    // Actual values stored on the heap
    println!("{}", s);
    println!("{}", s2);
}
```

See that?
I didn't add the result of the `println!()` macros in front of them because this code doesn't compile!

Here is the compiler's error:

```
  |
5 |     let s = Box::new(1_i32);
  |         - move occurs because `s` has type `Box<i32>`, which does not implement the Copy trait
6 |     let s2 = s;
  |              - value moved here
  …
9 |     println!("{:p}", &s);
  |                      ^^ value borrowed here after move
  |
help: consider cloning the value if the performance cost is acceptable
  |
6 |     let s2 = s.clone();
  |               ++++++++
```

Interesting!

Why did it worked in the code snippet number `#5`? Keep reading!

### Copy and Clone

Do you remember the first two ownership rules?

When the `Box::new()` allocates a location on the heap and returns a pointer to it, the variable `s` becomes the owner of that piece of memory. Deallocation happens when the owner _goes out of scope_; in this case, the scope ends at the end of the `main` function. This ensures that the memory gets freed automatically, without the need to manually call a `free()`-like function, when it's no longer required.

By assigning `s` to `s2`, we are moving the ownership of the memory location pointed to by `s`, to `s2`, and since _there can only be one owner at a time_, after the assignment operation, `s` is no longer valid.

If we were to assign just the number `1` to `s` (`let s = 1_i32`), then the value would be stored on the stack, and when assigning `s` to `s2`, `s2` would receive a fresh "Copy" of the value `1`, which is again stored on the stack and is completely unrelated to the value stored in `s`.
In Rust, Primitive types like integers and booleans are "Copy" which means they implement the `Copy` trait, which means they can be copied around easily and, most importantly, cheaply.

Moving the ownership only happens to the variables that are storing a non-copy value. Although pointers are still numbers, in contrast to C, Rust treats them differently. In fact, Rust calls them References instead of Pointers.

Rust also has Pointers (a.k.a. "Raw Pointers"), which pretty much behave like what you would expect from a pointer in C, where there is no notion of Ownership and Borrowing. Raw Pointers cannot be used in "Safe Rust" and are used in scenarios like [Foreign Function Interface (FFI)](https://doc.rust-lang.org/nomicon/ffi.html).

It is also possible to make a "fresh copy" of a value stored on the heap. But in doing so, first, we need to allocate the required memory and then copy the value over. Memory allocations are considered to be costly operations; in general, we usually use heap memory to store values whose size is not known at compile time or values whose lifetime should cross function-call boundaries.

If a type is `Copy`, by assigning it to another variable, the new variable would receive a bitwise copy of the old value and would become the owner of the new copy as well; and if the value doesn't implement the `Copy` trait, the ownership of the old value would be moved over to the new variable and the old variable can no longer be used. Unless the programmer explicitly calls `clone()`, which usually would cause an allocation to happen for the new value on the heap. On the other hand, if a value is `Copy`, then calling `clone()` would do nothing more than the implicit copy.

As a result, in Rust, _Copying_ is an implicit operation, while _Cloning_ is always explicit. Additionally, the implementation of `Clone` can vary for different types based on their specific needs.

More information about `Copy` and `Clone` can be found [here](https://doc.rust-lang.org/std/marker/trait.Copy.html).

### Compiler-Driven Development (CDD)

Now we can also understand the help message:
`consider cloning the value if the performance cost is acceptable.`

In Rust, the compiler is your best friend! So, with more theory behind us, we are hopefully more comfortable making sense of the compiler's messages. Being able to understand why the compiler is yelling at us is a crucial skill to develop while learning Rust.

Before continuing with more code, one last point is to understand why the first program, where the order of variable definition/assignments and `println!()`s were different, worked.

That was because we didn't try to use the variable `s` after its value moved to `s2`, and the compiler was smart enough to realize that. Isn't that cool?!

The lifetime of `s` ends after the move, and it should no longer be used, which was exactly what we did in the first Rust example.
It's time to make our compiler friend happy again without rearranging the order of operations.

### Borrowing

For that, we are going to borrow the value of `s`. By doing so, `s` would remain the owner:

```rust,linenos,hl_lines=6
// #7
// main.rs

fn main() {
    let s = Box::new(1_i32);
    let s2 = &s;

    // Addresses of `s` and `s2` on the Stack
    println!("{:p}", &s); // 0x16efee738
    println!("{:p}", &s2); // 0x16efee740

    // Values directly stored in `s` and `s2`
    println!("{:p}", s); // 0x127e05f70
    println!("{:p}", s2); // 0x16efee738

    // Actual values stored on the heap
    println!("{}", s); // 1
    println!("{}", s2); // 1
}
```

The value immediately stored in `s2` is just the address of the variable `s` on the stack. In Rust's terms, `s2` is an immutable reference to `s`.

What if we want to be able to mutate the inner value of the `Box`?

All variables in Rust are immutable unless explicitly changed to be mutable using the `mut` keyword.
There are also types that provide interior mutability (`Cell<T>`, `RefCell<T>`, `Mutex<T>`, and `RwLock<T>`), but they are a topic for another time!

### Order matters

Let's try that:

```rust,linenos,hl_lines=6-7
// #8
// main.rs

fn main() {
    let mut s = Box::new(1_i32);
    *s = 2;
    let s2 = &s;

    //...rest of the code...
    // The only change in the results is that the final set of `println!()`
    // macros will print 2 instead of 1, which is no surprise!
    // Addresses might also change which is expected but their causal
    // relationship stays the same.
}
```

The code snippet number `#8` compiles fine but the next one (`#9`) doesn't:

```rust,linenos,hl_lines=6-7
// #9
// main.rs

fn main() {
    let mut s = Box::new(1_i32);
    let s2 = &s;
    *s = 2;

    // Addresses of `s` and `s2` on the Stack
    println!("{:p}", &s);
    println!("{:p}", &s2);
}
```

Compilation fails with this error:

```
   |
6  |     let s2 = &s;
   |              -- `*s` is borrowed here
7  |     *s = 2;
   |     ^^^^^^ `*s` is assigned to here but it was already borrowed
...
11 |     println!("{:p}", &s2);
   |                      --- borrow later used here
```

_Remembering the first rule of borrowing_

> At any given time, you can have either one mutable reference or any number of immutable references to a value.

In the code snippet number `#8`, the value is borrowed after the mutation is done. So practically, the borrower will have a consistent view of the underlying memory. However, in snippet number `#9`, the memory is mutated while there is a reference to it out there, which could potentially cause data races.

Ok, nice but we're getting a little bit carried away!

I will stop here to go back to the actual reason I thought this could be an interesting topic to discuss; To see if we could rewrite the exact C code in Rust without all that fancy borrowing stuff and by now, you are hopefully convinced it's not possible based on what we saw and experimented with.

### Unsafe

So far, we have been writing code in _Safe Rust_ in which we have our compiler friend and its borrow checker as our supervisor. But there are certain situations such as interfacing with low-level system APIs (e.g., writing a device driver or [calling foreign functions](https://doc.rust-lang.org/nomicon/ffi.html#calling-foreign-functions)) where we can't do much with the strict rules enforced by the borrow checker.

That's where we need to enter the _[Unsafe Rust](https://doc.rust-lang.org/book/ch19-01-unsafe-rust.html)_.

Here, the word _unsafe_ doesn't really mean unsafe. So whenever we write an `unsafe {}` block, we are asking the compiler to trust us, and that we have made sure this code is safe to run.

Let's see how does that look like:

```rust,linenos,hl_lines=6
// #10
// main.rs

fn main() {
    let s = Box::new(1_i32);
    let s2 = unsafe { std::ptr::read(&s) };

    // Addresses of `s` and `s2` on the Stack
    println!("{:p}", &s);
    println!("{:p}", &s2);

    // Values directly stored in `s` and `s2`
    println!("{:p}", s);
    println!("{:p}", s2);

    // Actual values stored on the heap
    println!("{}", s);
    println!("{}", s2);
}
```

If we simply write `let s2 = unsafe { s };` it would still fail with the same error as `let s2 = s;`. That's because `s` still has type `Box<i32>`, which does not implement the `Copy` trait!

What we want to do is to copy the memory address stored in `s` into `s2` without invalidating `s` itself (i.e., without causing a move to happen).
Specifically, want to create a bitwise copy of the value stores in `s` and save it in `s2` in order to mimic what C did (`int *s2 = s;`), right?

Luckily, the Rust standard library provides a function that exactly does that. `std::ptr::read()` which has this signature:

```rust
pub const unsafe fn read(src: *const T) → T
```

It reads the value from `src` without moving it. This leaves the memory in `src` unchanged.

Running the program prints this output to the console:

```
    Finished dev [unoptimized + debuginfo] target(s) in 0.00s
     Running `target/debug/blog`
0x16d7566e8
0x16d7566f0
0x147605f70
0x147605f70
1
1
blog(51595,0x1d6f31000) malloc: Double free of object 0x147605f70
blog(51595,0x1d6f31000) malloc: *** set a breakpoint in malloc_error_break to debug
[1]    51595 abort      cargo run
```

It executes and prints all addresses and values correctly but at the end, the program panics with this error message:

```
malloc: Double free of object 0x147605f70
```

### Aha Moment

Sounds familiar?

That's the mighty double-free issue we have been talking about which could easily happen in C but Rust is trying to solve, with its model of memory management.

Why did a double-free happen?

_Remembering the last rule of ownership_

> When the owner goes out of scope, the value will be dropped.

What did we do?

- We cheated and stored two references of the same memory location (`0x147605f70`) in two different variables.
- We prevented Rust from moving the ownership to `s2` and invalidating `s`.

As a result, when `s` and `s2` go out of scope at the end of the main function, they both think they are the sole owner of the memory they point to and both will try to free that memory!

It was an _Aha Moment_ when I realized all that Ownership, Borrowing, values being Copy, and move semantics are just means by which Rust enables memory safety without runtime overhead.

That's all I have for you in this blog post.

Hope you have experienced an _Aha moment_ by reading this too!
