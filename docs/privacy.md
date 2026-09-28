# 隐私政策

> **权威文本在应用里**：`app/lib/features/settings/domain/privacy_policy.dart`。
> 「设置 → 关于」显示的就是它，逐字相同。

为什么放在代码里而不是只放一份文档：

- 骑手在手机上、离线、没有浏览器时也要能读到它。上架需要的那个 URL
  应该提供同一份文本，但应用不能依赖网络才能解释自己。
- 一份文本只有一个来源。文档、商店页面和应用各写一遍，就是三份会各自漂移的
  承诺 —— 而这个项目里其它承诺都是靠测试守住的，隐私这条没有理由更松。

---

## 上架需要的东西

| 位置 | 需要什么 | 状态 |
|---|---|---|
| App Store Connect / Play Console | 隐私政策 URL | 需要托管（内容用上面的文件） |
| Play Console | 数据安全表单：收集「位置」（可选、用于核心功能、不共享、可删除） | 需要填写 |
| Play Console | 后台定位申报（应用内披露 + 演示视频） | 应用内披露已实现：`location_notice.dart`，真机视频需要录制 |
| App Store Connect | 隐私标签：位置（不用于追踪、不与第三方关联）、邮箱（账号） | 需要填写 |
| 联系邮箱 | `--dart-define=SUPPORT_EMAIL=` | 可选，未设置时不显示联系入口 |

## 商店页面用的一段话（可直接用）

> 纯粹骑行只做四件事：记录、码表、路线、导航。骑行数据默认只保存在你的手机上，
> 只有你主动打开云同步才会备份到你的账号。没有社区、没有信息流、没有排行榜，
> 也没有任何公开分享入口。我们不读取通讯录、不获取广告标识、不接入第三方统计
> 或崩溃上报 SDK。位置轨迹是高度敏感的数据，因此它默认私有 —— 你可以随时删除
> 单条骑行、清空云端数据，或永久删除账号。

## 与代码的对应关系

政策里的每一条都能在仓库里找到根据，这是它敢写这么短的原因：

| 承诺 | 在哪里被守住 |
|---|---|
| 云端只有本人能读写 | `supabase/migrations/20260923000100_rls_and_grants.sql`，`scripts/verify-migrations.sh` / `verify-auth-flow.sh` 断言跨账号读不到 |
| 后台看不到轨迹、GPX、位置 | `20260924000100_admins.sql` 的 `admin_list_users`，`scripts/verify-migrations.sh` 断言管理员读 `rides` 得到 0 行 |
| 删除云端数据 / 删除账号真的删 | `supabase/functions/delete-account`，`scripts/verify-account-deletion.sh` |
| 不开云同步就不上传骑行数据 | `test/sync_gate_test.dart`；地图和版本检查的网络请求另见应用内隐私政策 |
| 版本检查不发送骑行数据 | `core/updates/github_release_checker.dart` 只请求 GitHub Release 元数据 |
| 诊断日志不上传、只有异常 | `core/diagnostics/diagnostic_log.dart`，`test/diagnostic_log_test.dart` |
| 位置只在记录时采集 | `core/location/location_service.dart` 的流只在骑行期间订阅（`RideRecorder` 建立、拆解时取消） |
