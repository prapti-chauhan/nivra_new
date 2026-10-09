import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/cashbook.dart';
import '../features/auth/login_screen.dart';
import '../features/billing/bill_detail_screen.dart';
import '../features/billing/bill_editor_screen.dart';
import '../features/billing/invoice_preview_screen.dart';
import '../features/money/account_ledger_screen.dart';
import '../features/money/money_entry_editor_screen.dart';
import '../features/money/money_screen.dart';
import '../features/purchases/purchase_detail_screen.dart';
import '../features/reports/owed_report_screen.dart';
import '../features/reports/pnl_screen.dart';
import '../features/reports/profit_report_screen.dart';
import '../features/reports/reorder_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/reports/sales_report_screen.dart';
import '../features/reports/stock_report_screen.dart';
import '../features/purchases/purchase_editor_screen.dart';
import '../features/purchases/purchases_screen.dart';
import '../features/suppliers/supplier_detail_screen.dart';
import '../features/suppliers/supplier_edit_screen.dart';
import '../features/suppliers/suppliers_screen.dart';
import '../features/billing/bills_screen.dart';
import '../features/customers/customer_detail_screen.dart';
import '../features/customers/customers_screen.dart';
import '../features/items/item_detail_screen.dart';
import '../features/items/item_edit_screen.dart';
import '../features/items/items_screen.dart';
import '../features/settings/more_screen.dart';
import '../features/sync/sync_detail_screen.dart';
import 'providers.dart';
import 'shell.dart';

final _rootKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(currentUserProvider, (_, _) => refresh.value++);

  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/bills',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(currentUserProvider);
      // Hold on the splash rather than flashing the login screen while the
      // stored session is being read.
      if (auth.isLoading) return null;

      final signedIn = auth.value != null;
      final atLogin = state.matchedLocation == '/login';

      if (!signedIn) return atLogin ? null : '/login';
      if (atLogin) return '/bills';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),

      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/bills',
                builder: (context, state) => const BillsScreen(),
                routes: [
                  // Full screen, above the shell: the editor is keyboard-heavy
                  // and the nav bar would eat the room the results list needs.
                  GoRoute(
                    path: 'new',
                    parentNavigatorKey: _rootKey,
                    builder: (context, state) => const BillEditorScreen(),
                  ),
                  GoRoute(
                    path: ':id',
                    builder: (context, state) =>
                        BillDetailScreen(billId: state.pathParameters['id']!),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        parentNavigatorKey: _rootKey,
                        builder: (context, state) => BillEditorScreen(
                          billId: state.pathParameters['id']!,
                        ),
                      ),
                      // Full screen above the shell: the preview is the
                      // customer's copy and deserves the whole display.
                      GoRoute(
                        path: 'share',
                        parentNavigatorKey: _rootKey,
                        builder: (context, state) => InvoicePreviewScreen(
                          billId: state.pathParameters['id']!,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/items',
                builder: (context, state) => const ItemsScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    builder: (context, state) => const ItemEditScreen(),
                  ),
                  GoRoute(
                    path: ':id',
                    builder: (context, state) =>
                        ItemDetailScreen(itemId: state.pathParameters['id']!),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        builder: (context, state) => ItemEditScreen(
                          itemId: state.pathParameters['id']!,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/customers',
                builder: (context, state) => const CustomersScreen(),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (context, state) => CustomerDetailScreen(
                      customerId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/reports',
                builder: (context, state) => const ReportsScreen(),
                routes: [
                  GoRoute(
                    path: 'sales',
                    builder: (context, state) => const SalesReportScreen(),
                  ),
                  GoRoute(
                    path: 'profit',
                    builder: (context, state) => const ProfitReportScreen(),
                  ),
                  GoRoute(
                    path: 'owed',
                    builder: (context, state) => const OwedReportScreen(),
                  ),
                  GoRoute(
                    path: 'stock',
                    builder: (context, state) => const StockReportScreen(),
                  ),
                  GoRoute(
                    path: 'reorder',
                    builder: (context, state) => const ReorderScreen(),
                  ),
                  GoRoute(
                    path: 'pnl',
                    builder: (context, state) => const PnlScreen(),
                  ),
                  GoRoute(
                    path: 'money',
                    builder: (context, state) => const MoneyScreen(),
                    routes: [
                      // Full screen above the shell: it is keyboard-heavy and
                      // the tab bar would eat the room the categories need.
                      GoRoute(
                        path: 'new/:kind',
                        parentNavigatorKey: _rootKey,
                        builder: (context, state) => MoneyEntryEditorScreen(
                          kind: MoneyKind.fromWire(state.pathParameters['kind']),
                        ),
                      ),
                      GoRoute(
                        path: 'entry/:id',
                        parentNavigatorKey: _rootKey,
                        builder: (context, state) => MoneyEntryEditorScreen(
                          entryId: state.pathParameters['id']!,
                        ),
                      ),
                      GoRoute(
                        path: 'ledger/:method',
                        builder: (context, state) => AccountLedgerScreen(
                          method: MoneyMethod.fromWire(
                            state.pathParameters['method'],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/more',
                builder: (context, state) => const MoreScreen(),
              ),
            ],
          ),
        ],
      ),

      GoRoute(
        path: '/suppliers',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const SuppliersScreen(),
        routes: [
          GoRoute(
            path: 'new',
            parentNavigatorKey: _rootKey,
            builder: (context, state) => const SupplierEditScreen(),
          ),
          GoRoute(
            path: ':id',
            parentNavigatorKey: _rootKey,
            builder: (context, state) =>
                SupplierDetailScreen(supplierId: state.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'edit',
                parentNavigatorKey: _rootKey,
                builder: (context, state) => SupplierEditScreen(
                  supplierId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/purchases',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const PurchasesScreen(),
        routes: [
          GoRoute(
            path: 'new',
            parentNavigatorKey: _rootKey,
            builder: (context, state) => PurchaseEditorScreen(
              supplierId: state.uri.queryParameters['supplier'],
            ),
          ),
          GoRoute(
            path: ':id',
            parentNavigatorKey: _rootKey,
            builder: (context, state) =>
                PurchaseDetailScreen(purchaseId: state.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'edit',
                parentNavigatorKey: _rootKey,
                builder: (context, state) => PurchaseEditorScreen(
                  purchaseId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/sync',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const SyncDetailScreen(),
      ),
      GoRoute(
        path: '/shop',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const ShopDetailsScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(child: Text('Nothing here: ${state.uri}')),
    ),
  );
});
