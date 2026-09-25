# 安全模型：分发出去的 App 里有什么

> 结论：**二进制是公开的，我们假设有人反编译。** 里面只有 URL 和 anon key——
> 两者本来就是公开凭据；没有任何东西能让持有者越过 RLS。分发是否安全，
> 不取决于二进制里有什么，取决于数据库拒绝什么，而这一点现在有测试。


## 二进制里有什么

| 东西 | 在不在 | 说明 |
|---|---|---|
| Supabase URL + anon key | ✅ 在 | 公开凭据。能做什么由 RLS 决定，不由 key 决定 |
| service_role key | ❌ 不在 | 只在管理后台的服务端环境变量和本地脚本里 |
| 高德 Web 服务 Key | ❌ 不在 | 骑手自己填（自用/开发），存在本机 SQLite。**分发时也不能打进来**：客户端发出去的东西机器主人一定能读到，见 [map.md](map.md) 的「Key 由谁持有」 |
| Android 签名密钥 | ❌ 不在 | 只在 CI secrets，构建时重建 |

Flutter 二进制可以反编译，这是已知前提，也是设计的一部分：
**没有任何秘密放在客户端。**


## 拿到 anon key 的人能做什么

这是用「反编译者的第一分钟」来写的清单，每条都有断言。

| 尝试 | 结果 | 断言在哪 |
|---|---|---|
| 读 `rides` / `routes` / `profiles` / `user_settings` | `[]` | `verify-migrations.sh`（SQL 层）+ `local-stack.sh`（PostgREST 层） |
| 列出或下载 Storage 里的 GPX | 拒绝 | 同上 |
| 调用 `push_ride` / `push_route` | 401（execute 被 revoke） | 同上 |
| 调用 `admin_list_users` / `is_admin` | 401 | 同上 |
| 读 `admins` / `admin_audit` | 权限拒绝或 0 行 | `verify-migrations.sh` |
| 把 `user_id` 伪造成别人写记录 | 被 `auth.uid()` 覆盖，写进自己账号 | `verify-migrations.sh` |
| 用第二个账号读第一个账号的数据 | 0 行 | `verify-auth-flow.sh` |

**能做的是**：注册账号（匿名或邮箱）、以自己身份写自己的数据、在自己的前缀里
传文件、以及 `user_settings` 上的一次性写入。这些是「当一个用户」，不是「操作数据库」。

> 一个容易被忽略的事实：Supabase 的镜像会给 public schema 的新表**默认授给
> anon 全部权限**（`alter default privileges ... grant all`）。所以「有权限」
> 不是防线，**策略才是**。这也是为什么 anon 的断言必须存在：策略写漏一次，
> 不会有任何报错，只会有人读到别人的轨迹。


## 残余风险（诚实清单）

### 1. 滥用与配额 —— 现实中最可能发生的一条

注册和上传是开放的。一个人可以造很多账号，每个账号传 50 MB × 任意数量的
GPX，把项目的存储和带宽配额吃光。数据不会泄露，但服务会变慢或暂停。

按性价比排序的对策：

1. **注册加 CAPTCHA**（Turnstile / hCaptcha，Supabase Auth 支持）——最有效的一道；
2. **生产环境开启邮箱确认**（本地 `config.toml` 关着是为了开发方便）；
3. **每用户配额**（未做）：Storage 对象数或总量上限，或定时清理长期未同步的账号；
4. 监控用量，异常时先关匿名注册。

### 2. 可用性

GoTrue 有按 IP 的注册/登录限流，Supabase 平台也有全局配额。极端流量会造成
短时不可用——**本地记录不受影响**，这也是本地优先的另一个好处。

### 3. RLS 被改坏 —— 唯一能让数据泄露的路径

守住它的是一组规矩和脚本：新表必须显式 `revoke`/`grant`；每个 policy 必须
限定 `to authenticated`；`verify-migrations.sh` 里既有跨账号断言，也有 anon
断言。改策略时这两个脚本就是审查。

### 4. 管理员会话

后台的 cookie 被偷 = 最大权限（等同 service_role）。建议：管理员账号强密码、
开 MFA、不在公共电脑登录。后台本身的动作也全部写审计。

### 5. service_role 泄露 —— 唯一真正致命的情况

它会绕过全部 RLS。它只存在于：管理后台的服务端环境变量、本地开发脚本
（从 `supabase status` 读）。防线：`.env.local` 被 gitignore、`check-secrets.sh`
扫描、后台的 `lib/supabase/admin.ts` 加了 `server-only`（客户端组件 import 会
直接构建失败）。


## 上线前检查清单（云项目）

- [ ] Authentication → Email：开启确认
- [ ] Authentication → Providers：匿名登录按需（不用就关）
- [ ] 注册加 CAPTCHA（推荐）
- [ ] Redirect URLs 只登记 `purecycling://login-callback`
- [ ] 跑一遍 `scripts/verify-migrations.sh`（表结构与策略）
- [ ] 用两个测试账号对着**云项目**跑一遍隔离检查（把 `local-stack.sh` 的
      断言指向它；本地通过不代表云端设置一致）
- [ ] 管理后台：管理员账号开 MFA；`SUPABASE_SERVICE_ROLE_KEY` 只配在部署环境
- [ ] 确认发布产物里没有 service_role：`scripts/check-secrets.sh` + 后台构建
- [ ] 不要把高德 Key 打进构建；部署 `route` 函数并 `supabase secrets set AMAP_KEY=...`，
      `ROUTING_RELAY_URL` 只写进构建参数（[map.md](map.md) 的「Key 由谁持有」）
- [ ] `route` 函数：确认 `verify_jwt` 开着、`ROUTE_DAILY_LIMIT` 按预算设好
      （它只暴露算路一个接口，防的是配额被一个人跑完）


## 一句话

反编译不是威胁模型的一部分——**「能做什么」才是**。那把 key 能做的事，被
RLS 限制在「操作自己的数据」；anon 的两层断言（SQL 与 API）让这句话在被破坏时
立刻变红，而不是在有人读到别人轨迹时才被发现。
