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

Mention the heap arena arenaBaseOffset = 0xffff800000000000*goarch.IsAmd64 + 0x0a00000000000000*goos.IsAix
However, this is not heap arena starting address, it's just used to calculate the heap arena offset, index

Mention mheap.pageAlloc uses radix-tree to find a free page from heap arenas.

Mention mheap.pageAlloc also sweeps & scavenges, by invoking sysUnused (madvise with _MADV_FREE).
After scavenging, the mapping from virtual pages to physical frames is removed, kernel reclaming the physical frames.

Explain the behavior of mheap when allocating heap arenas:
- Heap arenas may not be contiguous in process virtual memory space.
- ...

Mention 1 heap allocation optimization is grouping scalar types into a single struct allocation.
See: https://github.com/golang/go/commit/ba7b8ca336123017e43a2ab3310fd4a82122ef9d.

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

== Mention the importace of memory arena between [g.stackguard - StackSmall -> g.stack.lo]