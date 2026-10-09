# 构建流水线与密钥管理

---

## 先说结论：不要把 key 放在 git 上

这不是洁癖，是具体的损失：

| Key | 泄露的后果 |
|---|---|
| 高德 **Web 服务 Key** | 按配额计费。公开仓库的 key 会在几小时内被爬虫扫到，配额被跑光，**真实用户规划路线会失败**，而你不会知道原因 |
| Supabase **service_role** | 绕过全部 RLS。拿到的人可以读取和删除**每个用户**的数据 |
| Supabase **publishable / anon** | 低风险。它本来就要打进 App 二进制，谁都能提取；靠 RLS 保护（`scripts/verify-migrations.sh` 验证过隔离） |

**而且 git 历史是永久的。** 后面再提交一次删掉文件没用——它还在历史里。要清掉得重写历史（`git filter-repo` / BFG）并 force-push；如果已经 push 过，就假定它已泄露，**先轮换**。

### 而且这个项目不需要

架构从第一天就是按「没有 key 也能开发」设计的：

```text
398 个测试            没有一个需要 key
SQL 迁移验证          用 Docker 起 Supabase 官方镜像，不需要云项目
Auth 流程验证         真的注册账号，不需要云项目、不需要 key
本地整栈开发           supabase start，完整 Kong + PostgREST + Storage
高德集成              用录制的响应测（test/amap_parsing_test.dart）
没配置 key 时          App 完整可用，只有路线规划退化成直线
```

**高德 Key 根本不进流水线。** 它是运行时填在 App 设置里的，存在用户自己手机的 SQLite 里。这是当初的设计选择，现在正好省掉一整个密钥管理问题。

需要配置的只有 Supabase 的两项。

---

## 密钥怎么流动

```
本地开发                       CI                         发布
──────────────────────────────────────────────────────────────────────
app/dart_define.json           GitHub Secrets             GitHub Secrets
（.gitignore）                  （加密存储）                （加密存储）
      ↓                              ↓                          ↓
flutter run                    flutter build              flutter build
--dart-define-from-file=…      --dart-define-from-file=…  --dart-define-from-file=…
      ↓                              ↓                          ↓
                          dart-define 烘焙进二进制
```

### 本地开发

```sh
cd app
cp dart_define.example.json dart_define.json
# 填入真实值，这个文件不会进 git
flutter run --dart-define-from-file=dart_define.json
```

不填也能跑，App 会以本地模式工作并在设置里说明「云同步未配置」。

### 在 CI 里配置

仓库 → Settings → Secrets and variables → Actions：

**Secrets**（加密，日志里不显示）：

| 名称 | 用途 |
|---|---|
| `SUPABASE_ANON_KEY` | publishable key。**不是** service_role |
| `ANDROID_KEYSTORE_BASE64` | 上传密钥库的 base64 |
| `ANDROID_STORE_PASSWORD` | |
| `ANDROID_KEY_ALIAS` | |
| `ANDROID_KEY_PASSWORD` | |

**Variables**（明文，日志可见）：

| 名称 | 用途 |
|---|---|
| `SUPABASE_URL` | 项目 URL。本身不是秘密，它就在每个 App 二进制里 |
| `SUPABASE_FUNCTIONS_URL` | 边缘函数的基址（`route` / `delete-account` / `release`）。同样不是秘密——它就在每个用到它的二进制里；各函数按上面各自的方式守住 |
| `GITHUB_RELEASE_REPO` | App 预期的 Release 仓库；CI 自动写入当前仓库，本地构建默认 `csic21/pure-cycling`。App 会拒绝来自其他仓库的中转响应和 APK |
| `SUPPORT_EMAIL` | 可选。填入后「设置 → 关于」多一行联系方式；不填就不显示那一行（不用占位地址） |

生成 keystore 的 base64：

```sh
base64 -i upload-keystore.jks | pbcopy   # macOS
```

---

## 流水线

### `ci.yml` — 每次 push 和 PR

