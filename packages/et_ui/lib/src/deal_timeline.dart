import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

/// One stop on the road of a deal.
class EtTimelineEntry {
  const EtTimelineEntry({
    required this.title,
    this.when,
    this.body,
    this.done = false,
    this.current = false,
    this.icon,
  });

  final String title;
  final String? when;

  /// Whatever belongs under the title: photos of the step, the weighing, documents.
  final Widget? body;
  final bool done;
  final bool current;

  /// Чем этот шаг занят: животное, весы, грузовик, рукопожатие. Берётся из [etStageIcon].
  /// Пройденный шаг показывает галочку — она говорит «сделано» однозначнее любого рисунка, —
  /// а значок остаётся на текущем и на тех, что впереди: по ним и читается, что ещё будет.
  final IconData? icon;
}

/// The road a deal travels, drawn the same way for both sides.
///
/// The buyer watches it and the farm works down it, so it is one widget: if the two ever drew
/// their own, the step the farm ticked off and the step the buyer saw could stop matching.
class EtTimeline extends StatelessWidget {
  const EtTimeline({super.key, required this.entries});

  final List<EtTimelineEntry> entries;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < entries.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    _Dot(entry: entries[i]),
                    if (i != entries.length - 1)
                      Expanded(
                        child: Container(
                          width: 2,
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          color: entries[i].done ? c.green : c.line,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: i == entries.length - 1 ? 0 : 20),
                    child: _Entry(entry: entries[i]),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.entry});

  final EtTimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final filled = entry.done || entry.current;
    final icon = entry.icon;
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: entry.done ? c.green : (entry.current ? c.greenTint : c.surfaceRaised),
        border: Border.all(color: filled ? c.green : c.line, width: entry.current ? 2 : 1),
      ),
      child: entry.done
          ? Icon(Icons.check, size: 16, color: c.onGreen)
          : icon != null
              ? Icon(icon, size: 15, color: entry.current ? c.green : c.inkFaint)
              : entry.current
                  ? Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: c.green, shape: BoxShape.circle),
                      ),
                    )
                  : null,
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({required this.entry});

  final EtTimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final pending = !entry.done && !entry.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                entry.title,
                style: context.texts.titleSmall?.copyWith(
                  color: pending ? c.inkFaint : c.ink,
                  fontWeight: entry.current ? FontWeight.w800 : FontWeight.w700,
                ),
              ),
            ),
            if (entry.when != null && entry.when!.isNotEmpty)
              Text(entry.when!, style: context.texts.bodySmall?.copyWith(color: c.inkFaint)),
          ],
        ),
        if (entry.body != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: entry.body!),
      ],
    );
  }
}

/// Photos and videos of a step, in a row that scrolls.
///
/// A video has no thumbnail here on purpose: generating one costs a package and a decode on a
/// phone that is often a cheap one. A dark tile with a play badge says what it is, and tapping it
/// is the screen's business.
class EtMediaStrip extends StatelessWidget {
  const EtMediaStrip({
    super.key,
    required this.items,
    this.onTap,
    this.onRemove,
    this.size = 92,
  });

  final List<EtMediaItem> items;
  final void Function(EtMediaItem item)? onTap;
  final void Function(EtMediaItem item)? onRemove;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final c = context.et;
    return SizedBox(
      height: size,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: EtShape.gapSmall),
        itemBuilder: (context, i) {
          final item = items[i];
          return Stack(
            children: [
              GestureDetector(
                onTap: onTap == null ? null : () => onTap!(item),
                child: Container(
                  width: size,
                  height: size,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: c.fillTrack,
                    borderRadius: EtShape.smallRadius,
                    border: Border.all(color: c.line),
                  ),
                  child: item.isVideo
                      ? Center(child: Icon(Icons.play_circle_fill, size: 34, color: c.inkDim))
                      : Image.network(
                          item.url,
                          fit: BoxFit.cover,
                          width: size,
                          height: size,
                          errorBuilder: (_, __, ___) =>
                              Center(child: Icon(Icons.image_not_supported_outlined, color: c.inkFaint)),
                        ),
                ),
              ),
              if (onRemove != null)
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: () => onRemove!(item),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class EtMediaItem {
  const EtMediaItem({required this.url, required this.isVideo, this.name = ''});

  final String url;
  final bool isVideo;
  final String name;
}
