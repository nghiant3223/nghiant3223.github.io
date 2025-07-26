---
layout: post
title: "Memory Allocation in Go"
date: 2025-06-03
---

Sources:
- https://www.sobyte.net/post/2021-12/golang-stack-management/
- https://www.sobyte.net/post/2022-04/golang-memory-allocation/
- https://www.sobyte.net/post/2022-01/go-memory-allocation/
- https://blog.ankuranand.com/2019/02/20/a-visual-guide-to-golang-memory-allocator-from-ground-up/
- https://www.sobyte.net/post/2021-12/golang-memory-allocator/
- https://medium.com/@aditimishra_541/how-go-manages-memory-8123fd11eab9
- 20.6.3.1 Mapping of Programs into Memory in "OS Concepts" book
- https://www.youtube.com/watch?v=3uyiGO6a4q

## Fundamental

### Main Memory

#### What and Why?

Have you ever wondered why computers need main memory (RAM) when they already have disk storage? The answer lies in access speed.
While disk storage is permanent, it is much slower than main memory.
RAM sacrifices volatility for speed—data is lost when the power is off, but access times are much faster.
As a result, the CPU can only access data from main memory, not disk storage.

CPUs come with built-in registers, which are even faster than main memory.
So why do we need main memory at all?
It's because registers are limited in number and size.
Imagine a function that needs to work with a thousand variables—there’s no way to fit all of them into registers.
And what if you need to store large data structures like arrays or structs? Registers simply don’t have the capacity.
That’s where main memory comes in—it provides the space needed to handle larger and more complex data.

Main memory is a large array of bytes, ranging in size from hundreds of thousands to billions.
Each byte has its own address.
For a program to be executed, it must be mapped to absolute addresses and loaded into memory.
Once loaded, a process—an active execution of a program—accesses program instructions, reads data from and writes data to memory by using these absolute addresses.
In the same way, for the CPU to process data from disk, those data must first be transferred to main memory by CPU-generated I/O calls.

#### Simple Allocation Strategy

Typically, there are multiple processes running on a computer, each with its own memory space allocated in main memory.
It's the responsibility of the operating system to allocating memory for each process, ensuring that they don't interfere with each other.
One of the simplest method of allocating memory is to assign processes to a variably sized contiguous block of memory (i.e. partition) in memory, where each block may contain exactly one process.

| <img src="/assets/2025-06-03-memory_allocation_in_go/variable_partition.png" width=500> |
|:---------------------------------------------------------------------------------------:|
|                Contiguous memory block allocation strategy <sup>1</sup>                 |

When processes are created, the operating system takes into account the memory requirements of each process and the amount of available memory space to allocate a sufficient partition for it.
After allocation, the process is loaded into memory and start its execution.
Once the process is finished, the operating system reclaims the memory block, making it available for other processes.
If there is not enough room for an incoming process, the operating system may need to swap out some processes to disk to free up memory space.
Alternatively, we can place such processes into await queue.
When memory is later released, the operating system checks the wait queue to determine if it will satisfy the memory demands of a waiting process.

During allocation, the operating system must looks for a sufficiently large contiguous block of memory for the process.
There are many algorithms to do this, such as first-fit, best-fit, and worst-fit.
First-fit searches for the first block that is large enough and stop searching once it finds one.
Best-fit searches the entire memory space and finds the smallest block that is large enough.
Worst-fit searches the entire memory space and finds the largest block that is large enough.
First Fit and Best Fit perform better than Worst Fit in time and storage use.
First Fit is usually faster, though storage efficiency is similar between the two.

#### External Fragmentation

Unfortunately, this simple allocation strategy can lead to external fragmentation.
External fragmentation occurs when there is enough total memory to satisfy a request, but the available spaces are not contiguous.
This type of fragmentation can become a serious problem.
In the worst case, there can be a small block of free memory between every two allocated processes.
If all these scattered fragments were combined into a single large block, the system might be able to run several more processes.

| <img src="/assets/2025-06-03-memory_allocation_in_go/memory_fragmentation.png" width=550> |
|:-----------------------------------------------------------------------------------------:|
|          External fragmentation with contiguous memory block allocation strategy          |

In reality, the maximum memory space required by a process is not known at the time of allocation.
This is because processes may perform dynamic memory allocation based on user input or other factors.
If the allocated memory is not enough, the operating system may need to pause the process, search for a sufficient memory block, and migrate the process to a larger memory block.
This approach could lead to critical performance issues, thus not realistic.

#### Memory Paging

