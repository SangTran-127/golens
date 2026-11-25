# GoLens Go IDE — Cẩm Nang Tính Năng (User Guide)

Tài liệu này mô tả chi tiết toàn bộ các tính năng của **GoLens** (Native macOS IDE cho Go — SwiftUI/AppKit frontend + Go CGO backend), cách kích hoạt qua menu, phím tắt, thanh công cụ và kết quả kiểm chứng hành trình người dùng liên tục (`scripts/smoke/dogfood-journey.sh` — **15/15 PASS**).

---

## 1. Soạn Thảo Thông Minh & Điều Hướng AST

### 1.1. Mở Rộng / Thu Hẹp Vùng Chọn Theo Cú Pháp Go (`Expand / Shrink Selection`)
- **Công dụng**: Mở rộng vùng chọn từng bước theo cây cú pháp Go (`AST`):
  `Identifier` → `Field / Selector / CallExpr` → `Statement` → `Block {...}` → `FuncDecl / TypeSpec` → `File`.
- **Cách kích hoạt**:
  - **Menu**: `Edit ▸ Expand Selection` (`⌃⇧↑`) / `Edit ▸ Shrink Selection` (`⌃⇧↓`)
  - **Menu chuột phải trong Editor**: `Expand Selection` / `Shrink Selection`

### 1.1b. Nhiều Con Trỏ Và Chọn Theo Cột (`Multiple Cursors`)
- **Công dụng**: Gõ, xóa, xuống dòng, di chuyển, copy và paste ở nhiều vị trí cùng lúc. Undo một lần hoàn tác cả lượt gõ và trả lại các con trỏ.
- **Cách kích hoạt**:
  - **Menu**: `Edit ▸ Add Cursor Above` (`⌥⌘↑`) / `Edit ▸ Add Cursor Below` (`⌥⌘↓`)
  - **Chuột**: `⌥`-click (hoặc `⌃⇧`-click như Xcode) để thêm một con trỏ, click lại vào con trỏ đó để bỏ; `⌥`-kéo để chọn theo cột
  - **Theo từ**: `Find ▸ Select Next Occurrence` (`⌥⌘E`) thêm lần xuất hiện kế tiếp của vùng đang chọn
  - **Thoát**: `Esc` hoặc click thường để trở về một con trỏ
- **Lưu ý**: Gợi ý code và gợi ý AI tạm tắt khi đang có nhiều con trỏ. Lưu file có Format on Save sẽ trở về một con trỏ.

### 1.2. Điều Hướng Lùi / Tiến Chính Xác Từng Dòng & Cột (`Caret-Level Back / Forward`)
- **Công dụng**: Lưu lịch sử vị trí con trỏ `(file, line, column)` mỗi khi nhảy qua `Go to Definition`, `Go to Symbol in File…` (`⌃6`), `Go to Implementation` (`⌃⌘I`), hoặc `Call Hierarchy` (`⌃⌥H`), kể cả khi nhảy trong cùng một file.
- **Cách kích hoạt**:
  - **Menu**: `Navigate ▸ Back` (`⌘[`) / `Navigate ▸ Forward` (`⌘]`)

### 1.3. Cây Phân Cấp Lời Gọi & Kiểu (`Call Hierarchy` & `Type Hierarchy`)
- **Công dụng**: Xem danh sách hàm gọi tới (`Callers`) và hàm được gọi (`Callees`), hoặc các `interface` / `struct` liên quan (`Supertypes` / `Subtypes`).
- **Cách kích hoạt**:
  - **Menu**: `Navigate ▸ Call Hierarchy` (`⌃⌥H`) / `Navigate ▸ Type Hierarchy` (`⌃H`)
  - **Inline Code Lens**: Click trực tiếp vào nhãn `N usages` hoặc `implements N interfaces` ngay bên cạnh khai báo hàm/struct.

### 1.4. Nhảy Tới Lỗi Kế Tiếp / Trước Đó (`Next Issue` / `Previous Issue`)
- **Công dụng**: Đưa con trỏ tới dòng có lỗi hoặc cảnh báo kế tiếp (hoặc trước đó) trong file đang mở, theo thứ tự trong file, quay vòng khi tới cuối/đầu file, và mở popup mô tả lỗi của dòng đó. File không có lỗi nào thì GoLens báo "No issues in this file." thay vì im lặng. Trong popup, `Return` áp dụng quick fix đầu tiên. Phím bấm trước khi nút quick fix hiện ra, hoặc trong khoảnh khắc ngay sau đó, bị bỏ qua. Vì vậy một lần gõ vội không thể sửa code khi bạn chưa kịp đọc quick fix.
- **Cách kích hoạt**:
  - **Menu**: `Navigate ▸ Next Issue` (`⌘'`) / `Navigate ▸ Previous Issue` (`⇧⌘'`)
  - **Keymap GoLand**: `F2` / `⇧F2`; **Keymap VS Code**: `F8` / `⇧F8`

### 1.5. Live Template Do Bạn Định Nghĩa (`Live Templates`)
- **Công dụng**: Gõ tắt (abbreviation) trong file Go rồi chọn mục có nhãn `Template` trong danh sách gợi ý để chèn cả đoạn code, có các điểm dừng Tab (`$1`, `${2:default}`, `$0`) và biến `$TM_SELECTED_TEXT` (đoạn đang chọn). Đoạn chèn được thụt lề theo dòng con trỏ và Undo một lần là gỡ toàn bộ.
- **Template có sẵn** (không trùng snippet của gopls): `forr` (vòng `range`), `errw` (trả lỗi có bọc ngữ cảnh), `tfn` (test dạng bảng), `prl` (log một giá trị kèm tên). Có thể sửa, tắt, và khôi phục mặc định.
- **Cách kích hoạt**:
  - **Trong editor**: gõ abbreviation, chọn dòng `Template` trong danh sách gợi ý (Tab hoặc Return tuỳ cài đặt), rồi Tab qua từng điểm dừng
  - **Quản lý**: `Settings ▸ Editing ▸ Live Templates` — bật/tắt, `Add…`, `Edit…`, `Duplicate`, `Delete…` (template của bạn), `Restore Defaults…`

### 1.6. Bọc Code (`Surround With…`)
- **Công dụng**: Chọn các dòng (hoặc một biểu thức) trong file Go rồi bọc chúng bằng `if`, `for`, `func() { }()`, `go func() { }()`, `defer func() { }()`, cặp ngoặc `( )`, hoặc bất kỳ live template nào có dùng `$TM_SELECTED_TEXT`. Các dòng được thụt lề lại bên trong, con trỏ nằm ở điểm dừng đầu tiên (ví dụ `condition`), kết quả đúng chuẩn gofmt và Undo một lần là trở lại như cũ. Không chọn gì thì GoLens bọc dòng hiện tại.
- **Cách kích hoạt**:
  - **Menu**: `Editor ▸ Surround With…` (keymap GoLand `⌥⌘T`)
  - **Menu chuột phải trong Editor** (khi có vùng chọn trong file Go): `Surround With…`
  - Trong danh sách: gõ để lọc, ↑↓ để chọn, Return để bọc, Esc để đóng và quay lại editor

### 1.7. Xem Tham Số Của Hàm (`Parameter Info`)
- **Công dụng**: Hiện chữ ký của hàm đang gọi và tô đậm tham số tại con trỏ. Popup tự mở khi gõ `(` hoặc `,`. Khi popup đang mở, di chuyển con trỏ sẽ cập nhật tham số được tô đậm, kể cả khi lời gọi trải trên nhiều dòng. Popup tự đóng khi con trỏ ra khỏi lời gọi, khi gõ `)`, hoặc khi bấm Esc.
- **Cách kích hoạt**:
  - **Menu**: `View ▸ Parameter Info` (`⇧⌘Space`; keymap GoLand `⌘P`), dùng được ở bất kỳ đâu bên trong lời gọi hàm
  - **Command Palette (`⇧⌘P`)**: `Parameter Info`

### 1.8. Hoàn Thành Câu Lệnh (`Complete Current Statement`)
- **Công dụng**: Hoàn tất dòng đang gõ rồi đưa con trỏ tới chỗ gõ tiếp, như GoLand. GoLens đóng chuỗi và ngoặc còn mở, ví dụ `fmt.Println("a` thành `fmt.Println("a")`. Sau `if`, `for`, `switch`, `select`, `else`, `func`, `struct` hoặc `interface`, GoLens thêm ` { }` và đặt con trỏ bên trong khối. `go func()` và `defer func()` có thêm `()` ở cuối. Sau `case` hoặc `default`, GoLens thêm dấu `:`. Với các dòng khác, GoLens mở một dòng mới bên dưới, giữ nguyên thụt lề. Con trỏ ở đâu trên dòng cũng được, và Undo một lần là trở lại như cũ.
- **Cách kích hoạt**:
  - **Menu**: `Editor ▸ Complete Current Statement` (`⌥⌘↩`; keymap GoLand `⇧⌘↩`, khi đó `Submit Changes` của Database chuyển sang `⌥⌘↩`)
  - **Command Palette (`⇧⌘P`)**: `Complete Current Statement`

### 1.9. Nối Dòng, Di Chuyển Dòng Và Câu Lệnh (`Join Lines`, `Move Line`, `Move Statement`)
- **Join Lines** (`⌃⇧J`; keymap VS Code `⌃J`): nối dòng dưới vào dòng đang đặt con trỏ, hoặc nối mọi dòng trong vùng chọn. GoLens bỏ thụt lề của dòng dưới và chèn đúng một dấu cách, trừ sau `(`, `[`, `.` và trước `)`, `]`, `,`. Hai dòng comment `//` liền nhau được gộp thành một comment. Con trỏ nằm ở chỗ vừa nối.
- **Move Line Up / Down** (`⌥↑` / `⌥↓`; keymap GoLand `⌥⇧↑` / `⌥⇧↓`): đổi chỗ các dòng đang chọn với dòng trên hoặc dưới, dùng được trong mọi loại file.
- **Move Statement Up / Down** (`⌥⌘[` / `⌥⌘]`; keymap GoLand `⇧⌘↑` / `⇧⌘↓`; chỉ file Go): di chuyển cả câu lệnh. Trên dòng `if ... {`, cả khối đi theo; trên `} else {`, cả chuỗi if/else đi theo; một hàm đi cùng doc comment của nó; một lời gọi trải nhiều dòng đi như một câu lệnh. Câu lệnh nhảy qua nguyên khối bên cạnh và dừng ở `{` hoặc `}` của khối bao ngoài; khi đó GoLens báo lý do, và Move Line vẫn dùng được để đưa dòng ra ngoài khối.
- **Tiếp comment khi Enter** (file Go): nhấn Enter giữa một dòng `// ...` đưa phần sau con trỏ xuống dòng mới, bắt đầu bằng `// ` và cùng thụt lề. Enter ở cuối một dòng comment mà dòng dưới cũng là comment cũng thêm `// `. Enter ở cuối dòng comment cuối cùng, hoặc trong chỉ thị như `//go:build`, chỉ xuống dòng bình thường.
- Mỗi lệnh là một bước Undo mang tên lệnh, ví dụ "Undo Move Statement Up".
- **Cách kích hoạt**: menu `Edit`, hoặc gõ tên lệnh trong Command Palette (`⇧⌘P`). Khi con trỏ đang ở ô Find hay ô nhập khác, các phím này giữ nguyên tác dụng của ô đó.

