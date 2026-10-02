# GPS 采集与平台配置

`RideEngine` 处理的是已经拿到的定位。这份文档讲定位怎么拿到，以及为什么平台配置
不是可选项。

实现细节见 [ride-engine.md](ride-engine.md)。

---

## 锁屏继续记录

**需求：锁屏时继续记录。只有两个动作会结束一次骑行 —— 骑手按「结束」，或者进程被杀掉。**

### 三层保障

```text
第一层  平台保活        锁屏后进程不被挂起，定位继续到达
        ├── Android     location 类型的前台服务 + 常驻通知
        └── iOS         UIBackgroundModes: location

第二层  引擎不依赖前台   没有任何代码在 AppState 变化时停止引擎
        ├── 生命周期的所有分支都只写检查点，不改变状态机
        └── 时间从墙上时钟差值推算，不靠数 tick
        └── 定时器被系统合并/延迟也不会丢时间

第三层  进程真的被杀     5 秒检查点把损失限制在秒级
        ├── inactive / hidden / paused / detached 都写一次检查点
        └── 下次启动发现未完成的骑行，弹出恢复面板

第四层  不去动保活        后台绝不重建定位订阅
        ├── 采样档位切换推迟到回到前台（`RideRecorder.setForeground`）
        └── 断流看门狗只在前台重建，后台只记录
```

第四层是后加的，因为它补的是一个**自己把自己弄死**的路径：前三层都假设保活一旦建立
就稳定，而实际上有一处代码会主动拆掉它。见下一节。

### 为什么时间不能用 tick 计数

```dart
// _tick()
final dt = now.difference(last);   // 墙上时钟差值
_elapsed += dt;
```

iOS 会合并后台 App 的定时器，Android 在低电量下也会。如果时间靠「每 tick 加一秒」累计，
一次被合并的 tick 就永久丢失了那段时间 —— 一趟三小时的骑行可能少记几分钟，而且没有任何提示。

用时钟差值，延迟的 tick 会在下一次触发时把这次落后的时间一次性补上。

### 为什么后台不重新订阅

**采样档位属于订阅本身**（Android 的 `intervalDuration`、`accuracy` 都是订阅参数），
所以停车降采样只能靠取消再重新订阅来实现。这件事在**前台**是廉价的，
在**后台**却会毁掉整次记录。

取消最后一个监听不是一个局部操作。geolocator 在 Android 上的链条是：

```text
Dart 取消最后一个监听
  → 平台 onCancel
  → canStopLocationService(cancellationRequested: true) 返回 listenerCount == 1 → true
  → disableBackgroundMode()
  → stopForeground(STOP_FOREGROUND_REMOVE) + releaseWakeLocks()
     常驻通知消失、PARTIAL_WAKE_LOCK 释放、服务退出前台
重新订阅
  → enableBackgroundMode() → startForeground()
```

最后一步是**在后台启动前台服务**。Android 12+ 禁止这件事，而且
`stopForeground()` 会把「允许启动前台服务」的状态重置，所以紧接着的
`startForeground()` 会**重新检查进程状态**并抛
`ForegroundServiceStartNotAllowedException`。Android 14+ 更进一步：
需要 while-in-use 权限（定位）的服务根本不能在后台创建。

于是发生的事情是：**骑手锁屏后在红绿灯前停了 30 秒**（或停完再起步），档位切换触发重新订阅，
前台服务再也回不到前台。而失败是**上一层的事，不在流里**：Android 的 `EventChannel` 捕获这个
异常并回一个 error envelope，Dart 的 `receiveBroadcastStream` 把它交给
`FlutterError.reportError` —— **不会调用 `controller.addError`**。所以：

- 诊断日志里**有**记录（`installErrorHandlers` 挂的 `[flutter]` 条目），logcat 里有
  `Failed to open event stream`；
- 但那条 Dart 流**从来没有收到过错误、也没有关闭**：`onError` 不会触发，
  `cancelOnError: false` 让订阅继续活着。骑行从此一个点都不记，码表上的数字却还在往前走。

