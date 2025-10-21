---
layout: post
title: "Garbage Collection in Go"
date: 2025-06-03
---

Sources:
- https://www.sobyte.net/post/2022-04/go-gc/
- https://www.sobyte.net/post/2022-01/go-gc/
- https://www.sobyte.net/post/2021-12/golang-garbage-collector/
- https://groups.google.com/g/golang-nuts/c/eW1weV-FH1w
- https://github.com/golang/proposal/blob/master/design/17503-eliminate-rescan.md

## Terminology

- Mutator: goroutines that allocates and modifies objects.
- Collector: goroutines that performs garbage collection.

## Tri-color Mark-and-Sweep Algorithm

Objects are classified into 3 colors:
- White: Unseen objects, potentially unreachable.
- Gray: Seen objects, but their references have not been fully explored.
- Black: Seen objects, and all their references have been fully explored.

- Initially, all objects are in the white set.
- Add all root objects to the gray set.
- While the gray set is not empty:
  - Pick an object O from the gray set.
  - Remove O from the gray set and move it to the black set.
  - Add all objects that O references and are in the white set to the gray set and remove them from the white set.
- After the marking phase, all objects in the white set are unreachable and can be collected.

### Dijkstra's Insert Write-Barriers

Dijkstra insert write-barrier (strong variance): prevents black→white edges.
Dijkstra write-barrier says: "If I point to something new, make sure it’s marked."
Dijkstra writ-barrier lets concurrent marking start right away, but requires a STW at the end of marking to re-scan stacks.

```
writePointer(object, field, value):
  shade(value) // Make the pointed object gray if it is white.
  object.field = value
```

Consider the following program:
```go
  a := &Object{}
  b := &Object{}

  a.Next = b
```

Timeline without write-barrier:
T1 [mutator] `a` := &Object{} // `a` is white
T2 [mutator] `b` := &Object{} // `b` is white
T3 [collector] add `a` to gray set.
T4 [collector] move `a` from gray set to black set.
T5 [mutator] `a.Next` = `b` // `a` is black, `b` is white
T6 [collector] finish marking phase. `b` is white, so it will be collected.

Timeline with write-barrier:
T1 [mutator] `a` := &Object{} // `a` is white
T2 [mutator] `b` := &Object{} // `b` is white
T3 [collector] add `a` to gray set.
T4 [collector] move `a` from gray set to black set.
T5 [mutator] `a.Next` = `b` // `a` is black, `b` is added to gray set.
T6 [collector] move `b` from gray set to black set.
T7 [collector] finish marking phase. Both `a` and `b` are black, so they will not be collected.

According to https://github.com/golang/proposal/blob/master/design/17503-eliminate-rescan.md, there is a trade-off for pointers on stacks:

1. write to pointers on stack must have write-barrier
2. stack must be rescanned at the end of every GC cycle.

Go chooses the latter, which means that many stacks must be re-scanned during STW.

### Yuasa's Deletion Write-Barriers

RULE: The concurrent and incremental garbage collector operates conservatively, i.e.
it should prefer retaining unused objects rather than reclaiming them prematurely.
Any object that was reachable at the start of the marking phase must not be collected during that phase,
it must remain considered reachable until the end of the marking phase.

Yuasa deletion write-barrier (weak variance): prevent black→white edges without another path that black→gray→white.
Yuasa write-barrier says: “If I stop pointing to something, mark it before I lose it.”
Yuasa deletion write-barrier prevents hanging pointers: https://www.sobyte.net/post/2022-01/go-gc/#missing-marker---hanging-pointer-problem.
Yuasa write-barrier requires a STW at the beginning of marking to either scan or snapshot stacks, but does not require a re-scan at the end of marking.

```
writePointer(object, field, value):
  old_value = object.field
  shade(old_value)
  object.field = value
```

Consider the following program:
```go
a.Next = b
b.Next = c

b.Next = nil
a.Next = c
```

Timeline without write-barrier:
T1 [mutator] `a.Next` = `b` // `a` is white, `b` is white
T2 [mutator] `b.Next` = `c` // `b` is white, `c` is white
T3 [collector] add `a` to gray set
T4 [collector] move `a` from gray set to black set, add `b` to gray set
T5 [mutator] `b.Next` = nil // `b` is grey, `c` is white
T6 [collector] move `b` from gray set to black set, `c` is still white because noone points to it.
T7 [collector] finish marking phase. `c` is white, so it will be collected. <- GC cycle ends here. C is reachable at cycle start but not at cycle end, not satisfying the RULE.
T8 [mutator] `a.Next` = `c` // hanging pointer
T9 [collector] `c` is collected, but `a` points to it.

Timeline with write-barrier:
T1 [mutator] `a.Next` = `b` // `a` is white, `b` is white
T2 [mutator] `b.Next` = `c` // `b` is white, `c` is white
T3 [collector] add `a` to gray set
T4 [collector] move `a` from gray set to black set, add `b` to gray set
T5 [mutator] `b.Next` = nil // `c` is grey
T6 [collector] move `b` and `c` from gray set to black set
T7 [collector] finish marking phase. Both `b` and `c` are black, so they will not be collected. <- GC cycle ends here. C is reachable at both cycle start end cycle end, not satisfying the RULE.

### Go's Hybrid Write-Barriers

Hybrid says: "If I stop pointing to something, mark it before I lose it. If I point to something new, make sure it’s marked if stack has been discovered but not fully scanned (that goroutine may be in the middle of scanning its stack frames)."
The hybrid barrier inherits the best properties of both Yuasa and Dijkstra, allowing stacks to be concurrently scanned at the beginning of the mark phase, while also keeping stacks black after this initial scan.

```
writePointer(object, field, value):
  old_value = object.field
  shade(old_value)
  
  if stack is grey: # stack is in the middle of being scanned.
    shade(value)
 
  object.field = value
```

Hybrid write-barrier prevents rescanning stacks at the end of the marking phase.
Because at that time, stack is scanned and therefore only points to shaded objects.

You may wonder that after a stack is scanned, if a stack points to a new heap allocated object, then that object may be white and unreachable.
However, during marking phase, if an object is allocated, it's automatically added to the gray set, so it won't be collected.
See the code where objects are automatically shaded: https://github.com/golang/go/blob/go1.24.0/src/runtime/malloc.go#L1565-L1571.

But if newly allocated object is automatically added to gray set, then why do we need `shade(value)` in the write-barrier?
Because stack may point to an old object that is not allocated during marking phase, and that object may be white.

===

Explain that Go GC uses tri-color mark-and-sweep algorithm. Also explain what write-barrier is and how it helps the algorithm.
See: https://www.notion.so/nghiant3223/Tri-color-Mark-Sweep-GC-20758cf2502e80d087a2c700988767b2
Mention that write-barrier could slow down the program.
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

Explain write-barrier with this program:
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

Mention the pseudocode of write-barrier:
https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/mbarrier.go#L24-L36
writePointer(slot, ptr):
shade(*slot)
if current stack is grey:
shade(ptr)
*slot = ptr

Mention GOGC, GOMEMLIMIT: https://www.youtube.com/watch?v=07wduWyWx8M