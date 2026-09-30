# 架构

## 一句话

骑行时，数据从 GPS 流向引擎、流向 SQLite，**不流向网络**；骑行结束后，SQLite 通过一个持久化队列
流向 Supabase。云是备份，不是依赖。

```text
                    ┌─────────────┐
                    │  GPS / BLE  │
                    └──────┬──────┘
                           │  原始数据
                           ▼
                    ┌─────────────┐
                    │ RideEngine  │   校验 → 平滑 → 距离 → 统计
                    │  (纯计算)    │   无 Flutter / 无 IO / 无网络
                    └──────┬──────┘
                           │  RideState（不可变快照）
              ┌────────────┼────────────┐
              ▼                         ▼
      ┌───────────────┐         ┌───────────────┐
      │  UI 只订阅     │         │    SQLite     │
      │  RideState    │         │  本地唯一真相  │
      └───────────────┘         └───────┬───────┘
                                        │
                                  Sync Queue
                                        │
                                        ▼
                                ┌───────────────┐
                                │   Supabase    │
                                │ Auth/RLS/Store│
                                └───────────────┘
```

---

## 分层

`core/` 放与 UI 无关的基础设施，`features/` 按功能切分，`shared/` 放跨功能组件。

依赖方向是单向的：`features → core`。`core` 不 import `features` —— 唯一的例外是
`core/database/mappers.dart` 和 `core/sync/supabase_remote.dart`，它们需要把 domain model
翻译成存储格式。这是有意的：转换逻辑集中在一处，比让 domain 认识 drift 更好。

### 为什么 RideEngine 没有 I/O

`RideEngine` 的构造函数接收三个回调，而不是一个数据库：

```dart
RideEngine({
  TrackPointSink? onTrackPoint,      // 每个校验通过的轨迹点
  CheckpointSink? onCheckpoint,      // 每 5 秒的崩溃恢复检查点
  RideFinishedSink? onRideFinished,  // 结束时产出最终记录
})
```

这样做的回报是 `test/ride_engine_test.dart`：用合成的定位点在假的时钟上跑完整的四小时骑行，
不需要设备、不需要卫星、不需要自行车。整个过程耗时 0.3 秒。

如果把 Repository 注入进去，这个测试就不可能存在 —— 你得有一个真的 SQLite、真的文件系统，
以及处理异步写入时序的一堆麻烦。

### 为什么导航是独立的引擎

`NavigationEngine` 有自己的投影、偏航判定和重算逻辑，不共享 `RideEngine` 的状态。

两者在 `RideSession` 里汇合：它把 `RideState.lastPoint` 喂给导航引擎，把两个流折成一个
`RideSessionState` 给 UI。

分成两个引擎的原因是它们的失败模式不同。骑行引擎的 bug 表现为里程不对；导航引擎的 bug 表现为
转错弯。混在一起会让「距离为什么少了 200 米」变成一个需要同时理解投影算法的问题。

---

## 界面测试

`test/app_flow_test.dart` 和 `test/ride_flow_test.dart` 用真实的 widget 树跑：
真实的 provider、真实的路由、真实的界面。只替换两样东西 —— 内存数据库，
和假的定位服务（`geolocator` 在测试绑定里没有插件）。

### 三个必须知道的坑

**不能用 `pumpAndSettle`。** 每个界面在数据流加载时都会渲染
`CircularProgressIndicator`，而它是无限动画 ——「没有待调度的帧」永远不成立，
`pumpAndSettle` 会一直阻塞到十分钟超时。**失败表现是完全没有输出**，
看起来像测试卡死。用 `settle(tester)`（固定泵 600 ms）。

**600 ms 不是随便选的。** 要覆盖两件事：drift 查询需要一次事件循环 + 一帧；
路由转场需要 300 ms，而转场没结束时**上一个界面还在舞台上** ——
两屏都有的文字会被找到两次，只在新屏上的文字会找不到。

**测试视口要够高。** 默认 800×600 比这些界面都小，会造成两种看起来像 App bug
的失败：`ListView` 只构建**可见**的子项，所以屏幕外的文字 `find` 找不到；
落在底部导航栏下面的行会被导航栏抢走点击（点「OLED 模式」会切到「记录」标签页）。
用 `useTallSurface(tester)`。

### 拆解顺序

`shutdownApp` 必须在测试体里显式调用，不能放 `tearDown`：绑定在测试体结束时
检查待处理定时器，而 tearDown 在那之后才跑。同时顺序不能反 ——
先把树拆掉，再让 drift 的流清理定时器触发，最后关数据库。