```
secrets            key 扫描（含自检）
analyze-and-test   生成 Drift 代码 → flutter analyze → 398 个测试
functions          deno check + 22 个函数测试 + 两个函数必须要求会话（不需要 Docker）
migrations         Docker 起 Supabase 官方 Postgres，跑迁移 + RLS 隔离 + 管理员边界 + 配额验证
auth-flow          Docker 起真实 GoTrue，注册账号验证触发器与令牌
build-android      release APK（R8 开着）
build-ios          iOS 编译（不签名）
```

### `admin.yml` — admin/ 或它的 workflow 有改动时

```
typecheck + build  pnpm install --frozen-lockfile → tsc --noEmit → next build
```

只挂在 `admin/**` 的路径上：Flutter 的流水线和发布流水线都不该等一个
Next.js 构建。这里**故意不提供任何 Supabase URL 或 key** —— 后台在请求时才读配置，
一个必须有 `.env.local` 才能构建的后台会让每个新克隆的人先卡一次。

依赖用 **pnpm**（`packageManager` 字段钉版本，CI 里由 `pnpm/action-setup` 读取）：
node_modules 相对于 npm 省一半以上，而且全局 store 是内容寻址的，同一个包在
不同项目之间只存一份。

管理员边界的完整验证需要 GoTrue + PostgREST，所以放在本地：
`scripts/verify-admin-flow.sh`（不进程 CI，理由和本地整栈一样：要拉整栈的镜像）。
策略层面的那一半（`is_admin()`、`admin_list_users`、审计可见性、管理员读不到
骑行）在 `migrations` job 里，每次 push 都跑。

算路代理也是同样的切法：**逻辑进 CI，整栈留本地**。

| 检查 | 在哪 | 证明什么 |
|---|---|---|
| `deno check` + `deno test` | `functions` job，每次 push | 拒绝路径（401/429/503/400）、上游 URL 只由服务端构造、共享 Release 缓存、配额三分支、删除顺序（先文件后账号） |
| `scripts/check-functions-config.sh` | `functions` job，每次 push | 每个函数 `verify_jwt = true` —— 中转那条错了，它就是一个对全网开放的算路接口，而且请求看起来一切正常 |
| `scripts/verify-routing-relay.sh` | 本地（要整栈 + Edge runtime） | 真实运行时、真实 Kong、真实会话，桩代替高德 |
| `scripts/verify-account-deletion.sh` | 本地（要整栈 + Edge runtime） | 账号真的被删掉、GPX 没留成孤儿、别人的数据一条不少、旧会话立即失效 |

`check-functions-config.sh` 值得单独说一句：它是那种「错了不会报错、只会被人白嫖」
的配置，所以由脚本守，而不是靠 review 时记得看。

几个刻意的选择：

**为什么是 release 而不是 debug 构建。** debug 根本不跑 R8，而 R8 正是我加的那份 proguard 规则唯一会暴露问题的地方——drift 和 Supabase 里有靠反射访问的类，被 strip 掉之后**只在 release 构建里、只在运行时**报错。那是最糟的发现时机。

**为什么迁移要单独跑。** RLS 是**数据库**在强制执行的，不是客户端。一个 policy 写错了（比如把 `auth.uid() = user_id` 写成 `user_id = user_id`）在类型检查里完全合法，只有第二个账号能读到第一个账号的数据时才暴露。

**为什么 Auth 流程还要再跑一次。** 迁移脚本用的是自己伪造的 `request.jwt.claim.sub`，它证明策略本身对，证明不了 Supabase 的 Auth 服务写出来的行和策略的假设一致。`verify-auth-flow.sh` 起真实的 GoTrue、注册真实的账号、用真实签发的令牌，验证触发器、匿名注册和跨账号隔离。三样独立演进的东西在这里交界，不匹配只会在运行时暴露（详见 [auth.md](auth.md)）。

**为什么 GitHub Actions 版本固定。** Flutter 升级会改变分析器的规则集和 drift 代码生成器的输出，两者都会让一个无关的 PR 变红。

### `release.yml` — 打 tag 时

```
verify    先跑一遍 CI 的全部检查，并核对更新服务与当前发布仓库
android   签名 AAB
          同时构建签名 APK，供 GitHub Release 下载
publish   用 Actions 自带的 GITHUB_TOKEN 把 APK 发布到当前仓库的 Release
ios       编译归档（不签名）
```

