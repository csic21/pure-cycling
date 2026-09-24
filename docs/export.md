# 导出：GPX 与 FIT

两种格式，两种用途：

| 格式 | 给谁 | 内容 |
|---|---|---|
| GPX | 一切工具（轨迹查看器、路线规划、我们自己重新导入） | 轨迹点 + 海拔 + 心率/踏频扩展 |
| FIT | Garmin Connect / Strava / 码表 | 轨迹 + 传感器 + 摘要（lap / session / activity） |

两者都是**从数据库里的轨迹按需重新生成**的，不是骑行结束时必须落盘的产物。
一次 GPX 写失败的骑行仍然是一次骑行，文件随时可以从轨迹重建。

---

## FIT：手写编码器 + 独立解析器验证

代码在 `app/lib/core/fit/fit_codec.dart`。不引入运行时依赖，原因和 GPX 一样：
格式是一段固定的消息序列，而导出发生在骑手站在车边等着分享的时候。

验证链：

- 字段号、类型、scale 取自 `fit_tool` 的生成 profile（FIT profile 21.60），
  并与 FIT SDK 自带的 `Activity.fit` 逐条比对过消息顺序
- `test/fit_codec_test.dart` 用 `fit_tool`（dev 依赖，Stages Cycling 的独立实现）
  **解码我们写出的字节**：文件 CRC、字段语义、semicircle 往返、缩放字段、
  无效值、无传感器 / 空轨迹的边界
- 测试里没有任何一处用编码器自己的 helper 读回数据 —— 那样写的话，
  字段号写错也会全绿

---

## 文件里有什么

```text
file_id     activity, manufacturer = development (255)
event       timer / start
record *    每个有效定位点
event       timer / stop_all
lap         一个 lap 覆盖整趟
session     汇总与平均，sport = cycling
activity    一个 session，本地时间
```

消息顺序与 Garmin 设备写出来的一致 —— 解析器就是按这个预期写的。

---

## 三个容易写错的地方

**位置是 semicircle，不是度。** `度 * 2^31 / 180`，有符号 32 位整数。
写成度会得到一个解析正常、但把人放到另一个半球的文件。

**record 的定义消息对整个文件生效。** 定义消息声明了之后每个数据消息带哪些
字段，所以「只有部分点有心率」的骑行仍然要声明心率字段，没有的点写无效标记。
字段集合在遍历轨迹之前一次性决定，而不是逐点决定。

**无效值不是 0。** 海拔的 0 表示 -500 米；「没有读数」是 `0xFFFF`。
把缺海拔写成 0，等于让文件声称骑手在海平面以下 500 米。

---

## 取舍

- **FIT 不上传。** Storage 里只放 GPX（`original.gpx`）；`fit_path` 这一列
  留给以后。导出是本地行为：写进应用文档目录，然后走系统分享。
- **摘要用 App 显示的数字，轨迹里的累计距离用轨迹自己算。** 前者是骑手在
  屏幕上看到的，后者保证 record 流内部自洽；两者差异在米级。
- **平均心率/踏频/功率优先用引擎统计，缺失时回退到轨迹平均** ——
  从 GPX 恢复的骑行没有引擎统计，但有点。
- **最大心率/踏频/功率只有轨迹里有**，`RideStats` 不存最大值。
- **不上传名字。** FIT 活动文件本身不带活动名；名字在 Strava/Garmin 那边
  由用户或服务决定。
- **设备标识用 development (255)。** 这不是一台 Garmin 设备，
  声称一个不属于自己的厂商 ID 是会在服务端产生后果的谎言。

---

## GPX

`core/gpx/gpx_codec.dart`，手写而不是走 DOM builder：一次四小时骑行约
15,000 个点，导出时字符串拼接比构建九万个 XML 节点快一个数量级，
而且只有骑手填的名字和备注需要转义。

轨迹点写出 `<speed>`，所以重新导入能往返；心率/踏频走 Garmin 的
`TrackPointExtension`。摘要写在 `<extensions>` 里（不是 GPX 1.1 的一部分，
但被广泛读取），方便只看摘要的工具。

手动构造一个测试文件见 [README 的对应一节](../README.md#手动构造一个-gpx-测试文件)。
