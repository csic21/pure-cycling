# 纯粹骑行 / Pure Cycling

一款专注于骑行记录、码表、路线规划和导航的 App。骑行数据先保存在本机；云同步由用户自行开启。

支持 Android、iOS 和 macOS。Web 不在当前支持范围内。

## 功能

- 记录骑行、锁屏持续定位、暂停与崩溃后恢复
- 可配置码表、导航、转向语音播报和蓝牙传感器
- GPX 导入与导出、FIT 导出、历史记录
- 可选的高德骑行路线、路线高程和 Supabase 云同步

功能设计与当前取舍见 [产品规格](docs/product-spec.md)；定位和后台记录的实现见 [GPS 文档](docs/gps.md)。

## 本地运行

使用 Flutter 3.41.9。首次克隆后生成 Drift 数据库代码：

```sh
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

无需配置即可记录骑行、使用码表、查看历史、导入导出 GPX，并用直线路线进行规划与导航。生成的 `*.g.dart` 不提交到仓库；修改数据库表后需重新运行 `build_runner`。

### 可选服务

| 服务 | 配置 | 说明 |
| --- | --- | --- |
| 高德路线 | 开发时在「设置 → 地图」填写高德 Web 服务 Key；分发时部署 `route` Edge Function | [地图与 Key 管理](docs/map.md) |
| 云同步 | 设置 `SUPABASE_URL`、`SUPABASE_ANON_KEY`，应用内打开「启用云同步」 | [账号与同步](docs/auth.md)、[本地与云端架构](docs/architecture.md) |
| Edge Functions | 设置 `SUPABASE_FUNCTIONS_URL` | 路线中转、删除账号、检查更新；[部署说明](docs/ci.md) |

本地配置可复制 `app/dart_define.example.json` 为被忽略的 `app/dart_define.json`，再运行：

```sh
cd app
flutter run --dart-define-from-file=dart_define.json
```

不要把高德 Key、Supabase `service_role` Key 或 Android 签名密钥放入 App 或提交到仓库。凭据用途与权限边界见 [安全文档](docs/security.md)。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `app/` | Flutter 应用与测试 |
| `admin/` | Next.js 管理后台 |
| `supabase/` | 数据库迁移、Edge Functions、本地服务配置 |
| `scripts/` | 迁移、认证、本地整栈和密钥检查 |
| `docs/` | 产品与实现文档 |

骑行时的主要数据流为 `GPS → RideEngine → SQLite → SyncQueue → Supabase`。网络不可用时记录仍写入本机，稍后再同步。

## 验证

```sh
cd app
flutter analyze
flutter test
flutter build apk --release
```

数据库和服务端验证脚本、CI 检查项见 [CI 与发布](docs/ci.md)。真机上的长时间后台定位、耗电、GPS 漂移和蓝牙连接仍需实测，检查项见 [GPS 文档](docs/gps.md)。

## 发布

在 `app/pubspec.yaml` 更新版本号及递增的构建号，通过 CI 后合并。在 main 单独提交 `.github/release-request.json`，指定版本标签与完整 source_sha，由[受保护的发布控制器](.github/workflows/publish-request.yml)核验源码、APK 包名/版本、签名连续性和下载哈希后发布。旧标签发布工作流已停用；不要手动推送标签来发布。

Android 应用会检查新版本并在应用内下载 APK，随后由系统安装器确认安装；iOS 仍通过原安装渠道更新。

## 文档

- [地图、路线与导航](docs/map.md) · [海拔](docs/elevation.md) · [手机传感器](docs/phone-sensors.md)
- [骑行引擎](docs/ride-engine.md) · [导入导出](docs/export.md) · [界面设计](docs/design.md)
- [认证](docs/auth.md) · [安全](docs/security.md) · [隐私](docs/privacy.md) · [后台](docs/backend.md)
