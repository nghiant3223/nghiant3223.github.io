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
- https://www.youtube.com/watch?v=S_1YfTfuWmo
- https://go.googlesource.com/proposal/+/master/design/35112-scaling-the-page-allocator.md
- https://go.googlesource.com/proposal/+/refs/changes/57/202857/2/design/35112-scaling-the-page-allocator.md
- https://segmentfault.com/a/1190000041864888/en#item-5

## Basics of Main Memory

### What and Why?

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

### Simple Allocation Strategy

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

### External Fragmentation

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

### Memory Paging

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

### Demand Paging

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

### Virtual Memory Layout

Although virtual memory abstraction frees user-space programmers from managing physical memory directly, challenges still arise during memory allocation.
Developers must consider issues such as where to allocate memory, whether a given address is valid, and whether it conflicts with reserved regions like the code segment.
To address these issues, operating systems introduce the concept of *virtual memory layout*.
From a process’s perspective, the virtual address layout appears as illustrated below, with addresses growing upward.

| <img id="virtual_memory_layout.png" src="/assets/2025-06-03-memory_allocation_in_go/virtual_memory_layout.png" width=400> |
|:-------------------------------------------------------------------------------------------------------------------------:|
|                               Virtual memory layout of an x86-64 Linux process <sup>8</sup>                               |

