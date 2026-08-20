import SwiftUI
import SpriteKit

@main
struct PlatformerApp: App {
    var body: some Scene {
        WindowGroup {
            GameContainerView()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct GameContainerView: View {
    var body: some View {
        GeometryReader { geo in
            SpriteView(
                scene: MenuScene.make(size: CGSize(width: 844, height: 390)),
                options: [.ignoresSiblingOrder]
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
    }
}
