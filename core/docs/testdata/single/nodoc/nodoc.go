package nodoc

func Exported(a int) int { return a }

type Thing struct{ N int }

func (t Thing) Double() int { return t.N * 2 }
