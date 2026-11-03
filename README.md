# cfws

在自己的服务器上用 cron 跟随上游，自动更新 Cloudflare Worker。**不把代码和 token 交给第三方 CI。**

两种模式，按你的 Worker 类型选：

| 模式 | 用于 | 依赖 |
|---|---|---|
| `direct` | 单个 JS 文件 / 多文件 tarball，**无构建、无静态资源** | bash + curl |
| `wrangler` | 带静态资源（assets）、需要构建（Next / Nuxt / Vue） | bash + curl + **git + node** |

不配 `MODE` 时自动推断：有 `BUILD_CMD` / `SRC_GIT` / `SRC_DIR` 就走 `wrangler`，否则走 `direct`。

---

## 先判断你的 Worker 属于哪种

查一下它的形态：

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/workers/scripts" \
  -H "Authorization: Bearer $TOKEN" |
python3 -c "
import sys,json
for s in json.load(sys.stdin)['result']:
    print(f\"{s['id']:<24} assets={s.get('has_assets')} handlers={s.get('handlers')}\")
"
```

- `assets=False` 且只有 `fetch` → 用 **direct**
- `assets=True` 或有多种 handler → 用 **wrangler**

---

## 两种模式在做什么

### direct（零依赖）

```
cron → curl 拉上游文件 → sha256 比对 → PUT 上传（keep_bindings 保留绑定）→ 健康检查 → 记录版本
```

不需要 node、不需要 git。适合“上游就是一个 `.js` 文件”的场景。

### wrangler（覆盖带资源 / 需构建）

```
cron → git ls-remote 比对 → clone/pull → 跑 BUILD_CMD → wrangler deploy → 健康检查 → 记录版本
```

静态资源上传、assets 清单、版本管理全部交给 wrangler —— 这部分不自己实现，重复造轮子只会出错。

**注意**：`wrangler` 模式部署的是**你的仓库**，不是别人的上游。这类 Worker 通常你已经改过，跟随原作者会覆盖你的改动。

---

## 安装

```bash
git clone https://github.com/unmime/cfws.git
cd cfws
sudo ./install.sh
```

安装脚本会问模式和相关参数，然后生成：

```
/etc/cfws/<worker>.conf      配置（600）
/etc/cfws/cf.token           API Token（600，只含一行）
/etc/cron.d/cfws-<worker>    定时任务
/var/lib/cfws/<worker>/      状态目录 + 源码克隆位置
/usr/local/bin/cfws          主脚本
```

---

## API Token 权限

https://dash.cloudflare.com/profile/api-tokens → Create Custom Token：

- **Account → Workers Scripts → Edit**
- **Account → D1 → Read**（目标 Worker 绑了 D1 时需要）
- **Account Resources** 只勾目标账号

不要用 Global API Key。

---

## 配置项

### 通用

| 变量 | 说明 |
|---|---|
| `WORKER` | Cloudflare 上的脚本名 |
| `ACCOUNT_ID` | 账号 ID |
| `MODE` | `direct` / `wrangler`，可省略自动推断 |
| `VERIFY_URL` / `VERIFY_EXPECT` | 健康检查，部署后请求不到预期内容就算失败 |
| `ALLOW_CREATE` | 默认 `false`。为 `true` 时允许创建不存在的 Worker |
| `STATE_DIR` | 状态目录，默认 `/var/lib/cfws/<worker>` |

### direct 模式

| 变量 | 说明 |
|---|---|
| `UPSTREAM_URL` | 上游直链（`.js` 或 `.tar.gz`） |
| `UPSTREAM_TYPE` | 可省略，按后缀推断 |
| `MAIN_MODULE` | 入口模块名 |
| `COMPAT_DATE` / `COMPAT_FLAGS` | 兼容设置，照抄线上值 |
| `KEEP_BINDINGS` | 保留的绑定类型，默认全保留 |
| `MIN_BYTES` | 上游小于此值视为异常（防 404 页面被当代码） |

### wrangler 模式

| 变量 | 说明 |
|---|---|
| `SRC_GIT` | 源码仓库地址（优先） |
| `SRC_REF` | 分支，默认 `main` |
| `SRC_DIR` | 本地源码目录（与 `SRC_GIT` 二选一） |
| `BUILD_CMD` | 构建命令。**含空格时必须整体加引号** |
| `WRANGLER_CONFIG` | 配置文件路径，省略则用目录下的默认配置 |
| `WRANGLER_BIN` | 默认 `npx --yes wrangler@4`，可指向本地已装的 wrangler |

`BUILD_CMD` 写法示例（引号不能省，否则配置会被拆成两条命令）：

```bash
BUILD_CMD="pnpm install && pnpm build"
BUILD_CMD="opennextjs-cloudflare build"
```

---

## 关键设计

**① 上传前确认 Worker 存在**

`PUT /workers/scripts/{name}` 对不存在的名字会**直接新建**。所以先 `GET` 一次，404 就拒绝并退出。
不做这件事的话，Worker 名拼错一个字母的后果是：静默多出一个空 Worker，原 Worker 没动，而你收到“部署成功”。

在 `wrangler` 模式里这个检查放在**构建之前**——名字拼错不该白跑三分钟构建。

**② direct 模式不需要手写绑定清单**

只声明 `keep_bindings`，Cloudflare 会保留现有的 D1 / KV / 变量 / secret：

```json
{ "main_module": "main.js", "compatibility_date": "2026-03-01",
  "keep_bindings": ["d1", "plain_text", "kv_namespace", "secret_text"] }
```

**③ 阻止把网页当成代码**

两道闸：内容小于 `MIN_BYTES` 跳过；开头出现 `<!doctype html` / `<html` 跳过。

**④ 比文件哈希 / commit sha，不比版本号**

很多项目里的 `version = '1.2.3'` 是硬编码的，作者常忘记改。比内容哈希才可靠。

**⑤ 失败可重试**

```
成功 → 记录版本；任何一步失败 → 不记录 → 下次自动重试
```

不会出现“部署了坏版本还自认为成功”。

---

## 手动执行与排查

```bash
sudo cfws /etc/cfws/<worker>.conf      # 手动跑一次
tail -f /var/log/cfws-<worker>.log     # 看日志
```

| 退出码 | 含义 |
|---|---|
| 0 | 成功，或无需更新 |
| 1 | 拉取 / 构建 / 部署 / 健康检查失败 |
| 2 | 配置或凭据有问题，或目标 Worker 不存在（拒绝自动创建） |

回滚：Cloudflare 后台 → Worker → Deployments → 选旧版本 Rollback。

---

## 适用边界

- ✅ 纯 JS Worker（direct）
- ✅ 带 assets 或需构建的项目（wrangler，需 node）
- ❌ 需要访问**私有** git 仓库且没有部署密钥 —— 请自行在 `SRC_GIT` 里放带凭据的地址，注意别写进公开文件
- ❌ 需要构建但机器上没有 node —— 无解，这是硬约束

---

## License

MIT
