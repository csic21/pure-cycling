# 纯粹骑行 App — Product Spec v0.1

> 产品定位：把手机变成一台真正好用的骑行码表与骑行导航器。  
> 不做社区，不做动态，不做关注，不做排行榜，不做点赞。  
> 核心只有四件事：**记录、码表、路线、导航**。

最后更新：2026-09-23

---

## 1. 产品目标

这是一个面向日常骑行、通勤骑行、休闲骑行和长距离骑行用户的纯工具型 App。

核心体验应该是：

```text
打开 App
  ↓
选择：
开始骑行 / 规划路线
  ↓
进入骑行码表
  ↓
骑行中持续记录 GPS + 显示实时数据 + 导航
  ↓
结束骑行
  ↓
本地保存
  ↓
后台同步 Supabase
```

产品应该尽量减少用户在骑行过程中的操作。

### 1.1 产品原则

1. 打开就能骑。
2. 骑行过程中不依赖网络才能完成轨迹记录。
3. 所有核心骑行数据优先写入本地。
4. Supabase 用于云同步、备份和跨设备恢复，不作为实时骑行依赖。
5. OLED 屏幕优先适配。
6. UI 信息密度高，但视觉必须克制。
7. 能一眼看懂，骑行中不需要阅读复杂文字。
8. 不加入任何社交功能。
9. 优先保证 GPS 准确性、稳定性和低功耗。
10. 路线规划优先解决“适合骑车”，而不是简单复制汽车导航。

---

# 2. MVP 范围

## 2.1 V1 必做

- 用户登录
- GPS 骑行记录
- 实时速度
- 平均速度
- 最大速度
- 当前里程
- 骑行时间
- 移动时间
- 自动暂停
- 当前海拔
- 累计爬升
- 地图轨迹
- 骑行历史
- 单次骑行详情
- OLED 码表模式
- Pixel Shift 防烧屏
- 屏幕常亮
- 路线规划
- 骑行导航
- 偏航后重新规划
- GPX 导入
- GPX 导出
- Supabase 云同步
- 本地离线保存
- 自定义码表布局

## 2.2 V1.5

- BLE 心率带
- BLE 踏频器
- BLE 速度传感器
- 红绿灯倒计时（地图服务能力允许时）
- 语音导航
- 导航页面自动切换
- 深色地图
- 路线收藏

## 2.3 V2

- BLE 功率计
- FIT 导出
- 离线地图
- 路线海拔剖面
- 自定义路线偏好
- 少红绿灯路线
- 少机动车路线
- 骑行道优先
- 平路优先
- 爬坡路线
- 骑行热力图
- 自行车管理
- 组件化码表页面
- Apple Watch / Wear OS 扩展

## 2.4 明确不做

```text
❌ 动态
❌ 点赞
❌ 关注
❌ 粉丝
❌ 排行榜
❌ 俱乐部
❌ 社区
❌ 骑行朋友圈
❌ 短视频
❌ 内容推荐流
```

---

# 3. 页面信息架构

```text
App
│
├── 首页 Home
│   ├── 开始骑行
│   ├── 路线规划
│   ├── 本月里程
│   └── 最近一次骑行
│
├── 骑行 Ride
│   ├── 码表页
│   ├── 导航页
│   ├── 地图页
│   └── 暂停页
│
├── 路线 Routes
│   ├── 路线规划
│   ├── 已保存路线
│   ├── GPX 导入
│   └── 路线详情
│
├── 记录 History
│   ├── 骑行列表
│   ├── 月统计
│   └── 骑行详情
│
└── 设置 Settings
    ├── 码表布局
    ├── OLED
    ├── GPS
    ├── 自动暂停
    ├── 单位
    ├── 地图
    ├── BLE 设备
    └── 云同步
```

底部导航推荐：

```text
骑行        路线        记录        设置
●           ◇           ≡           ⚙
```

首页本身就是“骑行”。

返回键只有三种含义：

```text
tab 里的二级页面     返回      上一级
其它 tab 的根部      返回      回到「骑行」
「骑行」根部         返回      退出程序
```

不弹确认框，也不做“再按一次退出”。唯一可能正在记录的地方是骑行页，
而带着记录离开骑行页是不允许的——所以在壳层按返回时不可能丢数据。

---

# 4. 首页

首页不要做信息流。

