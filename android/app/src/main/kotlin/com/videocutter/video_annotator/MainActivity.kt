package com.videocutter.video_annotator

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val volumeChannelName = "video_annotator/volume_buttons"
    private var volumeChannel: MethodChannel? = null

    private lateinit var hidPlugin: BluetoothHIDPlugin

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Volume key forwarding channel (receive physical buttons → Flutter)
        volumeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            volumeChannelName,
        )

        // BLE HID peripheral channel (Flutter → send HID events to iPhone)
        hidPlugin = BluetoothHIDPlugin(applicationContext)
        val hidChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BluetoothHIDPlugin.CHANNEL,
        )
        hidPlugin.setChannel(hidChannel)
        hidChannel.setMethodCallHandler(hidPlugin)
        hidPlugin.isSupported() // initialise adapter reference
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> volumeChannel?.invokeMethod("volumeUp", null)
                KeyEvent.KEYCODE_VOLUME_DOWN -> volumeChannel?.invokeMethod("volumeDown", null)
            }
        }
        // Always pass through to super so system volume control still works.
        return super.dispatchKeyEvent(event)
    }
}

