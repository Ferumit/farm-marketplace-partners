import 'package:flutter/material.dart';

import 'theme.dart';

/// The notifications bell, with the number nobody has read yet.
///
/// Both apps put it in the app bar of the screen people land on. The count comes from a live
/// stream, because a badge that lags reads as a bug - and this one is the only sign that
/// something happened while push was refused or the phone was off.
class EtBell extends StatelessWidget {
  const EtBell({super.key, required this.unread, required this.onTap, this.tooltip = 'Уведомления'});

  /// The live count. Null means «not known yet» - shown as a plain bell.
  final Stream<int>? unread;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final icon = Icon(Icons.notifications_none, color: c.ink);
    if (unread == null) {
      return IconButton(onPressed: onTap, icon: icon, tooltip: tooltip);
    }

    return StreamBuilder<int>(
      stream: unread,
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        return IconButton(
          onPressed: onTap,
          tooltip: tooltip,
          icon: count == 0
              ? icon
              : Badge(
                  label: Text(count > 99 ? '99+' : '$count'),
                  backgroundColor: c.rust,
                  child: Icon(Icons.notifications, color: c.ink),
                ),
        );
      },
    );
  }
}
