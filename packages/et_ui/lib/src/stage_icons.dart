import 'package:et_core/et_core.dart';
import 'package:flutter/material.dart';

/// Значок шага сделки — один на оба приложения.
///
/// Покупатель и хозяйство смотрят на один и тот же заказ с двух сторон, и если бы каждое
/// приложение выбирало значки само, «мясо готово» у одного могло бы оказаться весами, а у другого
/// коробкой. Список здесь ровно тот же, что в et_core (`orderRoad`), и старые статусы приводятся
/// к новым через `stageOf` — как везде.
///
/// Значки нужны не для украшения: в списке из десятка заказов грузовик находится глазом быстрее,
/// чем читается «Отправлен — отметьте передачу».
IconData etStageIcon(String status) => switch (stageOf(status)) {
      'created' => Icons.schedule,
      'accepted' => Icons.check_circle_outline,
      'animal_selected' => Icons.pets,
      'meat_ready' => Icons.scale,
      'shipped' => Icons.local_shipping_outlined,
      'delivered' => Icons.handshake_outlined,
      'completed' => Icons.verified_outlined,
      'disputed' => Icons.report_problem_outlined,
      'cancelled' => Icons.cancel_outlined,
      _ => Icons.circle_outlined,
    };