### 1.10. Xem Nhanh Định Nghĩa (`Quick Definition`)
- **Quick Definition** (`⌥Space`; keymap VS Code `⌥F12`; chỉ file Go): đặt con trỏ lên một symbol rồi bấm lệnh, popup hiện tên file, số dòng và mã nguồn của định nghĩa ngay tại chỗ: doc comment phía trên, rồi cả khai báo (cả thân hàm, cả struct). Không cần rời file đang sửa.
- Nếu file chứa định nghĩa đang mở trong tab, popup lấy nội dung chưa lưu của tab. Định nghĩa dài hơn 40 dòng chỉ hiện 40 dòng đầu.
- Return hoặc **Open Source** mở định nghĩa trong editor (`Navigate ▸ Back` quay lại). Esc đóng popup và trả con trỏ, vùng chọn, vị trí cuộn về như cũ.
- **Cách kích hoạt**: menu `View`, menu chuột phải `Navigate`, hoặc gõ "Quick Definition" trong Command Palette.

### 1.11. Đổi Tên Ngay Trong Editor (`Rename Symbol…`)
- **Rename Symbol…** (`F2`; keymap GoLand `⇧F6`; chỉ file Go): đặt con trỏ lên tên một hàm, kiểu, biến hay field rồi bấm lệnh. Tên được chọn ngay trong editor, mọi chỗ dùng nó trong file được tô sáng, một ô gợi ý nhỏ dưới dòng cho biết số chỗ dùng.
- Gõ tên mới: mọi chỗ dùng trong file đổi theo ngay khi gõ. Chỉ gõ được chữ, số và `_`; tên bắt đầu bằng số hoặc trùng từ khoá Go bị từ chối kèm lý do.
- **Return** đổi tên ở mọi nơi trong workspace qua gopls, kể cả các file khác. Mỗi file là một bước Undo tên "Rename"; file đang mở được sửa trong tab, chưa tự lưu.
- **Esc** hoặc `⌘Z` khi đang đổi tên: huỷ, tên và vùng chọn trở lại như cũ. Đưa con trỏ ra khỏi tên, bấm chỗ khác hoặc đổi file thì việc đổi tên được hoàn tất.
- Nếu gopls không đổi tên được (ví dụ symbol của thư viện chuẩn, hoặc tên mới trùng một tên đã có), ô gợi ý nói lý do và giữ nguyên tên đang gõ để bạn sửa lại hoặc bấm Esc.
- **Cách kích hoạt**: menu `Editor ▸ Refactor`, menu chuột phải, hoặc gõ "Rename" trong Command Palette.

---

## 2. Tái Cấu Trúc Đa File & Sinh Code Go Tự Động

### 2.1. Thực Thi Interface Tự Động (`Implement Interface…`)
- **Công dụng**: Quét toàn bộ `interface` trong workspace và thư viện chuẩn Go (`io.Reader`, `io.Writer`, `io.Closer`, `fmt.Stringer`, `error`, `sort.Interface`, `http.Handler`, `json.Marshaler`, `context.Context`, ...) và sinh các method stub còn thiếu cho `struct` tại con trỏ.
- **Cách kích hoạt**:
  - **Menu**: `Editor ▸ Implement Interface…` (`⌃I`)
  - **Menu chuột phải trong Editor**: `Generate ▸ Implement Interface…`
  - **Command Palette (`⇧⌘P`)**: `Implement Interface…`

### 2.2. Di Chuyển Hàm / Struct Sang File Hoặc Package Khác (`Move Symbol…`)
- **Công dụng**: Di chuyển một khai báo cấp cao (`func`, `type`, `var`, `const`) từ file hiện tại sang một file `.go` khác trong cùng package (tự động tạo file mới kèm `package <name>` nếu file đích chưa tồn tại).
- **Cách kích hoạt**:
  - **Sang package khác**: trong ô Destination, nhập đường dẫn tính từ gốc project, ví dụ `internal/store/store.go` (hoặc chỉ thư mục `internal/store`). GoLens chuyển khai báo (kiểu thì kèm mọi method), thêm tiền tố package ở mọi nơi dùng, và thêm/bỏ import ở từng file. Package đích chưa có thì được tạo mới.
  - **Khi bị từ chối**: GoLens nêu lý do và không sửa gì, ví dụ khai báo dùng tên chưa export của package cũ, package đích đã có tên trùng, hoặc việc chuyển sẽ tạo vòng import.
  - **Menu**: `Editor ▸ Move Symbol…` (`⌃F6`)
  - **Menu chuột phải trong Editor**: `Refactor ▸ Move Symbol…`
  - **Command Palette (`⇧⌘P`)**: `Move Symbol…`

### 2.3. Đổi Chữ Ký Hàm Toàn Dự Án (`Change Signature…`)
- **Công dụng**: Đổi tên hàm, thêm/xoá/đổi thứ tự tham số (kèm giá trị mặc định cho các nơi gọi hàm hiện có), hoặc đổi kiểu trả về — cập nhật đồng bộ trên toàn bộ các file trong package và workspace. Hỗ trợ gọi trực tiếp tại cả dòng khai báo `func` lẫn tại **vị trí gọi hàm (`CallExpr`)** (tự động phân giải hàm được gọi kể cả khi nằm ở file khác trong package/module).
- **Cách kích hoạt**:
  - **Menu**: `Editor ▸ Change Signature…` (`⌘F6`)
  - **Menu chuột phải trong Editor**: `Refactor ▸ Change Signature…`
  - **Command Palette (`⇧⌘P`)**: `Change Signature…`

### 2.4. Bộ Sinh Code Go (`Generate Constructor`, `Extract Interface`) & Split Editor Độc Lập
- **Cách kích hoạt Bộ Sinh Code Go**:
  - **Menu**: `Editor ▸ Generate Constructor`, `Editor ▸ Extract Interface`
  - **Menu chuột phải trong Editor**: `Generate ▸ Generate Constructor`, `Refactor ▸ Extract Interface`
- **Split Editor Độc Lập (`Split Editor Right`)**:
  - Bấm biểu tượng **`Split Editor Right`** ở góc phải thanh tab, hoặc mở **`Open Quickly…` (`⇧⌘O`)** rồi nhấn **`⌥Return`** (hoặc bấm nút **`Open in Split Editor`** trên dòng kết quả / chuột phải vào file ở Sidebar chọn **`Open in Split Editor`**) để mở một file thứ hai ở khung bên phải kèm thanh tiêu đề hiển thị tên file độc lập mà không làm thay đổi file đang mở ở khung bên trái.

---

## 3. Build Target, Kiểm Thử, Fuzzing & Profiling

### 3.1. Chuyển Đổi Hệ Điều Hành / Kiến Trúc & Build Tags (`Build Target`)
- **Công dụng**: Chuyển đổi `GOOS` (`darwin`, `linux`, `windows`), `GOARCH` (`arm64`, `amd64`), và `-tags` trực tiếp từ thanh trạng thái dưới cùng. Khi file đang mở bị loại trừ bởi build tag hoặc tên file, GoLens hiện banner giải thích rõ lý do kèm nút **`Reset Build Target`** một chạm.
- **Cách kích hoạt**:
  - Click vào nút **`<GOOS>/<GOARCH>`** dưới thanh trạng thái hoặc chọn `Product ▸ Build Target…`.

### 3.2. Tự Động Phát Hiện & Chạy Unit Test, Table-Driven Subtest, Benchmark & Fuzz Test
- **Công dụng**: Phát hiện và chạy từng `TestXxx`, từng dòng trong table-driven test, `BenchmarkXxx(b *testing.B)` (hiển thị `ns/op · B/op · allocs/op`), `FuzzXxx(f *testing.F)`, và `testify/suite`.
- **Cách kích hoạt**:
  - Mở tab **Tests** ở Sidebar hoặc click biểu tượng chạy ở lề trái (gutter) của hàm test.
  - **Chạy/Debug tại con trỏ**: Đặt con trỏ vào thân `TestXxx`, `t.Run(...)` hoặc dòng bảng dữ liệu trong file `*_test.go` rồi bấm `Product ▸ Run Test at Cursor` (`⌃⇧R`), `Product ▸ Debug Test at Cursor` (`⌃⌥R`), chuột phải chọn **`Run “...”`** / **`Debug “...”`**, hoặc lặp lại bài test gần nhất với `Product ▸ Repeat Last Test`.
  - **Code Coverage**: `Product ▸ Run Tests with Coverage` (`⌃⇧⌘U`) — hiển thị thanh màu 3pt ở lề trái (nét liền cho dòng đã phủ, nét đứt cho dòng chưa phủ).

### 3.3. Phân Tích Hiệu Năng (`CPU & Memory Profiler`), Mở File `.pprof` & Thanh Nhiệt (`Editor Line Heat`)
- **Công dụng**: Thu thập và phân tích `CPU` / `Memory` profile khi chạy test, mở file `.pprof` / `.pb.gz` bất kỳ từ đĩa, và hiển thị thanh nhiệt (`Editor Line Heat`) ngay trên lề trái (gutter) của các dòng code tốn nhiều tài nguyên.
- **Cách kích hoạt**:
  - **Menu**: `Product ▸ Profile Tests` (`⌃⌥⌘P`) hoặc `Product ▸ Open Profile (.pprof)…`
  - **Trong tab Profiler**: Bấm nút **`Open .pprof…`** hoặc bật/tắt ô **`Editor Line Heat`**.

---

## 4. Gỡ Lỗi Tiến Trình Đang Chạy & Kiểm Toán An Toàn GoLens Safety

### 4.1. Gắn Trình Gỡ Lỗi Vào Tiến Trình Đang Chạy Hoặc Remote Delve (`Attach to Process…`) & Run Configurations
- **Công dụng**:
  - **Attach to Process… (`⌃⌥⌘A`)**: Gắn Delve debugger trực tiếp vào tiến trình Go đang chạy trên máy (`Local Process` theo `PID`) hoặc kết nối tới `dlv` headless từ xa (`Remote Delve` qua `host:port`). Khi bấm **Stop Debugging (`⌘.`)**, GoLens tự động gửi `Disconnect(TerminateDebuggee: false)` để tách trình gỡ lỗi mà không làm tắt tiến trình của bạn.
  - **Run Configurations (Bảo Toàn Tham Số Có Dấu Ngoặc Kép)**: Hỗ trợ đầy đủ chuỗi đối số có dấu ngoặc kép đơn/kép và ký tự thoát (ví dụ `-owner "Daily QA"` được truyền nguyên vẹn thành một tham số `Daily QA` cho cả `Run` và `Debug`).
- **Cách kích hoạt**:
  - **Menu**: `Product ▸ Attach to Process…` (`⌃⌥⌘A`)
  - **Toolbar**: Mở menu **Run Configuration** trên thanh công cụ ▸ **`Attach to Process…`**
  - **Command Palette (`⇧⌘P`)**: `Attach Debugger to Process…`