### 什么时候该用普通测试而不是界面测试

持久化用 `test/ride_recorder_test.dart`（普通 `test`，无 widget 绑定）。
停止骑行是一串 await 的写入，界面测试的 fake-async 区不会推进数据库和文件系统
真正完成所用的那个事件循环。没有 widget 绑定时整条链在真实事件循环上跑，
断言是确定性的 —— 关于 App 而不是关于时序。

这个决定直接换来了最有价值的一个发现：**轨迹点全部丢失**（见下）。

---

## 数据流：一次骑行

```text
1. 首页点击「开始骑行」
      ↓
2. LocationService.ensurePermission()      权限、服务检查
      ↓
3. RideSession.start()                      创建 RideRecorder + RideEngine
      ↓
4. RideEngine.start()                       status = preparing，启动 1 Hz ticker
      ↓
5. RideRepository.beginRide()               写入占位行 ← 必须在第一个轨迹点之前
      ↓
6. 第一个定位到达                           过滤 → 平滑 → 首个轨迹点
      ↓
7. StartCountdownOverlay 倒计时             同时显示 GPS 精度
      ↓
8. engine.beginRecording()                  重置时钟，status = riding
      ↓
9. 每秒：onLocation() → 校验 → 平滑 → 距离 → 新 RideState
      ↓                                    UI 重建；导航引擎消费位置
10. 每 10 个点：批量写入 SQLite（RideRecorder._flushPoints）
      ↓
11. 每 5 秒：先 flush 再写 active_ride 检查点
      ↓
12. 用户点「结束」→ engine.stop() → 生成 Ride
      ↓
13. RideRepository.saveFinishedRide()
      ├── upsert ride 行（用最终数据覆盖占位行）
      ├── 写入缓冲区里剩余的轨迹点
      ├── 从数据库读回完整轨迹 → 生成 WKT LineString
      ├── 后台写 GPX 文件（不 await）
      └── 加入 SyncQueue，sync_status = pending_upload
      ↓
14. 网络可用时 SyncService 上传 GPX 到 Storage，upsert ride 行
```

第 5 步不能省。`track_points` 对 `local_rides` 有外键，而 `PRAGMA foreign_keys = ON`
是开着的 —— 没有父行的点会被数据库直接拒绝。第 10 步的批量写入从骑行开始后几秒就发生，
所以占位行必须在那之前存在。

第 13 步的顺序也很重要：**先本地提交，再生成派生产物，最后入队**。
任何一步失败都不会回滚前面的步骤 —— 一个 GPX 写失败的骑行仍然是一次骑行，
而且 GPX 随时可以从数据库里的轨迹重新生成。

GPX 落盘刻意不 await：它写在轨迹已经提交之后，导出和上传两条路径都会在文件缺失时
按需重新生成。让骑手等着一次两兆的闪存写入才肯承认「已保存」没有任何好处。

---

## 崩溃恢复

三个机制配合：

1. **批量写入**：每 10 个轨迹点（约 10 秒）写一次 SQLite。1 Hz 单点写入会让闪存和电量都受不了。
2. **检查点**：每 5 秒写一行 `active_ride`，包含累计距离、时间、最大速度、爬升、
   最后位置**以及距离计算器的锚点**。
3. **顺序保证**：检查点写入前**先 flush 轨迹点**。检查点记录 `lastSequence`，
   如果那个序号的点还没落盘，恢复时就会跳过它。

崩溃后重启：

```text
App 启动 → 读取 active_ride → 有未完成的骑行？
   ↓ 是
弹出底部面板，先显示已记录的数字（骑手最想知道「我的数据还在吗」）
   ↓
「继续这次骑行」→ RideRecorder.resumeRide()
   ├── 从数据库查出实际的最大 sequence（数据库才是权威，检查点可能落后一次 flush）
   ├── 用锚点、累计距离、爬升重新播种各个计算器
   └── status = paused，等待骑手确认后 resume
```

恢复时**不会**把检查点到恢复点之间的位移算进距离 —— 那段时间骑手可能在继续骑，
也可能在原地，把它算进去是编造。

---

## 出错时

没有崩溃上报 SDK，这是决定不是遗漏：位置轨迹是这个 App 最敏感的数据，
把堆栈顺手发给第三方是一个没人同意的选择。替代方案是**本机诊断日志**：
出错时写文件，骑手愿意的时候自己导出。默认什么都没发生，日志最多占用
256 KB，超出后丢最旧的一半。

