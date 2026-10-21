package app.compii.compii

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Compii speaks with the phone's own text-to-speech voice: free and on the phone. */
class MainActivity : FlutterActivity() {
    private var tts: TextToSpeech? = null
    private var ready = false
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "compii/speech")
        channel = ch
        tts = TextToSpeech(this) { status ->
            ready = status == TextToSpeech.SUCCESS
            if (ready) tts?.language = Locale.getDefault()
        }
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) = post("start")
            override fun onDone(id: String?) = post("done")
            override fun onStop(id: String?, interrupted: Boolean) = post("done")
            @Deprecated("Deprecated in Java")
            override fun onError(id: String?) = post("done")
        })
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    if (!ready) {
                        result.success(false)
                    } else {
                        tts?.speak(call.argument<String>("text") ?: "", TextToSpeech.QUEUE_FLUSH, null, "compii")
                        result.success(true)
                    }
                }
                "stop" -> {
                    tts?.stop()
                    result.success(true)
                }
                "chime" -> {
                    val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 70)
                    tone.startTone(ToneGenerator.TONE_PROP_ACK, 180)
                    Handler(Looper.getMainLooper()).postDelayed({ tone.release() }, 300)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun post(event: String) {
        runOnUiThread { channel?.invokeMethod(event, null) }
    }

    override fun onDestroy() {
        tts?.shutdown()
        super.onDestroy()
    }
}