所以规则是：**后台不动订阅**。

- `RideRecorder.setForeground` 由 `app.dart` 的生命周期回调驱动。回到前台时按
  `SamplingPolicy.effective` 对账补上。代价说清楚：锁屏期间的省电收益让位给正确性，
  这是有意的取舍。
- 断流看门狗（`_checkStreamHealth`）同样只在前台重建订阅 —— 后台重建正是会失败的那件事，
  而且失败后 geolocator 的 `listenerCount` 已经被加过，会让它自己的停止条件
  （`listenerCount == 1`）此后永远不成立。后台观察到断流只写一条诊断日志，
  解锁后由 `setForeground(true)` 立刻自愈。

看门狗存在的理由，就是上面那段：**这个失败在 Dart 侧完全不可见**。`onError` 不是检测手段，
因为根本没东西发给它；`cancelOnError` 也无从谈起。唯一能发现「流已经死了」的，是
「它多久没给我东西」这个外部观察。

规则：断流 60 秒（前台）重建一次；**第一次没救回来就把等待翻倍**（上限 5 分钟），
收到任何一个定位立刻回到 60 秒。

退避是必要的，因为「流死了」和「天上被挡住」在信号上完全一样：隧道里每 60 秒重建一次，
等于每 60 秒扔掉一条**还活着**的订阅、让接收机重新搜星、让常驻通知闪一下。
翻倍之后，三分钟的隧道从三次重建变成一次。

注意 `AppLifecycleState` 在这里是**正确**的信号：Android 的限制看的是**进程**前后台状态，
而不是屏幕亮灭，两者正是同一件事。

**冻结的是哪一档，要说准**：是**锁屏那一刻生效的请求**，不是骑手选的那一档。
边骑边锁屏 → 冻结在所选精度和间隔；锁屏前刚停过 30 秒 → 冻结在所选精度、5 秒一次。
精度不降到 `medium`：那一档会让系统把卫星芯片休眠，下一个点要等很久，
红灯处信号图标就会变红。距离和爬升不受影响（距离计算器的锚点设计让延迟的点照常入账），
付出的是轨迹分辨率，以及自动恢复最多晚 5 秒，停车时也比「休眠精度」更费电。
这是一个可以接受的取舍，但不能说成「没有影响」。

### 什么会结束一次骑行

| 操作 | 行为 |
|---|---|
| 锁屏 | **继续记录** |
| 切到后台 | **继续记录** |
| 接电话 | **继续记录** |
| 勿扰模式 | **继续记录** |
| 骑手按「结束」 | 结束并保存 |
| 进程被杀 / 强杀 App / 手机重启 | 记录中断，**下次启动时提供恢复** |

最后一行是一个有意的设计选择：强杀之后不静默丢弃，而是先展示已记录的数字
（「我的数据还在吗」是骑手最想知道的），再让骑手选择「继续这次骑行」或「结束并保存」。
结束只需要一次点击，而静默丢弃一趟四小时的骑行是无法挽回的。

### 已经用测试锁定

`app/test/ride_engine_test.dart` 的 `a locked screen must not interrupt the ride` 分组：

- **进程被挂起时不丢时间** —— 墙上时钟前进 30 分钟而定时器队列完全不动，
  下一个 tick 触发后 `elapsed` 包含完整的 30 分钟，状态仍然是 `riding`。
- **挂起期间检查点存在且完整** —— 恢复所需的一切（距离、序号、距离计算器的锚点）都在。
- **长时间挂起不破坏距离** —— 15 分钟没有回调后，那段 4.5 公里的间隔被正确桥接，
  而且只计一次。

测试能证明的是**逻辑层**。另一半是平台配置，只能真机验证 —— 见下方清单。

---

## 仅手机端精度改进（2026-10）

不依赖外接轮速 / 自行车 GPS。主路径仍是 Android `GPS_PROVIDER` + iOS CoreLocation；
**不**改回 Fused、不设 `distanceFilter > 0`、停车不降精度档、锁屏不重订订阅。