三层兜底，缺一层就有一种错误会消失：

| 层 | 覆盖什么 |
|---|---|
| `FlutterError.onError` | build / layout / paint 抛出的错误 |
| `PlatformDispatcher.onError` | 平台通道回来的、没人接的异常 |
| `runZonedGuarded` | 定时器和 stream 回调里的错误 —— 没有它，这类错误既不显示也不记录 |

`ErrorWidget.builder` 也换掉了：默认的灰块什么都不说，而骑手最需要知道的一件事是
「记录还在不在」。出错的界面换成一句**记录不受影响、重启后可以继续**的说明
（记录写在本机数据库，不依赖任何 Widget），外加一行错误摘要和日志的位置。
这个 View 故意不依赖 `MaterialApp` / `Theme` / `Directionality` —— 出问题的
可能正是提供它们的那一层。

导出走系统分享（`设置 → 诊断日志 → 导出日志`），在 iOS 上这是唯一能拿到那份
文件的路径；没有导出，这个日志等于不存在。

### 被捕获的错误也走同一条路

上面三层管的是**没人接**的错误。还有一类是代码接住了、然后决定怎么告诉骑手的 ——
读数据库失败、导出失败、导入的文件损坏。这些曾经是这样写的：

```dart
error: (e, _) => Center(child: Text('读取失败：$e')),
```

骑手看到 `SqliteException(11): database disk image is malformed`，
而唯一对排查有用的东西没有进日志 —— 因为它根本没被当成错误上报。

现在统一成 `FailureReporter`：**屏幕上一句话说明下一步做什么，异常和堆栈进日志**。
界面用 `ErrorNotice`（整屏，带「重试」）或 `ErrorBanner`（行内），
数据从哪里失败就用哪个，但文案的分工是一样的。已经写成人话的异常
（`RoutePlanningException` / `AuthFailure` 的 message）直接显示，不进日志 ——
没网不是缺陷，不该把日志塞满。

## 已知的一个反面教材

`sync_queue_items` 上的 `enqueue` 曾经用 `insertOnConflictUpdate`，注释写着
「替换重复项」——而 drift 那个方法**只按主键判冲突**，这张表的主键是自增 id，
没人填。于是唯一键（entity, operation）被违反时抛的是 `UNIQUE constraint failed`，
不是替换。它一直没暴露，因为让同一个实体入队两次的路径很窄；而一旦走到，
同步会失败在一个「本来就不该失败」的地方。现在 `DoUpdate` 的冲突目标写全了，
`sync_queue_test.dart` 锁着。

---

## 同步

### 冲突策略（规格 §28）

| 数据类型 | 策略 |
|---|---|
| 骑行记录 | Local wins，前提是 `local.updated_at > cloud.updated_at` |
| 用户设置 | Last Write Wins |
| 删除 | tombstone（`deleted_at`） |

骑行结束后记录基本不可变，只有 `name` / `notes` 可以改（`bike_id` 字段在本地
存在，但云端 schema 没有它，见 README「已知取舍」）。
这让合并变得非常简单：永远没有统计数字需要协商。云端的更新只取这几个描述性字段，
**不会覆盖本机记录的统计数字** —— 那些是从 GPS 接收机读出来的，不该被一行摘要改写。

名字和备注按**原值**取用，包括 `null`：能设置、不能清空的字段等于只能写一次，
而在另一台手机上把备注删掉的骑手是认真的。

`push_ride` 里还有一条：

```sql
route_geometry = coalesce(excluded.route_geometry, rides.route_geometry)
```

一台还没生成几何就推送的设备，不会把云端已有的轨迹线擦掉。

### 重试退避

```text
15s → 60s → 5min → 15min → 30min → 1h（上限）
```

上限设为一小时：隧道里录的骑行应该在骑手出来之后不久就同步，而不是第二天早上。

网络恢复时 `resetBackoff()` 会清空退避，立即重试。

### 开关是唯一的闸门

设置里的「启用云同步」默认关闭。关闭时**不上传任何内容**，包括手动按下
「立即同步」——`syncNow()` 在所有触发点之前先看这个开关，闸门只有一处：

