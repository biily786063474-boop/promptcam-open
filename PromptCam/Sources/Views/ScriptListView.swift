import SwiftUI
import SwiftData

struct ScriptListView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Script.updatedAt, order: .reverse) private var scripts: [Script]

    /// 选中后回传给相机页
    let onPick: (Script) -> Void

    @State private var editing: Script?

    var body: some View {
        NavigationStack {
            Group {
                if scripts.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Theme.bgBase)
            .navigationTitle("脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .tint(Theme.fgMuted)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .tint(Theme.fgMuted)

                    Button {
                        let s = Script()
                        context.insert(s)
                        editing = s
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Theme.accent)
                }
            }
            .sheet(item: $editing) { s in
                ScriptEditorView(script: s)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 列表

    private var list: some View {
        List {
            ForEach(scripts) { s in
                Button {
                    onPick(s)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(s.displayTitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.fg)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Text("\(s.unitCount) 字")
                            Text("·")
                            Text(s.estimatedDurationText)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fgMuted)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .listRowBackground(Theme.bgElevated)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        context.delete(s)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        editing = s
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(Theme.accent)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.fgMuted)
            Text("还没有脚本")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.fg)
            Text("点右上角 + 新建,或用剪贴板图标\n直接粘贴一段稿子进来")
                .font(.system(size: 13))
                .foregroundStyle(Theme.fgMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 剪贴板

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Haptic.warning()
            return
        }
        let s = Script(content: text)
        context.insert(s)
        Haptic.success()
    }
}