| 项 | 行为 |
|---|---|
| GNSS 预热 | `prepareRideLocation` 成功后 `LocationService.prewarm`（前台、无 FGS）；骑行订阅建立或取消时 `stopPrewarm` |
| 放置提示 | 倒计时与骑行设置 GPS 脚注：车把支架 / 避开金属磁吸 / 开阔天空 |
| 卫星质量 | Android `GnssStatus` → `satellites_used` / `cn0_avg`；码表与倒计时展示；iOS 字段为空则只显示精度 |
| 城市多径 soft gate | `DistanceCalculator`：航向与位移差 ≥75° 且精度突升时**不移锚、不记距**（仍刷新 UI） |
| 导航位置 snap | 有规划路线且未偏航时，地图箭头/跟随用 `snappedPoint`；**轨迹与里程仍用原 GPS** |
| 自由骑零速兜底 | 无路线时加强 `_zeroSpeedMovementConfirmed`（更紧确认半径 + 路径一致性逃逸） |

---

## 权限矩阵

| 平台 | 前台定位 | 后台定位 | 蓝牙 | 通知 |
|---|---|---|---|---|
| Android | `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` | `ACCESS_BACKGROUND_LOCATION` | `BLUETOOTH_SCAN` (neverForLocation) + `BLUETOOTH_CONNECT` | `POST_NOTIFICATIONS` |
| iOS | `NSLocationWhenInUseUsageDescription` | `NSLocationAlwaysAndWhenInUseUsageDescription` + `UIBackgroundModes: location` | `NSBluetoothAlwaysUsageDescription` | — |
| macOS | `personal-information.location` entitlement | 同左 | `device.bluetooth` entitlement | — |

### Android 的关键点

**`FOREGROUND_SERVICE_LOCATION`** —— Android 会杀掉没有前台服务的后台应用。
没有这个权限，骑行在骑手把手机放进口袋的那一刻就结束了，而那正是唯一的用例。

**`neverForLocation`** —— 蓝牙扫描权限声明这个 App 扫描心率带和功率计，不是扫描位置。
否则会拿到比实际需要更宽的位置权限，那是一个不必要的谎。

**精确定位和粗略定位一起申请** —— Android 12+ 允许用户只授予粗略档位。
一次 ±2 公里的骑行记录没有意义，所以 App 必须能检测到这种状态并解释，
而不是默默记录一条无用轨迹。

**后台定位无法和前台权限在同一个对话框里申请** —— Android 11+ 要求分两步。
点击「开始骑行」或「开始导航并记录」后先申请前台权限。取得前台权限后，
应用说明锁屏记录的用途，由骑手选择是否申请「始终允许」。拒绝升级时仍可
在前台记录。iOS 的第二步使用系统的 Always 权限请求。

### 权限的说明顺序（Play 要求 + 骑手需要）

系统对话框本身不算披露 —— 请求后台定位的应用必须在弹系统框**之前**，
在应用内说清楚用途。第一次点「开始骑行」时的顺序是：

```text
首次开始骑行
  ↓ 应用内说明（为什么需要「始终允许」、数据去哪、不读什么）
  ↓ 用户同意
系统权限对话框
  ↓ 只给了「使用 App 期间」
一次提示：锁屏后记录可能中断，可选择申请「始终允许」或暂时继续
```

路线规划打开时不会弹权限框；点击「更新当前位置」时才申请前台定位。

- 两个提示各只出现一次，标记存在设置 KV 表里（**不同步**：授权属于这台手机，
  把「已看过」同步到另一台设备会跳过那台设备从未见过的披露）
- 「只给了使用期间」这件事必须说出来。否则结果是一条工作正常的 App，
  在骑手把手机放进口袋时停止记录 —— 而骑手是骑完才发现的
- 设置 → 骑行 → GPS 里的「锁屏继续记录」随时能看到当前状态并跳到系统设置

### 通知权限（Android 13+）

