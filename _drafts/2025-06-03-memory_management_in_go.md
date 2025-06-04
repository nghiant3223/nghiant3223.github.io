---
layout: post
title: "Memory Management in Go"
date: 2025-06-03
---

## Memory Allocation

Mention page table to map virtual pages to physical frames (read "OS Concepts" book).

Mention first-fit, best-fit, and segregated-fit algorithms for memory allocation (read https://www.cs.cmu.edu/afs/cs/academic/class/15213-f09/www/lectures/17-dyn-mem.pdf).

Mention that there is still memory fragmentation in Go, as specified in:
https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/sizeclasses.go#L90-L90

Mention process memory layout: text, data, heap, stack, mmap regions (read "OS Concepts" book and online resource).

Mention RSS and VSZ, how they relate to memory allocation (read "Linux Programming Interface" book).

Mention that `mmap` system call just allocates virtual memory in between process stack and heap, Linux uses demand paging, the physical frame is not allocated until the corresponding page is accessed.
- https://ryanstan.com/linux-demand-paging-anon-memory.html
- https://www.kernel.org/doc/html/v5.16/admin-guide/mm/concepts.html#anonymous-memory
- https://stackoverflow.com/questions/60076669/kernel-virtual-memory-space-and-process-virtual-memory-space

Mention that Go's stack doesn't relate to the process stack, Go's heap doesn't relate to the process heap.
Go's heap is allocated using `mmap` and is managed by the Go runtime. Go's stack and heap live in this mapped memory space.

Read https://www.bytelab.codes/what-is-memory-part-3-registers-stacks-and-threads
In stack section, mention %rsp register (if it's relevant to the discussion).

## Garbage Collection

Sources:
- https://www.sobyte.net/post/2022-04/go-gc/

Explain that Go GC uses tri-color mark-and-sweep algorithm. Also explain what write barrier is and how it helps the algorithm.
See: https://www.notion.so/nghiant3223/Tri-color-Mark-Sweep-GC-20758cf2502e80d087a2c700988767b2
Mention that write barrier could slow down the program.
See: https://ihagopian.com/posts/write-barriers-in-the-go-garbage-collector

Explain why there are 3 colors in tri-color mark-and-sweep algorithm: white, gray, and black.
See: https://blog.stackademic.com/basics-of-golang-gc-explained-tri-color-mark-and-sweep-and-stop-the-world-cc832f99164c.

Explain what STW and why it is needed in Go's GC. Also explain why it is not a problem for Go's GC.
See: https://blog.stackademic.com/basics-of-golang-gc-explained-tri-color-mark-and-sweep-and-stop-the-world-cc832f99164c.
See: https://www.notion.so/nghiant3223/Garbage-Collector-f5f230cdb1c74db2a1bf94642bfc845a?source=copy_link#d73a04097616425b8d875955af613df4

In GC section, mentions that if a goroutine is allocating too much memory, it will be used to assist the GC with mark phase.
https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/malloc.go#L1675-L1680.

Mention that GC's sweep phase happens when goroutines is allocating more memory, as specified in:
https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/mheap.go#L968-L968

Sweeping is fast because Go keeps track of unused by bitmap.
That's why the problem with Go's GC is not the speed of sweeping, but the speed of marking phase.

Mention that sweepgen increases by 2 every GC cycle.
https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/mgc.go#L1684-L1684
https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/mheap.go#L474-L480

Explain write barrier with this program:
```go
package main

type Node struct {
	ID     int
	Parent *Node
}

func New() *Node {
	child := &Node{}
	parent := &Node{}
	child.Parent = parent
	return child
}

func main() {
	New()
}
```

```shell
$ go build -gcflags="all=-l" -o main main.go
$ go tool objdump -s "main.New" main
TEXT main.New(SB) /Users/toninguyen/Workspace/go_playground/runtime/main.go
  main.go:8		0x100066b40		f9400b90		MOVD 16(R28), R16
  main.go:8		0x100066b44		eb3063ff		CMP R16, RSP
  main.go:8		0x100066b48		54000349		BLS 26(PC)
  main.go:8		0x100066b4c		f81d0ffe		MOVD.W R30, -48(RSP)
  main.go:8		0x100066b50		f81f83fd		MOVD R29, -8(RSP)
  main.go:8		0x100066b54		d10023fd		SUB $8, RSP, R29
  main.go:9		0x100066b58		900000c0		ADRP 98304(PC), R0
  main.go:9		0x100066b5c		91080000		ADD $512, R0, R0
  main.go:9		0x100066b60		97fe915c		CALL runtime.newobject(SB)
  main.go:9		0x100066b64		f90013e0		MOVD R0, 32(RSP)
  main.go:10		0x100066b68		900000c0		ADRP 98304(PC), R0
  main.go:10		0x100066b6c		91080000		ADD $512, R0, R0
  main.go:10		0x100066b70		97fe9158		CALL runtime.newobject(SB)
  main.go:11		0x100066b74		9000051b		ADRP 655360(PC), R27
  main.go:11		0x100066b78		b941b361		MOVWU 432(R27), R1
  main.go:11		0x100066b7c		35000061		CBNZW R1, 3(PC)
  main.go:11		0x100066b80		f94013e1		MOVD 32(RSP), R1
  main.go:11		0x100066b84		14000006		JMP 6(PC)
  main.go:11		0x100066b88		97fff546		CALL runtime.gcWriteBarrier2(SB)
  main.go:11		0x100066b8c		f9000320		MOVD R0, (R25)
  main.go:11		0x100066b90		f94013e1		MOVD 32(RSP), R1
  main.go:11		0x100066b94		f9400422		MOVD 8(R1), R2
  main.go:11		0x100066b98		f9000722		MOVD R2, 8(R25)
  main.go:11		0x100066b9c		f9000420		MOVD R0, 8(R1)
  main.go:12		0x100066ba0		aa0103e0		MOVD R1, R0
  main.go:12		0x100066ba4		a97ffbfd		LDP -8(RSP), (R29, R30)
  main.go:12		0x100066ba8		9100c3ff		ADD $48, RSP, RSP
  main.go:12		0x100066bac		d65f03c0		RET
  main.go:8		0x100066bb0		aa1e03e3		MOVD R30, R3
  main.go:8		0x100066bb4		97ffecaf		CALL runtime.morestack_noctxt.abi0(SB)
  main.go:8		0x100066bb8		17ffffe2		JMP main.New(SB)
  main.go:8		0x100066bbc		00000000		?
```

Mention the pseudocode of write barrier:
https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/mbarrier.go#L24-L36
writePointer(slot, ptr):
  shade(*slot)
  if current stack is grey:
    shade(ptr)
  *slot = ptr
