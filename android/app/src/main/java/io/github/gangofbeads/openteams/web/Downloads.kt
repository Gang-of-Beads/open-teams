package io.github.gangofbeads.openteams.web

import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.webkit.CookieManager
import android.webkit.URLUtil
import android.widget.Toast
import io.github.gangofbeads.openteams.OpenTeamsApp
import io.github.gangofbeads.openteams.R
import kotlin.concurrent.thread

object Downloads {
    fun onDownload(url: String, userAgent: String, contentDisposition: String?, mimeType: String?, contentLength: Long) {
        val app = OpenTeamsApp.instance
        val name = URLUtil.guessFileName(url, contentDisposition, mimeType)
        when {
            // Blob URLs only exist inside the page; it reads the bytes and sends them back as "save-file".
            url.startsWith("blob:") -> TeamsWeb.bridge.emit("download-blob", url, name)
            url.startsWith("https:") || url.startsWith("http:") -> {
                val request = DownloadManager.Request(Uri.parse(url))
                    .setMimeType(mimeType)
                    .addRequestHeader("User-Agent", userAgent)
                    .setTitle(name)
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name)
                CookieManager.getInstance().getCookie(url)?.let { request.addRequestHeader("Cookie", it) }
                (app.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager).enqueue(request)
                Toast.makeText(app, app.getString(R.string.downloading, name), Toast.LENGTH_SHORT).show()
            }
        }
    }

    fun saveDataUrl(rawName: String, dataUrl: String) {
        val app = OpenTeamsApp.instance
        val comma = dataUrl.indexOf(',')
        if (!dataUrl.startsWith("data:") || comma < 0) return
        val mime = dataUrl.substring(5, comma).substringBefore(';').ifBlank { "application/octet-stream" }
        val name = rawName.substringAfterLast('/').substringAfterLast('\\').ifBlank { "download" }
        thread {
            val saved = runCatching {
                val bytes = Base64.decode(dataUrl.substring(comma + 1), Base64.DEFAULT)
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name)
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                }
                val uri = app.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)!!
                app.contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }
            }.isSuccess
            val message = if (saved) app.getString(R.string.downloaded, name) else app.getString(R.string.download_failed)
            android.os.Handler(app.mainLooper).post { Toast.makeText(app, message, Toast.LENGTH_SHORT).show() }
        }
    }
}
