package analysis

type lastCandidateFixer[C any] struct {
	maxFixes int
	scan     func(src string) ([]C, bool, error)
	fixable  func(c C) bool
	span     func(scanSrc string, c C) (int, int, bool)
	apply    func(src string, c C) (string, bool)
	applied  func(c C)
}

func (f lastCandidateFixer[C]) run(src string) (string, int, error) {
	current := src
	fixed := 0

	cands, ok, firstErr := f.scan(current)
	if !ok {
		return current, 0, firstErr
	}
	scanSrc := current
	idx := len(cands) - 1
	floor := len(current) + 1
	fresh := true

	rescan := func() bool {
		next, ok, _ := f.scan(current)
		if !ok {
			return false
		}
		cands = next
		scanSrc = current
		idx = len(cands) - 1
		floor = len(current) + 1
		fresh = true
		return true
	}

	for fixed < f.maxFixes {
		for idx >= 0 && !f.fixable(cands[idx]) {
			idx--
		}
		if idx < 0 {
			if fresh || !rescan() {
				break
			}
			continue
		}

		cand := cands[idx]
		if !fresh {
			start, end, spanOK := f.span(scanSrc, cand)
			if !spanOK || start < 0 || end > floor {
				if !rescan() {
					break
				}
				continue
			}
		}

		updated, applied := f.apply(current, cand)
		if !applied || updated == current {
			if fresh || !rescan() {
				break
			}
			continue
		}

		if start, _, spanOK := f.span(scanSrc, cand); spanOK && start < floor {
			floor = start
		} else {
			floor = -1
		}
		current = updated
		fixed++
		fresh = false
		idx--
		if f.applied != nil {
			f.applied(cand)
		}
	}
	return current, fixed, nil
}
