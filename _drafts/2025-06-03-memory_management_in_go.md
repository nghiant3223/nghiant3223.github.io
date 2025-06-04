---
layout: post
title: "Memory Allocation and Garbage Collection in Go"
date: 2025-06-03
---

Mention page table to map virtual pages to physical frames (read "OS Concepts" book).

Mention first-fit, best-fit, and segregated-fit algorithms for memory allocation (read https://www.cs.cmu.edu/afs/cs/academic/class/15213-f09/www/lectures/17-dyn-mem.pdf).

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

In GC section, mentions that if a goroutine is allocating to much memory, it will be used to assist the GC with mark phase.
https://github.com/golang/go/blob/3901409b5d0fb7c85a3e6730a59943cc93b2835c/src/runtime/malloc.go#L1675-L1680.

