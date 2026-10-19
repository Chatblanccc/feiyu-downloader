package io.feather.videodownloader.android

import android.app.Application
import android.webkit.WebView
import io.feather.videodownloader.android.data.*
import io.feather.videodownloader.android.download.DownloadEngine

class FeiyuApp : Application() {
    val database by lazy { TaskDatabase.open(this) }
    val settings by lazy { Settings(this) }
    val engine by lazy { DownloadEngine(this) }
    val downloadNotice=kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    override fun onCreate() {
        super.onCreate()
        val process = getProcessName()
        if (process.endsWith(":auth")) WebView.setDataDirectorySuffix("feiyu_auth")
        if (process.endsWith(":anonymous")) WebView.setDataDirectorySuffix("feiyu_anonymous")
    }
}
