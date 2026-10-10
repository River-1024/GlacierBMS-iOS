import SwiftUI

@MainActor
struct RangeSettingsView: View {
    @EnvironmentObject private var range: RangeService
    @State private var capacityText = ""
    @State private var validationError: String?
    @State private var confirmingReset = false
    @FocusState private var editingCapacity: Bool

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("额定容量")
                    TextField("尚未设置", text: $capacityText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($editingCapacity)
                        .accessibilityIdentifier("range.capacity")
                    Text("Ah").foregroundStyle(.secondary)
                }
                Button("保存本设备容量") { saveCapacity() }
                    .disabled(range.deviceID == nil)
                if let error = validationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("设备参数")
            } footer: {
                Text("请填写电池真实额定容量；不会预填假定的 100 Ah。容量按稳定外设 UUID 保存，仅修改本设备。")
            }
            Section {
                Text(range.deviceID?.uuidString ?? "未绑定设备：等待主线程接入稳定外设 UUID。")
                    .font(.caption).textSelection(.enabled)
                Button("重置本设备续航设置与窗口", role: .destructive) {
                    confirmingReset = true
                }
                .disabled(range.deviceID == nil)
            } footer: {
                Text("重置后须重新设置容量并积累行驶窗口；不会删除其他设备设置、行程记录或已导出文件。")
            }
        }
        .navigationTitle("续航设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadCapacity() }
        .onChange(of: range.deviceID) { _ in
            confirmingReset = false
            editingCapacity = false
            reloadCapacity()
        }
        .confirmationDialog("重置当前设备续航？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("重置", role: .destructive) {
                editingCapacity = false
                range.reset()
                reloadCapacity()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除当前设备的额定容量设置与有效窗口，不能撤销。")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { editingCapacity = false }
            }
        }
    }

    private func reloadCapacity() {
        capacityText = range.nominalCapacityAh > 0 ? range.nominalCapacityAh.formatted(.number) : ""
        validationError = nil
    }
    private func saveCapacity() {
        // 与本地化显示格式一致（例如小数逗号地区），也接受普通点号输入。
        let text = capacityText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = (try? Double(text, format: .number)) ?? Double(text), value.isFinite, value > 0 else {
            validationError = "请输入大于零的有效容量（Ah）"
            return
        }
        guard range.updateNominalCapacityAh(value) else {
            validationError = range.lastError
            return
        }
        editingCapacity = false
        reloadCapacity()
    }
}
