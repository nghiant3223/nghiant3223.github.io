---
layout: post
title: "Go Scheduler"
date: 2025-04-15
image: https://raw.githubusercontent.com/nghiant3223/nghiant3223.github.io/refs/heads/main/assets/2025-03-11-go-scheduling/primitive_scheduler.png
---

<button id="scrollTop" title="Go to top">↑</button>
<button id="scrollBottom" title="Go to bottom">↓</button>

# Go Scheduler

* [Introduction](#introduction)
* [Compilation and Go Runtime](#compilation-and-go-runtime)
* [Primitive Scheduler](#primitive-scheduler)
* [Scheduler Enhancement](#scheduler-enhancement)
* [GMP Model](#gmp-model)
* [Program Bootstrap](#program-bootstrap)
* [Creating a Goroutine](#creating-goroutine)
* [Schedule Loop](#schedule-loop)
* [Finding a Runnable Goroutine](#finding-a-runnable-goroutine)
* [Goroutine Preemption](#goroutine-preemption)
* [Handling System Calls](#handling-system-calls)
* [Network I/O and File I/O](#network-io-and-file-io)
* [How netpoll Works](#how-netpoll-works)
* [Garbage Collector](#garbage-collector)
* [Common Functions](#common-functions)
* [Go Runtime APIs](#go-runtime-apis)

## Disclaimer

This blog post primarily focuses on [Go 1.24](https://tip.golang.org/doc/go1.24) programming language for [Linux](https://en.wikipedia.org/wiki/Linux) on [ARM](https://en.wikipedia.org/wiki/ARM_architecture_family) architecture.
It may not cover platform-specific details for other operating systems or architectures.

The content is based on other sources and my own understanding of Go, so it might not be entirely accurate.
Feel free to correct me or give suggestions in the comment section 😄.

## Introduction

> ⚠️ This post assumes that you already have a basic understanding of Go concurrency (goroutines, channels, etc.).
> If you're new to these concepts, consider reviewing them before continuing.

Go or Golang, introduced in 2009, has steadily grown in popularity as a programming language for building concurrent applications.
It is designed to be simple, efficient, and easy to use, with a focus on concurrency programming.

Go's concurrency model is built around the concept of goroutines, which are lightweight user threads managed by the Go runtime on user space.
Go offers useful primitives for synchronization, such as channels, to help developers write concurrent code easily.
It also uses non-trivial techniques to make I/O bound programs efficient.

Understanding the Go scheduler is crucial for Go programmer to write efficient concurrent programs.
It also helps us become better at troubleshooting performance issues or tuning the performance of our Go programs.
In this post, we will explore how Go scheduler evolved over time, and how the Go code we write happens under the hood.

## Compilation and Go Runtime

This post covers a lot of source code walkthrough, so it is better to have a basic understanding of how Go code is compiled and executed first.
When a Go program is built, there are three stages:
- **Compilation**: Go source files (`*.go`) are compiled into assembly files (`*.s`).
- **Assembling**: The assembly files (`*.s`) are then assembled into object files (`*.o`).
- **Linking**: The object files (`*.o`) are linked together to produce a single executable binary file.

<table>
    <thead>
        <tr>
            <td>
                <pre class="mermaid" style="margin: unset">

flowchart LR
start((Start)) ==> |*.go files|compiler[Compiler]
compiler ==> |*.s files|assembler[Assembler]
assembler ==> |*.o files|linker[Linker]
linker ==> |Executable binary file|_end(((End)))

                </pre>
            </td>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td style="text-align: center">
                How Go code is transformed into an executable binary file
            </td>
        </tr>
    </tbody>
</table>

To understand Go scheduler, you have to understand Go runtime first.
Go runtime is the core of the programming language, providing essential functionalities such as scheduling, memory managements, and data structures.
It's nothing but a collection of functions and data structures that makes Go programs work.
The implementation of Go runtime can be found in [runtime](https://github.com/golang/go/tree/go1.24.0/src/runtime) package.
Go runtime is written in a combination of Go and assembly code, with the assembly code primarily used for low-level operations such as dealing with registers.

| <img src="/assets/2025-03-11-go-scheduling/go_runtime_relationship.png" width=300> |
|:----------------------------------------------------------------------------------:|
|                               The role of Go runtime                               |

Upon compiling, Go compiler replaces some keywords and built-in functions with Go runtime's function calls.
For example, the `go` keyword—used to spawn a new goroutine—is substituted with a call to [`runtime.newproc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L5014-L5030), or the `new` function—used to allocate a new object—is replaced with a call to [`runtime.newobject`](https://github.com/golang/go/blob/go1.24.0/src/runtime/malloc.go#L1710-L1715).

You might be surprised to learn that some functions in the Go runtime have no Go implementation at all.
For example, functions like [`getg`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stubs.go#L28-L31) are recognized by the Go compiler and replaced with low-level assembly code during compilation.
Other function, such as [`gogo`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stubs.go#L214-L214), are platform-specific and implemented entirely in assembly.
It is the responsibility of the Go linker to connect these assembly implementations with their Go declarations.

In some cases, a function appears to have no implementation in its package, but is actually linked to a definition in the Go runtime using the [`//go:linkname`](https://pkg.go.dev/cmd/compile#hdr-Linkname_Directive) compiler directive.
For instance, the commonly used [`time.Sleep`](https://github.com/golang/go/blob/go1.24.0/src/time/sleep.go#L12-L14) function  is linked to its actual implementation at [`runtime.timeSleep`](https://github.com/golang/go/blob/go1.24.0/src/runtime/time.go#L297-L340)

## Primitive Scheduler

> ⚠️ The Go scheduler isn’t a standalone object, but rather a collection of functions that facilitate the scheduling.
> Additionally, it doesn’t run on a dedicated thread; instead, it runs on the same threads that goroutines run on.
> These concepts will become clearer as you read through the rest of the post.

If you've ever worked in concurrency programming, you might be familiar with multithreading models.
It specifies how user-space threads (coroutines in Kotlin, Lua or goroutines in Go) are multiplexed onto single or multiple kernel threads.
Typically, there are three models: many-to-one (N:1), one-to-one (1:1), and many-to-many (M:N).

| <img src="/assets/2025-03-11-go-scheduling/n_to_1_multithreading_model.png"> | <img src="/assets/2025-03-11-go-scheduling/1_to_1_multithreading_model.png"> | <img src="/assets/2025-03-11-go-scheduling/m_to_n_multithreading_model.png"> |
|:----------------------------------------------------------------------------:|:----------------------------------------------------------------------------:|:----------------------------------------------------------------------------:|
|  Many-to-one<br/>multithreading model<sup><a href="#references">1</a></sup>  |  One-to-one<br/>multithreading model<sup><a href="#references">2</a></sup>   | Many-to-many<br/>multithreading model<sup><a href="#references">3</a></sup>  |

Go opts for the many-to-many (M:N) threading model, which allows multiple goroutines to be multiplexed onto multiple kernel threads.
This approach sacrifices complexity to take advantage of multicore system and make Go program efficient with system calls, addressing the problems of both N:1 and 1:1 models.
As kernel doesn't know what goroutine is and only offers thread as concurrency unit to user-space application, it is the kernel thread that runs scheduling logic, executes goroutine code, and makes system call on behalf of goroutines.

In the early days, particularly before version 1.1, Go implemented the M:N multithreading model in a naive way.
There were only two entities: goroutines (`G`) and kernel threads (`M`, or *machines*).
A single global run queue was used to store all runnable goroutines and guarded with lock to prevent race condition.
The scheduler—running on every thread `M`—was responsible for selecting a goroutine from the global run queue and executing it.

| <img src="/assets/2025-03-11-go-scheduling/primitive_scheduler.png" width=500> |
|:------------------------------------------------------------------------------:|
|                            Go's primitive scheduler                            |

Nowadays, Go is well-known for its performant concurrency model.
Unfortunately, that's not the case for the early Go.
Dmitry Vyukov—one of the key Go contributors—pointed out multiple issues with this implementation in his famous [Scalable Go Scheduler Design](https://docs.google.com/document/d/1TTj4T2JO42uD5ID9e89oa0sLKhJYD0Y_kqxDv3I3XMw): "In general, the scheduler may inhibit users from using idiomatic fine-grained concurrency where performance is critical."
Let me explain in more detail what he meant.

Firstly, the global run queue was a bottleneck for performance.
When a goroutine was created, threads had to acquire a lock to put it into the global run queue.
Similarly, when threads wanted to pick up a goroutine from the global run queue, they also had to acquire the lock.
You may know that locking is not free, it does have overhead with lock contention.
Lock contention leads to performance degradation, especially in high-concurrency scenarios.

Secondly, threads frequently handoff its associated goroutine to another thread.
This cause poor locality and excessive context switch overhead.
Child goroutine usually wants to communicate with its parent goroutine.
Therefore, making child goroutine run on the same thread as its parent goroutine is more performant.

Thirdly, as Go's been using [Thread-caching Malloc](https://google.github.io/tcmalloc/design.html), every thread `M` has a thread-local cache `mcache` so that it can use for allocation or to hold free memory.
While `mcache` is only used by `M`s executing Go code, it is even attached with `M`s blocking in a system call, which don't use `mcache` at all.
An `mcache` can take up to 2MB of memory, and it is not freed until thread `M` is destroyed.
Because the ratio between `M`s running Go code and all `M`s can be as high as 1:100 (too many threads are blocking in system call), this could lead to excessive resource consumption and poor data locality.

## Scheduler Enhancement

Now that you have a understanding of the issues with early Go scheduler, let's examine some of the enhancement proposals to see how Go team addressed these issues so that we have a performant scheduler today.

### Proposal 1: Introduction of Local Run Queue

Each thread `M` is equipped with a local run queue to store runnable goroutines.
When a running goroutine `G` on thread `M` spawns a new goroutine `G1` using the `go` keyword, `G1` is added to `M`'s local run queue.
If the local queue is full, `G1` is instead placed in the global run queue.
When selecting a goroutine to execute, `M` first checks its local run queue before consulting the global run queue.
Thus, this proposal addresses the first and second issues as described in the last section.

| <img src="/assets/2025-03-11-go-scheduling/proposal_1.png" width=500> |
|:---------------------------------------------------------------------:|
|                 Proposal 1 for scheduler enhancement                  |

However, it can't resolve the third issue.
When many threads `M` are blocked in system calls, their `mcache` stays attached, causing high memory usage by the Go scheduler itself, not to mention the memory usage of the program that we—Go programmers—write.

It also introduces another performance problem.
In order to avoid starving goroutines in a blocked `M`'s local run queue like `M1` in the figure above, the scheduler should allow other threads to *steal* goroutine from it.
However, with a large number of blocked threads, scanning all of them to find a non-empty run queue becomes expensive.

### Proposal 2: Introduction of Logical Processor

This proposal is described in [Scalable Go Scheduler Design](https://docs.google.com/document/d/1TTj4T2JO42uD5ID9e89oa0sLKhJYD0Y_kqxDv3I3XMw), where the notion of *logical* processor `P` is introduced.
By *logical*, it means that `P` pretends to execute goroutine code, but in practice, it is thread `M` associated with `P` that actually performs the execution.
Thread's local run queue and `mcache` are now owned by `P`.

This proposal effectively addresses open issues in the last section.
As `mcache` is now attached to `P` instead of `M` and `M` is detached from `P` when `G` makes system call, the memory consumption stays low when there are a large number of `M`s entering system calls.
Also, as the number of `P` is limited, the *stealing* mechanism is efficient.

| <img src="/assets/2025-03-11-go-scheduling/proposal_2.png" width=500> |
|:---------------------------------------------------------------------:|
|                 Proposal 2 for scheduler enhancement                  |

With the introduction of logical processors, the multithreading model remains M:N.
But in Go, it is specifically referred to as the GMP model as there are three kinds of entities: goroutine, thread and processor.

## GMP Model

### Goroutine: [`g`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L396-L508)

When the `go` keyword is followed by a function call, a new instance of [`g`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L396-L508), referred to as `G`, is created.
`G` is an object that represents a goroutine, containing metadata such as its execution state, stack, and a program counter pointing to the associated function.
Executing a goroutine simply means running the function that `G` references.

When a goroutine finishes execution, it isn’t destroyed; instead, it becomes *dead* and is placed into the free list of the current processor `P` .
If `P`’s free list is full, the dead goroutine is moved to the global free list.
When a new goroutine is created, the scheduler first attempts to reuse one from the free list before allocating a new one from scratch.
This recycling mechanism makes goroutine creation significantly cheaper than creating a new thread.

The figure and table below described the state machine of goroutines in the GMP model.
Some states and transitions are omitted for simplicity.
The actions that trigger state transitions will be described along the post.

|                                         State                                          | &nbsp;&nbsp;&nbsp; Description                                       |
|:--------------------------------------------------------------------------------------:|----------------------------------------------------------------------|
|   [Idle](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L36-L39)   | Has just been created, and not yet initialized                       |
| [Runnable](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L40-L42) | Currently in run queue, and about to execute code                    |
| [Running](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L44-L47)  | Not in a run queue, and executing code                               |
| [Syscall](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L49-L52)  | Executing system call, and not executing code                        |
| [Waiting](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L54-L62)  | Not executing code, and not in a run queue, e.g. waiting for channel |
|   [Dead](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L68-L74)   | Currently in a free list, just exited, or just  beiging initialized  |

| <img src="/assets/2025-03-11-go-scheduling/goroutine_state_machine.png" width=400> |
|:----------------------------------------------------------------------------------:|
|                      State machine of goroutines in GMP model                      |

### Thread: [`m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L528-L630)

All Go code—whether it's user code, the scheduler, or the garbage collector—runs on threads that are managed by the operating system kernel.
In order for the Go scheduler to make threads work well in GMP model, [`m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L528-L630) struct representing threads is introduced, and an instance of [`m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L528-L630) is called `M`.

`M` maintains reference to the current goroutine `G`, the current processor `P` if `M` is executing Go code, the previous processor `P` if `M` is executing system call, and the next processor `P` if `M` is about to be created.

Each `M` also holds reference to a special goroutine called `g0`, which runs on the system stack—the stack provided by the kernel to the thread.
Unlike the system stack, a regular goroutine's stack is dynamically sized; it grows and shrinks as needed.
However, the operations for growing or shrinking a stack must themselves run on a valid stack. For this, the system stack is used.
When the scheduler—running on an `M`—needs to perform stack management, it switches from the goroutine's stack to the system stack.
In addition to stack growth and shrinkage, operations like garbage collection and [parking a goroutine](#goroutine-parking-gopark) also require execution on the system stack.
Whenever a thread performs such operation, it switches to the system stack and executes the operation in the context of `g0`.

Unlike goroutine, threads run scheduler code as soon as `M` is created, therefore the initial state of `M` is *running*.
When `M` is created or woken up, the scheduler guarantees that there is always an *idle* processor `P` so that it can be associated with `M` to run Go code.
If `M` is executing system call, it will be detached from `P` (will be described in [Handling System Calls](#handling-system-calls) section) and `P` might be acquired by another thread `M1` to continues its work.
If `M` can't find a runnable goroutine from its local run queue, the global run queue, or `netpoll` (will be described in [How netpoll Works](#how-netpoll-works) section), it keeps spinning to steal goroutines from other processors `P` and from the global run queue again.
Note that not all `M` enters spinning state, it does so only if the number of spinning threads is less than half of the number of busy processors.
When `M` has nothing to do, rather than being destroyed, it goes to sleep and waits to be acquired by a another processor `P1` later (described in [Finding a Runnable Goroutine](#finding-a-runnable-goroutine)).

The figure and table below described the state machine of threads in the GMP model.
Some states and transitions are omitted for simplicity.
*Spinning* is a substate of *idle*, in which thread consumes CPU cycles to solely execute Go runtime code that steals goroutine.
The actions that trigger state transitions will be described along the post.

|  State   | &nbsp;&nbsp;&nbsp; Description                  |
|:--------:|-------------------------------------------------|
| Running  | Executing Go runtime code, or user Go code      |
| Syscall  | Currently executing (blocking in) a system call |
| Spinning | Stealing goroutine from other processors        |
|  Sleep   | Sleeping, not consuming CPU cycle               |

| <img src="/assets/2025-03-11-go-scheduling/thread_state_machine.png" width=500> |
|:-------------------------------------------------------------------------------:|
|                      State machine of threads in GMP model                      |

### Processor: [`p`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L632-L757)

[`p`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L632-L757) struct conceptually represents a physical processor to execute goroutines.
Instances of [`p`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L632-L757) are called `P`, and they are created during the program's bootstrap phase.
While the number of threads created could be large ([10000](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L827-L827) in Go 1.24), the number of processors is usually small and determined by the [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS).
There are exactly [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) processors, regardless of its state.

To minimize lock contention on the global run queue, each processor `P` in the Go runtime maintains a local run queue.
A local run queue is not just a queue but composed of two components: [`runnext`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L655-L667) which holds a single prioritized goroutine, and [`runq`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L654-L654) which is a queue of goroutines.
Both of these components serve as a source of runnable goroutines for `P`, but [`runnext`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L655-L667) exists specifically as a performance optimization.
The Go scheduler allows `P` to steal goroutines from other processors `P1`'s local run queue.
`P1`'s [`runnext`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L655-L667) in only consulted if the first three attempts stealing from its [`runq`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L654-L654) is unsuccessful.
Therefore, when `P` wants to execute a goroutine, there is less lock contention if it looks for a runnable goroutine from its [`runnext`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L655-L667) first.

The [`runq`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L654-L654) component of `P` is an array-based, fixed-size, and circular queue.
By array-based and fixed-size with 256 slots, it allows better cache locality and reduces memory allocation overhead.
Fixed-size is safe for `P`'s local run queues as we also have the global run queue as a backup.
By circular, it allows efficiently adding and removing goroutines without needing to shift elements around.

Each `P` instance also maintains references to some memory management data structures such as [`mcache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mcache.go#L13-L55) and [`pageCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mpagecache.go#L14-L22).
[`mcache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mcache.go#L13-L55) serves as the front-end in [Thread-Caching Malloc](https://google.github.io/tcmalloc/design.html) model and is used by `P` to allocate micro and small objects.
[`pageCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mpagecache.go#L14-L22), on the other hand, enables the memory allocator to fetch memory pages without acquiring the [heap lock](https://www.ibm.com/docs/en/sdk-java-technology/8?topic=management-heap-allocation#the-allocator), thereby improving performance under high concurrency.

In order for a Go program to work well with [sleeps](https://pkg.go.dev/time#Sleep), [timeouts](https://pkg.go.dev/time#After) or [intervals](https://pkg.go.dev/time#Tick), `P` also manages timers implemented by [min-heap](https://en.wikipedia.org/wiki/Heap_(data_structure)) data structure, where the nearest timer is at the top of the heap.
When looking for a runnable goroutine, `P` also checks if there are any timers that have expired.
If so, `P` adds the corresponding goroutine with timer to its local run queue, giving chance for the goroutine to run.

The figure and table below described the state machine of processors in the GMP model.
Some states and transitions are omitted for simplicity.
The actions that trigger state transitions will be described along the post.

|                                          State                                          | &nbsp;&nbsp;&nbsp; Description                                                                         |
|:---------------------------------------------------------------------------------------:|--------------------------------------------------------------------------------------------------------|
|  [Idle](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L113-L120)   | Not executing Go runtime code or user Go code                                                          |
| [Running](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L122-L129) | Associated with a `M` that is executing user Go code                                                   |
| [Syscall](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L131-L141) | Associated with a `M` that is executing system call                                                    |
| [GCStop](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L143-L151)  | Associated with a `M` that is stopped-the-world for garbage collection                                 |
|  [Dead](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L153-L157)   | No longer in-used, waiting to be reused when [GOMAXPROCS](https://pkg.go.dev/runtime#GOMAXPROCS) grows |

| <img src="/assets/2025-03-11-go-scheduling/processor_state_machine.png" width=500> |
|:----------------------------------------------------------------------------------:|
|                      State machine of processors in GMP model                      |

At the early execution of a Go program, there are [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) processors `P` in the *idle* state.
When a thread `M` acquires a processor to run user Go code, `P` transitions to the *running* state.
If the current goroutine `G` makes a system call, `P` is detached from `M` and enters the *syscall* state.
During the system call, if `P` is seized by `sysmon` (see [Non-cooperative Preemption](#non-cooperative-preemption)), it first transitions to *idle*, then is handed off to another thread (`M1`) and enters the *running* state.
Otherwise, once the system call completes, `P` is reattached to last `M` and resumes the *running* state (see [Handling system calls](#handling-system-calls)).
When a stop-the-world garbage collection occurs, `P` transitions to the *gcStop* state and returns to its previous state once start-the-world resumes.
If [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) is decreased at runtime, redundant processors transition to the *dead* state and are reused if [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) increases later.

## Program Bootstrap

To enable the Go scheduler, it must be initialized during the program's bootstrap.
This initialization is handled in assembly via the [`runtime·rt0_go`](https://github.com/golang/go/blob/go1.24.0/src/runtime/asm_amd64.s#L159-L159) function.
During this phase, thread [`M0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L117-L117) (representing the main thread) and goroutine [`G0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L118-L118) ([`M0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L117-L117)'s system stack goroutine) are created.
[Thread-local storage](https://en.wikipedia.org/wiki/Thread-local_storage) (TLS) for the main thread is also set up, and the address of [`G0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L118-L118) is stored in this TLS, allowing it to be retrieved later via [`getg`](#getting-goroutine-getg).

The bootstrap process then invokes the assembly function [`runtime·schedinit`](https://github.com/golang/go/blob/go1.24.0/src/runtime/asm_amd64.s#L349), whose Go implementation can be found at [`runtime.schedinit`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L790-L898).
This function performs various initializations, most notably invoking [`procresize`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L5719-L5868), which sets up to [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) logical processors `P` in *idle* state.
The main thread [`M0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L117-L117) is then associated with the first processors, transitioning its state from *idle* to *running* to execute goroutines.

Afterward, the main goroutine is created to run [`runtime.main`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L146-L148) function, which serves as the Go runtime entry point.
Within the [`runtime.main`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L146-L148) function, a dedicated thread is created to launch `sysmon`, which will be described in [Non-cooperative Preemption](#non-cooperative-preemption) section.
Note that [`runtime.main`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L146-L148) is different from the `main` function that we write; the latter appears in the runtime as [`main_main`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L134-L135).

The main thread then calls [`mstart`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L1769-L1769) to begin execution on [`M0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L117-L117), starting the [schedule loop](#schedule-loop) to pick up and execute the main goroutine.
In the [`runtime.main`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L146-L148), after additional initialization steps, control is finally handed off to the user-defined [`main_main`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L134-L135) function, where the program begins executing user Go code.

It's worth noting that the main thread, [`M0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L117-L117), is responsible not only for running the main goroutine but also for executing other goroutines.
Whenever the main goroutine is blocked—such as waiting for a system call or while waiting on a channel—the main thread looks for another runnable goroutine and execute it.

Summing it up, when the program starts, there is one goroutine `G` executing the `main` function; two threads—one is the main thread `M0`, and the other is created to launch `sysmon`; one processor `P0` in *running* state, and `GOMAXPROCS−1` processors in *idle* state.
The main thread `M0` is initially associated with processor `P0` to run the main goroutine `G`.

The figure below illustrates the program's state at startup.
It assumes that [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) is set to 2 and that the `main` function has just started.
Processor `P0` is executing the main goroutine and is therefore in *running* state.
Processor `P1` is not executing any goroutine and is in *idle* state.
While the main thread `M0` is associated with processor `P0` to execute main goroutine, another thread `M1` is created to run `sysmon`.

| <img src="/assets/2025-03-11-go-scheduling/program_bootstrap.png" width=500> |
|:----------------------------------------------------------------------------:|
|                        Program bootstrap in GMP model                        |

It's worth to mention that during the bootstrap phase, the runtime also spawns several other goroutines related to memory management, such as marking, sweeping and scavenging.
However, we'll leave those out of scope for this post. They'll be explored in greater detail in a future article.

## Creating a Goroutine

Go offers us a simple API to start a concurrent execution unit: `go func() { ... } ()`.
Under the hood, Go runtime does a lot complicated work to make it happen.
The `go` keyword is just a syntactic sugar for Go runtime [`newproc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L5014-L5030) function, which is responsible for scheduling a new goroutine.
This function essentially does 3 things: initialize the goroutine, put it into the run queue of the processor `P` which the caller goroutine is running on, wake up another processor `P1`.

### Initializing Goroutine

When [`newproc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L5014-L5030) is called, it creates a new goroutine `G` only if there are no idle goroutines available.
Goroutines become idle after they return from execution.
The newly created goroutine `G` is initialized with a 2KB stack, as defined by the [`stackMin`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stack.go#L75-L75) constant in Go runtime.
Additionally, [`goexit`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stubs.go#L281-L291)—which handles cleanup logic and scheduling logic—is pushed onto `G`'s call stack to ensure it is executed when `G` returns.
After initialization, `G` transitions from *dead* state to *runnable* state, indicating that it's ready to be scheduled for execution.

### Putting Goroutine into Queue

As mentioned earlier, each processor `P` has a run queue composed of two parts: [`runnext`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L655-L667) and [`runq`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L654-L654).
When a new goroutine is created, it is placed in [`runnext`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L655-L667).
If [`runnext`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L655-L667) already contains a goroutine `G1`, the scheduler attempts to move `G1` to [`runq`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L654-L654)—provided [`runq`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L654-L654) is not full—and put `G` into [`runnext`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L655-L667).
If [`runq`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L654-L654) is full, `G1` along with half of the goroutines in [`runq`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L654-L654) are moved to the global run queue to reduce the workload for `P`.

### Waking Up Processor

When a new goroutine is created, and we aim to maximize program concurrency, the thread which goroutine is running on attempts to wake up another processor `P` by [`futex`](https://man7.org/linux/man-pages/man2/futex.2.html) system call. 
To do this, it first checks for any idle processors.
If an idle processor `P` is available, a new thread is either created or an existing one is woken up to enter the [schedule loop](#schedule-loop), where it will look for a runnable goroutine to execute.
The logic for creating or reusing thread is described in [Start Thread](#start-thread-startm) section.

As previously mentioned, [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS)—the number of active processors `P`—dictates how many goroutines can run concurrently.
If all processors are busy and new goroutines keep spawning, neither existing thread is woken up nor new thread is created.

### Putting It All Together

The figure below illustrates the process of how goroutines are created.
For simplicity, it assumes [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) is set to 2, processor `P1` hasn't entered the [schedule loop](#schedule-loop) yet, and `main` function does nothing but keeps spawning new goroutines.
Since goroutines don't execute system call (discussed in [Handling System Calls](#handling-system-calls) section), there is exactly one additional thread `M2` is created to associate with processor `P1`.

| <img src="/assets/2025-03-11-go-scheduling/creating_goroutine.png" /> |
|:---------------------------------------------------------------------:|
|                How goroutines are created in GMP model                |

## Schedule Loop

The [`schedule`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3986-L4068) function in the Go runtime is responsible for finding and executing a runnable goroutine.
It is invoked in various scenarios: when a new thread is created, when [`Gosched`](https://pkg.go.dev/runtime#Gosched) is called, when a goroutine is parked or preempted, or after a goroutine completes a system call and returns.

The process of selecting a runnable goroutine is complex and will be detailed in the [Finding a Runnable Goroutine](#finding-a-runnable-goroutine) section.
Once a goroutine is selected, it transitions from *runnable* to *running* state, signaling that it's ready to run.
At this point, a kernel thread invokes the [`gogo`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stubs.go#L214-L214) function to begin goroutine execution.

But why is it called a *loop*? As described in the [Initializing Goroutine](#initializing-goroutine) section, when a goroutine completes, the [`goexit`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stubs.go#L281-L291) function is invoked.
This function eventually leads to a call to [`goexit0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4307-L4310), which performs cleanup for the terminating goroutine and re-enters the [`schedule`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3986-L4068) function—bringing the [schedule loop](#schedule-loop) back.

The following diagram illustrates the schedule loop in Go runtime, where <span style="color:#c71585">pink</span> blocks happen in user Go code and <span style="color:#ffd700">yellow</span> blocks happen in the Go runtime code.
Although the following may seem obvious, please note that the schedule loop is executed by thread.
That's why it happens after thread initialization (the <span style="color:#0056b3">blue</span> block).

<table>
    <thead>
        <tr>
            <td>
                <pre class="mermaid" style="margin: unset">

graph LR
    subgraph Thread_Init[&nbsp]
    newm["newm()"] ==> mstart["mstart()"]
    mstart ==> mstart0["mstart0()"]
    mstart0 ==> mstart1["mstart1()"]
    end
    mstart1 ==> schedule["schedule()"]
    schedule ==> findrunnable["findrunnable()<br/>Find a runnable goroutine"]
    findrunnable ==> execute["execute()"]
    execute ==> gogo["gogo()<br/>Execute a goroutine"]
    gogo ==> |Goroutine executes code and returns|goexit["goexit()"]
    gogo ==> |Goroutine executes<br/>system call|entersyscall["entersyscall()"]
    entersyscall ==> exitsyscall["exitsyscall()"]
    exitsyscall ==> schedule
    goexit ==> goexit1["goexit1()"]
    goexit1 ==> goexit0["goexit0()"]
    goexit0 ==> schedule
    style Thread_Init fill:#bfdfff

                </pre>
            </td>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td style="text-align: center">
                The schedule loop in Go runtime
            </td>
        </tr>
    </tbody>
</table>

But if the main thread is stuck in schedule loop, how can the process exit?
Just take a look at the [`main`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L307-L307) function in Go runtime, which is executed by main goroutine.
After [`main_main`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L134-L135)—alias of the `main` function that Go programmers write—returns, [`exit`](https://man7.org/linux/man-pages/man3/exit.3.html) system call is invoked to terminate the process.
That's how the process can exit and the reason why the main goroutine doesn't wait for goroutines spawned by `go` keyword.

## Finding a Runnable Goroutine

It is the thread `M`'s responsibility to find a suitable runnable goroutine so that goroutine starvation can be minimized.
This logic is implemented in the [`findRunnable`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3267-L3646), which is called by the [schedule loop](#schedule-loop).

Thread `M` looks for a runnable goroutine the following order, stopping the chain if it finds one:
1. Check [trace reader](https://go.dev/blog/execution-traces-2024#trace-reader-api) goroutine's availability (used in [Non-cooperative Preemption](#non-cooperative-preemption) section).
2. Check garbage collection worker goroutine's availability (described in [Garbage Collector](#garbage-collector) section).
3. 1/61 of the time, check the global run queue.
4. Check local run queue of the associated processor `P` if `M` is spinning.
5. Check the global run queue again.
6. Check netpoll for I/O ready goroutine (described in [How netpoll Works](#how-netpoll-works) section). 
7. Steal from other processors `P1`'s local run queue.
8. Check garbage collection worker goroutine's availability again.
9. Check the global run queue again if `M` is spinning.

Step 1, 2 and 8 are for Go runtime internal use only.
In step 1, trace reader is used for tracing the execution of the program.
You will see how it's used in the [Goroutine Preemption](#goroutine-preemption) section later.
Meanwhile, step 2 and 8 allow the garbage collector to run concurrently with the regular goroutines.
Although these steps don't contribute to "user-visible" progress, they are essential for the Go runtime to function properly.

Step 3, 5 and 9 don't just take one goroutine but attempts to grab a batch for better efficiency.
The batch size is calculated as `(global_queue_size/number_of_processors)+1`, but it's limited by several factors: it won't exceed the specified maximum parameter, and won't take more than half of the P's local queue capacity.
After determining how many to take, it pops one goroutine to return directly (which will be run immediately) and puts the rest into the P's local run queue.
This batching approach helps with load balancing across processors and reduces contention on the global queue lock, as processors don't need to access the global queue as frequently.

Step 4 is a bit more tricky because the local run queue of `P` contains two parts: `runnext` and `runq`.
If `runnext` is not empty, it returns the goroutine in `runnext`.
Otherwise, it checks `runq` for any runnable goroutine and dequeue it.
Step 6 will be described in detail in [How netpoll Works](#how-netpoll-works) section.

Step 7 is the most complex part of the process.
It attempts up to four times to steal work from another processor, referred to as `P1`.
During the first three attempts, it tries to steal goroutines only from `P1`'s `runq`. 
If successful, half of the goroutines from `P1`'s `runq` are transferred to the current processor `P`'s `runq`.
On the last attempt, it first tries to steal from `P1`'s `runnext` slot—if available—before falling back to `P1`'s `runq`.

Note that [`findRunnable`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3267-L3646) not only finds a runnable goroutine but also wakes up goroutine that went into sleep before step 1 happens.
Once the goroutine wakes up, it'll be put into the local run queue of the processor `P` that was executing it, waiting to be picked up and executed by some thread `M`.

If no goroutine is found after step 9, thread `M` waits on `netpoll` until the nearest [timer](https://github.com/golang/go/blob/go1.24.0/src/runtime/time.go#L35-L107) expires—such as when a goroutine wakes up from sleep (since sleeping in Go internally creates a timer).
Why is `netpoll` involved with timers? This is because Go's timer system heavily relies on `netpoll`, as noted in [this](https://github.com/golang/go/blob/go1.24.0/src/runtime/time.go#L427-L427) code comment.
After `netpoll` returns, `M` re-enters the [schedule loop](#schedule-loop) to search for a runnable goroutine again.

The previous two behaviors of [`findRunnable`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3267-L3646) allows the Go scheduler to wake up asleep goroutines, allowing the program to continue executing.
They explain why every goroutine including the main one has chance to run after falling asleep.
Let's see how the following Go program works in another post 😄.

```go
package main

import "time"

func main() {
    go func() {
        time.Sleep(time.Second)
    }()
	
    time.Sleep(2*time.Second)
}
```

If `P` has no [timer](https://github.com/golang/go/blob/go1.24.0/src/runtime/time.go#L35-L107), its corresponding thread `M` will go idle.
`P` is placed into idle list, `M` goes to sleep by calling the [`stopm`](#stop-thread-stopm) function.
It remains asleep until another `M1` thread  wakes it up, typically upon the creation of a new goroutine, as explained in [Waking Up Processor](#waking-up-processor).
Once awakened, `M` reenters the [schedule loop](#schedule-loop) to search for and execute a runnable goroutine.

## Goroutine Preemption

Preemption is the act of temporarily interrupting a goroutine execution to allow other goroutines to run, preventing goroutine starvation.
There are two types of preemption in Go:

- Non-cooperative preemption: a too long-running goroutine is forced to stop.
- Cooperative preemption: a goroutine voluntarily yields its processor `P`.

Let's see how these two types of preemption work in Go.

### Non-cooperative Preemption

Let's take an example to understand how non-cooperative preemption works.
In this program, we have two goroutines that calculate the Fibonacci number, which is a tight loop with CPU intensive operations.
In order to make sure that only one goroutine can run at a time, we set the maximum number of logical processors to 1 using [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) when running the program: `GOMAXPROCS=1 go run main.go`.

```go
package main

import (
    "runtime"
    "time"
)

func fibonacci(n int) int {
    if n <= 1 {
        return n
    }   
    previous, current := 0, 1
    for i := 2; i <= n; i++ {
        previous, current = current, previous+current
    }
    return current
}

func main() {
    go fibonacci(1_000_000_000)
    go fibonacci(2_000_000_000)

    time.Sleep(3*time.Second)
}
```

Because there is exactly one processor `P`, there are many cases that could happen. 
One, neither goroutine runs because the main function has taken control of `P`.
Two, one goroutine runs while the other is starved of execution.
Three, somehow both goroutines run concurrently—almost magically.

Fortunately, Go does support us to get the idea of what is happening with the scheduling.
The [runtime/trace](https://go.dev/pkg/runtime/trace) package contains a powerful tool for understanding and troubleshooting Go programs.
To use it, we need to add instrument to the `main` method to export the traces to file.

```go
func main() {
    file, _ := os.Create("trace.out")
    _ = trace.Start(file)
    defer trace.Stop()
    ...
}
```

After the program finishes running, we use the command `go tool trace trace.out` to visualize the trace.
I have prepared the `trace.out` file [here](/assets/2025-03-11-go-scheduling/non_cooperative_preempt_trace.out) just in case you want to play with it.
In the figure below, the horizontal axis represents which goroutine is running on `P` at a given time.
As expected, there is only one logical processor `P` named "Proc 0", resulted from `GOMAXPROCS=1`.

| <img src="/assets/2025-03-11-go-scheduling/runtime_trace_start.png"> |
|:--------------------------------------------------------------------:|
|               Trace visualization when program starts                |

By zooming in (pressing 'W') to the start of the timeline, you can see that the process begins with `main.main` (the `main` function in the `main` package), which runs on the main goroutine, G1.
After a few microseconds, still on Proc 0, goroutine G10 is scheduled to execute the `fibonacci` function, taking over the processor and preempting G1.

| <img src="/assets/2025-03-11-go-scheduling/runtime_trace_preempt.png"> |
|:----------------------------------------------------------------------:|
|      Trace visualization when non-cooperative preemption happens       |

By zooming out (pressing 'S') and scrolling slightly to the right, it can be observed that G10 is later replaced by another goroutine, G9, which is the next instance running the `fibonacci` function.
This goroutine is also executed on Proc 0. Pay attention to `runtime.asyncPreempt:47` in the figure, I will explain this in a moment.

From the demo, it can be concluded that the Go is capable of preempting goroutines that are CPU-bound.
But why is it possible because if a goroutines continuously taking up the CPU, how can it be preempted?
This is a hard problem and there was a long [discussion](https://github.com/golang/go/issues/10958) on the Go issue tracker.
The problem was not addressed until Go 1.14, where asynchronous preemption was firstly introduced.

In Go runtime, there is a daemon running on a dedicated thread `M` without a `P`, called `sysmon` (i.e. system monitor). 
When `sysmon` finds a goroutine that has been using `P` for more than 10ms ([`forcePreemptNS`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L6245-L6245) constant in Go runtime), it signals thread `M` by executing [`tgkill`](https://man7.org/linux/man-pages/man2/tkill.2.html) system call to forcefully preempt the running goroutine.
Yes, you didn't read that wrong. According to the [Linux manual page](https://man7.org/linux/man-pages/man2/tkill.2.html), [`tgkill`](https://man7.org/linux/man-pages/man2/tkill.2.html) is used to send a signal to a thread, not to kill a thread.
The signal is `SIGURG`, and the reason it being chosen is described [here](https://github.com/golang/go/blob/go1.24.0/src/runtime/signal_unix.go#L43-L73).

Upon receiving `SIGURG`, the execution of the program is transferred to the signal handler, registered by a call of [`initsig`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L1879-L1879) function upon thread initialization.
Note that the signal handler can run concurrently with goroutine code or the scheduler code, as depicted in the figure below.
The execution switch from main program to signal handler is triggered by the kernel<a href="https://stackoverflow.com/questions/6949025/how-are-asynchronous-signal-handlers-executed-on-linux/"><sup>4,</sup></a><a href="https://unix.stackexchange.com/questions/733013/how-is-a-signal-delivered-in-linux"><sup>5</sup></a>.

| <img src="/assets/2025-03-11-go-scheduling/signal_delivery_and_handler_execution.png" width=500 /> | 
|:--------------------------------------------------------------------------------------------------:| 
|            Signal delivery and handler execution<sup><a href="#references">6</a></sup>             |

In the signal handler, the program counter is set to the [`asyncPreempt`](https://github.com/golang/go/blob/go1.24.0/src/runtime/preempt.go#L295-L299) function, allowing the goroutine to be suspended and creating space for preemption.
In the assembly implementation of [`asyncPreempt`](https://github.com/golang/go/blob/go1.24.0/src/runtime/preempt_arm64.s) function, it saves the goroutine's registers and call [`asyncPreempt2`](https://github.com/golang/go/blob/go1.24.0/src/runtime/preempt.go#L302-L311) function at line [47](https://github.com/golang/go/blob/go1.24.0/src/runtime/preempt_arm64.s#L47).
That is reason for the appearance of `runtime.asyncPreempt:47` in the visualization.
In [`asyncPreempt2`](https://github.com/golang/go/blob/go1.24.0/src/runtime/preempt.go#L302-L311), the goroutine `g0` of thread `M` will enter [`gopreempt_m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4191-L4193) to disassociate goroutine `G` from `M` and enqueue `G` into the global run queue.
The thread then continues with the [schedule loop](#schedule-loop), finding another runnable goroutine and execute it.

As preemption signal is triggered by `sysmon` but the actual preemption doesn't happen until the thread receives preemption signal, this kind of preemption is asynchronous.
That's why goroutines can actually run beyond the time limit 10ms, like goroutine G9 in the example.

| <img src="/assets/2025-03-11-go-scheduling/non_cooperative_preemption.png" width=600 /> | 
|:---------------------------------------------------------------------------------------:| 
|                         Non-cooperative preemption in GMP model                         |

### Cooperative Preemption in Early Go

In the early days of Go, Go runtime itself was not able to preempt a goroutines that have tight loop like the example above.
We, as Go programmers, had to tell goroutines to cooperatively give up its processor `P` by making a call to [`runtime.Gosched()`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L358-L365) in the loop body.
There was a Stackoverflow [question](https://stackoverflow.com/questions/13107958/what-exactly-does-runtime-gosched-do) that described an example and the behavior of [`runtime.Gosched()`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L358-L365).

From the programmer's point of view, this is very tedious and error-prone, and it did have some performance [issue](https://github.com/golang/go/issues/12553) in actuality.
Therefore, the Go team has decided to implement a clever way to preempt the goroutine by the runtime itself.
This will be discussed in the next section.

### Cooperative Preemption Since Go 1.14

Do you wonder why I didn't use `fmt.Printf` in each iteration and check the terminal to see whether both goroutines have chance to run?
That's because if I had done that, it would have become a cooperative preemption, not a non-cooperative preemption anymore.

#### Disassemble the Program
To better understand this, let's compile the program and analyze its assembly code.
Since the Go compiler applies various optimizations that can make debugging more challenging, we need to disable them when building the program.
This can be done by `go build -gcflags="all=-N -l" -o fibonacci main.go`.

For easier debugging, I use [Delve](https://github.com/go-delve/delve), a powerful debugger for Go, to disassemble the `fibonacci` function: `dlv exec ./fibonacci`.
Once inside the debugger, I run the following command to view the assembly code of the `fibonacci` function: `disassemble -l main.fibonacci`.
You can find the assembly code of the original program [here](/assets/2025-03-11-go-scheduling/non_cooperative_preempt.s).
As I'm building the program on my local machine, which is darwin/arm64, the assembly code built on your machine could be different from mine.

That's all set, let's take a look at the assembly of the `fibonacci` function to see what it does.
```
      main.go:11      0x1023e8890     900b40f9        MOVD 16(R28), R16
      main.go:11      0x1023e8894     f1c300d1        SUB $48, RSP, R17
      main.go:11      0x1023e8898     3f0210eb        CMP R16, R17
      main.go:11      0x1023e889c     090c0054        BLS 96(PC)
      ...
      main.go:17      0x1023e8910     6078fd97        CALL runtime.convT64(SB)
      ...
      main.go:17      0x1023e895c     4d78fd97        CALL runtime.convT64(SB)
      ...
      main.go:20      0x1023e8a18     c0035fd6        RET
      main.go:11      0x1023e8a1c     e00700f9        MOVD R0, 8(RSP)
      main.go:11      0x1023e8a20     e3031eaa        MOVD R30, R3
      main.go:11      0x1023e8a24     dbe7fe97        CALL runtime.morestack_noctxt(SB)
      main.go:11      0x1023e8a28     e00740f9        MOVD 8(RSP), R0
      main.go:11      0x1023e8a2c     99ffff17        JMP main.fibonacci(SB)
```

`MOVD 16(R28), R16` loads the value at offset 16 from the register `R28`, which holds the goroutine data structure [`g`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L396-L396), and store that value in register `R16`.
The loaded value is the [`stackguard0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L405-L405) field, which serves as the stack guard for the current goroutine.
But what exactly is a stack guard? You may know that a goroutine’s stack is growable, but how does Go runtime determine when it needs to grow?
The stack guard is a special value placed at the end of the stack. When the stack pointer reaches this value, Go runtime detects that the stack is nearly full and needs to grow—that’s exactly what the next three instructions do.

`SUB $48, RSP, R17` loads the goroutine's stack pointer from the register `RPS` to register `R17` and subtracts 48 from it.
`CMP R16, R17` compares the stack guard with the stack pointer, and `BLS 96(PC)` branches to the instruction located 96 instructions ahead in the program if the stack pointer is less than or equal to the stack guard.
Why less than or equal (≤) but not greater or equal (≥)?
Because stack grows downward, the stack pointer is always greater than the stack guard.

Have you ever wondered why these instructions don’t appear in the Go code but still show up in the assembly?
That's because upon compiling, Go compiler automatically inserts these instructions in function [prologue](https://en.wikipedia.org/wiki/Function_prologue_and_epilogue).
This applies for every function like `fmt.Println`, not just our `fibonacci`.

After advancing 96 instructions, execution reaches the `MOVD R0, 8(RSP)` instruction and then proceeds to `CALL runtime.morestack_noctxt(SB)`.
[`runtime.morestack_noctxt`](https://github.com/golang/go/blob/go1.24.0/src/runtime/asm_arm64.s#L348-L348) function will eventually call [`newstack`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stack.go#L966-L966) to grow the stack and optionally enter [`gopreempt_m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4191-L4193) to trigger preemption as discussed in non-cooperative preemption.
The key point of cooperative preemption is the condition for entering `gopreempt_m`, which is [`stackguard0 == stackPreempt`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stack.go#L1025-L1025).
This means that whenever a goroutine wants to extend its stack, it will be preempted if its `stackguard0` was set to [`stackPreempt`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stack.go#L128-L130) earlier.

[`stackPreempt`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stack.go#L128-L130) can be set by the `sysmon` if a goroutine has been running for more than 10ms.
The goroutine will then be cooperatively preempted if it makes a function call or non-cooperatively preempted by the thread's signal handler, whichever happens first.
It can also be set when the goroutine enters or exits a system call or during the tracing phase of the garbage collector.
See [sysmon preemption](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L6366-L6366), [syscall entry](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4525-L4525)/[exit](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4663-L4663), [garbage collector tracing](https://github.com/golang/go/blob/go1.24.0/src/runtime/trace.go#L389-L389).

#### Trace Visualization

Alright, let's rerun the program—make sure `GOMAXPROCS=1` is set—and then check out the trace.

| <img src="/assets/2025-03-11-go-scheduling/runtime_trace_cooperative_preempt.png" > |
|:-----------------------------------------------------------------------------------:|
|               Trace visualization when cooperative preemption happens               |

You can clearly see that goroutines relinquish the logical processor after just tens of microseconds—unlike with non-cooperative preemption, where they might retain it for over 10 milliseconds.
Notably, G9’s stack trace ends at the `fmt.Printf` inside the loop body, demonstrating the stack guard check in function prologue.
This visualization precisely illustrates cooperative preemption, where goroutines *voluntarily* yield the processor.

| <img src="/assets/2025-03-11-go-scheduling/cooperative_preemption.png" width=600 /> | 
|:-----------------------------------------------------------------------------------:| 
|                         Cooperative preemption in GMP model                         |

## Handling System Calls

[System calls](https://en.wikipedia.org/wiki/System_call) are services provided by the kernel that user-space applications access through an API.
These services include fundamental operations, for example, reading files, establishing connections, or allocating memory.
In Go, you rarely need to interact with system calls directly, as the standard library offers higher-level abstractions that simplify these tasks.

However, understanding how system calls work is crucial to gaining insight into Go runtime, standard library internals, as well as performance optimization.
Go's runtime employs an M:N threading model, further optimized by the use of logical processors `P`, making its approach to handling system calls particularly interesting.

### System Call Classification

In Go runtime, there are two wrapper functions around kernel system calls: [`RawSyscall`](https://github.com/golang/go/blob/go1.24.0/src/syscall/syscall_linux.go#L54-L56) and [`Syscall`](https://github.com/golang/go/blob/go1.24.0/src/syscall/syscall_linux.go#L72-L89).
The Go code we write uses these functions to invoke system calls. Each function accepts a system call number, its arguments, and returns values along with an error code.

[`Syscall`](https://github.com/golang/go/blob/go1.24.0/src/syscall/syscall_linux.go#L72-L89) is typically used for operations with unpredictable durations, such as reading from a file or writing an HTTP response.
Since the duration of these operations is non-deterministic, Go runtime needs to account for them to ensure efficient use of resources.
The function coordinates goroutines `G`, threads `M`, and processors `P`, allowing the Go runtime to maintain performance and responsiveness during blocking system calls.

Nevertheless, not all system calls are unpredictable. For example, retrieving the process ID or getting the current time is usually quick and consistent. For these types of operations, [`RawSyscall`](https://github.com/golang/go/blob/go1.24.0/src/syscall/syscall_linux.go#L54-L56) is used.
Since no scheduling is involved, the association between goroutines `G`, threads `M`, and processors `P` remains intact when raw system calls are made.

Internally, [`Syscall`](https://github.com/golang/go/blob/go1.24.0/src/syscall/syscall_linux.go#L72-L89) delegates to [`RawSyscall`](https://github.com/golang/go/blob/go1.24.0/src/syscall/syscall_linux.go#L54-L56) to perform the actual system call, but wraps it with additional scheduling logic, which will be described in detail in the next section.

```go
func Syscall(trap, a1, a2, a3 uintptr) (r1, r2 uintptr, err Errno) {
    runtime_entersyscall()
    r1, r2, err = RawSyscall6(trap, a1, a2, a3, 0, 0, 0)
    runtime_exitsyscall()
}
```

### Scheduling in `Syscall`

The scheduling logic is implemented in [`runtime_entersyscall`](https://github.com/golang/go/blob/go1.24.0/src/syscall/syscall_linux.go#L28-L29) function and [`runtime_exitsyscall`](https://github.com/golang/go/blob/go1.24.0/src/syscall/syscall_linux.go#L31-L32) function, respectively before and after actual system call is made.
Under the hood, these functions are actually [`runtime.entersyscall`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4512-L4532) and [`runtime.exitsyscall`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4644-L4747).
This association are created at compile time.

Before an actual system call is made, Go runtime records that the invoking goroutine is no longer using the CPU.
The goroutine `G` transitions from *running* state to *syscall* state, and its stack pointer, program counter, and frame pointer are saved for later restoration.
The association between thread `M` and processor `P` is then temporarily detached, and `P` transitions to *syscall* state.
This logic is implemented in the [`runtime.reentersyscall`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4413-L4510), which is invoked by [`runtime.entersyscall`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4512-L4532).

Interestingly, the `sysmon` (mentioned in the [Non-cooperative Preemption](#non-cooperative-preemption) section) monitors not only processors running goroutine code (where `P` is in *running* state), but also those making system calls (where `P` is in *syscall* state).
If a `P` remains in *syscall* state for more than 10ms, instead of non-cooperatively preempting the running goroutine, a [processor handoff](#processor-handoff-handoffp) takes place.
This keeps the association between goroutine `G` and thread `M`, and attaches another  thread `M1` to this `P`, allowing runnable goroutines to run on that `M1` thread.
Apparently, as `P` is now executing code, its status is running rather than syscall as before.

Note that while system call is still in progress and whether `sysmon` happens to seize `P` or not, the association between goroutine `G` and thread `M` still remains.
Why? Because the Go program (including Go runtime and Go code we write) are just user-space process.
The only mean of execution that kernel provides user-space process is thread.
It is the responsibility of thread to run Go runtime code, user Go code and make system call.
A thread `M` makes system call on behalf of some goroutine `G`, that's why the association between them is maintained as-is.
Therefore, even if `P` is seized by `sysmon`, `M` remains blocked, waiting for the system call to complete before it can invoke the [`runtime.exitsyscall`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4644-L4747) function.

Another important point is that whenever a processor `P` is in *syscall* state, <u>it can't be taken up by another thread M to execute code</u> until `sysmon` happens to seize it or until the system call is completed.
Therefore, in case there are multiple system calls happening at the same time, the program (excluding system calls) doesn't make any progress.
That's why [Dgraph](https://docs.hypermode.com/dgraph/overview) database hardcodes [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) to 128 to ["allow more disk I/O calls to be scheduled"](https://github.com/hypermodeinc/dgraph/blob/v24.1.2/dgraph/main.go#L33-L36).

As described in [`runtime.exitsyscall`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4644-L4747), there are two paths the scheduler can take after the syscall is finished: fast path and slow path.
The latter only takes place if the former is not possible.

The fast path occurs when if is a processor `P` available to execute the goroutine `G` that has just completed its system call.
This `P` can either be the same one that previously executed `G`, if it is still in the *syscall* state (i.e., it hasn’t been seized by `sysmon`), or any other processor `P1` currently in the *idle* state—whichever is found first.  
Note that when system call completes, the previous process `P` might not be in *syscall* state anymore bcause `sysmon` has seized it.
Before the fast path exits, `G` transition from *syscall* state to *running* state.

| <img src="/assets/2025-03-11-go-scheduling/syscall_fast_path_1.png" width=300/> | <img src="/assets/2025-03-11-go-scheduling/syscall_fast_path_2.png" width=500/> |
|:-------------------------------------------------------------------------------:|:-------------------------------------------------------------------------------:|
|      System call fast path when <br/> `sysmon` doesn't seize processor `P`      |         System call fast path when <br/> `sysmon` seizes processor `P`          | 


In the slow path, the scheduler tries retrieving any idle processor `P` once again.
If it's found, the goroutine `G` is scheduled to run on that `P`.
Otherwise, `G` is enqueued into the global run queue and the associated thread `M` is stopped by [`stopm`](#stop-thread-stopm) function, waiting to be woken up to continue the [schedule loop](#schedule-loop).

## Network I/O and File I/O

This [survey](https://go.dev/blog/survey2024h2/what.svg) shows that 75% of Go uses cases are web services and 45% are static websites.
It's not a coincidence, Go is designed to be efficient for I/O operations to solve the notorious problem—[C10K](https://en.wikipedia.org/wiki/C10k_problem).
To see how Go solves it, let's take a look at how Go handles I/O operations under the hood.

### HTTP Server Under the Hood

In Go, it's incredibly straightforward to start an HTTP server. For example:

```go
package main

import "net/http"

func main() {
    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(200)
    })
	
    http.ListenAndServe(":80", nil)
}
```

Functions like `http.ListenAndServe()` and `http.HandleFunc()` might seem deceptively simple—but under the hood, they abstract away a lot of low-level networking complexity.
Go relies on many fundamental [socket](https://en.wikipedia.org/wiki/Unix_domain_socket) operations (depicted in the figure below) to manage network communication.

| <img src="/assets/2025-03-11-go-scheduling/socket_system_calls_in_http_server.png" width=300/> | 
|:----------------------------------------------------------------------------------------------:| 
|    Overview of system calls used with stream sockets<sup><a href="#references">7</a></sup>     |

Specifically, `http.ListenAndServe()` leverages [`socket()`](https://man7.org/linux/man-pages/man2/socket.2.html), [`bind()`](https://man7.org/linux/man-pages/man2/bind.2.html), [`listen()`](https://man7.org/linux/man-pages/man2/listen.2.html), [`accept()`](https://man7.org/linux/man-pages/man2/accept.2.html) system calls to create TCP sockets, which are essentially [file descriptors](https://en.wikipedia.org/wiki/File_descriptor).
It binds the TCP listening socket to the specified address and port, listens for incoming connections, and creates a new connected socket to handle client requests.
This is achieved without requiring you to write socket-handling code.
Similarly, `http.HandleFunc()` registers your handler functions, abstracting away the lower-level details like using [`read()`](https://man7.org/linux/man-pages/man2/read.2.html) system call to read data, and [`write()`](https://man7.org/linux/man-pages/man2/write.2.html) system call to write data to the network socket.

| <img src="/assets/2025-03-11-go-scheduling/go_http_server_meme.jpg" width=300/> | 
|:-------------------------------------------------------------------------------:| 
|      Go abstracts system calls to provide simple interface for HTTP server      |

However, it's not that simple for an HTTP server to handle tens of thousands of concurrent requests efficiently.
Go employs several techniques to achieve this. Let's take a closer look at some notable I/O models in Linux and how Go takes advantage of them.

### Blocking I/O, Non-blocking I/O and I/O Multiplexing

An I/O operation can be either blocking or non-blocking.
When a thread issues a blocking system call, its execution is suspended until the system call completes with the requested data.
In contrast, non-blocking I/O doesn't suspend the thread; instead, it returns the requested data if available, or an error (<a href="https://man7.org/linux/man-pages/man3/errno.3.html#:~:text=POSIX.1%2D2001\).-,EAGAIN,-Resource%20temporarily%20unavailable">`EAGAIN`</a> or <a href="https://man7.org/linux/man-pages/man3/errno.3.html#:~:text=POSIX.1%2D2001\).-,EAGAIN,-Resource%20temporarily%20unavailable">`EWOULDBLOCK`</a>) if the data is not yet ready.
Blocking I/O is simpler to implement but inefficient, as it requires the application to spawn N threads for N connections.
In contrast, non-blocking I/O is more complex, but when implemented correctly, it enables significantly better resource utilization.
See the figures below for a visual comparison of these two models.

| <img src="/assets/2025-03-11-go-scheduling/blocking_io.png" width=300/> | <img src="/assets/2025-03-11-go-scheduling/non_blocking_io.png" width=300/> |
|:-----------------------------------------------------------------------:|:---------------------------------------------------------------------------:|
|        Blocking I/O model<sup><a href="#references">8</a></sup>         |        Non-blocking I/O model<sup><a href="#references">9</a></sup>         |

Another I/O model worth mentioning is I/O multiplexing, in which [`select`](https://man7.org/linux/man-pages/man2/select.2.html), or [`poll`](https://man7.org/linux/man-pages/man2/poll.2.html) system call is used to wait for one of a set of file descriptors to become ready to perform I/O.
In this model, the application blocks on one of these system calls, rather than on the actual I/O system calls, such as [`recvfrom`](https://man7.org/linux/man-pages/man2/recv.2.html) shown in the figures above.
When [`select`](https://man7.org/linux/man-pages/man2/select.2.html) returns that the socket is readable, the application calls [`recvfrom`](https://man7.org/linux/man-pages/man2/recv.2.html) to copy requested data to application buffer in user space.

| <img src="/assets/2025-03-11-go-scheduling/io_multiplexing.png" width=500/> |
|:---------------------------------------------------------------------------:|
|        I/O multiplexing model<sup><a href="#references">10</a></sup>        |

### I/O Model in Go

Go uses a combination of non-blocking I/O and I/O multiplexing to handle I/O operations efficiently.
Due to the performance limitations of [`select`](https://man7.org/linux/man-pages/man2/select.2.html) and [`poll`](https://man7.org/linux/man-pages/man2/poll.2.html)  —as explained in this [blog](https://jvns.ca/blog/2017/06/03/async-io-on-linux--select--poll--and-epoll/#why-don-t-we-use-poll-and-select)—Go avoids them in favor of more scalable alternatives: [epoll](https://man7.org/linux/man-pages/man7/epoll.7.html) on Linux, [kqueue](https://man.freebsd.org/cgi/man.cgi?kqueue) on Darwin, and [IOCP](https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports) on Windows.
Go introduces netpoll, a function that abstracts these alternatives, to provide a unified interface for I/O multiplexing across different OS.

## How netpoll Works

Working with netpoll requires 4 steps: creating an [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) instance in kernel space, registering file descriptors with the [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) instance, [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) polls for I/O on file descriptors, and unregistering file descriptors from the [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) instance.
Let's see how Go implements these steps.

### Creating epoll Instance and Registering Goroutine

When a TCP listener [accepts](https://github.com/golang/go/blob/go1.24.0/src/net/tcpsock.go#L374-L385) a connection, [`accept4`](https://man7.org/linux/man-pages/man2/accept.2.html) system call is invoked with [`SOCK_NONBLOCK`](https://man7.org/linux/man-pages/man2/socket.2.html#:~:text=of%0A%20%20%20%20%20%20%20socket()%3A-,SOCK_NONBLOCK,-Set%20the%20O_NONBLOCK) flag to set the socket's file descriptor of the socket to non-blocking mode.
Following this, several descriptors are created to integrate with Go runtime's netpoll.

1. An instance of [`net.netFD`](https://github.com/golang/go/blob/go1.24.0/src/net/fd_posix.go#L16-L27) is created to wrap the socket’s file descriptor.
This struct provides a higher-level abstraction for performing network operations on the underlying kernel file descriptor.
When an instance of [`net.netFD`](https://github.com/golang/go/blob/go1.24.0/src/net/fd_posix.go#L16-L27) is initialized, [`epoll_create`](https://man7.org/linux/man-pages/man2/epoll_create.2.html) system call is invoked to create an [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) instance. 
The [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) instance is initialized in the [`poll_runtime_pollServerInit`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L213-L216) function, which is wrapped in a [`sync.Once`](https://pkg.go.dev/sync#Once) to ensure it runs only once.
Because of [`sync.Once`](https://pkg.go.dev/sync#Once), only a **single** [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) instance exists within a Go process and is used throughout the lifetime of the process.
2. Inside [`poll_runtime_pollOpen`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L243-L278), Go runtime allocates a [`runtime.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L72-L115) instance, which contains scheduling metadata and [references](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L98-L101) to the goroutines involved in I/O.
The socket's file descriptor is then registered with the interest list of [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) using [`epoll_ctl`](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html) system call with [`EPOLL_CTL_ADD`](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html#:~:text=op%20argument%20are%3A-,EPOLL_CTL_ADD,-Add%20an%20entry) operation.
As [`epoll`]((https://man7.org/linux/man-pages/man7/epoll.7.html)) monitors file descriptors rather than goroutines, [`epoll_ctl`](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html) also associates the file descriptor with an instance of [`runtime.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L72-L115), allowing the Go scheduler to identify which goroutine should be resumed when I/O readiness is reported.
3. An instance of [`poll.FD`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_unix.go#L17-L48) is created to manage read and write operations with polling support.
It holds a reference to a [`runtime.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L72-L115) indirectly via [`poll.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_poll_runtime.go#L32-L34), which is simply a wrapper.

> ⚠️ Go does have problem with a single `epoll` instance as described in [this](https://github.com/golang/go/issues/65064) open issue.
> There are discussions [whether Go should use a single or multiple `epoll` instances](https://github.com/golang/go/issues/65064#issuecomment-1896633168), or even [use another I/O multiplexing model like `io_uring`](https://github.com/golang/go/issues/31908).

Building on the success of this model for network I/O, Go also leverages [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) for file I/O.
Once a file is opened, [`syscall.SetNonblock`](https://github.com/golang/go/blob/go1.24.0/src/os/file_unix.go#L222-L222) function is called to enable non-blocking mode for the file descriptor.
Subsequently, [`poll.FD`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_unix.go#L17-L48), [`poll.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_poll_runtime.go#L32-L34) and [`runtime.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L72-L115) instances are initialized to register the file descriptor with [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html)'s interest list, allowing file I/O to be multiplexed as well.

The relationship between these descriptors is depicted in the figure below.
Meanwhile [`net.netFD`](https://github.com/golang/go/blob/go1.24.0/src/net/fd_posix.go#L16-L27), [`os.File`](https://github.com/golang/go/blob/go1.24.0/src/os/types.go#L15-L20), [`poll.FD`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_unix.go#L17-L48), and [`poll.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_poll_runtime.go#L32-L34) are implemented in user Go code (specifically in the Go standard library), [`runtime.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L72-L115) resides within Go runtime itself.

| <img src="/assets/2025-03-11-go-scheduling/netpoll_descriptors.png"/> |
|:---------------------------------------------------------------------:|
|                   Relationship of descriptors in Go                   |

### Polling File Descriptors

When a goroutine reads from socket or file, it eventually invokes the [`Read`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_unix.go#L141-L173) method of [`poll.FD`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_unix.go#L17-L48).
In this method, the goroutine makes [`read`](https://man7.org/linux/man-pages/man2/read.2.html) system call to get any available data from the file descriptor.
If the I/O data is not ready yet, i.e. `EAGAIN` error is returned, Go runtime invokes [`poll_runtime_pollWait`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L336-L361) method to [park the goroutine](#goroutine-parking-gopark).
The behavior is similar when a goroutine writes to a socket or file, with the main difference being that [`Read`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_unix.go#L141-L173) is replaced by [`Write`](https://github.com/golang/go/blob/go1.24.0/src/net/net.go#L201-L211), and the [`read`](https://man7.org/linux/man-pages/man2/read.2.html) system call is substituted with [`write`](https://man7.org/linux/man-pages/man2/write.2.html).
Now that the goroutine is in *waiting* state, it is the responsibility of netpoll to present goroutine to the Go runtime when the goroutine's file descriptor is ready for I/O so that it can be resumed.

In Go runtime, netpoll is nothing more than a function having the same name.
In [netpoll](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll_epoll.go#L91-L176) function, [`epoll_wait`](https://man7.org/linux/man-pages/man2/epoll_wait.2.html) system call is used to monitor up to 128 file descriptors in a specified amount of time.
This system call returns the [`runtime.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L72-L115) instances that were previously registered (as described in the previous section) for each file descriptor that becomes ready.
Finally, netpoll extracts the goroutine references from [`runtime.pollDesc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L72-L115) and hands them off to the Go runtime.

But when is the netpoll function actually called?
It's triggered when a thread looks for a runnable goroutine to execute, as outlined in [schedule loop](#schedule-loop).
According to [`findRunnable`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3267-L3646) function, netpoll is only consulted by the Go runtime if there are no goroutines available in either the local run queue of the current `P` or the global run queue.
This means even if its file descriptor is ready for I/O, the goroutine is not necessarily woken up immediately.

As mentioned earlier, netpoll can block for a specified amount of time, and this is determined by the `delay` parameter.
If `delay` is positive, it blocks for the specified number of nanoseconds.
If `delay` is negative, it blocks until an I/O event becomes ready.
Otherwise, when `delay` is zero, it returns immediately with any I/O events that are currently ready.
In the [`findRunnable`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3267-L3646) function, `delay` is passed with 0, which means that if one goroutine is waiting for I/O, another goroutine can be scheduled to run on the same kernel thread.

### Unregistering File Descriptors

As mentioned above, [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) instance monitors up to 128 file descriptors.
Therefore, it's important to unregister file descriptors when they are no longer needed otherwise some goroutines may be starved.
When file or network connection is no longer in used, we should close it by calling its `Close` method.

Under the hood, the [`destroy`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_unix.go#L75-L87) method of [`poll.FD`](https://github.com/golang/go/blob/go1.24.0/src/internal/poll/fd_unix.go#L75-L87) is called.
This method eventually invokes the function [`poll_runtime_pollClose`](https://github.com/golang/go/blob/go1.24.0/src/runtime/netpoll.go#L280-L295) in Go runtime to make [`epoll_ctl`](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html) with `EPOLL_CTL_DEL` operation.
This unregisters the file descriptor from the [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html)'s interest list.

### Putting It All Together

The figure below illustrates the entire process of how netpoll works in Go runtime with file I/O.
The process for network I/O is similar, but with the addition of a TCP listener that accepts connection and connection is closed.
For simplicity purpose, other components in such as `sysmon` and other idle processors `P` are omitted.

| <img src="/assets/2025-03-11-go-scheduling/netpoll_in_gmp_model.png" width=350 /> |
|:---------------------------------------------------------------------------------:|
|                          How netpoll works in GMP model                           |

## Garbage Collector

You may know that Go includes a garbage collector (GC) to automatically reclaim memory from unused objects.
However, as mentioned in the [Program Bootstrap](#program-bootstrap) section, when the program starts, there are no threads initially available to run the GC.
So where does the GC actually run?

Before we answer that question, let’s take a quick look at how garbage collection works.
Go uses a tracing garbage collector, which identifies live and dead objects by traversing the allocated object graph starting from a set of root references.
Objects that are reachable from the roots are considered live; those that are not are considered dead and eligible for reclamation.

Go’s GC implements a [tri-color marking algorithm](https://en.wikipedia.org/wiki/Tracing_garbage_collection#Tri-color_marking) with support for [weak references](https://learn.microsoft.com/en-us/dotnet/standard/garbage-collection/weak-references).
This design allows the garbage collector to run concurrently with the program, significantly reducing stop-the-world (STW) pauses and improving overall performance.

A Go garbage collection cycle can be divided into 4 stages:
1. **First STW**: The process is paused so that all processors `P` can enter the safe point.
2. **Marking phase**: GC goroutines takes processor `P` shortly to mark reachable objects.
3. **Second STW**: The process is paused again to allow the GC to finalize the marking phase.
4. **Sweeping phase**: Unpause the process and reclaim memory for unreachable objects in background.

Note that in step 2, garbage collection worker goroutine runs concurrently with regular goroutines on the same processor `P`.
The [`findRunnable`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3267-L3646) function (mentioned in [Finding a Runnable Goroutine](#finding-a-runnable-goroutine) section) not only looks for regular goroutines but also for GC goroutines (step 1 and 2).

## Common Functions

### Getting Goroutine: [`getg`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stubs.go#L28-L31)

In Go runtime, there is a common function that is used to retrieve the running goroutine in current kernel thread: [`getg()`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stubs.go#L28-L31).
Taking a glance at the source code, you can see no implementation for this function.
That's because upon compiling, the compiler rewrites calls to this function into instructions that fetch the goroutine from [thread-local storage](https://en.wikipedia.org/wiki/Thread-local_storage) (TLS) or from registers.

But when is the current goroutine stored in thread-local storage so it can be retrieved later?
This happens during a goroutine context switch in the [`gogo`](https://github.com/golang/go/blob/go1.24.0/src/runtime/asm_amd64.s#L411-L413) function, which is called by [`execute`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3221-L3265).
It also takes place when a signal handler is invoked, in the [`sigtrampgo`](https://github.com/golang/go/blob/go1.24.0/src/runtime/signal_unix.go#L420-L495) function.

### Goroutine Parking: [`gopark`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L390-L436)

This is a commonly used procedure in Go runtime for transitioning the current goroutine into a *waiting* state and scheduling another goroutine to run.
The snippet below highlights some of its key aspects.

```go
func gopark(unlockf func(*g, unsafe.Pointer) bool, ...) {
    ...
    mp.waitunlockf = unlockf
    ...
    releasem(mp)
    ...
    mcall(park_m)
}
```

Inside [`releasem`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime1.go#L612-L619) function, the goroutine's [`stackguard0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L405-L405) is set to [`stackPreempt`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stack.go#L128-L130) to trigger an eventual cooperative preemption.
The control is then transferred to the [`g0`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L529) system goroutine, which belongs to the same thread currently running the goroutine, to invoke the [`park_m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4089-L4142) function.

Inside [`park_m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4089-L4142), the goroutine state is set to *waiting* and the association between the goroutine and thread `M` is dropped.
Additionally, [`gopark`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L390-L436) receives an `unlockf` callback function, which is executed in [`park_m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4089-L4142).
If `unlockf` returns `false`, the parked goroutine is immediately made runnable again and rescheduled on the same thread `M` using [`execute`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3221-L3265).
Otherwise, `M` enters the [schedule loop](#schedule-loop) to pick a goroutine and execute it.

### Start Thread: [`startm`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L2917-L3025)

This function is responsible for scheduling a thread `M` to run a given processor `P`.
The diagram below illustrates the flow of this function, in which `M1` thread is the parent of `M2` thread.

<table>
    <thead>
        <tr>
            <td>
                <pre class="mermaid" style="margin: unset">

flowchart LR
    subgraph M2
    direction LR
        mstart["mstart()"] ==> mstart0["mstart0()"]
        mstart0 ==> mstart1["mstart1()"]
        mstart1 ==> schedule["schedule()"]
    end
    subgraph M1
        direction LR
        start((Start)) ==> check_p{P == nil?}
        check_p ==> |Yes|check_idle_p{Is there any idle P?}
        check_idle_p ==> |No|_end(((End)))
        check_idle_p ==> |Yes|assign_p[P = idle P]
        check_p ==> |No|check_idle_m{Is there any idle M?}
        assign_p ==> check_idle_m
        check_idle_m ==> |Yes|wakeup_m[Wake up M]
        wakeup_m ==> _end
        check_idle_m ==> |No|newm["newm()"]
        newm ==> newm1["newm1()"]
        newm1 ==> newosproc["newosproc()"]
        newosproc ==> clone["clone() with entry point mstart, results in M2 thread"]
        clone ==> _end
    end

                </pre>
            </td>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td style="text-align: center">
                The <code>startm</code> function
            </td>
        </tr>
    </tbody>
</table>

If `P` is `nil`, it attempts to retrieve an idle processor from the global idle list.
If no idle processor is available, the function simply returns—indicating that the maximum number of active processors is already in use and no additional thread `M` can be created or reactivated.
If an idle processor is found (or `P` was already provided), the function either creates a new thread `M1` (if none is idle) or wakes up an existing idle one to run `P`.

Once awakened, the existing thread `M` continues in the [schedule loop](#schedule-loop).
If a new thread is created, it's done via the [`clone`](https://man7.org/linux/man-pages/man2/clone.2.html) system call, with [`mstart`](https://github.com/golang/go/blob/go1.24.0/src/runtime/os_linux.go#L186-L187) as the entry point.
The [`mstart`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L1769-L1771) function then transitions into the [schedule loop](#schedule-loop), where it looks for a runnable goroutine to execute.

### Stop Thread: [`stopm`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L2889-L2910)

This function adds thread `M` into the idle list and put it into sleep.
[`stopm`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L2889-L2910) doesn't return until `M` is woken up by another thread, typically when a new goroutine is created, as mentioned in [Waking Up Processor](#waking-up-processor) section.
This is achieved by [`futex`](https://linux.die.net/man/2/futex) system call, making `M` not eating CPU cycles while waiting.

### Processor Handoff: [`handoffp`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3026-L3096)

[`handoffp`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L3026-L3096) is responsible for transferring the ownership of a processor `P` from a thread `M`s that is blocking in a system call to another thread `M1`.
`P` will be associated with `M1` to make progress by calling [`startm`](#start-thread-startm) under certain conditions: if the global run queue is not empty, if its local run queue is not empty, if there is tracing work or garbage collection work to do, or if no thread is currently handling netpoll.
If none of these conditions is met, `P` is returned to the processor idle list.

## Go Runtime APIs

Go runtime provides several APIs to interact with the scheduler and goroutines.
It also allows Go programmers to tune the scheduler and other components like garbage collector for their application specific needs.

### [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS)

This function sets the number of processors `P` in Go runtime, thus controlling the level of parallelism in a Go program.
The default value of [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) is the value of [`runtime.NumCPU`](https://pkg.go.dev/runtime#NumCPU) function, which queries the operating system CPU allocation for the Go process.

[`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS)'s default value can be problematic, particularly in containerized environments, as described in [this](https://dev.to/rdforte/the-implications-of-running-go-in-a-containerised-environment-3bp1) awesome post.
There is an ongoing proposal to make [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) respect CPU cgroup quota limits, improving its behavior in such environments.
In future versions of Go, [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) may become obsolete, as noted in the official documentation: ["This call will go away when the scheduler improves."](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/debug.go#L15-L15)

Some I/O bound programs may benefit from a higher number of processors `P` than the default.
For example, [Dgraph](https://github.com/hypermodeinc/dgraph/blob/v24.1.2/dgraph/main.go#L36) database hardcodes [`GOMAXPROCS`](https://pkg.go.dev/runtime#GOMAXPROCS) to 128 to allow more I/O operations to be scheduled.

### [`Goexit`](https://pkg.go.dev/runtime#Goexit)

This function gracefully terminates the current goroutine.
All deferred calls run before terminating the goroutine.
The program continues execution of other goroutines.
If all other goroutines exit, the program crashes.
[`Goexit`](https://pkg.go.dev/runtime#Goexit) should be used testing rather than real-world application, where you want to abort the test case early (for example, if preconditions aren't met), but you still want deferred cleanup to run.

## Conclusion

The Go scheduler is a powerful and efficient system that enables lightweight concurrency through goroutines.
In this blog, we explored its evolution—from the primitive model to the GMP architecture—and key components like goroutine creation, preemption, syscall handling, and netpoll integration.

Hope you will find this knowledge useful in writing more efficient and reliable Go programs.
<span>
    If you really enjoy my content, please consider
    <span>
      <a href="https://buymeacoffee.com/nghiant3221" target="_blank">
        <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 45px; width: 162px;">
      </a>
    </span>! 😄
</span>

## References

- kelche.co. [*Go Scheduling*](https://www.kelche.co/blog/go/golang-scheduling).
- unskilled.blog. [*Preemption in Go*](https://unskilled.blog/posts/preemption-in-go-an-introduction/).
- Ian Lance Taylor. [*What is system stack?*](https://groups.google.com/g/golang-nuts/c/JCKWH8fap9o)
- [6], [7] Michael Kerrisk. [*The Linux Programming Interface*](https://man7.org/tlpi/).
- [8], [9], [10] W. Richard Stevens. [*Unix Network Programming*](https://www.amazon.com/UNIX-Network-Programming-Richard-Stevens/dp/0139498761).
- zhuanlan.zhihu.com. [*Golang program startup process analysis*](https://zhuanlan.zhihu.com/p/436925356).
- Madhav Jivrajani. [*GopherCon 2021: Queues, Fairness, and The Go Scheduler*](https://www.youtube.com/watch?v=wQpC99Xu1U4&t=2375s&ab_channel=GopherAcademy).
- <div><span id="ref-1"/><span id="ref-2"/><span id="ref-3"/>[1], [2], [3] Abraham Silberschatz, Peter B. Galvin, Greg Gagne. <a href="https://www.amazon.com/Operating-System-Concepts-Abraham-Silberschatz/dp/1119800366/ref=zg-te-pba_d_sccl_3_1/138-7692107-2007040"><i>Operating System Concepts.</i></a></div>

<div class="giscus" id="reaction"></div>
