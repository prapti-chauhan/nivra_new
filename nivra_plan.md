# nivra: Billing & Inventory App

A mobile billing and inventory app for small shop owners in India. A lighter, faster alternative to Vyapar.

---

## Who it is for

Picture Ramesh. He runs a hardware shop. A customer is standing in front of him with three items and getting impatient. Ramesh needs a bill created, saved, and sent to the customer's WhatsApp before that patience runs out.

He is not an accountant. He does not know what a debit or a credit is. He wants to know three things: how much did I make, who owes me money, and what is running out of stock.

His shop has bad network coverage and the power cuts out. The app has to keep working anyway.

Every design and technical decision should be judged against Ramesh standing at his counter.

---

## What the app does

**Billing.** Create a bill by picking a customer and adding items. Apply a discount if needed. Save it, generate a PDF, share it on WhatsApp. Mark it paid, unpaid, or partly paid.

**Inventory.** Keep a list of items with prices and stock counts. Stock goes down automatically when something is billed, and up when something is purchased. Tell Ramesh when something is about to run out.

**Customers and suppliers.** Keep contact details and, more importantly, a running balance of who owes what. Each one has a ledger showing every transaction with them.

**Purchases.** Record what Ramesh buys from suppliers, which increases stock and increases what he owes them.

**Payments.** Record money coming in and money going out, including partial payments against a bill.

**Money tracking.** Expenses, other income, and cash versus bank balances.

**Reports.** Sales, purchases, profit and loss, stock on hand, and who still owes money.

---

## How it should feel

**Billing is the whole app.** Everything else is secondary. If billing three items and sharing the PDF takes more than about fifteen seconds one-handed, something is wrong, no matter how good the rest is.

**It works offline without drama.** Ramesh bills through a power cut and does not think about it. But he can always see whether his data is safely synced or still waiting. Never hide this from him.

**Mistakes are cheap to fix.** He is billing fast and will tap the wrong thing. Recovering should be easy and should not involve a confirmation dialog on every action.

**No number is a mystery.** If the app says he made forty two thousand rupees this month, he must be able to tap it and see exactly where that came from. This is money. He will not trust a number he cannot open up.

**History is honest.** Editing an old bill should leave a trace. The first time a customer disputes a bill, this is what protects him.

**It must not look like a default Flutter app.** The bill PDF especially, because that is the one thing his customers see.

---

## What is already settled

- Flutter, targeting Android and iOS
- Supabase as the backend
- Offline-first, with local storage and background sync
- One user owns their own data, no staff logins or shared accounts
- No GST or tax reporting in this version, though the design should not make adding it later painful
- Not being published to app stores for now
- Running on free tiers, so no paid services without asking first

---

## What is deliberately not in this version

Tax and GST reports, e-invoicing, staff logins and permissions, multiple businesses under one account, barcode scanning, quotations and estimates, delivery challans, batch and expiry tracking, Tally import and export.

Some of these come later. None of them should be built now.

---

## How to work on this

**Do not make the big calls alone.** For anything with real consequences, come back with two or three options, explain the tradeoffs in plain language, say which one you would pick and why, then wait.

That includes, but is not limited to: how the app is structured internally, which packages to use, how offline sync should work, the database design, how the app looks, how billing is laid out on screen, how navigation works, what order to build things in, and how to handle data conflicts.

If you find yourself about to make a choice that would be expensive to reverse later, that is a signal to stop and ask.

**Build one slice at a time.** A complete slice from screen to database, not partial work spread across the whole app. After each one, tell me what you built, what you chose along the way, and anything you were unsure about.

**Push back when I am wrong.** If something in this document will not work well in practice, say so instead of building it anyway.

---

## Problems worth thinking hard about

These are genuinely difficult. There are no answers here on purpose.

- Two devices billing offline at the same time will both want the next invoice number.
- Stock counts and account balances have to stay correct when the same data is edited in two places while offline.
- Profit has to be traceable all the way back to the individual transactions that produced it.
- A low stock warning should tell Ramesh something useful, not just fire a generic alert he learns to ignore.
- The bill PDF needs to look like it came from a real business.
- Billing needs to be genuinely fast, not just fast in a demo with five items.

---

## The test

Ramesh uses this every day instead of his notebook, and stops double-checking it against the notebook.
