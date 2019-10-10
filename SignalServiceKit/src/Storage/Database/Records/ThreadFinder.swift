//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDB

public protocol ThreadFinder {
    associatedtype ReadTransaction

    func visibleThreadCount(isArchived: Bool, transaction: ReadTransaction) throws -> UInt
    func enumerateVisibleThreads(isArchived: Bool, transaction: ReadTransaction, block: @escaping (TSThread) -> Void) throws
}

@objc
public class AnyThreadFinder: NSObject, ThreadFinder {
    public typealias ReadTransaction = SDSAnyReadTransaction

    let grdbAdapter: GRDBThreadFinder = GRDBThreadFinder()
    let yapAdapter: YAPDBThreadFinder = YAPDBThreadFinder()

    public func visibleThreadCount(isArchived: Bool, transaction: SDSAnyReadTransaction) throws -> UInt {
        switch transaction.readTransaction {
        case .grdbRead(let grdb):
            return try grdbAdapter.visibleThreadCount(isArchived: isArchived, transaction: grdb.database)
        case .yapRead(let yap):
            return yapAdapter.visibleThreadCount(isArchived: isArchived, transaction: yap)
        }
    }

    @objc
    public func enumerateVisibleThreads(isArchived: Bool, transaction: SDSAnyReadTransaction, block: @escaping (TSThread) -> Void) throws {
        switch transaction.readTransaction {
        case .grdbRead(let grdb):
            try grdbAdapter.enumerateVisibleThreads(isArchived: isArchived, transaction: grdb.database, block: block)
        case .yapRead(let yap):
            yapAdapter.enumerateVisibleThreads(isArchived: isArchived, transaction: yap, block: block)
        }
    }
}

struct YAPDBThreadFinder: ThreadFinder {
    typealias ReadTransaction = YapDatabaseReadTransaction

    func visibleThreadCount(isArchived: Bool, transaction: YapDatabaseReadTransaction) -> UInt {
        guard let view = ext(transaction) else {
            return 0
        }
        return view.numberOfItems(inGroup: group(isArchived: isArchived))
    }

    func enumerateVisibleThreads(isArchived: Bool, transaction: YapDatabaseReadTransaction, block: @escaping (TSThread) -> Void) {
        guard let view = ext(transaction) else {
            return
        }
        view.safe_enumerateKeysAndObjects(inGroup: group(isArchived: isArchived),
                                          extensionName: type(of: self).extensionName,
                                          with: NSEnumerationOptions.reverse) { _, _, object, _, _ in
                                            guard let thread = object as? TSThread else {
                                                owsFailDebug("unexpected object: \(type(of: object))")
                                                return
                                            }
                                            block(thread)
        }
    }

    // MARK: -

    private static let extensionName: String = TSThreadDatabaseViewExtensionName

    private func group(isArchived: Bool) -> String {
        return isArchived ? TSArchiveGroup : TSInboxGroup
    }

    private func ext(_ transaction: YapDatabaseReadTransaction) -> YapDatabaseViewTransaction? {
        return transaction.safeViewTransaction(type(of: self).extensionName)
    }
}

struct GRDBThreadFinder: ThreadFinder {
    typealias ReadTransaction = Database

    static let cn = ThreadRecord.columnName

    func visibleThreadCount(isArchived: Bool, transaction: Database) throws -> UInt {
        let archivedClause = isArchived ? "IS NOT NULL" : "IS NULL"
        let sql = """
            SELECT COUNT(*)
            FROM \(ThreadRecord.databaseTableName)
            WHERE \(threadColumn: .shouldThreadBeVisible) = 1
            AND \(threadColumn: .archivedAsOfMessageSortId) \(archivedClause)
        """
        let arguments: StatementArguments = []

        guard let count = try UInt.fetchOne(transaction, sql: sql, arguments: arguments) else {
            owsFailDebug("count was unexpectedly nil")
            return 0
        }

        return count
    }

    func enumerateVisibleThreads(isArchived: Bool, transaction: Database, block: @escaping (TSThread) -> Void) throws {
        let archivedClause = isArchived ? "IS NOT NULL" : "IS NULL"
        let sql = """
            SELECT *
            FROM \(ThreadRecord.databaseTableName)
            WHERE \(threadColumn: .shouldThreadBeVisible) = 1
            AND \(threadColumn: .archivedAsOfMessageSortId) \(archivedClause)
            ORDER BY \(threadColumn: .lastInteractionSortId) DESC
            """
        let arguments: StatementArguments = []

        try ThreadRecord.fetchCursor(transaction, sql: sql, arguments: arguments).forEach { threadRecord in
            block(try TSThread.fromRecord(threadRecord))
        }
    }
}