### 4.1a. Tạm Dừng Chương Trình & Chạy Tới Con Trỏ (`Pause` / `Run to Cursor`)
- **Công dụng**:
  - **Pause**: Dừng chương trình đang chạy dưới debugger (ví dụ vòng lặp có `time.Sleep`) và hiển thị goroutine của code người dùng cùng stack trong tab **Debugger**.
  - **Run to Cursor**: Khi chương trình đang dừng, chạy tiếp tới dòng có con trỏ (hoặc dòng vừa click chuột phải) rồi dừng ở đó. GoLens đặt một breakpoint tạm thời và gỡ nó ở lần dừng kế tiếp (kể cả khi dừng ở breakpoint khác hoặc chương trình kết thúc); breakpoint của bạn giữ nguyên. Nếu chương trình đang chạy, file không phải Go, hoặc dòng không có câu lệnh, GoLens nói rõ lý do.
- **Cách kích hoạt**:
  - **Menu**: `Debug ▸ Pause` (`⌃⌘Y` khi đang chạy, giống Xcode; keymap VS Code `F6`) / `Debug ▸ Run to Cursor` (`⌃⌘C`; keymap GoLand `⌥F9`)
  - **Thanh điều khiển debugger**: nút Pause thay chỗ nút Continue khi chương trình đang chạy
  - **Menu chuột phải trong Editor** (file Go, khi đang debug): `Run to Cursor`

### 4.1c. Công Cụ Goroutine Trong Debugger (Lọc, Nhãn pprof, Dump)
- **Công dụng**:
  - **Lọc goroutine**: Khi chương trình đang dừng, ngay trên danh sách goroutine ở cột Frames của tab **Debugger** có ô lọc theo tên hàm, file, ID goroutine (`12` hoặc `#12`) hoặc nhãn pprof; bên cạnh là số đếm `N of M` (đang hiện / tổng số goroutine). Nếu bộ lọc chỉ còn lại goroutine hiện tại, dòng chú thích dưới ô lọc nói rõ điều đó.
  - **Ẩn goroutine hệ thống**: Goroutine chỉ chạy code của Go runtime (như bộ gom rác) được ẩn mặc định; bật lại bằng mục `Show System Goroutines` trong menu `…` cạnh số đếm (tooltip của số đếm cho biết bao nhiêu goroutine đang bị ẩn). Goroutine hiện tại luôn được liệt kê.
  - **Nhãn pprof**: Goroutine có nhãn `pprof.Labels` hiện nhãn ngay trong danh sách, ví dụ `Goroutine #18 [worker:alpha]`.
  - **Dump goroutine**: `Copy Goroutine Dump` / `Save Goroutine Dump…` tạo bản dump dạng văn bản: các goroutine có stack giống nhau được gộp dưới một tiêu đề kèm số lượng và ID (cùng nhãn nếu có), goroutine hệ thống ở cuối, frame thuộc dự án của bạn được đánh dấu `> `. Nếu chương trình đang chạy, GoLens nói rõ cần tạm dừng trước.
- **Cách kích hoạt**:
  - **Tab Debugger** (khi đang dừng, cột Frames): ô lọc, menu `…` ▸ `Show System Goroutines`, `Copy Goroutine Dump`, `Save Goroutine Dump…`
  - **Menu**: `Debug ▸ Copy Goroutine Dump` / `Debug ▸ Save Goroutine Dump…`

### 4.1b. Danh Sách Breakpoint & Breakpoint Theo Hàm (`Breakpoints`, `Add Function Breakpoint…`)
- **Công dụng**:
  - **Danh sách Breakpoints**: Tab phạm vi **Breakpoints** trong Issues navigator (`⌘4`), cạnh Bookmarks, liệt kê breakpoint theo dòng (theo file, kèm điều kiện, số lần chạm hoặc log message nếu có) và breakpoint theo hàm. Click một breakpoint dòng để nhảy tới dòng đó; click biểu tượng breakpoint ở đầu dòng để bật/tắt (breakpoint tắt hiện nhãn `Disabled` và mờ đi ở lề trái); xoá bằng nút `Delete` cuối dòng, menu chuột phải `Delete Breakpoint`, hoặc phím Delete.
  - **Phạm vi All**: `All` (và con số đi kèm) chỉ gồm những gì GoLens tìm thấy trong code — lỗi, cảnh báo, kết quả Safety, test thất bại và TODO. Bookmark và breakpoint do bạn tự đặt chỉ nằm (và chỉ được đếm) trong phạm vi riêng `Bookmarks` và `Breakpoints`.
  - **Breakpoint theo hàm**: Nhập tên hàm như `main.handler` hoặc method như `(*Server).Serve`; khi debug, chương trình dừng mỗi khi hàm đó bắt đầu chạy, hiển thị trong tab **Debugger** như mọi lần dừng khác. Nếu Delve không tìm thấy hàm, dòng đó hiện trạng thái cảnh báo và lý do bằng lời dễ hiểu thay vì im lặng; nếu debugger của phiên không hỗ trợ breakpoint theo hàm, GoLens cũng nói rõ.
  - **Lưu theo dự án**: Breakpoint dòng (cả điều kiện và trạng thái bật/tắt) và breakpoint theo hàm được lưu riêng cho từng dự án và khôi phục khi mở lại dự án. `Run to Cursor` không thay đổi danh sách này.
  - **Đi theo dòng khi sửa code**: Khi bạn thêm hoặc xoá dòng phía trên, breakpoint dòng di chuyển theo đúng dòng code của nó (Undo đưa nó về chỗ cũ); vị trí mới được dùng ngay cho lề trái, danh sách Breakpoints và (nếu đang debug) Delve, nhưng chỉ được lưu khi bạn lưu file; nếu đóng file mà không lưu, breakpoint trở về đúng dòng như trong file trên đĩa. Nếu chính dòng có breakpoint bị xoá, breakpoint ở lại tại dòng nơi đoạn bị xoá thu lại. Bookmark cũng đi theo dòng và được lưu theo đúng quy tắc này.
- **Cách kích hoạt**:
  - **Menu**: `Debug ▸ Add Function Breakpoint…`
  - **Issues navigator** (`⌘4`) ▸ phạm vi **Breakpoints** ▸ nút `+` trên thanh lọc, hoặc nút `Add Function Breakpoint…` khi danh sách trống
  - **Breakpoint dòng**: click số dòng trong file Go như trước

### 4.2. Kiểm Toán An Toàn Đa Tầng & Đặc Quyền Package (`GoLens Safety Audit + Capabilities`)
- **Công dụng**:
  - **Hazards & Vulns**: `go vet` + AST Concurrency/Security Hazards + `govulncheck` + `golangci-lint` (tự động tích hợp khi có trong `PATH`).
  - **Phát Hiện Rò Rỉ Tài Nguyên Theo Luồng & Sửa Nhanh Một Chạm (`IssuePopupView`)**: Theo dõi luồng điều khiển sau khi mở file/kết nối/giao dịch (bao gồm `os.OpenRoot`), phát hiện rò rỉ trên nhánh `return` sớm kể cả khi đường chạy chính đã có `Close()`, đồng thời bỏ qua các trường hợp tài nguyên được trả về, chuyển quyền sở hữu hoặc đóng trên mọi nhánh. Popup cảnh báo (`Navigate ▸ Next Issue` hoặc bấm vào nhãn lỗi nội tuyến) cung cấp sửa nhanh AST (`Return` / click) cho **`Add defer <target>.Close()`** (tự động xoá `Close()` đồng bộ dư thừa phía sau khi biến chưa gán lại), **`Add defer <tx>.Rollback()`**, **`Add defer <ticker>.Stop()`**, **`Add defer <mu>.Unlock()`** / **`Add defer <mu>.RUnlock()`** với hỗ trợ `Undo` / `Redo`, và chủ động từ chối chèn `defer` bên trong vòng lặp.
  - **Races & Panics**: Phân tích stack trace từ Console output khi có `DATA RACE` hoặc `panic:`.
  - **Dead Code**: Phát hiện hàm/phương thức không được gọi.
  - **Capabilities (`capslock`-style)**: Liệt kê các đặc quyền nhạy cảm mà package sử dụng (`CAPABILITY_NETWORK`, `CAPABILITY_EXEC`, `CAPABILITY_FILESYSTEM`, `CAPABILITY_UNSAFE`, `CAPABILITY_REFLECT`).
  - **Inline in Editor**: Hiển thị nhãn cảnh báo trực tiếp trên dòng code tương ứng trong trình soạn thảo.
- **Cách kích hoạt**:
  - **Menu**: `Product ▸ Run Safety Audit` (`⌃⇧⌘S`)
  - Mở tab **Safety** ở khung Console bên dưới, chọn bộ lọc **Capabilities** và bật/tắt **`Inline in Editor`**.

---

## 5. Công Cụ Struct, `go.mod` Code Lens & Git Tích Hợp Sâu (Wave 5)

### 5.1. Tự Động Gắn & Xoá Struct Tags (`⌃⌥T`)
- **Mục đích**: Tự động thêm, cập nhật hoặc xoá các tag (`json`, `yaml`, `db`, `xml`) trên toàn bộ các trường của `struct` tại vị trí con trỏ với hỗ trợ chuyển đổi kiểu chữ (`snake_case`, `camelCase`, `PascalCase`, `kebab-case`) và tuỳ chọn `,omitempty`.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Modify Struct Tags…` (`⌃⌥T`)
  - **Chuột phải trong editor**: `Generate ▸ Modify Struct Tags…`
  - **Command Palette (`⇧⌘P`)**: `Modify Struct Tags…`

### 5.2. Chuyển Đổi JSON Thành Go Struct Có Xem Trước (`⌃⌥V`)
- **Mục đích**: Dán hoặc nhập một mẫu JSON (object hoặc array) để suy luận và xem trước trực tiếp định nghĩa Go `type ... struct` (tự động chuẩn hoá các từ viết tắt `ID`, `URL`, `HTTP` và gắn tag `json:"..."`). Khi nhấn **Insert Struct**, GoLens tự động chèn struct mới ở cấp top-level ngay sau khối hiện tại để không bao giờ làm hỏng cú pháp file đang mở.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Convert JSON to Go Struct…` (`⌃⌥V`)
  - **Chuột phải trong editor**: `Generate ▸ Convert JSON to Go Struct…`
  - **Command Palette (`⇧⌘P`)**: `Convert JSON to Go Struct…`

### 5.3. `go.mod` Interactive Code Lens & Kiểm Tra Cập Nhật Dependency
- **Mục đích**: Cung cấp các nút thao tác trực tiếp ngay trong file `go.mod`:
  - Trên dòng `module`: **`Run go mod tidy`**, **`Check Module Updates`**, **`Download Modules`**.
  - Trên từng dòng `require` có phiên bản mới hơn: **`Upgrade to vX.Y.Z`** (chạy `go get module@vX.Y.Z` và tự động làm mới lại Code Lens).
- **Cách gọi**:
  - Mở `go.mod` và nhấp trực tiếp vào các nút Code Lens màu xanh trên dòng `module` hoặc `require`.
  - **Command Palette (`⇧⌘P`)**: `Check Go Module Updates`

### 5.4. Git Inline Blame & Khôi Phục Nhanh Vùng Sửa Đổi (`Revert Git Hunk`)
- **Mục đích**:
  - **Inline Git Blame**: Hiển thị thông tin commit (`Tác giả, thời gian — tóm tắt commit` hoặc `Uncommitted changes`) ngay ở cuối dòng con trỏ đang đứng.
  - **Gutter Hunk Diff & Revert**: Nhấp vào vạch màu thay đổi Git ở lề trái (gutter) để mở popover xem chi tiết các dòng thêm/xoá (`+`/`-`) và hoàn tác riêng vùng sửa đổi đó (`Revert Hunk`, hỗ trợ `⌘Z` để Undo) mà không ảnh hưởng tới các thay đổi khác trong file.
