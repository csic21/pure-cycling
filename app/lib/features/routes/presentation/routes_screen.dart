import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/error_notice.dart';
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
        error: (e, stack) => ErrorNotice(
          title: '读取路线失败',
          message: ref
              .read(failureReporterProvider)
              .report(
                'routes.read',
                e,
                stack: stack,
                message:
                    '本机数据库没有响应。重启应用通常可以恢复；'
                    '如果反复出现，可以在「设置 → 诊断日志」中导出日志。',
              ),
          onRetry: () => ref.invalidate(savedRoutesProvider),
        ),
        data: (list) {
          if (list.isEmpty) return const _EmptyRoutes();

          // DAO order is favourites first. Keep one metadata list and build
          // only visible rows, rather than materialising every row widget.
          final favoriteCount = list.takeWhile((r) => r.favorite).length;
          final hasFavorites = favoriteCount > 0;
          final hasRest = favoriteCount < list.length;
          final headerCount = hasFavorites ? (hasRest ? 2 : 1) : 0;
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: list.length + headerCount,
            itemBuilder: (context, index) {
              if (hasFavorites && index == 0) {
                return const _ListHeader('收藏');
              }
              if (hasFavorites && hasRest && index == favoriteCount + 1) {
                return const _ListHeader('全部路线');
              }
              final routeIndex =
                  index -
                  (hasFavorites ? 1 : 0) -
                  (hasFavorites && hasRest && index > favoriteCount + 1
                      ? 1
                      : 0);
              final route = list[routeIndex];
              return _RouteRow(
                key: ValueKey(route.id),
                route: route,
                formatter: formatter,
              );
            },
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
  const _RouteRow({super.key, required this.route, required this.formatter});

  final RouteSummary route;
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
          onPressed: () => ref
              .read(routeRepositoryProvider)
              .setFavorite(route.id, !route.favorite),
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
            const Icon(
              Icons.route_outlined,
              size: 48,
              color: AppColors.textTertiary,
            ),
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
