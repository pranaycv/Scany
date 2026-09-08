import PDFKit
import SwiftUI
import UIKit

struct PDFPreviewView: View {
    let url: URL
    var title: String = "PDF"
    var onClose: () -> Void

    var body: some View {
        navigationContainer {
            PDFKitRepresentedView(url: url)
                .background(ScanyTheme.ink)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .scanyToolbarChrome()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: onClose)
                    }
                }
        }
    }

    @ViewBuilder
    private func navigationContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

struct PDFKitRepresentedView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1)
        view.usePageViewController(false)
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
