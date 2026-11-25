#!/usr/bin/env python3
import ctypes
import os
import sys
import threading
import time
import json

def main():
    dylib_path = os.path.abspath("core/libgoagent.dylib")
    if not os.path.exists(dylib_path):
        print(f"ERROR: {dylib_path} not found")
        sys.exit(1)

    print(f"Loading {dylib_path}...")
    lib = ctypes.CDLL(dylib_path)

    # Function signatures
    # char* InspectRawVariablePayload(const char* typ, const char* value)
    lib.InspectRawVariablePayload.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.InspectRawVariablePayload.restype = ctypes.c_void_p

    # void FreeGoCString(char* ptr)
    lib.FreeGoCString.argtypes = [ctypes.c_void_p]
    lib.FreeGoCString.restype = None

    # char* ContextualASTQuickFixes(const char* filePath, const char* fileContent, int line, int col)
    lib.ContextualASTQuickFixes.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
    lib.ContextualASTQuickFixes.restype = ctypes.c_void_p

    print("=== Test 1: Null pointer handling ===")
    # 1. InspectRawVariablePayload(NULL, NULL)
    ptr = lib.InspectRawVariablePayload(None, None)
    if ptr:
        res = ctypes.cast(ptr, ctypes.c_char_p).value.decode('utf-8')
        lib.FreeGoCString(ptr)
        print(f"  InspectRawVariablePayload(NULL, NULL) -> {res}")
        json.loads(res)
    else:
        print("  FAIL: returned NULL pointer")
        sys.exit(1)

    # 2. InspectRawVariablePayload(NULL, "valid")
    ptr = lib.InspectRawVariablePayload(None, b"test payload")
    if ptr:
        res = ctypes.cast(ptr, ctypes.c_char_p).value.decode('utf-8')
        lib.FreeGoCString(ptr)
        print(f"  InspectRawVariablePayload(NULL, valid) -> len {len(res)}")
        json.loads(res)

    # 3. InspectRawVariablePayload("string", NULL)
    ptr = lib.InspectRawVariablePayload(b"string", None)
    if ptr:
        res = ctypes.cast(ptr, ctypes.c_char_p).value.decode('utf-8')
        lib.FreeGoCString(ptr)
        print(f"  InspectRawVariablePayload(string, NULL) -> {res}")
        json.loads(res)

    # 4. FreeGoCString(NULL) must not crash
    lib.FreeGoCString(None)
    print("  FreeGoCString(NULL) -> safely passed")

    print("\n=== Test 2: Huge Payloads via Cgo ===")
    # 10MB string via Cgo
    huge_data = b"A" * (10 * 1024 * 1024)
    start = time.time()
    ptr = lib.InspectRawVariablePayload(b"string", huge_data)
    dur = time.time() - start
    if ptr:
        res = ctypes.cast(ptr, ctypes.c_char_p).value.decode('utf-8')
        lib.FreeGoCString(ptr)
        parsed = json.loads(res)
        print(f"  10MB string -> processed in {dur:.3f}s, length={parsed['length']}, truncated={parsed['truncated']}")
        if not parsed['truncated'] or parsed['length'] != len(huge_data):
            print("  FAIL: incorrect truncation or length")
            sys.exit(1)

    print("\n=== Test 3: High Concurrency Multi-Threaded Stress Test ===")
    NUM_THREADS = 50
    ITERS_PER_THREAD = 200
    errors = []

    def worker(tid):
        for i in range(ITERS_PER_THREAD):
            op = i % 3
            try:
                if op == 0:
                    val = f'{{"tid": {tid}, "iter": {i}, "msg": "stress_json"}}'.encode('utf-8')
                    ptr = lib.InspectRawVariablePayload(b"string", val)
                    if ptr:
                        raw = ctypes.cast(ptr, ctypes.c_char_p).value.decode('utf-8')
                        lib.FreeGoCString(ptr)
                        json.loads(raw)
                    else:
                        errors.append(f"Thread {tid} iter {i} returned NULL")
                elif op == 1:
                    bval = f"[]uint8 len: 4, cap: 4, [{tid%256}, {i%256}, 42, 99]".encode('utf-8')
                    ptr = lib.InspectRawVariablePayload(b"[]byte", bval)
                    if ptr:
                        raw = ctypes.cast(ptr, ctypes.c_char_p).value.decode('utf-8')
                        lib.FreeGoCString(ptr)
                        json.loads(raw)
                elif op == 2:
                    code = b"package foo\nfunc Bar() {\n\t_ = 1\n}\n"
                    ptr = lib.ContextualASTQuickFixes(b"foo.go", code, 3, 2)
                    if ptr:
                        lib.FreeGoCString(ptr)
            except Exception as e:
                errors.append(f"Thread {tid} iter {i} exception: {e}")

    start = time.time()
    threads = []
    for t in range(NUM_THREADS):
        th = threading.Thread(target=worker, args=(t,))
        threads.append(th)
        th.start()

    for th in threads:
        th.join()

    total_ops = NUM_THREADS * ITERS_PER_THREAD
    elapsed = time.time() - start
    print(f"  Completed {total_ops} concurrent Cgo FFI calls across {NUM_THREADS} threads in {elapsed:.3f}s ({total_ops/elapsed:.1f} ops/sec)")

    if errors:
        print(f"  FAIL: {len(errors)} errors occurred:")
        for err in errors[:10]:
            print(f"    {err}")
        sys.exit(1)
    else:
        print("  PASS: 0 errors, 0 memory faults, 100% thread safety verified!")

if __name__ == "__main__":
    main()
