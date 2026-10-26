import Foundation
import GRDB

/// Lists of people travel to teammates (see PersonGroups): `list` (uuid, name; deleted = the list was deleted) and
/// `listMember` (uuid = the list, into = the person; deleted = taken off it). The newest change wins; what was
/// taken away is remembered (`personGroupGone`, `personGroupMemberGone`) so an older copy doesn't bring it back.
extension TeamSync {
    /// Lists, their members and what was taken away, since last published.
    func listOps(state: [String: String]) throws -> (ops: [Op], updates: [String: String]) {
        var ops: [Op] = []
        var updates: [String: String] = [:]
        try store.db.read { db in
            for r in try Row.fetchAll(db, sql: "SELECT uuid, name, updatedAt FROM personGroup") {
                let uuid: String = r["uuid"], at: Double = r["updatedAt"]
                guard state["pub:list:\(uuid)"] != "\(at)" else { continue }
                ops.append(Op(t: "list", at: at, uuid: uuid, name: r["name"]))
                updates["pub:list:\(uuid)"] = "\(at)"
            }
            for r in try Row.fetchAll(db, sql: "SELECT uuid, at FROM personGroupGone") {
                let uuid: String = r["uuid"], at: Double = r["at"]
                guard state["pub:list:\(uuid)"] != "x\(at)" else { continue }
                ops.append(Op(t: "list", at: at, uuid: uuid, deleted: true))
                updates["pub:list:\(uuid)"] = "x\(at)"
            }
            for r in try Row.fetchAll(db, sql: """
                SELECT g.uuid AS list, p.uuid AS person, m.at FROM personGroupMember m
                JOIN personGroup g ON g.id = m.groupId JOIN person p ON p.id = m.personId
                """) {
                let list: String = r["list"], person: String = r["person"], at: Double = r["at"]
                guard state["pub:lm:\(list):\(person)"] != "\(at)" else { continue }
                ops.append(Op(t: "listMember", at: at, uuid: list, into: person))
                updates["pub:lm:\(list):\(person)"] = "\(at)"
            }
            for r in try Row.fetchAll(db, sql: "SELECT groupUuid, personUuid, at FROM personGroupMemberGone") {
                let list: String = r["groupUuid"], person: String = r["personUuid"], at: Double = r["at"]
                guard state["pub:lm:\(list):\(person)"] != "x\(at)" else { continue }
                ops.append(Op(t: "listMember", at: at, uuid: list, into: person, deleted: true))
                updates["pub:lm:\(list):\(person)"] = "x\(at)"
            }
        }
        return (ops, updates)
    }

    /// The local list with this stable id, following lists merged into another.
    static func resolveList(_ uuid: String, db: Database) throws -> (id: Int64, uuid: String, updatedAt: Double)? {
        var u = uuid
        for _ in 0..<8 {
            if let r = try Row.fetchOne(db, sql: "SELECT id, uuid, updatedAt FROM personGroup WHERE uuid = ?", arguments: [u]) {
                return (r["id"], r["uuid"], r["updatedAt"])
            }
            guard let next = try String.fetchOne(db, sql: "SELECT intoUuid FROM personGroupAlias WHERE fromUuid = ?", arguments: [u]) else { return nil }
            u = next
        }
        return nil
    }

