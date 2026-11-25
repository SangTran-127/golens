import SwiftUI
import AppKit

struct ImagePreviewView: View {
    let path: String
    @State private var dimensions: CGSize = .zero
    @State private var fileSize: Int64 = 0
    @Environment(\.windowWorkspace) private var workspace
    
    var body: some View {
        VStack(spacing: Spacing.section) {
            Spacer()
            
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400, maxHeight: 400)
                    .padding(Spacing.standard)
                    .background(CheckerboardPattern().opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.1), radius: 6, x: 0, y: 3)
            } else {
                Text("Error loading image asset")
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: Spacing.compact) {
                Text((path as NSString).lastPathComponent)
                    .font(.callout.weight(.bold).monospaced())
                    .foregroundStyle(ThemeColor.textPrimary)
                
                Text("\(Int(dimensions.width)) x \(Int(dimensions.height)) • \(formattedFileSize)")
                    .font(.subheadline)
                    .foregroundStyle(ThemeColor.textSecondary)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.contentSurface)
        .onAppear {
            loadImageMetadata()
        }
    }
    
    private var formattedFileSize: String {
        UserMessage.byteCount(fileSize)
    }
    
    private func loadImageMetadata() {
        if let nsImage = NSImage(contentsOfFile: path) {
            dimensions = nsImage.size
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }
    }
}

struct CheckerboardPattern: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let squareSize: CGFloat = 16
                
                for y in stride(from: 0, to: height, by: squareSize) {
                    for x in stride(from: 0, to: width, by: squareSize) {
                        if (Int(x / squareSize) + Int(y / squareSize)) % 2 == 0 {
                            path.addRect(CGRect(x: x, y: y, width: squareSize, height: squareSize))
                        }
                    }
                }
            }
            .fill(Color.secondary)
        }
    }
}
