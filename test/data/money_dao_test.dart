import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/domain/cashbook.dart';

const userId = 'user-1';

void main() {
  late AppDatabase db;
  late MoneyDao dao;
  late FixedClock clock;

  setUp(() {
    clock = FixedClock(1700000000000);
    db = AppDatabase.forTesting(NativeDatabase.memory(), clock: clock);
    dao = MoneyDao(db);
  });

  tearDown(() => db.close());

  Future<int> cash() => dao.balanceOf(MoneyMethod.cash);
  Future<int> bank() => dao.balanceOf(MoneyMethod.bank);

  Future<int> accountTotal(String account) async => (await db.customSelect(
        'SELECT COALESCE(SUM(amount), 0) AS t FROM ledger_entries '
        'WHERE account_type = ?',
        variables: [Variable<String>(account)],
        readsFrom: {db.ledgerEntries},
      ).getSingle())
          .read<int>('t');

  Future<int> ledgerRows() async => (await db.select(db.ledgerEntries).get()).length;

  group('an expense', () {
    test('takes money out of the till and records what it was for', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 25000,
        category: 'Tea & snacks',
      );
      expect(await cash(), -25000);
      expect(await accountTotal('expense'), 25000);
      expect((await dao.findEntry(id))!.category, 'Tea & snacks');
    });

    test('paid from the bank leaves the till alone', () async {
      await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 800000,
        category: 'Rent',
        method: MoneyMethod.bank,
      );
      expect(await bank(), -800000);
      expect(await cash(), 0);
    });

    test('a blank category is stored as nothing, not as spaces', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 100,
        category: '   ',
      );
      expect((await dao.findEntry(id))!.category, isNull);
    });

    test('zero and negative amounts are refused', () async {
      for (final amount in [0, -100]) {
        expect(
          () => dao.addEntry(
              userId: userId, kind: MoneyKind.expense, amount: amount),
          throwsArgumentError,
        );
      }
      expect(await ledgerRows(), 0, reason: 'a refused entry writes nothing');
    });
  });

  group('other income', () {
    test('puts money in the till', () async {
      await dao.addEntry(
        userId: userId,
        kind: MoneyKind.income,
        amount: 50000,
        category: 'Scrap sale',
      );
      expect(await cash(), 50000);
      expect(await accountTotal('other_income'), 50000);
      expect(await accountTotal('expense'), 0);
    });
  });

  group('a transfer', () {
    test('moves money between places without creating any', () async {
      await dao.correctBalance(
          userId: userId, method: MoneyMethod.cash, countedPaise: 1000000);
      await dao.addEntry(
        userId: userId,
        kind: MoneyKind.transfer,
        amount: 400000,
        method: MoneyMethod.cash,
        toMethod: MoneyMethod.bank,
      );
      expect(await cash(), 600000);
      expect(await bank(), 400000);
      expect((await cash()) + (await bank()), 1000000);
      expect(await accountTotal('expense'), 0);
      expect(await accountTotal('other_income'), 0);
    });

    test('has no category', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.transfer,
        amount: 100,
        category: 'should be dropped',
        method: MoneyMethod.cash,
        toMethod: MoneyMethod.bank,
      );
      expect((await dao.findEntry(id))!.category, isNull);
    });

    test('to the same place, or nowhere, is refused', () async {
      expect(
        () => dao.addEntry(
          userId: userId,
          kind: MoneyKind.transfer,
          amount: 100,
          method: MoneyMethod.cash,
          toMethod: MoneyMethod.cash,
        ),
        throwsArgumentError,
      );
      expect(
        () => dao.addEntry(
          userId: userId,
          kind: MoneyKind.transfer,
          amount: 100,
          method: MoneyMethod.cash,
        ),
        throwsArgumentError,
      );
    });
  });

  group('editing', () {
    test('reverses the old effect and applies the new, leaving both visible',
        () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 25000,
        category: 'Tea',
      );
      await dao.updateEntry(
        userId: userId,
        id: id,
        amount: 20000,
        category: 'Tea',
        method: MoneyMethod.cash,
      );

      expect(await cash(), -20000);
      expect(await accountTotal('expense'), 20000);

      // Original two rows, two reversing rows, two new rows. The history shows
      // that it was changed rather than quietly becoming a different number.
      expect(await ledgerRows(), 6);
      expect((await dao.findEntry(id))!.amount, 20000);
    });

    test('can move an expense from cash to the bank', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 5000,
        category: 'Repairs',
      );
      await dao.updateEntry(
        userId: userId,
        id: id,
        amount: 5000,
        category: 'Repairs',
        method: MoneyMethod.bank,
      );
      expect(await cash(), 0);
      expect(await bank(), -5000);
    });

    test('marks the row dirty so the change syncs', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 100,
      );
      await db.customUpdate('UPDATE money_entries SET is_dirty = 0');
      clock.advance(1000);
      await dao.updateEntry(
        userId: userId,
        id: id,
        amount: 200,
        method: MoneyMethod.cash,
      );
      final row = (await dao.findEntry(id))!;
      expect(row.isDirty, isTrue);
      expect(row.updatedAt, 1700000001000);
    });

    test('a deleted entry cannot be edited', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 100,
      );
      await dao.deleteEntry(userId: userId, id: id);
      expect(
        () => dao.updateEntry(
          userId: userId,
          id: id,
          amount: 200,
          method: MoneyMethod.cash,
        ),
        throwsStateError,
      );
    });
  });

  group('deleting', () {
    test('puts the money back and keeps the original rows', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 25000,
        category: 'Tea',
      );
      clock.advance(60000);
      await dao.deleteEntry(userId: userId, id: id);

      expect(await cash(), 0);
      expect(await accountTotal('expense'), 0);
      expect((await dao.findEntry(id))!.deletedAt, isNotNull);
      expect(await ledgerRows(), 4,
          reason: 'two original rows and two reversing ones, none removed');
    });

    test('restoring puts it back exactly as it was', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 25000,
        category: 'Tea',
      );
      await dao.deleteEntry(userId: userId, id: id);
      await dao.restoreEntry(userId: userId, id: id);

      expect(await cash(), -25000);
      expect(await accountTotal('expense'), 25000);
      expect((await dao.findEntry(id))!.deletedAt, isNull);
    });

    test('deleting twice, or restoring something live, does nothing', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.expense,
        amount: 100,
      );
      await dao.restoreEntry(userId: userId, id: id);
      expect(await cash(), -100);
      await dao.deleteEntry(userId: userId, id: id);
      await dao.deleteEntry(userId: userId, id: id);
      expect(await cash(), 0);
    });

    test('a transfer undoes cleanly', () async {
      final id = await dao.addEntry(
        userId: userId,
        kind: MoneyKind.transfer,
        amount: 400000,
        method: MoneyMethod.cash,
        toMethod: MoneyMethod.bank,
      );
      await dao.deleteEntry(userId: userId, id: id);
      expect(await cash(), 0);
      expect(await bank(), 0);
    });
  });

  group('counting the till', () {
    test('writes the difference as a visible adjustment', () async {
      await dao.addEntry(
          userId: userId, kind: MoneyKind.income, amount: 100000);
      final diff = await dao.correctBalance(
        userId: userId,
        method: MoneyMethod.cash,
        countedPaise: 98000,
      );
      expect(diff, -2000);
      expect(await cash(), 98000);

      final adjustment = (await db.select(db.ledgerEntries).get())
          .singleWhere((e) => e.reason == 'adjustment');
      expect(adjustment.amount, -2000);
      expect(adjustment.note, 'Counted');
    });

    test('a matching count writes nothing at all', () async {
      await dao.addEntry(
          userId: userId, kind: MoneyKind.income, amount: 100000);
      final before = await ledgerRows();
      final diff = await dao.correctBalance(
        userId: userId,
        method: MoneyMethod.cash,
        countedPaise: 100000,
      );
      expect(diff, isNull);
      expect(await ledgerRows(), before);
    });

    test('is how a first balance gets in', () async {
      await dao.correctBalance(
          userId: userId, method: MoneyMethod.cash, countedPaise: 1250000);
      await dao.correctBalance(
          userId: userId, method: MoneyMethod.bank, countedPaise: 4000000);
      expect(await cash(), 1250000);
      expect(await bank(), 4000000);
    });

    test('a negative count is refused', () async {
      expect(
        () => dao.correctBalance(
            userId: userId, method: MoneyMethod.cash, countedPaise: -1),
        throwsArgumentError,
      );
    });

    test('bank and cash are counted separately', () async {
      await dao.correctBalance(
          userId: userId, method: MoneyMethod.bank, countedPaise: 5000);
      expect(await cash(), 0);
      expect(await bank(), 5000);
    });
  });

  group('the position', () {
    test('reports cash and bank together', () async {
      await dao.correctBalance(
          userId: userId, method: MoneyMethod.cash, countedPaise: 10000);
      await dao.correctBalance(
          userId: userId, method: MoneyMethod.bank, countedPaise: 90000);
      final p = await dao.watchCashPosition().first;
      expect(p.cashPaise, 10000);
      expect(p.bankPaise, 90000);
      expect(p.totalPaise, 100000);
    });

    test('is empty, not an error, before anything has happened', () async {
      final p = await dao.watchCashPosition().first;
      expect(p.totalPaise, 0);
    });

    test('does not mistake a customer or supplier row for the till', () async {
      // Ledger rows for customers carry an account id. Cash and bank never do,
      // and a sum that ignored that would fold people's balances into the till.
      await PartyDao(db).createCustomer(
        userId: userId,
        name: 'Ramesh',
        openingBalance: 500000,
      );
      expect(await cash(), 0);
    });
  });

  group('recent categories', () {
    test('most recently used first, one per spelling', () async {
      await dao.addEntry(
          userId: userId, kind: MoneyKind.expense, amount: 100, category: 'Rent');
      clock.advance(1000);
      await dao.addEntry(
          userId: userId, kind: MoneyKind.expense, amount: 100, category: 'Tea');
      clock.advance(1000);
      await dao.addEntry(
          userId: userId, kind: MoneyKind.expense, amount: 100, category: 'rent ');

      final recent =
          await dao.watchRecentCategories(MoneyKind.expense).first;
      expect(recent, hasLength(2));
      expect(recent.first.trim().toLowerCase(), 'rent');
      expect(recent.last, 'Tea');
    });

    test('kept apart for expenses and income', () async {
      await dao.addEntry(
          userId: userId, kind: MoneyKind.expense, amount: 100, category: 'Rent');
      await dao.addEntry(
          userId: userId, kind: MoneyKind.income, amount: 100, category: 'Scrap');
      expect(await dao.watchRecentCategories(MoneyKind.expense).first, ['Rent']);
      expect(await dao.watchRecentCategories(MoneyKind.income).first, ['Scrap']);
    });

    test('a deleted entry stops suggesting its category', () async {
      final id = await dao.addEntry(
          userId: userId, kind: MoneyKind.expense, amount: 100, category: 'Typo');
      await dao.deleteEntry(userId: userId, id: id);
      expect(await dao.watchRecentCategories(MoneyKind.expense).first, isEmpty);
    });
  });
}
