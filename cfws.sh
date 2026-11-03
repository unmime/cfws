#!/usr/bin/env bash
#
# cfws — 跟随上游自动更新 Cloudflare Worker
#
# 两种模式（不配 MODE 时自动推断）：
#   direct    拉单个 JS 文件 / tarball 直接上传。零依赖，只适合「无构建、无静态资源」的 Worker
#   wrangler  从 git 仓库或本地目录取源码，可选构建，再交给 wrangler 部署。
#             覆盖带静态资源（assets）和需要构建（Next/Nuxt/Vue）的项目。依赖 node + git
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

CF_TOKEN_FILE="${CF_TOKEN_FILE:-/etc/cfws/cf.token}"
if [ ! -r "$CF_TOKEN_FILE" ]; then
  echo "读不到 token 文件: $CF_TOKEN_FILE（应只含一行 Cloudflare API Token）" >&2
  exit 2
fi
CF_TOKEN="$(tr -d '\r\n' < "$CF_TOKEN_FILE")"

MAIN_MODULE="${MAIN_MODULE:-main.js}"
COMPAT_DATE="${COMPAT_DATE:-2025-01-01}"
COMPAT_FLAGS="${COMPAT_FLAGS:-nodejs_compat}"
KEEP_BINDINGS="${KEEP_BINDINGS:-d1,plain_text,kv_namespace,secret_text}"
VERIFY_URL="${VERIFY_URL:-}"
VERIFY_EXPECT="${VERIFY_EXPECT:-}"
STATE_DIR="${STATE_DIR:-/var/lib/cfws/${WORKER}}"
HASH_FILE="${STATE_DIR}/current.sha"
MIN_BYTES="${MIN_BYTES:-2000}"
ALLOW_CREATE="${ALLOW_CREATE:-false}"

# 模式推断：配了构建命令或源码来源就走 wrangler，否则直接传文件
if [ -z "${MODE:-}" ]; then
  if [ -n "${BUILD_CMD:-}" ] || [ -n "${SRC_GIT:-}" ] || [ -n "${SRC_DIR:-}" ]; then
    MODE=wrangler
  else
    MODE=direct
  fi
fi

to_json_array() {
  printf '%s' "$1" | tr -d ' ' | awk -F',' '{out=""; for(i=1;i<=NF;i++){if($i!=""){out=out (out?",":"") "\"" $i "\""}} print "[" out "]"}'
}

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${WORKER}" "$*"; }

# 部署前确认目标 Worker 存在：PUT 对不存在的名字会直接新建，拼错就静默多出一个空 Worker
require_existing_worker() {
  [ "$ALLOW_CREATE" = "true" ] && { log "ALLOW_CREATE=true，跳过存在性检查"; return 0; }
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER}")
  case "$code" in
    200) return 0 ;;
    404) log "Worker「${WORKER}」不存在。确认要新建请设 ALLOW_CREATE=true"; exit 2 ;;
    401|403) log "认证失败（HTTP ${code}），检查 token 权限"; exit 2 ;;
    *) log "查询 Worker 失败（HTTP ${code}），跳过本次"; exit 1 ;;
  esac
}

# 部署后验证。失败返回 1，调用方据此决定是否记录版本
check_health() {
  if [ -z "$VERIFY_URL" ]; then
    log "未配置 VERIFY_URL，跳过健康检查"
    return 0
  fi
  local i body
  for i in 1 2 3 4 5; do
    body=$(curl -fsS --max-time 20 -A "cfws/1.0" "$VERIFY_URL" 2>/dev/null || true)
    if [ -z "$VERIFY_EXPECT" ]; then
      [ -n "$body" ] && { log "健康检查通过"; return 0; }
    elif printf '%s' "$body" | grep -qF "$VERIFY_EXPECT"; then
      log "健康检查通过"
      return 0
    fi
    sleep 3
  done
  log "健康检查失败（${VERIFY_URL} 未返回预期内容），不更新版本记录，下次会重试"
  return 1
}

mkdir -p "$STATE_DIR"

