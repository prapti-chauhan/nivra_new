import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/remote/mappers.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(
      NativeDatabase.memory(),
      clock: FixedClock(1700000000000),
    );
  });

  tearDown(() => db.close());

  Future<BillLine> corrected() async {
    final billing = BillingDao(db);
    final billId = await billing.saveBill(
      userId: 'u1',
      lines: [
        const BillLineDraft(
          itemId: null,
          name: 'bolt',
          unit: 'pcs',
          qty: 1000,
          unitPrice: 2500,
          unitCost: 0,
        ),
      ],
    );
    final line = (await billing.linesFor(billId)).single;
    await billing.correctLineCost(lineId: line.id, unitCostPaise: 1800);
    return (await billing.linesFor(billId)).single;
  }

  test('a corrected cost travels in both directions', () async {
    final line = await corrected();

    final json = BillingMappers.billLineToJson(line);
    expect(json['unit_cost'], 1800);
    expect(json['original_unit_cost'], 0);
    expect(json['cost_corrected_at'], 1700000000000);

    final back = BillingMappers.billLineFromJson(json);
    expect(back.unitCost.value, 1800);
    expect(back.originalUnitCost.value, 0);
    expect(back.costCorrectedAt.value, 1700000000000);
  });

  test('a row from a server that predates the columns reads as uncorrected', () {
    final back = BillingMappers.billLineFromJson({
      'id': 'l1',
      'user_id': 'u1',
      'bill_id': 'b1',
      'name': 'bolt',
      'qty': 1000,
      'unit_cost': 1800,
    });
    expect(back.originalUnitCost.value, isNull);
    expect(back.costCorrectedAt.value, isNull);
  });
}
