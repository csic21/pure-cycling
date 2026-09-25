# 纯粹骑行 / Pure Cycling

> 一个没有社区、没有信息流、只专注记录、码表与导航的骑行 App。

把手机变成一台真正好用的骑行码表与骑行导航器。核心只有四件事：**记录、码表、路线、导航**。

---

## 当前状态

V1 功能已经完整实现并通过测试，可以构建运行。

```text
289 个测试通过          flutter test
静态分析零问题          flutter analyze
Android release 构建通过 flutter build apk --release   （R8 开着）
macOS debug 构建通过    flutter build macos --debug
管理后台构建通过        cd admin && pnpm run build
Edge Function 测试通过  deno test supabase/functions/route/   （13 个，不需要 Docker）
SQL 迁移在 Supabase 官方镜像上验证通过   scripts/verify-migrations.sh
Auth 流程在真实 GoTrue 上验证通过        scripts/verify-auth-flow.sh
管理员边界在本地整栈上验证通过          scripts/verify-admin-flow.sh
删除账号在本地整栈上验证通过            scripts/verify-account-deletion.sh
完整本地栈（含 PostgREST / Storage）通过 scripts/local-stack.sh
密钥扫描自检通过        scripts/check-secrets.sh --self-test
```

**没有任何商业授权限制。** 所有依赖都是 MIT / BSD 类型。

V1.5 的语音播报已经实现：转向、偏航、重算和到达会用系统语音播报，默认关闭。
策略与测试见 [docs/map.md](docs/map.md) 的「语音播报」一节。

V2 的 FIT 导出也已经实现：骑行详情页可以导出 Garmin / Strava 通用的 FIT 文件，
编码器用手写实现、用独立解析器验证，见 [docs/export.md](docs/export.md)。

管理后台（Next.js）也搭起来了：账号列表、封禁 / 解封、审计日志。
它**看不到任何骑行内容**——这是产品承诺，有测试锁着。要不要独立后端、
管理员边界在哪，见 [docs/backend.md](docs/backend.md)。

