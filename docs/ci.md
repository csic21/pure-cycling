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
215 个测试            没有一个需要 key
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

生成 keystore 的 base64：

```sh
base64 -i upload-keystore.jks | pbcopy   # macOS
```

---

## 流水线

### `ci.yml` — 每次 push 和 PR

```
secrets            key 扫描（含自检）
analyze-and-test   生成 Drift 代码 → flutter analyze → 215 个测试
migrations         Docker 起 Supabase 官方 Postgres，跑迁移 + RLS 隔离验证
auth-flow          Docker 起真实 GoTrue，注册账号验证触发器与令牌
build-android      release APK（R8 开着）
build-ios          iOS 编译（不签名）
```

几个刻意的选择：

**为什么是 release 而不是 debug 构建。** debug 根本不跑 R8，而 R8 正是我加的那份 proguard 规则唯一会暴露问题的地方——drift 和 Supabase 里有靠反射访问的类，被 strip 掉之后**只在 release 构建里、只在运行时**报错。那是最糟的发现时机。

**为什么迁移要单独跑。** RLS 是**数据库**在强制执行的，不是客户端。一个 policy 写错了（比如把 `auth.uid() = user_id` 写成 `user_id = user_id`）在类型检查里完全合法，只有第二个账号能读到第一个账号的数据时才暴露。

**为什么 Auth 流程还要再跑一次。** 迁移脚本用的是自己伪造的 `request.jwt.claim.sub`，它证明策略本身对，证明不了 Supabase 的 Auth 服务写出来的行和策略的假设一致。`verify-auth-flow.sh` 起真实的 GoTrue、注册真实的账号、用真实签发的令牌，验证触发器、匿名注册和跨账号隔离。三样独立演进的东西在这里交界，不匹配只会在运行时暴露（详见 [auth.md](auth.md)）。

**为什么 GitHub Actions 版本固定。** Flutter 升级会改变分析器的规则集和 drift 代码生成器的输出，两者都会让一个无关的 PR 变红。

### `release.yml` — 打 tag 时

```
verify    先跑一遍 CI 的全部检查（tag 不该绕过测试）
android   签名 AAB
ios       编译归档（不签名）
```

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
