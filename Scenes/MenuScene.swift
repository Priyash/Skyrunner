import SpriteKit

final class MenuScene: SKScene {

    static func make(size: CGSize) -> MenuScene {
        let s = MenuScene(size: size)
        s.scaleMode = .aspectFill
        return s
    }

    override func didMove(to view: SKView) {
        Audio.shared.playMusic("theme_menu")
        // Sunset-candy gradient backdrop
        let sky = SKSpriteNode(texture: Painter.gradient(
            size: CGSize(width: 64, height: 256),
            colors: [
                UIColor(red: 1.00, green: 0.55, blue: 0.45, alpha: 1),
                UIColor(red: 0.75, green: 0.40, blue: 0.90, alpha: 1),
                UIColor(red: 0.25, green: 0.20, blue: 0.55, alpha: 1),
            ]))
        sky.size = CGSize(width: size.width * 1.2, height: size.height * 1.2)
        sky.position = CGPoint(x: size.width / 2, y: size.height / 2)
        sky.zPosition = -10
        addChild(sky)

        // Drifting clouds
        let cloudTex = Painter.cloud()
        for i in 0..<3 {
            let c = SKSpriteNode(texture: cloudTex)
            c.alpha = 0.35
            c.setScale(CGFloat.random(in: 0.6...1.0))
            c.position = CGPoint(x: CGFloat(i) * size.width / 2.5 + 60,
                                 y: size.height - CGFloat.random(in: 50...120))
            c.zPosition = -5
            addChild(c)
            c.run(.repeatForever(.sequence([
                .moveBy(x: 22, y: 0, duration: Double.random(in: 6...10)).eased(),
                .moveBy(x: -22, y: 0, duration: Double.random(in: 6...10)).eased(),
            ])))
        }

        // Bouncing rainbow title
        let title = "SKY RUNNER"
        let palette: [SKColor] = [
            SKColor(red: 1.0, green: 0.45, blue: 0.35, alpha: 1),
            SKColor(red: 1.0, green: 0.75, blue: 0.15, alpha: 1),
            SKColor(red: 0.45, green: 0.90, blue: 0.45, alpha: 1),
            SKColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1),
            SKColor(red: 0.80, green: 0.50, blue: 1.0, alpha: 1),
        ]
        let charWidth: CGFloat = 30
        let startX = size.width / 2 - charWidth * CGFloat(title.count - 1) / 2
        for (i, ch) in title.enumerated() {
            let l = SKLabelNode(fontNamed: "AvenirNext-Heavy")
            l.text = String(ch)
            l.fontSize = 46
            l.fontColor = palette[i % palette.count]
            l.position = CGPoint(x: startX + CGFloat(i) * charWidth, y: size.height - 86)
            addChild(l)
            l.run(.repeatForever(.sequence([
                .wait(forDuration: Double(i) * 0.09),
                .moveBy(x: 0, y: 9, duration: 0.32).eased(),
                .moveBy(x: 0, y: -9, duration: 0.32).eased(),
                .wait(forDuration: Double(title.count - i) * 0.09),
            ])))
        }

        // Coin balance
        let coinIcon = SKShapeNode(circleOfRadius: 9)
        coinIcon.fillColor = SKColor(red: 1.0, green: 0.80, blue: 0.12, alpha: 1)
        coinIcon.strokeColor = SKColor(red: 0.85, green: 0.55, blue: 0.02, alpha: 1)
        coinIcon.lineWidth = 2
        coinIcon.position = CGPoint(x: size.width / 2 - 34, y: size.height - 124)
        addChild(coinIcon)
        let coins = SKLabelNode(fontNamed: "AvenirNext-Bold")
        coins.text = "\(GameData.shared.coins)"
        coins.fontSize = 19
        coins.fontColor = .white
        coins.horizontalAlignmentMode = .left
        coins.verticalAlignmentMode = .center
        coins.position = CGPoint(x: size.width / 2 - 18, y: size.height - 124)
        addChild(coins)

        // Animated mascot
        let mascot = PlayerRigFactory.make()
        mascot.position = CGPoint(x: 80, y: size.height / 2 + 6)
        mascot.setScale(1.5)
        mascot.startAutoIdle()
        addChild(mascot)
        NormalMapper.applyRecursively(from: mascot, shadows: .none)

