# Changelog

## 2026-06-26 — Split-State Bug Fixes & Performance

### Critical Bugs Fixed

#### 1. Autosuggestion không hoạt động
- **Root cause:** `performCompletionQuery()` ghi vào `WorkspaceState.completions` (cũ) nhưng views đọc từ `workspace.lsp.completions` (LSPState mới)
- **Fix:** Redirect 12 writes from `self.xxx` → `self.lsp.xxx` (completions, selectedCompletionIndex, isShowingCompletions, completionsRect, signatureHelp, hoverText)

#### 2. Git status không hiển thị
- **Root cause:** `refreshGitStatus()` ghi vào `WorkspaceState.gitChangedFiles` (cũ) nhưng views đọc từ `workspace.git.changedFiles` (GitState mới)
- **Fix:** Redirect 20+ writes from `self.gitXxx` → `self.git.xxx` (changedFiles, statusMap, branchName, branches, activeFileDiffs)

#### 3. Debug button không hoạt động
- **Root cause:** `debugProject()` là empty stub `{}`
- **Fix:** Khôi phục code start debug + thêm `RegisterDebugEventCallback` + `handleDebugEvent`

#### 4. Console không tự bật khi RUN
- **Root cause:** `runProject()` thiếu `showConsole = true`
- **Fix:** Thêm `showConsole = true` vào `runProject()`

#### 5. Terminal không nhận input
- Không phải bug — terminal cần Nerd Font để hoạt động. Font fallback chain đã có sẵn.

### Performance Fixes

#### 1. Xóa 13 `print("[Velo Debug]")`
- Mỗi lần gõ phím chạy 3-5 `print()` (I/O đồng bộ ~1-5ms/call)
- Xóa khỏi `performCompletionQuery()`, `updateCaretRect()`

#### 2. Trim logs/consoleOutput
- `appendLog()` giới hạn 2000 entries, giữ 1000 cuối
- Ngăn memory leak trong debug session dài

#### 3. URL(fileURLWithPath:) → NSString
- 6 chỗ trong body view thay bằng `(path as NSString).lastPathComponent/pathExtension`

### Files Modified
| File | Changes |
|------|---------|
| `WorkspaceState.swift` | ~50 edits: fix split-state writes, restore debug, remove prints, add log trim |
| `SubStates.swift` | 1 edit: thêm `previousConsoleTab` vào LSPState |
| `NativeEditorView.swift` | 1 edit: URL → NSString |
| `GitDiffView.swift` | 1 edit: URL → NSString |
| `WelcomeView.swift` | 1 edit: URL → NSString |
| `SidebarView.swift` | 1 edit: URL → NSString |
| `RecentFilesPopupView.swift` | 2 edits: URL → NSString |
| `RenameSymbolPopupView.swift` | 1 edit: xóa print |