- **Cách gọi**:
  - **Bật/Tắt Inline Blame**: `View ▸ Show/Hide Inline Git Blame` hoặc Command Palette `Toggle Inline Git Blame`.
  - **Xem/Revert Hunk**: Nhấp chuột trái hoặc chuột phải vào vạch diff ở gutter (`Show Git Change…` / `Revert Git Hunk`), hoặc chọn `Editor ▸ Revert Git Hunk at Cursor`.

### 5.5. Commit Graph Trong History
- **Mục đích**: Màn History vẽ graph bên trái mỗi commit: mỗi nhánh một làn có màu riêng, commit merge là chấm rỗng, đường merge và đường rẽ nhánh nối giữa các làn.
- **Cách gọi**: Source Control navigator ▸ Show History (biểu tượng đồng hồ ở Recent Commits), hoặc chọn một branch, tag trong tab Repositories. Ô **All Branches** ở đầu màn hiện commit của mọi branch, branch remote và tag cùng lúc.
- **Ghi chú**: Khi lọc theo message, tác giả hoặc hash, graph được ẩn vì các commit còn lại không còn nối liền nhau.

### 5.6. Interactive Rebase
- **Mục đích**: Sửa lại lịch sử commit của branch hiện tại trước khi push: đổi thứ tự, đổi message (Reword), gộp vào commit phía trên (Squash giữ cả hai message, Fixup chỉ giữ message phía trên), bỏ commit (Drop), hoặc dừng ở một commit để sửa (Stop to Edit).
- **Cách gọi**: `Source Control ▸ Interactive Rebase…` (các commit chưa lên upstream; nếu không có thì 10 commit gần nhất), hoặc chuột phải một commit trong History ▸ `Interactively Rebase from Here…` (commit đó và mọi commit sau nó).
- **Cách dùng**: Chọn hành động ở ô đầu mỗi dòng; kéo dòng hoặc dùng nút mũi tên để đổi thứ tự (dòng trên được áp dụng trước); chọn Reword thì ô message bên dưới cho sửa. Bấm `Start Rebasing`.
- **Ghi chú**: Thay đổi chưa commit được stash trước và trả lại sau khi rebase xong. Sheet cảnh báo khi có commit đã lên remote (lần push sau cần force push) và không cho chạy khi trong khoảng có merge commit. Nếu dừng để edit hoặc gặp conflict, khung "Rebase in Progress" trong Source Control navigator có `Continue` và `Abort Rebase…`.

### 5.7. Merge Editor 3 Cột
- **Mục đích**: Giải quyết conflict của một file trong một màn: cột Left (phiên bản của bạn, HEAD), cột Result (kết quả sẽ lưu) và cột Right (phiên bản đang merge vào). Khi rebase, Left là upstream và Right là commit của bạn.
- **Cách gọi**: nút `Open in Merge Editor` trên banner "N Conflicts" của file, chuột phải file trong mục Merge Conflicts của Source Control navigator, hoặc `Source Control ▸ Open in Merge Editor`.
- **Cách dùng**: Với mỗi conflict, bấm `Accept Left` hoặc `Accept Right`, chọn `Both` để giữ cả hai theo thứ tự, hoặc gõ thẳng vào cột Result. `Accept All` giải quyết mọi conflict bằng một bên. `Apply Changes` ghi kết quả vào file (một bước Undo) và, nếu không còn conflict nào, lưu file và đánh dấu đã giải quyết.
- **Ghi chú**: Đoạn không đổi dài được thu gọn, bấm "Show N Unchanged Lines" để mở. Cancel khi đã chọn sẽ hỏi trước khi bỏ các lựa chọn.

### 5.8. Git Worktrees & Mở Nhanh Worktree Khi Trùng Nhánh
- **Mục đích**: Tạo và làm việc song song trên nhiều nhánh ở các thư mục worktree tách biệt bằng nhiều cửa sổ GoLens độc lập mà không làm gián đoạn công việc đang dở hoặc phải chạy lại chỉ mục từ đầu. Khi thử chuyển sang một nhánh đang được mở ở worktree khác, GoLens phát hiện xung đột và gợi ý nút **`Open Worktree`** để mở thẳng cửa sổ worktree tương ứng.
- **Cách gọi**:
  - **Source Control navigator ▸ Repositories**: mục **`Worktrees`** liệt kê mọi worktree kèm nhánh/HEAD, trạng thái `Locked`/`Missing`, và menu chuột phải (`Open in New Window`, `Show in Finder`, `Copy Path`, `Remove Worktree…`, `New Worktree…`, `Prune Stale Worktrees`). Chuột phải vào tiêu đề repository hoặc một nhánh để mở **`New Worktree…`** / **`New Worktree from “<branch>”…`**.
  - **Popover chuyển nhánh trên thanh công cụ**: hiển thị mục **`Worktrees`** khi repository có nhiều hơn một worktree cùng nút **`New Worktree…`**.
  - **Menu & Command Palette (`⇧⌘P`)**: `Source Control ▸ New Worktree…` (gán phím tắt tuỳ chỉnh trong `Settings ▸ Key Bindings` hoặc mặc định `⌃⌥⌘W` trong bộ phím `GoLand`).
  - **Chạy test `stretchr/testify/suite` theo con trỏ**: `Run Test at Cursor` (`⌃⇧R`) và `Debug Test at Cursor` (`⌃⌥R`) tự động tìm hàm `suite.Run` trong các file `*_test.go` cùng thư mục (kể cả buffer chưa lưu và trường hợp nhiều runner dùng chung một struct suite).

---

## 6. Tối Ưu Bộ Nhớ Struct, Xử Lý Lỗi Thông Minh & Go Scratchpad (Wave 6)

### 6.1. Phân Tích & Tối Ưu Bộ Nhớ Struct (`Inspect Struct Memory Layout…` `⌃⌥L`)
- **Mục đích**: Tính toán kích thước từng trường, độ căn chỉnh (`align`), byte offset và số byte bị lãng phí do padding (`Wasted Padding`) theo kiến trúc đích (`arm64`/`amd64`/`386`/`arm`), đồng thời cho phép tối ưu lại thứ tự trường bằng 1 cú nhấp chuột (`Optimize Field Order`) mà vẫn giữ nguyên toàn bộ struct tags.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Inspect Struct Memory Layout…` (`⌃⌥L`)
  - **Chuột phải trong editor**: `Refactor ▸ Inspect Struct Memory Layout…`
  - **Command Palette (`⇧⌘P`)**: `Inspect Struct Memory Layout…`

### 6.2. Tự Động Bọc Lỗi `if err != nil` (`⌃⌥E`) & Biến Đổi Nhanh AST
- **Mục đích**:
  - **Handle Error with `if err != nil` (`⌃⌥E`)**: Tự động bọc lệnh gọi hàm hoặc phép gán có `err` bằng khối `if err != nil { return <zero-values>, err }` khớp chính xác với chữ ký trả về của hàm bao ngoài (tự động nhận diện các hàm trả về 2 giá trị như `fmt.Println`, `io.Copy`, `os.Open` để sinh `if _, err := ...`).
  - **Convert Between `:=` and `var`**: Chuyển đổi nhanh giữa khai báo ngắn `x := expr` và `var x = expr`.
  - **Convert Between Raw and Interpreted String**: Chuyển đổi qua lại giữa chuỗi `"..."` và chuỗi thô `` `...` ``.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Handle Error with if err != nil` (`⌃⌥E`), `Editor ▸ Convert Between ':=' and 'var'`, `Editor ▸ Convert Between Raw and Interpreted String`
  - **Chuột phải trong editor**: `Refactor ▸ Handle Error with if err != nil`, `Refactor ▸ Convert Between ':=' and 'var'`, `Refactor ▸ Convert Between Raw and Interpreted String`

### 6.3. Go Scratchpad (`⌃⌥⌘N`) & So Sánh Benchmark Baseline
- **Mục đích**:
  - **Go Scratch File (`⌃⌥⌘N`)**: Tạo nhanh `.golens-scratch/scratch.go` có thể chạy thử ngay và truy cập đầy đủ `go.mod` của dự án hiện tại, đồng thời tự động ghi vào `.git/info/exclude` để không làm bẩn Git working tree.
  - **Pin Benchmark Baseline**: Ghim kết quả chạy Benchmark hiện tại làm mốc chuẩn (Baseline) trong Test Navigator (`⌘5`) để hiển thị `%` chênh lệch (`ns/op`, `B/op`) ở các lần chạy tiếp theo.
- **Cách gọi**:
  - **Menu**: `File ▸ New Go Scratch File` (`⌃⌥⌘N`)
  - **Command Palette (`⇧⌘P`)**: `New Go Scratch File`, `Run Go Scratch File`, `Pin Current Benchmarks as Baseline`

---

## 7. Trích Xuất Hàm/Biến (`Extract Function / Variable`), Biểu Đồ Lửa (`Flame Graph`) & Sinh Table-Driven Test (`⌃⇧T`) + Postfix Completions (Wave 7)

