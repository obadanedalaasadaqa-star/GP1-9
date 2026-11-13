import 'package:flutter/material.dart';
import '../core/budget_models.dart';
import '../core/receipt_event.dart';
import 'budget_alert.dart';
import 'new_receipt_sheet.dart';

/// The bottom sheets the shell opens for live events: the QR sheet, the "New
/// receipt" sheet and the budget alert sheet. Each is kept as a route, so
/// exactly that sheet can be closed later. A mixin, so tests can drive it
/// from a small host widget instead of the whole shell.
mixin LiveSheets<T extends StatefulWidget> on State<T> {
  ModalBottomSheetRoute<void>? qrRoute;
  ModalBottomSheetRoute<void>? receiptRoute;
  ModalBottomSheetRoute<void>? alertRoute;

  /// Receipt id of the open "New receipt" sheet.
  String? receiptRouteId;

  /// Budget alerts shown inside the open "New receipt" sheet.
  final receiptAlerts = ValueNotifier<List<BudgetAlert>>(const []);

  // Same route showModalBottomSheet builds, but we keep the object.
  ModalBottomSheetRoute<void> sheetRoute(WidgetBuilder builder) {
    final navigator = Navigator.of(context);
    final localizations = MaterialLocalizations.of(context);
    return ModalBottomSheetRoute<void>(
      builder: builder,
      capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(localizations.bottomSheetLabel),
      modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
    );
  }

  // Close exactly [route] if it is still open. On top: animated pop.
  // Under another route (e.g. VerifyEmailScreen): removed in place.
  void closeSheet(ModalBottomSheetRoute<void>? route) {
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// Push the QR sheet built by [builder].
  void showQrSheet(WidgetBuilder builder) {
    final route = sheetRoute(builder);
    qrRoute = route;
    // whenComplete also runs on swipe-dismiss, so the field never points at a dead route.
    Navigator.of(context).push(route).whenComplete(() {
      if (qrRoute == route) qrRoute = null;
    });
  }

  /// Swap any open sheet for the "New receipt" sheet of [e].
  void showReceiptSheet(ReceiptEvent e, {required VoidCallback onViewArchive}) {
    closeSheet(qrRoute);
    closeSheet(receiptRoute);
    closeSheet(alertRoute);
    receiptAlerts.value = const [];

    late final ModalBottomSheetRoute<void> route;
    route = sheetRoute((_) => NewReceiptSheet(
      receipt: e.receipt,
      pointsEarned: e.pointsEarned,
      alerts: receiptAlerts,
      onViewArchive: () {
        closeSheet(route);
        onViewArchive();
      },
      onDone: () => closeSheet(route),
    ));
    receiptRoute = route;
    receiptRouteId = e.receipt.id;
    Navigator.of(context).push(route).whenComplete(() {
      if (receiptRoute == route) {
        receiptRoute = null;
        receiptRouteId = null;
      }
    });
  }

  /// A budget alert: shown inside the open "New receipt" sheet of the same
  /// receipt, otherwise in its own sheet (replacing an older alert sheet).
  void showBudgetAlert(BudgetAlert alert, {required VoidCallback onViewBudgets}) {
    final open = receiptRoute;
    if (open != null && open.isActive && receiptRouteId == alert.receiptId) {
      receiptAlerts.value = [...receiptAlerts.value, alert];
      return;
    }
    closeSheet(qrRoute);
    closeSheet(alertRoute);

    late final ModalBottomSheetRoute<void> route;
    route = sheetRoute((_) => BudgetAlertSheet(
      alert: alert,
      onViewBudgets: () {
        closeSheet(route);
        onViewBudgets();
      },
      onDone: () => closeSheet(route),
    ));
    alertRoute = route;
    Navigator.of(context).push(route).whenComplete(() {
      if (alertRoute == route) alertRoute = null;
    });
  }

  /// Close every live sheet (session expired).
  void closeLiveSheets() {
    closeSheet(qrRoute);
    closeSheet(receiptRoute);
    closeSheet(alertRoute);
  }

  @override
  void dispose() {
    receiptAlerts.dispose();
    super.dispose();
  }
}