```text
网络恢复 / 退避重试 / App 回前台 / 登录成功 / 下拉刷新 / 手动按钮
                              │
                              ▼
                    syncNow()  ← 先看 cloudSync
                      │ 关 → SyncPhase.disabled，连客户端都不解析
                      ▼ 开
                    推送 → 拉取
```

放在这里而不是放在每个调用点，是因为调用点会随功能增加，而承诺不会。
`test/sync_gate_test.dart` 锁住三件事：关闭时不上传、`force` 不能绕过、
打开后闸门确实放行。

「关闭后仍可手动同步」曾经是设置页的原话——那不是开关，是建议。

### 删除云端副本

设置页提供「删除云端数据」。顺序是有讲究的：**先对象、后行**——行是桶内容的
索引，先删行就再也找不到该删的文件，而一个「删除」动作把位置轨迹留在存储里
是最糟的失败。本地这边：`gpx_path` 清空（它指向的 404 已经不存在），记录状态
回到「待上传」并重新入队——队列的语义就是「应该进云端的东西」。

删除本身用骑手自己的令牌完成，RLS 仍是边界，不需要 `service_role`。
删除后**自动关闭云同步**：一个删掉云端、又开着同步的状态，下一分钟就会把
刚删的东西传回去，那不是删除，是刷新。

### 跨设备恢复

云端只存骑行摘要和一条 LineString，完整轨迹在 Storage 里是 GPX。
新手机登录后拉下来的是摘要，打开某条记录时才会**按需**下载那条 GPX 并重新导入轨迹点。

没有人在意的一条四小时的骑行，不该在登录时就被下载下来。

---

## 坐标系

内部全部 WGS-84。转换只发生在 `core/map/amap/`：

```text
请求高德前：  WGS-84 → GCJ-02   （否则会吸附到 300 米外的道路上）
解析响应后：  GCJ-02 → WGS-84   （否则轨迹与记录不一致）
```

瓦片源声明自己的基准（`MapTileSource.datum`），绘制时由 `RouteMap` 统一投影。
这样不可能出现「路线是 GCJ-02、瓦片是 WGS-84」这种配置。

GCJ-02 没有解析反函数，所以反向用迭代：猜一个值、正向变换、按残差修正，三轮收敛到厘米级。

---

## 地图服务抽象

```text
MapProvider          （瓦片源 + 基准）
RouteProvider        └── AmapRouteProvider
                     └── OfflineRouteProvider（直线兜底）
PlaceProvider        └── AmapPlaceProvider
                     └── NullPlaceProvider
TrafficLightProvider └── AmapTrafficLightProvider（明确不可用）
NavigationProvider   （偏航重算在 NavigationEngine 内部完成）
```

页面依赖 `MapServices` 这个组合对象，从不直接调用任何厂商 API。
换地图服务是 `providers.dart` 里的一个工厂函数，而不是在表现层里搜索 `AMap.` 调用点。

没有配置 Key 时，`MapServices` 会组装成离线版本：直线路线 + 空搜索 + 不可用的红绿灯。
所有功能仍然可用，UI 会明确标注当前是直线路径。

语音播报走同样的模式：`VoiceCoach` 是纯策略 —— 什么时候说、说什么、什么打断什么 ——
`VoiceBackend` 是接口，`FlutterTtsVoiceBackend` 是唯一碰平台 TTS 的代码。
策略全部在假后端上测试，所以「隧道出来会不会补报过时距离」这种问题
不需要语音引擎就能回答。

---

## OLED 与功耗

- 背景是**纯 `#000000`**，不是 `#111111` —— 后者在 OLED 上耗电一样，但看起来发灰。
- 面与面之间用发丝边框和明度对比区分，而不是抬高的灰色填充。
- Pixel Shift 每 45 秒把整个数据面板偏移 ±2 像素，按八个方位循环（右、下、左、上）。
  偏移量刻意保持在 2 像素：更大的位移在骑行中会被察觉成画面抖动，比烧屏更影响使用。
- 静止 30 秒后降低亮度并隐藏次要数据（规格 §7.3），重新移动时立即恢复 —— 不是定时恢复。
- 屏幕常亮只在记录中启用。

---

## 性能

