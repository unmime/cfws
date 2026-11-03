#!/usr/bin/env bash
#
# cfws 安装脚本 —— 交互式生成配置并安装定时任务
#
# 用法：sudo ./install.sh
#
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行：sudo $0" >&2
  exit 1
fi

CFG_DIR=/etc/cfws
STATE_ROOT=/var/lib/cfws
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo " cfws 安装 —— 自动更新 Cloudflare Worker"
echo "======================================"
echo

read -r -p "Worker 名称（与 Cloudflare 上的脚本名一致）: " WORKER
[ -z "$WORKER" ] && { echo "不能为空"; exit 1; }

read -r -p "Cloudflare Account ID: " ACCOUNT_ID
[ -z "$ACCOUNT_ID" ] && { echo "不能为空"; exit 1; }

echo
echo "这个 Worker 是否带静态资源（assets）或需要构建？"
echo "  - 纯 JS、上游就是一个 .js 文件        → 选 N（direct 模式，零依赖）"
echo "  - Next / Nuxt / Vue / 带前端资源       → 选 Y（wrangler 模式，需 node + git）"
read -r -p "需要构建或带静态资源？[y/N] " NEED_BUILD

MODE=direct
CONF_EXTRA=""

if [ "$NEED_BUILD" = "y" ] || [ "$NEED_BUILD" = "Y" ]; then
  MODE=wrangler

  echo
  read -r -p "源码 git 仓库地址（留空则用本地目录）: " SRC_GIT
  if [ -n "$SRC_GIT" ]; then
    read -r -p "分支 [main]: " SRC_REF
    SRC_REF="${SRC_REF:-main}"
    CONF_EXTRA="SRC_GIT=${SRC_GIT}
SRC_REF=${SRC_REF}"
  else
    read -r -p "本地源码目录绝对路径: " SRC_DIR
    [ -d "$SRC_DIR" ] || { echo "目录不存在: $SRC_DIR"; exit 1; }
    CONF_EXTRA="SRC_DIR=${SRC_DIR}"
  fi

  echo
  echo "构建命令（不需要构建直接回车）。含空格必须整体加引号，例如："
  echo '  "pnpm install && pnpm build"'
  read -r -p "BUILD_CMD: " BUILD_CMD
  [ -n "$BUILD_CMD" ] && CONF_EXTRA="${CONF_EXTRA}
BUILD_CMD=${BUILD_CMD}"

  read -r -p "wrangler 配置文件路径（留空用目录默认）: " WRANGLER_CONFIG
  [ -n "$WRANGLER_CONFIG" ] && CONF_EXTRA="${CONF_EXTRA}
WRANGLER_CONFIG=${WRANGLER_CONFIG}"

  command -v node >/dev/null 2>&1 || echo "⚠️  未检测到 node，wrangler 模式会失败"
  command -v git  >/dev/null 2>&1 || echo "⚠️  未检测到 git"
else
  echo
  read -r -p "上游地址（raw js 链接，或 .tar.gz 链接）: " UPSTREAM_URL
  [ -z "$UPSTREAM_URL" ] && { echo "不能为空"; exit 1; }

  read -r -p "入口文件名 [main.js]: " MAIN_MODULE
  MAIN_MODULE="${MAIN_MODULE:-main.js}"

  read -r -p "兼容日期 compatibility_date [2025-01-01]: " COMPAT_DATE
  COMPAT_DATE="${COMPAT_DATE:-2025-01-01}"

  read -r -p "compatibility_flags [nodejs_compat]: " COMPAT_FLAGS
  COMPAT_FLAGS="${COMPAT_FLAGS:-nodejs_compat}"

  CONF_EXTRA="UPSTREAM_URL=${UPSTREAM_URL}
MAIN_MODULE=${MAIN_MODULE}
COMPAT_DATE=${COMPAT_DATE}
COMPAT_FLAGS=${COMPAT_FLAGS}"
fi

echo
read -r -p "健康检查 URL（留空则跳过）: " VERIFY_URL
VERIFY_EXPECT=""
if [ -n "$VERIFY_URL" ]; then
  read -r -p "健康检查应包含的内容（如 pong，留空只要求有响应）: " VERIFY_EXPECT
fi

read -r -p "定时表达式（cron，默认每周日 04:17）[17 4 * * 0]: " SCHED
SCHED="${SCHED:-17 4 * * 0}"

echo
echo "Cloudflare API Token 权限建议："
echo "  Account → Workers Scripts → Edit"
echo "  Account → D1 → Read（目标 Worker 绑了 D1 时）"
echo "Account Resources 只勾这一个账号。"
echo
read -r -s -p "粘贴 API Token（输入不回显）: " CF_TOKEN
echo
[ -z "$CF_TOKEN" ] && { echo "Token 不能为空"; exit 1; }

echo
echo "即将写入："
echo "  $CFG_DIR/${WORKER}.conf   （模式 $MODE）"
echo "  $CFG_DIR/cf.token         （600，仅 root）"
echo "  /etc/cron.d/cfws-${WORKER}"
echo "  $STATE_ROOT/${WORKER}/"
echo
read -r -p "确认？[y/N] " OK
[ "$OK" = "y" ] || [ "$OK" = "Y" ] || { echo "已取消"; exit 1; }

install -d -m 700 "$CFG_DIR" "$STATE_ROOT/${WORKER}"

printf '%s\n' "$CF_TOKEN" > "$CFG_DIR/cf.token"
chmod 600 "$CFG_DIR/cf.token"
chown root:root "$CFG_DIR/cf.token"

cat > "$CFG_DIR/${WORKER}.conf" <<CONF
# cfws 配置 —— 由 install.sh 生成
WORKER=${WORKER}
ACCOUNT_ID=${ACCOUNT_ID}
MODE=${MODE}

CF_TOKEN_FILE=${CFG_DIR}/cf.token

${CONF_EXTRA}

VERIFY_URL=${VERIFY_URL}
VERIFY_EXPECT=${VERIFY_EXPECT}

STATE_DIR=${STATE_ROOT}/${WORKER}
CONF
chmod 600 "$CFG_DIR/${WORKER}.conf"

install -m 755 "$SELF_DIR/cfws.sh" /usr/local/bin/cfws

cat > "/etc/cron.d/cfws-${WORKER}" <<CRON
# cfws: 自动更新 Worker ${WORKER}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${SCHED} root /usr/local/bin/cfws ${CFG_DIR}/${WORKER}.conf >> /var/log/cfws-${WORKER}.log 2>&1
CRON
chmod 644 "/etc/cron.d/cfws-${WORKER}"

echo
echo "首次运行……"
/usr/local/bin/cfws "$CFG_DIR/${WORKER}.conf"
RC=$?

echo
if [ $RC -eq 0 ]; then
  echo "✅ 安装完成。日志：/var/log/cfws-${WORKER}.log"
  echo "   手动触发：sudo cfws $CFG_DIR/${WORKER}.conf"
else
  echo "⚠️  首次运行返回 $RC，请查看上面的输出与日志。"
fi
