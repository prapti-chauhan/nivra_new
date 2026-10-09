# Open questions and known defects

- `schema_v5.sql`, `schema_v6.sql`, `schema_v7.sql` are written, NOT applied to the
  live project. Their live tests in `test/integration/supabase_sync_test.dart` are
  written, not run.
- Known defect, not fixed: `reviseBill` double-reverses the sale ledger entries on
  a second edit, understating what a customer owes. Existing twice-edited bills
  would need a correcting entry. See decisions.md, slice ten, "Found while building".
- Slices 7 to 12 have not been run on a device. A debug APK builds.
- Logo photos may carry EXIF (including location) into the uploaded file.
- Live-sync runs previously stalled, probably the laptop sleeping; one clean run on
  mains power has not been done.
