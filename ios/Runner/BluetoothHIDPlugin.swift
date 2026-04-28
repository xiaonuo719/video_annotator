import CoreBluetooth
import Flutter

// ---------------------------------------------------------------------------
// BluetoothHIDPlugin.swift
//
// Turns this iOS/iPadOS device into a BLE HID peripheral (Consumer Control /
// media keys).  Once an iPhone pairs with it, calling sendVolumeUp() sends a
// single Volume-Up HID report which the iPhone Camera app recognises as a
// shutter / record trigger.
// ---------------------------------------------------------------------------

@objc class BluetoothHIDPlugin: NSObject, FlutterPlugin, CBPeripheralManagerDelegate {

    // MARK: — Constants

    static let channelName = "video_annotator/bluetooth_hid"

    // BLE HID service / characteristic UUIDs (Bluetooth SIG assigned)
    private let hidServiceUUID          = CBUUID(string: "1812")
    private let reportMapUUID           = CBUUID(string: "2A4B")
    private let hidInfoUUID             = CBUUID(string: "2A4A")
    private let hidControlPointUUID     = CBUUID(string: "2A4C")
    private let protocolModeUUID        = CBUUID(string: "2A4E")
    private let reportUUID              = CBUUID(string: "2A4D")
    private let reportRefDescriptorUUID = CBUUID(string: "2908")
    private let cccdUUID                = CBUUID(string: "2902")

    // Device Information service
    private let deviceInfoUUID          = CBUUID(string: "180A")
    private let pnpIdUUID               = CBUUID(string: "2A50")

    // HID Report Descriptor — Consumer Control (media keys)
    // Report ID 1, 2 bits: bit-0 = Volume Up (0xE9), bit-1 = Volume Down (0xEA)
    private let hidReportDescriptor: [UInt8] = [
        0x05, 0x0C,         // Usage Page (Consumer)
        0x09, 0x01,         // Usage (Consumer Control)
        0xA1, 0x01,         // Collection (Application)
        0x85, 0x01,         //   Report ID (1)
        0x15, 0x00,         //   Logical Minimum (0)
        0x25, 0x01,         //   Logical Maximum (1)
        0x75, 0x01,         //   Report Size (1 bit)
        0x95, 0x02,         //   Report Count (2)
        0x09, 0xE9,         //   Usage (Volume Up)
        0x09, 0xEA,         //   Usage (Volume Down)
        0x81, 0x02,         //   Input (Data,Var,Abs)
        0x95, 0x06,         //   Report Count (6) — padding
        0x81, 0x03,         //   Input (Const,Var,Abs)
        0xC0,               // End Collection
    ]

    // MARK: — State

    private var peripheralManager: CBPeripheralManager?
    private var inputReportCharacteristic: CBMutableCharacteristic?
    private var subscribedCentral: CBCentral?
    private var isAdvertising = false

    private var channel: FlutterMethodChannel?

    // MARK: — FlutterPlugin registration

    static func register(with registrar: FlutterPluginRegistrar) {
        let ch = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = BluetoothHIDPlugin()
        instance.channel = ch
        registrar.addMethodCallDelegate(instance, channel: ch)
    }

    // MARK: — FlutterPlugin method handler

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            result(true)   // CoreBluetooth is always available on iOS/iPadOS

        case "startAdvertising":
            startAdvertising(result: result)

        case "stopAdvertising":
            stopAdvertising(result: result)

        case "sendVolumeUp":
            sendKey(bit: 0x01, result: result)

        case "sendVolumeDown":
            sendKey(bit: 0x02, result: result)

        case "getConnectionStatus":
            result(subscribedCentral != nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: — Advertising

    private func startAdvertising(result: @escaping FlutterResult) {
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        }
        // Actual advertising starts once peripheralManagerDidUpdateState fires.
        isAdvertising = true
        result(nil)
    }

    private func stopAdvertising(result: @escaping FlutterResult) {
        isAdvertising = false
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        subscribedCentral = nil
        peripheralManager = nil
        notifyConnectionChanged(connected: false)
        result(nil)
    }

    // MARK: — Key report

