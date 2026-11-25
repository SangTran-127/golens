# GoLens Design & Mascot Asset Kit (`design/`)

Bộ tài nguyên thiết kế chuẩn hóa của **GoLens (Native macOS Go IDE)** — được dùng trực tiếp trong app macOS (`desktop/Resources/`).

---

## 1. Cấu trúc thư mục (`design/`)

```text
design/
├── README.md                  # Tài liệu hướng dẫn tổng thể & quy chuẩn thiết kế
├── app-icon/                  # Nguồn sinh GoLens.icon (Assets.car), GoLens.icns và 4 icon theo mùa (Boba Milk Tea Gopher)
├── mascot/                    # Unified 2D Cel-Shaded Concept Studio (studio_art.py, studio.html, preview/), Audit 1:1 (audit.html) & Duckoo Library (duckoo-library/index.html)
├── file-icons/                # Nguồn sinh 37 File/Folder Icons & 36 Seasonal Gopher (tools/build.py, tools/gopher.py)
└── symbol-icons/              # Nguồn sinh 11 AST Symbol Icons & 7 Empty-State Badges (tools/build.py, tools/icons.py)
```

---

## 2. Quy tắc thiết kế cốt lõi (Design Rules)

### 2.1. Quy tắc 80/20 Go Cyan Core
- **80% Nhận diện cốt lõi giữ nguyên màu Xanh Go Cyan (`#4CC9EB` trên nền tối / `#007A99` trên nền sáng)**:
  - Thân chú chuột túi **Gopher** trên mọi icon (`.go`, `_test.go`, generated Go) luôn giữ màu xanh Go Cyan đặc trưng. App Icon là wordmark "Go" (chữ "o" là kính lúp) trên nền Go Cyan.
  - Các token Go cốt lõi (`func`, `method`, `go.mod`, `go.sum`, `go.work`, `pprof`, `builtin`) luôn giữ màu xanh Go Cyan để lập trình viên Go nhận diện bằng phản xạ thị giác trong `0.1s`.
- **20% Phụ kiện & Nhóm vệ tinh biến hóa theo Chủ đề / Mùa (`Seasonal & Theme Accents`)**:
  - Phụ kiện trên đầu Gopher thay đổi theo mùa:
    - **Halloween**: Mũ phù thủy tím thạch anh (`#B366FF`) + đai vàng cam (`#FF9F43`) + răng nanh.
    - **Noel**: Mũ ông già Noel đỏ (`#F04754`) + viền bông tuyết trắng (`#FFFFFF`) + má hồng + huy hiệu bông tuyết.
    - **Lunar New Year (Tết)**: Khăn đóng / Mão Trạng nguyên đỏ thắm (`#F04754`) + đai gấm & đồng kim tiền vàng (`#FFD166`) + huy hiệu hoa mai 5 cánh.
    - **Hacker**: Kính gọng dày lập trình viên phản chiếu dòng code Go Cyan.
  - Các nhóm icon vệ tinh (`data/type`, `infra/property`, `web/package`, `neutral/folder`) tự động lấy màu ngữ nghĩa của Theme đang chọn.

### 2.2. Chuẩn độ tương phản WCAG 2.1 (Không bao giờ bị chìm màu trên nền tối)
- Toàn bộ 10 themes (`Xcode Light/Dark`, `Tokyo Night`, `Catppuccin Mocha`, `GitHub Dark`, `Dracula`, `One Dark`, `Monokai`, `Halloween`, `Noel`, `Lunar New Year`) và mọi lớp màu icon đều được kiểm định tự động qua `scripts/smoke/gate5-audit.py`:
  - Văn bản chính (`text`): **`>= 4.5:1`** (thực tế đạt `7.5:1 – 15.8:1`).
  - Đồ họa Icon & từng lớp phụ kiện Gopher (`go-core`, `data`, `infra`, `web`, `neutral`, `witch-hat`, `santa-cap`, `tet-hat`): **`>= 3.0:1`** theo chuẩn WCAG 1.4.11 Non-Text Contrast.

### 2.3. Unified 2D Cel-Shaded Mascot & Scene Concept Studio (POP MART Duckoo x Go Gopher)
- **Thống nhất một phong cách duy nhất (owner-approved 2026-11-15)**: 100% bảng concept art trong `design/mascot/studio.html` dùng phong cách **2D hand-illustrated comic-ink & cel-shaded** (viền `#16283A`, tô bóng cel 2 tông) kết hợp tỷ lệ Go Gopher chuẩn của Renée French (CC BY 4.0) với tư duy biến hóa thế giới **POP MART Duckoo**. Các bảng SVG hình học ghép thô trước đây (`studio-*-board.png`, `renders/studio/*.svg`) đã bị loại bỏ hoàn toàn.
- **Bảng màu Cast 7 nhân vật (`CAST_PALETTES` trong `design/mascot/studio_art.py`)**:
  - `Lens` (`cyan` `#6AD3EC`), `Coral` (`pink` `#F5A3B7`), `Sunny` (`yellow` `#F7D469`), `Mint` (`mint` `#7CE0B8`), `Cosmo` (`lavender` `#B9A4F4`), `Rocky` (`slate` `#94B4C8`), `Mocha` (`brown` `#C69C72`).
