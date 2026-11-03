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

read -r -p "上游地址（raw js 链接，或 .tar.gz 链接）: " UPSTREAM_URL
[ -z "$UPSTREAM_URL" ] && { echo "不能为空"; exit 1; }

UPSTREAM_TYPE=raw
case "$UPSTREAM_URL" in
  *.tar.gz|*.tgz) UPSTREAM_TYPE=tarball ;;
esac

read -r -p "入口文件名 [main.js]: " MAIN_MODULE
MAIN_MODULE="${MAIN_MODULE:-main.js}"

read -r -p "兼容日期 compatibility_date [2025-01-01]: " COMPAT_DATE
COMPAT_DATE="${COMPAT_DATE:-2025-01-01}"

read -r -p "compatibility_flags [nodejs_compat]: " COMPAT_FLAGS
COMPAT_FLAGS="${COMPAT_FLAGS:-nodejs_compat}"

read -r -p "健康检查 URL（留空则跳过）: " VERIFY_URL
VERIFY_EXPECT=""
if [ -n "$VERIFY_URL" ]; then
  read -r -p "健康检查应包含的内容（如 pong，留空只要求 HTTP 200）: " VERIFY_EXPECT
fi

read -r -p "定时表达式（cron，默认每周日 04:17）[17 4 * * 0]: " SCHED
SCHED="${SCHED:-17 4 * * 0}"

echo
echo "Cloudflare API Token 需要在后台创建，权限建议："
echo "  Account → Workers Scripts → Edit"
echo "  Account → D1 → Read（如果 Worker 绑定了 D1）"
echo "Account Resources 只勾这一个账号。"
echo
read -r -s -p "粘贴 API Token（输入不回显）: " CF_TOKEN
echo
[ -z "$CF_TOKEN" ] && { echo "Token 不能为空"; exit 1; }

echo
echo "即将写入："
echo "  $CFG_DIR/${WORKER}.conf"
echo "  $CFG_DIR/cf.token      （600，仅 root）"
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

CF_TOKEN_FILE=${CFG_DIR}/cf.token

UPSTREAM_URL=${UPSTREAM_URL}
UPSTREAM_TYPE=${UPSTREAM_TYPE}
MAIN_MODULE=${MAIN_MODULE}
COMPAT_DATE=${COMPAT_DATE}
COMPAT_FLAGS=${COMPAT_FLAGS}

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
echo "首次运行（会立刻部署一次当前上游版本）……"
/usr/local/bin/cfws "$CFG_DIR/${WORKER}.conf"
RC=$?

echo
if [ $RC -eq 0 ]; then
  echo "✅ 安装完成。日志：/var/log/cfws-${WORKER}.log"
  echo "   手动触发：sudo cfws $CFG_DIR/${WORKER}.conf"
else
  echo "⚠️  首次运行返回 $RC，请查看上面的输出与日志。"
fi
