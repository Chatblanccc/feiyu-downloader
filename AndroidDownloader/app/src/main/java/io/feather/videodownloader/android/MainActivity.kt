package io.feather.videodownloader.android

import android.Manifest
import android.content.*
import android.net.Uri
import android.os.*
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.feather.videodownloader.android.core.*
import io.feather.videodownloader.android.data.DownloadTask
import io.feather.videodownloader.android.web.*
import kotlinx.coroutines.*
import java.net.HttpURLConnection
import java.net.URL

class MainActivity:ComponentActivity(){
    private val model:MainViewModel by viewModels()
    override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState);enableEdgeToEdge();receive(intent);setContent{FeiyuScreen(model)}}
    override fun onNewIntent(intent:Intent){super.onNewIntent(intent);setIntent(intent);receive(intent)}
    private fun receive(intent:Intent?){if(intent?.action==Intent.ACTION_SEND && intent.type=="text/plain") { model.setInput(intent.getStringExtra(Intent.EXTRA_TEXT) ?: "");model.tab.value=0 }}
}
private val Blue=Color(0xFF3970DC)
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun FeiyuScreen(vm:MainViewModel){
    val context=androidx.compose.ui.platform.LocalContext.current
    val tab by vm.tab.collectAsStateWithLifecycle();val tasks by vm.tasks.collectAsStateWithLifecycle()
    val message by vm.message.collectAsStateWithLifecycle()
    val colorScheme=if(isSystemInDarkTheme())darkColorScheme(primary=Color(0xFFABC6FF),secondary=Color(0xFFABC6FF),primaryContainer=Color(0xFF233A60),secondaryContainer=Color(0xFF233A60),surface=Color(0xFF14191F),background=Color(0xFF101418),surfaceContainer=Color(0xFF1B222C))
        else lightColorScheme(primary=Blue,secondary=Blue,primaryContainer=Color(0xFFE3EDFF),secondaryContainer=Color(0xFFE3EDFF),onPrimaryContainer=Blue,onSecondaryContainer=Blue,background=Color(0xFFF7F9FC),surface=Color.White,surfaceContainer=Color(0xFFF0F4FB),outline=Color(0xFF8591A3),outlineVariant=Color(0xFFCFD7E4))
    MaterialTheme(colorScheme=colorScheme){
        Scaffold(topBar={TopAppBar(title={Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)){
            Image(painterResource(R.drawable.feiyu_logo),"飞羽",Modifier.size(38.dp));Column{Text("飞羽下载",fontWeight=FontWeight.SemiBold);Text("让好内容，轻松留在身边",style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
        }})},bottomBar={NavigationBar{listOf("下载" to Icons.Outlined.FileDownload,"任务" to Icons.Outlined.DownloadDone,"设置" to Icons.Outlined.Settings).forEachIndexed{index,item->
            NavigationBarItem(selected=tab==index,onClick={vm.tab.value=index},icon={Icon(item.second,item.first)},label={Text(if(index==1 && tasks.any{it.status.active})"任务 · 下载中" else item.first)})
        }}}){padding->
            Column(Modifier.fillMaxSize().padding(padding)){
                message?.let{Surface(color=MaterialTheme.colorScheme.errorContainer,modifier=Modifier.fillMaxWidth().padding(horizontal=16.dp)){
                    Row(Modifier.padding(12.dp),verticalAlignment=Alignment.CenterVertically){Text(it,Modifier.weight(1f),style=MaterialTheme.typography.bodySmall);IconButton(onClick={vm.message.value=null}){Icon(Icons.Outlined.Close,"关闭提示")}}
                }}
                when(tab){0->DownloadPage(vm);1->TasksPage(vm,tasks);else->SettingsPage(vm)}
            }
        }
    }
}
@Composable private fun DownloadPage(vm:MainViewModel){
    val text by vm.text.collectAsStateWithLifecycle();val quality by vm.quality.collectAsStateWithLifecycle()
    val auth by vm.authentication.collectAsStateWithLifecycle();val info by vm.preview.collectAsStateWithLifecycle()
    val busy by vm.busy.collectAsStateWithLifecycle();val ready by vm.ready.collectAsStateWithLifecycle()
    val context=androidx.compose.ui.platform.LocalContext.current
    val clipboard=androidx.compose.ui.platform.LocalClipboardManager.current
    val notification=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){vm.enqueue()}
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(18.dp)){
        item{Text("保存你喜欢的视频",style=MaterialTheme.typography.headlineSmall,fontWeight=FontWeight.SemiBold)}
        item{Text("抖音 · 快手 · B站 · YouTube · X · TikTok",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
        item{Card(colors=CardDefaults.cardColors(containerColor=MaterialTheme.colorScheme.surface),modifier=Modifier.fillMaxWidth()){
            Column(Modifier.padding(18.dp),verticalArrangement=Arrangement.spacedBy(14.dp)){
                Row(verticalAlignment=Alignment.CenterVertically){Text("添加视频",style=MaterialTheme.typography.titleMedium,modifier=Modifier.weight(1f));TextButton(onClick={clipboard.getText()?.let{vm.setInput(it.text)}}){Text("粘贴")}}
                OutlinedTextField(value=text,onValueChange=vm::setInput,placeholder={Text("粘贴视频链接或完整分享文案\n多个链接可一起添加")},modifier=Modifier.fillMaxWidth().heightIn(min=138.dp),shape=RoundedCornerShape(12.dp),label={Text("视频链接或分享文案")})
                Text("下载画质",style=MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement=Arrangement.spacedBy(8.dp),modifier=Modifier.horizontalScroll(rememberScrollState())){Quality.entries.forEach{q->FilterChip(selected=quality==q,onClick={vm.quality.value=q},label={Text(q.label)})}}
                Text("网站登录状态",style=MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement=Arrangement.spacedBy(8.dp),modifier=Modifier.horizontalScroll(rememberScrollState())){listOf("none" to "不使用登录状态","session" to "应用内网站会话","file" to "导入的 Cookie").forEach{(key,label)->FilterChip(selected=auth==key,onClick={vm.authentication.value=key;vm.preview.value=null},label={Text(label)})}}
                Row(horizontalArrangement=Arrangement.spacedBy(10.dp)){
                    OutlinedButton(onClick=vm::inspect,enabled=text.isNotBlank() && !busy && ready,modifier=Modifier.weight(1f)){if(busy)CircularProgressIndicator(Modifier.size(16.dp),strokeWidth=2.dp) else Text("解析预览")}
                    Button(onClick={if(Build.VERSION.SDK_INT>=33)notification.launch(Manifest.permission.POST_NOTIFICATIONS)else vm.enqueue()},enabled=text.isNotBlank() && ready,modifier=Modifier.weight(1f)){Icon(Icons.Outlined.FileDownload,null,Modifier.size(18.dp));Spacer(Modifier.width(4.dp));Text("开始下载")}
                }
                Text("也可以在其他应用中选择“分享 → 飞羽下载”。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }}
        info?.let{media->item{Card(modifier=Modifier.fillMaxWidth()){
            Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                BoundedCover(media.thumbnail)
                Text(media.title,style=MaterialTheme.typography.titleMedium)
                Text(listOfNotNull(media.duration?.let{"时长 ${duration(it)}"},media.heights.take(6).takeIf{it.isNotEmpty()}?.joinToString(" / "){"${it}p"}).joinToString(" · "),style=MaterialTheme.typography.bodySmall)
            }
        }}}
        item{Text("文件将保存至系统“影片／音乐 → 飞羽下载”。默认仅使用非计费网络，可在设置中允许移动网络。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
    }
}
@Composable private fun BoundedCover(url:String?){
    val image by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null,url){value=null;if(url==null)return@produceState
        value=withContext(Dispatchers.IO){runCatching{
            val c=URL(url).openConnection() as HttpURLConnection;c.connectTimeout=8000;c.readTimeout=8000
            try{check(c.contentLengthLong<=2*1024*1024);val bytes=c.inputStream.use{it.readBounded(2*1024*1024)};check(bytes.size<=2*1024*1024)
                val bounds=android.graphics.BitmapFactory.Options().apply{inJustDecodeBounds=true};android.graphics.BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
                check(bounds.outWidth in 1..20000 && bounds.outHeight in 1..20000)
                val opts=android.graphics.BitmapFactory.Options().apply{inSampleSize=generateSequence(1){it*2}.first{maxOf(bounds.outWidth,bounds.outHeight)/it<=1024}}
                android.graphics.BitmapFactory.decodeByteArray(bytes,0,bytes.size,opts)?.asImageBitmap()
            }finally{c.disconnect()}
        }.getOrNull()}
    }
    image?.let{Image(it,"视频封面",Modifier.fillMaxWidth().heightIn(max=200.dp))}
}
@Composable private fun TasksPage(vm:MainViewModel,tasks:List<DownloadTask>){
    val context=androidx.compose.ui.platform.LocalContext.current
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(14.dp)){
        item{Text("下载任务",style=MaterialTheme.typography.headlineSmall,fontWeight=FontWeight.SemiBold)}
        if(tasks.isEmpty())item{Column(Modifier.fillMaxWidth().padding(vertical=80.dp),horizontalAlignment=Alignment.CenterHorizontally){Icon(Icons.Outlined.VideoLibrary,null,Modifier.size(50.dp),tint=MaterialTheme.colorScheme.outline);Spacer(Modifier.height(16.dp));Text("还没有下载任务");TextButton(onClick={vm.tab.value=0}){Text("添加第一个视频")}}}
        items(tasks,key={it.id}){task->Card(colors=CardDefaults.cardColors(containerColor=MaterialTheme.colorScheme.surface),modifier=Modifier.fillMaxWidth()){
            Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                Row{Text(Site.from(task.source)?.label ?: "视频",style=MaterialTheme.typography.labelMedium,color=MaterialTheme.colorScheme.primary,modifier=Modifier.weight(1f));Text(task.status.label,style=MaterialTheme.typography.labelMedium)}
                Text(task.title,style=MaterialTheme.typography.titleSmall,maxLines=3)
                if(task.status.active){val fraction=task.total?.takeIf{it>0}?.let{(task.bytes.toFloat()/it).coerceIn(0f,1f)}
                    if(fraction!=null && task.status==TaskState.DOWNLOADING)LinearProgressIndicator(progress={fraction},modifier=Modifier.fillMaxWidth()) else LinearProgressIndicator(Modifier.fillMaxWidth())
                    Text("${bytes(task.bytes)}"+(task.total?.let{" / ${bytes(it)}"} ?: "")+(task.speed?.let{" · ${bytes(it.toLong())}/s"} ?: "")+(task.eta?.let{" · 剩余 ${duration(it.toDouble())}"} ?: ""),style=MaterialTheme.typography.bodySmall)
                }
                task.error?.let{Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.error)}
                Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){
                    when {
                        task.status.active || task.status==TaskState.QUEUED -> TextButton(onClick={vm.cancel(task)}){Text("取消")}
                        task.status==TaskState.COMPLETED -> {
                            TextButton(onClick={openMedia(context,task,false)}){Text("打开")};TextButton(onClick={openMedia(context,task,true)}){Text("分享")}
                        }
                        else -> TextButton(onClick={vm.retry(task)}){Text("重试")}
                    }
                    if(!task.status.active && task.status!=TaskState.QUEUED)TextButton(onClick={vm.remove(task)}){Text("移除记录")}
                }
            }
        }}
        if(tasks.isNotEmpty())item{Text("移除记录会保留手机中的媒体文件。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
    }
}
@Composable private fun SettingsPage(vm:MainViewModel){
    val context=androidx.compose.ui.platform.LocalContext.current;val scope=rememberCoroutineScope()
    val mobile by vm.allowMobile.collectAsStateWithLifecycle();var importSite by remember{mutableStateOf<Site?>(null)};var refresh by remember{mutableIntStateOf(0)}
    val vault=remember{CookieVault(context)}
    val picker=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()){uri->val site=importSite;if(uri!=null && site!=null)scope.launch{runCatching{withContext(Dispatchers.IO){vault.import(site,uri)}}.onSuccess{refresh++;vm.message.value="已导入${site.label} Cookie。"}.onFailure{vm.message.value=it.message}}}
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(18.dp)){
        item{Text("设置",style=MaterialTheme.typography.headlineSmall,fontWeight=FontWeight.SemiBold)}
        item{Card{Row(Modifier.fillMaxWidth().padding(18.dp),verticalAlignment=Alignment.CenterVertically){Column(Modifier.weight(1f)){Text("允许移动网络下载",style=MaterialTheme.typography.titleSmall);Text("关闭时仅使用非计费网络",style=MaterialTheme.typography.bodySmall)};Switch(checked=mobile,onCheckedChange=vm::mobile)}}}
        item{Text("网站登录状态",style=MaterialTheme.typography.titleMedium);Text("仅在下载页主动选择后使用。Cookie 保存在手机应用私有目录。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
        items(Site.entries){site->Card(colors=CardDefaults.cardColors(containerColor=MaterialTheme.colorScheme.surface)){
            Column(Modifier.fillMaxWidth().padding(14.dp)){
                Text(site.label,style=MaterialTheme.typography.titleSmall)
                Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){
                    TextButton(onClick={context.startActivity(Intent(context,SiteSessionActivity::class.java).putExtra("site",site.name))}){Text("打开网站登录")}
                    TextButton(onClick={importSite=site;picker.launch(arrayOf("text/*","application/octet-stream"))}){Text("导入 Cookie")}
                }
                if(refresh>=0 && vault.hasImported(site))TextButton(onClick={vault.clearImported(site);refresh++}){Text("删除已导入的 Cookie")}
            }
        }}
        item{OutlinedButton(onClick={context.startActivity(Intent(context,SiteSessionActivity::class.java).putExtra("site",Site.BILIBILI.name).putExtra("clear",true))},modifier=Modifier.fillMaxWidth()){Text("退出全部网页登录会话")}}
        item{HorizontalDivider();Spacer(Modifier.height(18.dp));Text("飞羽下载 ${BuildConfig.VERSION_NAME}",style=MaterialTheme.typography.titleMedium);Text("Android 内部测试版 · GPL-3.0\n运行时 ${BuildConfig.RUNTIME_VERSION}\n字幕、直播和播放列表将在后续版本评估。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
    }
}
private fun openMedia(context:Context,task:DownloadTask,share:Boolean){
    val uri=task.outputUri?.let(Uri::parse) ?: return
    runCatching{
        context.contentResolver.openAssetFileDescriptor(uri,"r")?.close() ?: error("文件已移动或删除。")
        val mime=context.contentResolver.getType(uri) ?: "video/*"
        val intent=if(share)Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM,uri) else Intent(Intent.ACTION_VIEW).setDataAndType(uri,mime)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);intent.clipData=ClipData.newRawUri("飞羽下载",uri)
        context.startActivity(if(share)Intent.createChooser(intent,"分享视频")else intent)
    }.onFailure{Toast.makeText(context,it.message ?: "无法打开文件，请检查播放器和媒体文件。",Toast.LENGTH_LONG).show()}
}
private fun bytes(n:Long):String=when{n>=1024*1024*1024->"%.2f GiB".format(n/1073741824.0);n>=1024*1024->"%.1f MiB".format(n/1048576.0);n>=1024->"%.0f KiB".format(n/1024.0);else->"$n B"}
private fun duration(n:Double):String{val s=n.toLong().coerceAtLeast(0);return if(s>=3600)"%d:%02d:%02d".format(s/3600,s/60%60,s%60)else"%d:%02d".format(s/60,s%60)}
