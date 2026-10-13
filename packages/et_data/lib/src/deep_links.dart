import 'package:app_links/app_links.dart';
import 'package:et_core/et_core.dart';

/// Ссылки на example.kz, открытые в приложении.
///
/// Приходят двумя путями: приложение было закрыто и ссылка его запустила (initial), или оно уже
/// работало и его позвали поверх (stream). Оба обязаны вести в одно место, иначе человек с той
/// же ссылкой попадает то в сбор, то в каталог — в зависимости от того, было ли приложение в
/// памяти, о чём он не знает и знать не должен.
///
/// Разбор адреса живёт в et_core (parseEtLink): он общий с сайтом и проверяется тестами без
/// Firebase и без устройства. Здесь остаётся только доставка.
class DeepLinks {
  DeepLinks({AppLinks? links}) : _links = links ?? AppLinks();

  final AppLinks _links;

  /// Ссылка, которой приложение запустили. Читается один раз при старте.
  Future<LinkTarget?> initial() async {
    try {
      return parseEtLink(await _links.getInitialLink());
    } catch (_) {
      return null;
    }
  }

  /// Ссылки, пришедшие в уже работающее приложение. Чужие адреса сюда не попадают.
  Stream<LinkTarget> get stream => _links.uriLinkStream
      .map(parseEtLink)
      .where((target) => target != null)
      .cast<LinkTarget>();
}
