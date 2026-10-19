package io.feather.videodownloader.android.download

import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class HttpLimitsTest {
    @Test fun aStalledWebsiteBodyCannotOutliveTheParsingDeadline() {
        val server=ServerSocket(0,1,InetAddress.getByName("127.0.0.1"))
        val release=CountDownLatch(1)
        val responder=Thread {
            try {server.accept().use{socket->
                val input=socket.getInputStream().bufferedReader()
                while(!input.readLine().isNullOrBlank()){}
                socket.getOutputStream().apply{write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".toByteArray());flush()}
                release.await(3,TimeUnit.SECONDS)
            }}catch(_:Exception){}
        }.apply{isDaemon=true;start()}
        val started=System.nanoTime()
        try {
            assertNotNull(runCatching{DownloadEngine.http("http://127.0.0.1:${server.localPort}/",deadlineNanos=started+300_000_000)}.exceptionOrNull())
            assertTrue("The response-body read must respect the total deadline",(System.nanoTime()-started)/1_000_000<2000)
        }finally{release.countDown();server.close();responder.join(1000)}
    }
}
