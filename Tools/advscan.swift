import CoreBluetooth
import Foundation
setvbuf(stdout, nil, _IONBF, 0)

final class S: NSObject, CBCentralManagerDelegate {
    var m: CBCentralManager!
    func start() { m = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { c.scanForPeripherals(withServices: nil, options: nil) }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? ""
        guard name.contains("FLOW") else { return }
        print("DEV", name, p.identifier.uuidString, "rssi", rssi)
        for (k, v) in advertisementData {
            if let d = v as? Data { print("  ", k, d.map { String(format: "%02x", $0) }.joined()) }
            else { print("  ", k, v) }
        }
    }
}
let s = S(); s.start()
RunLoop.current.run(until: Date().addingTimeInterval(12))
