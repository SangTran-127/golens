package main

import (
	"fmt"
	"io"
	"os"
)

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string, in io.Reader, out io.Writer) error {
	opts, err := parseArgs(args)
	if err != nil {
		return err
	}
	stats, err := Count(in)
	if err != nil {
		return err
	}
	return Render(out, stats, opts.JSON)
}
