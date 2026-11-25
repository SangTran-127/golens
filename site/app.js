(() => {
  "use strict";

  const AST_SCENARIOS = [
    {
      id: "concurrency",
      titleVi: "1. Concurrency & Context",
      titleEn: "1. Concurrency & Context",
      rule: "Editor ▸ Inspect ▸ Concurrency & Context (⌃⌥C)",
      screenshot: "./assets/screenshots/concurrency-inspector.png",
      screenshotAltVi: "Cửa sổ Inspect Concurrency & Context Propagation trong GoLens.app",
      screenshotAltEn: "Inspect Concurrency & Context Propagation sheet in GoLens.app",
      issuesCount: 2,
      explainVi: "Phát hiện tạo context.Background() mới bên trong hàm con làm đứt chuỗi huỷ (cancellation) và quên gọi defer cancel() gây rò rỉ tài nguyên.",
      explainEn: "Detects fresh context.Background() calls inside callees that break cancellation propagation and missing defer cancel() leaks.",
      before: `package server

import (
    "context"
    "time"
)

func backgroundPoll(endpoint string) error {
    // Finding 1: Root Context in Function (ignores caller cancellation)
    // Finding 2: Missing defer cancel() (leaks timer & child context)
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)

    return fetchMetrics(ctx, endpoint)
}`,
      after: `package server

import (
    "context"
    "time"
)

func backgroundPoll(parentCtx context.Context, endpoint string) error {
    // Propagates caller context and guarantees cleanup on return
    ctx, cancel := context.WithTimeout(parentCtx, 5*time.Second)
    defer cancel()

    return fetchMetrics(ctx, endpoint)
}`,
      diff: `@@ -8,6 +8,7 @@
-func backgroundPoll(endpoint string) error {
-    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
+func backgroundPoll(parentCtx context.Context, endpoint string) error {
+    ctx, cancel := context.WithTimeout(parentCtx, 5*time.Second)
+    defer cancel()
 
     return fetchMetrics(ctx, endpoint)
 }`
    },
    {
      id: "crypto",
      titleVi: "2. Crypto & Timing Attack",
      titleEn: "2. Crypto & Timing Side-Channel",
      rule: "Editor ▸ Inspect ▸ Crypto & Randomness Safety (⌃⌥;)",
      screenshot: "./assets/screenshots/crypto-inspector.png",
      screenshotAltVi: "Cửa sổ Crypto & Randomness Safety Inspector trong GoLens.app",
      screenshotAltEn: "Crypto & Randomness Safety Inspector sheet in GoLens.app",
      issuesCount: 2,
      explainVi: "So sánh trực tiếp chuỗi token/HMAC bằng == hoặc != làm lộ độ dài và từng byte qua thời gian phản hồi. GoLens tự động viết lại sang subtle.ConstantTimeCompare.",
      explainEn: "Direct == or != comparison on secrets/HMACs leaks byte prefixes via timing side-channels. GoLens rewrites AST nodes to subtle.ConstantTimeCompare.",
      before: `package auth

import "crypto/rand"

func VerifyStoreToken(secretToken, expectedToken string) bool {
    // Timing Side-Channel: byte-by-byte early exit leaks token prefix
    if secretToken == expectedToken {
        return true
    }
    return false
}`,
      after: `package auth

import (
    "crypto/subtle"
)

func VerifyStoreToken(secretToken, expectedToken string) bool {
    // Constant-time comparison prevents timing side-channel leakage
    if subtle.ConstantTimeCompare([]byte(secretToken), []byte(expectedToken)) == 1 {
        return true
    }
    return false
}`,
      diff: `@@ -1,8 +1,9 @@
 package auth
 
-import "crypto/rand"
+import "crypto/subtle"
 
 func VerifyStoreToken(secretToken, expectedToken string) bool {
-    if secretToken == expectedToken {
+    if subtle.ConstantTimeCompare([]byte(secretToken), []byte(expectedToken)) == 1 {
         return true
     }
     return false`
    },
    {
      id: "sql",
      titleVi: "3. SQL & Transaction Safety",
      titleEn: "3. SQL & Transaction Safety",
      rule: "Editor ▸ Inspect ▸ SQL & Transaction Safety",
      screenshot: "./assets/screenshots/api-compatibility.png",
      screenshotAltVi: "Kiểm toán an toàn SQL và tương thích API trong GoLens.app",
      screenshotAltEn: "SQL safety and API compatibility inspection in GoLens.app",
      issuesCount: 2,
      explainVi: "Phát hiện nối chuỗi SQL trực tiếp (SQL Injection) và mở transaction db.BeginTx() nhưng thiếu defer tx.Rollback() khi xảy ra lỗi.",
      explainEn: "Catches string-concatenated SQL queries and transactions missing a deferred tx.Rollback() guard on error paths.",
      before: `package store

import (
    "context"
    "database/sql"
    "fmt"
)

func TransferQuota(ctx context.Context, db *sql.DB, userID string, delta int) error {
    tx, err := db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    // Missing defer tx.Rollback() + SQL string concatenation
    q := fmt.Sprintf("UPDATE quotas SET amount = amount + %d WHERE user_id = '%s'", delta, userID)
    _, err = tx.ExecContext(ctx, q)
    if err != nil {
        return err
    }
    return tx.Commit()
}`,
      after: `package store

import (
    "context"
    "database/sql"
)

func TransferQuota(ctx context.Context, db *sql.DB, userID string, delta int) error {
    tx, err := db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()

    // Parameterized query + guaranteed rollback if Commit is not reached
    _, err = tx.ExecContext(ctx, "UPDATE quotas SET amount = amount + $1 WHERE user_id = $2", delta, userID)
    if err != nil {
        return err
    }
    return tx.Commit()
}`,
      diff: `@@ -10,6 +10,7 @@
     tx, err := db.BeginTx(ctx, nil)
     if err != nil {
         return err
     }
+    defer tx.Rollback()
-    q := fmt.Sprintf("UPDATE quotas SET amount = amount + %d WHERE user_id = '%s'", delta, userID)
-    _, err = tx.ExecContext(ctx, q)
+    _, err = tx.ExecContext(ctx, "UPDATE quotas SET amount = amount + $1 WHERE user_id = $2", delta, userID)`
    },
    {
      id: "tparallel",
      titleVi: "4. Testing Goroutine t.Fatal",
      titleEn: "4. Testing Goroutine t.Fatal",
      rule: "Editor ▸ Inspect ▸ Testing & t.Parallel Safety",
      screenshot: "./assets/screenshots/benchmark-comparison.png",
      screenshotAltVi: "Công cụ kiểm thử và so sánh Benchmark trong GoLens.app",
      screenshotAltEn: "Testing safety and Benchmark comparison in GoLens.app",
      issuesCount: 1,
      explainVi: "Gọi t.Fatal / t.Fatalf bên trong goroutine con sẽ gọi runtime.Goexit() trên goroutine sai và làm treo hoặc panic test runner. GoLens đổi sang t.Errorf kèm return.",
      explainEn: "Calling t.Fatalf inside a non-test goroutine violates testing.T contract. GoLens rewrites it to t.Errorf followed by an explicit return.",
      before: `package store_test

import "testing"

func TestConcurrentReads(t *testing.T) {
    t.Parallel()
    done := make(chan struct{})
    go func() {
        defer close(done)
        if err := pingStore(); err != nil {
            // Illegal t.Fatalf inside child goroutine
            t.Fatalf("unexpected store error: %v", err)
        }
    }()
    <-done
}`,
      after: `package store_test

import "testing"

func TestConcurrentReads(t *testing.T) {
    t.Parallel()
    done := make(chan struct{})
    go func() {
        defer close(done)
        if err := pingStore(); err != nil {
            // Safe error report + explicit return from child goroutine
            t.Errorf("unexpected store error: %v", err)
            return
        }
    }()
    <-done
}`,
      diff: `@@ -9,5 +9,6 @@
         if err := pingStore(); err != nil {
-            t.Fatalf("unexpected store error: %v", err)
+            t.Errorf("unexpected store error: %v", err)
+            return
         }`
    },
    {
      id: "layout",
      titleVi: "5. Struct Memory Padding",
      titleEn: "5. Struct Memory Padding",
      rule: "Editor ▸ Optimize Struct Memory Layout… (⌃⌥L)",
      screenshot: "./assets/screenshots/struct-layout.png",
      screenshotAltVi: "Cửa sổ Struct Memory Layout trong GoLens.app",
      screenshotAltEn: "Struct Memory Layout optimizer sheet in GoLens.app",
      issuesCount: 1,
      explainVi: "Trên kiến trúc 64-bit (arm64/amd64), đặt trường bool (1B) xen giữa các trường 8-byte làm lãng phí 14 byte padding. GoLens sắp xếp lại trường để giảm 33% bộ nhớ.",
      explainEn: "On 64-bit architectures (arm64/amd64), interleaving 1-byte bool fields with 8-byte fields wastes 14 B of padding. GoLens reorders fields to save 33% per allocation.",
      before: `package model

// Current Size: 48 B · Wasted Padding: 14 B (arm64 · 64-bit)
type SessionRecord struct {
    Active    bool   // 1 B + 7 B wasted padding
    SessionID int64  // 8 B (offset +8)
    Admin     bool   // 1 B + 7 B wasted padding
    UserName  string // 16 B (offset +24)
    Verified  bool   // 1 B + 7 B tail padding
}`,
      after: `package model

// Optimized Size: 32 B · Wasted Padding: 5 B (Saved 16 B / 33% per struct)
type SessionRecord struct {
    UserName  string // 16 B (offset +0, align 8)
    SessionID int64  // 8 B  (offset +16, align 8)
    Active    bool   // 1 B  (offset +24, align 1)
    Admin     bool   // 1 B  (offset +25, align 1)
    Verified  bool   // 1 B  (offset +26, align 1)
}`,
      diff: `@@ -3,7 +3,7 @@
 type SessionRecord struct {
+    UserName  string
+    SessionID int64
     Active    bool
-    SessionID int64
     Admin     bool
-    UserName  string
     Verified  bool
 }`
    }
  ];

  const JSON_PRESETS = {
    service: `{
  "service_id": 1042,
  "cluster_url": "https://ap-southeast.golens.dev",
  "http_timeout_ms": 2500,
  "tls_enabled": true,
  "tags": ["production", "arm64"],
  "rate_limit": {
    "requests_per_sec": 500,
    "burst_capacity": 1200
  }
}`,
    user: `{
  "user_uuid": "usr_01J9Z8K4X",
  "full_name": "Sang Tran",
  "email_verified": true,
  "login_count": 42,
  "quota_gb": 128.5
}`,
    webhook: `{
  "event_id": "evt_99812",
  "repo_name": "opla/golens",
  "commit_sha": "8cb103fd",
  "ci_passed": true,
  "duration_sec": 14.2
}`
  };

  const CATALOG_TOOLS = [
    { cat: "safety", badge: "AST Safety", name: "SQL & Query Safety Inspector", shortcut: "Editor ▸ Inspect", vi: "Phát hiện nối chuỗi SQL, thiếu context trong query và gọi Prepare trong vòng lặp.", en: "Detects SQL string concatenation, missing query context, and Prepare inside loops." },
    { cat: "safety", badge: "AST Safety", name: "Concurrency & Context Propagation", shortcut: "⌃⌥C", vi: "Phát hiện context.Background() trong hàm con, thiếu defer cancel() và goroutine không giới hạn.", en: "Detects root context creation in callees, missing defer cancel(), and unbounded goroutines." },
    { cat: "safety", badge: "AST Safety", name: "Crypto & Timing Side-Channel Inspector", shortcut: "⌃⌥;", vi: "Phát hiện MD5/SHA1/DES, math/rand cho bảo mật và so sánh trực tiếp làm lộ timing side-channel.", en: "Flags weak hashes, math/rand PRNG in security contexts, and non-constant-time token comparisons." },
    { cat: "safety", badge: "AST Safety", name: "Channel & Select Deadlock Safety", shortcut: "Editor ▸ Inspect", vi: "Cảnh báo select trên channel nil, rò rỉ unbuffered sender và đóng channel hai lần.", en: "Detects nil channel select hazards, unbuffered sender leaks, and double channel closes." },
    { cat: "safety", badge: "AST Safety", name: "Atomic & Memory Alignment Safety", shortcut: "Editor ▸ Inspect", vi: "Kiểm tra căn chỉnh 64-bit cho sync/atomic, atomic.Value.Store(nil) và lỗi vòng lặp CAS.", en: "Checks 64-bit alignment for sync/atomic, atomic.Value.Store(nil), and broken CAS loops." },
    { cat: "safety", badge: "AST Safety", name: "Path Traversal & Archive Bomb Safety", shortcut: "Editor ▸ Inspect", vi: "Ngăn chặn lỗ hổng Zip Slip, nối đường dẫn bằng dấu / và giải nén không giới hạn bộ nhớ.", en: "Prevents Zip Slip path traversal, raw slash path concatenation, and decompression bombs." },
    { cat: "safety", badge: "AST Safety", name: "CGO & Unsafe Pointer Inspector", shortcut: "Editor ▸ Inspect", vi: "Kiểm tra chuyển đổi unsafe.Pointer sai chuẩn, đột biến SliceHeader và truyền con trỏ Go sang C.", en: "Validates unsafe.Pointer arithmetic rules, slice header mutations, and CGO pointer passing." },
    { cat: "safety", badge: "AST Safety", name: "Error Chain & Sentinel Safety", shortcut: "Editor ▸ Inspect", vi: "Tự động đổi phép so sánh ==/!= trên wrapped error sang errors.Is / errors.As và %w.", en: "Rewrites direct == comparisons on wrapped errors to errors.Is / errors.As and %w formatting." },
    { cat: "safety", badge: "AST Safety", name: "HTTP Response, Cookie & CORS Safety", shortcut: "Editor ▸ Inspect", vi: "Phát hiện thiếu cờ Secure/HttpOnly/SameSite trên Cookie, CORS wildcard kèm credentials và CRLF.", en: "Flags insecure cookies missing HttpOnly/Secure/SameSite, wildcard CORS with credentials, and CRLF." },
    { cat: "safety", badge: "AST Safety", name: "Socket, Dialer & Keep-Alive Safety", shortcut: "Editor ▸ Inspect", vi: "Phát hiện tạo mới http.Client trên mỗi request gây cạn kiệt connection pool và thiếu deadline.", en: "Catches per-request http.Client instantiation, connection pool starvation, and missing net.Conn deadlines." },
    { cat: "safety", badge: "AST Safety", name: "Slice Capacity Aliasing & UTF-8 Slicing", shortcut: "Editor ▸ Inspect", vi: "Cảnh báo append vào sub-slice làm ghi đè mảng gốc và cắt chuỗi giữa ký tự UTF-8 đa byte.", en: "Detects sub-slice append aliasing without full slice expressions and mid-rune byte slicing." },
    { cat: "safety", badge: "AST Safety", name: "SQL Transaction & Rollback Safety", shortcut: "Editor ▸ Inspect", vi: "Đảm bảo mọi db.BeginTx đều có defer tx.Rollback() và không commit transaction đã lỗi.", en: "Ensures every db.BeginTx has a deferred tx.Rollback() guard and prevents committing failed transactions." },
    { cat: "safety", badge: "AST Safety", name: "Hot-Path Allocation & Regex Compilation", shortcut: "Editor ▸ Inspect", vi: "Phát hiện regexp.MustCompile hoặc template.Parse lặp lại bên trong vòng lặp và HTTP handler.", en: "Finds repeated regexp/template compilation inside loops or HTTP handlers and suggests precompilation." },
    { cat: "safety", badge: "AST Safety", name: "Unrecovered Goroutine Panic & Signal Safety", shortcut: "Editor ▸ Inspect", vi: "Phát hiện goroutine thiếu recover() có thể làm sập tiến trình và channel os.Signal không có buffer.", en: "Flags background goroutines without recover() guards and unbuffered os.Signal channels." },
    { cat: "safety", badge: "AST Safety", name: "Package Capabilities Audit (capslock)", shortcut: "⌃⇧⌘S", vi: "Liệt kê đặc quyền nhạy cảm của từng package: NETWORK, EXEC, FILESYSTEM, UNSAFE, REFLECT.", en: "Audits package privilege capabilities: NETWORK, EXEC, FILESYSTEM, UNSAFE, and REFLECT." },
    { cat: "safety", badge: "AST Safety", name: "Package API Compatibility & SemVer Diff", shortcut: "⌃⌥A", vi: "So sánh khai báo Go export với Git HEAD để phát hiện thay đổi làm gãy API và gợi ý SemVer.", en: "Compares exported Go declarations against Git HEAD to detect breaking API changes and SemVer bump." },
    { cat: "generator", badge: "Generator", name: "Implement Interface Stubs", shortcut: "⌃I", vi: "Quét mọi interface trong workspace & thư viện chuẩn Go và sinh đầy đủ method stub còn thiếu.", en: "Scans workspace and Go stdlib interfaces to generate missing method stubs on any struct." },
    { cat: "generator", badge: "Generator", name: "Paste JSON as Go Struct", shortcut: "⌃⌥V", vi: "Suy luận trực tiếp Go struct từ mẫu JSON kèm chuẩn hoá tên viết tắt (ID, URL, HTTP) và json tag.", en: "Infers Go struct definitions from JSON samples with acronym normalization and struct tags." },
    { cat: "generator", badge: "Generator", name: "Modify Struct Tags", shortcut: "⌃⌥T", vi: "Thêm, cập nhật hoặc xoá hàng loạt tag json, yaml, db, xml với snake_case, camelCase và omitempty.", en: "Batch-add, update, or remove json/yaml/db/xml tags with casing transforms and omitempty." },
    { cat: "generator", badge: "Generator", name: "Generate Immutable With / Clone Methods", shortcut: "Editor ▸ Generate", vi: "Sinh các phương thức WithField() bất biến kèm sao chép sâu (deep copy) cho trường slice và map.", en: "Generates immutable WithField() builders with automatic deep copying for slices and maps." },
    { cat: "generator", badge: "Generator", name: "Generate Bounded Worker Pool", shortcut: "Editor ▸ Generate", vi: "Sinh worker pool giới hạn số goroutine, tôn trọng ctx.Done() và không để lọt goroutine mồ côi.", en: "Generates context-aware bounded worker pools that exit cleanly without orphan goroutines." },
    { cat: "generator", badge: "Generator", name: "Generate Retry with Exponential Backoff", shortcut: "Editor ▸ Generate", vi: "Sinh bộ thử lại có jitter, kiểm tra sẵn ctx.Err() trước khi chạy và huỷ tức thì khi hết hạn.", en: "Generates jittered exponential backoff helpers that guard against pre-canceled contexts." },
    { cat: "generator", badge: "Generator", name: "Generate Typed sync.Pool Wrapper", shortcut: "Editor ▸ Generate", vi: "Sinh wrapper sync.Pool định kiểu mạnh (generic/typed) kèm hàm Reset() chống rò rỉ dữ liệu cũ.", en: "Generates strongly-typed sync.Pool wrappers with automatic Reset() methods to prevent data leaks." },
    { cat: "generator", badge: "Generator", name: "Generate Thread-Safe LRU / TTL Cache", shortcut: "Editor ▸ Generate", vi: "Sinh bộ nhớ đệm in-memory an toàn đa luồng với thời hạn TTL, giới hạn dung lượng và eviction callback.", en: "Generates concurrent in-memory LRU/TTL caches with expiration and eviction callbacks." },
    { cat: "generator", badge: "Generator", name: "Generate Circuit Breaker & Rate Limiter", shortcut: "Editor ▸ Generate", vi: "Sinh bộ ngắt mạch (Closed/Open/Half-Open) và bộ giới hạn tốc độ Token Bucket theo context.", en: "Generates thread-safe state-tracked circuit breakers and context-aware token bucket rate limiters." },
    { cat: "generator", badge: "Generator", name: "Generate Singleflight & Batch Processor", shortcut: "Editor ▸ Generate", vi: "Sinh bộ gộp request trùng lặp (Singleflight) và bộ gom lô theo kích thước/thời gian có graceful flush.", en: "Generates concurrent request deduplicators and time/count-bounded batch processors." },
    { cat: "generator", badge: "Generator", name: "Generate Service Lifecycle & Health Probes", shortcut: "Editor ▸ Generate", vi: "Sinh trình điều phối khởi động/tắt dịch vụ theo tín hiệu OS và handler /healthz, /readyz.", en: "Generates graceful startup/shutdown coordinators and /healthz & /readyz HTTP handlers." },
    { cat: "generator", badge: "Generator", name: "Generate Zero-Dependency Interface Mock", shortcut: "⌃⌥M", vi: "Sinh struct Mock kiêm ghi lịch sử lời gọi hàm (Call Spy) thuần Go không cần thư viện ngoài.", en: "Generates pure-Go typed mock structs with call-count and argument spy recording." },
    { cat: "refactor", badge: "Refactor", name: "Change Signature Across Workspace", shortcut: "⌘F6", vi: "Đổi tên hàm, thêm/xoá/đổi thứ tự tham số và kiểu trả về từ cả nơi khai báo lẫn nơi gọi hàm.", en: "Rename functions and add, remove, or reorder parameters/returns from declaration or call site." },
    { cat: "refactor", badge: "Refactor", name: "Move Symbol Across Files", shortcut: "⌃F6", vi: "Di chuyển hàm, struct, interface, var/const sang file khác cùng package (tự tạo file mới nếu cần).", en: "Moves top-level funcs, types, vars, or consts to another file in the package safely." },
    { cat: "refactor", badge: "Refactor", name: "Extract Method & Extract Interface", shortcut: "⌥⌘M", vi: "Tự động phân tích biến đầu vào/đầu ra để tách hàm mới hoặc trích xuất interface từ struct.", en: "Analyzes free/mutated variables to extract functions/methods or derive interfaces from structs." },
    { cat: "refactor", badge: "Refactor", name: "Propagate Method to Interface", shortcut: "⌃⌥P", vi: "Đẩy chữ ký phương thức vừa viết trên struct lên các interface liên quan và tạo stub cho struct khác.", en: "Pushes a struct method signature up to target interfaces and stubs sibling implementations." },
    { cat: "refactor", badge: "Refactor", name: "Optimize Struct Memory Layout", shortcut: "⌃⌥L", vi: "Hiển thị offset từng byte trên arm64/amd64 và sắp xếp lại trường struct để xoá byte padding thừa.", en: "Visualizes byte offsets & padding on arm64/amd64 and reorders struct fields to minimize size." },
    { cat: "refactor", badge: "Refactor", name: "AST-Aware Expand & Shrink Selection", shortcut: "⌃⇧↑ / ⌃⇧↓", vi: "Mở rộng/thu hẹp vùng chọn theo từng nấc cây cú pháp Go: Identifier → Expr → Statement → Func → File.", en: "Expands or shrinks selection semantically along the Go AST from identifier up to file." },
    { cat: "runtime", badge: "Profiler & Debug", name: "CPU & Memory Profiler + Editor Line Heat", shortcut: "⌃⌥⌘P", vi: "Phân tích .pprof, hiển thị Flame Graph và vẽ thanh nhiệt trực tiếp trên lề dòng code tốn tài nguyên.", en: "Captures CPU/Memory profiles, renders Flame Graphs, and overlays Editor Line Heat in the gutter." },
    { cat: "runtime", badge: "Profiler & Debug", name: "Inline Heap Escape Analysis Lenses", shortcut: "Product ▸ Profile", vi: "Hiển thị trực tiếp nhãn ↗ heap ngay trên dòng code có biến bị thoát lên bộ nhớ heap.", en: "Displays inline ↗ heap escape explanations directly on offending source lines in the editor." },
    { cat: "runtime", badge: "Profiler & Debug", name: "Compare Benchmarks with Saved Baseline", shortcut: "⌃⌥B", vi: "So sánh ns/op, B/op, allocs/op với baseline đã lưu và phân loại Faster / Regressed / Unchanged.", en: "Compares ns/op, B/op, and allocs/op against saved baselines with automatic regression verdicts." },
    { cat: "runtime", badge: "Profiler & Debug", name: "Attach Debugger to Local PID or Remote Delve", shortcut: "⌃⌥⌘A", vi: "Gắn trình gỡ lỗi vào tiến trình đang chạy hoặc dlv từ xa, tự động tách an toàn khi nhấn Stop.", en: "Attaches to running local Go processes or remote headless Delve with non-destructive detach." },
    { cat: "runtime", badge: "Profiler & Debug", name: "1-Click GOOS / GOARCH & Build Tag Switcher", shortcut: "Status Bar", vi: "Chuyển nhanh darwin/linux/windows & arm64/amd64 kèm banner giải thích khi file bị loại trừ bởi build tag.", en: "Switches GOOS/GOARCH and build tags from the status bar with 1-click excluded-file recovery." }
  ];

  let currentLang = localStorage.getItem("golens-showcase-lang") || "vi";
  let currentScenarioIdx = 0;
  let currentCodeMode = "before"; // "before" | "after" | "diff"
  let activeCatalogCategory = "all";

  // 1. Language Switching
  function applyLanguage(lang) {
    currentLang = lang;
    try {
      localStorage.setItem("golens-showcase-lang", lang);
    } catch (_) {}
    document.documentElement.lang = lang;

    document.querySelectorAll("[data-vi][data-en]").forEach((el) => {
      const text = lang === "vi" ? el.getAttribute("data-vi") : el.getAttribute("data-en");
      if (text !== null) {
        el.textContent = text;
      }
    });

    document.querySelectorAll("[data-placeholder-vi][data-placeholder-en]").forEach((el) => {
      el.setAttribute(
        "placeholder",
        lang === "vi" ? el.getAttribute("data-placeholder-vi") : el.getAttribute("data-placeholder-en")
      );
    });

    document.querySelectorAll("[data-lang-btn]").forEach((btn) => {
      const isMatch = btn.getAttribute("data-lang-btn") === lang;
      btn.setAttribute("aria-pressed", String(isMatch));
      btn.classList.toggle("is-active", isMatch);
    });

    renderScenarioButtons();
    renderActiveScenario();
    renderCatalog();
  }

  // 2. Two-State Color Scheme Toggle (Modern Web Guidance `dark-mode-toggle`)
  const metaScheme = document.querySelector('meta[name="color-scheme"]');
  const darkMedia = window.matchMedia("(prefers-color-scheme: dark)");

  function getResolvedScheme() {
    const content = metaScheme ? metaScheme.content : "light dark";
    if (content === "dark" || content === "light") {
      return content;
    }
    return darkMedia.matches ? "dark" : "light";
  }

  function updateThemeButtonLabel() {
    const resolved = getResolvedScheme();
    const themeLabel = document.getElementById("theme-btn-label");
    if (themeLabel) {
      themeLabel.setAttribute("data-vi", resolved === "dark" ? "Giao diện Sáng" : "Giao diện Tối");
      themeLabel.setAttribute("data-en", resolved === "dark" ? "Light Theme" : "Dark Theme");
      themeLabel.textContent =
        currentLang === "vi"
          ? themeLabel.getAttribute("data-vi")
          : themeLabel.getAttribute("data-en");
    }
  }

  function toggleColorScheme() {
    const currentlyRendered = getResolvedScheme();
    const targetScheme = currentlyRendered === "dark" ? "light" : "dark";
    const systemScheme = darkMedia.matches ? "dark" : "light";

    if (targetScheme !== systemScheme) {
      try {
        localStorage.setItem("color-scheme", targetScheme);
      } catch (_) {}
      if (metaScheme) metaScheme.content = targetScheme;
    } else {
      try {
        localStorage.removeItem("color-scheme");
      } catch (_) {}
      if (metaScheme) metaScheme.content = "light dark";
    }

    syncHeroWindowPreview(targetScheme);
    updateThemeButtonLabel();
  }

  darkMedia.addEventListener("change", () => {
    updateThemeButtonLabel();
  });

  window.addEventListener("storage", (e) => {
    if (e.key === "color-scheme" && metaScheme) {
      metaScheme.content = e.newValue ?? "light dark";
      updateThemeButtonLabel();
    }
  });

  // 3. Hero Light/Dark Screenshot Switcher
  function syncHeroWindowPreview(mode) {
    const lightImg = document.getElementById("hero-img-light");
    const darkImg = document.getElementById("hero-img-dark");
    if (!lightImg || !darkImg) return;

    const showDark = mode === "dark";
    lightImg.classList.toggle("is-hidden", showDark);
    darkImg.classList.toggle("is-hidden", !showDark);

    document.querySelectorAll("[data-hero-window]").forEach((btn) => {
      const active = btn.getAttribute("data-hero-window") === mode;
      btn.setAttribute("aria-pressed", String(active));
      btn.classList.toggle("is-active", active);
    });
  }

  // 4. Interactive Feature Tabs (Refactoring Section)
  function initFeatureTabs() {
    const tabs = Array.from(document.querySelectorAll(".feature-tab"));
    const panels = Array.from(document.querySelectorAll(".feature-panel"));

    function activateTab(tab) {
      const targetId = tab.getAttribute("aria-controls");
      tabs.forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
      panels.forEach((p) => {
        if (p.id === targetId) {
          p.removeAttribute("hidden");
        } else {
          p.setAttribute("hidden", "");
        }
      });
    }

    tabs.forEach((tab, idx) => {
      tab.addEventListener("click", () => activateTab(tab));
      tab.addEventListener("keydown", (e) => {
        if (e.key === "ArrowDown" || e.key === "ArrowRight") {
          e.preventDefault();
          const next = tabs[(idx + 1) % tabs.length];
          next.focus();
          activateTab(next);
        } else if (e.key === "ArrowUp" || e.key === "ArrowLeft") {
          e.preventDefault();
          const prev = tabs[(idx - 1 + tabs.length) % tabs.length];
          prev.focus();
          activateTab(prev);
        }
      });
    });
  }

  // 5. Interactive AST Safety Auto-Fixer Playground
  function renderScenarioButtons() {
    const container = document.getElementById("ast-scenario-pills");
    if (!container) return;
    container.innerHTML = "";
    AST_SCENARIOS.forEach((sc, idx) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "scenario-btn";
      btn.setAttribute("aria-pressed", String(idx === currentScenarioIdx));
      btn.textContent = currentLang === "vi" ? sc.titleVi : sc.titleEn;
      btn.addEventListener("click", () => {
        currentScenarioIdx = idx;
        currentCodeMode = "before";
        renderScenarioButtons();
        renderActiveScenario();
      });
      container.appendChild(btn);
    });
  }

  function renderActiveScenario() {
    const sc = AST_SCENARIOS[currentScenarioIdx];
    if (!sc) return;

    const ruleEl = document.getElementById("ast-rule-label");
    const badgeEl = document.getElementById("ast-diagnostic-badge");
    const codeEl = document.getElementById("ast-code-display");
    const explainEl = document.getElementById("ast-explain-text");
    const screenshotEl = document.getElementById("ast-inspector-screenshot");
    const applyBtn = document.getElementById("ast-apply-fix-btn");

    if (ruleEl) ruleEl.textContent = sc.rule;
    if (explainEl) {
      explainEl.textContent = currentLang === "vi" ? sc.explainVi : sc.explainEn;
    }
    if (screenshotEl) {
      screenshotEl.src = sc.screenshot;
      screenshotEl.alt = currentLang === "vi" ? sc.screenshotAltVi : sc.screenshotAltEn;
    }

    if (codeEl) {
      if (currentCodeMode === "before") {
        codeEl.textContent = sc.before;
      } else if (currentCodeMode === "after") {
        codeEl.textContent = sc.after;
      } else {
        codeEl.textContent = sc.diff;
      }
    }

    if (badgeEl) {
      const isFixed = currentCodeMode === "after";
      badgeEl.className = `diagnostic-badge ${isFixed ? "is-safe" : "is-warning"}`;
      if (isFixed) {
        badgeEl.textContent =
          currentLang === "vi" ? "0 Cảnh báo · Đã sửa AST" : "0 Findings · AST Verified Safe";
      } else {
        badgeEl.textContent =
          currentLang === "vi"
            ? `${sc.issuesCount} Cảnh báo AST`
            : `${sc.issuesCount} AST Finding(s)`;
      }
    }

    if (applyBtn) {
      const isFixed = currentCodeMode === "after";
      applyBtn.textContent = isFixed
        ? currentLang === "vi"
          ? "Khôi phục code chưa sửa"
          : "Reset to Unfixed Code"
        : currentLang === "vi"
          ? "Apply GoLens AST Fix"
          : "Apply GoLens AST Fix";
    }

    document.querySelectorAll("[data-code-mode]").forEach((btn) => {
      const m = btn.getAttribute("data-code-mode");
      btn.setAttribute("aria-pressed", String(m === currentCodeMode));
      btn.classList.toggle("is-active", m === currentCodeMode);
    });
  }

  // 6. Live JSON -> Go Struct Generator
  const GO_ACRONYMS = new Set([
    "id", "url", "uri", "http", "https", "api", "uuid", "json", "xml",
    "sql", "ip", "tcp", "udp", "tls", "ssl", "cpu", "ram", "os", "io", "db", "sha"
  ]);

  function toPascalCaseGo(key) {
    return key
      .split(/[^a-zA-Z0-9]+/)
      .filter(Boolean)
      .map((part) => {
        const lower = part.toLowerCase();
        if (GO_ACRONYMS.has(lower)) {
          return lower.toUpperCase();
        }
        return lower.charAt(0).toUpperCase() + lower.slice(1);
      })
      .join("") || "Field";
  }

  function formatTagKey(key, casing) {
    const parts = key
      .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
      .split(/[^a-zA-Z0-9]+/)
      .filter(Boolean)
      .map((s) => s.toLowerCase());
    if (parts.length === 0) return key;
    if (casing === "camel") {
      return parts[0] + parts.slice(1).map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join("");
    }
    if (casing === "kebab") {
      return parts.join("-");
    }
    return parts.join("_");
  }

  function inferGoType(val, indent) {
    if (val === null || val === undefined) return "any";
    if (typeof val === "boolean") return "bool";
    if (typeof val === "number") {
      return Number.isInteger(val) ? "int" : "float64";
    }
    if (typeof val === "string") return "string";
    if (Array.isArray(val)) {
      if (val.length === 0) return "[]any";
      return "[]" + inferGoType(val[0], indent);
    }
    if (typeof val === "object") {
      return buildStructBody(val, indent);
    }
    return "any";
  }

  function buildStructBody(obj, indent = "") {
    const tagKind = document.getElementById("json-tag-kind")?.value || "json";
    const tagCase = document.getElementById("json-tag-case")?.value || "snake";
    const omitEmpty = document.getElementById("json-omit-empty")?.checked ?? false;

    const entries = Object.entries(obj);
    if (entries.length === 0) return "struct{}";

    const lines = ["struct {"];
    const innerIndent = indent + "\t";

    for (const [rawKey, value] of entries) {
      const goField = toPascalCaseGo(rawKey);
      const goType = inferGoType(value, innerIndent);
      const formattedKey = formatTagKey(rawKey, tagCase);
      const suffix = omitEmpty ? ",omitempty" : "";
      const tag = `\`${tagKind}:"${formattedKey}${suffix}"\``;
      lines.push(`${innerIndent}${goField.padEnd(14, " ")} ${goType.padEnd(10, " ")} ${tag}`);
    }

    lines.push(`${indent}}`);
    return lines.join("\n");
  }

  function updateJsonStructPreview() {
    const inputEl = document.getElementById("json-input-area");
    const outputEl = document.getElementById("json-struct-output");
    const structNameEl = document.getElementById("json-struct-name");
    if (!inputEl || !outputEl) return;

    const structName = (structNameEl?.value || "Payload").trim() || "Payload";
    try {
      const parsed = JSON.parse(inputEl.value);
      const targetObj = Array.isArray(parsed) ? (parsed[0] || {}) : parsed;
      if (typeof targetObj !== "object" || targetObj === null) {
        outputEl.textContent = "// Please enter a JSON object or array of objects";
        return;
      }
      const body = buildStructBody(targetObj, "");
      outputEl.textContent = `package model\n\n// Generated by GoLens Paste JSON as Go Struct (⌃⌥V)\ntype ${toPascalCaseGo(structName)} ${body}\n`;
    } catch (err) {
      outputEl.textContent = `// Invalid JSON syntax:\n// ${err.message}`;
    }
  }

  // 7. Searchable 72+ Tools Catalog
  function renderCatalog() {
    const grid = document.getElementById("catalog-grid");
    const searchInput = document.getElementById("catalog-search-input");
    const countLabel = document.getElementById("catalog-count-label");
    if (!grid) return;

    const query = (searchInput?.value || "").trim().toLowerCase();
    const filtered = CATALOG_TOOLS.filter((item) => {
      const matchesCat = activeCatalogCategory === "all" || item.cat === activeCatalogCategory;
      if (!matchesCat) return false;
      if (!query) return true;
      const haystack = `${item.name} ${item.vi} ${item.en} ${item.shortcut}`.toLowerCase();
      return haystack.includes(query);
    });

    if (countLabel) {
      countLabel.textContent =
        currentLang === "vi"
          ? `Hiển thị ${filtered.length} / ${CATALOG_TOOLS.length} công cụ nổi bật (trong tổng số 72+ công cụ đã kiểm chứng QA)`
          : `Showing ${filtered.length} of ${CATALOG_TOOLS.length} highlighted tools (from 72+ QA-verified features)`;
    }

    grid.innerHTML = "";
    if (filtered.length === 0) {
      const empty = document.createElement("div");
      empty.className = "catalog-empty";
      empty.textContent =
        currentLang === "vi"
          ? "Không tìm thấy công cụ phù hợp. Hãy thử từ khoá khác (ví dụ: SQL, Context, Pool, pprof)."
          : "No matching tools found. Try another keyword (e.g. SQL, Context, Pool, pprof).";
      grid.appendChild(empty);
      return;
    }

    filtered.forEach((item) => {
      const card = document.createElement("article");
      card.className = "tool-card";
      card.innerHTML = `
        <div class="tool-card-top">
          <span class="tool-badge cat-${item.cat}">${item.badge}</span>
          <span class="kbd-pill">${item.shortcut}</span>
        </div>
        <h4>${item.name}</h4>
        <p>${currentLang === "vi" ? item.vi : item.en}</p>
      `;
      grid.appendChild(card);
    });
  }

  // 8. Lightbox Dialog for Screenshots
  function initLightbox() {
    const dialog = document.getElementById("screenshot-lightbox");
    const dialogImg = document.getElementById("lightbox-img");
    const dialogCaption = document.getElementById("lightbox-caption");
    const closeBtn = document.getElementById("lightbox-close-btn");
    if (!dialog || !dialogImg) return;

    document.querySelectorAll(".zoomable-screenshot").forEach((img) => {
      img.addEventListener("click", () => {
        dialogImg.src = img.src;
        dialogImg.alt = img.alt;
        if (dialogCaption) dialogCaption.textContent = img.alt;
        dialog.showModal();
      });
    });

    closeBtn?.addEventListener("click", () => dialog.close());
    dialog.addEventListener("click", (e) => {
      if (e.target === dialog) dialog.close();
    });
  }

  // Initialize Everything on DOMContentLoaded
  document.addEventListener("DOMContentLoaded", () => {
    // Language buttons
    document.querySelectorAll("[data-lang-btn]").forEach((btn) => {
      btn.addEventListener("click", () => {
        applyLanguage(btn.getAttribute("data-lang-btn") || "vi");
      });
    });

    // Theme button
    document.getElementById("theme-toggle-btn")?.addEventListener("click", toggleColorScheme);

    // Hero window switcher
    document.querySelectorAll("[data-hero-window]").forEach((btn) => {
      btn.addEventListener("click", () => {
        syncHeroWindowPreview(btn.getAttribute("data-hero-window") || "light");
      });
    });

    // AST Playground mode buttons
    document.querySelectorAll("[data-code-mode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        currentCodeMode = btn.getAttribute("data-code-mode") || "before";
        renderActiveScenario();
      });
    });

    document.getElementById("ast-apply-fix-btn")?.addEventListener("click", () => {
      currentCodeMode = currentCodeMode === "after" ? "before" : "after";
      renderActiveScenario();
    });

    // Playground top-level mode switcher (AST Auto-Fixer vs JSON-to-Struct Lab)
    document.querySelectorAll("[data-lab-tab]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const target = btn.getAttribute("data-lab-tab");
        document.querySelectorAll("[data-lab-tab]").forEach((b) => {
          const active = b === btn;
          b.setAttribute("aria-pressed", String(active));
          b.classList.toggle("is-active", active);
        });
        document.getElementById("lab-pane-ast")?.toggleAttribute("hidden", target !== "ast");
        document.getElementById("lab-pane-json")?.toggleAttribute("hidden", target !== "json");
      });
    });

    // JSON Lab events
    ["json-input-area", "json-struct-name", "json-tag-kind", "json-tag-case", "json-omit-empty"].forEach((id) => {
      document.getElementById(id)?.addEventListener("input", updateJsonStructPreview);
      document.getElementById(id)?.addEventListener("change", updateJsonStructPreview);
    });

    document.querySelectorAll("[data-json-preset]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const key = btn.getAttribute("data-json-preset");
        const inputEl = document.getElementById("json-input-area");
        if (inputEl && key && JSON_PRESETS[key]) {
          inputEl.value = JSON_PRESETS[key];
          updateJsonStructPreview();
        }
      });
    });

    document.getElementById("copy-struct-btn")?.addEventListener("click", (e) => {
      const btn = e.currentTarget;
      const code = document.getElementById("json-struct-output")?.textContent || "";
      navigator.clipboard?.writeText(code);
      const orig = btn.textContent;
      btn.textContent = currentLang === "vi" ? "Đã chép Go Struct!" : "Copied Go Struct!";
      setTimeout(() => {
        btn.textContent = orig;
      }, 1600);
    });

    // Catalog filters
    document.querySelectorAll("[data-cat-filter]").forEach((btn) => {
      btn.addEventListener("click", () => {
        activeCatalogCategory = btn.getAttribute("data-cat-filter") || "all";
        document.querySelectorAll("[data-cat-filter]").forEach((b) => {
          const active = b === btn;
          b.setAttribute("aria-pressed", String(active));
          b.classList.toggle("is-active", active);
        });
        renderCatalog();
      });
    });

    document.getElementById("catalog-search-input")?.addEventListener("input", renderCatalog);

    initFeatureTabs();
    initLightbox();
    syncHeroWindowPreview(getResolvedScheme());
    updateThemeButtonLabel();
    applyLanguage(currentLang);
    updateJsonStructPreview();
  });
})();
