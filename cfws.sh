#!/usr/bin/env bash
#
# cfws — 跟随上游自动更新 Cloudflare Worker
#
# 设计前提：只针对「纯 JS、无需构建」的 Worker。不处理 TypeScript、打包、npm 依赖。
# 依赖：bash + curl；tarball 模式额外需要 tar
#
# 用法：cfws.sh /etc/cfws/<worker>.conf
#
set -uo pipefail

CONF="${1:-}"
if [ -z "$CONF" ]; then
  echo "用法: $0 /etc/cfws/<worker>.conf" >&2
  exit 2
fi
if [ ! -f "$CONF" ]; then
  echo "配置文件不存在: $CONF" >&2
  exit 2
fi

# shellcheck disable=SC1090
. "$CONF"

: "${WORKER:?配置缺 WORKER}"
: "${ACCOUNT_ID:?配置缺 ACCOUNT_ID}"
: "${UPSTREAM_URL:?配置缺 UPSTREAM_URL}"

CF_TOKEN_FILE="${CF_TOKEN_FILE:-/etc/cfws/cf.token}"
if [ ! -r "$CF_TOKEN_FILE" ]; then
  echo "读不到 token 文件: $CF_TOKEN_FILE（应只含一行 Cloudflare API Token）" >&2
  exit 2
fi
CF_TOKEN="$(tr -d '\r\n' < "$CF_TOKEN_FILE")"

UPSTREAM_TYPE="${UPSTREAM_TYPE:-raw}"      # raw | tarball
MAIN_MODULE="${MAIN_MODULE:-main.js}"
COMPAT_DATE="${COMPAT_DATE:-2025-01-01}"
COMPAT_FLAGS="${COMPAT_FLAGS:-nodejs_compat}"
KEEP_BINDINGS="${KEEP_BINDINGS:-d1,plain_text,kv_namespace,secret_text}"
VERIFY_URL="${VERIFY_URL:-}"
VERIFY_EXPECT="${VERIFY_EXPECT:-}"
STATE_DIR="${STATE_DIR:-/var/lib/cfws/${WORKER}}"
HASH_FILE="${STATE_DIR}/current.sha"
MIN_BYTES="${MIN_BYTES:-2000}"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${WORKER}" "$*"; }

mkdir -p "$STATE_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------- 1. 拉取上游 ----------

if ! curl -fsS --max-time 60 -A "cfws/1.0" "$UPSTREAM_URL" -o "$WORK/src"; then
  log "拉取上游失败，跳过本次"
  exit 1
fi

SIZE=$(wc -c < "$WORK/src" | tr -d ' ')
# 体积下限：防止把 404 页面 / 登录页当成代码传上去
if [ "$SIZE" -lt "$MIN_BYTES" ]; then
  log "上游内容异常（${SIZE} 字节 < ${MIN_BYTES}），跳过"
  exit 1
fi

NEW_HASH=$(sha256sum "$WORK/src" | awk '{print $1}')
OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo none)

if [ "$NEW_HASH" = "$OLD_HASH" ]; then
  log "无更新 (${NEW_HASH:0:12})"
  exit 0
fi

log "检测到更新: ${OLD_HASH:0:12} -> ${NEW_HASH:0:12}（${SIZE} 字节）"

# ---------- 2. 准备上传文件 ----------

MODULE_ARGS=()

case "$UPSTREAM_TYPE" in
  raw)
    MODULE_DIR="$WORK/modules"
    mkdir -p "$MODULE_DIR/$(dirname "$MAIN_MODULE")" 2>/dev/null || true
    cp "$WORK/src" "$MODULE_DIR/$MAIN_MODULE"
    MODULE_ARGS+=(-F "${MAIN_MODULE}=@${MODULE_DIR}/${MAIN_MODULE};filename=${MAIN_MODULE};type=application/javascript+module")
    ;;
  tarball)
    MODULE_DIR="$WORK/modules"
    mkdir -p "$MODULE_DIR"
    if ! tar -xzf "$WORK/src" -C "$MODULE_DIR" 2>/dev/null; then
      log "解压失败，跳过"
      exit 1
    fi
    # 若压缩包顶层只有一个目录，则下移一层
    FIRST_DIR=$(find "$MODULE_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -n "$FIRST_DIR" ] && [ "$(find "$MODULE_DIR" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; then
      MODULE_DIR="$FIRST_DIR"
    fi
    while IFS= read -r f; do
      rel="${f#"$MODULE_DIR"/}"
      MODULE_ARGS+=(-F "${rel}=@${f};filename=${rel};type=application/javascript+module")
    done < <(find "$MODULE_DIR" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' \) | sort)
    if [ "${#MODULE_ARGS[@]}" -eq 0 ]; then
      log "压缩包里没有 js/mjs/wasm 文件，跳过"
      exit 1
    fi
    ;;
  *)
    log "未知 UPSTREAM_TYPE: $UPSTREAM_TYPE（只支持 raw / tarball）"
    exit 2
    ;;
esac

# ---------- 3. 构造 metadata ----------

flags_json=$(printf '%s' "$COMPAT_FLAGS" | tr -d ' ' | awk -F',' '{out=""; for(i=1;i<=NF;i++){if($i!=""){out=out (out?",":"") "\"" $i "\""}} print "[" out "]"}')
keep_json=$(printf '%s' "$KEEP_BINDINGS" | tr -d ' ' | awk -F',' '{out=""; for(i=1;i<=NF;i++){if($i!=""){out=out (out?",":"") "\"" $i "\""}} print "[" out "]"}')

cat > "$WORK/meta.json" <<JSON
{
  "main_module": "${MAIN_MODULE}",
  "compatibility_date": "${COMPAT_DATE}",
  "compatibility_flags": ${flags_json},
  "keep_bindings": ${keep_json}
}
JSON

# ---------- 4. 上传 ----------

RESP=$(curl -sS --max-time 120 -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER}" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -F "metadata=<${WORK}/meta.json" \
  "${MODULE_ARGS[@]}")

if ! printf '%s' "$RESP" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
  log "部署失败: $(printf '%s' "$RESP" | tr -d '\n' | head -c 400)"
  exit 1
fi

log "已上传，开始健康检查"

# ---------- 5. 验证 ----------

if [ -n "$VERIFY_URL" ]; then
  ok=0
  for _ in 1 2 3 4 5; do
    body=$(curl -fsS --max-time 20 -A "cfws/1.0" "$VERIFY_URL" 2>/dev/null || true)
    if [ -z "$VERIFY_EXPECT" ] || printf '%s' "$body" | grep -qF "$VERIFY_EXPECT"; then
      ok=1
      break
    fi
    sleep 3
  done
  if [ "$ok" -ne 1 ]; then
    log "健康检查失败（${VERIFY_URL} 未返回预期内容），不更新版本记录，下次会重试"
    exit 1
  fi
  log "健康检查通过"
else
  log "未配置 VERIFY_URL，跳过健康检查"
fi

# ---------- 6. 记录版本 ----------

printf '%s\n' "$NEW_HASH" > "$HASH_FILE"
log "完成 (${NEW_HASH:0:12})"
