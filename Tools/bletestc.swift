import CoreBluetooth
import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let service = CBUUID(string: "14839AD4-8D7E-415C-9A42-167340CF2339")
final class C: NSObject, CBCentralManagerDelegate {
    var m: CBCentralManager!
    func start() { m = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("central state", c.state.rawValue)
        if c.state == .poweredOn { c.scanForPeripherals(withServices: [service], options: nil) }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        print("found", p.name ?? "?", "rssi", rssi)
    }
}
let c = C(); c.start()
RunLoop.current.run(until: Date().addingTimeInterval(20))
