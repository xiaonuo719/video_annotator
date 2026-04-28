package com.videocutter.video_annotator

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * BluetoothHIDPlugin — makes this device act as a BLE HID peripheral
 * (media-key keyboard).  When connected to an iPhone and the user taps
 * "Start", the plugin sends a Volume-Up HID report which the iPhone
 * Camera app recognises as "start recording".  A second Volume-Up stops it.
 *
 * Requires Android 9+ (API 28) for BluetoothHidDevice.
 */
@SuppressLint("MissingPermission")
class BluetoothHIDPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "video_annotator/bluetooth_hid"

        // HID report descriptor — Consumer Control (media keys)
        // Usage Page (Consumer), Usage (Consumer Control), ...
        private val HID_REPORT_DESCRIPTOR = byteArrayOf(
            0x05.toByte(), 0x0C.toByte(),       // Usage Page (Consumer)
            0x09.toByte(), 0x01.toByte(),       // Usage (Consumer Control)
            0xA1.toByte(), 0x01.toByte(),       // Collection (Application)
            0x85.toByte(), 0x01.toByte(),       //   Report ID (1)
            0x15.toByte(), 0x00.toByte(),       //   Logical Minimum (0)
            0x25.toByte(), 0x01.toByte(),       //   Logical Maximum (1)
            0x75.toByte(), 0x01.toByte(),       //   Report Size (1 bit)
            0x95.toByte(), 0x02.toByte(),       //   Report Count (2)
            0x09.toByte(), 0xE9.toByte(),       //   Usage (Volume Up)
            0x09.toByte(), 0xEA.toByte(),       //   Usage (Volume Down)
            0x81.toByte(), 0x02.toByte(),       //   Input (Data,Var,Abs)
            0x95.toByte(), 0x06.toByte(),       //   Report Count (6) — padding
            0x81.toByte(), 0x03.toByte(),       //   Input (Const,Var,Abs)
            0xC0.toByte(),                      // End Collection
        )

        private val SDP_SETTINGS = BluetoothHidDeviceAppSdpSettings(
            "Video Annotator Remote",
            "BLE HID Media Keys",
            "VideoAnnotator",
            BluetoothHidDevice.SUBCLASS1_COMBO,
            HID_REPORT_DESCRIPTOR,
        )

        private const val REPORT_ID: Byte = 0x01
        private const val VOLUME_UP_BIT: Byte = 0x01   // bit 0
        private const val VOLUME_DOWN_BIT: Byte = 0x02  // bit 1
        private const val NO_KEY: Byte = 0x00
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    private var bluetoothAdapter: BluetoothAdapter? = null
    private var hidDevice: BluetoothHidDevice? = null
    private var connectedHost: BluetoothDevice? = null
    private var isRegistered = false

    // ---- Public API --------------------------------------------------------

    fun setChannel(ch: MethodChannel) {
        channel = ch
    }

    fun isSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val bm = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bm?.adapter
        return bluetoothAdapter != null
    }

    // ---- MethodChannel.MethodCallHandler -----------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "startAdvertising" -> startAdvertising(result)
            "stopAdvertising" -> stopAdvertising(result)
            "sendVolumeUp" -> sendKey(VOLUME_UP_BIT, result)
            "sendVolumeDown" -> sendKey(VOLUME_DOWN_BIT, result)
            "getConnectionStatus" -> result.success(connectedHost != null)
            else -> result.notImplemented()
        }
    }

    // ---- Bluetooth HID profile callbacks -----------------------------------

    private val hidCallback = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
            isRegistered = registered
            if (!registered) {
                connectedHost = null
                notifyStatus()
            }
        }

        override fun onConnectionStateChanged(device: BluetoothDevice?, state: Int) {
            connectedHost = when (state) {
                BluetoothProfile.STATE_CONNECTED -> device
                BluetoothProfile.STATE_DISCONNECTED -> null
                else -> connectedHost
            }
            notifyStatus()
        }

        override fun onGetReport(device: BluetoothDevice?, type: Byte, id: Byte, bufferSize: Int) {
            hidDevice?.replyReport(device, type, id, ByteArray(1))
        }

        override fun onSetReport(device: BluetoothDevice?, type: Byte, id: Byte, data: ByteArray?) {}
        override fun onSetProtocol(device: BluetoothDevice?, protocol: Byte) {}
        override fun onInterruptData(device: BluetoothDevice?, reportId: Byte, data: ByteArray?) {}
    }

    private val profileListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return
            hidDevice = proxy as? BluetoothHidDevice
            hidDevice?.registerApp(
                SDP_SETTINGS,
                null,
                null,
                context.mainExecutor,
                hidCallback,
            )
        }

        override fun onServiceDisconnected(profile: Int) {
            hidDevice = null
            connectedHost = null
            isRegistered = false
            notifyStatus()
        }
    }

    // ---- Private helpers ---------------------------------------------------

    private fun startAdvertising(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            result.error("UNSUPPORTED", "BluetoothHidDevice requires Android 9+", null)
            return
        }
        val adapter = bluetoothAdapter ?: run {
            result.error("NO_BT", "Bluetooth adapter not available", null)
            return
        }
        adapter.getProfileProxy(context, profileListener, BluetoothProfile.HID_DEVICE)
        result.success(null)
    }

    private fun stopAdvertising(result: MethodChannel.Result) {
        hidDevice?.unregisterApp()
        hidDevice = null
        connectedHost = null
        isRegistered = false
        notifyStatus()
        result.success(null)
    }

    private fun sendKey(keyBit: Byte, result: MethodChannel.Result) {
        val device = connectedHost
        val hid = hidDevice
        if (device == null || hid == null) {
            result.error("NOT_CONNECTED", "No device connected", null)
            return
        }
        // Press
        hid.sendReport(device, REPORT_ID.toInt(), byteArrayOf(keyBit))
        // Release after 50 ms
        mainHandler.postDelayed({
            hid.sendReport(device, REPORT_ID.toInt(), byteArrayOf(NO_KEY))
        }, 50)
        result.success(null)
    }

    private fun notifyStatus() {
        mainHandler.post {
            channel?.invokeMethod("onConnectionChanged", connectedHost != null)
        }
    }
}