The virtual memory layout is divided into several segments:
1. **Kernel virtual memory space**: Reserved for the kernel and is not accessible to user-space processes.
2. **(User) Stack**: Holds the stack frames of the process's main thread and grows downward.
3. **Memory mapped regions**: Memory allocated by [`mmap`](https://man7.org/linux/man-pages/man2/mmap.2.html) for shared memory, file or anonymous mapping.
4. **Heap**: Memory allocated by the process for dynamic memory allocation, which grows upward.
5. **Initialized data segment (`.data`)**: Contains global and static variables that are initialized by the program.
6. **Uninitialized data segment (`.bss`)**: Contains program's uninitialized global and static variables.
7. **Read-only code segment**: Contains the executable code of the program, which is typically read-only.

Note that these segments are merely pages within the process's virtual address space.

### Stack Allocation

Every process has a stack, a memory segment that tracks the local variables and function calls at some point in time.
It's a data structure that grows downward as functions are called and local variables are allocated, shrinking upward as functions return.
When a function is called, a new *stack frame* is created on the stack, which contains the function's local variables, parameters, and return address.
When the function returns, its stack frame is popped off the stack, deallocating all variables within that stack frame.

| <video width=500 autoplay controls id="stack_frame.mp4"><source src="/assets/2025-06-03-memory_allocation_in_go/stack_frame.mp4"/></video> |
|:------------------------------------------------------------------------------------------------------------------------------------------:|
|                           Visualization of how process stack grows and shrinks as program executes <sup>9</sup>                            |

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

### Heap Allocation

Allocation variables on the heap means finding a free memory block in from the heap segment or resizing the heap there is no such memory block.
The current limit of the heap is referred to as the *program break*, or *brk* as depicted in the above [figure](#virtual_memory_layout.png).

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
To reduce the number of calls to `sbrk`, rather than allocating exactly the amount of memory required, `malloc` increases the program break in larger units, putting the excess memory onto the free list.

The figure below depicts how `malloc` manages memory blocks in heap, which is a one-dimensional array of memory address.
Each memory block, apart from the actual space used for storing value of variables, it also stores its metadata such as the length of the block, pointer to previous block and next block in the free list.
These metadata allows `malloc` and `free` to function properly.

| <img src="/assets/2025-06-03-memory_allocation_in_go/free_list_visualization.png" width=300> |
|:--------------------------------------------------------------------------------------------:|
|                             Free list visualization<sup>11</sup>                             |

As heap is shared across threads, to avoid corruption in multithreaded applications, mutexes are used internally to protect the memory-management data structures employed by these functions.
In a multithreaded application in which threads simultaneously allocate and free memory, there could be contention for these mutexes.
Therefore, heap allocation is less efficient than stack allocation.

### Memory Mapping

As depicted in virtual memory layout figure below, apart from the heap and stack, there is also a memory segment called *memory mapped regions*.
There are two types of memory mapping: file mapping and anonymous mapping.
A file mapping maps a region of a file directly into the calling process’s virtual memory, allowing its contents can be accessed by operations on the bytes in the corresponding memory region.
An anonymous mapping doesn’t have a corresponding file; instead, the pages of the mapping are initialized to 0.
Another way of thinking of an anonymous mapping is that it is a mapping of a virtual file whose contents are always initialized with zeros.

| <img src="/assets/2025-06-03-memory_allocation_in_go/memory_layout_elf.png" width=400> |
|:--------------------------------------------------------------------------------------:|
|                      Memory layout for ELF programs <sup>12</sup>                      |

A memory mapped region can be *private* (aka. *copy-on-write*) or *shared*.
By private, it means that the memory region is only accessible by the process that created it.
Whenever a process attempts to modify the contents of a page, the kernel first creates a new, separate copy of that page for the process and adjusts the process's page tables.
Conversely, if the memory mapped region is shared, then all processes that share the same memory mapped region can see the changes made by any of them.

Demand paging also works for memory mapping.
When a user process's address space is expanded, kernel does not immediately allocate any physical memory for these new virtual addresses.
Instead, the kernel implements demand paging, where a page will only be allocated from physical memory and mapped to the address space when the user process tries to write to that new virtual memory address<sup>[N](https://ryanstan.com/linux-demand-paging-anon-memory.html)</sup>.
The read accesses will result in creation of a page table entry that references a special physical page filled with zeroes<sup>[N](https://www.kernel.org/doc/html/v5.16/admin-guide/mm/concepts.html#anonymous-memory)</sup>.

Since anonymous memory mappings are not backed by a file and are always zero-initialized, they are ideal for programs that implement their own memory allocation strategies—such as Go—rather than relying on the operating system's default allocators like `malloc` and `free`.
This allows greater control over memory management, enabling features like custom allocators or garbage collection tailored to the runtime's needs.


## Go's View of Virtual Memory

### Arena and Page

As a Go process is simply a user-space application, it follows the standard virtual memory layout described in the previous section.
Specifically, the *Stack* segment of the process is the `g0` stack (aka. system stack) associated with the main thread (`M0`) of the Go runtime.
Initialized (i.e. having non-zero value) global variables are stored in the *Data* segment, while uninitialized ones reside in the *BSS* segment.
The traditional *Heap* segment, which is located under the program break, is not utilized by the Go runtime to allocate heap objects.
Instead, Go relies heavily on memory-mapped segments for allocating memory for goroutine stacks and heap objects.

| <img src="/assets/2025-06-03-memory_allocation_in_go/go_virtual_memory_view.png" width=200> |
|:-------------------------------------------------------------------------------------------:|
|                         Virtual memory layout from Go's perspective                         |

To manage this memory efficiently, Go runtime partitions these memory-mapped segments into hierarchical units, ranging from coarse-grained to fine-grained.
The most coarse-grained units are known as an [*arenas*](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L245-L311), a fixed-size region of 64 MB. Arenas are not required to be contiguous due to the characteristic of [`mmap`](https://man7.org/linux/man-pages/man2/mmap.2.html) system call, which *may return a different address than requested*.

Each arena is further subdivided into smaller fixed-size units called *pages*, each measuring 8 KB.
It's important to note that these runtime-managed pages differ from the typical OS pages discussed in the previous section, which are commonly 4 KB in size.
Each page holds multiple objects of *the same size* if the objects are smaller than 8 KB, or just a single object if the size is exactly 8 KB.
Objects larger than 8 KB stretch over multiple pages.

| <img src="/assets/2025-06-03-memory_allocation_in_go/go_memory_pages.png" width=900> |
|:------------------------------------------------------------------------------------:|
|                                  Go's memory pages                                   |

These pages are also utilized for the allocation of goroutine stack.
As discussed previously in my [Go Scheduler](https://nghiant3223.github.io/2025/04/15/go-scheduler.html) blog post, each goroutine stack initially occupies 2 KB, meaning a single 8 KB page can house up to 4 goroutine stacks.

### Span and Size Class

Another key concept in Go's memory management is the [*span*](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496).
A span is a unit of memory consisting of one or more *contiguous* pages allocated together.
Each span is subdivided into multiple objects of the same size.
By partitioning a span into multiple equal object, Go effectively uses *segregated fit* memory allocation strategy.
This strategy allows Go to efficiently allocate memory for objects of various sizes while minimizing fragmentation.

The Go runtime organizes object sizes into a set of predefined groups called *size classes*.
Every span belongs to exactly one size class, determined by the size of objects it contains.
Go defines 68 distinct size classes, numbered from 0 to 67, as shown in this [table](https://github.com/golang/go/blob/go1.24.0/src/runtime/sizeclasses.go#L6).
Size class 0 is reserved to handle allocation for *large objects*, which is larger than 32 KB, while size class 1 to 67 are used for *tiny objects* and *small objects*.
Note that every span belonging to some size class has a fixed number of pages and objects, as specified in the aforementioned [table](https://github.com/golang/go/blob/go1.24.0/src/runtime/sizeclasses.go).

| <img src="/assets/2025-06-03-memory_allocation_in_go/span_with_size_class.png" width=900> |
|:-----------------------------------------------------------------------------------------:|
|                           Two spans with different size classes                           |

The figure above illustrates two spans: one from size class 38 (holding 2048-byte objects) and another from size class 55 (holding 10880-byte objects).
Because a single 8 KB page fits exactly four 2048-byte objects, the span for size class 38 contains 8 objects within a single page.
Conversely, since each 10880-byte object exceeds one page, the span for size class 55 spans 4 pages, accommodating 3 objects.

But why doesn't a span of size class 55 contain only one object and stretch over 2 pages, as described in the below figure?
The reason is to reduce memory fragmentation. Since objects within a span are contiguous, there could be a space between the last object and the end of the span.
This space is called *tail waste*, and can be easily determined by the formula `(number of pages)*8192-(number of objects)*(object size)`.
If the span were allocated across 2 pages, the tail waste would be `2*8192-10880*1=5504` bytes, significantly higher than the `4*8192-10880*3=128` bytes of tail waste when allocated across 4 pages.

| <img src="/assets/2025-06-03-memory_allocation_in_go/span_tail_waste.png" width=900> |
|:------------------------------------------------------------------------------------:|
|                                  Tail waste in span                                  |

While a user Go application can allocate objects of various sizes, why does Go have only 67 size classes for small objects?
What if our application allocates a small object of size 300 bytes, which doesn't have a corresponding entry in ths size classes [table](https://github.com/golang/go/blob/go1.24.0/src/runtime/sizeclasses.go)?
In such case, Go runtime will round up the size of the object to the next size class, which is 320 bytes in this case.
The <span style="color:#a9c3aa">green</span> object illustrated so far is not an actual object allocated by user Go application, but rather a size class object managed by the Go runtime.

| <img src="/assets/2025-06-03-memory_allocation_in_go/user_objects_and_size_class_objects.png" width=500> |
|:--------------------------------------------------------------------------------------------------------:|
|                               User objects and size class objects in span                                |

Objects allocated by user Go application (abbreviated by *user objects*) are contained within a size class object.
User objects can vary in size, but they must be smaller than the size of the size class object.
Because of this, there could be a waste between the size of the user object and the size of the size class object.
These wastes together with the tail waste constitutes the *total waste* of the span.

Let's consider a span of size class 55 in the worst-case scenario, where it holds three user objects, each with a size of 10241 bytes.
The waste of 3 size class objects is `3*(10880-(10240+1))=3*639=1917` bytes (10240 is the size of the size class 54), and the tail waste is `4*8192-10880*3=128` bytes.
Therefore, the total waste of this span is `1917+128=2045` bytes, while the span size is `4*8192=32768` bytes, resulting in the maximum total waste of `2045/32768=6.23%`, as described in the 6th column of the size class 55 in Go's size class [table](https://github.com/golang/go/blob/go1.24.0/src/runtime/sizeclasses.go#L54).

### Span Class

Go’s garbage collector is a tracing garbage collector, which means it needs to traverse the object graph to identify all reachable objects during a collection cycle.
However, if a type is known to contain no pointers neither directly nor through its fields, e.g. a struct that has multiple fields and some of the fields contain pointer to primitive types for pointer to another struct, then the garbage collector can safely skip scanning objects of that type to reduce overhead and improve performance, right?
The presence or absence of pointers in a type is determined at compile time, so this optimization comes with no additional runtime cost.

To facilitate this behavior, the Go runtime introduces the concept of a span class.
A span class categorizes memory spans based on two properties: the size class of the objects they contain and whether those objects include pointers.
If the objects contain pointers, the span belongs to the *scan* class. If they don’t, it's classified as a *noscan* class.

Because pointer presence is a binary property—either a type contains pointers or it doesn’t—the total number of span classes is simply twice the number of size classes.
Go defines `68*2=136` span classes in total. Each span class is represented by an integer, ranging from 0 to 135.
If span class is even, it is a *scan* class; while if it is odd, it is a *noscan* class.

Previously, I mentioned that every span belongs to exactly one size class.
More accurately, however, every span belongs to exactly one span class.
The associated size class can be derived by dividing the span class number by 2.
Whether the span belongs to scan or noscan class is determined by the parity of the span class number: even numbers indicate scan spans, while odd numbers indicate noscan spans.

### Heap Bits and Malloc Header

Given a big struct having 1000 fields, some of the fields are pointers, how does Go's garbage collector know which fields are pointers so that it can traverse the object graph correctly?
If the GC had to inspect every field of every object at runtime, it would be prohibitively inefficient, especially for large or deeply nested data structures.
To solve this, Go uses metadata to efficiently identify pointer locations without scanning all fields.
This mechanism is based on two key structures: heap bits and malloc headers.

For objects smaller than 512 bytes, Go allocates memory in spans and uses a heap bitmap to track which words in the span contain pointers.
Each bit in the bitmap corresponds to a word (typically 8 bytes): 1 indicates a pointer, 0 indicates non-pointer data.
The bitmap is stored at the end of the span and shared by all objects in that span.
When a span is created, Go reserves space for the bitmap and uses the remaining space to fit as many objects as possible.

| <img src="/assets/2025-06-03-memory_allocation_in_go/heap_bits.png" width=500> |
|:------------------------------------------------------------------------------:|
|                              Heap bits in a span                               |

For objects larger than 512 bytes, maintaining a big bitmap is inefficient.
Instead, each object is accompanied by an 8-byte malloc header—a pointer to the object’s type information.
This type metadata includes the [`GCData`](https://github.com/golang/go/blob/go1.24.0/src/internal/abi/type.go#L31-L42) field, which encodes the pointer layout of the object.
The garbage collector uses this data to precisely and efficiently locate only the fields that contain pointers.

| <img src="/assets/2025-06-03-memory_allocation_in_go/malloc_header.png" width=500> |
|:----------------------------------------------------------------------------------:|
|                              Malloc header in a span                               |

## Go Heap: [mheap](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L55-L241)

### Span Allocation

Since the Go runtime operates within a vast virtual address space, the [`mheap`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L55-L241) allocator can struggle to locate contiguous free pages efficiently when it comes to allocating a span, especially under high concurrency.
In early versions of Go, as detailed in the [Scaling the Go Page Allocator](https://go.googlesource.com/proposal/+/refs/changes/57/202857/2/design/35112-scaling-the-page-allocator.md) proposal, every `mheap` operation was globally synchronized.
This design caused *severe throughput degradation and increased tail latency* during heavy allocation workloads.
Today's Go memory allocator implements the scalable design from that proposal.
Let's dive into how it overcomes these bottlenecks and manages memory allocation efficiently in highly concurrent environments.

#### Tracking Free Pages

Because the virtual address space is large, and each page’s state (free or in-use) is a binary property, it is efficient to store this information in a bitmap where `1` represents in-use and `0` represents free.
Note that in-use or free in this context refers to whether the page is handed to `mcentral` or not, not whether it is in-use or free by the user Go application.
Each bitmap is an array of 8 `uint64` values, taking 64 bytes in total, and can represent the state of 512 contiguous pages.

Given that an arena is 64 MB in size and each page is 8 KB, there are `64MB/8KB=8192` pages in an arena.
Since each bitmap covers 512 pages, an arena requires `8192/512=16` bitmaps.
With each bitmap taking 64 bytes, the total size of all bitmaps for an arena is `16×64=1024` bytes, or 1 KB.

However, iterating through a bitmap to find a run of free pages is still inefficient, and wasteful if the bitmap doesn't contain any free pages.
It's better if we somehow *cache* the free pages so that we can quickly find a free page without scanning the bitmap.
Go introduces the concept of *summary* for a bitmap, which has three fields: `start`, `end`, and `max`.
`start` is the number of contiguous 0 bits at the beginning of a bitmap.
Similarly, `end` is the number of contiguous 0 bits at the end of the bitmap.
Finally, `max` represents the largest contiguous sequence of 0 bits.
The summaries are updated eagerly as soon as the bitmap is modified, i.e. when a page is allocated or freed.

The figure below shows a bitmap summary: there are 3 contiguous free pages at the beginning, 7 contiguous free pages at the end, and the longest run of free pages is 10.
The arrow indicates the growth direction in address space, i.e. 3 free pages at the lower address and 7 free pages at the higher address.

| <img src="/assets/2025-06-03-memory_allocation_in_go/bitmap_summary.png" width=500> |
|:-----------------------------------------------------------------------------------:|
|                          Visualization of a bitmap summary                          |

With these three fields, Go is able to find a sufficient contiguous free chunk of memory within a single arena or across multiple adjacent arenas by merging the summaries of contiguous memory chunks.
Consider two adjacent chunks, `S1` and `S2`, each spanning 512 pages.
The summary of `S1` is `start=3`, `end=7`, and `max=10`, while the summary of `S2` is `start=5`, `end=2`, and `max=8`.
Since these chunks are contiguous, they can be merged into a single summary covering all 1024 pages.
The merged one is computed as `start=S1.start=3`, `end=S2.end=2`, `max=max(S1.max, S2.max, S1.end+S2.start)=max(10, 8, 7+5)=12`.

| <img src="/assets/2025-06-03-memory_allocation_in_go/merging_summary.png" width=900> |
|:------------------------------------------------------------------------------------:|
|                  Merging summaries of two contiguous memory chunks                   |

By merging lower-level summaries, Go implicitly builds a hierarchical structure that enables efficient tracking of contiguous free pages.
It manages the entire virtual address space using a single global [*radix tree*](https://en.wikipedia.org/wiki/Radix_tree) of summaries as depicted in the figure below.
Each <span style="color:#0f8088">blue</span> box represents a summary for a contiguous memory chunk and its dotted lines to the next level reflects what portion in the next level it covers.
The <span style="color:#81b365">green</span> box represents the bitmap that a leaf node summary refers to.

| <img src="/assets/2025-06-03-memory_allocation_in_go/summary_radix_tree.png" width=900> |
|:---------------------------------------------------------------------------------------:|
|                  Radix tree of summaries for the entire address space                   |

On linux/amd64 architecture, Go uses a 48-bit virtual address space, which is `2^48` bytes or 256 TB.
In this setup, the radix tree has a height of 5.
Internal nodes (levels 0 to 3) store summaries derived from merging their 8 child nodes.
Each leaf node (level 4) corresponds to the summary of a single bitmap, which covers 512 pages.

There are `16384` entries at level 0, `16384*8` entries at level 1, `16384*8^2` entries at level 2, `16384*8^3` entries at level 3, and `16384*8^4` entries at level 4.
Because each leaf entry summarizes 512 pages, each level 0 entry summarizes `512*8^4=2097152` contiguous pages, which accommodates `2097152*8KB=16GB` amount of memory.
Note that these numbers represent the maximum possible entries. The actual number of entries at each level increases gradually as the Go heap grows.

| <img src="/assets/2025-06-03-memory_allocation_in_go/radix_tree_zoom.png" width=900> |
|:------------------------------------------------------------------------------------:|
|                      A deeper look into the summary radix tree                       |

As mentioned earlier, each level 0 entry summaries `209715=2^21` contiguous pages, `start`, `end`, and `max` can be as big as `2^21`.
As a result, storing all these three fields together requires up to `21*3=63` bits.
This makes it possible to pack a summary into a single `uint64` called [`pallocSum`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mpagealloc.go#L985-L990): the first 21 bits store `start`, the next 21 bits store `end`, and the following 21 bits store `max`.

There is one special case: if `max=2^21`, it means the entire chunk is free.
In this situation, `start` and `end` are also `2^21`, and the summary is encoded as `1<<63`.
Conversely, if the chunk has no free page, i.e. both `start`, `end` and `max` are `0`, the summary value is definitely `0`.

The summary radix tree is implemented as an [array of slices](https://github.com/golang/go/blob/go1.24.0/src/runtime/mpagealloc.go#L181-L202), where each slice corresponds to a tree level.
The array fixes the number of levels in the tree, while the slices grow dynamically as the Go heap expands.
Summaries for the lower address stays at the beginning of the slice, while summaries for the higher address are appended to the end of the slice.
Since the summary slice at a given level covers the entire *reserved* address space, the index of a summary within its slice directly determines the memory region it represents.

#### Finding Free Pages: [`pageAlloc.find`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mpagealloc.go#L631-L870)

Go uses depth-first search algorithm locate a sufficient run of free pages. It begins with scanning up to 16,384 entries at level 0 of the radix tree. If a summary is `0` (meaning no free pages), it moves on to the next entry.
If a sufficient run is found at the boundary between two adjacent entries, or at the start of the first entry, or at the end of the last entry, then it returns the address of the free run immediately, based on the address the summary refers to.

Otherwise, if current summary’s `max` field satisfies the allocation request, the search descends into its 8 child entries at the next level.
If the search reaches the leaf level but still can't find a sufficient run, then it scans the bitmap within the entry whose `max` value is large enough, in order to locate the exact run of free pages.
If we traverse all entries at level 0 but still can't find a sufficient run, it returns `0`, indicating no free pages.

You may notice a drawback in this algorithm: if many pages at the beginning of level 0 are already in use, the allocator ends up traversing the same path in the radix tree repeatedly for each allocation, which is inefficient.
Go addresses this by maintaining a *hint* called [`searchAddr`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/mpagealloc.go#L241-L249), which marks an address before which no free pages exist.
This allows the allocator to begin its search directly from the hint instead of restarting from the beginning.

Since allocations proceed from lower to higher addresses in the heap, the hint can be advanced after each search, shrinking the search space until new memory is freed.
In practice, most allocations occur close to the current hint.

#### Growing the Heap: [`mheap.grow`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L1482-L1583)

If no free pages are available in the radix tree, i.e. [`pageAlloc.find`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mpagealloc.go#L631-L870) returns 0, Go runtime must ask the kernel to expand its virtual address space by making an [`mmap`](https://man7.org/linux/man-pages/man2/mmap.2.html) system call.
The growth may not be as big as the number of pages requested, but instead occurs in larger chunks rounded up to the arena size (64 MB).
Even if only a single page is requested, the heap expands by 64 MB virtual memory (not physical one, thanks to demand paging!).

To manage this, the runtime maintains a list of *hint addresses* called [`arenaHints`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L158-L162), which are addresses it prefers the kernel to use for new allocations.
This list is initialized before the `main` function runs, and its values can be found [here](https://github.com/golang/go/blob/go1.24.0/src/runtime/malloc.go#L477-L553).
During heap growth, Go iterates through these hints, asking the kernel to allocate memory at each suggested address by passing that address to the first parameter of [`mmap`](https://man7.org/linux/man-pages/man2/mmap.2.html) system call.

The kernel, however, may choose a different location. If that happens, Go moves on to the next hint.
If all hints fail, Go falls back to requesting memory at a random address aligned to the arena size, and then updates the hint list so that the future growth stays contiguous with the newly allocated arena.

This process transitions the memory section from *None* to *Reserved*.
Once the arena is registered with the runtime, i.e. by being added to the [list of all arenas](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L127-L147), the section transitions from *Reserved* to *Prepared*.
At this point, the radix summary tree is updated to include the new arena, expanding the summary slices at each level, marking the bitmap for new pages as free, and update the summaries accordingly.
This new memory section is also tracked as [in-use](https://github.com/golang/go/blob/go1.24.0/src/runtime/mpagealloc.go#L386-L386).

#### Preparing a Span: [`mheap.haveSpan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L1270-L1385)

Once the requested run of pages is found, the runtime prepares an [`mspan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496) object to manage that memory range.
Like any other Go object, an [`mspan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496) itself must live in memory.
Thus, these [`mspan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496) objects are allocated by a [slab](https://en.wikipedia.org/wiki/Slab_allocation) allocator [`fixalloc`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mfixalloc.go#L16-L42), which requests memory directly from the kernel using [`mmap`](https://man7.org/linux/man-pages/man2/mmap.2.html) system call.

The span is then set up with its size class, the number of pages it covers, and the address of its first page.
The associated memory section transitions from *Prepared* to *Ready*, indicating that it's ready for [`mcentral`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mcentral.go#L20-L45) to use.

#### Caching Free Pages: [`mheap.allocToCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mpagecache.go#L110-L183)

Unfortunately, both [`pageAlloc.find`](#finding-free-pages-pageallocfind) and [`mheap.grow`](#growing-the-heap-mheapgrow) rely on global locks, which can become bottlenecks under heavy concurrent allocation workloads.
Since a Go program can run as many concurrent threads as there are `P`s (processors), caching free pages locally in each `P` helps avoid global lock contention.

Go implements this with a per-`P` [`pageCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L641-L641).
A [`pageCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L641-L641) consists of a base address for a 64-page-aligned memory chunk and a 64-bit bitmap tracking which of those pages are free.
Because each page is 8 KB, a single `P`'s [`pageCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L641-L641) can hold up to 512 KB of free memory.

When a goroutine requests a span from [`mheap`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L55-L241), the runtime first checks the [`pageCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L641-L641) of the current `P`.
If it contains enough free pages, those pages are used immediately to prepare a span.
If not, the runtime falls back to invoking [`pageAlloc.find`](#finding-free-pages-pageallocfind) to locate a sufficient run of pages.

If the [`pageCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L641-L641) is empty, the runtime allocates a new one.
It first tries to obtain pages near the current hint [`searchAddr`](https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/mpagealloc.go#L241-L249) in the summary radix tree (as described in [Finding Free Pages](#finding-free-pages-pageallocfind) section).
Since the hint may not be accurate, it may instead need to walk the radix tree to find free pages.

Note that the probability of having a `N` free pages decreases when `N` approaches 64, as the [`pageCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L641-L641) is limited to 64 pages.
In such case, there would be too many cache misses, and the runtime would have to frequently fall back to [`pageAlloc.find`](#finding-free-pages-pageallocfind) to find free pages.
That's why if `N` is greater than 16, the runtime doesn't bother checking the cache, and fallback to [`pageAlloc.find`](#finding-free-pages-pageallocfind) right away.

<table>
    <thead>
        <tr>
            <td>
                <pre class="mermaid" style="margin: unset">

flowchart LR
0[Start] --> A
A{N < 16} --> |No|B[Acquire lock]
B --> C[Find free pages at hint address]
C --> |Found?|D{Found free pages?}
D --> |Yes|E[Release lock]
D --> |No|F[Find free pages by<br/>walking summary radix tree]
F --> E
E --> G[Prepare a span]
A --> |Yes|H{Is<br/>P's page cache<br/>empty?}
H --> |Yes|I[Acquire lock]
I --> J[Allocate a <br/>new page cache<br/>for P]
J --> K[Release lock]
K --> L[Find free pages<br/>in the page cache]
H --> |No|L
L --> M{Found free pages?}
M --> |Yes|G
M --> |No|B
G --> 1[End]

                </pre>
            </td>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td style="text-align: center">
                Overview of span allocation logic
            </td>
        </tr>
    </tbody>
</table>

Once new pages are acquired, they are marked as in-use in the summary radix tree to prevent other `P`s from claiming them and to ensure the allocator does not reuse them on the next heap growth.
The summary radix tree hint is also updated so that subsequent allocations skip over these pages, which are in-use.

#### Caching Free Spans: [`mheap.allocMSpanLocked`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L1103-L1133)

As discussed in [Preparing a Span](#preparing-a-span-mheaphavespan), an [`mspan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496) must be allocated to represent and manage a span of pages. If an [`mspan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496) is obtained directly from [`mheap`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L55-L241), it requires acquiring a global lock, which can become a performance bottleneck. To avoid this, the Go runtime caches free [`mspan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496) objects per `P`, just as it does with pages.

When free pages are found in a [`pageCache`](https://github.com/golang/go/blob/go1.24.0/src/runtime/runtime2.go#L641-L641), the runtime first checks whether the current `P` already has a cached [`mspan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496).
If so, it can be reused immediately without any global lock contention.

If no cached [`mspan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496) is available, the runtime allocates multiple [`mspan`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L402-L496) objects from [`mheap`](https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L55-L241), caches them in the `P`’s free list for future use, and assigns one of them to manage the newly allocated run of pages.

Mention 1 heap allocation optimization is grouping scalar types into a single struct allocation.
See: https://github.com/golang/go/commit/ba7b8ca336123017e43a2ab3310fd4a82122ef9d.

Mention scavenge: https://groups.google.com/g/golang-nuts/c/eW1weV-FH1w

## Goroutine Stack

https://docs.google.com/document/u/0/d/1wAaf1rYoM4S4gtnPh0zOlGzWtrZFQ5suE8qr2sD8uWQ/mobilebasic

Mention stack of main thread and other thread in Go.

Mention that each thread created with clone is allocated with a new thread, as in https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L2242-L2242
This is subject to the requirement of clone: the caller of clone must setup stack space for child thread before calling clone.
The parameter `stack` in `clone` is the starting address (higher address) of the stack space for the child thread.
The stack size of threads other than main is 16KB, see https://github.com/golang/go/blob/go1.24.0/src/runtime/proc.go#L2242-L2242
While stack size of main thread is controlled by the kernel.

Mention that the memory space used by stack is also mspan.

Mention stack allocation use mheap.allocSpan with typ=spanAllocStack (allocManual), while heap allocation use mheap.allocSpan with typ=spanAllocHeap
However, mspan that stack uses is initialized differently than mspan that heap uses.
See: https://github.com/golang/go/blob/go1.24.0/src/runtime/mheap.go#L1398-L1446

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

Mention stack init https://github.com/golang/go/blob/go1.24.0/src/runtime/stack.go#L167-L167

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
See https://github.com/golang/go/blob/go1.24.0/src/runtime/asm_amd64.s#L170-L176

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
- https://github.com/golang/go/blob/go1.24.0/src/cmd/internal/obj/arm/obj5.go#L712-L746

this case StackSmall < framesize < Stackbug means that if frame size of next function is greater than SmallStack and less than SmallBig,
but if the address space [SP -> function frame size] still fits within the address space [g.stack.hi -> StackSmall], then we can continue executing the function.

== Mention the importance of memory arena between [g.stackguard - StackSmall -> g.stack.lo]

Mention that each thread has its own stack. When creating thread with clone (what Go does), the stack space must be allocated beforehand and the starting address of the stack must be specified.
See: https://github.com/golang/go/blob/go1.24.0/src/runtime/os_linux.go#L186-L186
When Go clones a thread, it passes M.g0.stack.hi as the stack address.
See: https://grok.com/chat/ce58ca57-b84a-41ca-8ecf-54498ab0c6ba

## Escape Analysis
