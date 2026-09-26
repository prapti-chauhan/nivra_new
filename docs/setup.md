# Running nivra

## Without a backend

```
flutter run
```

Everything works. Data stays on the device and the app says so.

## With Supabase

1. Create a project at supabase.com.
2. Open the SQL editor and run `supabase/schema.sql`, then
   `supabase/schema_v2.sql`. Both are re-runnable.
3. Authentication → Providers → Email: enable it. Turn **off** "Confirm email"
   while developing, or the first sign-in will block on a confirmation link.
4. Project Settings → API. Copy the project URL and the publishable
   (anon) key.

Copy `supabase.local.example.json` to `supabase.local.json`, fill it in, then:

```
flutter run --dart-define-from-file=supabase.local.json
```

`supabase.local.json` is gitignored. The publishable key is safe to ship — it
goes into the app binary and row-level security is what actually protects the
data — but it still does not belong in version control.

Never put the `service_role` key in this file or anywhere in the app. It
bypasses every RLS policy in `supabase/schema.sql`.

The older `--dart-define=SUPABASE_ANON_KEY=...` spelling still works.

## Tests

```
flutter test
```

## Integration test against the live project

The default suite uses a fake server. To exercise the real one:

```
flutter test test/integration \
  --dart-define-from-file=supabase.local.json \
  --dart-define=RUN_SUPABASE_IT=true
```

It signs up a throwaway user and writes real rows, so it is opt-in. Clean up
afterwards in the SQL editor:

```sql
delete from public.bill_revisions where bill_id in
  (select id from public.bills where customer_name like 'IT %'
      or customer_name like 'V2 %');
delete from public.payments where bill_id in
  (select id from public.bills where customer_name like 'IT %'
      or customer_name like 'V2 %');
delete from public.bill_lines where bill_id in
  (select id from public.bills where customer_name like 'IT %'
      or customer_name like 'V2 %');
delete from public.bills where customer_name like 'IT %'
   or customer_name like 'V2 %';
delete from public.ledger_entries where account_id in
  (select id from public.customers where name like 'IT %' or name like 'V2 %');
delete from public.customers where name like 'IT %' or name like 'V2 %';
delete from public.stock_movements where item_id in
  (select id from public.items where code like 'IT-%' or code = 'VERIFY');
delete from public.items where code like 'IT-%' or code = 'VERIFY';
-- auth users: Dashboard > Authentication > Users, filter "nivra-"
```

## Billing speed

The fifteen-second target is measured, not asserted:

```
flutter drive \
  --driver=integration_test/driver.dart \
  --target=integration_test/billing_speed_test.dart \
  -d <device> --profile
```

It seeds 400 items and times three items onto a bill plus the save. Run it in
profile mode; a debug build is several times slower and the number means
nothing.
