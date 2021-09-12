// Resolve MAC address and device name of BLE device from SQLite database at /Library/Bluetooth introduced in Monterey.

import SQLite3

private var inited = false
private var db_paired: OpaquePointer?
private var db_other: OpaquePointer?

private func connect() {
    if inited { return }

    if sqlite3_open("/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.paired.db", &db_paired) == SQLITE_OK {
        print("paired.db open success")
    } else {
        db_paired = nil
    }

    if sqlite3_open("/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.other.db", &db_other) == SQLITE_OK {
        print("other.db open success")
    } else {
        db_other = nil
    }

    inited = true
}

struct LEDeviceInfo {
    var name: String?
    var macAddr: String?
}

private func getStringFromRow(stmt: OpaquePointer?, index: Int32) -> String? {
    if sqlite3_column_type(stmt, index) != SQLITE_TEXT { return nil }
    let s = String(cString: sqlite3_column_text(stmt, index))
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed == "" { return nil }
    return trimmed
}

private func getPairedDeviceFromUUID(_ uuid: String) -> LEDeviceInfo? {
    guard let db = db_paired else { return nil }
    var stmt: OpaquePointer?
    if sqlite3_prepare(db, "SELECT Name, Address, ResolvedAddress FROM PairedDevices where Uuid='\(uuid)'", -1, &stmt, nil) != SQLITE_OK {
        print("failed to prepare")
        return nil
    }
    if sqlite3_step(stmt) != SQLITE_ROW {
        return nil
    }
    let name = getStringFromRow(stmt: stmt, index: 0)
    let address = getStringFromRow(stmt: stmt, index: 1)
    let resolvedAddress = getStringFromRow(stmt: stmt, index: 2)
    var mac: String? = nil
    if let addr = resolvedAddress ?? address {
        // It's like "Public XX:XX:..." or "Random XX:XX:...", so split by space and take the second one
        let parts = addr.split(separator: " ")
        if parts.count > 1 {
            mac = String(parts[1])
        }
    }
    return LEDeviceInfo(name: name, macAddr: mac)
}

private func getOtherDeviceFromUUID(_ uuid: String) -> LEDeviceInfo? {
    guard let db = db_other else { return nil }
    var stmt: OpaquePointer?
    if sqlite3_prepare(db, "SELECT Name, Address FROM OtherDevices where Uuid='\(uuid)'", -1, &stmt, nil) != SQLITE_OK {
        print("failed to prepare")
        return nil
    }
    if sqlite3_step(stmt) != SQLITE_ROW {
        return nil
    }
    let name = getStringFromRow(stmt: stmt, index: 0)
    let address = getStringFromRow(stmt: stmt, index: 1)
    var mac: String? = nil
    if let addr = address {
        // It's like "Public XX:XX:..." or "Random XX:XX:...", so split by space and take the second one
        let parts = addr.split(separator: " ")
        if parts.count > 1 {
            mac = String(parts[1])
        }
    }
    return LEDeviceInfo(name: name, macAddr: mac)
}

func getLEDeviceInfoFromUUID(_ uuid: String) -> LEDeviceInfo? {
    connect()
    return getPairedDeviceFromUUID(uuid) ?? getOtherDeviceFromUUID(uuid);
}
