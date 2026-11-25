package main

type Index struct {
	shards [][]byte
}

var index Index

func loadIndex(shards, size int) {
	index = Index{shards: make([][]byte, 0, shards)}
	for i := 0; i < shards; i++ {
		shard := make([]byte, size)
		shard[0] = byte(i)
		index.shards = append(index.shards, shard)
	}
}

func (ix Index) Bytes() int {
	total := 0
	for _, s := range ix.shards {
		total += len(s)
	}
	return total
}
