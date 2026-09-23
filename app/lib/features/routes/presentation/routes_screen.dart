import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/utils/units.dart';
import '../domain/route.dart';

/// Saved routes (spec §3, §38).
class RoutesScreen extends ConsumerWidget {
  const RoutesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(savedRoutesProvider);
    final formatter = ref.watch(unitFormatterProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('路线'),
        actions: [
          IconButton(
            tooltip: '导入 GPX',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () => context.push(AppRoutes.routeImport),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(AppRoutes.routePlan),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('规划路线'),
      ),
      body: routes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (list) {
          if (list.isEmpty) return const _EmptyRoutes();

          // Favourites first, then most recently touched — the same order the
          // DAO returns, so the list does not reshuffle between screens.
          final favourites = list.where((r) => r.favorite).toList();
          final rest = list.where((r) => !r.favorite).toList();

          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (favourites.isNotEmpty) ...[
                const _ListHeader('收藏'),
                for (final route in favourites)
                  _RouteRow(route: route, formatter: formatter),
              ],
              if (rest.isNotEmpty) ...[
                if (favourites.isNotEmpty) const _ListHeader('全部路线'),
                for (final route in rest)
                  _RouteRow(route: route, formatter: formatter),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ListHeader extends StatelessWidget {
  const _ListHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(title, style: AppText.sectionTitle),
    );
  }
}

class _RouteRow extends ConsumerWidget {
  const _RouteRow({required this.route, required this.formatter});

  final Route route;
  final UnitFormatter formatter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: ValueKey(route.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: AppColors.danger,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) =>
          ref.read(routeRepositoryProvider).deleteRoute(route.id),
      child: ListTile(
        onTap: () => context.push(AppRoutes.routeDetailFor(route.id)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        title: Text(
          route.name,
          style: AppText.body,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Text(
                '${formatter.distanceKm(route.distanceMeters)} '
                '${formatter.system.distanceSuffix}',
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(width: 12),
              Text(
                UnitFormatter.durationMinutes(route.estimatedDuration),
                style: AppText.caption,
              ),
              if (route.elevationGainMeters != null) ...[
                const SizedBox(width: 12),
                Text(
                  '↑ ${formatter.elevationWithUnit(route.elevationGainMeters!)}',
                  style: AppText.caption,
                ),
              ],
            ],
          ),
        ),
        trailing: IconButton(
          icon: Icon(
            route.favorite ? Icons.star : Icons.star_border,
            size: 20,
            color: route.favorite ? AppColors.accent : AppColors.textTertiary,
          ),
          onPressed: () =>
              ref.read(routeRepositoryProvider).setFavorite(route.id, !route.favorite),
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条路线？'),
        content: Text(route.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

class _EmptyRoutes extends StatelessWidget {
  const _EmptyRoutes();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.route_outlined,
                size: 48, color: AppColors.textTertiary),
            const SizedBox(height: 16),
            const Text('还没有保存的路线', style: AppText.body),
            const SizedBox(height: 6),
            const Text(
              '规划一条路线，或导入别人分享的 GPX 文件',
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => context.push(AppRoutes.routeImport),
              icon: const Icon(Icons.file_download_outlined, size: 20),
              label: const Text('导入 GPX'),
            ),
          ],
        ),
      ),
    );
  }
}