        // Level buttons — candy colored, gentle wobble
        let unlocked = GameData.shared.maxUnlockedLevel
        let count = Levels.all.count
        let spacing: CGFloat = 112
        let startBX = size.width / 2 - spacing * CGFloat(count - 1) / 2 + 40
        let buttonColors: [SKColor] = [
            SKColor(red: 0.98, green: 0.45, blue: 0.15, alpha: 1),
            SKColor(red: 0.20, green: 0.70, blue: 0.95, alpha: 1),
            SKColor(red: 0.55, green: 0.80, blue: 0.25, alpha: 1),
            SKColor(red: 0.85, green: 0.40, blue: 0.90, alpha: 1),
        ]
        // World-map path: dotted trail connecting the level nodes
        if count > 1 {
            let pathY = size.height / 2 + 6
            for i in 0..<(count - 1) {
                let fromX = startBX + CGFloat(i) * spacing + 43
                let toX = startBX + CGFloat(i + 1) * spacing - 43
                let dots = max(2, Int((toX - fromX) / 14))
                for d in 0..<dots {
                    let f = CGFloat(d) / CGFloat(max(1, dots - 1))
                    let dot = SKShapeNode(circleOfRadius: 3)
                    dot.fillColor = SKColor(white: 1, alpha: i < unlocked ? 0.85 : 0.25)
                    dot.strokeColor = .clear
                    dot.position = CGPoint(x: fromX + (toX - fromX) * f,
                                           y: pathY + CGFloat(sin(Double(f) * .pi)) * 10)
                    dot.zPosition = -1
                    addChild(dot)
                }
            }
        }
        for i in 0..<count {
            let locked = i > unlocked
            let b = SKShapeNode(rectOf: CGSize(width: 86, height: 86), cornerRadius: 22)
            b.fillColor = locked ? SKColor(white: 0.35, alpha: 1) : buttonColors[i % buttonColors.count]
            b.strokeColor = SKColor(white: 1, alpha: locked ? 0.2 : 0.85)
            b.lineWidth = 3.5
            b.position = CGPoint(x: startBX + CGFloat(i) * spacing, y: size.height / 2 + 6)
            b.name = locked ? nil : "level.\(i)"
            let l = SKLabelNode(fontNamed: "AvenirNext-Heavy")
            l.text = locked ? "🔒" : "\(i + 1)"
            l.fontSize = 34
            l.verticalAlignmentMode = .center
            l.name = b.name
            b.addChild(l)
            // The level's own title, under its node. Levels earned names when
            // they became files; a row of numbered squares told the player
            // nothing about where they were going.
            if !locked, i < Levels.titles.count {
                let caption = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
                caption.text = Levels.titles[i]
                caption.fontSize = 12
                caption.fontColor = SKColor(white: 1, alpha: 0.9)
                caption.verticalAlignmentMode = .center
                caption.horizontalAlignmentMode = .center
                caption.position = CGPoint(x: 0, y: -60)
                // Long titles would collide with the neighbouring node.
                if caption.frame.width > spacing - 12 {
                    caption.fontSize *= (spacing - 12) / caption.frame.width
                }
                b.addChild(caption)
            }
            addChild(b)
            if !locked {
                b.run(.repeatForever(.sequence([
                    .wait(forDuration: Double(i) * 0.3),
                    .rotate(toAngle: 0.05, duration: 0.8).eased(),
                    .rotate(toAngle: -0.05, duration: 0.8).eased(),
                    .rotate(toAngle: 0, duration: 0.4).eased(),
                ])))
            }
        }

        // IAP row
        addChild(pill(name: "iap.removeads",
                      text: GameData.shared.adsRemoved ? "Ads Removed ✓" : "Remove Ads",
                      at: CGPoint(x: size.width / 2 - 130, y: 70)))
        addChild(pill(name: "iap.coins",
                      text: "Buy 500 Coins",
                      at: CGPoint(x: size.width / 2 + 130, y: 70)))
        addChild(pill(name: "iap.restore",
                      text: "Restore Purchases",
                      at: CGPoint(x: size.width / 2, y: 24), small: true))
    }

    private func pill(name: String, text: String, at pos: CGPoint, small: Bool = false) -> SKNode {
        let b = SKShapeNode(rectOf: CGSize(width: small ? 200 : 220, height: small ? 34 : 46),
                            cornerRadius: small ? 17 : 23)
        b.fillColor = SKColor(white: 1, alpha: 0.14)
        b.strokeColor = SKColor(red: 1.0, green: 0.85, blue: 0.35, alpha: 0.8)
        b.lineWidth = 2.5
        b.position = pos
        b.name = name
        let l = SKLabelNode(fontNamed: "AvenirNext-Bold")
        l.text = text
        l.fontSize = small ? 14 : 17
        l.fontColor = .white
        l.verticalAlignmentMode = .center
        l.name = name
        b.addChild(l)
        return b
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        for node in nodes(at: location) {
            guard let name = node.name else { continue }
            if name.hasPrefix("level.") {
                Audio.shared.play("menu", on: self)
                let idx = Int(name.dropFirst("level.".count)) ?? 0
                view?.presentScene(GameScene(levelIndex: idx),
                                   transition: .fade(withDuration: 0.4))
                return
            }
            switch name {
            case "iap.removeads":
                Task { await StoreManager.shared.purchase(productID: ProductID.removeAds) }
                return
            case "iap.coins":
                Task { await StoreManager.shared.purchase(productID: ProductID.coins500) }
                return
            case "iap.restore":
                Task { await StoreManager.shared.restorePurchases() }
                return
            default:
                break
            }
        }
    }
}
