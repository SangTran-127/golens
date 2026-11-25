package benchlab

func Dedupe(items []string) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		seen := false
		for _, existing := range out {
			if existing == item {
				seen = true
				break
			}
		}
		if !seen {
			out = append(out, item)
		}
	}
	return out
}
