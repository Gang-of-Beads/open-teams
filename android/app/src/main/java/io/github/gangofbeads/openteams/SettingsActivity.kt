package io.github.gangofbeads.openteams

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.preference.Preference
import androidx.preference.PreferenceFragmentCompat
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import io.github.gangofbeads.openteams.databinding.ActivitySettingsBinding
import io.github.gangofbeads.openteams.web.TeamsWeb

class SettingsActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.toolbar.setNavigationOnClickListener { finish() }
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.updatePadding(left = bars.left, top = bars.top, right = bars.right, bottom = bars.bottom)
            insets
        }
        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction().replace(R.id.settings, SettingsFragment()).commit()
        }
    }

    class SettingsFragment : PreferenceFragmentCompat() {
        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            setPreferencesFromResource(R.xml.preferences, rootKey)
            val context = requireContext()
            val appUri = Uri.fromParts("package", context.packageName, null)

            link("full_screen_calls") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    Intent(AndroidSettings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, appUri)
                } else {
                    Intent(AndroidSettings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(AndroidSettings.EXTRA_APP_PACKAGE, context.packageName)
                }
            }
            link("notification_settings") {
                Intent(AndroidSettings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(AndroidSettings.EXTRA_APP_PACKAGE, context.packageName)
            }
            link("battery") { Intent(AndroidSettings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS) }
            findPreference<Preference>("sign_out")?.setOnPreferenceClickListener {
                MaterialAlertDialogBuilder(context)
                    .setMessage(R.string.sign_out_confirm)
                    .setNegativeButton(android.R.string.cancel, null)
                    .setPositiveButton(R.string.sign_out) { _, _ -> TeamsWeb.signOut() }
                    .show()
                true
            }
            findPreference<Preference>("about")?.summary = getString(R.string.about_summary, BuildConfig.VERSION_NAME)
        }

        private fun link(key: String, intent: () -> Intent) {
            findPreference<Preference>(key)?.setOnPreferenceClickListener {
                runCatching { startActivity(intent()) }
                true
            }
        }
    }
}
