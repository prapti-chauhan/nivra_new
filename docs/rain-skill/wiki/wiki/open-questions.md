# Open questions and known defects

- `schema_v5.sql`, `schema_v6.sql`, `schema_v7.sql` are written, NOT applied to the
  live project. Their live tests in `test/integration/supabase_sync_test.dart` are
  written, not run.
- Fixed 2026-10-17: `reviseBill` and `deleteBill` double-reversed the sale ledger
  entries of a bill edited more than once, understating what a customer owes. They
  now cancel the net per account. NOT repaired: bills already edited twice or more
  keep their old wrong rows and would need a correcting entry.
- Slices 7 to 12 have not been run on a device. A debug APK builds.
- Logo photos may carry EXIF (including location) into the uploaded file.
- Live-sync runs previously stalled, probably the laptop sleeping; one clean run on
  mains power has not been done.