目标是让用户在 1 秒内找到“开始骑行”。

示意：

```text
┌────────────────────────────┐
│                            │
│          今天骑车？         │
│                            │
│          本月 286 km        │
│                            │
│    ┌──────────────────┐    │
│    │     开始骑行      │    │
│    └──────────────────┘    │
│                            │
│    路线规划      导入 GPX   │
│                            │
│ ────────────────────────── │
│ 最近一次                   │
│ 42.8 km   1:52   22.9 km/h │
│                            │
└────────────────────────────┘
```

点击“开始骑行”：

```text
检查 GPS
↓
获取初始定位
↓
3
2
1
↓
开始
```

如果 GPS 精度差：

```text
GPS 信号较弱
当前精度 ±42m
```

但是不要强制阻止用户开始骑行。

---

# 5. 骑行码表

这是整个产品最重要的页面。

## 5.1 默认码表

```text
┌──────────────────────────────┐
│                              │
│             28.6             │
│             km/h             │
│                              │
│ ──────────────────────────── │
│                              │
│   23.82 km       01:02:36    │
│   距离            骑行时间    │
│                              │
│   22.3 km/h      ↑ 384 m     │
│   平均速度         爬升       │
│                              │
└──────────────────────────────┘
```

设计规则：

- 当前速度最大。
- 速度数字至少占屏幕高度的 20%。
- 骑行过程中尽量不显示复杂按钮。
- 所有按钮尺寸适合戴手套操作。
- 主码表页面不依赖地图。
- 左右滑动切换 Dashboard。

---

# 6. Dashboard 系统

不要写死一套码表。

设计成：

```text
Dashboard
  ├── Page 1
  │     ├── Speed
  │     ├── Distance
  │     ├── Ride Time
  │     └── Avg Speed
  │
  ├── Page 2
  │     ├── Elevation
  │     ├── Elevation Gain
  │     └── Grade
  │
  └── Page 3
        ├── Heart Rate
        ├── Cadence
        └── Power
```

可选字段：

```text
speed
avg_speed
max_speed

distance
trip_distance

elapsed_time
moving_time

altitude
elevation_gain
elevation_loss
grade

heart_rate
avg_heart_rate

cadence
avg_cadence

power
avg_power

gps_accuracy
battery
current_time

distance_to_destination
eta
distance_to_next_turn
```

V1 可以先提供 3 种布局：

```text
1 大 + 2 小

1 大 + 4 小

2 × 3
```

以后再支持完全自由布局。

---

# 7. OLED 模式

OLED 是产品差异化重点。

## 7.1 基础规则

背景：

```text
#000000
```

避免使用：

```text
#111111
#121212
```

主数据优先白色/浅灰。

不必要的图标尽可能隐藏。

---

## 7.2 Pixel Shift

所有长期固定 UI 不允许永久处于完全相同像素位置。

建议定义一个安全区域：

```text
offsetX: -2 ... +2 px
offsetY: -2 ... +2 px
```

每 30~60 秒变化一次。

例如：

```text
0s      (0, 0)
45s     (1, 0)
90s     (1, 1)
135s    (0, 1)
180s    (-1, 1)
225s    (-1, 0)
270s    (-1, -1)
315s    (0, -1)
```

然后循环。

禁止突然跳动过大。

---

## 7.3 静止保护

检测：

```text
speed < 1 km/h
持续 > 30 秒
```

进入 Dim Mode：

```text
亮度降低
+
非必要数据隐藏
+
Pixel Shift 范围扩大
```

重新移动时立即恢复。

---

## 7.4 极简 OLED 模式

```text
┌──────────────────────────────┐
│                              │
│             28.6             │
│                              │
│                              │
│            ↑ 380m            │
│             直行             │
│                              │
│     23.8km          01:02    │
│                              │
└──────────────────────────────┘
```

骑行导航过程中不必持续显示完整地图。

---

# 8. 导航体验

导航提供两个模式：

```text
地图导航
极简导航
```

## 8.1 极简导航

推荐作为默认骑行状态：

```text
┌──────────────────────────────┐
│             27.2             │
│             km/h             │
│                              │
│              ↰               │
│             180m             │
│            左转              │
│          人民大道            │
│                              │
│     剩余 8.2km      27min    │
└──────────────────────────────┘
```

优点：

