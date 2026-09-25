# 管理后台

Next.js + Supabase 直连。**没有独立后端**，理由、边界和触发条件见
[docs/backend.md](../docs/backend.md)。

## 能做什么

| 页面 | 内容 |
|---|---|
| `/users` | 账号列表：邮箱、注册时间、最后登录、骑行/路线**条数**、是否管理员、是否封禁；封禁 / 解封 |
| `/audit` | 审计日志：谁在什么时候对哪个账号做了什么 |

**不能做**：读任何人的骑行轨迹、GPX、位置数据。这不是「还没做」，是产品承诺
（规格 §44）。数据库策略锁着这条线，`scripts/verify-migrations.sh` 和
`scripts/verify-admin-flow.sh` 各有一组断言。

## 本地跑

```sh
# 1. 起整栈（会应用 supabase/migrations 里的全部迁移）
scripts/local-stack.sh --reset

# 2. 造一个管理员账号
#    先在 App 里注册（或 Supabase Studio → Authentication 里新建），
#    然后把它加进名单 —— 这是唯一一步需要 SQL 的操作，且刻意不通过 Data API：
docker exec -i supabase_db_cycling psql -U postgres -d postgres -c \
  "insert into public.admins (user_id) select id from auth.users where email = 'you@example.com';"

# 3. 配置并启动
cp .env.example .env.local     # 值从 supabase status 取
pnpm install
pnpm run dev                   # http://localhost:3001
```

**用 pnpm，不用 npm**：node_modules 相对 npm 省一半以上，而且全局 store 是内容
寻址的，同一个包在不同项目之间只存一份。版本钉在 `package.json` 的
`packageManager` 字段里，`preinstall` 钩子会在 npm/yarn 下直接报错退出。
store 本身想回收空间时：`pnpm store prune`。

## 环境变量

| 变量 | 用途 |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | 项目 URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | publishable key，读路径用它 + RLS |
| `SUPABASE_SERVICE_ROLE_KEY` | **仅服务端**，封禁账号用。绕过 RLS，永远不要加 `NEXT_PUBLIC_` 前缀 |

`.env.local` 已被 `.gitignore` 排除；`lib/supabase/admin.ts` 里的 `server-only`
会让「不小心在客户端组件里 import 它」变成构建错误。

## 验证

本地栈跑着时：

```sh
scripts/verify-admin-flow.sh
```

它注册两个真实账号、把其中一个提升为管理员、以骑手身份同步一条骑行，然后断言：

```text
✓ 管理员能看到账号列表（含邮箱）
✓ 非管理员被 admin_list_users 拒绝（HTTP 403）
✓ 骑手能读到自己的骑行
✓ 管理员读不到任何骑行
✓ public.admins 不通过 Data API 暴露（HTTP 403）
```

## 边界是怎么实现的

- 管理员 = `public.admins` 里的一行；`is_admin()` 给策略用。
- 账号列表走 `admin_list_users()`（`security definer` 才能读 `auth.users` 的邮箱），
  函数内部先判 `is_admin()`，非管理员直接 `42501`。
- 封禁/解封走 server action：先用调用者的会话确认「是不是管理员」，
  再用 `service_role` 执行 GoTrue 的 ban —— 两个凭据各做一件对方做不到的事。
- 「已封禁」状态从审计日志派生，不依赖 GoTrue 的 `banned_until` 列
  （那个列是 auth 服务启动时才加的，裸镜像里没有）。
- 审计表没有外键：管理员或目标账号被删掉后，日志必须还在。

## 还没做

- 生成类型（`supabase gen types typescript`）—— 现在 `admin_list_users` 的结果
  类型是手写在页面里的；出现第二个 RPC 时应该换掉。
- 分页 UI（RPC 支持 `p_limit` / `p_offset`，页面写死 100）。
- 改邮箱、重置密码：同样是 `auth.admin`，需要时按封禁那条路加。