| 目标 | 做法 |
|---|---|
| 码表 60/120 FPS | 只有 hero 数字用 `FittedBox` 缩放，其余是固定尺寸的 `Text` |
| 1 Hz 更新 | 引擎每秒发布一次 `RideState`；GPS 也是 1 Hz |
| 不重建整棵树 | Widget 通过 Riverpod 的 `select` 订阅具体字段 |
| 实时地图不查库 | `RideRecorder` 在内存里维护轨迹并用 `ValueNotifier<int>` 通知增量 |
| 实时地图不重投影整条线 | `DisplayTrack` 抽稀后缓存投影；剩余路线按顶点切换，每秒只移动当前位置和短连接 |
| 距离计算 O(1) | 锚点机制不需要遍历历史点 |

`RideRecorder.liveTrace` 是原地增长的列表，用计数器通知增量，避免每秒复制坐标。
绘制时不再把这整张表交给地图：`DisplayTrack` 直线上大约每 8 米留一个点，转弯更密，
骑过的部分再压到几百个顶点，最近一段保持骑行分辨率。投影按这条显示折线缓存。
码表每秒刷新时只移动当前位置和它后面那一小段；已经画过的折线不重新投影。
`flutter_map` 在折线图层的配置变化时会丢掉投影缓存，所以地图画布只创建一次，
位置更新不会重建那一层。导航时强调色只画还没骑的路线：切点落在抽稀后的折线上，
长线只在骑过一个顶点时更换，人和下一个顶点之间用两个点补上。镜头跟人走、正北朝上；
拖动或缩放会停下跟随。

---

## 数据库

### 外键与写入顺序

`track_points` 对 `local_rides` 有外键，而 `beforeOpen` 里设置了
`PRAGMA foreign_keys = ON`。这意味着**骑行行必须在第一个轨迹点之前就存在**。

最初不是这样的：骑行行只在结束时写入，于是骑行中每 10 个点一次的批量写入
全部违反外键、全部被 `catch` 吞掉。结果是一次骑行保存了摘要、丢失了完整轨迹 ——
地图、GPX、海拔图全空，而且没有任何地方说明为什么。

现在 `RideRecorder.startRide` 在引擎启动后立刻调用 `RideRepository.beginRide`
写入占位行；结束时的 `saveFinishedRide` 用最终数据 upsert 同一个 id。

代价是：放弃的骑行会留下一行。`discardRide` 用 `purgeAbandonedRide` **硬删除**它
（不是 tombstone —— 云端从没见过这次骑行，给它发一条删除是没有意义的）。

### 本地（Drift + SQLite）

```text
local_rides          骑行摘要
track_points         完整轨迹（一次四小时骑行约 15,000 行）
saved_routes         已保存路线
sync_queue           持久化发件箱
app_settings         键值设置
paired_sensors       已配对传感器
active_ride          崩溃恢复检查点（单行）
```

两个 pragma 在 `beforeOpen` 里设置：

- `journal_mode = WAL`：1 Hz 写入不会阻塞读取，而且写一半进程被杀不会损坏数据库。
- `synchronous = NORMAL`：配合 WAL，操作系统崩溃可能丢最后一个事务，应用崩溃不会。
  FULL 会为了这个 App 不需要的持久性等级消耗真实电量。

索引：`track_points(ride_id, sequence)` 和 `track_points(ride_id, timestamp)`。

### 云端（PostgreSQL + PostGIS）

```text
profiles / rides / routes / bikes / user_settings
```

**轨迹点不逐点上传。** 一次三小时的骑行是 10,000 个点；乘以每个用户、每条记录，
这张表的唯一用途就是变得昂贵。云端保存摘要 + 一条 PostGIS `LineString`，
完整轨迹以 GPX 存在 Storage。

上传走 `push_ride` / `push_route` 这两个 RPC 而不是直接 upsert 表，原因是 PostGIS 的
`geometry` 列：通过 PostgREST 的自动类型转换发送几何在不同版本上行为不一致，
失败时又不明显。RPC 显式调用 `ST_GeomFromGeoJSON`，在任何 Supabase 项目上行为相同。

两个函数都是 `security invoker`，所以 RLS 依然生效 —— RPC 是便利，不是绕过。
`user_id` 永远取自 `auth.uid()`，从不取自请求体：伪造的请求写不进别人的账号。

---

## 设置

用键值表而不是一行宽表：新设置不需要迁移，旧版本读到不认识的键会忽略它。

`AppSettings` 是不可变的，每次修改产出新实例。UI 因此永远不会观察到「改了一半」的设置。

一个细节：`_bool` 解析无法识别的值时**回退到默认值**，而不是回退到 `false`。
后者会让一个损坏的字节把自动暂停关掉，而骑手只会在骑行结束后发现移动时间不对。
