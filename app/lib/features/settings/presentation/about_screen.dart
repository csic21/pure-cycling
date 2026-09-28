import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/app_contact.dart';
import '../../../core/updates/update_prompt.dart';
import '../domain/privacy_policy.dart';

/// What this app is, what it does with your data, and what it is built on.
///
/// One screen rather than three: a rider looking for the privacy policy is
/// usually looking for one of the other two as well, and the stores need all
/// of it to be reachable without a browser.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versionAsync = ref.watch(appVersionProvider);
    final versionLabel = versionAsync.when(
      data: (version) => version == null ? '开发版本' : '版本 $version',
      loading: () => '版本读取中…',
      error: (_, _) => '开发版本',
    );
    final version = versionAsync.valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('纯粹骑行', style: AppText.title),
                const SizedBox(height: 4),
                Text(versionLabel, style: AppText.caption),
                const SizedBox(height: 16),
                const Text(
                  '一个没有社区、没有信息流、只专注记录、码表与导航的骑行 App。'
                  '记录全程不依赖网络，数据默认只保存在你的手机上。',
                  style: AppText.body,
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          const Divider(height: 1),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(
              Icons.system_update_outlined,
              color: AppColors.textSecondary,
            ),
            title: const Text('检查更新', style: AppText.body),
            subtitle: const Text(
              '通过 GitHub Release 查看新版本',
              style: AppText.caption,
            ),
            onTap: () => checkForAppUpdate(context),
          ),

          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text('隐私政策', style: AppText.sectionTitle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '最近更新 ${PrivacyPolicy.lastUpdated}',
              style: AppText.caption,
            ),
          ),
          for (final section in PrivacyPolicy.sections)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(section.heading, style: AppText.body),
                  const SizedBox(height: 6),
                  Text(
                    section.body,
                    style: AppText.caption.copyWith(height: 1.6),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 24),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text('地图与数据来源', style: AppText.sectionTitle),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Text(
              '地图瓦片与骑行路线规划：高德（中国大陆）、OpenStreetMap 与 CARTO'
              '（境外及深色底图）。坐标系转换只发生在与地图服务交互的边界上，'
              '本机与云端保存的始终是 GPS 原始坐标。',
              style: AppText.caption,
            ),
          ),

          const SizedBox(height: 24),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text('开源许可', style: AppText.sectionTitle),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.code, color: AppColors.textSecondary),
            title: const Text('查看使用的开源组件', style: AppText.body),
            subtitle: const Text(
              'Flutter 及其依赖的许可证全文，随应用一起离线提供',
              style: AppText.caption,
            ),
            onTap: () => showLicensePage(
              context: context,
              applicationName: '纯粹骑行',
              applicationVersion: version ?? '',
              applicationLegalese: 'Flutter 与各依赖组件的许可证见下。地图数据版权归各自提供方所有。',
            ),
          ),

          if (AppContact.hasSupportEmail) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Text('联系', style: AppText.sectionTitle),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const Icon(
                Icons.mail_outline,
                color: AppColors.textSecondary,
              ),
              title: Text(AppContact.supportEmail, style: AppText.body),
              subtitle: const Text('问题、错误报告与隐私相关请求', style: AppText.caption),
              onTap: () => launchUrl(
                Uri(scheme: 'mailto', path: AppContact.supportEmail),
              ),
            ),
          ],

          const SizedBox(height: 28),
          const Center(child: Text('没有社区，没有信息流', style: AppText.caption)),
        ],
      ),
    );
  }
}
