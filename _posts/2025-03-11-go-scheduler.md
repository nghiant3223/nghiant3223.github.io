# Go Scheduler

## Disclaimer

This blog post primarily focuses on [Go 1.24](https://tip.golang.org/doc/go1.24) programming for [Linux](https://en.wikipedia.org/wiki/Linux) on [ARM](https://en.wikipedia.org/wiki/ARM_architecture_family) architecture. It may not cover platform-specific details for other operating systems or architectures.
## Introduction

// Mention why Go is fast:

- M:N threading model
- Goroutines
    - Lightweight, cheap to create
    - Small stack size (2KB) and grows as needed
    - Multiplexed onto a small number of OS threads
    - Scheduled by the Go runtime (user space)
- Efficient scheduling with reducing lock contention
- Able to handle many concurrent I/O operations
- Useful primitives for synchronization

## Go Runtime

- How Go code is compiled to Go runtime code
    - https://www.sobyte.net/post/2021-12/golang-plugin/
    - https://www.sobyte.net/post/2022-07/go-bootstrap/
- Mention goroutine stack size is controlled by runtime variable

## Primitive Scheduler

## Scheduler Enhancements

### Proposal 1

### Proposal 2

// Mention g and g0 and gsignal

// Mention P's runnext

## Work Stealing

## Efficient Scheduling

// Mention P's runnext to reduce lock contention

// Mention local, global is circular queue for efficiency

## Goroutine Preemption

Preemption is the act of temporarily interrupting a goroutine to allow other goroutines to run, preventing goroutine starvation.
There are 2 types of preemption in Go: cooperative preemption is when a goroutine voluntarily yields the processor to the scheduler, and non-cooperative preemption is when the scheduler forcibly stops a goroutine that has been running for too long.
Let's see how these two types of preemption work in Go.

### Non-cooperative Preemption

Let's take an example to understand how non-cooperative preemption works.
In this program, we have two goroutines that calculate the Fibonacci number, which is an tight loop with CPU intensive operations.
In order to make sure that only one goroutine can run at a time, we set the maximum number of logical processors to 1 using `GOMAXPROCS=1` when running the program.

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

Because there is exactly one P, there are many cases that could happen. 
One, neither goroutine runs because the main function has taken control of the P.
Two, one goroutine runs while the other is starved of execution.
Three, somehow both goroutines run concurrently—almost magically.

Fortunately, Go does support us to get the idea of what is happening with the scheduler.
The [runtime/trace](https://go.dev/pkg/runtime/trace) package contains a powerful tool for understanding and troubleshooting Go programs.
To make use of this, we need to add instrument to the `main` method to export the traces to file.

```go
func main() {
    file, _ := os.Create("trace.out")
    _ = trace.Start(file)
    defer trace.Stop()
    ...
}
```

After the program finishes running, we use the command `go tool trace trace.out` to visualize the trace.
I prepared the `trace.out` file [here](/assets/2025-03-11-go-scheduler/non_cooperative_preempt_trace.out) just in case you want to play with it.
In the visualization, the horizontal axis represents which goroutine is running on the P at a given time.
As expected, there is only one logical processor P named "Proc 0", resulted from `runtime.GOMAXPROCS(1)`.

![runtime_trace_start.png](/assets/2025-03-11-go-scheduler/runtime_trace_start.png)

By zooming in (pressing 'W') to the start of the timeline, you can see that the process begins with `main.main` (the main function in the main package), which runs on the primary goroutine, G1.
After a few microseconds, still on Proc 0, goroutine G10 is scheduled to execute the `fibonacci` function. It then takes over the processor, preempting G1.

![runtime_trace_preempt.png](/assets/2025-03-11-go-scheduler/runtime_trace_preempt.png)

By zooming out (pressing 'S') and scrolling slightly to the right, you can observe that G10 is later replaced by another goroutine, G9, which is the next instance running the `fibonacci` function.
This goroutine is also created and executed on Proc 0. Please pay attention to the `runtime.asyncPreempt:47` in the visualization, I will explain this in a moment.

So, from this demonstration, it can be concluded that the Go scheduler is capable of preempting goroutines that are CPU-bound.
But how is it possible because if a goroutines continuously taking up the CPU, how can the scheduler preempt it?
This is a hard problem and there was a long [discussion](https://github.com/golang/go/issues/10958) on the Go issue tracker.
The problem was not addressed until Go 1.14, where asynchronous preemption was introduced.

In the Go runtime, there is a daemon running on a dedicated M without a P, called `sysmon` (i.e. system monitor). 
When `sysmon` finds a goroutine that has been running for more than 10ms (as determined by the [`forcePreemptNS`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L6245-L6245) constant in Go runtime), it signals the kernel thread M by making system call `pthread_kill` to preempt the running goroutine.
Yes, you didn't read that wrong. According to the [Linux manual page](https://man7.org/linux/man-pages/man3/pthread_kill.3.html), `pthread_kill` is used to send a signal to a thread, not to kill a thread.
The signal sent is `SIGURG`, and the reason for choosing it is described in detail [here](https://github.com/golang/go/blob/go1.24.0/src/runtime/signal_unix.go#L43-L73).

On the other side, there is a dedicated goroutine for handling signal installed in every P, called `gsignal`.
Upon receiving `SIGURG`, the `gsignal` goroutine will enter the [asyncPreempt](https://github.com/golang/go/blob/go1.24.0/src/runtime/preempt_arm64.s) function, which is implemented in assembly, to save the goroutine's register and call [`asyncPreempt2`](https://github.com/golang/go/blob/go1.24.0/src/runtime/preempt.go#L302-L311) at line [47](https://github.com/golang/go/blob/go1.24.0/src/runtime/preempt_arm64.s#L47).
That's reason for the appearance of `runtime.asyncPreempt:47` in the visualization.
Inside [`asyncPreempt2`](https://github.com/golang/go/blob/go1.24.0/src/runtime/preempt.go#L302-L311), the goroutine `g0` of kernel thread M will enter [`gopreempt_m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4191-L4193) to disassociate goroutine running `fibonacci` function from M and enqueue the goroutine into global run queue, allowing M to execute another goroutine.

As preemption signal is triggered by `sigmon` but the actual preemption doesn't happen until the `gsignal` goroutine receives preemption signal, this kind of preemption is asynchronous.
That's why goroutines can actually run beyond the time limit 10ms, like goroutine G9 in the example.

### Cooperative Preemption in Early Go

In the early days of Go, the Go runtime itself was not able to preempt a goroutines that have tight loop like the example above.
We, the programmer, have to tell the goroutine to cooperatively yield the processor to the scheduler by calling `runtime.Gosched()` in the loop body.
There were a Stackoverflow [question](https://stackoverflow.com/questions/13107958/what-exactly-does-runtime-gosched-do) that described an example and the behavior of `runtime.Gosched()`.

From the programmer's point of view, this is very tedious and error-prone, and it did have some performance [issue](https://github.com/golang/go/issues/12553) in actuality.
Therefore, the Go team has decided to implement a clever way to preempt the goroutine by the runtime itself.
This will be discussed in the next section.

### Cooperative Preemption Since Go 1.14

Do you wonder why I didn't use `fmt.Printf` in each iteration to see whether both goroutines have chance to run?
That's because if I had done that, it would have become a cooperative preemption, not a non-cooperative preemption anymore.

#### Disassembly the Program
To better understand this, let's compile the program and analyze its assembly code.
Since the Go compiler applies various optimizations that can make debugging more challenging, we need to disable them when building the program.
This can be done using the following command: `go build -gcflags="all=-N -l" -o fibonacci main.go`.
For easier debugging, I use [Delve](https://github.com/go-delve/delve), a powerful debugger for Go, to disassemble the `fibonacci` function: `dlv exec ./fibonacci`.
Once inside the debugger, I run the following command to view the assembly code of the fibonacci function: `disassemble -l main.fibonacci`.
You can find the assembly code of the original program [here](/assets/2025-03-11-go-scheduler/non_cooperative_preempt.s).
As I'm building the program on my local machine, which is darwin/arm64, the assembly code could be different from the one you might see on your machine. 

That's all set, let's take a look at the assembly code of the `fibonacci` function and see what the code does.
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
But what exactly is a stack guard? You may know that a goroutine’s stack is growable, but how does the Go runtime determine when it needs to grow?
The stack guard is a special value placed at the end of the stack. When the stack pointer reaches this value, the Go runtime detects that the stack is nearly full and needs to grow—that’s exactly what the next three instructions do.

`SUB $48, RSP, R17` loads the goroutine's stack pointer from the register `RPS` to register `R17` and subtracts 48 from it.
`CMP R16, R17` compares the stack guard with the stack pointer, and `BLS 96(PC)` branches to the instruction located 96 instructions ahead in the program if the stack pointer is less than or equal to the stack guard.
Why less than or equal (≤) but not greater or equal (≥)? Because the stack grows downward, the stack pointer is always greater than the stack guard.

Have you ever wondered why these instructions don’t appear in the Go code but still show up in the assembly?
That's because upon compiling, Go compiler automatically inserts these instructions in every function [prologue](https://en.wikipedia.org/wiki/Function_prologue_and_epilogue).
This applies for every function like `fmt.Println`, not just the `fibonacci` function in the program.

After advancing 96 instructions, execution reaches the `MOVD R0, 8(RSP)` instruction and then proceeds to `CALL runtime.morestack_noctxt(SB)`.
[`runtime.morestack_noctxt`](https://github.com/golang/go/blob/go1.24.0/src/runtime/asm_arm64.s#L348-L348) will eventually call [`newstack`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stack.go#L966-L966) to grow the stack and optionally enter [`gopreempt_m`](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4191-L4193) to trigger preemption as discussed in non-cooperative preemption.
The key point of cooperative preemption is the condition for entering `gopreempt_m`, which is [`stackguard0 == stackPreempt`](https://github.com/golang/go/blob/go1.24.0/src/runtime/stack.go#L1025-L1025).
This means that whenever a goroutine wants to extend its stack—typically at the beginning of a function call—it will be preempted if its `stackguard0` was set to `stackPreempt` earlier.

`stackPreempt` can be set by the `sysmon` if a goroutine has been running for more than 10ms.
The goroutine will then be cooperatively preempted by making a function call or non-cooperatively preempted by the signal handler, whichever happens first.
It can also be set when the goroutine enters or exits a system call or during the tracing phase of the garbage collector.
For reference, see the relevant code: [sysmon preemption](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L6366-L6366), syscall [entry](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4525-L4525)/[exit](https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L4663-L4663), [garbage collector tracing](https://github.com/golang/go/blob/go1.24.0/src/runtime/trace.go#L389-L389).

#### Trace Visualization

Alright, let's rerun the program—make sure `GOMAXPROCS=1` is set—and then check out the trace.

![](/assets/2025-03-11-go-scheduler/runtime_trace_cooperative_preempt.png)

You can clearly see that goroutines relinquish the logical processor after just tens of microseconds—unlike with non-cooperative preemption, where they might retain it for over 10 milliseconds.
Notably, G9’s stack trace ends at the `fmt.Printf` call inside the loop body, demonstrating the stack guard check in function prologue.
This trace precisely illustrates cooperative preemption, where goroutines *voluntarily* yield the processor.

## Handling System Call

// Mention thread cannot both be in syscall and running Go code at the same time.
https://www.sobyte.net/post/2022-07/go-gmp/#2-new-logic-for-p

https://utcc.utoronto.ca/~cks/space/blog/programming/GoSchedulerAndSyscalls
https://stackoverflow.com/questions/16977988/details-of-syscall-rawsyscall-syscall-syscall-in-go
https://www.cnblogs.com/flhs/p/12709962.html

## Network I/O and File I/O

This [survey](https://go.dev/blog/survey2024h2/what.svg) shows that 75% of Go uses cases are web services.
And it's not a coincidence, Go is designed to be fast and efficient for network operation to solve the notorious problem—[C10K](https://en.wikipedia.org/wiki/C10k_problem).
To see how Go solves this problem, let's take a look at how Go handles I/O operations under the hood.

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
Go builds on top of fundamental [socket](https://en.wikipedia.org/wiki/Unix_domain_socket) operations (depicted in the figure below) to manage network communication between clients and servers.

| <img src="/assets/2025-03-11-go-scheduler/socket_system_calls_in_http_server.png" width=300/> | 
|:---------------------------------------------------------------------------------------------:| 
|                Overview of system calls used with stream sockets<sup>[N]</sup>                |

Specifically, `http.ListenAndServe()` leverages the following system calls: [`socket()`](https://man7.org/linux/man-pages/man2/socket.2.html), [`bind()`](https://man7.org/linux/man-pages/man2/bind.2.html), [`listen()`](https://man7.org/linux/man-pages/man2/listen.2.html), [`accept()`](https://man7.org/linux/man-pages/man2/accept.2.html) to create a TCP sockets, which  to create a TCP sockets, which is essentially [file descriptors](https://en.wikipedia.org/wiki/File_descriptor).
It binds the listening socket to the specified address and port, listens for incoming connections, and creates a new connected socket to handle client requests—all without requiring you to write any socket-handling code.
Similarly, `http.HandleFunc()` registers your handler functions to respond to HTTP requests, abstracting away the lower-level details like reading from and writing to the connection using system calls such as [`read()`](https://man7.org/linux/man-pages/man2/read.2.html) and [`write()`](https://man7.org/linux/man-pages/man2/write.2.html).

| <img src="/assets/2025-03-11-go-scheduler/go_http_server_meme.jpg" width=300/> | 
|:------------------------------------------------------------------------------:| 
|             Go abstracts system calls to provide simple interface              |

But it's not that simple for an HTTP server to handle tens of thousands of concurrent requests efficiently.
Go employs several techniques to achieve this. Let's take a closer look at some I/O models in Linux and how Go takes advantage of them.

### Blocking I/O, Non-blocking I/O and I/O Multiplexing

An I/O operation can be either blocking or non-blocking.
When a thread issues a blocking system call, its execution is suspended until the system call completes with the requested data.
In contrast, non-blocking I/O doesn't suspend the thread; instead, it immediately returns the requested data if available, or an error (<a href="https://man7.org/linux/man-pages/man3/errno.3.html#:~:text=POSIX.1%2D2001\).-,EAGAIN,-Resource%20temporarily%20unavailable">`EAGAIN`</a> or <a href="https://man7.org/linux/man-pages/man3/errno.3.html#:~:text=POSIX.1%2D2001\).-,EAGAIN,-Resource%20temporarily%20unavailable">`EWOULDBLOCK`</a>) if the data is not yet ready.
Blocking I/O is simpler to implement but inefficient, as it requires the application to spawn N kernel threads for N connections.
In contrast, non-blocking I/O is more complex, but when implemented correctly, it enables significantly better resource utilization.
See the figures below for a visual comparison of these two models.

| <img src="/assets/2025-03-11-go-scheduler/blocking_io.png" width=300/> | <img src="/assets/2025-03-11-go-scheduler/non_blocking_io.png" width=300/> | 
|:----------------------------------------------------------------------:|:--------------------------------------------------------------------------:| 
|                    Blocking I/O model<sup>[N]</sup>                    |                    Non-blocking I/O model<sup>[N]</sup>                    |

Another I/O model worth mentioning is I/O multiplexing, in which [`select`](https://man7.org/linux/man-pages/man2/select.2.html), or [`poll`](https://man7.org/linux/man-pages/man2/poll.2.html) system call is used to wait for one of a set of file descriptors to become ready to perform I/O.
In this model, the application blocks on one of these system calls, rather than on the actual I/O system calls, such as `recvfrom` shown in the figures above.
When `select` returns that the socket is readable, the application calls `recvfrom` to copy requested data to application buffer.

| <img src="/assets/2025-03-11-go-scheduler/io_multiplexing.png" width=500/> |
|:--------------------------------------------------------------------------:|
|                    I/O multiplexing model<sup>[N]</sup>                    |

## I/O Model in Go

Go uses a combination of non-blocking I/O and I/O multiplexing to handle I/O operations efficiently.
Due to the performance limitations of `select` and `poll`—as explained in this [blog](https://jvns.ca/blog/2017/06/03/async-io-on-linux--select--poll--and-epoll/#why-don-t-we-use-poll-and-select)—Go avoids them in favor of more scalable alternatives: [epoll](https://man7.org/linux/man-pages/man7/epoll.7.html) on Linux, [kqueue](https://man.freebsd.org/cgi/man.cgi?kqueue) on macOS, and [IOCP](https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports) on Windows.
In Go, `netpoll` is a set of functions that abstracts these 3 mechanisms, providing a unified interface for I/O multiplexing across different operating systems.

## How *netpoll* Works

### Registering Goroutine with [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html)

When a TCP listener [accepts](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/net/tcpsock.go#L374-L385) a new connection, it invokes the [`accept4`](https://man7.org/linux/man-pages/man2/accept.2.html) system call with the [`SOCK_NONBLOCK`](https://man7.org/linux/man-pages/man2/socket.2.html#:~:text=of%0A%20%20%20%20%20%20%20socket()%3A-,SOCK_NONBLOCK,-Set%20the%20O_NONBLOCK) flag to set the socket’s file descriptor to non-blocking mode.
Following this, several descriptors are created to integrate with the Go runtime's `netpoll` system.

First, an instance of [`net.netFD`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/net/fd_posix.go#L16-L27) is initialized to wrap the socket's file descriptor and provide higher-level abstractions for network operations.
Next, the Go runtime creates a [`runtime.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L72-L115) instance—containing scheduling data and [references to the goroutine](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L98-L101) involved in I/O—using the [`poll_runtime_pollOpen`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L243-L278) function.
The socket's file descriptor is then registered with the [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) interest list via the [`epoll_ctl`](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html) system call using the [`EPOLL_CTL_ADD`](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html#:~:text=op%20argument%20are%3A-,EPOLL_CTL_ADD,-Add%20an%20entry) operation.
Since [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) operates on file descriptors rather than goroutines, this system call also associates the address of [`runtime.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L72-L115) with the file descriptor, enabling the scheduler to identify which goroutine to resume when [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) signals readiness.
Finally, an instance of [`poll.FD`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/internal/poll/fd_unix.go#L17-L48) is initialized to encapsulate logic for read and write operations with polling support.
It indirectly references [`runtime.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L72-L115) via [`poll.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/internal/poll/fd_poll_runtime.go#L32-L34), serves as a lightweight wrapper around a pointer to [`runtime.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L72-L115).

Building on the success of this model for network I/O, Go also leverages [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html) for file I/O.
Once a file is opened, [`syscall.SetNonblock(fd, true)`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/os/file_unix.go#L222-L222) is called to enable non-blocking mode on the file descriptor.
Then, [`poll.FD`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/internal/poll/fd_unix.go#L17-L48), [`poll.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/internal/poll/fd_poll_runtime.go#L32-L34) and [`runtime.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L72-L115) are initialized to register the file descriptor with [`epoll`](https://man7.org/linux/man-pages/man7/epoll.7.html), allowing file I/O to be multiplexed as well.

The relationship between these descriptors is depicted in the figure below.
Meanwhile [`net.netFD`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/net/fd_posix.go#L16-L27), [`os.File`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/os/types.go#L15-L20), [`poll.FD`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/internal/poll/fd_unix.go#L17-L48), and [`poll.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/internal/poll/fd_poll_runtime.go#L32-L34) are implemented in normal Go code (specifically in Go standard library), [`runtime.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L72-L115) resides within the Go runtime itself.

| <img src="/assets/2025-03-11-go-scheduler/netpoll_descriptors.png"/> |
|:--------------------------------------------------------------------:|
|              Relationship of descriptors in `netpoll`               |


### Polling File Descriptors

When a goroutine reads from socket or file, it eventually invokes the [`Read`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/internal/poll/fd_unix.go#L141-L173) method of [`poll.FD`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/internal/poll/fd_unix.go#L17-L48).
In this method, the goroutine makes [`read`](https://man7.org/linux/man-pages/man2/read.2.html) system call to get any available data from the file descriptor.
If the I/O data is not ready yet, i.e. `EAGAIN` or `EWOULDBLOCK` is returned, the Go runtime invokes [`poll_runtime_pollWait`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L336-L361) method to [park the goroutine](#goroutine-parking).
The behavior is similar when a goroutine writes to a socket or file, with the main difference being that `Read` is replaced by [`Write`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/net/net.go#L201-L211), and the `read` system call is substituted with [`write`](https://man7.org/linux/man-pages/man2/write.2.html).

Now that the goroutine is in waiting state, it is the responsibility of `netpoll` to provide the goroutine to the scheduler when the goroutine's file descriptor is ready for I/O so that it can be resumed.
You may be surprised to learn that `netpoll` is nothing more than the [`netpoll`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll_epoll.go#L91-L176) function implemented in the Go runtime.
In this function, [`epoll_wait`](https://man7.org/linux/man-pages/man2/epoll_wait.2.html) system call is used to monitor up to 128 file descriptors in a specified amount of time.
This system call returns the [`runtime.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L72-L115) instances that were previously registered (as described in the previous section) for each file descriptor that becomes ready.
Finally, `netpoll` extracts the goroutine references from [`runtime.pollDesc`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll.go#L72-L115) instances and hands them off to the scheduler.

But when is the [`netpoll`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/netpoll_epoll.go#L91-L176) function actually called?
It's triggered when a processor  P looks for a runnable goroutine to execute, as outlined in [runtime schedule](#runtime-schedule).
According to the [`findRunnable`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/proc.go#L3267-L3646) function, `netpoll` is only consulted by the scheduler if there are no goroutines available in either the local run queue of the current P or the global run queue.
This means even if the file descriptor is ready for I/O, the associated goroutine is not necessarily woken up immediately.

// Mention netpoll: https://www.sobyte.net/post/2021-09/golang-netpoll

// Mention: https://www.sobyte.net/post/2022-01/go-netpoller/

// Mention epoll: https://www.sobyte.net/post/2021-10/golang-from-kernel-to-epoll

// https://tuhuynh.com/posts/nio-under-the-hood/

## Garbage Collector

Another equally important part of the Go runtime is the garbage collector.

## The Scheduler Overview

// Mention what happens when Go program starts: how many threads are created, how many goroutines are created, how many
P's are created.

<!--
In schedinit:
  - initialize GOMAXPROCS number of idle P
In newproc -> wakep:
  - create M (with startm) only when there is idle P
In startm -> newm -> newm1 -> newosproc -> clone -> mstart -> mstart1 -> schedule -> findRunnable -> execute -> gogo -> goexit -> schedule 

M is not destroyed but will put into sleep by stopm (using futexes under the hood)

entersyscall:
- disassociate m and p, m.oldp = p
- P status us set to _Psyscall

exitsyscal:
- exitsyscallfast:
  - if M has oldp and P is _Psyscall, then associate M with P, change P status to _Prunning: wirep
  - otherwise, get an idle P if there is any then associate M with P: exitsyscallfast_pidle
- exitsyscall0: slow path: 

-->

// https://www.sobyte.net/post/2022-07/go-bootstrap/
// https://www.sobyte.net/post/2022-07/go-gmp/
// https://www.sobyte.net/post/2021-09/golang-netpoll/#groutinue-scheduling-for-io-events

## Runtime API

- LockOSThread, UnlockOSThread
    - https://www.sobyte.net/post/2021-06/golang-number-of-threads-in-the-running-program/

## Glossary

### Goroutine Parking

A commonly used procedure in the Go runtime for transitioning the current goroutine into a waiting state.
It is implemented in [`gopark`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/net/fd_unix.go#L40-L42) function.
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

Inside [`releasem`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/runtime1.go#L612-L619) function, the goroutine's [`stackguard0`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/runtime2.go#L405-L405) is set to [`stackPreempt`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/runtime1.go#L617-L617) to trigger an eventual cooperative preemption.
Control is then transferred to the [g0](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/runtime2.go#L529) system goroutine, which belongs to the same kernel thread currently running the goroutine, to invoke the [`park_m`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/proc.go#L4089-L4142) function.

Inside `park_m`, the goroutine status is set to waiting and the association between the goroutine and the kernel thread M is dropped.
Additionally, `gopark` receives an `unlockf` callback function, which is executed in `park_m`.
If `unlockf` returns `false`, the parked goroutine is immediately made runnable again and rescheduled on the same M using [`execute`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/proc.go#L3221-L3265).
Finally, the [`schedule`](#runtime-schedule) function is called to pick a runnable goroutine and execute it on this M.

### Runtime `schedule`

A function implemented in the Go runtime that identifies runnable goroutines and schedules them for execution.
This function is used when a new kernel thread is created, a goroutine is parked or preempted, [`Gosched`](https://pkg.go.dev/runtime#Gosched) is called, when a goroutine finishes system call or when a goroutine returns.

<!--
https://draven.co/golang/docs/part3-runtime/ch06-concurrency/golang-goroutine/#656-%e8%a7%a6%e5%8f%91%e8%b0%83%e5%ba%a6
-->

## References

- unskilled.blog. [*Preemption in Go*](https://unskilled.blog/posts/preemption-in-go-an-introduction/).
- kelche.co. [*Go Scheduling*](https://www.kelche.co/blog/go/golang-scheduling).
- [N] Michael Kerrisk. *The Linux Programming Interface*.
- [N], [N], [N] W. Richard Stevens, Bill Fenner, Andrew M. Rudoff. *Unix Network Programming*.

<!-- 
## sobyte posts
- https://www.sobyte.net/post/2023-08/go-apache-arrow-parquet/
- https://www.sobyte.net/post/2023-04/unsafe-assume-no-moving-gc
- https://www.sobyte.net/post/2023-03/go-subtest
- https://www.sobyte.net/post/2023-03/gpm
- https://www.sobyte.net/post/2023-02/learn-go-in-10-min
- https://www.sobyte.net/post/2022-11/go-time
- https://www.sobyte.net/post/2022-10/go-cni
- https://www.sobyte.net/post/2022-09/go-goroutine-channel
- https://www.sobyte.net/post/2022-08/waitgroup
- https://www.sobyte.net/post/2022-08/go-generate
- https://www.sobyte.net/post/2022-08/go-k8s-operators-part1
- https://www.sobyte.net/post/2022-07/golang-performance
- https://www.sobyte.net/post/2022-06/go-example-pitfalls
- https://www.sobyte.net/post/2022-06/go-1-19
- https://www.sobyte.net/post/2022-05/go-pyroscope
- https://www.sobyte.net/post/2022-03/think-in-sync-pool
- https://www.sobyte.net/post/2022-03/golang-zero-copy
- https://www.sobyte.net/post/2022-03/go-interface
- https://www.sobyte.net/post/2022-03/go-timer
- https://www.sobyte.net/post/2022-03/what-is-pause-container
- https://www.sobyte.net/post/2022-02/go-try-lock
- https://www.sobyte.net/post/2022-01/go-sync-pool
- https://www.sobyte.net/post/2022-01/go-channel-source-code
- https://www.sobyte.net/post/2022-01/go-netpoller
- https://www.sobyte.net/post/2022-01/go-dispatch-loop
- https://www.sobyte.net/post/2022-01/go-timer-analysis
- https://www.sobyte.net/post/2022-01/go-gc
- https://www.sobyte.net/post/2021-12/whys-the-design-go-generics
- https://www.sobyte.net/post/2021-12/golang-sysmon
- https://www.sobyte.net/post/2021-12/golang-garbage-collector
- https://www.sobyte.net/post/2021-12/golang-stack-management
- https://www.sobyte.net/post/2021-10/golang-from-kernel-to-epoll
- https://www.sobyte.net/post/2021-09/golang-netpoll
- https://www.sobyte.net/post/2021-07/go-implements-prioritization-in-select-statements
- https://www.sobyte.net/post/2021-06/golang-cron-v3-timed-tasks
- https://www.sobyte.net/post/2021-06/golang-number-of-threads-in-the-running-program/
- https://www.programmersought.com/article/57436593817/
- https://morsmachine.dk/netpoller
- https://www.altoros.com/blog/golang-internals-part-6-bootstrapping-and-memory-allocator-initialization/
- https://www.learnvulnerabilityresearch.com/stack-frame-function-prologue
- https://dev.to/aceld/understanding-the-golang-goroutine-scheduler-gpm-model-4l1g
- https://notes.shichao.io/unp/ch6/#nonblocking-io-model
- https://draven.co/golang/docs/part3-runtime/ch06-concurrency/golang-netpoller/
- PR that adds file I/O to netpoll: https://github.com/golang/go/commit/c05b06a12d005f50e4776095a60d6bd9c2c91fac
- https://www.sobyte.net/post/2022-02/where-is-goexit-from/
-->