前台服务的常驻通知在 Android 13+ 上默认不显示，需要 `POST_NOTIFICATIONS`
运行时授权。它比一般通知重要：锁屏之后，那条「正在记录骑行」是骑手确认
记录还在继续的**唯一**方式。

顺序和定位一致：应用内先说明（`showNotificationNotice`）→ 系统对话框
（`NotificationPermission`，只问一次，标记同样在 KV 表里）→ 设置 → 骑行 → GPS
里的「记录通知」显示当前状态并跳系统设置。拒绝不影响记录，只是看不到那条状态。

### iOS 的关键点

**`pauseLocationUpdatesAutomatically: false`** —— iOS 会在它认为用户停止移动时
暂停定位更新。对骑行码表来说这个启发式是有害的：一个没有位移的长下坡会让骑行静默结束。

**`activityType: otherNavigation`** —— 告诉 CoreLocation 这是导航场景，
它据此调整采样策略。

**`showBackgroundLocationIndicator: true`** —— 显示系统级的后台定位指示条。
这是用户知情权的一部分，也是一个诚实的设计选择：不隐藏 App 在后台用定位这件事。

**`UIBackgroundModes: location`** —— 没有它，锁屏即停止记录。
这是这个项目里最不能省略的一个键。

### macOS 的关键点

macOS 是开发预览目标，不是交付目标（产品是手机 App）。但为了能跑起来：

- `com.apple.security.network.client` —— 没有它，沙盒里连不出任何网络请求
  （Supabase、高德、地图瓦片全部失效）。
- `com.apple.security.files.user-selected.read-only` —— GPX 导入用。

---

## 采样配置

```dart
AndroidSettings(
  accuracy: LocationAccuracy.best,
  distanceFilter: 0,                          // 关键
  intervalDuration: Duration(seconds: 1),
  forceLocationManager: true,                 // 不依赖 Google Play 服务
  useMSLAltitude: true,
  foregroundNotificationConfig: ForegroundNotificationConfig(
    notificationTitle: '正在记录骑行',
    notificationText: '纯粹骑行正在后台记录你的轨迹',
    enableWakeLock: true,
    setOngoing: true,
  ),
)
```

高精度和均衡档在这条流旁边再直接向 `LocationManager.GPS_PROVIDER` 要卫星点
（`app.purecycling/gnss`，约 1 Hz，每个历元都交上来）。多普勒时速来自
`Location.getSpeed()`。geolocator 这条流保持订阅：它的前台服务让灭屏之后卫星点
仍然合法，卫星流报错或安静超过 3 秒时改由它供数。两路同时到达时只采纳卫星点，
避免距离被记两次。省电档不打开卫星通道。海拔优先用 NMEA GGA 的海拔（5 秒内），
其次是 API 34 的海平面高度，避免卫星流接手时爬升突然跳几十米。

iOS 高精度使用 `LocationAccuracy.bestForNavigation`，并保持
`pauseLocationUpdatesAutomatically: false` 与 `activityType: otherNavigation`。

导航进行中，沿路线投影的距离差除以时间差用来补上停在 0 的多普勒速度。
偏航、间隔短于 0.4 秒或长于 12 秒、结果低于 1.5 m/s（投影爬行）或已有
不低于 0.5 m/s 的多普勒速度时，这个补速不进码表。轮速传感器仍然优先。

### `distanceFilter: 0` 是必须的

平台默认的基于距离的过滤器会在低速时静默丢弃定位 —— 而那恰恰是自动暂停规则最需要数据的地方。
如果设成 10 米，骑手在停车场里慢速挪动时一个点都收不到。

### `useMSLAltitude: true`

Android 默认返回的是 WGS84 椭球高，在中国会偏高约 30–50 米。
MSL 转换给出的是骑手在地图上能对上的数字。

---

## 三档功耗策略

规格 §32 要求三档：

