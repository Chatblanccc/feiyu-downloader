import AppKit
import WebKit

/// Public-page parsing has one shared slot, a fresh cookie-free session, and a fixed lifetime.
public struct DouyinBrowserAdapter {
    private static let admission = DouyinBrowserAdmission()

    public static func supports(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), host == "douyin.com" || host.hasSuffix(".douyin.com") || host == "iesdouyin.com" || host.hasSuffix(".iesdouyin.com") else { return false }
        if host == "live.douyin.com" { return false }
        return host == "v.douyin.com" || url.path.contains("/video/") || URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "modal_id" }) == true
    }

    @MainActor public static func resolve(url: URL) async throws -> VideoMetadata {
        guard supports(url) else { throw DownloadError.invalidMetadata }
        let permit = UUID()
        try await admission.acquire(permit)
        defer { Task { await admission.release(permit) } }
        let browserURL: URL
        do { browserURL = try await canonicalBrowserURL(for: url) }
        catch { try Task.checkCancellation(); throw error }
        try Task.checkCancellation()
        let session = DouyinBrowserSession(sourceURL: url, initialURL: browserURL)
        defer { withExtendedLifetime(session) {} }
        return try await session.resolve()
    }

    @MainActor private static func canonicalBrowserURL(for url: URL) async throws -> URL {
        if let id = DouyinBrowserSession.videoID(in: url) { return URL(string: "https://www.douyin.com/video/" + id)! }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        guard let requestURL = components?.url else { throw DownloadError.invalidMetadata }
        // GET redirect headers are enough; the landing page body is never buffered.
        let response = try await AnonymousHTTPClient().resolveURL(requestURL, headers: ["User-Agent": "Mozilla/5.0"])
        try Task.checkCancellation()
        guard let id = DouyinBrowserSession.videoID(in: response.finalURL) else { throw DownloadError.invalidMetadata }
        return URL(string: "https://www.douyin.com/video/" + id)!
    }
}

private actor DouyinBrowserAdmission {
    private var owner: UUID?
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if owner == nil { owner = id; continuation.resume(); return }
                guard waiting.count < 8 else { continuation.resume(throwing: DownloadError.timedOut); return }
                waiting.append((id, continuation))
            }
        }, onCancel: { Task { await self.cancel(id) } })
        if Task.isCancelled { release(id); throw CancellationError() }
    }

    private func cancel(_ id: UUID) {
        // A granted permit belongs to the resolver until its cleanup defer runs.
        // A delayed cancellation callback must never release an active WebView slot.
        if let index = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: index).1.resume(throwing: CancellationError())
        }
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            owner = next.0
            next.1.resume()
        }
    }
}

private final class DouyinDeadlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func expire() { lock.lock(); value = true; lock.unlock() }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor private final class DouyinMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: DouyinBrowserSession?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

