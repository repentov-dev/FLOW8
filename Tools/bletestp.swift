import CoreBluetooth
import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let service = CBUUID(string: "14839AD4-8D7E-415C-9A42-167340CF2339")
let char = CBUUID(string: "0034594A-A8E7-4B1A-A6B1-CD5243059A57")

final class P: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!
    func start() {
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("peripheral state", peripheral.state.rawValue)
        guard peripheral.state == .poweredOn else { return }
        let c = CBMutableCharacteristic(type: char, properties: [.write, .writeWithoutResponse, .read, .notify], value: nil, permissions: [.writeable, .readable])
        let s = CBMutableService(type: service, primary: true)
        s.characteristics = [c]
        manager.add(s)
        manager.startAdvertising([CBAdvertisementDataLocalNameKey: "FLOW 8 LE", CBAdvertisementDataServiceUUIDsKey: [service]])
        print("advertising")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        print("added service", error?.localizedDescription ?? "ok")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests { print("write", r.value?.map { String(format: "%02x", $0) }.joined() ?? "", "offset", r.offset) }
        peripheral.respond(to: requests[0], withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        print("read")
        peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("subscribed", central.identifier)
    }
}

let p = P()
p.start()
RunLoop.current.run(until: Date().addingTimeInterval(25))
