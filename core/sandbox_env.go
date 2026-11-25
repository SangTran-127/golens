package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"os"
	"unsafe"
)

func init() {
	adoptLibcEnv("TMPDIR")
}

func adoptLibcEnv(key string) {
	ck := C.CString(key)
	defer C.free(unsafe.Pointer(ck))
	v := C.getenv(ck)
	if v == nil {
		return
	}
	if s := C.GoString(v); s != "" && s != os.Getenv(key) {
		_ = os.Setenv(key, s)
	}
}
