package main

import "fmt"

func main() {
	loadIndex(16, 256*1024)
	fmt.Println(renderRows(1000), index.Bytes())
}