### 7.1. Trích Xuất Khối Lệnh Thành Hàm/Method (`Extract Function…` `⌥⌘M`), Trích Xuất Biến (`⌥⌘V`) & Nội Tuyến Biến (`⌥⌘N`)
- **Mục đích**:
  - **Extract Function… (`⌥⌘M`)**: Chọn một hoặc nhiều câu lệnh (hoặc đặt con trỏ trên dòng lệnh) để tách thành một hàm hoặc method mới. GoLens tự động phân tích AST để suy luận các biến đầu vào làm tham số (`Parameters`), các biến biến đổi hoặc được dùng sau vùng chọn làm giá trị trả về (`Return Values`), và tự động giữ nguyên receiver `(s *KVStore)` nếu đang ở bên trong một method.
  - **Extract Variable (`⌥⌘V`)**: Tách biểu thức đang chọn (hoặc biểu thức tại con trỏ) thành biến cục bộ `<name> := <expr>` ngay phía trên câu lệnh hiện tại.
  - **Inline Variable (`⌥⌘N`)**: Thay thế toàn bộ các vị trí sử dụng biến cục bộ bằng biểu thức khởi tạo gốc (tự động đóng ngoặc đơn nếu cần bảo toàn thứ tự ưu tiên toán tử) và xoá dòng khai báo biến.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Extract Function…` (`⌥⌘M`), `Editor ▸ Extract Variable` (`⌥⌘V`), `Editor ▸ Inline Variable` (`⌥⌘N`)
  - **Chuột phải trong editor**: `Refactor ▸ Extract Function…`, `Refactor ▸ Extract Variable`, `Refactor ▸ Inline Variable`
  - **Command Palette (`⇧⌘P`)**: `Extract Function…`, `Extract Variable`, `Inline Variable`

### 7.2. Biểu Đồ Lửa Tương Tác (`Interactive Flame Graph`) Trong Profiler
- **Mục đích**:
  - Chuyển đổi trực tiếp giữa bảng danh sách (**`Table`**) và biểu đồ lửa phân cấp (**`Flame Graph`**) ngay trên thanh công cụ của tab **Profiler** cho cả `CPU` và `Memory` profile.
  - Hiển thị trực quan cây lời gọi (`Callers` → `Children`) với độ rộng mỗi thanh tỷ lệ thuận với `Cum %`.
  - Nhấp vào bất kỳ thanh hàm nào để **phóng to (`Zoom`)** nhánh gọi đó thành gốc 100%, xem chi tiết `Flat` / `Cum`, nhảy trực tiếp tới dòng code nguồn (`Jump to Source`), hoặc bấm **`Reset Zoom`** để quay về toàn bộ mẫu đo.
- **Cách gọi**:
  - Chạy `Product ▸ Profile Tests` (`⌃⌥⌘P`) hoặc mở file `.pprof`, sau đó chọn **`Flame Graph`** trên thanh chuyển đổi **`Table | Flame Graph`** của tab **Profiler**.

### 7.3. Tự Động Sinh Table-Driven Test (`Generate Table-Driven Test…` `⌃⇧T`) & Go Postfix Completions
- **Mục đích**:
  - **Generate Table-Driven Test… (`⌃⇧T`)**: Đặt con trỏ vào bất kỳ hàm hoặc method nào và mở hộp thoại xem trước trực tiếp hàm `func TestXxx(t *testing.T)` chuẩn Go (`tests := []struct{ name string; ... }` kèm `t.Run(tt.name, ...)` và tuỳ chọn `Include t.Parallel()`). Khi bấm **Generate Test**, GoLens tự động tạo mới hoặc nối thêm vào file `<file>_test.go` (tự động thêm các `import` cần thiết) và mở ngay file test đó.
  - **Go Postfix Completions**: Gõ dấu chấm `.` sau một biểu thức bất kỳ để bung nhanh cấu trúc câu lệnh:
    - `<expr>.var` → `v := <expr>`
    - `<expr>.err` → `if <expr> != nil { return <expr> }`
    - `<expr>.nil` / `<expr>.notnil` → `if <expr> == nil { ... }` / `if <expr> != nil { ... }`
    - `<expr>.for` / `<expr>.fori` → vòng lặp `for _, v := range <expr>` / `for i := 0; i < len(<expr>); i++`
    - `<expr>.len` → `len(<expr>)`, `<expr>.return` → `return <expr>`, `<expr>.not` → `!<expr>`, `<expr>.print` → `fmt.Println(<expr>)`
- **Cách gọi**:
  - **Menu**: `Editor ▸ Generate Table-Driven Test…` (`⌃⇧T`) hoặc `Editor ▸ Generate Test`
  - **Chuột phải trong editor**: `Generate ▸ Generate Table-Driven Test…`
  - **Command Palette (`⇧⌘P`)**: `Generate Table-Driven Test…`

---

## 8. Zero-Edit Live Application Profiling (`⌃⇧⌘P`), Phân Tích Escape Analysis (`-gcflags="-m"`) & Nút Chạy `//go:generate` Trực Tiếp (Wave 8)

### 8.1. Đo Hiệu Năng Ứng Dụng Không Cần Sửa Code (`Product ▸ Profile Application` `⌃⇧⌘P`)
- **Mục đích**: Thu thập trực tiếp cả **CPU Profile** và **Heap Memory Profile** của toàn bộ ứng dụng `package main` bằng cơ chế `go run -overlay` mà **không sửa đổi bất kỳ dòng code nào trên đĩa** và không làm bẩn `git status`. Ngay khi ứng dụng chạy xong (hoặc khi bấm **Stop**), GoLens tự động nạp dữ liệu vào tab **Profiler** (cả chế độ **Table** lẫn **Flame Graph**) và hiển thị thanh nhiệt **Editor Line Heat** trên từng dòng code.
- **Cách gọi**:
  - **Menu**: `Product ▸ Profile Application` (`⌃⇧⌘P`)
  - **Thanh công cụ tab Profiler**: Bấm nút **`Profile App`** (hoặc **`Profile Application`** ở trạng thái rỗng)
  - **Command Palette (`⇧⌘P`)**: `Profile Application`

### 8.2. Chú Thích Nội Tuyến Escape Analysis Của Trình Biên Dịch Go (`View ▸ Show Escape Analysis`)
- **Mục đích**: Chạy `go build -gcflags=-m` trên package hiện tại và hiển thị trực tiếp các biến bị đẩy lên Heap (`↗ heap: ...`) hoặc tham số bị rò rỉ (`↗ leaks param: ...`) ngay cuối dòng code trong Editor, đồng thời ghi báo cáo tổng hợp số lượng `heap escape(s)`, `leaking param(s)` và `inlineable call(s)` ra Console.
- **Cách gọi**:
  - **Menu**: `View ▸ Show Escape Analysis` / `View ▸ Hide Escape Analysis`
  - **Command Palette (`⇧⌘P`)**: `Toggle Go Escape Analysis`

### 8.3. Nút Chạy `//go:generate` Tương Tác Trên Gutter & Code Lens
- **Mục đích**: Tự động nhận diện mọi chỉ thị `//go:generate <command>` trong file `.go`, hiển thị nút **Play (`▶`)** ngay trên Gutter cùng **Code Lens tương tác (`▶ Run go:generate (...)`)** bên cạnh dòng chỉ thị. Khi nhấp vào nút Play trên Gutter hoặc Code Lens, GoLens thực thi `go generate` trên file đó, stream kết quả ra Console và tự động cập nhật các file mới sinh vào cây thư mục dự án.
- **Cách gọi**:
  - **Trong Editor**: Nhấp trực tiếp vào nút `▶` trên Gutter hoặc nhấp vào nhãn `▶ Run go:generate (...)` tại dòng chứa `//go:generate`
  - **Menu**: `Product ▸ Run go generate`
- **Truy nguồn file Go tự sinh (`Generated-Code Origin`)**: Khi mở file `.go` mang tiêu đề `// Code generated ... DO NOT EDIT.`, GoLens tự tìm file nguồn gốc thông qua chỉ thị `//line` hoặc `//go:generate` trong cùng package và hiển thị banner kèm nút **`Open Source`** (mở đúng file và dòng nguồn tương ứng) cùng **`Regenerate`**. Nếu có lỗi biên dịch hoặc cảnh báo trong file tự sinh, popup chi tiết vấn đề cũng cung cấp nút **`Open Generator Source`** để nhảy thẳng về nguồn sinh code.

---

## 9. Tìm Kiếm Biểu Tượng Toàn Workspace (`⌘O`) & Refactor Kiểu Dữ Liệu (`⌥⌘T` / `⌃⌥P`) (Wave 9)

### 9.1. Tìm Kiếm Biểu Tượng Toàn Workspace (`Navigate ▸ Go to Workspace Symbol…` `⌘O` / `⌥⌘O`) & Tự Động Import Khi Gợi Ý Code
- **Mục đích**:
  - **Workspace Symbol Search (`⌘O` / `⌥⌘O`)**: Duyệt và tìm kiếm tức thời mọi `func`, `method` (kèm kiểu receiver `(*KVStore).Get`), `struct`, `interface`, `type`, `const`, `var` trên toàn bộ các package trong workspace (hỗ trợ khớp tiền tố, CamelCase humps và `Receiver.Method`), nhấn `Return` để nhảy tới đúng file và dòng khai báo.
  - **Auto-Import Unimported Packages**: Khi gõ tên package chưa có trong `import` và chọn hàm/kiểu từ bảng gợi ý code, GoLens tự động chèn dòng `import` tương ứng và hoàn tất biểu thức trong cùng 1 bước Undo (`⌘Z`).
- **Cách gọi**:
  - **Menu**: `Navigate ▸ Go to Workspace Symbol…` (`⌥⌘O` hoặc `⌘O` trong Editor)
  - **Command Palette (`⇧⌘P`)**: `Go to Workspace Symbol…`

### 9.2. Trích Xuất Kiểu Dữ Liệu Đặt Tên (`Extract Type Definition…` `⌥⌘T`) & Lan Truyền Phương Thức Interface (`⌃⌥P`)
- **Mục đích**:
  - **Extract Type Definition… (`⌥⌘T`)**: Tách một biểu thức kiểu phức tạp (`map[string]string`, `struct{...}`, `func(...)`) thành khai báo `type <Name> ...` ở cấp package kèm bản xem trước trực tiếp (`Live Preview`) và thay thế vị trí sử dụng.
  - **Propagate Method to Implementations… (`⌃⌥P`)**: Khi đặt con trỏ trong một `interface`, tự động phát hiện các `struct` trong package đang thực thi `interface` đó nhưng còn thiếu phương thức mới, hiển thị danh sách `Target Types` kèm bản xem trước các hàm stub chuẩn `gofmt`, và chèn đồng loạt chỉ với 1 cú nhấp.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Extract Type Definition…` (`⌥⌘T`), `Editor ▸ Propagate Method to Implementations…` (`⌃⌥P`)
  - **Command Palette (`⇧⌘P`)**: `Extract Type Definition…`, `Propagate Method to Implementations…`

---

## 10. Hiệu Năng Vùng Nhìn, Chế Độ File Lớn & Bảng Chẩn Đoán Workspace (Wave 10)

### 10.1. Tô Màu Ngữ Nghĩa Ưu Tiên Vùng Nhìn (`Viewport-First Semantic Highlighting`) & Dịch Chuyển Token Theo Delta
- **Mục đích**:
  - Giữ màu sắc ngữ nghĩa (`semantic tokens`) hoàn toàn ổn định ngay trong lúc đang gõ bên trong hoặc ở cuối tên hàm/biến/kiểu dữ liệu mà không bị nhấp nháy về màu chữ thường trong lúc chờ `gopls` phản hồi.
  - Ưu tiên truy vấn `textDocument/semanticTokens/range` cho vùng đang hiển thị (`visible viewport ± 512 chars`) trước, sau đó mới mở rộng sang vùng đệm xung quanh.

### 10.2. Chế Độ File Lớn (`Large-File Mode Banner`) & Nút `Enable Anyway`
- **Mục đích**:
  - Khi mở file `.go` có dung lượng `> 2 MB` hoặc `> 50.000 dòng`, GoLens tự động tạm dừng các tác vụ phân tích nặng toàn file (`Semantic Tokens`, `Inlay Hints`, `Code Lens`) để duy trì độ mượt 120Hz và hiển thị banner giải thích rõ ràng kèm nút **`Enable Anyway`** một chạm nếu người dùng vẫn muốn bật đầy đủ phân tích.

### 10.3. Bảng Chẩn Đoán Workspace (`Help ▸ Workspace Diagnostics…` `⌃⌥⌘D`) & Thu Hồi Bộ Nhớ Tự Động
- **Mục đích**:
  - Hiển thị trực tiếp dung lượng `Physical Footprint` của tiến trình macOS, bộ nhớ Heap/Sys/Goroutines/GC của nhân Go nhúng (`libgoagent.dylib`), trạng thái `PID` và `RSS` của `gopls`, số lượng `DocumentSession` đang mở và trạng thái `Large-File Mode`.
  - Cung cấp nút **`Release Unused Caches`** (và tự động kích hoạt khi macOS phát tín hiệu áp lực bộ nhớ `.warning` / `.critical`) để giải phóng các `DocumentSession` ẩn, thu gọn log và gọi `debug.FreeOSMemory()` trả lại trang nhớ cho macOS.
- **Cách gọi**:
  - **Menu**: `Help ▸ Workspace Diagnostics…` (`⌃⌥⌘D`)
  - **Command Palette (`⇧⌘P`)**: `Workspace Diagnostics…`

---

## 11. Kiểm Tra Đồng Thời & Ngữ Cảnh, So Sánh Benchmark Baseline & Sinh Mock Interface (Wave 11)

### 11.1. Trình Kiểm Tra Ngữ Cảnh & Goroutine Leak (`Editor ▸ Inspect Concurrency & Context…` `⌃⌥K`)
- **Mục đích**:
  - Quét cây cú pháp AST của file hiện tại hoặc toàn bộ các file `.go` trong workspace để phát hiện:
    1. **`Missing defer cancel()`**: Các lệnh khởi tạo `context.WithCancel` / `WithTimeout` / `WithDeadline` nhưng quên gọi `defer cancel()`.
    2. **`Root Context in Function`**: Sử dụng `context.Background()` hoặc `context.TODO()` trực tiếp bên trong hàm xử lý nghiệp vụ thay vì truyền `ctx context.Context`.
    3. **`Unbounded Goroutine`**: Lệnh `go func(...)` hoặc `go call(...)` không có cơ chế dừng qua `ctx.Done()` hoặc `sync.WaitGroup`.
  - Hỗ trợ nút **`Apply Fix`** / **`Apply All Quick Fixes`** để tự động chèn `defer cancel()` hoặc sửa ngữ cảnh ngay lập tức với hỗ trợ `⌘Z` (`Undo`).
- **Cách gọi**:
  - **Menu**: `Editor ▸ Inspect Concurrency & Context…` (`⌃⌥K`)
  - **Chuột phải**: `Refactor ▸ Inspect Concurrency & Context…`
  - **Command Palette (`⇧⌘P`)**: `Inspect Concurrency & Context…`

### 11.2. Trình So Sánh Benchmark Với Baseline (`Product ▸ Compare Benchmarks with Baseline…` `⌃⌥B`) & Huy Hiệu Độ Lệch Nội Tuyến
- **Mục đích**:
  - Lưu trữ kết quả chuẩn (`Save Current as Baseline`) và đối chiếu tự động các chỉ số `ns/op`, `B/op`, `allocs/op` giữa lần chạy hiện tại và baseline.
  - Phân loại kết quả theo từng hàm benchmark (`Faster`, `Regressed`, `Unchanged`, `New`) và hiển thị huy hiệu độ lệch trực tiếp trên dòng Code Lens trong trình soạn thảo (`Run Bench | Compare Baseline (7.70 ns/op · -12.4% faster)`).
- **Cách gọi**:
  - **Menu**: `Product ▸ Compare Benchmarks with Baseline…` (`⌃⌥B`)
  - **Command Palette (`⇧⌘P`)**: `Compare Benchmarks with Baseline…`

### 11.3. Trình Sinh Mock / Stub Tự Động Cho Interface (`Editor ▸ Generate Interface Mock…` `⌃⌥M`)
- **Mục đích**:
  - Tự động phân tích các `interface` trong package và sinh `struct Mock<InterfaceName>` an toàn đồng thời (`sync.Mutex`), không phụ thuộc thư viện ngoài, bao gồm trường hook `<Method>Func` và mảng ghi nhận lịch sử gọi `<Method>Calls`.
  - Cho phép chèn trực tiếp vào file hiện tại hoặc tạo file kiểm thử độc lập `mock_<interface>_test.go`.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Generate Interface Mock…` (`⌃⌥M`)
  - **Chuột phải**: `Generate ▸ Generate Interface Mock…`
  - **Command Palette (`⇧⌘P`)**: `Generate Interface Mock…`

