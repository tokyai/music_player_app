package com.example.music_player_app

import android.media.audiofx.AudioEffect
import android.media.audiofx.BassBoost
import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.Equalizer
import android.media.audiofx.Virtualizer
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.ln

/** Engine-scoped so background playback and Activity rotation keep their effects. */
@Suppress("DEPRECATION")
class AudioEffectsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var owner = -1L
    private var sessionId: Int? = null
    private var equalizer: Equalizer? = null
    private var bass: BassBoost? = null
    private var surround: Virtualizer? = null
    private var balance: AudioEffect? = null
    private val frequencies = doubleArrayOf(31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "music_player/audio_effects").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        releaseAll()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "apply" && call.method != "release") {
            result.notImplemented()
            return
        }
        val requestedOwner = call.argument<Number>("owner")?.toLong() ?: -1L
        if (call.method == "release") {
            if (requestedOwner == owner) releaseAll()
            result.success(null)
            return
        }
        // A closing profile may finish a queued call after the next player starts.
        if (requestedOwner < owner) {
            result.success(mapOf("failures" to emptyList<String>()))
            return
        }
        val failures = mutableListOf<String>()
        try {
            val id = call.argument<Number>("sessionId")?.toInt()?.takeIf { it > 0 }
            if (id != sessionId || requestedOwner != owner) releaseAll()
            owner = requestedOwner
            sessionId = id
            if (id != null) apply(call, id, failures)
        } catch (error: RuntimeException) {
            Log.w("AudioEffects", "Invalid audio effect request", error)
            releaseAll()
            failures.add("音效引擎")
        }
        result.success(mapOf("failures" to failures))
    }

    private fun apply(call: MethodCall, id: Int, failures: MutableList<String>) {
        val master = call.argument<Boolean>("enabled") == true
        fun enabled(key: String) = master && call.argument<Boolean>(key) == true
        fun number(key: String, min: Double, max: Double): Double {
            val value = call.argument<Number>(key)?.toDouble() ?: min
            require(value.isFinite() && value in min..max)
            return value
        }
        val values = call.argument<List<*>>("bands") ?: emptyList<Any>()
        require(values.size == 10)
        val gains = values.map {
            val gain = (it as? Number)?.toDouble() ?: throw IllegalArgumentException("Invalid EQ")
            require(gain.isFinite() && gain in -12.0..12.0)
            gain
        }
        val bassStrength = number("bassStrength", 0.0, 1.0)
        val surroundStrength = number("surroundStrength", 0.0, 0.7)
        val balanceValue = number("balance", -1.0, 1.0)

        val eqOn = enabled("equalizerEnabled")
        effect("均衡器", failures, { release(equalizer); equalizer = null }) {
            val eq = equalizer ?: if (eqOn) Equalizer(0, id).also { equalizer = it } else return@effect
            val range = eq.bandLevelRange
            for (index in 0 until eq.numberOfBands.toInt()) {
                // Device EQs often have 5 bands, not the 10 shown by the UI.
                // Map by actual center frequency, never by array index.
                val hz = eq.getCenterFreq(index.toShort()) / 1000.0
                val gain = if (eqOn) interpolatedGain(hz, gains) else 0.0
                eq.setBandLevel(index.toShort(), (gain * 100).toInt().coerceIn(range[0].toInt(), range[1].toInt()).toShort())
            }
            check(eq.setEnabled(true) == AudioEffect.SUCCESS)
        }
        val bassOn = enabled("bassEnabled")
        effect("低音增强", failures, { release(bass); bass = null }) {
            val effect = bass ?: if (bassOn) BassBoost(0, id).also { bass = it } else return@effect
            check(effect.strengthSupported)
            effect.setStrength((if (bassOn) bassStrength * 1000 else 0.0).toInt().toShort())
            check(effect.setEnabled(true) == AudioEffect.SUCCESS)
        }
        val surroundOn = enabled("surroundEnabled")
        effect("环绕", failures, { release(surround); surround = null }) {
            val effect = surround ?: if (surroundOn) Virtualizer(0, id).also { surround = it } else return@effect
            check(effect.strengthSupported)
            effect.setStrength((if (surroundOn) surroundStrength * 1000 else 0.0).toInt().toShort())
            check(effect.setEnabled(true) == AudioEffect.SUCCESS)
        }
        val balanceOn = enabled("balanceEnabled")
        effect("声道平衡", failures, { release(balance); balance = null }) {
            if (!balanceOn && balance == null) return@effect
            check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            applyBalance(id, if (balanceOn) balanceValue else 0.0)
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.P)
    private fun applyBalance(id: Int, value: Double) {
        val dp = balance as? DynamicsProcessing ?: run {
            val config = DynamicsProcessing.Config.Builder(
                DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
                2, false, 0, false, 0, false, 0, false,
            ).build()
            DynamicsProcessing(0, id, config).also { balance = it }
        }
        check(dp.channelCount >= 2)
        // DynamicsProcessing uses dB (not Equalizer's millibels). Attenuate only.
        dp.setInputGainbyChannel(0, if (value > 0) (-60 * value).toFloat() else 0f)
        dp.setInputGainbyChannel(1, if (value < 0) (60 * value).toFloat() else 0f)
        check(dp.setEnabled(true) == AudioEffect.SUCCESS)
    }

    private fun interpolatedGain(hz: Double, gains: List<Double>): Double {
        if (hz <= frequencies.first()) return gains.first()
        for (index in 1 until frequencies.size) {
            if (hz <= frequencies[index]) {
                val fraction = ln(hz / frequencies[index - 1]) / ln(frequencies[index] / frequencies[index - 1])
                return gains[index - 1] + fraction * (gains[index] - gains[index - 1])
            }
        }
        return gains.last()
    }

    private inline fun effect(name: String, failures: MutableList<String>, cleanup: () -> Unit, apply: () -> Unit) {
        try {
            apply()
        } catch (error: RuntimeException) {
            cleanup()
            failures.add(name)
            Log.w("AudioEffects", "$name unavailable", error)
        }
    }

    private fun release(effect: AudioEffect?) {
        if (effect == null) return
        try { effect.enabled = false } catch (error: RuntimeException) { Log.w("AudioEffects", "Disable failed", error) }
        try { effect.release() } catch (error: RuntimeException) { Log.w("AudioEffects", "Release failed", error) }
    }

    private fun releaseAll() {
        release(equalizer)
        release(bass)
        release(surround)
        release(balance)
        equalizer = null
        bass = null
        surround = null
        balance = null
        sessionId = null
    }
}