In practice, operating systems use a more sophisticated memory allocation strategy called *paging* to avoid external fragmentation.
Paging divides the main memory into fixed-size blocks called *frames*.
Rather than a contiguous block of memory for each process, the operating system allocates multiple frames that can be scattered throughout the main memory.

When mentioning paging, we need to talk about *physical memory* and *virtual memory* (or *logical memory*).
Physical memory refers to the main memory installed in the computer, while virtual memory is an abstraction that operating systems use to manage process memory.
Process can only access virtual memory, and operating system takes care of mapping virtual memory to physical memory.
While the process's physical memory could be non-contiguous, from the perspective of each process, it has its own **isolated** virtual memory space, appearing as a contiguous block.

> 🧑‍💻 To demonstrate the concept of virtual memory, you can try running this Go program, getting the address for later comparison, opening other programs, and then running the program again.
> ```go
> package main
>
> func main() {
>   x := 0
>   println(&x)
> }
> ```
> You can see that even there are new processes coming in, the address of the variable remains the same.
> That's because the variable is allocated at the same address in process's virtual memory space.

The virtual memory is divided into fix-sized blocks called *pages*, which having the same size as the frames in physical memory.
By separating virtual memory from physical memory and with the help of techniques such as *demand paging* (explained below), a process can access up to 18.4 million TB of memory on a 64-bit architecture, or up to 4 GB on a 32-bit architecture, even if the actual physical memory is much smaller, such as 512 MB.

Each page has a page number *p*, and each frame has a frame number *f*.
Each address has an offset *d* to identify the specific location within the page or frame.
*p* and *f* lives in the high bits of the address, while *d* lives in the low bits.
The mapping between virtual pages and physical frames is maintained in a per process data structure called *page table*.
In a page table, each entry is indexed by a page number *p*, and the corresponding value is the frame number *f*.


| <img src="/assets/2025-06-03-memory_allocation_in_go/page_table.png" width=550> |
|:-------------------------------------------------------------------------------:|
|                          Paging hardware <sup>2</sup>                           |

<p style="margin-bottom: 5px">In order to obtain the physical address of a virtual one, the following steps are performed:</p>
1. The page number *p* is extracted from the virtual address.
2. The page table is accessed to retrieve the corresponding frame number *f*.
3. Replace the page number *p* with the frame number *f* in the virtual address.

| <img src="/assets/2025-06-03-memory_allocation_in_go/paging_model.png" width=400> |
|:---------------------------------------------------------------------------------:|
|                             Paging model <sup>3</sup>                             |

