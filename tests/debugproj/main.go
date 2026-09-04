// A small program for the debugger tests: a function called in a loop with
// a local that changes, a goroutine, a line on stderr and a non-zero exit.
package main

import (
	"fmt"
	"os"
	"time"
)

func accumulate(items []int) int {
	total := 0
	for i, n := range items {
		total += n * (i + 1)
	}
	return total
}

func worker(done chan<- int) {
	time.Sleep(10 * time.Millisecond)
	done <- 7
}

func main() {
	fmt.Println("debugproj: start")
	done := make(chan int)
	go worker(done)
	sum := accumulate([]int{1, 2, 3})
	fmt.Println("sum", sum, "worker", <-done)
	fmt.Fprintln(os.Stderr, "debugproj: stderr line")
	if len(os.Args) > 1 && os.Args[1] == "sleep" {
		time.Sleep(10 * time.Second)
	}
	os.Exit(3)
}
