import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let theme = model.theme
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HeaderBar()
                HStack(spacing: 0) {
                    SidebarView()
                    ThreadListView()
                    ReaderPane()
                }
                .frame(maxHeight: .infinity)
                StatusBar()
            }
            // The header sits under the transparent title bar, with the traffic lights inside it.
            .ignoresSafeArea(.container, edges: .top)
            .background(backdrop(theme))

            if let compose = model.compose {
                ComposeView(compose: compose)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.opacity)
            }
            OverlayHost()
                .ignoresSafeArea(.container, edges: .top)
            ToastView()
        }
        .environment(\.theme, theme)
        .preferredColorScheme(theme.palette.isDark ? .dark : .light)
        .tint(theme.green)
        .frame(minWidth: 1040, minHeight: 640)
        .background(WindowConfigurator(headerHeight: 70, background: theme.background))
        .animation(.easeOut(duration: 0.15), value: model.overlay)
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .animation(.easeOut(duration: 0.15), value: model.compose == nil)
    }

    /// The design's soft corner gradients behind the translucent panes.
    private func backdrop(_ theme: Theme) -> some View {
        ZStack {
            theme.background
            EllipticalGradient(colors: [theme.greenSoft, theme.greenSoft.opacity(0)], center: .topLeading, startRadiusFraction: 0, endRadiusFraction: 0.75)
            EllipticalGradient(colors: [theme.orangeSoft, theme.orangeSoft.opacity(0)], center: .bottomTrailing, startRadiusFraction: 0, endRadiusFraction: 0.75)
        }
        .ignoresSafeArea()
    }
}