---

## 12. Đồ Thị Phụ Thuộc Package, Tự Động Điền Struct & Kiểm Toán Bảo Mật Chuỗi Cung Ứng `go.mod` (Wave 12)

### 12.1. Trình Phân Tích Đồ Thị Phụ Thuộc Package & Phát Hiện Chu Trình Import (`Navigate ▸ Inspect Package Dependencies…` `⌃⌥G`)
- **Mục đích**:
  - Phân tích toàn bộ các khai báo `import` trong workspace, phân loại rõ **Internal Packages**, **Standard Library** và **External Modules**, tính toán chỉ số `Fan-In` / `Fan-Out` và tự động phát hiện mọi chu trình phụ thuộc vòng (`Circular Cycles`: `A → B → A`) kèm nút **`Jump to Import`**.
- **Cách gọi**:
  - **Menu**: `Navigate ▸ Inspect Package Dependencies…` (`⌃⌥G`)
  - **Command Palette (`⇧⌘P`)**: `Inspect Package Dependencies…`

### 12.2. Tự Động Điền Đầy Đủ Trường Khởi Tạo Struct (`Editor ▸ Fill Struct Fields` `⌃⌥F`)
- **Mục đích**:
  - Đặt con trỏ vào bất kỳ biểu thức khởi tạo struct nào (`KVStore{}` hoặc `&Payload{}`) và nhấn `⌃⌥F`, GoLens tự động tra cứu định nghĩa `struct` xuyên file trong package và điền đầy đủ các trường còn thiếu với giá trị mặc định chuẩn Go (`""`, `0`, `false`, `nil`, `SubStruct{}`), hỗ trợ hoàn tác 1 bước bằng `⌘Z`.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Fill Struct Fields` (`⌃⌥F`)
  - **Chuột phải**: `Generate ▸ Fill Struct Fields`
  - **Command Palette (`⇧⌘P`)**: `Fill Struct Fields`

### 12.3. Kiểm Toán Chuỗi Cung Ứng & Bảo Mật Phụ Thuộc `go.mod` Trong Tab `Safety` (`⌃⇧⌘S`)
- **Mục đích**:
  - Quét `go.mod` trong quá trình chạy `Product ▸ Run Safety Audit` (`⌃⇧⌘S`) để phát hiện phiên bản Go toolchain cũ (`[DEP_TOOLCHAIN]`), chỉ thị `replace` cục bộ bỏ qua kiểm tra checksum (`[DEP_REPLACE]`), các phiên bản module có lỗ hổng bảo mật đã biết (`[DEP_VULN]`) và các bản ghim pseudo-version chưa gắn thẻ (`[DEP_PIN]`), hiển thị trong bộ lọc **`Dependencies`** của tab **`Safety`**.

---

## 13. Phân Tích Độ Phức Tạp Hàm (Wave 13)

### 13.1. Trình Phân Tích Độ Phức Tạp Hàm Cyclomatic & Cognitive (`Editor ▸ Inspect Function Complexity…` `⌃⌥Q`)
- **Mục đích**:
  - Đo lường chỉ số **Cognitive Complexity**, **Cyclomatic Complexity**, độ sâu lồng nhau (**Max Nesting**) và số dòng cho từng hàm trong file hiện tại hoặc toàn bộ workspace, phân loại theo mức `Good` / `Moderate` / `High`, gợi ý tách hàm bằng `Extract Function (⌥⌘M)` và hỗ trợ nút **`Jump to Function`**.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Inspect Function Complexity…` (`⌃⌥Q`)
  - **Chuột phải**: `Refactor ▸ Inspect Function Complexity…`
  - **Command Palette (`⇧⌘P`)**: `Inspect Function Complexity…`

---

## 14. Sinh Phương Thức Enum / Stringer, Kiểm Tra Lộ Dữ Liệu Nhạy Cảm & Sinh Constructor / Functional Options (Wave 14)

### 14.1. Trình Sinh Phương Thức `String()` & Bộ Chuyển Đổi Enum Cho Hằng Số Go (`Editor ▸ Generate Enum / Stringer Methods…` `⌃⌥S`)
- **Mục đích**:
  - Tự động phát hiện kiểu hằng số (`type <Enum> int` / `string` kèm khối `const (...)` dùng `iota` hoặc giá trị tường minh) trong package và sinh bộ phương thức chuẩn không phụ thuộc thư viện ngoài: `String() string`, `Parse<Enum>(s string) (<Enum>, error)`, `IsValid() bool` và `All<Enum>Values() []<Enum>`.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Generate Enum / Stringer Methods…` (`⌃⌥S`)
  - **Chuột phải**: `Generate ▸ Generate Enum / Stringer Methods…`
  - **Command Palette (`⇧⌘P`)**: `Generate Enum / Stringer Methods…`

### 14.2. Trình Kiểm Tra Lộ Dữ Liệu Nhạy Cảm Trong Struct Tag & Log (`Editor ▸ Inspect Sensitive Data Exposure…` `⌃⌥D`)
- **Mục đích**:
  - Quét tĩnh cây cú pháp AST để phát hiện các trường nhạy cảm (`Password`, `Secret`, `Token`, `APIKey`, `PrivateKey`, `AccessKey`, `SSN`, `CreditCard`) bị lộ qua struct tag (`[SENSITIVE_TAG]`), thiếu hàm `String() string` che giấu (`[SENSITIVE_STRINGER]`) hoặc bị truyền trực tiếp vào lệnh in/log (`[SENSITIVE_LOG]`), kèm nút **`Apply Fix`** / **`Apply All Quick Fixes`** một chạm.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Inspect Sensitive Data Exposure…` (`⌃⌥D`)
  - **Chuột phải**: `Refactor ▸ Inspect Sensitive Data Exposure…`
  - **Command Palette (`⇧⌘P`)**: `Inspect Sensitive Data Exposure…`

### 14.3. Trình Sinh Hàm Khởi Tạo & Functional Options Cho Struct (`Editor ▸ Generate Constructor & Options…` `⌃⌥N`)
- **Mục đích**:
  - Sinh nhanh hàm khởi tạo `New<Struct>(...) *<Struct>` hoặc mẫu thiết kế **Functional Options (`type <Struct>Option func(*<Struct>)`, `With<Field>(...) <Struct>Option`)** chuẩn Go kèm tự động khởi tạo `make(...)` cho trường `map`.
- **Cách gọi**:
  - **Menu**: `Editor ▸ Generate Constructor & Options…` (`⌃⌥N`)
  - **Chuột phải**: `Generate ▸ Generate Constructor & Options…`
  - **Command Palette (`⇧⌘P`)**: `Generate Constructor & Options…`



---

## 15. HTTP Client Dùng File `.http` (Cú Pháp Tương Thích JetBrains)

### 15.1. Chạy Request Từ Editor, Chọn Môi Trường & Nối Chuỗi Request
- **Mục đích**:
  - Lưu bộ request trong Git dưới dạng file `.http` (cùng cú pháp với GoLand/IntelliJ): `###` tách request (`### Login`, `# @name login`), dòng `METHOD URL`, header, body, `< ./file.json` (nhúng file), `<@ ./file.json` (nhúng và thay biến), `# @no-redirect`, `# @timeout 60`, biến trong file `@base = /api`.
  - Biến `{{host}}` lấy từ `http-client.env.json` và `http-client.private.env.json` (file private ghi đè; nhóm `$shared` áp cho mọi môi trường), từ `client.global` và các biến động `{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$randomInt}}`, `{{$random.integer(1, 10)}}`, `{{$env.NAME}}`.
  - Response handler `> {% ... %}` (hoặc `> ./check.js`) chạy bằng JavaScriptCore: `client.global.set/get/clear/clearAll/isEmpty`, `client.test(name, fn)`, `client.assert(cond, msg)`, `client.log(...)`, `response.status`, `response.headers.valueOf(name)` / `valuesOf(name)`, `response.body` (đã parse JSON), `response.contentType`.
  - gRPC: `GRPC host:port/package.Service/Method` với body JSON, đọc định nghĩa qua server reflection (unary và server-streaming; `grpcs://` dùng TLS).