| 档位 | 精度（Android / iOS） | 间隔（Android） | 用途 |
|---|---|---|---|
| 高精度 | `best` / `bestForNavigation` | 1 秒 | 骑行默认。Android 另要 GPS_PROVIDER |
| 均衡 | `high` | 2 秒 | 省电与精度折中。Android 同样走 GPS_PROVIDER |
| 省电 | `medium` | 5 秒 | 长距离骑行、低电量。骑手自己选的，停车不会自动降到这一档 |

**动态降采样已经实现**（`core/location/sampling_policy.dart`）。规则一句话：
**停着的人不需要每秒定位一次，但卫星芯片不能为此休眠。**

```text
速度 < 2 km/h 持续 30 秒   → 间隔拉长到 5 秒，精度保持骑手选的那一档
速度 > 3 km/h 持续 5 秒    → 立刻恢复所选间隔
任何切换之后 60 秒内不再切换
```

三个设计选择：

- **降级慢、恢复快**：错过爬坡的头 30 秒是真实损失，晚一点发现停车不是。
- **切换有静默期**：切档就是重新订阅平台流（采样率属于订阅本身），
  城市里每个红绿灯都切一次是纯浪费。
- **永远不会比骑手选的档位更费电**：选了省电的人不会因为「在移动」被悄悄升级。

注意事项：

- 停车降采样会**延迟自动恢复**：恢复判定需要当前速度，5 秒一次意味着
  恢复最多晚 5 秒。这也是为什么升级只用 5 秒的判定窗口。
- **切档在后台不发生**：锁屏期间请求冻结在**锁屏那一刻生效的精度和间隔**，回到前台才补上
  （原因见上一节）。所以「停车后把间隔拉长到 5 秒」这条只在前台成立。
- **加速度计能把这个判断做得更准**：它确认车停着时，降采样从 30 秒缩短到 10 秒。
  低速段的速度是接收机最不可靠的输出，而「完全没在抖」是强得多的证据。
  见 [phone-sensors.md](phone-sensors.md)。
- **iOS 没有采样率控制**：`CLLocationManager` 自己决定投递频率，
  给定的精度请求只是提示。所以骑手选了省电档时，iOS 上的收益主要来自更低的精度请求
  （也就是更少的无线电工作时间），而不是更少的定位次数。停车不会自动降到这一档。
- 屏幕状态在 Flutter 里拿不到可靠事件（`AppLifecycleState` 不是屏幕状态），
  所以策略只看速度 —— 需要额外平台通道才能把屏幕状态也算进去。

---

## 后台定位验证清单

规格 §31 明确要求「锁屏 2 小时，GPS 是否持续记录」必须在 MVP 早期验证，
而不是等 UI 全做完。

**这一条是当前实现里最需要真机确认的部分。** 逻辑层已经用测试锁定，
但「锁屏 2 小时后轨迹是否完整」只能在真机上回答 —— 模拟器和桌面环境都无法复现
系统的后台调度行为。

以下是在真机上必须逐项确认的：

### Android

- [ ] 有气压计与没有气压计的机型各骑一次：有气压计的爬升不应标「估算」，
      没有的一侧行为不变
- [ ] 气压计机型：骑一次已知爬升（例如一座桥或一段已知坡），
      与地图上的真实高差对比，确认没有把天气漂移当成爬坡
- [ ] 停车 2 分钟后开始骑：记录应自动恢复（5 秒间隔回到所选间隔，精度始终没降过），
      且起步不会丢掉第一段距离
- [ ] **锁屏 → 停车 2 分钟 → 起步**：前台服务通知全程不消失，轨迹连续
      （这条专门盯第四层：档位切换绝不能在后台发生）
- [ ] 锁屏 2 小时，轨迹连续，结束后诊断日志里**没有** `location_stream_rebuilt`
      （安静即正确；有记录说明看门狗在兜别的故障）
- [ ] 切到后台（Home 键），轨迹连续
- [ ] 前台服务通知可见且常驻
- [ ] 用户拒绝通知权限时，记录仍然继续
- [ ] 首次开始骑行时先看到应用内说明，再弹系统权限框（Android 11+ 的「始终允许」路径）
- [ ] 电池优化白名单未加入时，记录能持续多久
- [ ] 厂商省电模式（小米/华为/OPPO）下的表现
- [ ] 接听电话时轨迹不中断
- [ ] 强杀 App 后重启，能恢复未完成的骑行
- [ ] 飞行模式 → 正常模式的切换不影响记录

