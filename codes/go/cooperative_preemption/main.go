package main

import (
	"fmt"
	"os"
	"runtime"
	"runtime/trace"
	"time"
)

func fibonacci(n int) int {
	if n <= 1 {
		return n
	}
	previous, current := 0, 1
	for i := 2; i <= n; i++ {
		fmt.Printf("Calculating fibonacci for %d, currently at %d\n", n, i)
		previous, current = current, previous+current
	}
	return current
}

func main() {
	file, _ := os.Create("trace.out")
	_ = trace.Start(file)
	defer trace.Stop()

	runtime.GOMAXPROCS(1)

	go fibonacci(1_000_000_000)
	go fibonacci(2_000_000_000)

	time.Sleep(3 * time.Second)
}
