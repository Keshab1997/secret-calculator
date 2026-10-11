package com.keshabstudios.calculator

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "com.keshabstudios.calculator/native"
    private val requestRecordAudioCode = 7001

    private var mediaRecorder: MediaRecorder? = null
    private var mediaPlayer: MediaPlayer? = null
    private var ringtonePlayer: MediaPlayer? = null
    private var ringtoneVibrator: Vibrator? = null
    private var currentRecordingPath: String? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureMicPermission" -> ensureMicPermission(result)
                    "startRecording" -> startRecording(result)
                    "stopRecording" -> stopRecording(result)
                    "playAudio" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("INVALID_PATH", "Audio path is empty", null)
                        } else {
                            playAudio(path, result)
                        }
                    }
                    "stopAudio" -> {
                        stopAudioInternal()
                        result.success(true)
                    }
                    "setSpeakerphone" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        @Suppress("DEPRECATION")
                        audioManager.isSpeakerphoneOn = enabled
                        result.success(true)
                    }
                    "setSecureScreen" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(true)
                    }
                    "startRingtone" -> startRingtone(
                        result,
                        call.argument<String>("mode") ?: "sound"
                    )
                    "stopRingtone" -> {
                        stopRingtoneInternal()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun ensureMicPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), requestRecordAudioCode)
    }

    private fun startRecording(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            result.error("PERMISSION_DENIED", "Microphone permission not granted", null)
            return
        }
        try {
            stopRecordingInternal()
            val outFile = File(cacheDir, "voice_${System.currentTimeMillis()}.m4a")
            val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioEncodingBitRate(64000)
            recorder.setAudioSamplingRate(22050)
            recorder.setOutputFile(outFile.absolutePath)
            recorder.prepare()
            recorder.start()
            mediaRecorder = recorder
            currentRecordingPath = outFile.absolutePath
            result.success(outFile.absolutePath)
        } catch (e: Exception) {
            stopRecordingInternal()
            result.error("RECORD_ERROR", e.message ?: "Failed to start recording", null)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        val path = currentRecordingPath
        try {
            mediaRecorder?.apply {
                stop()
                release()
            }
            mediaRecorder = null
            currentRecordingPath = null
            result.success(path)
        } catch (e: Exception) {
            stopRecordingInternal()
            result.success(null)
        }
    }

    private fun stopRecordingInternal() {
        try {
            mediaRecorder?.apply {
                stop()
            }
        } catch (_: Exception) {
        }
        try {
            mediaRecorder?.release()
        } catch (_: Exception) {
        }
        mediaRecorder = null
        currentRecordingPath = null
    }

    private fun playAudio(path: String, result: MethodChannel.Result) {
        try {
            stopAudioInternal()
            val player = MediaPlayer()
            player.setDataSource(path)
            player.setOnCompletionListener {
                stopAudioInternal()
            }
            player.prepare()
            player.start()
            mediaPlayer = player
            result.success(player.duration)
        } catch (e: Exception) {
            stopAudioInternal()
            result.error("PLAY_ERROR", e.message ?: "Failed to play audio", null)
        }
    }

    private fun stopAudioInternal() {
        try {
            mediaPlayer?.apply {
                if (isPlaying) {
                    stop()
                }
                release()
            }
        } catch (_: Exception) {
        }
        mediaPlayer = null
    }

    private fun startRingtone(result: MethodChannel.Result, mode: String) {
        try {
            stopRingtoneInternal()
            when (mode) {
                // Alert with vibration only — the call appears quietly on
                // screen, no audio.
                "vibrate" -> startRingVibration()
                // Fully quiet: neither audio nor vibration.
                "silent" -> Unit
                else -> {
                    val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                    val player = MediaPlayer()
                    player.setDataSource(this, uri)
                    player.setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                    player.isLooping = true
                    player.prepare()
                    player.start()
                    ringtonePlayer = player
                    startRingVibration()
                }
            }
            result.success(true)
        } catch (e: Exception) {
            stopRingtoneInternal()
            result.error("RING_ERROR", e.message ?: "Failed to start ringtone", null)
        }
    }

    private fun startRingVibration() {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val manager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                manager.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            ringtoneVibrator = vibrator
            val pattern = longArrayOf(0, 1000, 800)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, 0)
            }
        } catch (_: Exception) {
        }
    }

    private fun stopRingtoneInternal() {
        try {
            ringtonePlayer?.apply {
                if (isPlaying) {
                    stop()
                }
                release()
            }
        } catch (_: Exception) {
        }
        ringtonePlayer = null
        try {
            ringtoneVibrator?.cancel()
        } catch (_: Exception) {
        }
        ringtoneVibrator = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == requestRecordAudioCode) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    override fun onDestroy() {
        stopRecordingInternal()
        stopAudioInternal()
        stopRingtoneInternal()
        super.onDestroy()
    }
}