@MainActor private final class DouyinBrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"
    private static var compiledRules: WKContentRuleList?
    private let sourceURL: URL
    private let initialURL: URL
    private let targetID: String
    private let deadlineState = DouyinDeadlineState()
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<VideoMetadata, Error>?
    private var polling: DispatchSourceTimer?
    private var deadline: DispatchSourceTimer?
    private var evaluating = false
    private var finished = false
    private var polls = 0
    private var targetDetail: [String: Any]?

    init(sourceURL: URL, initialURL: URL) {
        self.sourceURL = sourceURL; self.initialURL = initialURL
        self.targetID = Self.videoID(in: initialURL) ?? ""
        super.init()
    }

    func resolve() async throws -> VideoMetadata {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.start()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } })
    }

    private func start() {
        guard !targetID.isEmpty else { finish(.failure(DownloadError.invalidMetadata)); return }
        let state = deadlineState
        let hardDeadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        hardDeadline.schedule(deadline: .now() + 20)
        hardDeadline.setEventHandler { [weak self] in
            state.expire()
            Task { @MainActor [weak self] in self?.finish(.failure(DownloadError.timedOut)) }
        }
        deadline = hardDeadline
        hardDeadline.resume()
        if let rules = Self.compiledRules { launch(rules: rules); return }
        let rules = #"[{"trigger":{"url-filter":".*","resource-type":["media","image","font"]},"action":{"type":"block"}},{"trigger":{"url-filter":"^https?://[^/]*douyinvod\\.com/"},"action":{"type":"block"}},{"trigger":{"url-filter":"^https?://[^/]*douyin\\.com/aweme/v1/play/"},"action":{"type":"block"}},{"trigger":{"url-filter":"\\.mp[34]"},"action":{"type":"block"}},{"trigger":{"url-filter":"\\.m4a"},"action":{"type":"block"}},{"trigger":{"url-filter":"\\.webm"},"action":{"type":"block"}},{"trigger":{"url-filter":"\\.m3u8"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "FeatherMetadataOnly-v2", encodedContentRuleList: rules) { [weak self] list, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                guard let list else { self.finish(.failure(DownloadError.invalidMetadata)); return }
                Self.compiledRules = list
                self.launch(rules: list)
            }
        }
    }

    private func launch(rules: WKContentRuleList) {
        guard !finished, !deadlineState.expired else { finish(.failure(DownloadError.timedOut)); return }
        let controller = WKUserContentController()
        let proxy = DouyinMessageProxy()
        proxy.owner = self
        controller.add(proxy, name: "featherDouyinDetail")
        controller.add(rules)
        let observer = Self.observerScript.replacingOccurrences(of: "__FEATHER_TARGET__", with: targetID)
        controller.addUserScript(WKUserScript(source: observer, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 960, height: 600), configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self; view.customUserAgent = Self.userAgent
        webView = view
        view.load(URLRequest(url: initialURL, timeoutInterval: 15))
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + 1, repeating: 1.5)
        source.setEventHandler { [weak self] in Task { @MainActor [weak self] in self?.poll() } }
        polling = source
        source.resume()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !finished, !deadlineState.expired, let url = action.request.url,
              Self.isAllowedNavigation(url), action.targetFrame != nil else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == true {
            guard let host = url.host?.lowercased(), host == "douyin.com" || host.hasSuffix(".douyin.com") else {
                decisionHandler(url.absoluteString == "about:blank" ? .allow : .cancel); return
            }
            if let id = Self.videoID(in: url), id != targetID { decisionHandler(.cancel); return }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            decisionHandler(.cancel); finish(.failure(DownloadError.invalidMetadata)); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(DownloadError.invalidMetadata)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        if error.code != NSURLErrorCancelled && !(error.domain == "WebKitErrorDomain" && error.code == 102) { finish(.failure(DownloadError.invalidMetadata)) }
    }

    func receive(_ message: WKScriptMessage) {
        guard !finished else { return }
        if deadlineState.expired { finish(.failure(DownloadError.timedOut)); return }
        guard message.frameInfo.isMainFrame, let origin = message.frameInfo.request.url?.host?.lowercased(),
              origin == "douyin.com" || origin.hasSuffix(".douyin.com"),
              let input = message.body as? [String: Any], input.count <= 8,
              input["id"] as? String == targetID,
              let title = input["title"] as? String, !title.isEmpty, title.utf8.count <= 2_048,
              let formats = input["formats"] as? [[String: Any]], !formats.isEmpty, formats.count <= 12 else { return }
        // Keep one small projection; never retain page records, recommended IDs, or arbitrary fields.
        let boundedFormats = formats.compactMap { item -> [String: Any]? in
            guard item.count <= 8, let value = item["url"] as? String, value.utf8.count <= 8_192,
                  let url = URL(string: value), Self.isAllowedMedia(url) else { return nil }
            var projected: [String: Any] = ["url": value]
            for key in ["width", "height", "fps", "bytes", "bitrate"] {
                if let number = item[key] as? NSNumber, number.doubleValue.isFinite { projected[key] = number }
            }
            return projected
        }
        guard !boundedFormats.isEmpty else { return }
        var detail: [String: Any] = ["id": targetID, "title": title, "formats": boundedFormats]
        if let duration = input["duration"] as? NSNumber, duration.doubleValue.isFinite, duration.doubleValue >= 0 { detail["duration"] = duration }
        if let thumbnail = input["thumbnail"] as? String, thumbnail.utf8.count <= 8_192 { detail["thumbnail"] = thumbnail }
        targetDetail = detail
        resolveMatchingDetail()
    }

    private func poll() {
        guard !finished, let webView else { return }
        if deadlineState.expired || polls >= 12 { finish(.failure(DownloadError.timedOut)); return }
        guard !evaluating else { return }
        polls += 1; evaluating = true
        webView.evaluateJavaScript(Self.pollScript) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.evaluating = false }
        }
    }

    private func resolveMatchingDetail() {
        guard !finished, let currentURL = webView?.url, Self.videoID(in: currentURL) == targetID,
              let detail = targetDetail, let title = detail["title"] as? String,
              let candidates = detail["formats"] as? [[String: Any]], let candidate = candidates.sorted(by: {
                  let left = ($0["height"] as? NSNumber)?.intValue ?? 0, right = ($1["height"] as? NSNumber)?.intValue ?? 0
                  return left == right ? (($0["bitrate"] as? NSNumber)?.doubleValue ?? 0) > (($1["bitrate"] as? NSNumber)?.doubleValue ?? 0) : left > right
              }).first, let value = candidate["url"] as? String, let media = URL(string: value) else { return }
        let format = MediaFormat(id: "douyin-browser-mp4", fileExtension: "mp4", width: (candidate["width"] as? NSNumber)?.intValue,
                                 height: (candidate["height"] as? NSNumber)?.intValue, fps: (candidate["fps"] as? NSNumber)?.doubleValue,
                                 fileSize: (candidate["bytes"] as? NSNumber)?.int64Value, hasVideo: true, hasAudio: true, formatNote: "网页提供的 H.264 MP4")
        finish(.success(VideoMetadata(id: targetID, sourceURL: sourceURL, webpageURL: currentURL, title: title,
                                      thumbnailURL: (detail["thumbnail"] as? String).flatMap(URL.init(string:)), duration: (detail["duration"] as? NSNumber)?.doubleValue,
                                      formats: [format], extractor: "DouyinBrowser", resolvedMediaURL: media,
                                      httpHeaders: ["Referer": "https://www.douyin.com/", "User-Agent": Self.userAgent])))
    }

    private func finish(_ result: Result<VideoMetadata, Error>) {
        guard !finished else { return }
        finished = true
        polling?.cancel(); polling = nil; deadline?.cancel(); deadline = nil
        let pending = continuation; continuation = nil; targetDetail = nil
        guard let view = webView else { pending?.resume(with: result); return }
        webView = nil
        view.stopLoading()
        view.pauseAllMediaPlayback(completionHandler: {})
        view.configuration.userContentController.removeScriptMessageHandler(forName: "featherDouyinDetail")
        view.configuration.userContentController.removeAllUserScripts()
        view.navigationDelegate = nil; view.uiDelegate = nil
        view.loadHTMLString("<html><body></body></html>", baseURL: nil)
        view.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast, completionHandler: {})
        view.removeFromSuperview()
        // Allow the blank navigation to discard the old document before releasing the last view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [view] in
            view.stopLoading()
            pending?.resume(with: result)
        }
    }

    private static func isAllowedNavigation(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank" }
    private static func isAllowedMedia(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return ["douyinvod.com", "douyin.com", "snssdk.com", "amemv.com", "bytecdn.cn", "bytecdn.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    fileprivate static func videoID(in url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(),
              host == "douyin.com" || host.hasSuffix(".douyin.com") || host == "iesdouyin.com" || host.hasSuffix(".iesdouyin.com") else { return nil }
        let parts = url.pathComponents
        let value: String?
        if let index = parts.firstIndex(of: "video"), parts.indices.contains(index + 1) { value = parts[index + 1] }
        else { value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "modal_id" })?.value }
        guard let value, value.count <= 24, value.range(of: #"^\d+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private static let pollScript = #"""
    (() => {
      if (window.__featherStopped || window.__featherPublished || typeof window.__featherScanTarget !== 'function') return null;
      window.__featherScanTarget();
      return null;
    })();
    """#

    private static let observerScript = #"""
    (() => {
      if(window.__featherDouyinObserverInstalled)return;
      window.__featherDouyinObserverInstalled=true;
      const target='__FEATHER_TARGET__';
      let published=false, reads=0;
      const own=(x,k)=>{try{return Object.getOwnPropertyDescriptor(x,k)?.value}catch(_){return undefined}};
      const list=x=>Array.isArray(x)?x:[];
      const number=x=>{if(typeof x==='number')return Number.isFinite(x)?x:0;if(typeof x==='string'&&x.length<=32){const n=Number(x);return Number.isFinite(n)?n:0}return 0};
      const address=x=>{
        for(let i=0;i<Math.min(list(x).length,4);i++){
          const item=own(x,String(i)), u=typeof item==='string'?item:own(item,'src');
          if(typeof u==='string'&&u.length<=8192&&/^https:\/\//.test(u)&&!/\/media-video-|\/play\/dash\//.test(u))return u;
        }
      };
      const publish=(id,title,duration,thumbnail,formats)=>{
        if(published||id!==target||typeof title!=='string'||!title||!formats.length)return;
        published=true;window.__featherPublished=true;
        const detail={id,title:title.slice(0,2048),duration:Number.isFinite(duration)?duration:0,thumbnail:typeof thumbnail==='string'?thumbnail.slice(0,8192):null,formats:formats.slice(0,12)};
        try{window.webkit.messageHandlers.featherDouyinDetail.postMessage(detail)}catch(_){}
      };
      const accept=json=>{
        const d=own(json,'aweme_detail');if(!d||own(d,'aweme_id')!==target)return;
        const v=own(d,'video');if(!v)return;const variants=list(own(v,'bit_rate')), formats=[];
        for(let i=0;i<Math.min(variants.length,64)&&formats.length<12;i++){
          const b=own(variants,String(i));if(own(b,'format')!=='mp4'||(number(own(b,'is_h265'))||number(own(b,'is_bytevc1')))===1)continue;
          const a=own(b,'play_addr'), u=address(own(a,'url_list'));if(!u)continue;
          formats.push({url:u,width:number(own(a,'width'))||number(own(v,'width')),height:number(own(a,'height'))||number(own(v,'height')),fps:number(own(b,'FPS')),bytes:number(own(a,'data_size')),bitrate:number(own(b,'bit_rate'))});
        }
        publish(target,own(d,'desc'),(number(own(v,'duration'))||number(own(d,'duration')))/1000,own(list(own(own(v,'cover'),'url_list')),'0'),formats);
      };
      const acceptNormalized=d=>{
        if(!d||own(d,'awemeId')!==target)return;const v=own(d,'video');if(!v)return;
        const variants=list(own(v,'bitRateList')),formats=[];
        for(let i=0;i<Math.min(variants.length,64)&&formats.length<12;i++){
          const b=own(variants,String(i));if(own(b,'format')!=='mp4'||number(own(b,'isH265'))===1)continue;
          const u=address(own(b,'playAddr'));if(!u)continue;
          formats.push({url:u,width:number(own(b,'width'))||number(own(v,'width')),height:number(own(b,'height'))||number(own(v,'height')),fps:number(own(b,'fps')),bytes:number(own(b,'dataSize')),bitrate:number(own(b,'bitRate'))});
        }
        publish(target,own(d,'desc'),number(own(v,'duration'))/1000,own(v,'cover')||own(list(own(v,'coverUrlList')),'0'),formats);
      };
      const isDetail=u=>{try{const p=new URL(u,location.href);return p.protocol==='https:'&&/(^|\.)douyin\.com$/.test(p.hostname)&&p.pathname==='/aweme/v1/web/aweme/detail/'&&p.searchParams.get('aweme_id')===target}catch(_){return false}};
      const readResponse=async response=>{
        if(reads++>=2||published||!response.ok)return;
        const length=Number(response.headers.get('content-length')||0);if(length>1048576)return;
        const reader=response.clone().body?.getReader();if(!reader)return;
        const decoder=new TextDecoder();let bytes=0,text='';
        try{while(!published&&!window.__featherStopped){const item=await reader.read();if(item.done){text+=decoder.decode();accept(JSON.parse(text));break}bytes+=item.value.byteLength;if(bytes>1048576)break;text+=decoder.decode(item.value,{stream:true})}}catch(_){}finally{reader.cancel().catch(()=>{})}
      };
      const fetchOriginal=window.fetch;
      window.fetch=function(input,...args){const result=fetchOriginal.call(this,input,...args);const u=typeof input==='string'?input:input&&(input.url||input.href);if(isDetail(u)&&reads<2)result.then(readResponse).catch(()=>{});return result};
      const openOriginal=XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open=function(method,url,...args){if(isDetail(url))this.addEventListener('load',()=>{if(reads++>=2||published)return;try{if(this.responseType==='json')accept(this.response);else if(this.responseText.length<=1048576)accept(JSON.parse(this.responseText))}catch(_){}},{once:true});return openOriginal.call(this,method,url,...args)};
      // An allowlist of data slots avoids enumerating giant objects or typed-array indices.
      const slots=['awemeInfo','aweme','video','data','item','itemData','value','state','memoizedState','baseState','next','payload','dataSource','videoInfo','awemeDetail','currentVideo','selectedVideo','detail','itemList','list','children','props','initialState','cache','current'];
      window.__featherScanTarget=()=>{
        if(published)return;const seen=new WeakSet(), started=performance.now();let budget=1500;
        const scan=(x,depth)=>{
          if(!x||typeof x!=='object'||seen.has(x)||depth>7||budget--<=0||performance.now()-started>15||ArrayBuffer.isView(x)||x instanceof ArrayBuffer)return false;
          let proto;try{proto=Object.getPrototypeOf(x)}catch(_){return false}
          if(!Array.isArray(x)&&proto!==Object.prototype&&proto!==null)return false;
          seen.add(x);
          if(own(x,'aweme_id')===target)accept({aweme_detail:x});else if(own(x,'awemeId')===target)acceptNormalized(x);
          if(published)return true;
          if(Array.isArray(x)){if(x.length>256)return false;for(let i=0;i<Math.min(x.length,32);i++){if(scan(own(x,String(i)),depth+1))return true}}
          else for(const key of slots){if(scan(own(x,key),depth+1))return true}
          return false;
        };
        const elements=document.querySelectorAll('h1,video');
        for(let index=0;index<Math.min(elements.length,4);index++){
          const element=elements[index];
          const key=Object.getOwnPropertyNames(element).slice(0,16).find(k=>k.startsWith('__reactFiber$'));let fiber=key?own(element,key):null;
          for(let level=0;fiber&&level<24&&budget>0&&performance.now()-started<=15;level++,fiber=own(fiber,'return')){if(scan(own(fiber,'memoizedProps'),0)||scan(own(fiber,'memoizedState'),0))break}
          if(published)break;
        }
      };
    })();
    """#
}
