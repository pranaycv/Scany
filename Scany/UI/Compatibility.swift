import SwiftUI
import UIKit

/// View helpers so the app builds and runs on iOS 15+ (iPhone 12 class)
/// without relying on iOS 17-only SwiftUI APIs.
extension View {
    /// `onChange` with a single new-value callback. iOS 17's two-parameter form
    /// is used when available; iOS 15–16 get the older API.
    @ViewBuilder
    func scanyOnChange<Value: Equatable>(
        of value: Value,
        perform: @escaping (Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, newValue in
                perform(newValue)
            }
        } else {
            onChange(of: value, perform: perform)
        }
    }

    @ViewBuilder
    func scanyHideListBackground() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            onAppear {
                UITableView.appearance().backgroundColor = .clear
            }
        }
    }

    @ViewBuilder
    func scanyToolbarChrome() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func scanyNavigationDestination<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *) {
            navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            self
        }
    }
}
