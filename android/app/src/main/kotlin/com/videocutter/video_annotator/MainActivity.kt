package com.videocutter.video_annotator

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "video_annotator/volume_buttons"
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> channel?.invokeMethod("volumeUp", null)
                KeyEvent.KEYCODE_VOLUME_DOWN -> channel?.invokeMethod("volumeDown", null)
            }
        }
        // Always pass through to super so system volume control still works.
        return super.dispatchKeyEvent(event)
    }
}