    private func sendKey(bit: UInt8, result: @escaping FlutterResult) {
        guard let central = subscribedCentral,
              let char = inputReportCharacteristic,
              let pm = peripheralManager else {
            result(FlutterError(code: "NOT_CONNECTED",
                                message: "No device connected",
                                details: nil))
            return
        }
        // Press
        pm.updateValue(Data([bit]), for: char, onSubscribedCentrals: [central])
        // Release after 50 ms
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pm.updateValue(Data([0x00]), for: char, onSubscribedCentrals: [central])
        }
        result(nil)
    }

    // MARK: — CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn, isAdvertising else { return }
        setupServices(peripheral)
    }

    private func setupServices(_ peripheral: CBPeripheralManager) {
        peripheral.removeAllServices()

        // ---- HID Information (read, static) --------------------------------
        let hidInfo = CBMutableCharacteristic(
            type: hidInfoUUID,
            properties: .read,
            value: Data([0x11, 0x01, 0x00, 0x03]),  // HID 1.11, country 0, flags remote-wake|normally-connectable
            permissions: .readable
        )

        // ---- Report Map (read, static) -------------------------------------
        let reportMap = CBMutableCharacteristic(
            type: reportMapUUID,
            properties: .read,
            value: Data(hidReportDescriptor),
            permissions: .readable
        )

        // ---- Protocol Mode (read/write, boot protocol = 0x01) --------------
        let protocolMode = CBMutableCharacteristic(
            type: protocolModeUUID,
            properties: [.read, .writeWithoutResponse],
            value: Data([0x01]),
            permissions: [.readable, .writeable]
        )

        // ---- HID Control Point (write-no-response) --------------------------
        let controlPoint = CBMutableCharacteristic(
            type: hidControlPointUUID,
            properties: .writeWithoutResponse,
            value: nil,
            permissions: .writeable
        )

        // ---- Input Report (notify) -----------------------------------------
        let cccd = CBMutableDescriptor(
            type: cccdUUID,
            value: Data([0x01, 0x00])  // notify enabled
        )
        // Report Reference: Report ID = 1, Input = 1
        let reportRef = CBMutableDescriptor(
            type: reportRefDescriptorUUID,
            value: Data([0x01, 0x01])
        )
        let inputReport = CBMutableCharacteristic(
            type: reportUUID,
            properties: [.read, .notify, .notifyEncryptionRequired],
            value: nil,
            permissions: [.readable, .readEncryptionRequired]
        )
        inputReport.descriptors = [cccd, reportRef]
        inputReportCharacteristic = inputReport

        // ---- HID Service ---------------------------------------------------
        let hidService = CBMutableService(type: hidServiceUUID, primary: true)
        hidService.characteristics = [
            hidInfo, reportMap, protocolMode, controlPoint, inputReport,
        ]

        // ---- Device Information Service ------------------------------------
        let pnpId = CBMutableCharacteristic(
            type: pnpIdUUID,
            properties: .read,
            value: Data([0x01, 0xD2, 0x05, 0xAB, 0xCD, 0x00, 0x01]),
            permissions: .readable
        )
        let deviceInfoService = CBMutableService(type: deviceInfoUUID, primary: true)
        deviceInfoService.characteristics = [pnpId]

        peripheral.add(deviceInfoService)
        peripheral.add(hidService)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        // Start advertising once all services are added (HID service is last)
        if service.uuid == hidServiceUUID {
            peripheral.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [hidServiceUUID],
                CBAdvertisementDataLocalNameKey: "Video Annotator",
            ])
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        subscribedCentral = central
        notifyConnectionChanged(connected: true)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        if subscribedCentral == central {
            subscribedCentral = nil
            notifyConnectionChanged(connected: false)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        if let char = request.characteristic as? CBMutableCharacteristic,
           let val = char.value {
            request.value = val.subdata(in: request.offset..<val.count)
            peripheral.respond(to: request, withResult: .success)
        } else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            peripheral.respond(to: request, withResult: .success)
        }
    }

    // MARK: — Helpers

    private func notifyConnectionChanged(connected: Bool) {
        DispatchQueue.main.async {
            self.channel?.invokeMethod("onConnectionChanged", arguments: connected)
        }
    }
}