### iOS

- [ ] 锁屏 2 小时，轨迹连续
- [ ] 后台定位指示条可见
- [ ] 勿扰模式下记录继续
- [ ] 接听电话时轨迹不中断
- [ ] 强杀 App 后重启，能恢复未完成的骑行

### 两者共同

- [ ] 隧道进出：出来后轨迹正确连接（长间隔 + 合理速度）
- [ ] 隧道内：信号丢失提示出现，时钟继续走
- [ ] 城市高楼：偏航误判不频繁
- [ ] 树荫：精度变差但不影响里程
- [ ] 红绿灯停车 60 秒：里程不增长，自动暂停按预期触发
- [ ] 低电量模式下的表现和提示

---

## 功耗预估

没有实测数据。规格 §43 给出的目标：

```text
连续运行 4h+
内存 < 250 MB
```

主要的耗电来源，按影响排序：

1. **屏幕常亮** —— 通常是最大的一项。OLED 纯黑背景和 Pixel Shift 已经优化了这部分，
   但一块常亮的屏幕仍然消耗可观电量。
2. **GPS 高精度 1 Hz** —— 第二项。
3. **地图瓦片下载** —— 只在导航且地图可见时发生。极简导航作为默认模式正是为了避免它。
4. **BLE 传感器** —— 心率带和功率计的广播接收，相对较小。

如果实测超过预期，第一个可调的旋钮是导航时的地图自动切换频率
（`NavigationConfig.autoMapDismissSeconds` 和 `approachingTurnMeters`）。

---

## 已知的平台差异

| 行为 | Android | iOS |
|---|---|---|
| 定位时间戳 | 可能是定位产生的时间，也可能是接收时间 | 通常是接收时间 |
| 开流时会不会先给一个缓存定位 | 会给 | **会给**，且可能已经过去几分钟 |
| 海拔 | 需要 `useMSLAltitude` 转换 | 已经是 MSL |
| 是否伪造位置 | 有 `isMocked` 标志 | 无 |
| 蓝牙服务 UUID | 通常报告短格式 `180D` | 通常报告完整 128 位格式 |
| 后台限制 | 需要前台服务 | 需要 `UIBackgroundModes` |

UUID 格式的差异由 `GattParsers.normalizeUuid` 处理 —— 两侧比较前都归一化。

### 「信号丢了」看的是到达时间，不是定位时间戳

引擎里因此有**两个**时钟，用途不同：

| 时钟 | 谁在用 | 回答的问题 |
|---|---|---|
| 平台给的时间戳（`_lastFixAt`） | 距离计算器的锚点时间、两次定位的间隔、长间隔桥接 | 位置在时间上怎么连起来 |
| 定位**到达**的时间（`_lastFixArrivedAt`） | GPS 指示图标、速度衰减 | 还有没有在收到更新 |

正常情况两者一致，不一致时**说谎的是平台的时间戳**：

- iOS 在流一打开就会把**缓存定位**交出来（`didUpdateLocations` 里只对一次性定位做了 5 秒的过期过滤，
  持续流没有），所以后台待过一阵之后重新订阅，收到的第一个定位可能盖着几分钟前的时间戳。
  按时间戳判断，这与「接收机彻底沉默了」无法区分 —— 于是**刚重新开始监听，GPS 图标就变红了**。
- 接收机会重放定位；部分 ROM 报告的 GNSS 时间与系统时钟并不一致。
  这两件事都说明不了「还有没有在收到更新」。

骑手看到红灯时问的问题是「App 还听得到定位吗」，所以那个判据必须用到达时间。
`ride_engine_test.dart` 的 `a fix the receiver stamped long ago is not silence`
和 `reports signal lost when fixes stop` 一起锁住这条：前者防止误报，后者防止漏报。
