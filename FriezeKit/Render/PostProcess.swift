import SpriteKit

/// Post-processing: the stage between "the scene is drawn" and "the player sees
/// it". Bloom, colour grading, vignette, chromatic aberration, and a screen
/// distortion for impacts.
///
/// Why it matters more here than it sounds. Painted 2D art reads as *cheap*
/// without a post chain, because every element sits at exactly the value it was
/// painted at — nothing blooms, nothing ties the palette together, nothing falls
/// off at the frame edge. A Rayman frame is unified by its grade and its
/// backlight bloom far more than by any individual asset. This is the highest
/// visual return per line in the engine.
///
/// Implementation shape, and the constraint that drives it: SpriteKit gives one
/// hook — `SKEffectNode` with an `SKShader` — so the chain has to be a *single*
/// fragment pass over the composited frame rather than a sequence of render
/// targets. That rules out a true multi-tap Gaussian bloom, so the bloom here is
/// a cheap 4-tap bright-pass, which at 2D scale is indistinguishable from the
/// expensive one. Everything is uniform-driven, so a grade can be animated and
/// the whole chain costs one draw.
final class PostProcess: SKEffectNode {

    /// A named look. Levels select one, so a cave and a sunlit grove are graded
    /// differently without touching code.
    struct Grade {
        var exposure: CGFloat = 1.0
        /// Multiplied per channel — this is the whole colour identity of a level.
        var tint: SKColor = .white
        var contrast: CGFloat = 1.0
        var saturation: CGFloat = 1.0
        /// Bloom threshold and strength. Threshold near 0.7 catches the backlight
        /// and highlights without smearing mid-tones into mush.
        var bloomThreshold: CGFloat = 0.68
        var bloomStrength: CGFloat = 0.55
        var bloomRadius: CGFloat = 2.4      // in points
        var vignette: CGFloat = 0.28
        /// Chromatic aberration at the frame edge, in points. Small values only:
        /// this is a lens hint, not an effect.
        var aberration: CGFloat = 0.6

        static let neutral = Grade(bloomStrength: 0, vignette: 0, aberration: 0)

        /// Warm, bright, gentle contrast — the daylight jungle look.
        static let grove = Grade(exposure: 1.06,
                                 tint: SKColor(red: 1.02, green: 1.0, blue: 0.94, alpha: 1),
                                 contrast: 1.05, saturation: 1.08,
                                 bloomThreshold: 0.64, bloomStrength: 0.62,
                                 bloomRadius: 2.8, vignette: 0.26, aberration: 0.6)

        /// Cooler, deeper, more contrast — thorns and shade.
        static let hollow = Grade(exposure: 0.98,
                                  tint: SKColor(red: 0.94, green: 0.99, blue: 1.04, alpha: 1),
                                  contrast: 1.12, saturation: 0.96,
                                  bloomThreshold: 0.72, bloomStrength: 0.45,
                                  bloomRadius: 2.2, vignette: 0.36, aberration: 0.8)

        /// Evening: warm highlights, crushed shadows, heavy vignette.
        static let evening = Grade(exposure: 0.94,
                                   tint: SKColor(red: 1.06, green: 0.96, blue: 0.88, alpha: 1),
                                   contrast: 1.16, saturation: 1.02,
                                   bloomThreshold: 0.58, bloomStrength: 0.72,
                                   bloomRadius: 3.2, vignette: 0.42, aberration: 0.9)

        /// Boss arena: desaturated, hard, cold.
        static let arena = Grade(exposure: 0.96,
                                 tint: SKColor(red: 1.0, green: 0.96, blue: 0.98, alpha: 1),
                                 contrast: 1.22, saturation: 0.82,
                                 bloomThreshold: 0.74, bloomStrength: 0.5,
                                 bloomRadius: 2.0, vignette: 0.44, aberration: 1.2)

        static let named: [String: Grade] = [
            "neutral": .neutral, "grove": .grove, "hollow": .hollow,
            "evening": .evening, "arena": .arena,
        ]
    }

    private(set) var grade: Grade = .grove
    private var sceneSize: CGSize = .zero

    /// Transient screen shake/distortion, decayed each frame. Driven by impacts,
    /// so a ground pound bends the whole frame for a moment.
    private var punch: CGFloat = 0
    private var punchDecay: CGFloat = 6

    /// Uniforms are held rather than recreated: `SKUniform` allocation per frame
    /// shows up in a profile immediately.
    private let uExposure = SKUniform(name: "u_exposure", float: 1)
    private let uTint = SKUniform(name: "u_tint", vectorFloat3: vector_float3(1, 1, 1))
    private let uContrast = SKUniform(name: "u_contrast", float: 1)
    private let uSaturation = SKUniform(name: "u_saturation", float: 1)
    private let uBloom = SKUniform(name: "u_bloom", vectorFloat3: vector_float3(0.68, 0.55, 2.4))
    private let uVignette = SKUniform(name: "u_vignette", float: 0.28)
    private let uAberration = SKUniform(name: "u_aberration", float: 0.6)
    private let uPunch = SKUniform(name: "u_punch", float: 0)
    private let uTexel = SKUniform(name: "u_texel", vectorFloat2: vector_float2(0, 0))