    func applyListOp(_ op: Op, team: TeamRecord, db: Database) throws -> Outcome {
        guard let uuid = op.uuid else { return .ignored }
        func published(_ local: String, _ value: String) throws {
            // Known here now: not sent back as this Mac's own change.
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)", arguments: [team.id, "pub:list:\(local)", value])
        }
        let gone = try Double?.fetchOne(db, sql: "SELECT at FROM personGroupGone WHERE uuid = ?", arguments: [uuid]) ?? nil
        if op.deleted == true {
            if let l = try Self.resolveList(uuid, db: db) {
                guard op.at >= l.updatedAt else { return .ignored }  // renamed here since: kept
                try db.execute(sql: "DELETE FROM personGroup WHERE id = ?", arguments: [l.id])
                try db.execute(sql: "INSERT OR REPLACE INTO personGroupGone (uuid, at) VALUES (?, ?)", arguments: [l.uuid, op.at])
                try published(l.uuid, "x\(op.at)")
                return .applied(people: [], remote: [])
            }
            guard op.at > (gone ?? 0) else { return .ignored }
            try db.execute(sql: "INSERT OR REPLACE INTO personGroupGone (uuid, at) VALUES (?, ?)", arguments: [uuid, op.at])
            try published(uuid, "x\(op.at)")
            return .ignored
        }
        guard let rawName = op.name else { return .ignored }
        let name = PersonNames.clean(rawName)
        guard !name.isEmpty, op.at > (gone ?? 0) else { return .ignored }
        if let l = try Self.resolveList(uuid, db: db) {
            guard op.at > l.updatedAt else { return .ignored }
            try db.execute(sql: "UPDATE personGroup SET name = ?, updatedAt = ? WHERE id = ?", arguments: [name, op.at, l.id])
            try published(l.uuid, "\(op.at)")
            return .applied(people: [], remote: [])
        }
        if let existing = try PersonGroups.find(name, db: db) {
            // Both Macs made a list of that name: the smaller id becomes the one everybody uses.
            let theirs: String = try String.fetchOne(db, sql: "SELECT uuid FROM personGroup WHERE id = ?", arguments: [existing]) ?? ""
            if uuid < theirs {
                try db.execute(sql: "UPDATE personGroup SET uuid = ? WHERE id = ?", arguments: [uuid, existing])
                try db.execute(sql: "UPDATE personGroupMemberGone SET groupUuid = ? WHERE groupUuid = ?", arguments: [uuid, theirs])
                try db.execute(sql: "INSERT OR REPLACE INTO personGroupAlias (fromUuid, intoUuid) VALUES (?, ?)", arguments: [theirs, uuid])
                try db.execute(sql: "UPDATE personGroupAlias SET intoUuid = ? WHERE intoUuid = ?", arguments: [uuid, theirs])
            } else {
                try db.execute(sql: "INSERT OR REPLACE INTO personGroupAlias (fromUuid, intoUuid) VALUES (?, ?)", arguments: [uuid, theirs])
            }
            return .applied(people: [], remote: [])
        }
        let last = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM personGroup") ?? -1
        var g = PersonGroupRecord(name: name, sortOrder: last + 1, uuid: uuid, updatedAt: op.at)
        try g.insert(db)
        try published(uuid, "\(op.at)")
        return .applied(people: [], remote: [])
    }

    func applyListMemberOp(_ op: Op, team: TeamRecord, db: Database) throws -> Outcome {
        guard let listUuid = op.uuid, let personUuid = op.into else { return .ignored }
        guard let list = try Self.resolveList(listUuid, db: db) else {
            let gone = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personGroupGone WHERE uuid = ?", arguments: [listUuid]) ?? 0
            return gone > 0 ? .ignored : .deferred
        }
        guard let pid = try Self.resolve(personUuid, db: db) else { return .deferred }
        let person: String = try String.fetchOne(db, sql: "SELECT uuid FROM person WHERE id = ?", arguments: [pid]) ?? personUuid
        let current = try Double?.fetchOne(db, sql: "SELECT at FROM personGroupMember WHERE groupId = ? AND personId = ?", arguments: [list.id, pid]) ?? nil
        let gone = try Double?.fetchOne(db, sql: "SELECT at FROM personGroupMemberGone WHERE groupUuid = ? AND personUuid = ?",
                                        arguments: [list.uuid, person]) ?? nil
        guard op.at > max(current ?? 0, gone ?? 0) else { return .ignored }
        if op.deleted == true {
            try db.execute(sql: "DELETE FROM personGroupMember WHERE groupId = ? AND personId = ?", arguments: [list.id, pid])
            try db.execute(sql: "INSERT OR REPLACE INTO personGroupMemberGone (groupUuid, personUuid, at) VALUES (?, ?, ?)",
                           arguments: [list.uuid, person, op.at])
        } else {
            try db.execute(sql: "INSERT OR REPLACE INTO personGroupMember (groupId, personId, at) VALUES (?, ?, ?)", arguments: [list.id, pid, op.at])
            try db.execute(sql: "DELETE FROM personGroupMemberGone WHERE groupUuid = ? AND personUuid = ?", arguments: [list.uuid, person])
        }
        try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)",
                       arguments: [team.id, "pub:lm:\(list.uuid):\(person)", op.deleted == true ? "x\(op.at)" : "\(op.at)"])
        return .applied(people: [], remote: [])
    }
}