# ============================================================
# 模式一：wrangler —— 源码 + 可选构建 + wrangler 部署
# 覆盖带静态资源(assets)与需要构建的项目
# ============================================================
if [ "$MODE" = "wrangler" ]; then
  SRC_REF="${SRC_REF:-main}"
  WRANGLER_CONFIG="${WRANGLER_CONFIG:-}"
  WRANGLER_BIN="${WRANGLER_BIN:-npx --yes wrangler@4}"
  SRC_PATH="${STATE_DIR}/src"
  REMOTE_SHA=""

  if [ -n "${SRC_GIT:-}" ]; then
    command -v git >/dev/null 2>&1 || { log "wrangler 模式需要 git"; exit 2; }
    REMOTE_SHA=$(git ls-remote "$SRC_GIT" "refs/heads/${SRC_REF}" 2>/dev/null | awk '{print $1}')
    if [ -z "$REMOTE_SHA" ]; then
      log "读取远程分支失败: ${SRC_GIT} (${SRC_REF})"
      exit 1
    fi
    if [ "$REMOTE_SHA" = "$(head -c 64 "$HASH_FILE" 2>/dev/null || true)" ]; then
      log "无更新 (${REMOTE_SHA:0:12})"
      exit 0
    fi
    log "检测到更新: $(head -c 12 "$HASH_FILE" 2>/dev/null || echo none) -> ${REMOTE_SHA:0:12}"

    if [ -d "$SRC_PATH/.git" ]; then
      git -C "$SRC_PATH" fetch --depth 1 origin "$SRC_REF" >/dev/null 2>&1 || { log "git fetch 失败"; exit 1; }
      git -C "$SRC_PATH" reset --hard FETCH_HEAD >/dev/null 2>&1 || { log "git reset 失败"; exit 1; }
    else
      rm -rf "$SRC_PATH"
      git clone --depth 1 --branch "$SRC_REF" "$SRC_GIT" "$SRC_PATH" >/dev/null 2>&1 || { log "git clone 失败"; exit 1; }
    fi
  else
    SRC_PATH="${SRC_DIR:-}"
    if [ -z "$SRC_PATH" ] || [ ! -d "$SRC_PATH" ]; then
      log "wrangler 模式需要 SRC_GIT 或存在的 SRC_DIR"
      exit 2
    fi
    log "使用本地源码目录，跳过版本比对（每次都会构建部署）"
  fi

  # 先确认目标存在，再花时间构建（名字拼错时不该白跑一次构建）
  require_existing_worker

  if [ -n "${BUILD_CMD:-}" ]; then
    log "构建: ${BUILD_CMD}"
    ( cd "$SRC_PATH" && eval "$BUILD_CMD" ) || { log "构建失败"; exit 1; }
  fi

  export CLOUDFLARE_API_TOKEN="$CF_TOKEN"
  export CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID"

  log "调用 wrangler 部署"
  if [ -n "$WRANGLER_CONFIG" ]; then
    ( cd "$SRC_PATH" && $WRANGLER_BIN deploy --config "$WRANGLER_CONFIG" )
  else
    ( cd "$SRC_PATH" && $WRANGLER_BIN deploy )
  fi || { log "wrangler 部署失败"; exit 1; }

  check_health || exit 1
  [ -n "$REMOTE_SHA" ] && printf '%s\n' "$REMOTE_SHA" > "$HASH_FILE"
  log "完成${REMOTE_SHA:+ (${REMOTE_SHA:0:12})}"
  exit 0
fi

# ============================================================
# 模式二：direct —— 拉文件直接上传，零依赖
# 只适合「单/多模块 JS，无静态资源，无构建」
# ============================================================
: "${UPSTREAM_URL:?direct 模式缺 UPSTREAM_URL}"

if [ -z "${UPSTREAM_TYPE:-}" ]; then
  case "$UPSTREAM_URL" in
    *.tar.gz|*.tgz) UPSTREAM_TYPE=tarball ;;
    *)              UPSTREAM_TYPE=raw ;;
  esac
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! curl -fsS --max-time 60 -A "cfws/1.0" "$UPSTREAM_URL" -o "$WORK/src"; then
  log "拉取上游失败，跳过本次"
  exit 1
fi

SIZE=$(wc -c < "$WORK/src" | tr -d ' ')
if [ "$SIZE" -lt "$MIN_BYTES" ]; then
  log "上游内容异常（${SIZE} 字节 < ${MIN_BYTES}），跳过"
  exit 1
fi

if head -c 400 "$WORK/src" | grep -qiE '<!doctype html|<html'; then
  log "上游返回的是 HTML 页面而不是代码，跳过"
  exit 1
fi

NEW_HASH=$(sha256sum "$WORK/src" | awk '{print $1}')
OLD_HASH=$(head -c 64 "$HASH_FILE" 2>/dev/null || echo none)

if [ "$NEW_HASH" = "$OLD_HASH" ]; then
  log "无更新 (${NEW_HASH:0:12})"
  exit 0
fi

log "检测到更新: ${OLD_HASH:0:12} -> ${NEW_HASH:0:12}（${SIZE} 字节）"

MODULE_ARGS=()
MODULE_DIR="$WORK/modules"

case "$UPSTREAM_TYPE" in
  raw)
    if ! mkdir -p "$MODULE_DIR/$(dirname "$MAIN_MODULE")"; then
      log "创建模块目录失败: $MODULE_DIR"
      exit 1
    fi
    cp "$WORK/src" "$MODULE_DIR/$MAIN_MODULE" || { log "复制模块失败"; exit 1; }
    MODULE_ARGS+=(-F "${MAIN_MODULE}=@${MODULE_DIR}/${MAIN_MODULE};filename=${MAIN_MODULE};type=application/javascript+module")
    ;;
  tarball)
    mkdir -p "$MODULE_DIR" || { log "创建临时目录失败"; exit 1; }
    if ! tar -xzf "$WORK/src" -C "$MODULE_DIR" 2>/dev/null; then
      log "解压失败，跳过"
      exit 1
    fi
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

flags_json=$(to_json_array "$COMPAT_FLAGS")
keep_json=$(to_json_array "$KEEP_BINDINGS")

cat > "$WORK/meta.json" <<JSON
{
  "main_module": "${MAIN_MODULE}",
  "compatibility_date": "${COMPAT_DATE}",
  "compatibility_flags": ${flags_json},
  "keep_bindings": ${keep_json}
}
JSON

require_existing_worker

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
check_health || exit 1

printf '%s\n' "$NEW_HASH" > "$HASH_FILE"
log "完成 (${NEW_HASH:0:12})"
