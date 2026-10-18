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
///
/// Kareler ana iş parçacığında değil, kendi çizim kuyruğunda çizilir.
/// `mpv_render_context_render` karenin gösterim zamanına kadar bekliyor
/// (BLOCK_FOR_TARGET_TIME) ve GPU çizimi (ölçekleme, altyazı katmanı) her
/// karede birkaç ms sürüyor; ana iş parçacığında bunlar zamanın ~%90'ını
/// yiyordu ve arayüzün en küçük işi bile kareyi geciktirip oynatmada ara ara
/// takılma yapıyordu. GL bağlamı `CGLLockContext` ile korunur: AppKit boyut
/// değişiminde bağlamı ana iş parçacığında günceller (`update()`).
final class MPVGLView: NSOpenGLView {

    private weak var core: MPVCore?
    private var renderContext: OpaquePointer?
    private var isRenderContextReady = false
    /// Çizim kuyruğu bağlama AppKit özelliği üzerinden değil, buradan erişir.
    private var glContext: NSOpenGLContext!

    private let renderQueue = DispatchQueue(label: "com.zyplayer.mpv.render",
                                            qos: .userInteractive)
    /// Aşağıdaki üç değeri korur (ana iş parçacığı, mpv ve çizim kuyruğu).
    private let stateLock = NSLock()
    /// Kuyrukta bekleyen bir çizim var; mpv'nin peş peşe geri çağrıları
    /// tek çizimde birleşir.
    private var renderPending = false
    /// Yeni kare olmasa da çizilsin (boyut değişti, AppKit yeniden çizim istedi).
    private var forcePending = false
    /// Çizim boyutu (piksel); ana iş parçacığında hesaplanır.
    private var drawableSize = CGSize(width: 1, height: 1)

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
        glContext = openGLContext
        glContext.makeCurrentContext()
        createRenderContext()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        // Sürmekte olan bir çizim bitmeden bağlam serbest bırakılmaz.
        let context = glContext!
        renderQueue.sync {
            let cgl = context.cglContextObj!
            CGLLockContext(cgl)
            context.makeCurrentContext()
            mpv_render_context_free(renderContext)
            CGLUnlockContext(cgl)
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

    /// mpv calls this off the main thread; the frame is drawn on the render queue.
    func scheduleRender() {
        enqueueRender(force: false)
    }

    private func enqueueRender(force: Bool) {
        stateLock.lock()
        if force { forcePending = true }
        let alreadyQueued = renderPending
        renderPending = true
        stateLock.unlock()
        guard !alreadyQueued else { return }
        renderQueue.async { [weak self] in
            self?.renderFromQueue()
        }
    }

    // MARK: - Ana iş parçacığı: boyut ve yeniden çizim istekleri

    override func draw(_ dirtyRect: NSRect) {
        enqueueRender(force: true)
    }

    override func reshape() {
        super.reshape()
        updateDrawableSize()
        enqueueRender(force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        enqueueRender(force: true)
    }

    /// AppKit bağlamı boyut değişiminde ana iş parçacığında günceller; çizim
    /// kuyruğu o sırada bağlamı kullanmasın.
    override func update() {
        guard let cgl = glContext?.cglContextObj else {
            super.update()
            return
        }
        CGLLockContext(cgl)
        super.update()
        CGLUnlockContext(cgl)
    }

    private func updateDrawableSize() {
        let size = convertToBacking(bounds).size
        stateLock.lock()
        drawableSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        stateLock.unlock()
    }

    // MARK: - Çizim kuyruğu

    private func renderFromQueue() {
        stateLock.lock()
        let force = forcePending
        forcePending = false
        renderPending = false
        let size = drawableSize
        stateLock.unlock()
        drawFrame(force: force, size: size)
    }

    /// `ADVANCED_CONTROL` kipinde mpv, güncelleme geri çağrısının ardından
    /// `mpv_render_context_update`'in çağrılmasını şart koşar: çözücünün
    /// render iş parçacığına gönderdiği işler (yazılım çözmede direct-rendering
    /// görüntü tamponu ayırma) yalnızca bu çağrıda işlenir. Çağrılmazsa yazılım
    /// çözücü ilk tamponda sonsuza dek bekler — IPTV "devam et"te VideoToolbox
    /// atlama sonrası hata verip yazılıma düşünce oynatıcı zamanı gösterip hiç
    /// kare çizmiyordu.
    private func drawFrame(force: Bool, size: CGSize) {
        let context = glContext!
        guard let cgl = context.cglContextObj else { return }
        CGLLockContext(cgl)
        defer { CGLUnlockContext(cgl) }
        context.makeCurrentContext()

        guard let renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(UInt32(GL_COLOR_BUFFER_BIT))
            context.flushBuffer()
            return
        }

        let flags = mpv_render_context_update(renderContext)
        if !force && flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) == 0 {
            return
        }

        var fbo = mpv_opengl_fbo(fbo: 0, w: Int32(size.width), h: Int32(size.height),
                                 internal_format: 0)
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
