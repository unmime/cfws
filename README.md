# cfws

在自己的服务器上用 cron 跟随上游，自动更新 Cloudflare Worker。**零依赖，不碰 GitHub Actions。**

只需要 `bash` + `curl`。不需要 node、不需要 wrangler、不需要 fork、不需要 CI。

---

## 它解决什么问题

有些 Worker 是别人写的、你会长期使用、但作者偶尔才更新一次。你希望他更新后你这边也跟上，但不想：

- 把代码和 token 放进 GitHub Actions（第三方机器 + secrets 暴露面）
- 每周手动 `git pull && wrangler deploy`
- 用 watchtower —— 那是给 Docker 镜像用的，Worker 没有镜像

cfws 的做法：**在自己的机器上定时拉取上游文件，变了就调 Cloudflare API 上传。**

```
cron 触发
   ↓
curl 拉上游文件
   ↓
sha256 比对，没变就退出
   ↓
变了 → PUT 到 Cloudflare（保留原绑定）
   ↓
curl 健康检查，通过才记录版本
```

---

## 为什么不直接用 CI

| | GitHub Actions | cfws |
|---|---|---|
| 执行环境 | 别人的虚拟机 | 你自己的机器 |
| 凭据存放 | GitHub Secrets | 本地 600 权限文件 |
| 需要 fork | 要 | 不要 |
| 需要 node | 要 | 不要 |
| 上游改结构时的容错 | 合并冲突 | 健康检查失败则不更新，等人工处理 |

---

## 安装

```bash
git clone https://github.com/unmime/cfws.git
cd cfws
sudo ./install.sh
```

安装脚本会问几个问题，然后生成：

```
/etc/cfws/<worker>.conf      配置（600）
/etc/cfws/cf.token           API Token（600，只含一行）
/etc/cron.d/cfws-<worker>    定时任务
/var/lib/cfws/<worker>/      状态目录（记录上次部署的哈希）
/usr/local/bin/cfws          主脚本
```

装完会立刻跑一次并给出结果。

---

## Cloudflare API Token 权限

在 https://dash.cloudflare.com/profile/api-tokens 创建 Custom Token：

- **Account → Workers Scripts → Edit**
- **Account → D1 → Read**（如果目标 Worker 绑定了 D1）
- **Account Resources** 只勾目标的那个账号

不要用 Global API Key，也不要给管理员级 Token。

---

## 配置项

见 `cfws.conf.example`，关键几项：

| 变量 | 说明 |
|---|---|
| `WORKER` | Cloudflare 上的脚本名 |
| `UPSTREAM_URL` | 上游直链（`.js` 或 `.tar.gz`） |
| `UPSTREAM_TYPE` | 可省略，默认按 URL 后缀推断；`raw` 单文件 / `tarball` 压缩包 |
| `MAIN_MODULE` | 入口模块名，必须与压缩包内相对路径一致 |
| `COMPAT_DATE` / `COMPAT_FLAGS` | Worker 兼容设置，**照抄线上值** |
| `KEEP_BINDINGS` | 保留的绑定类型，默认全保留 |
| `VERIFY_URL` / `VERIFY_EXPECT` | 健康检查，部署后请求不到预期内容就算失败 |
| `MIN_BYTES` | 上游小于此字节数视为异常（防 404 页面被当代码上传） |

---

## 关键设计

**① 不需要手写绑定清单**

上传时只声明 `keep_bindings`，Cloudflare 会保留 Worker 现有的 D1 / KV / 变量 / secret：

```json
{
  "main_module": "main.js",
  "compatibility_date": "2026-03-01",
  "keep_bindings": ["d1", "plain_text", "kv_namespace", "secret_text"]
}
```

所以脚本对"这个 Worker 具体绑了什么"一无所知，天然通用。

**② 上传前先确认 Worker 存在**

`PUT /workers/scripts/{name}` 对不存在的名字会**直接新建**。所以脚本会先 `GET` 一次，404 就拒绝并退出。
不这么做的话，Worker 名拼错一个字母的后果是：静默多出一个空 Worker，原 Worker 没动，而你收到"部署成功"。

**③ 阻止把网页当成代码**

两道闸：内容小于 `MIN_BYTES` 跳过；开头出现 `<!doctype html` / `<html` 跳过。
上游 404 返回一个错误页时，避免它被当成脚本传上去。

**④ 比文件哈希，不比版本号**

很多项目里的 `version = '1.2.3'` 是硬编码的，作者改代码时常忘记改。比内容哈希才可靠。

**③ 失败可重试**

```
上传成功 → 健康检查通过 → 才记录哈希
任何一个环节失败 → 不记录 → 下次自动重试
```

不会出现"部署了坏版本还自认为成功"。

---

## 适用边界

**只适合纯 JS、无需构建的 Worker。**

- ✅ 单文件 `main.js`，或几个 `.js` / `.mjs` / `.wasm` 文件
- ❌ TypeScript、需要打包、需要 npm 依赖 —— 这类请用 CI

配置错误的典型症状：健康检查一直失败、日志里 `No such module`。此时线上仍是旧版本，不会挂。

---

## 手动执行与排查

```bash
# 手动跑一次
sudo cfws /etc/cfws/<worker>.conf

# 看日志
tail -f /var/log/cfws-<worker>.log

# 回滚：Cloudflare 后台 Worker → Deployments → 选旧版本 Rollback
```

常见退出码：

| 码 | 含义 |
|---|---|
| 0 | 成功，或无需更新 |
| 1 | 拉取失败 / 内容异常 / 部署失败 / 健康检查失败 |
| 2 | 配置 / 凭据有问题，或目标 Worker 不存在（拒绝自动创建） |

---

## License

MIT
