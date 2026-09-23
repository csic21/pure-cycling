# 纯粹骑行 — Flutter 应用

这是应用本身。仓库级别的说明、架构决策和已知取舍见 [../README.md](../README.md)。

## 运行

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 生成 Drift 代码
flutter run
```

`lib/**/*.g.dart` 不提交，所以新克隆的副本必须先跑一次 `build_runner`。
改了 `lib/core/database/tables.dart` 之后也要重新生成 —— 改了表结构却没重新生成，
表现是运行时「找不到列」，而不是编译错误。

## 测试

```sh
flutter test                    # 全部
flutter test test/ride_engine_test.dart
flutter analyze
```

## 目录

```text
lib/
├── app/          应用外壳、路由、主题、Provider 图
├── core/         与 UI 无关的基础设施
│   ├── database/ Drift + SQLite（本地唯一真相）
│   ├── location/ GPS 采集、校验、平滑、距离、高度
│   ├── map/      地图服务抽象 + 高德实现 + 坐标转换
│   ├── gpx/      GPX 编解码
│   ├── sync/     Supabase 客户端与同步队列
│   └── utils/    地理计算、单位、格式化、ID
├── features/     ride / dashboard / navigation / routes /
│                 history / sensors / settings / auth
└── shared/       跨功能组件
```

## 阅读顺序

如果要从头理解这个项目，按这个顺序读：

1. `core/location/distance_calculator.dart` —— 为什么距离门限是半径而不是逐点阈值
2. `core/location/elevation_tuning.dart` —— 气压计与纯 GPS 为什么需要两套参数
3. `features/ride/domain/ride_engine.dart` —— 记录管线，以及它为什么没有 I/O
4. `features/ride/domain/elevation_accumulator.dart` —— 两个被测量揪出来的算法 bug
5. `core/map/coord_transform.dart` —— 坐标系转换为什么只在一个地方发生

## 命令速查

```sh
# 只看某一个测试
flutter test test/elevation_noise_probe_test.dart

# 探针会打印实测数字（虚报爬升、真实爬坡保真度）
flutter test test/elevation_noise_probe_test.dart --reporter expanded

# 重新生成数据库代码
dart run build_runner build --delete-conflicting-outputs

# 持续监听代码生成
dart run build_runner watch
```
