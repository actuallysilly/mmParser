# Branching — BUILT

> **Status: implemented.** This file is kept as the original brief; what actually
> shipped is described in **[ARCHITECTURE.md §9](../../ARCHITECTURE.md)** and the code is
> [src/branch/tree.ahk](../../src/branch/tree.ahk) (the model and the compiler),
> [src/ui/branch_window.ahk](../../src/ui/branch_window.ahk) (the window) and
> [src/ui/webview/branch_builder.html](../../src/ui/webview/branch_builder.html) (the
> editor). Open it with `^!b`.
>
> **The one thing the brief got wrong**, and it is the good kind of wrong: it says
> *"How to parse this and turn it into hotkey is part 2 of the problem."* There is no
> part 2. A root-to-leaf path through the tree **is** a named branch, so the builder
> emits the `!mma` format the parser already reads and the engine already sends. No new
> format, no second parser.
>
> The brief also proposed a `[altbranch1]` block syntax. That was not needed either —
> `::name` already existed and already round-trips.

---

## The original brief

We need to implement a branching feature along with a special web gui
This is separate from our normal workflow so we will take it to the browser
As the task is a little more complex

Normal mass message flow

Follow up1 -> Follow up2 -> Follow up3 -> PPV

The point is, follow ups should be able to answer the most common expected response

But we run into a problem of having multiple common answers that all need to be covered

The idea is to have a web editor that can the convo flows fu1->resp1->fu2->resp2
And that the gui can spawn a new thread with alternate routes fu1->resp3->fuALT->resp4
These branches should be able to merge back into a main branch

This is just a visual tool, its output is a !mma mass message in a new format

!mma My mass message

Fu1:
Fu2:
Fu3:

[altbranch1]

altbranch1
altbranch2
altbranch3

[altbranch2]

altbranch2
altbranch3

This should work as multiple threads that can merge back into each other or split off
Kind of like git?

If you disapprove of the format make up a new one
We are just implementing the webgui now
How to parse this and turn it into hotkey is part 2 of the problem

This is a generelization of the Or-Or mass problem
This one woudl just have 2 full branches
Instead of a few partial ones
