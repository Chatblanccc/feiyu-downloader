package io.feather.videodownloader.android.web

import android.app.Service
import android.content.*
import android.os.*
import android.webkit.*
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.feather.videodownloader.android.core.Site
import kotlinx.coroutines.*
import org.json.*
import java.net.URI
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

object AnonymousResolver {
    private val admission=kotlinx.coroutines.sync.Mutex()
    suspend fun resolve(context: Context,url: String): String = withContext(Dispatchers.Main) {
        admission.lock()
        try { withTimeout(40000) { suspendCancellableCoroutine { continuation ->
            var bound=false
            lateinit var connection: ServiceConnection
            fun release(){if(bound){bound=false;runCatching{context.unbindService(connection)}}}
            val reply=Messenger(Handler(Looper.getMainLooper()){message->
                release()
                if(continuation.isActive) {
                    val raw=message.data.getString("result")
                    if(raw!=null)continuation.resume(raw) else continuation.resumeWithException(IllegalStateException(message.data.getString("error") ?: "未能匿名读取抖音视频。请主动打开网站会话，或稍后重试。"))
                };true
            })
            connection=object:ServiceConnection {
                override fun onServiceConnected(name: ComponentName,binder: IBinder) {
                    if(!continuation.isActive){release();return}
                    runCatching{Messenger(binder).send(Message.obtain(null,1).apply{data=Bundle().apply{putString("url",url)};replyTo=reply})}.onFailure{release();if(continuation.isActive)continuation.resumeWithException(it)}
                }
                override fun onServiceDisconnected(name: ComponentName){release();if(continuation.isActive)continuation.resumeWithException(IllegalStateException("网页解析组件已退出。"))}
            }
            bound=context.bindService(Intent(context,AnonymousResolverService::class.java),connection,Context.BIND_AUTO_CREATE)
            if(!bound)continuation.resumeWithException(IllegalStateException("无法启动网页解析。"))
            continuation.invokeOnCancellation{Handler(Looper.getMainLooper()).post{release()}}
        } } } finally { admission.unlock() }
    }
}
class AnonymousResolverService:Service() {
    private val handler=Handler(Looper.getMainLooper());private var web:WebView?=null
    private var reply:Messenger?=null;private var target:String?=null;private var finished=false
    private val messenger=Messenger(Handler(Looper.getMainLooper()){message->if(message.what==1){reply=message.replyTo;start(message.data.getString("url") ?: "")};true})
    override fun onBind(intent:Intent)=messenger.binder
    override fun onUnbind(intent:Intent):Boolean{dispose();stopSelf();return false}
    private fun start(url:String) {
        // A rapid rebind may reuse this service after its prior task finished.
        dispose();finished=false;target=null
        if(Site.from(url)!=Site.DOUYIN){finish(null);return}
        if(!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            finish(null,"请更新手机的 Android System WebView 后重试抖音解析。");return
        }
        val cookies=CookieManager.getInstance().apply{setAcceptCookie(true)}
        web=WebView(this).apply {
            cookies.setAcceptThirdPartyCookies(this,false)
            settings.javaScriptEnabled=true;settings.domStorageEnabled=true;settings.mediaPlaybackRequiresUserGesture=true
            settings.allowFileAccess=false;settings.allowContentAccess=false;settings.loadsImagesAutomatically=false
            settings.useWideViewPort=true;settings.loadWithOverviewMode=true;settings.offscreenPreRaster=true
            settings.userAgentString="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
            WebViewCompat.addWebMessageListener(this,"FeiyuNative",setOf("https://www.douyin.com")) { _,message,origin,isMainFrame,_ ->
                val value=message.data
                if(isMainFrame && origin.host=="www.douyin.com" && value!=null && value.length<=1024*1024)accept(value)
            }
            webViewClient=object:WebViewClient(){
                override fun shouldOverrideUrlLoading(v:WebView,r:WebResourceRequest)= r.url.scheme!="https" || Site.from(r.url.toString())!=Site.DOUYIN
                override fun onPageStarted(v:WebView,u:String,icon:android.graphics.Bitmap?){
                    updateTarget(u)
                    val id=target;val parsed=android.net.Uri.parse(u)
                    if(id!=null && (parsed.host!="www.douyin.com" || parsed.path!="/video/$id"))
                        v.post{if(!finished)v.loadUrl("https://www.douyin.com/video/$id")}
                }
                override fun shouldInterceptRequest(v:WebView,r:WebResourceRequest):WebResourceResponse? {
                    val p=r.url.path ?: ""
                    return if(p.endsWith(".mp4") || p.endsWith(".m3u8") || p.endsWith(".mp3") || r.url.host?.contains("douyinvod.com")==true)
                        WebResourceResponse("text/plain","UTF-8",java.io.ByteArrayInputStream(byteArrayOf())) else null
                }
            }
        }
        web!!.measure(android.view.View.MeasureSpec.makeMeasureSpec(1280,android.view.View.MeasureSpec.EXACTLY),android.view.View.MeasureSpec.makeMeasureSpec(900,android.view.View.MeasureSpec.EXACTLY))
        web!!.layout(0,0,1280,900)
        updateTarget(url)
        val observer=assets.open("douyin-observer.js").bufferedReader().use{it.readText()}
        // Install network observers before page scripts start, rather than after
        // the first metadata response has already been consumed by the site.
        if(WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(web!!,
                "(()=>{const m=location.href.match(/(?:video\\/|modal_id=)([0-9]+)/);if(m){"+observer.replace("'__FEATHER_TARGET__'","m[1]")+"}})();",
                setOf("https://www.douyin.com","https://www.iesdouyin.com"))
        }
        // The independent anonymous profile may receive fresh first-party visitor
        // cookies, but starts empty and never reads the persistent auth profile.
        cookies.removeAllCookies{cookies.flush();if(!finished)web?.loadUrl(url.replaceFirst("http://","https://"))}
        handler.postDelayed({
            if(io.feather.videodownloader.android.BuildConfig.DEBUG)android.util.Log.i("FeiyuAnonymous","Timed out: title=${web?.title?.take(100)} host=${runCatching{android.net.Uri.parse(web?.url).host}.getOrNull()}")
            finish(null)
        },35000)
        if(io.feather.videodownloader.android.BuildConfig.DEBUG)handler.postDelayed({web?.evaluateJavascript("JSON.stringify({ready:document.readyState,installed:!!window.__featherDouyinObserverInstalled,published:!!window.__featherPublished,h1:document.querySelectorAll('h1').length,video:document.querySelectorAll('video').length,width:innerWidth,height:innerHeight,text:document.body?.innerText.slice(0,100)})"){value->android.util.Log.i("FeiyuAnonymous","Page state "+value.take(800))}},25000)
        val poll=object:Runnable { override fun run(){if(finished)return
            val id=target
            if(id!=null)web?.evaluateJavascript(observer.replace("__FEATHER_TARGET__",id)+";window.__featherScanTarget?.();",null)
            handler.postDelayed(this,500)
        } };handler.post(poll)
    }
    private fun updateTarget(url:String){target=(Regex("/(?:video|share/video)/(\\d+)").find(url)?.groupValues?.get(1) ?: Regex("[?&]modal_id=(\\d+)").find(url)?.groupValues?.get(1))?.takeIf{it.length<=32} ?: target}
    private fun accept(value:String) {
        runCatching {
            val j=JSONObject(value);check(j.optString("id")==target)
            if(io.feather.videodownloader.android.BuildConfig.DEBUG)android.util.Log.i("FeiyuAnonymous","Bridge id=${j.optString("id")} target=$target hosts="+(0 until j.getJSONArray("formats").length()).map{runCatching{URI(j.getJSONArray("formats").getJSONObject(it).getString("url")).host}.getOrNull()})
            val incoming=j.getJSONArray("formats");val formats=JSONArray()
            for(i in 0 until minOf(incoming.length(),12)) {
                val f=incoming.getJSONObject(i);val u=f.getString("url");val h=URI(u).host ?: ""
                if(u.startsWith("https://") && listOf("douyinvod.com","douyin.com","snssdk.com","amemv.com","bytecdn.cn","bytecdn.com").any{h==it || h.endsWith(".$it")})
                    formats.put(f.put("format_id","douyin-$i").put("ext","mp4").put("vcodec","h264").put("acodec","aac"))
            }
            check(formats.length()>0)
            j.put("formats",formats).put("extractor","DouyinBrowser").put("extractor_key","Generic")
                .put("http_headers",JSONObject().put("Referer","https://www.douyin.com/").put("User-Agent","Mozilla/5.0"))
            finish(j.toString())
        }.onFailure{if(io.feather.videodownloader.android.BuildConfig.DEBUG)android.util.Log.w("FeiyuAnonymous","Metadata projection rejected: ${it.javaClass.simpleName} ${it.message?.take(160)}")}
    }
    private fun finish(result:String?,error:String?=null){if(finished)return;finished=true;runCatching{reply?.send(Message.obtain(null,2).apply{data=Bundle().apply{putString("result",result);putString("error",error)}})};dispose()}
    private fun dispose(){handler.removeCallbacksAndMessages(null);web?.apply{stopLoading();removeJavascriptInterface("FeiyuNative");clearCache(true);clearHistory();destroy()};web=null;CookieManager.getInstance().removeAllCookies(null);WebStorage.getInstance().deleteAllData()}
    override fun onDestroy(){dispose();super.onDestroy()}
}
