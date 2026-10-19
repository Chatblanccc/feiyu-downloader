package io.feather.videodownloader.android.web

import android.app.Activity
import android.os.*
import android.webkit.*
import android.widget.*
import android.view.ViewGroup
import io.feather.videodownloader.android.core.Site
import java.io.File
import java.net.URI

class SiteSessionActivity : Activity() {
    private var view: WebView?=null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val site=runCatching{Site.valueOf(intent.getStringExtra("site") ?: "")}.getOrElse{finish();return}
        val manager=CookieManager.getInstance();manager.setAcceptCookie(true)
        val export=intent.getStringExtra("export")
        if(export!=null) {
            @Suppress("DEPRECATION") val receiver=intent.getParcelableExtra<ResultReceiver>("receiver")
            try {
                check(export.matches(Regex("cookie-[a-zA-Z0-9-]+\\.txt")))
                val cookies=manager.getCookie("https://${site.domain}/") ?: error("请先在设置中打开${site.label}并完成登录。")
                val rows=cookies.split(';').mapNotNull { piece ->
                    val pair=piece.trim().split('=',limit=2)
                    if(pair.size==2 && pair[0].isNotBlank() && !piece.contains('\n') && !piece.contains('\t'))
                        "${site.domain}\tFALSE\t/\tTRUE\t0\t${pair[0]}\t${pair[1]}" else null
                }
                check(rows.isNotEmpty()){"未获得可用网站会话。"}
                File(cacheDir,export).writeText("# Netscape HTTP Cookie File\n"+rows.joinToString("\n")+"\n")
                receiver?.send(1,Bundle())
            } catch(e: Exception){receiver?.send(0,Bundle().apply{putString("error",e.message)})}
            finish();return
        }
        if(intent.getBooleanExtra("clear",false)) {
            manager.removeAllCookies { manager.flush();WebStorage.getInstance().deleteAllData();finish() };return
        }
        val layout=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(16,16,16,0)}
        layout.addView(TextView(this).apply{text="${site.label} · ${site.domain}\n请自行完成登录或验证，完成后返回飞羽。";textSize=15f;setPadding(8,8,8,12)})
        layout.addView(Button(this).apply{text="完成，返回飞羽下载";setOnClickListener{manager.flush();finish()}})
        val web=WebView(this);view=web
        web.settings.javaScriptEnabled=true;web.settings.domStorageEnabled=true
        web.settings.allowFileAccess=false;web.settings.allowContentAccess=false
        web.settings.mediaPlaybackRequiresUserGesture=true
        manager.setAcceptThirdPartyCookies(web,false)
        web.webViewClient=object:WebViewClient(){
            override fun shouldOverrideUrlLoading(v:WebView,r:WebResourceRequest):Boolean {
                val u=r.url;val h=u.host ?: return true
                if(u.scheme!="https")return true
                if(h=="accounts.google.com") {
                    Toast.makeText(this@SiteSessionActivity,"Google 不支持此内嵌登录方式，可返回后主动导入 Cookie 文件。",Toast.LENGTH_LONG).show();return true
                }
                val root=site.domain.removePrefix("www.")
                return !(h==root || h.endsWith(".$root") || (site==Site.X && (h=="twitter.com" || h.endsWith(".twitter.com"))))
            }
        }
        layout.addView(web,LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,0,1f));setContentView(layout)
        web.loadUrl("https://${site.domain}/")
    }
    override fun onDestroy(){view?.apply{stopLoading();clearHistory();destroy()};view=null;super.onDestroy()}
}
