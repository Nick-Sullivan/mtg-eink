package com.nicksullivan.mtg_eink

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The app's own platform code: just the vibrator.
 *
 * The NFC radio lives in the `epaper_nfc` package (`EpaperNfcPlugin.kt`), which registers itself
 * and follows this activity's resume and pause.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val HAPTICS_CHANNEL = "mtg_eink/haptics"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HAPTICS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "buzz" -> {
                        buzz(call.arguments as? Int ?: 1)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * [pulses] firm buzzes, through the vibrator directly. Flutter's HapticFeedback did fire, but
     * as the system's 50 ms touch "tick" — on a Pixel 10a, too faint to notice mid-write.
     */
    private fun buzz(pulses: Int = 1) {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(VIBRATOR_MANAGER_SERVICE) as android.os.VibratorManager)
                .defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as android.os.Vibrator
        }
        runCatching {
            // Firm 150 ms pulses, 100 ms apart: one means "not here", two means "done".
            val timings = mutableListOf(0L)
            repeat(pulses) { i -> if (i > 0) timings += 100L; timings += 150L }
            vibrator.vibrate(android.os.VibrationEffect.createWaveform(timings.toLongArray(), -1))
        }
    }
}