- 功耗更低
- OLED 更友好
- 阳光下可读性更好
- 用户不用一直看地图

---

## 8.2 自动地图模式

以下情况自动切换地图：

```text
复杂路口
环岛
连续转向
距离转向 < 150m
偏航
用户点击导航区域
```

完成转弯后：

```text
5~10 秒
↓
自动回到码表
```

可设置关闭自动切换。

---

# 9. 路线规划

第一版使用第三方地图服务。

路线规划页面：

```text
当前位置
↓
目的地

[开始规划]
```

高级：

```text
+ 添加途经点
```

结果显示：

```text
路线 A

距离         32.6 km
预计         1h 32m
爬升         280m

──────────── 海拔图

[开始导航]
```

---

# 10. 地图服务策略

中国大陆第一阶段：

```text
高德地图
```

主要能力：

```text
地图显示
定位
POI 搜索
骑行路径规划
导航
偏航重算
```

截至 2026-09，高德 Web 服务“路径规划 2.0”支持骑行路线规划。

注意：

```text
骑行路线规划
≠
拥有完整自行车道底层数据
```

“自行车道优先”“少红绿灯”“少机动车”未来可能需要：

```text
第三方地图数据
+
自有骑行数据
+
路线评分系统
```

V1 不自行构建完整路由引擎。

---

# 11. 红绿灯

红绿灯作为增强能力，不作为 V1 核心依赖。

高德两轮车导航 SDK 已经出现：

```text
电动自行车红绿灯倒计时
巡航红绿灯倒计时
```

但是实际接入前需要再次确认：

```text
平台支持情况
iOS / Android 支持情况
授权方式
商务费用
普通自行车是否可用
数据覆盖城市
```

因此代码设计：

```text
TrafficLightProvider
```

不要和业务页面绑定到高德实现。

例如：

```text
TrafficLightProvider
  ├── AMapTrafficLightProvider
  └── FutureProvider
```

---

# 12. 骑行数据采集

骑行时 GPS 数据进入：

```text
Location
   ↓
RideEngine
   ↓
TrackPoint
   ↓
SQLite
```

TrackPoint：

```text
timestamp
latitude
longitude
altitude
horizontal_accuracy
vertical_accuracy
speed
bearing
```

不要完全信任 GPS 返回的 speed。

RideEngine 可以根据：

```text
GPS speed
+
point distance
+
time delta
+
accuracy
```

共同计算稳定速度。

---

# 13. GPS 数据过滤

需要过滤明显漂移。

示例：

```text
accuracy > 50m
→ 默认不计入里程

瞬时速度 > 100 km/h
→ 标记异常

1 秒内跳跃 500m
→ 丢弃

时间戳倒退
→ 丢弃
```

不要简单使用：

```text
distance(point[n], point[n-1])
```

直接累计。

建议：

```text
raw GPS
 ↓
validation
 ↓
smoothing
 ↓
distance calculator
 ↓
ride stats
```

---

# 14. 自动暂停

默认：

```text
speed < 2 km/h
持续 5 秒
→ pause
```

恢复：

```text
speed > 3 km/h
持续 2 秒
→ resume
```

必须允许用户关闭。

避免 GPS 漂移导致：

```text
红灯停车
→ 里程还在增长
```

---

# 15. 本地优先架构

最关键的架构原则：

```text
Local First
```

骑行过程中：

```text
GPS
 ↓
RideEngine
 ↓
SQLite
```

不是：

```text
GPS
 ↓
Internet
 ↓
Supabase
```

原因：

```text
山区无网络
隧道
弱信号
后台运行
切换网络
服务器故障
```

都不能影响轨迹记录。

---

# 16. 同步架构

```text
                ┌─────────────┐
                │   Sensors   │
                │ GPS / BLE   │
                └──────┬──────┘
                       │
                       ▼
                ┌─────────────┐
                │ Ride Engine │
                └──────┬──────┘
                       │
                       ▼
                ┌─────────────┐
                │   SQLite    │
                │ Local Truth │
                └──────┬──────┘
                       │
                 Sync Queue
                       │
                       ▼
              ┌────────────────┐
              │    Supabase    │
              │                │
              │ Auth           │
              │ PostgreSQL     │
              │ PostGIS        │
              │ Storage        │
              └────────────────┘
```

状态：

```text
local_only
pending_upload
syncing
synced
sync_failed
```

