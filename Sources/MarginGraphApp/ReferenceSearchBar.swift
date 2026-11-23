import SwiftUI

struct ReferenceSearchBar<Field: View>: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    @ViewBuilder let field: () -> Field

    var body: some View {
        HStack(spacing: 4) {
            field()
                .textFieldStyle(.plain)
                .focused(focus)

            if !text.isEmpty {
                Button {
                    text = ""
                    focus.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(minHeight: 22)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focus.wrappedValue ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: focus.wrappedValue ? 2 : 1)
                .allowsHitTesting(false)
        }
    }
}
