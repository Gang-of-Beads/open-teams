package io.github.gangofbeads.openteams.call

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.appcompat.app.AppCompatActivity
import io.github.gangofbeads.openteams.MainActivity
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
        binding.acceptAudio.setOnClickListener { answer(MainActivity.ACTION_ANSWER_AUDIO) }
        binding.acceptVideo.setOnClickListener { answer(MainActivity.ACTION_ANSWER_VIDEO) }
    }

    /** MainActivity asks for the microphone (and camera) before Teams picks up. */
    private fun answer(action: String) {
        startActivity(Intent(this, MainActivity::class.java).setAction(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
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
