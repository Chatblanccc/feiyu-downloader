package io.feather.videodownloader.android.web

import android.content.Context
import android.net.Uri
import android.os.*
import io.feather.videodownloader.android.core.Site
import io.feather.videodownloader.android.core.readBounded
import kotlinx.coroutines.*
import java.io.File

class CookieVault(private val context: Context) {
    private val root=File(context.noBackupFilesDir,"site-cookies").apply{mkdirs()}
    fun import(site: Site,uri: Uri) {
        val data=context.contentResolver.openInputStream(uri)!!.use { it.readBounded(1024*1024) }
        check(data.size<=1024*1024){"Cookie 文件不能超过 1 MiB。"}
        val text=data.toString(Charsets.UTF_8)
        check(text.take(1024).contains("HTTP Cookie File")){"请选择 Netscape 格式的 Cookie 文本文件。"}
        val lines=text.lineSequence().filter { line ->
            if(line.startsWith('#') && !line.startsWith("#HttpOnly_"))false else {
                val p=line.removePrefix("#HttpOnly_").split('\t')
                p.size==7 && allowed(site,p[0].trimStart('.'))
            }
        }.toList()
        check(lines.isNotEmpty()){ "文件中没有${site.label}网站的 Cookie。" }
        val file=File(root,"${site.name}.txt");val temp=File(root,"${site.name}.new")
        temp.writeText("# Netscape HTTP Cookie File\n"+lines.joinToString("\n")+"\n")
        temp.setReadable(false,false);temp.setWritable(false,false);temp.setReadable(true,true);temp.setWritable(true,true)
        check(temp.renameTo(file)){"无法保存 Cookie 文件。"}
    }
    fun hasImported(site: Site)=File(root,"${site.name}.txt").isFile
    fun clearImported(site: Site){File(root,"${site.name}.txt").delete()}
    suspend fun snapshot(site: Site?,mode: String,id: String): File? {
        if(mode=="none")return null
        requireNotNull(site){"这个网站暂不支持登录状态。"}
        val destination=File(context.cacheDir,"cookie-$id.txt")
        destination.delete()
        if(mode=="file") {
            val source=File(root,"${site.name}.txt");check(source.isFile){"请先在设置中为${site.label}导入 Cookie 文件。"}
            source.copyTo(destination,true)
        } else {
            check(mode=="session")
            SessionExportService.export(context,site,destination)
        }
        destination.setReadable(false,false);destination.setWritable(false,false);destination.setReadable(true,true);destination.setWritable(true,true)
        return destination
    }
    companion object {
        fun allowed(site: Site,host: String): Boolean {
            val domain=site.domain.removePrefix("www.")
            return host==domain || host.endsWith(".$domain") || (site==Site.X && (host=="twitter.com" || host.endsWith(".twitter.com")))
        }
    }
}
