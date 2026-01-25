+++
title = "programming is modeling - an experience report"
date = 2024-07-11
# updated = 2025-01-01
draft = false

[taxonomies]
categories = ["posts"]
tags= ["programming", "modeling"]

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

A short description of why mental models are important when building systems.

<!-- more -->

## Intro

A CLI game is basically a state-machine with a loop that continuously checks and updates the state based on some criteria such as user input or when a collision happens.

A while ago I built such a game, [HEXvaders](https://github.com/pooladkhay/HEXvaders), where, _not surprisingly_, I had to dynamically print characters to the terminal screen. Later I decided to let multiple players compete online by splitting the screen such that the game occupies two-thirds of the screen, with the remaining one-third dedicated to a scoreboard.

Soon I realized that in order to split the screen to add a scoreboard, I need to refactor the entire codebase, and if you need to refactor an entire idea to add another piece of functionality, chances are something is fundamentally wrong with how you modeled the idea in the first place.

There are libraries out there to create Terminal UIs but since I like re-inventing the wheel, I went to the quest of creating a library that I can use to reimplement my game, with extendibility in mind.

In this blog post I want to briefly discuss how I initially designed the game, how I did it the second time and what I learned from it.

## First attempt

A game has some objects, like arrows, enemies, cars, etc. that needs to keep track of. In case of my game, each item on the screen can be considered an object, e.g. the game canvas, input area, an invader, an arrow, etc.

In the first try, one major flaw in my design was the way I separated the concerns, or in other words, the way I didn't separate the concerns!

The idea behind the HEXvaders is simple, when you see a hexadecimal value on the screen, an invader, enter the binary equivalent of the hex value to kill the invader!

In particular, the fundamental issues in my first design were as follows:

- There was no holistic view of the world, i.e. there was no entity knowing the position of all objects in order to find and correct any potential drifts.
- Each game object (i.e. invader, arrow, bottom board, etc.) was responsible for drawing itself to the screen by calling `print!()`, in addition to saving the its own state.
- Printing to the screen was being done character by character, by calling to `print!()`, and since I/O is relatively expensive this causes a performance issue.

## Second attempt

While working on the game, I also realized each game object can be considered to be either a rectangle or a text, hence the [rectext library](https://github.com/pooladkhay/rectext) (repo is not public yet) was born!

My goal was to address the issues with the first design, I wanted a library to handle the positioning and drawing of characters so that I can focus the the game logic itself.

Characteristics of the _rectext_ library:

- It has an internal buffer which is simply a Vector of bytes that stores the characters based on their position/coordinate on the screen.
- It exposes two main types for creating more complicated objects, `Rectangle` and `Text`.
- Since I used Rust, it exposes a trait called `UIElement`. Any object that implements this trait can be passed to the library to be printed on the screen.
- It has a `Terminal` object that knows how to talk to an ANSI Terminal.
- In has a rendering algorithm that generates the next "frame", considering what is the current state of the screen and what should be the next state. For that, it uses a double-buffering strategy.
- For each frame, there is only one call to `print!()`, as a result each frame gets printed to the screen in one shot.
- The library accepts arbitrary entities as `stdin` (if it implements `AsRawFd + Read` traits) and `stdout` (if it implements `AsRawFd + Write` traits), with the goal of making it easy to port it to WebAssembly.

With this new way of modeling my idea, what I built is a library that given a set of objects with their coordinates, generates a string of characters to be interpreted by a terminal. This is similar to how a compiler transforms one representation of a program to another.

With the right mental model of the problem, once an almost impossible task, became as easy as a pie!

Here is when the game starts at position `(0, 0)` and fits the entire screen:

```rust
let game = Game::new(0, 0, (screen_cols).into(), (screen_rows).into());
```

![hexvaders-fullscreen](/blog-img/hexvaders-full.png)

And this is when the game starts at position `(0, 0)` and only occupies two-thirds of the screen:

```rust
let game = Game::new(0, 0, (screen_cols * 2 / 3).into(), (screen_rows).into());
```

![hexvaders-two-thirds](/blog-img/hexvaders-two-thirds.png)

Now you should be able to imagine the endless possibilities of various arrangements of the objects on the screen.

## Conclusion

This blog post was not about teaching you about specifics of Rust nor about how one should design a UI library. My goal was to remind you that having the correct model in mind is very critical when it comes to designing software.

Thinking about how different parts of the code would interact with each other, and thinking about how to model them is a crucial aspect of every software project.

I would like to end this with a quote from Rob Pike, on the importance of mental models and how he learned this from Ken Thompson:

{% quote(cite="Rob Pike") %}
A year or two after I'd joined the Labs, I was pair programming with Ken Thompson on an on-the-fly compiler for a little interactive graphics language designed by Gerard Holzmann. I was the faster typist, so I was at the keyboard and Ken was standing behind me as we programmed. We were working fast, and things broke, often visibly—it was a graphics language, after all.

When something went wrong, I'd reflexively start to dig in to the problem, examining stack traces, sticking in print statements, invoking a debugger, and so on. But Ken would just stand and think, ignoring me and the code we'd just written. After a while I noticed a pattern: Ken would often understand the problem before I would, and would suddenly announce, "I know what's wrong." He was usually correct. I realized that Ken was building a mental model of the code and when something broke it was an error in the model. By thinking about how that problem could happen, he'd intuit where the model was wrong or where our code must not be satisfying the model.

Ken taught me that thinking before debugging is extremely important. If you dive into the bug, you tend to fix the local issue in the code, but if you think about the bug first, how the bug came to be, you often find and correct a higher-level problem in the code that will improve the design and prevent further bugs.

I recognize this is largely a matter of style. Some people insist on line-by-line tool-driven debugging for everything. But I now believe that thinking—without looking at the code—is the best debugging tool of all, because it leads to better software.
{% end %}
