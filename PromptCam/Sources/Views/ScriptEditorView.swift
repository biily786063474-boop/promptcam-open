import SwiftUI
import SwiftData

struct ScriptEditorView: View {

    @Bindable var script: Script

    @Environment(\.dismiss) private var dismiss
    @FocusState private var contentFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("标题（留空则用首行）", text: $script.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)

                Divider().overlay(Theme.border)

                TextEditor(text: $script.content)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.fg)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 14)
                    .focused($contentFocused)
                    .overlay(alignment: .topLeading) {
                        if script.content.isEmpty {
                            Text("把口播稿贴进来…")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.fgMuted.opacity(0.6))
                                .padding(.horizontal, 19)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }

                footer
            }
            .background(Theme.bgBase)
            .navigationTitle("编辑脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        script.updatedAt = Date()
                        dismiss()
                    }
                    .tint(Theme.accent)
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("收起键盘") { contentFocused = false }
                            .tint(Theme.accent)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(script.unitCount) 字")
            Text("·")
            Text(script.estimatedDurationText)
            Spacer()
            Text("\(ScriptTokenizer.parse(script.content).sentences.count) 句")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.fgMuted)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.bgElevated)
    }
}
