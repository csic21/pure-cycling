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
```

### 为什么时间不能用 tick 计数

```dart
// _tick()
final dt = now.difference(last);   // 墙上时钟差值
_elapsed += dt;
```

iOS 会合并后台 App 的定时器，Android 在低电量下也会。如果时间靠「每 tick 加一秒」累计，
一次被合并的 tick 就永久丢失了那段时间 —— 一趟三小时的骑行可能少记几分钟，而且没有任何提示。

用时钟差值，延迟的 tick 会在下一次触发时把落后的时间一次性补上。

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
`LocationService.ensurePermission` 先拿前台权限，再尝试升级。用户拒绝升级时，
App 继续工作（屏幕亮着），只是会说明后台记录不可用。

### 权限的说明顺序（Play 要求 + 骑手需要）

系统对话框本身不算披露 —— 请求后台定位的应用必须在弹系统框**之前**，
在应用内说清楚用途。第一次点「开始骑行」时的顺序是：

```text
首次开始骑行
  ↓ 应用内说明（为什么需要「始终允许」、数据去哪、不读什么）
  ↓ 用户同意
系统权限对话框
  ↓ 只给了「使用 App 期间」
一次提示：锁屏后记录可能中断，以及怎么改
```

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
  forceLocationManager: false,                // 用 FusedLocationProvider
  useMSLAltitude: true,
  foregroundNotificationConfig: ForegroundNotificationConfig(
    notificationTitle: '正在记录骑行',
    notificationText: '纯粹骑行正在后台记录你的轨迹',
    enableWakeLock: true,
    setOngoing: true,
  ),
)
```

### `distanceFilter: 0` 是必须的

平台默认的基于距离的过滤器会在低速时静默丢弃定位 —— 而那恰恰是自动暂停规则最需要数据的地方。
如果设成 10 米，骑手在停车场里慢速挪动时一个点都收不到。

### FusedLocationProvider

`forceLocationManager: false` 使用 Google Play Services 的融合定位提供者。
在所有装有 Play Services 的 Android 设备上，它的精度和耗电都明显优于原始的 LocationManager。

### `useMSLAltitude: true`

Android 默认返回的是 WGS84 椭球高，在中国会偏高约 30–50 米。
MSL 转换给出的是骑手在地图上能对上的数字。

---

## 三档功耗策略

规格 §32 要求三档：

| 档位 | 精度（Android / iOS） | 间隔（Android） | 用途 |
|---|---|---|---|
| 高精度 | `best` | 1 秒 | 骑行默认 |
| 均衡 | `high` | 2 秒 | 省电与精度折中 |
| 省电 | `medium` | 5 秒 | 长距离骑行、低电量，以及停车时 |

**动态降采样已经实现**（`core/location/sampling_policy.dart`）。规则一句话：
**停着的人不需要每秒定位一次。**

```text
速度 < 2 km/h 持续 30 秒   → 切到省电档（Android 5 秒一次）
速度 > 3 km/h 持续 5 秒    → 立刻切回骑手选的档位
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
- **iOS 没有采样率控制**：`CLLocationManager` 自己决定投递频率，
  给定的精度请求只是提示。所以 iOS 上省电档的收益主要来自更低的精度请求
  （也就是更少的无线电工作时间），而不是更少的定位次数。
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
- [ ] 停车 2 分钟后开始骑：记录应自动恢复（省电档回到所选档位），
      且起步不会丢掉第一段距离
- [ ] 锁屏 2 小时，轨迹连续
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
| 海拔 | 需要 `useMSLAltitude` 转换 | 已经是 MSL |
| 是否伪造位置 | 有 `isMocked` 标志 | 无 |
| 蓝牙服务 UUID | 通常报告短格式 `180D` | 通常报告完整 128 位格式 |
| 后台限制 | 需要前台服务 | 需要 `UIBackgroundModes` |

UUID 格式的差异由 `GattParsers.normalizeUuid` 处理 —— 两侧比较前都归一化。
