import AppKit
import OpenGL.GL
import OpenGL.GL3
import Cmpv

/// Resolves OpenGL entry points for mpv's render context.
private func mpvGetProcAddress(_ ctx: UnsafeMutableRawPointer?,
                               _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name,
          let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else {
        return nil
    }
    let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}

/// Called by mpv from its render thread when a frame is ready.
private func mpvRenderUpdate(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let view = Unmanaged<MPVGLView>.fromOpaque(ctx).takeUnretainedValue()
    view.scheduleRender()
}

/// Owns the GL context and mpv's render context, and draws video frames.
///
/// The context is created eagerly at init rather than on first draw: mpv reports
/// "No render context set" and drops the video track if playback starts before
/// the render context exists.
final class MPVGLView: NSOpenGLView {

    private weak var core: MPVCore?
    private var renderContext: OpaquePointer?
    private var isRenderContextReady = false

    /// Fires once the render context exists, so queued files can start playing.
    var onReady: (() -> Void)?

    init(core: MPVCore) {
        self.core = core

        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            0
        ]
        let format = NSOpenGLPixelFormat(attributes: attributes)
        super.init(frame: .zero, pixelFormat: format)!

        wantsBestResolutionOpenGLSurface = true
        self.openGLContext?.makeCurrentContext()
        createRenderContext()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
        }
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Render context

    private func createRenderContext() {
        guard renderContext == nil, let handle = core?.handle else { return }

        var initParams = mpv_opengl_init_params(
            get_proc_address: mpvGetProcAddress,
            get_proc_address_ctx: nil
        )
        var advancedControl: CInt = 1
        var ctx: OpaquePointer?

        // MPV_RENDER_PARAM_API_TYPE's `data` is the string itself, not a pointer
        // to it — the extra level of indirection makes mpv fail with
        // MPV_ERROR_NOT_IMPLEMENTED because no backend name matches.
        let status: Int32 = MPV_RENDER_API_TYPE_OPENGL.withCString { apiTypeStr in
            withUnsafeMutablePointer(to: &initParams) { initPtr in
                withUnsafeMutablePointer(to: &advancedControl) { advPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                         data: UnsafeMutableRawPointer(mutating: apiTypeStr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    return mpv_render_context_create(&ctx, handle, &params)
                }
            }
        }

        guard status >= 0, let ctx else {
            NSLog("ZyPlayer: mpv_render_context_create failed (%d)", status)
            return
        }

        renderContext = ctx
        isRenderContextReady = true
        mpv_render_context_set_update_callback(
            ctx,
            mpvRenderUpdate,
            Unmanaged.passUnretained(self).toOpaque()
        )
        onReady?()
    }

    var isReady: Bool { isRenderContextReady }

    /// mpv calls this off the main thread; hop before touching AppKit.
    func scheduleRender() {
        DispatchQueue.main.async { [weak self] in
            self?.drawFrame()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawFrame()
    }

    override func reshape() {
        super.reshape()
        drawFrame()
    }

    private func drawFrame() {
        guard let context = openGLContext else { return }
        context.makeCurrentContext()
        CGLLockContext(context.cglContextObj!)
        defer {
            CGLUnlockContext(context.cglContextObj!)
        }

        guard let renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(UInt32(GL_COLOR_BUFFER_BIT))
            context.flushBuffer()
            return
        }

        let scale = window?.backingScaleFactor ?? 2.0
        let width = Int32(max(bounds.width * scale, 1))
        let height = Int32(max(bounds.height * scale, 1))

        var fbo = mpv_opengl_fbo(fbo: 0, w: width, h: height, internal_format: 0)
        // NSOpenGLView's origin is bottom-left; mpv renders top-left by default.
        var flipY: CInt = 1

        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                _ = mpv_render_context_render(renderContext, &params)
            }
        }

        context.flushBuffer()
        mpv_render_context_report_swap(renderContext)
    }
}