- **Cách gọi**:
  - **Code Lens**: `Run Request` ở cuối dòng request; sau khi chạy hiện kết quả (`200 OK · 42 ms · 2 tests passed`, xanh khi đạt, đỏ khi lỗi) — bấm để mở response.
  - **Thanh jump bar** (khi mở file `.http`): menu `Environment` và nút `Run All`.
  - **Menu**: `Product ▸ Run HTTP Request` (`⌃↩`), `Product ▸ Run All HTTP Requests in File` (`⌃⇧↩`), `Product ▸ Stop HTTP Requests`, `Product ▸ HTTP Environment`, `Product ▸ Show HTTP Responses`, `File ▸ New HTTP Request File`.
  - **Chuột phải** trong file `.http`: `Run HTTP Request`, `Run All HTTP Requests in File`.
  - **Command Palette (`⇧⌘P`)**: `Run HTTP Request`, `Run All HTTP Requests in File`, `New HTTP Request File`, `Show HTTP Responses`.
- **Xem kết quả**: tab `Requests` ở panel dưới — lịch sử theo từng request (20 lần gần nhất), trạng thái, thời gian (di chuột để xem DNS/Connect/TLS/First byte), kích thước, `Body` (JSON đã định dạng), `Headers`, `Tests` (đạt/trượt theo từng test và từng assertion), `Request` (request thực sự đã gửi sau khi thay biến). Lỗi giải thích nguyên nhân bằng lời và có nút `Run Again`, `Run Project`, `Choose Environment`, `Open Environment File`.
- **Bảo mật**: biến `client.global` và lịch sử response chỉ nằm trong bộ nhớ của phiên làm việc, không ghi ra đĩa; chỉ tên môi trường đã chọn được lưu lại.

## 16. Gợi Ý Code Bằng AI Ngay Trong Editor (`AI Suggestions`)

