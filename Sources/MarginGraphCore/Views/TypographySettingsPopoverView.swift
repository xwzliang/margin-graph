import SwiftUI

public struct TypographySettingsPopoverView: View {
    public var documentMD5: String
    public var onApply: (TypographyOptions) -> Void

    @State private var options: TypographyOptions
    @State private var isApplying: Bool = false

    public init(documentMD5: String, onApply: @escaping (TypographyOptions) -> Void) {
        self.documentMD5 = documentMD5
        self.onApply = onApply
        _options = State(initialValue: TypographyPreferences.shared.options(forDocumentMD5: documentMD5))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Label("Reading Appearance", systemImage: "textformat.size")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button("Reset") {
                    let def = TypographyOptions.default
                    options = def
                    TypographyPreferences.shared.resetOptions(forDocumentMD5: documentMD5)
                    triggerApply(def)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            }

            Divider()

            // 1. Font Size Control
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Size")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(options.fontSize.rounded())) pt")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 8) {
                    Button {
                        adjustFontSize(by: -1)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                            .font(.system(size: 12))
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .disabled(options.fontSize <= 11)

                    Slider(
                        value: Binding(
                            get: { options.fontSize },
                            set: { newVal in
                                options.fontSize = newVal
                            }
                        ),
                        in: 11...26,
                        step: 1
                    ) { editing in
                        if !editing {
                            triggerApply(options)
                        }
                    }

                    Button {
                        adjustFontSize(by: 1)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .font(.system(size: 12))
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .disabled(options.fontSize >= 26)
                }
            }

            // 2. Line Spacing Control
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Line Spacing")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2fx", options.lineSpacing))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                Picker("Line Spacing", selection: Binding(
                    get: { options.lineSpacing },
                    set: { newVal in
                        options.lineSpacing = newVal
                        triggerApply(options)
                    }
                )) {
                    Text("1.25x").tag(CGFloat(1.25))
                    Text("1.50x").tag(CGFloat(1.50))
                    Text("1.75x").tag(CGFloat(1.75))
                    Text("2.00x").tag(CGFloat(2.00))
                }
                .pickerStyle(.segmented)
            }

            // 3. Font Style Control
            VStack(alignment: .leading, spacing: 6) {
                Text("Font Family")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("Font Family", selection: Binding(
                    get: { options.fontStyle },
                    set: { newVal in
                        options.fontStyle = newVal
                        triggerApply(options)
                    }
                )) {
                    ForEach(TypographyOptions.FontStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Status Note
            HStack {
                Text("Reflowable eBook Format")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if isApplying {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 280)
    }

    private func adjustFontSize(by delta: CGFloat) {
        let newSize = max(11.0, min(26.0, (options.fontSize + delta).rounded()))
        guard newSize != options.fontSize else { return }
        options.fontSize = newSize
        triggerApply(options)
    }

    private func triggerApply(_ newOptions: TypographyOptions) {
        isApplying = true
        onApply(newOptions)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isApplying = false
        }
    }
}
