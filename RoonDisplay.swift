import Cocoa
import WebKit

let kDefaultURL     = "http://192.168.1.100:9330/display/"
let kURLKey         = "roonDisplayURL"
let kTimeoutKey     = "roonIdleTimeout"
let kZoneIdKey      = "roonDisplayZoneId"
let kDefaultTimeout: TimeInterval = 300.0

// MARK: - WKScriptMessageHandler proxy (retain cycle 防止)

class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(ucc, didReceive: message)
    }
}

// MARK: - Preferences Window

class PreferencesWindowController: NSWindowController {
    var urlField: NSTextField!
    var timeoutField: NSTextField!
    var onSave: ((String, TimeInterval) -> Void)?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Preferences"
        win.center()
        self.init(window: win)
        setupUI()
    }

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        let urlLabel = NSTextField(labelWithString: "Display URL:")
        urlLabel.frame = NSRect(x: 16, y: 82, width: 90, height: 20)
        cv.addSubview(urlLabel)

        urlField = NSTextField(frame: NSRect(x: 110, y: 78, width: 330, height: 24))
        urlField.stringValue = UserDefaults.standard.string(forKey: kURLKey) ?? kDefaultURL
        cv.addSubview(urlField)

        let toLabel = NSTextField(labelWithString: "Idle timeout (s):")
        toLabel.frame = NSRect(x: 16, y: 52, width: 110, height: 20)
        cv.addSubview(toLabel)

        let savedTimeout = UserDefaults.standard.double(forKey: kTimeoutKey)
        timeoutField = NSTextField(frame: NSRect(x: 130, y: 48, width: 80, height: 24))
        timeoutField.stringValue = String(Int(savedTimeout > 0 ? savedTimeout : kDefaultTimeout))
        cv.addSubview(timeoutField)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancelBtn.frame = NSRect(x: 270, y: 12, width: 80, height: 24)
        cancelBtn.bezelStyle = .rounded
        cv.addSubview(cancelBtn)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveAction))
        saveBtn.frame = NSRect(x: 360, y: 12, width: 80, height: 24)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        cv.addSubview(saveBtn)
    }

    @objc private func saveAction() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        let secs = timeoutField.integerValue > 0 ? TimeInterval(timeoutField.integerValue) : kDefaultTimeout
        UserDefaults.standard.set(url, forKey: kURLKey)
        UserDefaults.standard.set(secs, forKey: kTimeoutKey)
        onSave?(url, secs)
        window?.close()
    }

    @objc private func cancelAction() {
        window?.close()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var prefsController: PreferencesWindowController?

    private var overlayView: NSView?
    private var activityTimer: Timer?

    private var idleTimeout: TimeInterval {
        let v = UserDefaults.standard.double(forKey: kTimeoutKey)
        return v > 0 ? v : kDefaultTimeout
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "roonActivity" {
            DispatchQueue.main.async { self.resetActivityTimer() }
        } else if message.name == "roonZoneId", let zid = message.body as? String {
            UserDefaults.standard.set(zid, forKey: kZoneIdKey)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[nav] didFailProvisional: \(error)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resetActivityTimer()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        loadCurrentURL()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.charactersIgnoringModifiers?.lowercased() == "f" &&
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                self?.window.toggleFullScreen(nil)
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit RoonDisplay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(NSMenuItem(title: "Reload", action: #selector(reloadPage), keyEquivalent: "r"))

        NSApp.mainMenu = main
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Roon Display"
        window.setFrameAutosaveName("RoonDisplayWindow")
        window.center()

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // visibilityState override: WKWebView may report 'hidden' causing Roon JS to skip WebSocket init
        let visibilityJS = """
        Object.defineProperty(document, 'visibilityState', { get: function(){ return 'visible'; } });
        Object.defineProperty(document, 'hidden', { get: function(){ return false; } });
        """

        // console.log傍受で"display zone callback: <zone_id>"からdisplayZoneId確定
        let savedZoneId = UserDefaults.standard.string(forKey: kZoneIdKey) ?? ""
        let monitorJS = """
        (function() {
            const _WS = window.WebSocket;
            var displayZoneId = '\(savedZoneId)' || null;

            function ping() {
                try { window.webkit.messageHandlers.roonActivity.postMessage('ping'); } catch(e) {}
            }
            function saveZoneId(zid) {
                if (zid && zid !== displayZoneId) {
                    displayZoneId = zid;
                    try { window.webkit.messageHandlers.roonZoneId.postMessage(zid); } catch(e) {}
                }
            }

            // console.log傍受: "display zone callback: <zone_id>" を捕捉
            var _log = console.log;
            console.log = function() {
                _log.apply(console, arguments);
                var msg = Array.prototype.slice.call(arguments).join(' ');
                var m = msg.match(/display zone callback:\\s*([0-9a-f]+)/);
                if (m) { saveZoneId(m[1]); }
            };

            function handleText(text) {
                if (text.indexOf('zones_seek_changed') >= 0) {
                    var match = !displayZoneId || text.indexOf(displayZoneId) >= 0;
                    if (match) { ping(); }
                }
            }
            function handleData(data) {
                if (typeof data === 'string') {
                    handleText(data);
                } else if (data instanceof Blob) {
                    data.arrayBuffer().then(function(buf) {
                        handleText(new TextDecoder('utf-8', {fatal:false}).decode(buf));
                    });
                } else if (data instanceof ArrayBuffer) {
                    handleText(new TextDecoder('utf-8', {fatal:false}).decode(data));
                }
            }
            function PatchedWS(url, protocols) {
                const ws = protocols !== undefined ? new _WS(url, protocols) : new _WS(url);
                ws.addEventListener('message', function(e) { handleData(e.data); });
                return ws;
            }
            PatchedWS.prototype = _WS.prototype;
            PatchedWS.CONNECTING = _WS.CONNECTING;
            PatchedWS.OPEN     = _WS.OPEN;
            PatchedWS.CLOSING  = _WS.CLOSING;
            PatchedWS.CLOSED   = _WS.CLOSED;
            window.WebSocket = PatchedWS;
        })();
        """

        config.userContentController.addUserScript(
            WKUserScript(source: visibilityJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: monitorJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(WeakScriptMessageHandler(self), name: "roonActivity")
        config.userContentController.add(WeakScriptMessageHandler(self), name: "roonZoneId")

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.navigationDelegate = self
        let hostname: String = {
            let p = Process(); p.launchPath = "/bin/hostname"; p.arguments = ["-s"]
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return out.isEmpty ? (Host.current().localizedName ?? "unknown") : out
        }()
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 RoonDisplay/\(hostname)"
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Activity Timer & Overlay

    private func resetActivityTimer() {
        hideOverlay()
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            self?.showOverlay()
        }
    }

    private func showOverlay() {
        guard overlayView == nil, let contentView = window?.contentView else { return }

        let overlay = NSView(frame: contentView.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.autoresizingMask = [.width, .height]


        overlay.alphaValue = 0
        contentView.addSubview(overlay)
        overlayView = overlay

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.5
            overlay.animator().alphaValue = 1.0
        }
    }

    private func hideOverlay() {
        guard let overlay = overlayView else { return }
        overlayView = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            overlay.animator().alphaValue = 0
        }) {
            overlay.removeFromSuperview()
        }
    }

    // MARK: Actions

    func loadCurrentURL() {
        let str = UserDefaults.standard.string(forKey: kURLKey) ?? kDefaultURL
        guard let url = URL(string: str) else { return }
        webView.load(URLRequest(url: url))
    }

    @objc func openPreferences() {
        prefsController = PreferencesWindowController()
        prefsController?.onSave = { [weak self] _, _ in self?.loadCurrentURL() }
        prefsController?.showWindow(nil)
        prefsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func reloadPage() {
        webView.reload()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