- **Bật**: `Settings ▸ Editing ▸ Completion ▸ AI Suggestions` (mặc định **tắt**). Lần bật đầu tiên GoLens hỏi lại và nói rõ dữ liệu được gửi đi: đoạn code quanh con trỏ của file Go đang mở và đường dẫn của file trong dự án, gửi tới provider đã cấu hình trong Gopilot. Không gửi gì khác; file `.env`, khoá bí mật, chứng chỉ và các file Gopilot loại trừ không bao giờ được gửi, credential nhận diện được (kể cả API key) bị thay trước khi gửi.
- **Model riêng**: chọn `Model` cho gợi ý (độc lập với model chat của Gopilot, dùng chung provider và API key). `Request Style`: `Chat` (yêu cầu model chat điền vào chỗ trống, chạy với NanoGPT) hoặc `Fill-in-the-Middle` (gửi code trước và sau con trỏ tới `/completions`, ví dụ Codestral qua LiteLLM). GoLens tự đoán kiểu theo tên model, bạn có thể đổi. Với Fill-in-the-Middle, `FIM Template` chọn cách gửi code sau con trỏ: `Suffix Parameter` (Mistral, DeepSeek, OpenAI) hoặc template thô của model (`Qwen2.5-Coder`, `Codestral`, `DeepSeek Coder`, `StarCoder`) cho các route bỏ qua tham số `suffix` (ví dụ llama.cpp sau LiteLLM). Nút `Test` gửi một yêu cầu nhỏ và báo thời gian phản hồi; với Fill-in-the-Middle còn báo provider có dùng code sau con trỏ hay không, route có trả về định dạng gốc của server hay không, streaming có lỗi hay không, hoặc model không hỗ trợ (khi đó đổi template hoặc chọn `Chat`).
- **Dùng**: dừng gõ trong file `.go` → gợi ý màu xám hiện ngay tại con trỏ (một dòng, hoặc nhiều dòng khi phần còn lại của dòng trống). `Tab` chèn toàn bộ gợi ý (một bước Undo tên `Accept Suggestion`), `Esc` ẩn, gõ đúng ký tự tiếp theo của gợi ý thì gợi ý ngắn lại, gõ khác/`Return`/di chuyển con trỏ thì gợi ý biến mất. Danh sách completion của gopls và snippet luôn được ưu tiên: khi chúng đang mở thì không có gợi ý AI.
- **Lệnh**: `Editor ▸ Show Suggestion` (`⌥\`) yêu cầu gợi ý ngay; `Editor ▸ Read Suggestion` đọc gợi ý bằng VoiceOver. Cả hai có trong Command Palette.
- **Trạng thái**: biểu tượng `sparkles` trên thanh trạng thái khi tính năng đang bật; mờ khi file hiện tại không dùng được; `Suggestions Paused` màu cam kèm lý do khi provider lỗi liên tục (gợi ý tự tạm dừng, không hiện thông báo khi đang gõ).
- **Đồng ý kết nối AI ra ngoài (`Outbound AI Consent`)**: Mọi yêu cầu mạng tới endpoint AI không phải loopback (`127.0.0.1`, `localhost`, `::1`) — bao gồm `Fetch Models`, `Test Connection`, `Check This Model`, `Test` trong Cài đặt, lượt chat Gopilot và chuyển hướng HTTP — đều kiểm tra và hỏi xác nhận rõ ràng cho từng host trước khi gửi dữ liệu hoặc API key ra ngoài.

---

## 17. Tra Cứu Phím Tắt (`Help ▸ Keyboard Shortcuts`)

- **Mở bảng phím tắt**: Chọn `Help ▸ Keyboard Shortcuts` trên thanh menu (cũng có thể gán phím tắt riêng trong `Settings ▸ Key Bindings`).
- **Nhóm theo menu & cập nhật trực tiếp**: Danh sách nhóm các phím tắt theo đúng thứ tự thanh menu (`GoLens`, `File`, `Edit`, `View`, `Find`, `Navigate`, `Editor`, `Product`, `Debug`, `Source Control`, `Tools`, `Window`, `Help`) và tự động cập nhật ngay lập tức khi bạn đổi bộ phím (`GoLens`, `VS Code`, `GoLand`), thay đổi phím tắt tùy chỉnh (nhãn `Custom`), đổi phím chấp nhận completion (`Tab` / `Return`), hoặc có phím bị trùng.
- **Tìm kiếm nhanh**: Gõ tên lệnh, tên menu hoặc tổ hợp phím vào ô tìm kiếm (`Search Keyboard Shortcuts`); nhấn `Esc` để xóa từ khóa đang lọc hoặc đóng cửa sổ khi ô tìm trống, và bấm `Customize…` để mở `Settings ▸ Key Bindings`.

---

## 18. Báo Cáo Sự Cố & Gói Chẩn Đoán Cục Bộ (`Help ▸ Report a Problem…`)

- **Mở**: chọn **Help ▸ Report a Problem…** trên thanh menu khi đang mở một cửa sổ GoLens.
- **Thu thập cục bộ & che dữ liệu nhạy cảm**: GoLens thu thập tại chỗ 4 nhóm thông tin đã được lọc trước khi hiển thị — phiên bản ứng dụng và macOS (`system-info.txt`), phiên bản `go` / `gopls` (`toolchain-health.txt`), phần cuối log của GoLens (`golens-logs.txt`) và payload hiệu năng/sự cố từ Apple MetricKit lưu cục bộ dưới `~/Library/Application Support/GoLens/Diagnostics/` (`metrickit-diagnostics.json`). Không thu thập output console của chương trình bạn chạy, nội dung file hay đường dẫn dự án. API key, token, mật khẩu trong URL, địa chỉ email, đường dẫn dự án và thư mục cá nhân được thay thế trước khi hiện trên màn hình. Tính năng này không đọc Keychain và không tự gửi dữ liệu ra ngoài.
- **Xem trước, bỏ chọn và xoá mục**: mở rộng từng mục để xem chính xác nội dung đã lọc sẽ được đóng gói; bỏ tick ô chọn hoặc nhấn nút thùng rác để loại bỏ mục đó khỏi lần báo cáo này.
- **Xuất file**: **Save Archive…** chọn nơi lưu gói `.zip` chỉ chứa các mục đang được tick chọn.

---

## 19. Công Cụ Cơ Sở Dữ Liệu (`Tools ▸ Database`)

- **Data source**: `Tools ▸ Database ▸ Data Sources…` thêm PostgreSQL, MySQL/MariaDB hoặc SQLite; mật khẩu nằm trong Keychain, định nghĩa nằm trong `.golens/data-sources.json`. `Detect Data Sources in Project…` đọc biến kiểu `DATABASE_URL` trong file `.env*`, service `postgres`/`mysql`/`mariadb` trong `compose.yaml` và `sqlc.yaml`, rồi đề xuất từng data source trong một sheet với mọi trường hiển thị; không có gì được tạo khi chưa bấm `Done`, và mật khẩu tìm thấy trong file chỉ vào Keychain khi bạn bật ô lưu mật khẩu. Mục `Transactions` của data source chọn chế độ mặc định cho console mới (data source production mặc định là `Manual`).
- **Chạy SQL**: mở file `.sql` gắn với data source, `⌘↩` chạy câu lệnh tại con trỏ. Câu lệnh có tham số (`$1`, `?`, `:name`, `@name`, `sqlc.arg(name)`) mở sheet `Query Parameters`: mỗi tham số một ô, gợi ý kiểu khi câu lệnh cho biết, `NULL` và `Secret`; giá trị luôn được gửi riêng cho database (bind), không bao giờ ghép vào chuỗi SQL. Lỗi cú pháp có vị trí được gạch chân ngay trong editor và biến mất khi bạn sửa hoặc chạy lại.
- **Transaction**: trên thanh breadcrumb của console, menu `Auto-Commit` / `Manual` và `Isolation Level` (chỉ các mức engine hỗ trợ). Ở `Manual`, sau câu lệnh đầu tiên console hiện `Transaction Active` cùng nút `Commit` và `Roll Back` (cũng có trong `Tools ▸ Database`). Không đổi được chế độ hay isolation khi transaction đang mở — GoLens nói rõ lý do. Đóng console hoặc cửa sổ khi transaction đang mở sẽ hỏi `Commit`, `Roll Back` hoặc `Cancel`.
- **Table editor**: double-click bảng trong schema outline (hoặc giữ `⌘` và bấm tên bảng trong console đã gắn data source; khi giữ `⌘`, tên bảng có gạch chân) mở tab bảng với ô `WHERE` và `ORDER BY` (có gợi ý cột; `Return` để áp dụng). Bấm tiêu đề cột sắp xếp phía server. `Count Rows` chỉ đếm khi bạn bấm. Bảng có primary key hoặc unique key not-null thì sửa được: `Return` hoặc double-click để sửa ô (`Esc` huỷ), chuột phải có `Set NULL`, `Add Row`, `Duplicate Row`, `Delete Rows` (`⌘⌫`), `Revert Selected`, `Revert All`. Cột `Change` ghi `New`, `Edited`, `Deleted` cho từng dòng. `Submit Changes` (`⇧⌘↩`; keymap GoLand `⌥⌘↩`) mở bản xem trước đúng các câu SQL sẽ chạy (DELETE, rồi UPDATE mỗi dòng một câu, rồi INSERT) và chạy tất cả trong một transaction; mỗi câu phải đổi đúng một dòng, nếu không mọi thứ được roll back kèm giải thích. Data source production hỏi lại một lần nữa. Bảng không có khoá thì chỉ xem, và lý do hiện ngay trên bảng.
- **Explain**: `Tools ▸ Database ▸ Explain Plan` và `Explain Analyze` cho câu lệnh tại con trỏ; kết quả là cây các node với rows ước tính/thực tế, cost và thời gian, node tốn nhất được đánh dấu `Most Expensive`. `Explain Analyze` một câu ghi dữ liệu trên PostgreSQL chạy trong transaction và luôn được roll back (GoLens báo rõ); MySQL và SQLite không phân tích câu ghi và nói lý do.
- **Query History**: `Tools ▸ Database ▸ Query History…` mở ô tìm nhanh các câu đã chạy trên data source hiện tại (tối đa 1.000 câu mỗi data source, lưu trong Application Support của máy). `Return` chèn câu lệnh tại con trỏ, `⌘⌫` xoá một câu, `Clear History…` xoá hết. Giá trị đánh dấu `Secret` và giá trị gõ trong table editor không bao giờ được lưu.
- **Export**: nút `Export…` dưới lưới kết quả hoặc `Tools ▸ Database ▸ Export Result…` lưu ra CSV, TSV, JSON, SQL INSERT (sửa được tên bảng) hoặc Markdown, cho dòng đang chọn, các dòng đã tải hoặc toàn bộ kết quả (GoLens đọc tiếp từ cursor thẳng vào file, không tốn thêm bộ nhớ; sau đó lưới chỉ giữ các dòng đã tải). Chuột phải ▸ `Copy As` chép ra clipboard, tối đa 10 MB.
- **SQL trong code Go**: chuỗi SQL hằng (kể cả nối chuỗi hằng) truyền vào `database/sql` (`Query`, `QueryRow`, `Exec`, `Prepare` và bản `Context`), pgx (`Query`, `QueryRow`, `Exec`, `Batch.Queue`) và sqlx (`Select`, `Get`, `NamedExec`, `NamedQuery`, `Queryx`, `QueryRowx`), hoặc chuỗi có chú thích `// language=SQL` ngay phía trên, có lens `Run SQL`, tô màu từ khoá SQL và gợi ý bảng, cột ngay trong chuỗi. GoLens dùng data source mặc định: data source đầu tiên, hoặc data source chọn trong `Tools ▸ Database ▸ Default Data Source`. Tham số (`$1`, `?`, `:name`) mở sheet `Query Parameters`; kết quả hiện trong tab `Database` với tiêu đề là file và dòng Go (`store.go:42`). `Tools ▸ Database ▸ Run SQL` chạy chuỗi SQL tại con trỏ. Chỉ project có data source mới được quét, và việc quét chạy nền khi bạn dừng gõ hoặc lưu file.
- **sqlc**: khi project có data source, mỗi dòng `-- name:` có thêm lens `Run Query` cạnh `Go Method` và `Usages`. Câu truy vấn chạy trên data source có engine khớp với `sqlc.yaml` (nếu không có thì data source mặc định); `sqlc.arg(x)`, `sqlc.narg(x)`, `sqlc.slice(x)` và `@x` thành tham số trong sheet `Query Parameters`. Project sqlc không có data source vẫn như cũ.
- **SSH tunnel**: trong `Data Sources…`, bật `Connect Through SSH` và nhập `user@host` hoặc tên Host trong `~/.ssh/config` (cổng SSH tuỳ chọn). GoLens chạy `/usr/bin/ssh -N -L` nên key, ssh-agent, ProxyJump và security key đều dùng được; mật khẩu SSH không được hỗ trợ. Mỗi data source chỉ có một tunnel, dùng chung cho mọi console; tunnel dừng khi kết nối cuối cùng đóng, khi `Disconnect`, khi đóng cửa sổ và khi thoát app. Nếu SSH báo chưa biết host key, hãy chạy `ssh <destination>` một lần trong Terminal để chấp nhận key rồi thử lại.
- **Dòng liên quan**: trong tab bảng, chuột phải vào ô của cột khoá ngoại ▸ `Show Referenced Row` mở bảng được tham chiếu, lọc đúng dòng đó; `Show Referencing Rows` liệt kê các bảng tham chiếu tới dòng đang chọn và mở bảng bạn chọn với bộ lọc tương ứng (bộ lọc hiện trong ô `WHERE`).

---

## 20. Containers và Kubernetes (`Services`)

- **Mở**: `View ▸ Show Services` (hoặc `Tools ▸ Containers & Compose ▸ Show Services`, `Tools ▸ Kubernetes ▸ Show Kubernetes`, mở sẵn mục Kubernetes). Tab `Services` ở panel dưới có hai mục: Docker (container, Compose, image, volume, network) và Kubernetes (hiện khi máy có kubeconfig: `KUBECONFIG` hoặc `~/.kube/config`).
- **Kubernetes**: tiêu đề mục có hai menu chọn context và namespace. Chọn context trong GoLens không sửa kubeconfig; `Use as kubectl Default…` chỉ ghi `current-context` sau khi bạn xác nhận. GoLens chỉ kết nối cluster khi mục Kubernetes đang mở và tab đang hiện, mỗi nhóm đang mở (Pods, Deployments, Services) dùng một watch; thu gọn nhóm, đổi context/namespace hoặc ẩn tab quá 30 giây thì watch đóng lại.
- **Pod**: chọn pod để xem log trực tiếp (500 dòng cuối rồi theo dõi); pod crash có banner và `Show Previous Logs` để đọc log container trước lần restart. `Details` có Overview, từng container (image, trạng thái, lần thoát cuối, requests/limits), Conditions và Events (cảnh báo màu cam). `Open Shell` mở tab Terminal chạy `kubectl exec`. `Delete Pod…` hỏi trước và ghi rõ context, namespace.
- **Deployment và Service**: `Show Pods` lọc danh sách pod theo selector, `Rollout Restart…` hỏi trước. `Port Forward…` (service hoặc pod có cổng TCP) chọn cổng local (cổng đang bận thì GoLens chọn cổng trống kế tiếp và nói rõ); forward hiện thành dòng con với `Stop` và `Open in Browser`.
- **Apply to Cluster…**: với file YAML có `apiVersion` và `kind` ở cấp cao nhất (`Tools ▸ Kubernetes` hoặc menu chuột phải trong editor), sheet chạy `kubectl diff` và hiện thay đổi từng object trước, rồi `Apply` chạy `kubectl apply` thành một phiên trong Console.
- **Read-Only for This Context**: tắt mọi thao tác thay đổi (Delete Pod, Rollout Restart, Apply) cho context đó và ghi rõ lý do.
- **Lỗi**: không kết nối được cluster thì hiện địa chỉ server và `Retry`; thiếu credential helper (ví dụ `gke-gcloud-auth-plugin`) thì nói tên helper; không có quyền list thì có `Choose Namespace…`; phiên đăng nhập hết hạn thì `Open Terminal` chạy sẵn lệnh đăng nhập.

## 21. Bắt Đầu Với GoLens (`Help ▸ Get Started`)

- **Thiết lập máy**: lần đầu mở GoLens, nếu máy thiếu Go, gopls, Git hoặc Delve, cửa sổ Welcome hiện `Set Up Your Mac for Go` với nút cài cho từng công cụ và `Check Again` để kiểm lại.
- **Get Started**: khi đủ công cụ, cửa sổ Welcome hiện 5 việc nên làm thử: mở một dự án Go, nhảy tới định nghĩa, chạy test bằng nút ở lề editor, dừng ở một breakpoint, mở Command Palette. Mỗi việc tự đánh dấu khi bạn làm thật; dòng hướng dẫn dưới mỗi việc dùng đúng phím tắt của keymap đang chọn.
- **Ẩn và hiện lại**: bấm `Hide` để ẩn; chọn `Help ▸ Get Started` để hiện lại và mở cửa sổ Welcome. Tiến độ được giữ qua các lần mở app.

## 22. Giấy Phép Mã Nguồn Mở (`GoLens ▸ About GoLens ▸ Acknowledgements`)

- **Mở**: chọn `About GoLens` trong menu GoLens rồi bấm `Acknowledgements`.
- **Nội dung**: mọi thành phần mã nguồn mở có trong GoLens (Swift package, module Go trong lõi, thư viện chuẩn Go) và tài nguyên đồ họa (Go gopher, icon nhà cung cấp AI). Mỗi văn bản giấy phép hiện một lần, kèm danh sách thành phần dùng nó.
- **Tìm**: gõ tên thành phần vào `Search Components`, ví dụ `pgx` hoặc `SwiftTerm`.

## 23. Linux Sandbox Tải Thêm (`Settings ▸ Execution`)

- **Mặc định**: mọi project chạy trên macOS bằng Go, gopls, Git và Delve của máy. GoLens không kèm máy ảo trong bản cài.
- **Tải về**: mở `Settings ▸ Execution`, mục `Linux Sandbox` cho biết dung lượng tải và dung lượng trên đĩa. Bấm `Download`; trong lúc tải có thanh tiến độ và `Cancel`. Mạng đứt hoặc bấm `Cancel` thì lần sau tải tiếp từ chỗ đã dừng.
- **Kiểm chứng**: GoLens chỉ cài khi bản mô tả runtime có chữ ký của GoLens và file tải về khớp checksum trong bản mô tả đó; nếu không khớp, GoLens xóa file và nói rõ lý do.
- **Dùng cho một project**: sau khi cài, bật `Run “<tên project>” in the Linux Sandbox`. GoLens nhớ lựa chọn này cho project, không hỏi lại mỗi lần mở. Khi có project đang mở dùng sandbox, mọi project đang mở đều chạy trong sandbox; dòng `Running On` cho biết đang chạy ở đâu.
- **Cập nhật và gỡ**: `Update` xuất hiện khi có bản runtime mới; `Remove…` xóa runtime và giải phóng dung lượng, các project đã chọn sandbox quay về chạy trên macOS cho tới khi tải lại.
- **Mac Intel**: runtime chỉ có cho Apple Silicon, nên mục này ghi `Requires a Mac with Apple Silicon`.


---

## 24. Cập Nhật GoLens (`GoLens ▸ Check for Updates…`)
- **Kiểm tra thủ công**: chọn **GoLens ▸ Check for Updates…** hoặc nút cùng tên trong **Settings ▸ General ▸ Updates**. GoLens hiện phiên bản mới, đường dẫn tới ghi chú phát hành, rồi tải, cài và mở lại khi bạn đồng ý.
- **Tự động**: bật **Check for Updates Automatically** để GoLens tự kiểm tra mỗi ngày một lần. Lần đầu mở app, GoLens hỏi bạn có muốn bật hay không.
- **An toàn**: mỗi bản cập nhật được ký EdDSA; GoLens từ chối bản tải về nếu chữ ký không khớp khóa có sẵn trong app, và chỉ cài bản được ký bằng cùng chứng chỉ với bản đang chạy.
- **Bản build tại máy**: app build bằng `make build` không có nguồn cập nhật nên hai nút trên bị vô hiệu kèm lời giải thích trong Settings.
