package io.github.gangofbeads.openteams.web

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import io.github.gangofbeads.openteams.R

object ExternalLinks {
    fun open(context: Context, uri: Uri) {
        val intent = if (uri.scheme == "intent") {
            runCatching { Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME) }.getOrNull()
                ?.apply {
                    // Never let a page target a specific (possibly non-exported) component.
                    component = null
                    selector = null
                    addCategory(Intent.CATEGORY_BROWSABLE)
                } ?: return
        } else {
            Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
        }
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(context, R.string.no_app_for_link, Toast.LENGTH_SHORT).show()
        }
    }
}