尚未在真机 GPS 上验证的部分见 [§ 需要在真机上验证的部分](#需要在真机上验证的部分)。

### 锁屏继续记录

需求是：**锁屏时继续记录，只有骑手按「结束」或进程被杀才停止。**

三层保障：

| 层 | 机制 |
|---|---|
| 平台保活 | Android `location` 类型前台服务；iOS `UIBackgroundModes: location` |
| 引擎不依赖前台 | 生命周期事件只写检查点，不改变状态机；时间从墙上时钟差值推算，定时器被系统合并也不丢时间 |
| 进程被杀 | 5 秒检查点把损失限制在秒级；下次启动提供恢复 |

逻辑层已经用测试锁定（`ride_engine_test.dart` 的 `a locked screen must not interrupt the ride` 分组，
包括「墙上时钟前进 30 分钟而定时器完全不动」这种最坏情况）。
平台层需要在真机上验证，清单在 [docs/gps.md](docs/gps.md)。

---

## 快速开始

### 只跑本地功能（不需要任何配置）

```sh
cd app
flutter pub get
dart run build_runner build        # 生成 Drift 的数据库代码（首次必须）
flutter run
```

不配置任何东西也可以完整使用：记录骑行、码表、历史、GPX 导入导出、路线规划（直线兜底）、导航。
云同步和地图搜索会明确提示「未配置」，而不是静默失败。

`*.g.dart` 不提交到仓库，所以新克隆的副本必须先跑一次 `build_runner`。
改了 `core/database/tables.dart` 之后也要重新生成。

### 启用真实骑行路线（高德）

**自用 / 开发**：到 [高德开放平台](https://lbs.amap.com/) 申请一个 **Web 服务**
类型的 Key（不是 Android/iOS SDK Key —— 两者不通用，SDK Key 会被 REST 接口拒绝），
在 App 内「设置 → 地图」中填入，或直接写进数据库键 `amap_key`。
填入后路线规划切换到 `/v5/direction/bicycling`，返回沿道路的骑行路线和转向指令。

**分发给骑手时不要这么做**：不能让装上 App 的人自己去申请 Key；也不要把 Key
打进构建——客户端发出去的东西，机器主人一定能读到（装个代理就能看到 URL 里的
`key=`），打包等于公开，而 IP 白名单和数字签名都救不了移动端。分发的形态是
**服务端薄代理持有 Key**：

```sh
supabase functions deploy route
supabase secrets set AMAP_KEY=...
flutter run \
  --dart-define=SUPABASE_FUNCTIONS_URL=https://xxx.supabase.co/functions/v1
```

代理要求登录（匿名账号也可以）、按账号扣配额、只暴露算路一个接口。
理由、实现和本地验证见 [docs/map.md](docs/map.md) 的「Key 由谁持有」；
验证脚本是 `scripts/verify-routing-relay.sh`。

### 启用云同步（Supabase）

设置里的「启用云同步」**默认关闭**；关闭时任何触发路径都不会上传，
包括手动同步（`test/sync_gate_test.dart` 锁着这条承诺）。
打开后，传输的是骑行摘要、完整轨迹（GPX 文件）、保存的路线和设置。

删除云端数据：设置 → 云同步 → **云端数据** → 删除。它会清空云端的行和 GPX，
本机记录保留并变为「待上传」，**云同步同时关闭**——否则下一次同步会立刻
把刚删掉的东西重新传上去。重新打开开关就是重新备份一遍。

```sh
flutter run \
  --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGci...
```

**只用 publishable / anon key。**`service_role` key 会绕过全部 RLS，绝不能打进移动端二进制。

数据库迁移：

```sh
supabase db push          # 或者用 supabase CLI 的 migration 流程
```

迁移文件按顺序包含：表结构、RLS 与 grant、上传 RPC、Storage 桶。

#### 或者不建云项目，本地跑一整套

`supabase/config.toml` 已经配好了：匿名登录开启、`purecycling://login-callback`
已登记、App 用不到的服务（realtime / analytics / edge functions）关掉。所以：

```sh
scripts/local-stack.sh --reset    # 起栈、重放迁移、验证整条请求路径
```

它起的是真实的 Kong + GoTrue + PostgREST + Storage，然后**注册账号、调用
`push_ride`、上传 GPX**，并验证第二个账号读不到、下载不了。跑完会打印指向本地的
`flutter run` 命令，Studio 在 `127.0.0.1:54323`，本地收件箱在 `127.0.0.1:54324`。

这个脚本**不进 CI**：`supabase start` 要拉十来个镜像。CI 用下面两个精简脚本覆盖同样的策略。

---

## 仓库结构

```text
cycling-app/
├── app/                      Flutter 应用
│   ├── lib/
│   │   ├── app/              应用外壳、路由、主题、Provider 图
│   │   ├── core/             与 UI 无关的基础设施
│   │   │   ├── database/     Drift + SQLite（本地唯一真相）
│   │   │   ├── location/     GPS 采集、校验、平滑、距离计算
│   │   │   ├── map/          地图服务抽象 + 高德实现 + 坐标转换
│   │   │   ├── gpx/          GPX 编解码
│   │   │   ├── fit/          FIT 编解码（导出）
│   │   │   ├── sync/         Supabase 客户端、同步队列
│   │   │   └── utils/        地理计算、单位、格式化、ID
│   │   ├── features/         ride / dashboard / navigation / routes /
│   │   │                     history / sensors / settings / auth
│   │   └── shared/           跨功能组件
│   └── test/                 289 个测试（单元 + 界面）
├── admin/                    管理后台（Next.js，直连 Supabase）
├── supabase/                 迁移 + 本地整栈配置（config.toml）
├── docs/                     文档
├── scripts/                  迁移验证、Auth 验证、管理员边界验证、本地栈、密钥扫描
└── .github/workflows/        CI 与发布流水线
```

---

## 架构要点

### 本地优先

```text
GPS → RideEngine → SQLite → SyncQueue → Supabase
```

骑行过程中**不经过网络**。山区、隧道、弱信号、后台运行、服务器故障都不会影响轨迹记录。
同步失败只会重新排队，**没有任何代码路径会因为网络问题删除或覆盖本地记录**。

### RideEngine 与 UI 解耦

`RideEngine` 是纯计算：没有 Flutter、没有数据库、没有网络。持久化通过回调推出。

这让整个记录管线可以用合成定位点测试 —— 参见 `app/test/ride_engine_test.dart`，
它用 `fake_async` 同时控制时钟和定时器队列，模拟出完整的骑行过程。

UI 只订阅 `RideState`，没有任何 Widget 自己计算距离或速度。

### 两端一套设计语言

App 和管理后台共用同一套 token：纯黑 `#000000`、发丝线分隔、青柠 `#C8FF3D`
只表示「进行中／主操作」、数字全部等宽。层级靠线和明度，不靠卡片、阴影、
渐变——两个界面因此看上去是同一台仪器的两张脸，而不是两个模板。

token 只有两处定义（`app/lib/app/theme.dart` 和 `admin/app/globals.css`），
改动必须一起做。完整规则、反模式（全大写小标题、`·` 元信息串、卡片网格）
和两端的落地方式见 [docs/design.md](docs/design.md)。

### 界面测试揪出的问题

界面测试（`app_flow_test.dart` / `ride_flow_test.dart`）第一次跑就发现了 8 个
单元测试完全覆盖不到的问题。它们全部编译通过、全部不影响领域层测试：

| 问题 | 后果 |
|---|---|
| 轨迹点有指向骑行行的外键，但骑行行只在结束时才写入 | **每次骑行的完整轨迹全部丢失** —— 地图、GPX、海拔图全空，而且异常被 `catch` 吞掉 |
| `RideSession` 用 `late final` 字段接 `build()` 的赋值 | Riverpod 重建时抛 `LateInitializationError` —— 高德 Key 从磁盘读完的那一刻崩溃 |
| 录制器在 `engine.start()` **之后**才订阅状态流 | 广播流没有重放，「准备中」被发给空房间，倒计时永远不显示 |
| `RideSession` 同样在录制器启动**之后**才订阅 | 同一类问题，高一层 |
| 距离磁贴的单位写死 `km` | 135 米显示成「135 km」 |
| `MetricTile` 在预览面板里溢出 | 调试时是红黄条纹，release 里是静默截断 |
| 恢复面板的三个数字格溢出 | 同上 |
| `routingAvailabilityProvider` 用 `isConfigured` 判断 | 直线兜底 provider 永远「已配置」，**降级提示永远不会出现** |

外加 `_teardownEngine` 先 await 定位取消再停引擎，导致录制定时器活过了拆解。

这些的共同点是：**单看代码都合理**。只有把整个树跑起来才会暴露。

### 三个容易被忽略的正确性问题

实现过程中有三处细节值得单独说明，因为它们都是「看起来对、实际错」的类型：

**1. 距离计算的门限是半径，不是逐点阈值**

「忽略与前一点距离小于 N 米的采样」是直觉上正确、实际错误的设计。
静止的接收机不是收敛在一个点上，而是**来回摆动**：连续两个采样相距 10 米完全正常。
任何小到能保住真实骑行的逐点阈值都会放进这种摆动，而摆动是正负交替的，会累加起来。

正确做法是围绕一个**保持不动的锚点**设半径：半径内的采样既不计入距离，也不移动锚点，
所以围绕一个固定点的摆动永远逃不出半径范围。这个设计的关键性质是它**延迟而非丢弃**：
采样最终越过半径时，从锚点起的完整距离一次性入账。

参见 `core/location/distance_calculator.dart`。

**2. 坐标系转换在高德边界完成，且只在那里完成**

GPS 芯片和系统定位 API 返回 WGS-84。高德按法规发布 GCJ-02 的瓦片和路线，
两者相差 50–500 米。把 WGS-84 轨迹直接画在 GCJ-02 瓦片上，线条会偏离实际道路。

本项目遵循的规则：**内部全部 WGS-84**（数据库、引擎、GPX、Supabase），
只有 `core/map/amap/` 下的代码做双向转换。其它任何地方都不出现坐标系概念。

**3. 平均速度的分母是移动时间，不是总时间**

否则每个红绿灯都会拉低这个数字。骑行时间包含自动暂停，移动时间不包含 ——
默认码表同时显示两者，正是为了让这个区别可见。

---

## 平台配置

权限已经配置好了，因为它们不是可选项：

**Android** (`android/app/src/main/AndroidManifest.xml`)
- 精确定位 + 后台定位
- 前台服务（没有它，锁屏后骑行会被系统杀掉）
- 蓝牙扫描 / 连接（扫描声明 `neverForLocation` —— 这个 App 找的是心率带，不是位置）
- R8 规则在 `android/app/proguard-rules.pro`

**iOS** (`ios/Runner/Info.plist`)
- 三级定位权限说明 + `UIBackgroundModes: location, bluetooth-central`
- 蓝牙权限说明

**macOS** (entitlements)
- 定位、蓝牙、网络客户端、用户选择文件读取

### Web 不是目标平台

项目只构建 Android / iOS / macOS。**Web 被刻意移除了**，原因不是优先级，
而是它在这个依赖组合下根本无法构建：

`drift_dev make-web-worker`（生成 web 端所需的 worker）在 drift_dev 2.34.0 上是坏的，
而 2.34.0 是当前 Flutter SDK 能解析的唯一版本 —— SDK 把 `meta` 钉在 1.17.0，
drift_dev ≥ 2.34.1 需要 `analyzer ^13`，冲突。

产品是装在车把上的手机 App，Web 从来不在范围内。与其留一个构建不出来的目标，
不如明确去掉。

---

## 测试

```sh
cd app
flutter test
```

覆盖范围：

| 文件 | 覆盖内容 |
|---|---|
| `distance_calculator_test.dart` | 静止抖动、慢速漂移、坏定位、恢复续算 |
| `ride_engine_test.dart` | 完整生命周期、自动暂停、爬升、传感器、崩溃恢复、GPS 状态 |
| `navigation_engine_test.dart` | 投影、进度单调、转向提示、偏航重算、自动切图、ETA |
| `gpx_codec_test.dart` | 编解码往返、扩展字段、WKT、简化 |
| `coord_transform_test.dart` | WGS-84 ⇄ GCJ-02 往返精度、境外恒等 |
| `gatt_parsers_test.dart` | 心率 8/16 位、CSC 计数器回绕、功率字段位移 |
| `units_and_settings_test.dart` | 单位换算、码表字段、配置持久化容错 |
| `elevation_accumulator_test.dart` | 爬升算法，含两个由测量发现的回归 |
| `elevation_noise_probe_test.dart` | 测量探针：各数据源的虚报爬升与真实爬坡保真度 |
| `amap_parsing_test.dart` | 高德响应解析、坐标转换、错误分类 —— 用录制响应，不需要 key |
| `ride_recorder_test.dart` | 骑行落盘：摘要、轨迹、几何、同步队列、放弃清空 |
| `app_flow_test.dart` | 界面冒烟：四个标签页、历史、详情、设置、路线、同步 |
| `ride_flow_test.dart` | 记录流程：倒计时、实时速度、暂停/继续、权限、返回键守卫、崩溃恢复 |
| `password_recovery_test.dart` | 重置链接 → 设置新密码 → 生效的整条链路 |
| `ride_metadata_test.dart` | 名称与备注的编辑、清空，以及和云端副本的合并 |
| `sync_queue_test.dart` | 出件箱：重复入队只留一行，新的编辑重置退避 |
| `diagnostic_log_test.dart` | 诊断日志的写入 / 上限 / 不抛异常，以及出错页与导出入口 |
| `auth_test.dart` | 深链配置、账号标签、Supabase 错误翻译 |
| `account_section_test.dart` | 匿名 / 实名两种账号状态的界面 |
| `voice_coach_test.dart` | 播报策略：远近两级、去重、隧道跳级、偏航 / 重算 / 到达、优先级与队列 |
| `voice_session_test.dart` | 播报接线：会话是否真的把导航快照喂给了教练 |
| `fit_codec_test.dart` | FIT 编码器：CRC、semicircle 往返、缩放字段、无效值、边界 —— 用独立解析器解码 |

SQL 迁移和 Auth 流程都用**Supabase 官方镜像**验证，不需要云项目、不需要任何 key：

```sh
scripts/verify-migrations.sh    # 表结构 + RLS 隔离 + user_id 伪造防护 + 管理员边界 + 配额
scripts/verify-auth-flow.sh     # 真实注册 + 匿名 + 令牌 + 跨账号隔离
scripts/local-stack.sh          # 完整本地栈：PostgREST + Storage + Studio（开发用）
scripts/verify-admin-flow.sh    # 管理员边界走真实 PostgREST（需要本地栈在跑）
scripts/verify-routing-relay.sh # 算路代理走真实 Edge Function，桩代替高德（需要本地栈）
scripts/verify-account-deletion.sh # 自助删除账号走真实函数与存储（需要本地栈）
```

`verify-auth-flow.sh` 会真的注册两个账号（一个邮箱、一个匿名），
再验证触发器、令牌的 `sub`、以及两个账号互相看不见。
**这里同时有三样独立演进的东西在交界**——本仓库的迁移、Supabase 的 `auth` schema、
Supabase 的 Auth 服务——不匹配只会在运行时暴露。

---

## 登录

**不登录也能完整使用** —— 记录、码表、历史、GPX 全部在本地完成，没有一个功能需要登录。
登录只做一件事：把骑行备份到云端，让换手机之后能找回来。

已完成：邮箱密码注册/登录、邮箱验证、忘记密码、匿名登录、**匿名账号绑定邮箱**、
退出登录、会话持久化与自动刷新。完整说明见 [docs/auth.md](docs/auth.md)。

一个最容易漏的环节：Supabase 发出的邮件链接要能回到 App，需要在三个平台上注册
`purecycling://` URL scheme，**并且**在 Supabase 控制台的
Authentication → URL Configuration → Redirect URLs 里加上同一个地址。
不加的话邮件照常发出，只是链接指向浏览器 —— 骑手确认完回不到 App，
账号是好的但 App 还显示登录表单，看起来像「验证没生效」。

---

## 密钥管理

**不要把 key 提交到 git。** 高德 Key 是按配额计费的凭据，公开仓库里的 key 几小时内就会被扫走，
然后真实用户规划路线会失败。Supabase 的 `service_role` 泄露更严重——它绕过全部 RLS。
而且 git 历史是永久的，事后删文件没用。

**而且这个项目不需要。** 289 个测试没有一个需要 key；高德的解析用录制响应测；
没配置 key 时 App 完整可用，只有路线规划退化成直线。
**高德 Key 根本不进流水线**——它是运行时填在 App 设置里、存在用户手机上的。

配置方式见 [docs/ci.md](docs/ci.md)。

### 分发出去之后：反编译拿到 key 能做什么

App 二进制里**只有** Supabase URL 和 anon key，两者本来就是公开凭据；
service_role、高德 Key、签名密钥都不在里面。拿到 anon key 的人能注册账号、
操作**自己**的数据，读不到任何人的骑行、也调不了管理函数——
这两层（SQL 与 API）都有断言，见 [docs/security.md](docs/security.md)。
真正要防的是滥用（注册与存储配额）和 service_role 泄露，清单在同一份文档里。

```sh
# 本地开发
cp app/dart_define.example.json app/dart_define.json   # 填真实值，此文件不进 git
flutter run --dart-define-from-file=dart_define.json

# 提交前自查
./scripts/check-secrets.sh
```

---

## 构建流水线

```
ci.yml（每次 push）        secrets → analyze+test → migrations → build-android → build-ios
release.yml（打 tag）      verify → 签名 AAB / iOS 归档
```

Android 那步特意用 **release** 而不是 debug：debug 不跑 R8，而 R8 是 proguard 规则
唯一会暴露问题的地方，失败只会在 release 构建的运行时出现。

依赖版本固定而不是 `latest`——Flutter 升级会改变分析器规则集和 drift 代码生成器的输出，
两者都会让无关的 PR 变红。

---

## 需要做的决定

### 红绿灯倒计时

代码里保留了 `TrafficLightProvider` 抽象和一个明确返回「不可用」的高德实现。

高德的红绿灯倒计时能力通过**两轮车导航 SDK** 提供，不是本项目使用的 Web 服务 REST 接口。
接入它需要单独授权、Key 和原生 SDK 集成，而且需要先确认：平台支持情况、iOS/Android 支持情况、
商务费用、普通自行车是否可用、数据覆盖城市。

在确认之前，返回「不可用」比返回空列表更诚实 —— 后者看起来和「前方没有红绿灯」一样。

### 没有气压计的手机

爬升高度在纯 GPS 设备上是**估算值**，不是测量值。原因是 GPS 高度误差会缓慢漂移，
而这段漂移和真实爬坡处在同一频段，无法分离。

已经做的：阈值按垂直精度自适应、算法改为峰值检测、UI 标注「估算」。
实测 300 m 真实爬坡报 299 m，9 km 平路虚报 15–32 m。

还没做的（按性价比）：读手机自带气压计（差 15 m → 2 m）、用 DEM 高程数据修正。

完整分析、测量数据和三个方案的取舍见 [docs/elevation.md](docs/elevation.md)。

### 高德骑行路线不含海拔

`/v5/direction/bicycling` 不返回海拔数据。因此路线详情里的「爬升」显示 `—` 而不是 `0`，
因为 0 是一个断言，不是一个占位符。V2 的「路线海拔剖面」需要第三方高程数据（例如 SRTM）补齐。

---

## 需要在真机上验证的部分

以下项目在当前环境（macOS 桌面 + 合成数据）无法验证，需要真机：

- **锁屏 2 小时后台定位是否连续** —— 规格书 §31 明确要求这是 MVP 早期就要验证的技术点
- **真实 GPS 漂移** —— 城市高楼、树荫、隧道、红绿灯停车
- **耗电与发热** —— 连续 4 小时以上
- **BLE 传感器实际连接** —— 解析器已用构造报文测试，但没有连过真实设备
- **强杀进程后恢复** —— 检查点逻辑已测试，但没有在真机上杀过进程

规格书 §41 要求的验收场景（真实骑行 5 / 20 / 50 / 100 km）需要按此清单执行。

---

## 已知取舍

- **码表布局是三种固定版式**，不是自由拖拽。版式编码了「主数字至少占屏幕 20%」这条规则（§5.1），
  自由布局允许做出在骑行中无法阅读的码表。
- **骑行结束后只有名称和备注可改**（§28）。这让与云端的合并变得非常简单：
  永远没有统计数字需要协商。
- **自行车（车辆）没有做成功能** —— `rides.bike_id` 这个字段从第一版就在，
  但没有任何东西能写它：本地没有 bikes 表，云端 `public.bikes` 也没有对应的
  上传路径（`push_ride` 的 payload 里没有 `bike_id`）。所以「选一辆车」在今天
  只能是一个本地有效、重装即失、且上传后被静默丢弃的下拉框 —— 规格 §2.3 把
  自行车管理放在 V2，这里先不给这个承诺。真要做需要三件事：本地 bikes 表 +
  `public.rides.bike_id` 列 + `push_ride` 带上它。
- **路线收藏是本地偏好，不上传**。你自己收藏了哪条路线，不需要告诉别的设备。
- **删除采用 tombstone**，本地行保留，避免离线设备重新上传已删除的记录。
- **`trip_distance` 字段未实现** —— 规格 §6 的可选字段里它和 `distance` 是同一个数值，
  提供两个做同一件事的选项只会让用户困惑。
- **纯 GPS 设备的爬升是估算值** —— 详见 [docs/elevation.md](docs/elevation.md)。
  没有气压计的手机，9 km 平路会虚报 15–32 m 爬升；这是物理限制而非实现缺陷。
  长爬坡几乎无损（300 m 报 299 m），UI 会把结果标注为「估算」。
- **语音播报默认关闭** —— 它比看屏幕更打扰，也更耗电。开关在骑行中即时生效：
  关掉立刻静音，打开从下一个定位开始播报。语速与音色跟随系统，App 不提供选择。
- **macOS release 打包在当前工具链上不可用** —— Flutter 3.41.9 的
  `release_unpack_macos` 用 `lipo <file> -verify_arch …`，而 Xcode 27 的 lipo
  要求 `-verify_arch` 在前，直接报「requires exactly one input file」。
  这是 SDK 侧的问题，仓库里改不了；debug 构建正常，开发和测试不受影响。

---

## 手动构造一个 GPX 测试文件

导出格式（GPX 与 FIT）的设计说明见 [docs/export.md](docs/export.md)。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>测试路线</name>
    <trkseg>
      <trkpt lat="39.9042" lon="116.4074"><ele>50</ele></trkpt>
      <trkpt lat="39.9142" lon="116.4174"><ele>80</ele></trkpt>
      <trkpt lat="39.9242" lon="116.4274"><ele>120</ele></trkpt>
    </trkseg>
  </trk>
</gpx>
```

导入方式：「路线 → 导入 GPX → 从文件选择 / 从剪贴板粘贴」。