发布时先把 `app/pubspec.yaml` 的版本升到例如 `0.2.0+2`，然后推送同版本 tag `v0.2.0`。源码和 Release 都位于公开的 `csic21/pure-cycling`。Android 签名四项 Secret 也必须齐全，发布任务才会生成可安装的 APK。首次发布前请备份签名 keystore；后续更新必须使用同一把签名密钥。

App 启动时每天最多静默检查一次最新 Release，也可以在「设置 → 关于 → 检查更新」手动检查。检测到新版本后，Android 用户点击「安装更新」，App 在内部下载 APK 并显示进度，然后打开系统安装界面。用户需要确认安装；部分设备首次使用时还需要允许「从此应用安装」。iOS 会显示版本说明，安装更新仍由 TestFlight 或 App Store 完成。GitHub Release 的 APK 不会自动替换正在运行的 App。

自动检查的网络响应返回后，会再次确认应用仍在前台、没有记录骑行，且停留在首页或设置首页；被骑行、恢复提示或其他页面打断时延后提示，回到安全状态后继续。手动检查与自动检查共用一个应用级流程，从检查到下载和交给系统安装器期间，重复点击不会创建第二个下载或弹窗。离开关于页后，旧的手动检查不会再弹出结果。

APK 下载逐块写入磁盘，最多 250 MiB；更新说明响应最多 1 MiB。取消或返回会关闭下载连接，清除本次未完成文件；清理任务跳过仍在写入的文件，下载完成也只关闭自己创建的弹窗。被系统安装器引用的完整 APK 不按时间清除；前后台切换和冷启动都会保留一个完整安装包，即使确认或权限页面停留超过一分钟也不会删除。只有用户明确开始下一次下载时才替换它；若旧文件仍无法清除，新下载会停止，避免继续堆积。下载结束后若已经进入骑行或后台，不会打开安装器。Android 仍会核验应用包名、提示的版本名和递增的 versionCode，并由用户在系统安装界面确认。


### 更新检查为什么要走中转

**App 不直接问 GitHub。** 匿名调 `api.github.com` 的配额是 **60 次/小时，按公网 IP 计**，
而这个额度是整个 IP 后面的所有人共用的。国内运营商大量使用 CGNAT，
一个公网 IPv4 后面是成百上千个用户 —— 额度被陌生人花光，
每个骑手都拿到一个 403，而重试在接下来一小时内都不会有用。
这个配额不在 App 手里，所以 App 做什么都没用。

`supabase/functions/release` 查询 GitHub，并将结果保存在
Postgres 的 `release_cache` 中。数据库租约保证不同边缘实例同时收到请求时
只有一个实例回源；成功结果缓存十分钟，没有 Release 的结果缓存 30 秒。
GitHub 暂时不可用时最多沿用一天内的上次成功结果，并短暂退避。

它和另外两个函数不同，是**唯一不要求会话**的：它转发的是公开仓库的公开信息，
没有秘密可保护，而要求会话会让退出登录的骑手查不了更新。
`scripts/check-functions-config.sh` 会断言它保持公开，免得被当成漏配改回去。

首次部署和 fork 部署的顺序：先应用 `20260928084427_release_cache.sql`
迁移，再部署函数。默认仓库是 `csic21/pure-cycling`；fork 必须设置
`RELEASE_REPOSITORY` 为**这次工作流发布到的仓库**。数据库配置不可用时函数返回 503。

```sh
supabase db push --linked
supabase functions deploy release --no-verify-jwt
./scripts/check-release-service.sh "$SUPABASE_FUNCTIONS_URL" csic21/pure-cycling
```