- **3 Series chính thức (12 Bảng · 53 Panels)**:
  - **Series 01 · POP MART Duckoo-Inspired Creative Universe**: `duckoo-series-blindbox.png`, `duckoo-cosplay-icons.png`, `duckoo-diorama-badges.png`, `duckoo-ide-worlds.png`.
  - **Series 02 · POP MART Duckoo Expansion**: `duckoo-series02-blindbox.png`, `duckoo-festival-icons.png`, `duckoo-adventure-badges.png`, `duckoo-ide-worlds-v2.png`.
  - **Series 03 · GopherCon Heritage & Classic Edition**: `artist-mascot-icons.png`, `artist-wardrobe-cast.png`, `artist-gophercon-badges.png`, `artist-ide-backgrounds.png`.
- **8 Cổng Kiểm Định Giải Phẫu & Chống AI-Slop ở Tỷ Lệ 1:1 (`G1`–`G8` trong `scripts/design/gopher-art-audit.py`)**:
  - `G1_NO_LONG_LEGS`: Thân hình quả lê/khoai tây tròn lẳn không chân (`1:1.15`); tuyệt đối không có đùi, đầu gối, ống quyển hay ngón chân người; 2 bàn chân oval nhỏ gắn trực tiếp dưới đáy bụng kể cả khi ngồi.
  - `G2_HEAD_BODY_SYNC`: Hướng xoay của đầu và thân nhất quán (không vặn cổ 180 độ nhìn ngược lưng).
  - `G3_TWO_ARMS_MAX`: Tối đa đúng 2 tay/chi ngắn trên mỗi Gopher.
  - `G4_EYES_TOUCHING`: Hai mắt tròn trắng kích thước lớn chạm nhau (hoặc gần chạm nhau) tại sống mũi (`OO`) kèm tai tròn nhỏ phía trên đỉnh đầu.
  - `G5_PEANUT_MUZZLE`: Mõm hạt đậu hai thùy màu be với mũi bầu dục tối màu và 2 răng cửa trắng bo tròn.
  - `G6_PROP_PHYSICS`: Laptop xoay màn hình về phía Gopher đang gõ; đạo cụ nối khớp tự nhiên với tay.
  - `G7_PEAR_SILHOUETTE`: Giữ tỷ lệ phom dáng quả lê `1:1.15` đồng nhất qua mọi trang phục và tư thế.
  - `G8_CLEAN_TEXT_ICONS`: Chữ sắc nét dễ đọc, không chữ AI biến dạng, không logo bên thứ ba (như logo Apple), không vạch đen dọc cắt ngang khung cảnh, không sử dụng emoji.

---

## 3. Lệnh Build & Cập nhật Bộ Tài Nguyên

Khi chỉnh sửa bất kỳ hình vẽ vector hoặc bảng màu nào trong `design/`, chạy các lệnh sau để đồng bộ toàn bộ từ nguồn sang `desktop/Resources/`:

```zsh
# 1. Sinh lại File Icons + 36 Seasonal Gopher PDFs/SVGs
/tmp/golens-icons-venv/bin/python design/file-icons/tools/build.py
cp design/file-icons/template/*.pdf desktop/Resources/FileIcons/

# 2. Sinh lại AST Symbol Icons + 7 Empty-State 2-Layer Hero Badges
/tmp/golens-icons-venv/bin/python design/symbol-icons/tools/build.py
cp design/symbol-icons/template/sym-*.pdf desktop/Resources/SymbolIcons/
cp design/symbol-icons/template/empty-*.pdf desktop/Resources/EmptyStates/

# 3. Sinh lại App Icon chính và 4 icon theo mùa (Halloween, Noel, Tết, Hacker) — cần Xcode 26 (actool)
python3 design/app-icon/build-icon-layers.py && scripts/make-app-icon.sh
python3 design/app-icon/build-seasonal-icons.py

# 4. Chạy kiểm định WCAG Gate 5
python3 scripts/smoke/gate5-audit.py

# 5. Sinh lại Mascot & Scene Concept Studio (studio.html) và cắt 53 ảnh cận cảnh 1:1 cho bảng Audit (audit.html)
python3 design/mascot/studio_art.py
python3 scripts/design/gopher-art-audit.py

# 6. Sinh lại Welcome Art Concept 2 (5 huy hiệu diorama tròn + 4 canvas Light/Dark/High Contrast < 400 KB) vào desktop/Resources/WelcomeArt/
python3 design/mascot/build_welcome_art.py

# 7. Đóng gói & cập nhật thư viện Duckoo-inspired Go Gopher (design/mascot/duckoo-library/index.html + catalog.json + README.md)
python3 design/mascot/build_duckoo_library.py
```

---

## 4. Bản quyền & Ghi công (Licensing & Attribution)

- **Biểu tượng File, Folder, Go AST Symbols & Empty-State Hero Badges**: Thiết kế vector nguyên bản (Original vector artwork) vẽ riêng cho GoLens trên lưới `32×32` (`16pt`).
- **Nhân vật Go Gopher**: Thiết kế gốc bởi **Renée French**, phát hành theo giấy phép [Creative Commons Attribution 4.0 (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).
- **App Icon (`GoLens.icns`, `GoLens.icon`) và icon theo mùa (`golens-icon-*.png`)**: `GoLens.icon` dùng minh họa **Boba Milk Tea Gopher** 2D cel-shaded trong Icon Composer với Liquid Glass (dựa trên Go Gopher của Renée French, CC BY 4.0); các icon theo mùa phát triển trên cùng phong cách 2D cel-shaded.
- **Concept Studio 2D Cel-Shaded (`design/mascot/studio_art.py`, `design/mascot/preview/*.png`) & Welcome Art (`desktop/Resources/WelcomeArt/`, `design/mascot/build_welcome_art.py`)**: Tác phẩm minh họa 2D diorama và studio canvas phát triển dựa trên Go Gopher của Renée French (CC BY 4.0), đã ghi công trong hộp thoại **About GoLens**.
