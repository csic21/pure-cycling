# 登录与云同步

---

## 默认状态：不登录

App 完整可用。记录、码表、历史、GPX 导入导出全部在本地完成，
**没有一个功能需要登录**（规格 §15）。

登录只做一件事：把骑行备份到云端，让换手机之后能找回来。
所以每个 auth API 的降级路径都是「不可用」而不是「失败」——
一个没配 Supabase 的构建连 SDK 都不会碰。

---

## 做完了什么

| 能力 | 状态 |
|---|---|
| 邮箱 + 密码注册 / 登录 | ✅ |
| 邮箱验证 | ✅ 注册后发确认邮件，链接回到 App |
| 忘记密码 | ✅ 重置链接回到 App |
| 匿名登录 | ✅ 拿到真实的 `auth.users` 行，骑行照常同步 |
| 匿名账号绑定邮箱 | ✅ 账号 id 不变，已同步的骑行不受影响 |
| 退出登录 | ✅ 不删除任何本地记录 |
| 会话持久化 | ✅ SDK 默认存储在本地 |
| 会话自动刷新 | ✅ `autoRefreshToken: true` |
| `profiles` 行 | ✅ 数据库触发器 + 客户端兜底 |
| 错误翻译成中文 | ✅ 见下 |

**没做**：第三方登录（Google / Apple / 微信）。规格里没有要求，
而且 App Store 上架时如果要提供第三方登录，Apple 会要求同时提供 Sign in with Apple ——
那是另一个决定。

---

## 深链：整件事里最容易漏的一环

Supabase 发出的每一封邮件（验证、重置密码、改邮箱）都以一个链接结尾。

**没有自己的 URL scheme，App 就不可能是那个链接的目的地。** 骑手点了链接、
在浏览器里确认了邮箱、然后回不到 App。账号是好的，App 还显示登录表单 ——
骑手的结论是「验证没生效」。

### 三处必须一致

```
purecycling://login-callback
    ↑            ↑
    │            └── SupabaseConfig.redirectPath
    └── SupabaseConfig.redirectScheme
```

| 位置 | 内容 |
|---|---|
| `core/sync/supabase_config.dart` | `redirectScheme` / `redirectPath` 常量 |
| `ios/Runner/Info.plist` | `CFBundleURLTypes` → `CFBundleURLSchemes: [purecycling]` |
| `macos/Runner/Info.plist` | 同上 |
| `android/app/src/main/AndroidManifest.xml` | `<data android:scheme="purecycling" android:host="login-callback"/>` |

**还有第四处，在代码之外：Supabase 控制台。**

> Authentication → URL Configuration → Redirect URLs → 加入 `purecycling://login-callback`

不加上去 Supabase 会拒绝重定向，而且**从 App 这一侧完全看不出来** ——
邮件照常发出，只是链接指向项目的 Site URL。这是最容易卡住的一步。

`test/auth_test.dart` 断言了常量值，所以谁改了 scheme 而没改 Info.plist，
测试会红。平台文件本身没法从单元测试里读，那份清单在这里。

### 邮件模板

默认模板够用。如果自定义，`{{ .ConfirmationURL }}` 必须保留 ——
它就是指向上面那个 scheme 的链接。

---

## 匿名账号

匿名登录给骑手一个真实的 `auth.users` 行，骑行照常同步、重装 App 也能恢复
（同一台设备上）。**但换手机就找不回来了** —— 没有任何凭据可以登进去。

所以：

- 同步页在匿名状态下**明说**「换手机后无法找回」
- 提供「绑定邮箱」，走 `updateUser(UserAttributes(email, password))`
- 绑定后账号 id 不变，**已经同步的骑行一条都不会动** —— 只是多了一条回来的路

登录页那句「匿名账号同样会把骑行同步到云端，之后可以随时绑定邮箱」是对的，
而且现在真的能绑定。这句话在补上 UI 之前是不成立的。

`updateUser` 会再发一封验证邮件，所以绑定后的提示是
「已绑定，请到邮箱点击验证链接」而不是「已绑定」——地址在未验证前只是记录在案。

---

## 错误翻译

Supabase 返回英文错误，骑手看不懂。`AuthRepository.describeAuthError` 做映射，
是**公开的纯函数**，所以能直接测。

| Supabase 说的 | 骑手看到的 |
|---|---|
| `Invalid login credentials` | 邮箱或密码不正确 |
| `Email not confirmed` | 邮箱尚未验证，请先点击验证邮件中的链接 |
| `User already registered` | 该邮箱已被注册，请直接登录，或换一个邮箱 |
| `... already been registered` | 同上（绑定邮箱时撞到别人的账号） |
| `Unable to validate email address` | 邮箱格式不正确 |
| `Email rate limit exceeded` / `429` | 操作过于频繁，请稍后再试 |
| `Auth session missing!` | 登录状态已失效，请重新登录 |
| 其它 | **原样透传** |

最后一条是刻意的。把未知错误压成「登录失败」会让骑手没有任何可报告的信息；
一句英文至少是可诊断的。

---

## 客户端 key

```
--dart-define=SUPABASE_URL=https://xxxx.supabase.co
--dart-define=SUPABASE_ANON_KEY=eyJhbGci...
```

| Key | 能不能进客户端 |
|---|---|
| publishable / anon | ✅ 它本来就要打进二进制，靠 RLS 保护 |
| **service_role** | ❌ **绝对不行**。绕过全部 RLS，拿到的人能读写每个用户的数据 |

移动端只用 publishable key。这条在 `main.dart` 和 `docs/ci.md` 里都写了。

---

## 配置清单

要让登录和云同步真正跑起来：

- [ ] Supabase 项目建好
- [ ] 跑完 `supabase/migrations/` 里四个迁移（见 `scripts/verify-migrations.sh`）
- [ ] Authentication → Providers → Email 开启
- [ ] Authentication → Providers → **Anonymous 开启**（否则匿名登录会报「该项目未开启匿名登录」）
- [ ] Authentication → URL Configuration → Redirect URLs 加入 `purecycling://login-callback`
- [ ] Storage → 确认 `rides` 桶存在且为 private（迁移里有）
- [ ] 构建时传 `SUPABASE_URL` 和 `SUPABASE_ANON_KEY`

**邮件确认是可选的。** 开着的话注册后需要点链接才能登录 ——
App 会提示「注册成功，请到邮箱点击验证链接后再登录」。
开发阶段可以在 Authentication → Providers → Email 里关掉。

---

## 代码位置

| 文件 | 作用 |
|---|---|
| `core/sync/supabase_config.dart` | URL、key、深链 scheme |
| `features/auth/data/auth_repository.dart` | 全部 auth 调用 + 错误翻译 |
| `features/auth/presentation/login_screen.dart` | 登录 / 注册 / 匿名 / 忘记密码 |
| `features/settings/presentation/widgets/account_section.dart` | 账号状态、绑定邮箱、退出 |
| `features/settings/presentation/sync_screen.dart` | 同步状态与手动同步 |
| `test/auth_test.dart` | 深链配置、账号标签、错误翻译 |
| `test/account_section_test.dart` | 匿名 / 实名两种状态的界面 |