同步失败永远不能导致本地数据丢失。

---

# 17. Supabase 数据设计

建议：

```text
profiles
rides
routes
user_settings
bikes
```

原始 GPX/FIT：

```text
Supabase Storage
```

---

# 18. profiles

```sql
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,

  display_name text,
  avatar_url text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

---

# 19. rides

```sql
create table public.rides (
  id uuid primary key,

  user_id uuid not null references auth.users(id) on delete cascade,

  name text,

  started_at timestamptz not null,
  ended_at timestamptz,

  elapsed_seconds integer not null default 0,
  moving_seconds integer not null default 0,

  distance_meters double precision not null default 0,

  avg_speed_mps double precision,
  max_speed_mps double precision,

  elevation_gain_meters double precision,
  elevation_loss_meters double precision,

  start_lat double precision,
  start_lng double precision,

  end_lat double precision,
  end_lng double precision,

  route_geometry geometry(LineString, 4326),

  gpx_path text,
  fit_path text,

  sync_version bigint not null default 1,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

索引：

```sql
create index rides_user_started_at_idx
on public.rides(user_id, started_at desc);

create index rides_route_geometry_idx
on public.rides
using gist(route_geometry);
```

---

# 20. routes

```sql
create table public.routes (
  id uuid primary key,

  user_id uuid not null references auth.users(id) on delete cascade,

  name text not null,

  distance_meters double precision,
  estimated_seconds integer,

  elevation_gain_meters double precision,

  route_geometry geometry(LineString, 4326),

  provider text,
  provider_route_id text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

---

# 21. bikes

V1 可以不展示，但是表可以提前设计。

```sql
create table public.bikes (
  id uuid primary key,

  user_id uuid not null references auth.users(id) on delete cascade,

  name text not null,

  brand text,
  model text,

  total_distance_meters double precision not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

---

# 22. user_settings

可以使用 JSONB。

```sql
create table public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,

  units text not null default 'metric',

  auto_pause boolean not null default true,

  oled_mode boolean not null default true,

  pixel_shift boolean not null default true,

  dashboard_config jsonb not null default '{}'::jsonb,

  navigation_config jsonb not null default '{}'::jsonb,

  updated_at timestamptz not null default now()
);
```

dashboard_config 示例：

```json
{
  "pages": [
    {
      "layout": "hero_4",
      "fields": [
        "speed",
        "distance",
        "moving_time",
        "avg_speed",
        "elevation_gain"
      ]
    }
  ]
}
```

---

# 23. TrackPoint 不直接全部上传 PostgreSQL

不要默认：

```text
1 GPS point
=
1 PostgreSQL row
```

否则一趟 3 小时骑行可能产生：

```text
10,000+
```

行。

更好的方案：

```text
SQLite:
保存完整 TrackPoint

Supabase Database:
保存骑行统计 + LineString

Supabase Storage:
保存 original.gpx
```

后续如果确实需要服务端逐点分析，再增加：

```text
ride_track_chunks
```

而不是一开始就设计成海量单点行。

---

# 24. GPX 文件

推荐 Storage 路径：

```text
rides/
{user_id}/
  {ride_id}/
    original.gpx
```

后续：

```text
activity.fit
thumbnail.png
```

不要直接修改 Supabase `storage` schema；文件操作通过 Storage API 完成。

---

# 25. Supabase 安全

所有用户数据必须：

```text
RLS ENABLED
```

例如 rides：

```sql
alter table public.rides enable row level security;
```

SELECT：

```sql
create policy "Users can read own rides"
on public.rides
for select
to authenticated
using ((select auth.uid()) = user_id);
```

INSERT：

```sql
create policy "Users can insert own rides"
on public.rides
for insert
to authenticated
with check ((select auth.uid()) = user_id);
```

UPDATE：

```sql
create policy "Users can update own rides"
on public.rides
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);
```

DELETE：

```sql
create policy "Users can delete own rides"
on public.rides
for delete
to authenticated
using ((select auth.uid()) = user_id);
```

2026 年 Supabase Data API 默认行为正在调整：

```text
创建 public table
≠
自动可被客户端访问
```

因此 migration 中明确写：

```sql
grant select, insert, update, delete
on table public.rides
to authenticated;
```

其它公开给 App 的表同样显式 GRANT。

不要在移动端放：

```text
service_role key
```

移动端只使用 Publishable Key / 合适的客户端 key。

---

# 26. 本地数据库

推荐 Flutter：

```text
Drift + SQLite
```

本地表：

```text
local_rides
track_points
saved_routes
sync_queue
app_settings
paired_sensors
```

TrackPoint：

```text
id
ride_id
sequence

timestamp

lat
lng
altitude

speed
bearing

horizontal_accuracy
vertical_accuracy
```

索引：

```text
ride_id + sequence
ride_id + timestamp
```

---

# 27. Sync Queue

```text
sync_queue

id
entity_type
entity_id
operation
retry_count
created_at
last_error
```

例如：

```text
ride
01J...
UPSERT
```

同步流程：

```text
结束骑行
 ↓
SQLite commit
 ↓
生成 GPX
 ↓
生成 LineString
 ↓
加入 SyncQueue
 ↓
网络可用
 ↓
上传 GPX
 ↓
upsert ride
 ↓
sync complete
```

---

# 28. 冲突策略

骑行记录：

```text
Local wins
```

前提是：

```text
local.updated_at > cloud.updated_at
```

用户设置：

```text
Last Write Wins
```

删除采用 tombstone：

```text
deleted_at
```

避免离线设备重新上传已经删除的记录。

V1 可以暂时简单处理：

```text
骑行结束后记录视为基本不可变
只有 name / bike / notes 可以编辑
```

这样同步非常简单。

---

# 29. 推荐技术栈

## App

```text
Flutter
Dart
```

理由：

- 一套代码覆盖 Android / iOS
- 自定义 Canvas/UI 很强
- 数字仪表类界面非常适合
- 动画控制方便
- 性能稳定
- 原生插件生态成熟

---

## Flutter 推荐结构

```text
lib/
│
├── app/
│
├── core/
│   ├── database/
│   ├── location/
│   ├── map/
│   ├── sync/
│   └── utils/
│
├── features/
│   ├── ride/
│   │   ├── domain/
│   │   ├── data/
│   │   └── presentation/
│   │
│   ├── dashboard/
│   ├── routes/
│   ├── navigation/
│   ├── history/
│   ├── sensors/
│   └── settings/
│
└── shared/
```

不要过度 Clean Architecture。

核心目标：

```text
RideEngine
```

与 UI 解耦即可。

---

# 30. RideEngine

核心对象：

```text
RideEngine

start()
pause()
resume()
stop()

onLocation(Location)
onSensorData(SensorData)
```

状态：

```text
idle
preparing
riding
paused
finishing
finished
```

输出：

```text
RideState

currentSpeed
avgSpeed
maxSpeed

distance

elapsedTime
movingTime

altitude
elevationGain

gpsAccuracy
```

UI：

```text
只订阅 RideState
```

不要让 Widget 自己计算距离。

---

# 31. 后台定位

Android：

```text
Foreground Service
+
persistent notification
```

iOS：

```text
CoreLocation
+
Background Location
```

这是 MVP 早期就必须验证的技术点。

不要等 UI 全做完才测试：

```text
锁屏 2 小时
GPS 是否持续记录？
```

---

# 32. 功耗策略

三档：

```text
High Accuracy
Balanced
Battery Saver
```

骑行默认：

```text
High Accuracy
```

但不要无脑 1Hz 请求所有传感器。

可以根据：

```text
速度
屏幕状态
导航状态
GPS 精度
```

动态调整。

例如停车时降低采样频率。

---

# 33. 地图 Provider 抽象

定义：

```text
MapProvider
RouteProvider
NavigationProvider
TrafficLightProvider
```

例如：

```text
RouteProvider
  └── AMapRouteProvider
```

不要让页面直接调用：

```text
AMap.xxx()
```

否则未来替换地图服务非常痛苦。

---

# 34. Domain Models

建议核心模型：

```text
Ride
TrackPoint
RideStats

Route
RoutePoint
RouteInstruction

NavigationState

Dashboard
DashboardPage
DashboardField

Sensor
SensorReading
```

---

# 35. BLE 架构

V1.5：

```text
BLE Manager
│
├── Heart Rate
├── Cycling Speed
├── Cadence
└── Power
```

UI 不关心设备品牌。

统一输出：

```text
SensorReading
```

例如：

```json
{
  "type": "cadence",
  "value": 86,
  "timestamp": 1780000000
}
```

---

# 36. 骑行详情

```text
┌────────────────────────────┐
│ 9 月 23 日 骑行             │
│                            │
│         42.8 km            │
│                            │
│ 1:52       22.9 km/h       │
│ 时间       平均速度         │
│                            │
│ 38.6       ↑ 486m          │
│ 最大速度    爬升            │
│                            │
│ ┌────────────────────────┐ │
│ │        轨迹地图         │ │
│ └────────────────────────┘ │
│                            │
│ ─────── 海拔曲线 ────────  │
│                            │
│ [导出 GPX]                 │
└────────────────────────────┘
```

---

# 37. 历史记录

不要做 Feed。

就是工具列表：

```text
2026 / 09

09/23
42.8 km
1:52
22.9 km/h

09/21
26.4 km
1:08
23.3 km/h
```

顶部：

```text
本月

286 km
12 次
12h 48m
↑ 2,386m
```

---

# 38. 路线详情

```text
周末环湖

56.2 km
预计 2h 31m
↑ 520m

[地图]

[海拔]

起点
人民路
湖滨大道
自行车道
终点

[开始导航]
```

---

# 39. 设置

```text
骑行
  自动暂停
  倒计时开始
  GPS 精度

码表
  页面布局
  数据字段
  字号

OLED
  OLED 模式
  Pixel Shift
  静止自动变暗
  极简模式

导航
  自动显示地图
  语音提示
  偏航重算

单位
  km / mile
  m / ft

设备
  心率
  踏频
  功率计

数据
  云同步
  导出 GPX
```

---

# 40. 第一阶段开发顺序

不要从地图开始。

## Sprint 0 — 项目骨架

- Flutter 初始化
- 路由
- Riverpod
- Drift
- Supabase
- 登录
- Theme
- CI

完成标准：

```text
App 可以运行
登录
SQLite 可读写
Supabase session 正常
```

---

## Sprint 1 — GPS RideEngine

只做：

```text
Start
GPS
Distance
Speed
Timer
Stop
```

没有地图都可以。

完成标准：

```text
骑真实自行车 10km
轨迹不断
里程合理
锁屏不断
恢复 App 数据仍在
```

这是整个项目最重要的 Sprint。

---

## Sprint 2 — 码表 UI

实现：

- 默认 Dashboard
- OLED
- Pixel Shift
- 屏幕常亮
- 暂停
- 自动暂停

完成标准：

```text
骑行过程中不需要打开地图
也能舒服使用 1~2 小时
```

---

## Sprint 3 — 本地历史

实现：

```text
rides
track points
history
ride detail
```

完成：

```text
完全断网
也能记录、结束、查看历史
```

---

## Sprint 4 — Supabase Sync

实现：

```text
Auth
rides
RLS
Storage
GPX
SyncQueue
```

完成：

```text
A 手机骑行
↓
上传
↓
B 手机登录
↓
能看到骑行记录
```

---

## Sprint 5 — 地图

实现：

```text
地图
当前定位
历史轨迹
骑行实时轨迹
```

---

## Sprint 6 — 路线规划

实现：

```text
搜索目的地
路线规划
路线展示
保存路线
```

---

## Sprint 7 — 导航

实现：

```text
turn instruction
distance to turn
rerouting
极简导航
自动地图
```

---

## Sprint 8 — 打磨

重点测试：

```text
GPS 漂移
后台定位
锁屏
发热
耗电
弱网
断网
恢复
闪退恢复
长距离骑行
OLED
```

---

# 41. 第一版验收场景

至少真实骑：

```text
5 km
20 km
50 km
100 km
```

测试：

### GPS

- 城市高楼
- 开阔道路
- 树荫
- 隧道
- 红绿灯停车

### 系统

- 锁屏
- 切后台
- 接电话
- 切 Wi-Fi / 5G
- 无网络
- 低电量

### App

- 强杀进程
- 闪退
- 重启
- 登录过期

---

# 42. Crash Recovery

骑行状态需要持续 checkpoint。

例如：

```text
每 5~10 秒
```

写入：

```text
active_ride
```

如果 App 崩溃：

```text
重新启动
↓
发现 unfinished ride
↓
继续骑行？
```

绝不能因为 App 崩溃直接损失整趟骑行。

---

# 43. 性能目标

建议目标：

```text
码表页面：
60 / 120 FPS 稳定

Dashboard update：
1 Hz 足够

GPS：
约 1 Hz

CPU：
尽量避免持续高占用

内存：
< 250 MB 为目标

骑行：
连续运行 4h+
```

不要因为 GPS 每秒更新就：

```text
整个 Widget Tree rebuild
```

---

# 44. 隐私

位置轨迹属于高度敏感数据。

默认：

```text
所有 rides private
```

不提供公开链接。

Storage Bucket：

```text
private
```

读取走用户授权。

不记录：

```text
通讯录
无关设备信息
广告 ID
```

除非未来明确需要。

---

# 45. 产品护城河方向

第一阶段：

```text
专业码表体验
```

第二阶段：

```text
骑行导航体验
```

第三阶段：

```text
路线质量
```

长期真正有价值的数据不是：

```text
用户发了多少动态
```

而是：

```text
哪些道路大家真的在骑
哪些道路平均速度更稳定
哪些道路停车更少
哪些道路经常偏航
哪些道路适合通勤
哪些道路适合公路车
```

这可以逐渐形成自己的：

```text
Cycling Road Score
```

但必须在用户明确同意匿名数据分析的前提下进行。

---

# 46. 项目核心模块优先级

```text
P0
RideEngine
GPS
SQLite
后台定位
Crash Recovery

P1
Dashboard
OLED
Pixel Shift
Auto Pause
History

P2
Supabase Sync
GPX

P3
Map
Route Planning
Navigation

P4
BLE
Traffic Light
FIT
Offline Map
```

---

# 47. 建议仓库结构

```text
cycling-app/
│
├── app/
│
├── supabase/
│   ├── migrations/
│   └── seed.sql
│
├── docs/
│   ├── product-spec.md
│   ├── architecture.md
│   ├── ride-engine.md
│   ├── gps.md
│   └── map.md
│
├── scripts/
│
└── README.md
```

当前这份文档可以直接保存为：

```text
docs/product-spec.md
```

---

# 48. 第一个开发 Issue

## Issue: Implement minimal RideEngine

目标：

```text
完成一次完全离线的真实骑行记录
```

功能：

- start ride
- receive GPS
- calculate elapsed time
- calculate distance
- calculate current speed
- store TrackPoint
- pause
- resume
- stop
- persist Ride
- restore unfinished Ride

不包括：

```text
地图
Supabase
导航
BLE
```

验收：

```text
1. 开始一次骑行
2. 锁屏
3. 骑行至少 5km
4. 解锁
5. 结束
6. 可以看到里程、时间、平均速度
7. SQLite 中存在完整 TrackPoint
8. 全程关闭网络仍然正常
```

---

# 49. 第一阶段最重要的原则

不要急着做：

```text
漂亮地图
登录动画
统计图
复杂设置
```

第一件真正需要证明的是：

> 手机放到车把上，锁屏、弱网、骑几十公里之后，这个 App 仍然能得到一条可靠的骑行轨迹。

只要这个基础是稳的，后面的码表、导航、云同步都是可逐步叠加的。

---

# 50. 当前技术决策

```text
Client
Flutter

State
Riverpod

Local DB
Drift + SQLite

Backend
Supabase

Cloud DB
PostgreSQL + PostGIS

Cloud File
Supabase Storage

Auth
Supabase Auth

China Map
AMap / 高德

Architecture
Local First

Ride Data
SQLite = source of truth while riding

Cloud
eventual sync
```

---

# 51. 当前外部能力核对

截至 2026-09-23：

- 高德路径规划 2.0 支持骑行路线规划。
- 高德导航 SDK 支持骑行场景的路线规划和导航。
- 高德两轮车 SDK 已增加电动自行车 / 巡航红绿灯倒计时相关能力。
- Supabase 支持 Auth、Postgres、Storage 和 PostGIS。
- Supabase 新项目的 public 表不应再假设会自动暴露给 Data API，应在 migration 中显式处理 Data API grants，并同时启用 RLS。

实现任何地图收费能力、红绿灯能力或生产环境 Supabase 配置前，重新核对官方最新文档与费用。

---

# 52. 一句话产品定义

> **一个没有社区、没有信息流、只专注记录、码表与导航的骑行 App。**

产品首页甚至可以只保留一句：

> **开始骑行。**