    /// - Parameter size: the scene size in points, for the texel step.
    init(size: CGSize) {
        super.init()
        sceneSize = size
        shouldEnableEffects = true
        // Rasterising would cache the output and defeat the point — the frame
        // changes every tick.
        shouldRasterize = false
        shader = PostProcess.makeShader()
        shader?.uniforms = [uExposure, uTint, uContrast, uSaturation, uBloom,
                            uVignette, uAberration, uPunch, uTexel]
        uTexel.vectorFloat2Value = vector_float2(Float(1 / max(size.width, 1)),
                                                Float(1 / max(size.height, 1)))
        apply(.grove)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func apply(_ grade: Grade) {
        self.grade = grade
        uExposure.floatValue = Float(grade.exposure)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        grade.tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        uTint.vectorFloat3Value = vector_float3(Float(r), Float(g), Float(b))
        uContrast.floatValue = Float(grade.contrast)
        uSaturation.floatValue = Float(grade.saturation)
        uBloom.vectorFloat3Value = vector_float3(Float(grade.bloomThreshold),
                                                 Float(grade.bloomStrength),
                                                 Float(grade.bloomRadius))
        uVignette.floatValue = Float(grade.vignette)
        uAberration.floatValue = Float(grade.aberration)
        // A grade with nothing switched on should cost nothing at all.
        shouldEnableEffects = !(grade.bloomStrength == 0 && grade.vignette == 0
                                && grade.aberration == 0 && grade.exposure == 1
                                && grade.contrast == 1 && grade.saturation == 1)
    }

    func apply(named name: String) -> Bool {
        guard let grade = Grade.named[name] else { return false }
        apply(grade)
        return true
    }

    /// Kick the screen — an impact, a boss hit, a landing from height.
    func impact(_ strength: CGFloat = 1, decay: CGFloat = 6) {
        punch = min(1.4, punch + strength)
        punchDecay = decay
    }

    func update(_ dt: CGFloat) {
        guard punch > 0.001 else {
            if uPunch.floatValue != 0 { uPunch.floatValue = 0 }
            return
        }
        punch = max(0, punch - punchDecay * dt)
        uPunch.floatValue = Float(punch)
    }

    // MARK: The pass

    private static func makeShader() -> SKShader {
        // One fragment pass over the composited frame. Ordering matters and is
        // the conventional one: sample (with aberration) → bloom → exposure/tint →
        // contrast → saturation → vignette. Grading before bloom would make the
        // bloom chase the grade rather than the light.
        SKShader(source: """
        void main() {
            vec2 uv = v_tex_coord;

            // Barrel distortion for impacts: push uv outward from centre by the
            // square of the distance, so the frame bends at the edges and the
            // middle — where the player is looking — stays readable.
            vec2 centred = uv - 0.5;
            float r2 = dot(centred, centred);
            uv = 0.5 + centred * (1.0 + u_punch * 0.16 * r2);

            // Chromatic aberration, scaled by distance from centre — a lens
            // property, so it must not be uniform across the frame.
            float edge = sqrt(r2) * 2.0;
            vec2 offset = centred * u_aberration * u_texel * 6.0 * edge;
            vec4 base = texture2D(u_texture, uv);
            base.r = texture2D(u_texture, uv + offset).r;
            base.b = texture2D(u_texture, uv - offset).b;

            // Bright-pass bloom. Four diagonal taps at the bloom radius: with a
            // single pass available there is no separable blur to run, and at 2D
            // scale four taps of the *thresholded* image is visually the same as
            // a wide Gaussian of it.
            vec2 step = u_texel * u_bloom.z;
            vec3 sum = vec3(0.0);
            sum += max(texture2D(u_texture, uv + vec2( step.x,  step.y)).rgb - u_bloom.x, 0.0);
            sum += max(texture2D(u_texture, uv + vec2(-step.x,  step.y)).rgb - u_bloom.x, 0.0);
            sum += max(texture2D(u_texture, uv + vec2( step.x, -step.y)).rgb - u_bloom.x, 0.0);
            sum += max(texture2D(u_texture, uv + vec2(-step.x, -step.y)).rgb - u_bloom.x, 0.0);
            vec3 colour = base.rgb + sum * (u_bloom.y * 0.25);

            colour *= u_exposure * u_tint;
            colour = (colour - 0.5) * u_contrast + 0.5;

            // Rec.709 luma, because a naive average desaturates greens wrongly —
            // and this game is almost entirely green.
            float luma = dot(colour, vec3(0.2126, 0.7152, 0.0722));
            colour = mix(vec3(luma), colour, u_saturation);

            float vig = 1.0 - u_vignette * smoothstep(0.25, 0.95, sqrt(r2) * 1.42);
            colour *= vig;

            // Premultiplied: SpriteKit composites premultiplied alpha, and
            // forgetting this makes every transparent edge glow.
            gl_FragColor = vec4(clamp(colour, 0.0, 1.0) * base.a, base.a);
        }
        """)
    }
}
