# 后端：现在在哪，什么时候才需要加一个

> 结论：**不做前后端分离。** 骑手端直连 Supabase，管理后台也直连 Supabase；
> 「服务端」只在需要 `service_role` 的那几个动作里出现，形态是 Next.js 的一个
> server action / route，不是一个独立的服务。

---

## 后端已经存在，只是不是独立部署的服务

```text
Flutter App ──┐
              ├──> Kong ──> GoTrue（登录）
Next.js 后台 ─┘         ──> PostgREST（数据 + RPC）
                        ──> Storage（GPX）
                        ──> Postgres（RLS + 函数 + 触发器）
```

业务规则已经在数据库里，不是「还没写」：

| 规则 | 位置 |
|---|---|
| 谁能读哪一行 | `supabase/migrations/*_rls_and_grants.sql` |
| 骑行合并规则（不拿 null 擦轨迹、时钟单调） | `push_ride()` |
| `user_id` 只认 `auth.uid()`，不信任请求体 | `push_ride()` / `push_route()` |
| 新账号自动建 profile / settings | 触发器 |
| 管理员边界与审计 | `20260924000100_admins.sql` |

所以「要不要后端」的准确说法是：**要不要在 Supabase 之上再叠一个自己部署的服务层。**

---

## 为什么现在不要

1. **没有一项功能需要服务端可信计算。** 记录在本地，同步是「本地说了算」，
   登录/数据/文件各有服务。App 里唯一需要服务端的部分已经写在 SQL 函数里。
2. **叠一层会让安全性变差。** RLS 是被 `verify-migrations.sh` 和
   `verify-auth-flow.sh` 用官方镜像验证过的边界。自建 API 走 `service_role`，
   绕过它，就得在服务层重建同等强度的授权测试——两份授权逻辑，两份出 bug 的机会。
3. **代价不对称。** 直连的成本是 0（已经有了）；加服务层的成本是部署、密钥、
   监控、升级，换来的能力是 0。

「多用户」不是理由：Supabase Auth + RLS 下，一个用户和一万个用户走的是同一条代码路径。

---

## 什么时候才需要

判断标准只有一条：**这件事客户端做不到，或者客户端不可信。**

| 触发条件 | 为什么绕不开服务端 | 形态 |
|---|---|---|
| 禁用/删除用户、改邮箱、重置密码 | `auth.admin` 需要 `service_role` | 后台的 server action（已有） |
| 第三方 API Key（高德算路、DEM 高程） | Key 不能进客户端：发出去的东西机器主人一定能读到 | 薄代理，只做那一件事 |
| 推送通知（APNs/FCM） | 推送密钥 + 按用户定向 | Edge Function 或小服务 |
| 支付/订阅 | 金额和权益必须可信 | 独立服务 |
| 定时任务（清理孤儿 GPX、周报、聚合） | 没有客户端在跑 | Edge Function / cron |

第一项已经落在管理后台里。**第二项（算路代理）已经实现**：`supabase/functions/route`
持有高德 Key，要求会话、按账号扣配额、只暴露算路一个接口，理由和实现见
[map.md](map.md) 的「Key 由谁持有」。出现时，**加的是「一个只做那件事的服务」，
不是把 App 改成前后端分离。**

---

## 管理后台的边界（隐私）

产品的承诺是骑行记录私有（规格 §44）。所以管理员能看的是**账号元数据**，
不是轨迹：

| 能 | 不能 |
|---|---|
| 账号列表与 profile：邮箱、注册时间、最后登录、骑行/路线**条数** | 任何骑行轨迹、GPX、传感器数据 |
| 封禁 / 解封账号（`service_role`，写审计） | 读别人的 `rides` / `routes` / `user_settings` |
| 删除账号：先删 Storage 对象、再删用户（行有级联，文件没有） | 删除或修改审计日志 |
| 读审计日志 | 读 Storage 里的文件 |

这些不是口头约定，`scripts/verify-migrations.sh` 里有断言：
**管理员能列账号、能读审计，但读不到任何一条骑行。**

实现上：

- 管理员身份是 `public.admins` 表里的一行，`is_admin()` 是策略用的判定函数。
  `admins` 表**完全没有 Data API 权限**（Supabase 镜像给 public schema 设了默认
  权限，所以是显式 `revoke` 出来的，不是「没 grant」）。
- 账号列表走 `admin_list_users()`：`security definer` 才能读 `auth.users` 的邮箱，
  函数内部先判 `is_admin()`，非管理员直接 `insufficient_privilege`。
  列表按邮箱子串筛选并分页（`p_search` / `p_limit` / `p_offset`），
  返回的 `total` 是**筛选后**的总数 —— 后台靠它显示「匹配 N 个」并决定有没有下一页。
  匿名账号没有邮箱，只在不过滤时出现，界面上写明了这一点。
- 封禁/解封走后台的 server action，用 `SUPABASE_SERVICE_ROLE_KEY`（只存在于
  服务端环境变量，永不进浏览器），成功与否都写一行 `admin_audit`。
- 审计表没有外键：管理员账号或目标账号被删掉之后，日志必须还在。
- 账号列表与审计表都分页并显示总数（50 / 100 条一页）：一个悄悄被截断的列表
  读起来像「这就是全部」，那比短更糟。

---

## 如果将来真的要加后端

加，但**不要动 App 的同步路径**。那条路径（SQLite → SyncQueue → PostgREST/RPC）
是离线优先的核心，已经被测试锁住；新服务只负责它自己那件事，需要读数据时
以 `service_role` 访问 Postgres，并把授权逻辑写在自己的测试里。

什么时候重新评估这份文档：**上表里出现第二个被勾掉的触发条件时。**
