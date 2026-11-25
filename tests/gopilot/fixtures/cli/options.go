package main

import "fmt"

type Options struct {
	JSON bool
}

func parseArgs(args []string) (Options, error) {
	var opts Options
	for _, a := range args {
		switch a {
		case "--json":
			opts.JSON = true
		default:
			return opts, fmt.Errorf("unknown argument %q", a)
		}
	}
	return opts, nil
}
