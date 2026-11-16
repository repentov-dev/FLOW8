import CoreBluetooth
import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let service = CBUUID(string: "14839AD4-8D7E-415C-9A42-167340CF2339")
let charUUID = CBUUID(string: "0034594A-A8E7-4B1A-A6B1-CD5243059A57")

func frame(_ body: [UInt8]) -> Data {
    var b = body
    b.append(b.reduce(0, &+) & 0xFF)
    return Data(b)
}

final class Fake: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!
    var characteristic: CBMutableCharacteristic!

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { return }
        characteristic = CBMutableCharacteristic(type: charUUID,
                                                 properties: [.write, .writeWithoutResponse, .read, .notify],
                                                 value: nil,
                                                 permissions: [.writeable, .readable])
        let s = CBMutableService(type: service, primary: true)
        s.characteristics = [characteristic]
        p.add(s)
        p.startAdvertising([
            CBAdvertisementDataLocalNameKey: "FLOW 8 LE",
            CBAdvertisementDataServiceUUIDsKey: [service],
            CBAdvertisementDataServiceDataKey: [service.uuidString: Data([0x00, 0x7b, 0xc6, 0xad, 0xd2, 0xf2, 0xad])]
        ])
        print("FAKE advertising")
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let hex = r.value?.map { String(format: "%02x", $0) }.joined() ?? ""
            print("FAKE write \(hex)")
            if let v = r.value, v.first == 0x39 {
                p.respond(to: r, withResult: .success)
                let reply = frame([0x36, 0x01, 0x37])
                p.updateValue(reply, for: characteristic, onSubscribedCentrals: nil)
                print("FAKE sent 36 01 37")
                return
            }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        print("FAKE read")
        request.value = Data([0x09, 0x00])
        p.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("FAKE subscribed \(central.identifier)")
    }
}

let f = Fake()
f.start()
RunLoop.main.run()
