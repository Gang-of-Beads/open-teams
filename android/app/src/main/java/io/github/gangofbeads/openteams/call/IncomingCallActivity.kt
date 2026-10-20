package io.github.gangofbeads.openteams.call

import android.os.Bundle
import android.view.View
import androidx.appcompat.app.AppCompatActivity
import io.github.gangofbeads.openteams.databinding.ActivityIncomingCallBinding

/**
 * Full-screen ringing screen (shown over the lock screen), laid out like the
 * native app's pre-call screen: caller, then decline / video / audio.
 */
class IncomingCallActivity : AppCompatActivity() {
    private lateinit var binding: ActivityIncomingCallBinding
    private val listener: () -> Unit = { render() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityIncomingCallBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.decline.setOnClickListener { CallController.decline() }
        binding.acceptAudio.setOnClickListener { CallController.answer(video = false) }
        binding.acceptVideo.setOnClickListener { CallController.answer(video = true) }
    }

    override fun onStart() {
        super.onStart()
        CallController.addListener(listener)
        render()
    }

    override fun onStop() {
        CallController.removeListener(listener)
        super.onStop()
    }

    private fun render() {
        val incoming = CallController.incoming
        if (incoming == null) {
            finish()
            return
        }
        binding.caller.text = incoming.caller
        binding.subtitle.text = incoming.subtitle
        binding.initials.text = incoming.caller.split(' ').filter { it.isNotBlank() }.take(2)
            .joinToString("") { it.first().uppercase() }
        binding.avatar.setImageBitmap(incoming.avatar)
        binding.avatar.visibility = if (incoming.avatar != null) View.VISIBLE else View.GONE
    }
}
