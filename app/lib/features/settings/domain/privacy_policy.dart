/// The privacy policy, as text.
///
/// It lives in Dart rather than in a markdown file on a website because that
/// is the copy the rider can actually read: on a phone, offline, without a
/// browser, in the same language as the rest of the app. A store listing needs
/// a URL as well, and that URL should serve this same text — but the app must
/// not depend on the network being there to explain itself.
///
/// Every claim here is one the code keeps. The list is short on purpose: a
/// policy nobody can verify is decoration. Where a claim is enforced by a test
/// or a verification script, it says so.
class PrivacySection {
  const PrivacySection({required this.heading, required this.body});

  final String heading;

  /// Paragraphs, separated by blank lines in the source.
  final String body;
}

abstract final class PrivacyPolicy {
  static const String lastUpdated = '2026-09-25';

  static const List<PrivacySection> sections = [
    PrivacySection(
      heading: '收集什么',
      body: '位置：只在你按下「开始骑行」之后、到结束之前采集，用于记录轨迹、'
          '速度和导航。不在其它时间读取。\n\n'
          '骑行数据：距离、时间、速度、爬升、轨迹点，以及你连接的蓝牙传感器'
          '（心率、踏频、功率）的读数 —— 前提是你主动配对了设备。\n\n'
          '账号：只有登录或云同步时才有。邮箱、密码（哈希后由 Supabase 保存）、'
          '注册时间、最后登录时间。\n\n'
          '设置：你选择的单位、码表布局、导航偏好等。',
    ),
    PrivacySection(
      heading: '不收集什么',
      body: '不读取通讯录，不获取广告标识，不采集设备指纹，不做行为分析，'
          '不接入任何第三方统计或崩溃上报 SDK。\n\n'
          '没有社区、没有信息流、没有排行榜，因此也没有任何「公开」的东西：'
          '每一趟骑行默认只有你自己能看。',
    ),
    PrivacySection(
      heading: '数据存在哪里',
      body: '本机：骑行记录、轨迹点、路线和设置存在手机上的 SQLite 数据库里。'
          '不登录、不联网也能完整使用。\n\n'
          '云端（可选）：只有你打开「云同步」之后，骑行摘要、完整轨迹（GPX 文件）、'
          '路线和设置才会上传到你的账号下。存储桶是私有的，数据库行级权限'
          '（RLS）只允许本人读写 —— 这一点由仓库里的验证脚本在真实的 '
          'PostgREST / GoTrue 上断言，包括「另一个账号读不到、也下不到」。',
    ),
    PrivacySection(
      heading: '谁能看到',
      body: '只有你。没有公开链接，没有分享流。\n\n'
          '运营方的管理后台只能看到账号元数据：邮箱、注册时间、最后登录时间、'
          '骑行条数。它**看不到**轨迹、GPX 文件或任何位置数据 —— 这是产品承诺，'
          '仓库里的迁移验证脚本会断言后台读不到 rides 表。'
          '封禁或删除账号这类动作会留下审计记录。',
    ),
    PrivacySection(
      heading: '地图瓦片缓存',
      body: '看过的地图区域会缓存在本机（最多 1 GB），这样断网或隧道里，'
          '已经看过的路段仍然能显示。这份缓存按你看过的位置记录，'
          '因此本身是一条位置线索：它只在本机，不会上传，'
          '可以随时在「设置 → 地图 → 离线瓦片」里清空。',
    ),
    PrivacySection(
      heading: '第三方地图',
      body: '路线规划和地图瓦片来自第三方地图服务（高德，境外为 '
          'OpenStreetMap / CARTO）。请求会包含坐标 —— 这是任何在线地图的固有行为。'
          '不配置地图服务时，App 完全离线可用，只有路线规划退化为直线。\n\n'
          '路线高程默认关闭。开启后，规划路线的坐标会发送给公开高程服务 '
          'OpenTopoData（SRTM 30m）用于计算爬升与海拔剖面 ——'
          '这是本 App 唯一一处会把坐标发给非地图供应商的地方，因此由你决定，'
          '也随时可以关掉。',
    ),
    PrivacySection(
      heading: '诊断日志',
      body: '应用出错时会在本机写一份日志：只有异常信息和调用栈，没有位置轨迹，'
          '不会自动上传。你可以在「设置 → 诊断日志」里查看大小、导出或清空。',
    ),
    PrivacySection(
      heading: '保留与删除',
      body: '数据一直保留到你删除它为止：\n\n'
          '• 单条骑行：在骑行详情里删除（云端副本会一并删除）\n'
          '• 云端全部数据：「设置 → 云同步 → 删除云端数据」，'
          '本机记录保留并停止上传\n'
          '• 账号：「设置 → 云同步 → 删除账号」，永久删除账号与云端全部数据\n'
          '• 本机数据：卸载 App 即删除；本机没有其它副本',
    ),
    PrivacySection(
      heading: '儿童与敏感数据',
      body: '这款应用不面向儿童设计。位置轨迹属于高度敏感的数据，'
          '这也是它默认私有、不提供任何公开分享入口的原因。',
    ),
    PrivacySection(
      heading: '变更',
      body: '政策更新时会修改本页顶部的日期，并在版本说明里写明改了什么。',
    ),
  ];
}
