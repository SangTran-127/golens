import SwiftUI

struct ListDetailSheet<SelectionValue: Hashable, Rows: View, SidebarAccessory: View, Detail: View, EmptyDetail: View, Banner: View, FooterLeading: View>: View {
    @Binding var selection: SelectionValue?
    let listTitle: String
    let addTitle: String
    let removeTitle: String
    let showsDetail: Bool
    let size: SheetSize
    let onAdd: () -> Void
    let onRemove: (SelectionValue) -> Void
    let onCancel: () -> Void
    let onDone: () -> Void
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let sidebarAccessory: () -> SidebarAccessory
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let emptyDetail: () -> EmptyDetail
    @ViewBuilder let banner: () -> Banner
    @ViewBuilder let footerLeading: () -> FooterLeading

    init(
        selection: Binding<SelectionValue?>,
        listTitle: String,
        addTitle: String,
        removeTitle: String,
        showsDetail: Bool,
        size: SheetSize = .splitInspector,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (SelectionValue) -> Void,
        onCancel: @escaping () -> Void,
        onDone: @escaping () -> Void,
        @ViewBuilder rows: @escaping () -> Rows,
        @ViewBuilder sidebarAccessory: @escaping () -> SidebarAccessory = { EmptyView() },
        @ViewBuilder detail: @escaping () -> Detail,
        @ViewBuilder emptyDetail: @escaping () -> EmptyDetail,
        @ViewBuilder banner: @escaping () -> Banner = { EmptyView() },
        @ViewBuilder footerLeading: @escaping () -> FooterLeading = { EmptyView() }
    ) {
        self._selection = selection
        self.listTitle = listTitle
        self.addTitle = addTitle
        self.removeTitle = removeTitle
        self.showsDetail = showsDetail
        self.size = size
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onCancel = onCancel
        self.onDone = onDone
        self.rows = rows
        self.sidebarAccessory = sidebarAccessory
        self.detail = detail
        self.emptyDetail = emptyDetail
        self.banner = banner
        self.footerLeading = footerLeading
    }

    var body: some View {
        VStack(spacing: 0) {
            banner()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 232)
                Divider()
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: Spacing.standard) {
                footerLeading()
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.section)
        }
        .sheetFrame(size)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section(listTitle) {
                    rows()
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 0) {
                ListDetailBarButton(title: addTitle, symbol: "plus", action: onAdd)
                ListDetailBarButton(title: removeTitle, symbol: "minus") {
                    if let selection { onRemove(selection) }
                }
                .disabled(selection == nil)
                Spacer()
                sidebarAccessory()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.compact)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if showsDetail {
            detail()
        } else {
            emptyDetail()
        }
    }
}

struct ListDetailBarButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Spacing.content, height: Spacing.content)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}
