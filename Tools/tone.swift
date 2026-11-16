import AVFoundation
import CoreAudio
import Foundation
setvbuf(stdout, nil, _IONBF, 0)

func deviceID(named name: String) -> AudioDeviceID? {
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
    for device in devices {
        var nameSize: UInt32 = 0
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(device, &nameAddress, 0, nil, &nameSize) == noErr else { continue }
        var cfName: CFString = "" as CFString
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &cfName) == noErr else { continue }
        if (cfName as String).contains(name) { return device }
    }
    return nil
}

guard let device = deviceID(named: "FLOW 8") else {
    print("FLOW 8 output not found"); exit(1)
}
print("device id", device)

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
engine.connect(player, to: engine.mainMixerNode, format: format)

var outputDevice = device
if let au = engine.outputNode.audioUnit {
    AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                         kAudioUnitScope_Global, 0, &outputDevice,
                         UInt32(MemoryLayout<AudioDeviceID>.size))
}
try engine.start()
print("engine running", engine.isRunning, "out format", engine.outputNode.outputFormat(forBus: 0))

let frames = AVAudioFrameCount(48000 * 2)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
buffer.frameLength = frames
let data = buffer.floatChannelData!
for channel in 0..<2 {
    for frame in 0..<Int(frames) {
        data[channel][frame] = 0.2 * sin(2 * .pi * 1000 * Float(frame) / 48000)
    }
}
player.scheduleBuffer(buffer, at: nil, options: .loops)
player.play()
print("tone playing…")
Thread.sleep(forTimeInterval: 14)