Note that in fact, the structure of page table is not that simple and it can take several forms to manage memory efficiently.
One common approach—[used by Linux](https://docs.kernel.org/mm/page_tables.html#mmu-tlb-and-page-faults)—is a multi-level page table, where each level contains page tables that map to the next level, eventually leading to the physical frame.
Another method is a hashed page table, where a hash function maps virtual page numbers to entries in a hash table that point to physical frames.
A third option is the inverted page table, where each entry represents a frame in physical memory and stores the virtual address of the page currently held there, along with information about the owning process.

| <img src="/assets/2025-06-03-memory_allocation_in_go/hierarchical_page_table.png" width=400> | <img src="/assets/2025-06-03-memory_allocation_in_go/hashed_page_table.png" width=400> | <img src="/assets/2025-06-03-memory_allocation_in_go/inverted_page_table.png" width=400> |
|:--------------------------------------------------------------------------------------------:|:--------------------------------------------------------------------------------------:|:----------------------------------------------------------------------------------------:|
|                             Hierarchical page table <sup>4</sup>                             |                             Hashed page table <sup>5</sup>                             |                             Inverted page table <sup>6</sup>                             |

Virtual memory allows multiple processes to share files and memory through page sharing.
For example, in Chrome, each tab is a separate process but uses the same shared libraries like libc and libssl.
Instead of loading separate copies for each tab, the operating system maps the same physical pages into each process, thus reducing memory usage significantly.

#### Demand Paging

As mentioned earlier, for a program to execute, it must first be loaded into main memory.
However, when dealing with large programs, it’s not always necessary to load the entire program at once, only a portion currently needed.
Consider an open-world video game: while the entire map may be massive, the player only interacts with and views a small area at any given time, such as a 1 km² region around them.
This is where demand paging comes into play.
With demand paging, only the required pages of a program are loaded into memory on demand.

| <img src="/assets/2025-06-03-memory_allocation_in_go/demand_paging.png" width=400> |
|:----------------------------------------------------------------------------------:|
|                             Demand paging <sup>7</sup>                             |

As a process executes, some of its pages are loaded into memory, while others remain on disk storage (i.e., backing store).
To manage this, an additional column called the *valid-invalid bit* is included in the page table to indicate the status of each page.
If the bit is set to *valid (v)*, it means the page is both legal (i.e. belonging to the process's logical address space) and currently loaded in memory.
If the bit is *invalid*, the page is either outside the process’s logical address space (illegal) or it is a valid page that currently resides on disk.

When a process tries to access a page whose valid-invalid bit is set to invalid (i), a *page fault* occurs, causing a trap to the operating system.
The operating system then follows these steps to handle the page fault:
1. It checks the process’s internal table to determine whether the memory reference is valid.
2. If the address is invalid (i.e., not part of the process's logical address space), the process is terminated. 
3. If the address is valid but the page is not currently in memory, the page is paged in.
4. The operating system locates a free frame in physical memory.
5. It instructs the disk to read the required page into the newly allocated frame.
6. Once complete, process's internal table and page table are updated to reflect that the page is now in memory.
7. The process then resumes execution from the instruction that caused the page fault.

In Linux, two key memory metrics are *Resident Set Size (RSS)* and *Virtual Size (VSZ)*.
RSS represents the amount of physical memory a process is currently using, including shared memory but excluding swapped-out pages.
VSZ, on the other hand, represents the total virtual memory allocated to a process, including shared libraries plus the entire reserved address space, regardless of whether it is currently in physical memory or swapped out.
Also, VSZ includes memory allocated but not yet used by the process, such as memory reserved through [`mmap`](https://man7.org/linux/man-pages/man2/mmap.2.html) or [`malloc`](https://man7.org/linux/man-pages/man3/free.3.html) that has not been accessed, which is not included in RSS.

#### Virtual Memory Layout

Although virtual memory abstraction frees user-space programmers from managing physical memory directly, challenges still arise during memory allocation.
Developers must consider issues such as where to allocate memory, whether a given address is valid, and whether it conflicts with reserved regions like the code segment.
To address these issues, operating systems introduce the concept of *virtual memory layout*.
From a process’s perspective, the virtual address layout appears as illustrated below, with addresses growing upward.

| <img src="/assets/2025-06-03-memory_allocation_in_go/virtual_memory_layout.png" width=400> |
|:------------------------------------------------------------------------------------------:|
|               Virtual memory layout of an x86-64 Linux process <sup>8</sup>                |

The virtual memory layout is divided into several segments:
1. **Kernel virtual memory space**: Reserved for the kernel and is not accessible to user-space processes.
2. **(User) Stack**: Holds the stack frames of the process's main thread and grows downward.
3. **Memory mapped regions**: Memory allocated by [`mmap`](https://man7.org/linux/man-pages/man2/mmap.2.html) for shared memory, file or anonymous mapping.
4. **Heap**: Memory allocated by the process for dynamic memory allocation, which grows upward.
5. **Initialized data segment (`.data`)**: Contains global and static variables that are initialized by the program.
6. **Uninitialized data segment (`.bss`)**: Contains program's uninitialized global and static variables.
7. **Read-only code segment**: Contains the executable code of the program, which is typically read-only.

Note that these segments are merely pages within the process's virtual address space.

#### Stack Allocation

Every process has a stack, a memory segment that tracks the local variables and function calls at some point in time.
It's a data structure that grows downward as functions are called and local variables are allocated, shrinking upward as functions return.
When a function is called, a new *stack frame* is created on the stack, which contains the function's local variables, parameters, and return address.
When the function returns, its stack frame is popped off the stack, deallocating all variables within that stack frame.

| <img src="https://cdn.hashnode.com/res/hashnode/image/upload/v1700063997626/2783c1e7-7c4e-4f76-a09f-dee9ff4094ad.gif" width=500> |
|:--------------------------------------------------------------------------------------------------------------------------------:|
|                      Visualization of how process stack grows and shrinks as program executes <sup>9</sup>                       |

Every thread has its own stack. Since a process can have multiple threads, there may be multiple stacks within a process.
When we refer to the "process stack",  we typically mean the stack of the main thread.
When a thread is created, it is assigned with a stack that is separate from the main thread's stack.
Because each thread has an isolated stack, stack allocations do not require synchronization.
If a new thread is created using the [`pthread_create`](https://man7.org/linux/man-pages/man3/pthread_create.3.html) system call, the kernel by default automatically selects a suitable memory region for the stack.
Alternatively, we can manually specify the starting address of the stack by [`pthread_attr_setstack`](https://man7.org/linux/man-pages/man3/pthread_attr_setstack.3.html) system call.
This behavior also applies to threads created using the [`clone`](https://man7.org/linux/man-pages/man2/clone.2.html) system call.

The size of stack is fixed at the time of thread creation, and it cannot be dynamically resized.
The default size of stack is determined by the `RLIMIT_STACK` resource limit.
Default value of `RLIMIT_STACK` is typically 2 MB on most architectures, or 4 MB on POWER and Sparc-64.
While `RLIMIT_STACK` is global, if we want to set stack size for a specific thread, we can use [`pthread_attr_setstacksize`](https://man7.org/linux/man-pages/man3/pthread_attr_setstacksize.3.html) to allow for larger stack if that thread allocates large automatic variables or make nested function calls great depth (perhaps because of recursion).

In order to keep track of the top of the stack, the CPU uses a special register called the *stack pointer*.
Depending on the architecture, it may be called `RSP` on x86-64, `ESP` on x86, or `SP` on ARM.
Before a thread starts executing, the stack pointer is initialized to point to the top of the stack.
As stack is pre-allocated in thread creation, allocating a variable on the stack is simply moving the stack pointer down, which is a very fast operation.
Loading a variable from the stack is also fast, as it only requires reading the value at the address pointed to by the stack pointer.

There is also another special register called the *base pointer* (or *frame pointer*), which points to the start of the current stack frame.
It's used to provide a stable reference point for accessing local variables as well as function parameters.
The stack deallocation is done by simply setting the stack pointer back to the base pointer, which is fast.

Since stack allocation is determined at compile time, it is the compiler's responsibility to calculate the size of all variables and generate the corresponding assembly code to allocate them on the stack.
The compiler also emits instructions to deallocate the stack frame when the function returns.
For example, `MOVD` is used to store a variable onto the stack, while `ADD` is used to increase the stack pointer thus deallocate the stack frame.

| <img src="/assets/2025-06-03-memory_allocation_in_go/general_stack_frame.png" width=300> |
|:----------------------------------------------------------------------------------------:|
|                            General stack frame <sup>10</sup>                             |

The figure above illustrates a general stack frame layout for a scenario in which function `P` calls function `Q`.
The frame for the currently executing procedure is always at the top of the stack.
The base pointer (`%rbp`) marks the start of the current stack frame, while the stack pointer (`%rsp`) points to the top of the stack.
During `P`'s execution, it may allocate space on the stack by increasing the stack pointer to store local variables.

When `P` calls `Q`, it pushes the return address onto the stack, which tells the program where to resume execution in `P` after `Q` returns.
This return address is considered part of `P`’s stack frame, as it holds state relevant to `P`.
At this point, `P` may also save register values and prepare arguments for the called procedure.
When control transfers to `Q`, the base pointer `%rbp` no longer points to `P`’s stack frame; instead, it is updated to point to the start of `Q`’s frame.
`Q` then deallocates its own stack frame by decreasing the stack pointer upon returning.

Not every variable should be allocated on the stack due to the following reasons.
Since stack allocation is determined at compile time, if variable's size is not known at this time, it can't be allocated on stack.
Additionally, if variable is local to function `F` but still referenced by another function when `F` returns, allocating this variable on stack causes invalid address access.
In such case, we need to allocate the variable on the heap instead.

#### Heap Allocation

Allocation variables on the heap means finding a free memory block in from the heap segment or resizing the heap there is no such memory block.
The current limit of the heap is referred to as the *program break*, or *brk* as depicted in the above figure.

Resizing the heap is just simple as telling the kernel to adjust its idea of where the process’s program break is.
After the program break is increased, the program may access any address in the newly allocated area, but no physical memory pages are allocated yet.
The kernel automatically allocates new physical pages on the first attempt by the process to access addresses in those pages.
Once the virtual memory for heap is expanded, the process can choose wherever memory block to hold value for variable.

Linux offers `brk` system call to change the position of program break and `sbrk` system call for how much to increase program break.
While programmers usually care about variable's size when allocating it, `brk` and `sbrk` is rarely used and `malloc` is used in Linux instead.

`malloc` first scans the list of memory blocks previously released by `free` in order to find one whose size is larger than or equal to its requirements.
Different strategies may be employed for this scan, depending on the implementation; for example, first-fit or best-fit.
If the block is exactly the right size, then it is returned to the caller.
If it is larger, then it is split, so that a block of the correct size is returned to the caller and a smaller free block is left on the free list.
If no block on the free list is large enough, then `malloc` calls `sbrk` to allocate more memory.
To reduce the number of calls to `sbrk`, rather than allocating exactly the number of bytes required, `malloc` increases the program break in larger units (some multiple of the virtual memory page size), putting the excess memory onto the free list.

The figure below depicts how `malloc` manages memory blocks in heap, which is a one-dimensional array of memory address.
Each memory block, apart from the actual space used for storing value of variables, it also stores its metadata such as the length of the block, pointer to previous block and next block in the free list.
These metadata allows `malloc` and `free` to function properly.

| <img src="/assets/2025-06-03-memory_allocation_in_go/free_list_visualization.png" width=300> |
|:--------------------------------------------------------------------------------------------:|
|                             Free list visualization<sup>11</sup>                             |


As heap is shared across threads, to avoid corruption in multithreaded applications, mutexes are used internally to protect the memory-management data structures employed by these functions.
In a multithreaded application in which threads simultaneously allocate and free memory, there could be contention for these mutexes.
Therefore, heap allocation is less efficient than stack allocation.

Mention:
- Heap allocation requires synchronization, as multiple threads may allocate memory from the heap concurrently.

---

Mention page table to map virtual pages to physical frames (read "OS Concepts" book).
See: https://linux-kernel-labs.github.io/refs/heads/master/lectures/address-space.html#linux-paging

Mention first-fit, best-fit, and segregated-fit algorithms for memory allocation (read https://www.cs.cmu.edu/afs/cs/academic/class/15213-f09/www/lectures/17-dyn-mem.pdf).
Also read 9.9.14 Segregated Free Lists in Computer System, A Programmer's Perspective book.

Mention process memory layout: text, data, heap, stack, mmap regions (read "OS Concepts" book and online resource).

Mention RSS and VSZ, how they relate to memory allocation (read "Linux Programming Interface" book).

Mention that there are many APIs to allocate memory: sbrk, malloc, free. malloc is a wrapper around sbrk, which is a system call to allocate memory from the heap.

Mention that `mmap` system call just allocates virtual memory in between process stack and heap, Linux uses demand paging (demand-zero paging), the physical frame is not allocated until the corresponding page is accessed.
- https://offlinemark.com/demand-paging/
- https://ryanstan.com/linux-demand-paging-anon-memory.html
- https://www.kernel.org/doc/html/v5.16/admin-guide/mm/concepts.html#anonymous-memory
- https://stackoverflow.com/questions/60076669/kernel-virtual-memory-space-and-process-virtual-memory-space
- Section 9.8 Memory Mapping, Computer System: A Programmer's Perspective book

Explain physical frame, virtual page, page table, memory layout, demand paging, VSZ, RSS.
Explain stack, heap, memory fragmentation.
Mention that stack is linear allocation, that's why it is fast.
Get image from the book: Computer Systems: A Programmer's Perspective.

Mention that each thread has its own stack. When creating thread with clone (what Go does), the stack space must be allocated beforehand and the starting address of the stack must be specified.
See: https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/os_linux.go#L186-L186
When Go clones a thread, it passes M.g0.stack.hi as the stack address.
See: https://grok.com/chat/ce58ca57-b84a-41ca-8ecf-54498ab0c6ba

Talk about RSP register. Mention that process's stack is pre-allocated, so allocating memory on stack is just moving the RSP register down, WITHIN the allocated memory space.
Therefore, allocating variable on stack is fast & cheap.
Initially, when a process is created, the value of RSP is set to the top of the stack, as mentioned in https://lwn.net/Articles/631631/: "the saved stack pointer to the current top of the stack"
Also mentioned in: https://refspecs.linuxfoundation.org/ELF/zSeries/lzsabi0_zSeries/x895.html

Apart from RSP, there is frame pointer (FP) or base pointer (BP) register, which points the starting address of the current function's stack frame. This is used to access local variables and function parameters.

Eg:
```cpp
#include <stdio.h>
void func() {
    int x = 10; // "Allocated" by decrementing RSP within pre-allocated stack
    printf("Stack variable at %p\n", &x);
}
int main() {
    int *p = malloc(4); // Dynamic heap allocation
    func();
    free(p);
    return 0;
}
```
Stack: The variable x in func is allocated by decrementing RSP (e.g., sub rsp, 8 in assembly) within the main thread’s pre-allocated stack ([0x7ffffffde000 - 0x7ffffffff000]).
Heap: malloc(4) requests memory from the heap, potentially expanding it via brk or mmap.
Assembly for func (simplified x86-64)

```asm
func:
    push rbp
    mov rbp, rsp
    sub rsp, 8    ; Reserve 8 bytes for x within pre-allocated stack
    mov DWORD PTR [rsp], 10 ; Store 10 in x
    ...
    mov rsp, rbp  ; Restore RSP
    pop rbp
    ret
```

RBP is the base pointer register. `mov rbp, rsp` save the current stack pointer (RSP) to the base pointer (RBP), establishing a new stack frame.
When function returns, `mov rsp, rbp` restores the stack pointer to its previous state, effectively deallocating the space used by local variables like x.

## Heap

UNDERSTAND: https://github.com/golang/proposal/blob/2c02d6bab9c85b41afd730856a70286a687f85be/design/35112-scaling-the-page-allocator.md

Mention that there is still memory fragmentation in Go, as specified in:
https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/sizeclasses.go#L90-L90

Ask why there is no method to allocate memory on stack like `malloc` for heap allocation, that's because stack allocation is done at compile time, while heap allocation is done at runtime.
Mention that Go's stack doesn't relate to the process stack, Go's heap doesn't relate to the process heap.
Go's heap is allocated using `mmap` and is managed by the Go runtime. Go's stack and heap live in this mapped memory space.

Mention mspan.

Mention that type with no pointer will be allocated in noscan spanclass, while types with pointers will be allocated in scan spanclass.
GC doesn't need to scan every field of object of noscan spanclass, but it needs to visit scan spanclass to find pointers to other objects.

Mention that each mspan has a heapBits method.
If heapBits is already in mspan (size ≤ 512 bytes), we don't need to allocate header for the objects in that mspan.
heapBits is a bitmap that store at the end of the mspan, it indicates which words has a pointer to another object.
heapBits is set in heapSetTypeNoHeader method, which is called when the object is allocated.
Otherwise, we need to allocate a header for the objects in that mspan, indicated by size += mallocHeaderSize.
Header is prepended to the object. There are 8 bytes of header, and the remaining 8 bytes is used for the object itself.
https://go.googlesource.com/proposal/+/master/design/12800-sweep-free-alloc.md                                                             

https://go.dev/src/runtime/mbitmap.go
The GC method scanobject -> typePointersOfUnchecked -> heapBitsSmallForAddr: read heapBits
                                                    \-> read object's type header

Mention radix tree, which is used to find a free page in heap arenas.

Mention the heap arena arenaBaseOffset = 0xffff800000000000*goarch.IsAmd64 + 0x0a00000000000000*goos.IsAix
However, this is not heap arena starting address, it's just used to calculate the heap arena offset, index

Mention mheap.pageAlloc uses radix-tree to find a free page from heap arenas.

Mention mheap.pageAlloc also sweeps & scavenges, by invoking sysUnused (madvise with _MADV_FREE).
After scavenging, the mapping from virtual pages to physical frames is removed, kernel reclaming the physical frames.

Explain the behavior of mheap when allocating heap arenas:
- Heap arenas may not be contiguous in process virtual memory space.
- ...

===

Mention that pageAlloc is the struct that manges the heap arenas, is responsible for finding free pages in heap arena.
pageAlloc uses a radix tree to store the bit map of pages, where 0 means free and 1 means in-used.
The bitmap is sharded into multiple chunks:
```go
// Each chunk represents 512 pages (4MB) of memory
const (
  pallocChunkPages    = 1 << logPallocChunkPages  // 512 pages
  pallocChunkBytes    = pallocChunkPages * pageSize // 4MB
  logPallocChunkPages = 9
)
```
The bitmap is divided into chunks, where each chunk tracks 512 pages (4MB) of memory. Each chunk has its own bitmap:
```go
// pallocData encapsulates pallocBits and a bitmap for scavenging
type pallocData struct {
    pallocBits    // Main bitmap: 0 = free, 1 = allocated
    scavenged pageBits  // Scavenging bitmap
}

// pallocBits is a bitmap that tracks page allocations for one chunk
type pallocBits pageBits

// pageBits represents 512 bits (one per page)
type pageBits [pallocChunkPages / 64]uint64  // 8 uint64s = 512 bits, each bit represents in-use or free of a page, 1 pageBits is for 1 chunk
```

The chunks are stored in a two-level sparse array (similar to mheap.arenas):
```go
type pageAlloc struct {
    // Two-level sparse array of chunks
    chunks [1 << pallocChunksL1Bits]*[1 << pallocChunksL2Bits]pallocData
}
```

This means:
- L1: Points to L2 arrays (only allocated when needed)
- L2: Contains the actual pallocData chunks
- Sparse: Only chunks that are actually used are allocated

```go
func (b *pallocBits) summarize() pallocSum {}
```

pallocSum, is a summary, which has 3 properties:
- start: number of first consecutive 0s in the bitmap
- end: number of last consecutive 1s in the bitmap
- max: maximum number of consecutive 0s in the bitmap

Summaries can be merged with each other to create a hierarchical structure, allowing for efficient searching of free pages:
- we can merge the summaries by picking the maximum of each summary's max value and the sum of their start and end values.
- I propose we update these summary values eagerly as spans are allocated and freed

```go
type pageAlloc struct {
  // Radix tree of summaries
  summary [summaryLevels][]pallocSum
}
```

Example for 64-bit system:
L0 (Root): Each summary covers 16GB (represents 8 L1 summaries)
L1: Each summary covers 2GB (represents 8 L2 summaries)
L2: Each summary covers 256MB (represents 8 L3 summaries)
L3: Each summary covers 32MB (represents 8 L4 summaries)
L4 (Leaf): Each summary covers 4MB (represents 1 chunk)

A given entry at some level of the radix tree represents the merge of some number of summaries in the next level.
The leaf level in this case contains the per-chunk summaries, while each entry in the previous levels may reflect 8 chunks, and so on.
This tree would be constructed from a finite number of arrays of summaries, with lower layers being smaller in size than following layers, since each entry reflects a larger portion of the address space.

Visual Example
Let's say we want to allocate 3 pages:
1. Check page cache → Empty
2. Search radix tree:
  L0: Summary says "max 100 free pages" → Descend to L1
  L1: Summary says "max 50 free pages" → Descend to L2
  L2: Summary says "max 10 free pages" → Descend to L3
  L3: Summary says "max 5 free pages" → Descend to L4
  L4: Summary says "max 3 free pages" → Search this chunk's bitmap
3. Search chunk bitmap:
  Bitmap: 000111000000... (0=free, 1=allocated)
  Find first 3 consecutive 0s → Found at position 3
  Return address: chunkBase + 3 * pageSize
4. Update bitmaps and summaries:
  Set bits 3,4,5 in chunk bitmap to 1
  Recompute chunk summary
  Propagate changes up the radix tree

Key Benefits
  Efficient Search: O(log n) instead of O(n)
  Cache-Friendly: Summary blocks fit in cache lines
  Memory Efficient: Only allocate chunks that are used
  Fast Updates: Only update affected summaries
  The radix tree acts as a hierarchical index over the bitmap, allowing the allocator to quickly skip over large regions with no free space and focus on promising areas.

===

Mention during program bootstrap, Go runtime also initializes 2 goroutines for sweeping and scavenging.

Mention 1 heap allocation optimization is grouping scalar types into a single struct allocation.
See: https://github.com/golang/go/commit/ba7b8ca336123017e43a2ab3310fd4a82122ef9d.

Mention scavenge: https://groups.google.com/g/golang-nuts/c/eW1weV-FH1w

## Thread Stack and Goroutine Stack

Mention stack of main thread and other thread in Go.

Mention that each thread created with clone is allocated with a new thread, as in https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/proc.go#L2242-L2242
This is subject to the requirement of clone: the caller of clone must setup stack space for child thread before calling clone.
The parameter `stack` in `clone` is the starting address (higher address) of the stack space for the child thread.
The stack size of threads other than main is 16KB, see https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/proc.go#L2242-L2242
While stack size of main thread is controlled by the kernel.

Mention that the memory space used by stack is also mspan.

Mention stack allocation use mheap.allocSpan with typ=spanAllocStack (allocManual), while heap allocation use mheap.allocSpan with typ=spanAllocHeap
However, mspan that stack uses is initialized differently than mspan that heap uses.
See: https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/mheap.go#L1398-L1446

Read https://www.bytelab.codes/what-is-memory-part-3-registers-stacks-and-threads
In stack section, mention stack pointer (SP) register and frame pointer (FP) register (if it's relevant to the discussion).
See https://substackcdn.com/image/fetch/f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F35358ebb-0af2-482e-a359-36932f60b1a5_399x299.png
SP is physically a register in CPU, it points to the top of the stack.
FP is a pointer to the current function's stack frame, it is used to access local variables and function parameters.
Mention how Go handle stack operation:
- when new variable is allocated on stack, it decreases the SP register
- when a function returns, it increases the SP register.
- because the size of variables is determined at compile time, the SP register is always increased by a fixed amount.

Explain how SP, FP is set to stack.lo, stack.hi (gobuf) in Go runtime.
Explain stackguard. Why don't just use stack.lo and stack.hi as the stack bounds?

| Stack   |
|---------|
|         | <- hi
|         |
|         | <- lo
| ------- |
| Heap    |

Mention stack init https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/stack.go#L167-L167

Mention system stack of each thread is non-preemptible and the GC doesn't scan system stack.

Mention that Go initially used segmented stack, but now it uses contiguous stack.
Watch: https://youtu.be/-K11rY57K7k?si=YZrRRgGyZXAs7tes

Mention escape analysis.

===

Explain more about system stack g0.
See: https://go.dev/src/runtime/HACKING#stacks
See: https://www.sobyte.net/post/2022-07/go-gmp/#4-the-role-of-g0
See: https://draven.co/golang/docs/part3-runtime/ch06-concurrency/golang-goroutine/#%E5%88%9D%E5%A7%8B%E5%8C%96%E7%BB%93%E6%9E%84%E4%BD%93

For main thread M, M's system stack g0 is allocated by the kernel.
Go runtime creates an instance of Go runtime stack with stack.hi-stack.lo = 64*1024.
See https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/asm_amd64.s#L170-L176

For non-main thread M,
- In Linux, m's system stack g0 is allocated by Go runtime.
- In Darwin and Windows, m's system stack g0 is allocated by the kernel.
  if iscgo || mStackIsSystemAllocated() {
    mp.g0 = malg(-1)
  } else {
    mp.g0 = malg(16384 * sys.StackGuardMultiplier)
  }

Below is how system stack g0 is allocated in Darwin:
The Go runtime uses a clever approach that combines information gathering before thread creation with runtime stack discovery when the new thread starts executing. Here's how it works:
1. Pre-Creation Setup (in newosproc)
   Before calling pthread_create, the Go runtime in newosproc function:
```cassandraql
	// Find out OS stack size for our own stack guard.
	var stacksize uintptr
	if pthread_attr_getstacksize(&attr, &stacksize) != 0 {
		writeErrStr(failthreadcreate)
		exit(1)
	}
	mp.g0.stack.hi = stacksize // for mstart
```
   Calls pthread_attr_getstacksize to get the size of the stack that pthread will allocate
   Stores this size in mp.g0.stack.hi (note: this is initially just the size, not the actual address)
2. Thread Starts at mstart_stub
   When pthread_create creates the new thread, it starts execution at mstart_stub. Looking at the Darwin ARM64 assembly:
```
TEXT runtime·mstart_stub(SB),NOSPLIT,$160
	// R0 points to the m.
	// We are already on m's g0 stack.

	// Save callee-save registers.
	SAVE_R19_TO_R28(8)
	SAVE_F8_TO_F15(88)

	MOVD	m_g0(R0), g
	BL	·save_g(SB)
```
   The key insight is in the comment: "We are already on m's g0 stack." At this point, the new thread is executing on the pthread-allocated stack.
3. Stack Address Discovery in mstart0
   The actual stack address discovery happens in mstart0:
```
	gp := getg()

	osStack := gp.stack.lo == 0
	if osStack {
		// Initialize stack bounds from system stack.
		// Cgo may have left stack size in stack.hi.
		// minit may update the stack bounds.
		//
		// Note: these bounds may not be very accurate.
		// We set hi to &size, but there are things above
		// it. The 1024 is supposed to compensate this,
		// but is somewhat arbitrary.
		size := gp.stack.hi
		if size == 0 {
			size = 16384 * sys.StackGuardMultiplier
		}
		gp.stack.hi = uintptr(noescape(unsafe.Pointer(&size)))
		gp.stack.lo = gp.stack.hi - size + 1024
	}
```
Here's the crucial technique:
Current Stack Pointer: &size gives the address of a local variable on the current stack
Stack High Address: This becomes gp.stack.hi - the high end of the stack
Stack Low Address: Calculated as gp.stack.hi - size + 1024, where size is the stack size obtained earlier

===

Mention sys.NotInHeap, finalizer, write barrier.
sys.NotInHeap prevents the object from being allocated in Go heap, so it is not scanned by GC.
It's used for objects that are not managed by Go, and write barrier is omitted.
If we 'new' and object with sys.NotInHeap, compilation error will be raised.

===

Explain how stackguard relates to stack expansion

Stackguard, see the following. Framesize is the maximum size of the stack frame, which is determined at compile time.
SP + X means move SP up by X bytes, while SP - X means move SP down by X bytes.
- https://kirk91.github.io/posts/2d571d09/
- https://www.sobyte.net/post/2022-01/go-stack/#goroutine-stack-operations
- https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/cmd/internal/obj/arm/obj5.go#L712-L746

this case StackSmall < framesize < Stackbug means that if frame size of next function is greater than SmallStack and less than SmallBig,
but if the address space [SP -> function frame size] still fits within the address space [g.stack.hi -> StackSmall], then we can continue executing the function.

== Mention the importance of memory arena between [g.stackguard - StackSmall -> g.stack.lo]