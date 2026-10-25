package com.example.pulsepath

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.speech.tts.TextToSpeech
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** One lazily allocated engine; pending speech is discarded on stop/destroy. */
class VoiceGuidance(private val context: Context) {
    private var engine: TextToSpeech? = null
    private var ready = false
    private var destroyed = false
    private val waiting = mutableListOf<MethodChannel.Result>()

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepare(result)
            "speak" -> {
                val text = call.argument<String>("text")?.take(1000).orEmpty()
                if (!ready || text.isBlank()) result.success(false)
                else if (call.argument<Boolean>("navigation") != true && engine?.isSpeaking == true) result.success(false)
                else result.success(engine?.speak(text, TextToSpeech.QUEUE_FLUSH, null,
                    "pulsepath-${System.nanoTime()}") == TextToSpeech.SUCCESS)
            }
            "stop" -> { engine?.stop(); result.success(null) }
            "settings" -> {
                try {
                    context.startActivity(Intent("com.android.settings.TTS_SETTINGS")
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                } catch (_: Exception) {
                    result.error("SETTINGS", "Откройте настройки синтеза речи телефона", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun prepare(result: MethodChannel.Result) {
        if (destroyed) { result.success(false); return }
        if (ready) { result.success(true); return }
        waiting.add(result)
        if (engine != null) return
        engine = TextToSpeech(context.applicationContext) { status ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                if (destroyed) return@post
                val tts = engine
                var available = false
                if (status == TextToSpeech.SUCCESS && tts != null) {
                    val language = tts.setLanguage(Locale.forLanguageTag("ru-RU"))
                    available = language >= TextToSpeech.LANG_AVAILABLE
                    if (available) {
                        // Prefer an installed voice that works without a network connection.
                        val offline = tts.voices?.firstOrNull {
                            it.locale.language == "ru" && !it.isNetworkConnectionRequired &&
                                !it.features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)
                        }
                        available = offline != null && tts.setVoice(offline) == TextToSpeech.SUCCESS
                        tts.setSpeechRate(1.0f)
                        tts.setAudioAttributes(AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    }
                }
                ready = available
                val callbacks = waiting.toList()
                waiting.clear()
                if (!available) { engine?.shutdown(); engine = null }
                callbacks.forEach {
                    if (available) it.success(true)
                    else it.error("VOICE_UNAVAILABLE",
                        "Установите русский голос в настройках синтеза речи телефона", null)
                }
            }
        }
    }

    fun close() {
        destroyed = true
        waiting.forEach { it.success(false) }
        waiting.clear()
        engine?.stop()
        engine?.shutdown()
        engine = null
        ready = false
    }
}