fork 在部署前运行 `supabase secrets set RELEASE_REPOSITORY=owner/repo`。
`GITHUB_TOKEN` 可选：配置后匿名 API 的额度问题会进一步减轻；没有 token 时，
共享缓存限制请求量，若 GitHub API 仍限流，函数会使用 GitHub 官方的
`/releases/latest` 链接取得版本，并验证当前和早期版本使用的 APK 下载链接。
此回退不会提供完整的 Release 说明，App 会引导用户查看 GitHub 页面。
发布工作流会在构建前调用公开的更新接口，检查它已部署、缓存可用且
`X-Release-Repository` 与当前 `$GITHUB_REPOSITORY` 一致。首次发布时
`release_missing` 的 404 是正常状态；其他 404 或 503 会阻止发布。

Apple 的部分**故意停在编译**。上架 TestFlight 还需要 App Store Connect API key、分发证书和 provisioning profile——三个额外的 secret，以及「要不要从 CI 发布」这个决定。现在的产物是编译检查和冒烟测试用的构建，不是可上架的构建。

---

## 密钥扫描

`scripts/check-secrets.sh` 在 CI 和本地都能跑。

```sh
./scripts/check-secrets.sh              # 扫描会被提交的文件
./scripts/check-secrets.sh --all        # 连 gitignore 的也扫，用来审计磁盘上有什么
./scripts/check-secrets.sh --self-test  # 种诱饵验证每个规则还能匹配
```

### 自检是必须的

**一个悄悄失效的扫描器比没有扫描器更糟**：构建一直绿，所有人都不再想这件事。所以每次 CI 都会先用诱饵验证四个规则都还在匹配，外加一个**反向测试**——一行提到「amap」但没有 key 的文本**不能**被报出来，否则就是在训练读者忽略告警。

诱饵是从片段拼出来的，不是写死的：写死的话它们本身就是字面量凭据，扫描器会一直把自己的测试夹具报成泄露。

### 误报的代价

规则刻意收窄过一轮。第一版把注释里每个 `service_role` 都报成 HIGH——包括脚本自己的注释，一跑就是 10 个 finding。**会叫狼来了的扫描器会被关掉**，那就等于没有。

现在的规则只在真的像凭据时才触发：

| 规则 | 严重度 | 触发条件 |
|---|---|---|
| Supabase JWT | CRITICAL | `eyJ...` 三段式 |
| service_role key | CRITICAL | `service_role` 后 60 字符内跟着 `eyJ` |
| 高德 Key | HIGH | 同一行提到 amap/高德 **且** 有 32 位十六进制串 |
| Supabase URL | INFO | 本身不是秘密，只在与 service_role 同时出现时才有问题 |

高德那条还加了尾部边界：不加的话，一个 40 位的 commit hash 里就包含 32 位十六进制子串，每一行都会变成 finding。

---

## 本地钩子（可选）

把扫描接到 pre-commit，可以在密钥离开你的机器之前拦住它：

```sh
cat > .git/hooks/pre-commit <<'EOF'
#!/bin/sh
exec "$(git rev-parse --show-toplevel)/scripts/check-secrets.sh"
EOF
chmod +x .git/hooks/pre-commit
```

---

## 如果密钥已经泄露了

顺序不能颠倒：

1. **先轮换。** push 的那一刻就假定它已被抓取。删文件不能 un-push。
   - 高德：到控制台重置 Key，检查配额消耗记录
   - Supabase：Settings → API → 轮换；service_role 泄露的话还要审计 `auth` 日志
2. **再清历史。** `git filter-repo` 或 BFG，然后 force-push。
3. **通知。** 如果仓库是公开的，假定已经有人抓过。

---

## 相关文件

| 文件 | 作用 |
|---|---|
| `.github/workflows/ci.yml` | 每次 push 的检查 |
| `.github/workflows/release.yml` | 打 tag 时的构建 |
| `scripts/check-secrets.sh` | 密钥扫描，含自检 |
| `scripts/verify-migrations.sh` | 起 Supabase 官方 Postgres 验证迁移 + RLS |
| `scripts/verify-auth-flow.sh` | 起真实 GoTrue 验证注册、匿名与跨账号隔离 |
| `app/dart_define.example.json` | 本地配置的模板（提交） |
| `app/dart_define.json` | 真实值（不提交） |
| `app/android/app/build.gradle.kts` | 有 keystore 就用它，没有就退到 debug 签名 |
