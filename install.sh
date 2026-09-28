#!/usr/bin/env bash
# lark-channel-bridge 一键安装
#
#   curl -fsSL https://raw.githubusercontent.com/Minerva67/lark-coding-agent-bridge/main/install.sh | bash
#
# 做的事（全程不需要 sudo，不改系统目录）：
#   1. Node >= 20.12：没有就下载一份放到 ~/.lark-bridge-runtime/node
#   2. 把 lark-channel-bridge + lark-cli 装到 ~/.lark-bridge-runtime/npm（不会 EACCES）
#   3. 检查 Claude Code（或 Codex）已安装且已登录，没登录就当场带你登录
#   4. 扫码绑定飞书机器人，并注册为开机自启的后台服务
#   5. 自检：确认后台服务在跑，告诉你去飞书发第一句话
#
# 可选环境变量：
#   AGENT=codex          用 Codex 代替 Claude Code（默认 claude）
#   PROFILE=claude       bridge profile 名（默认与 AGENT 相同）
#   NPM_REGISTRY=...     指定 npm 源；不设时自动探测，npmjs 不通就用 npmmirror
#   NODE_MIRROR=...      指定 Node 下载源；不设时自动探测
#   SKIP_RC=1            不往 ~/.zshrc / ~/.bashrc 写 PATH

set -euo pipefail

RUNTIME_DIR="${LARK_BRIDGE_RUNTIME:-$HOME/.lark-bridge-runtime}"
NODE_DIR="$RUNTIME_DIR/node"
NPM_PREFIX="$RUNTIME_DIR/npm"
AGENT="${AGENT:-claude}"
PROFILE="${PROFILE:-$AGENT}"
MIN_NODE="20.12.0"
NODE_MAJOR="22"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
step() { printf '\n%s▸ %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# `curl | bash` 时 stdin 是管道，交互步骤（登录、扫码确认）要从终端读
if [ -t 0 ]; then TTY=/dev/stdin
elif (exec </dev/tty) 2>/dev/null; then TTY=/dev/tty
else die "需要在终端里运行（扫码和登录要交互）。"
fi

case "$AGENT" in claude|codex) ;; *) die "AGENT 只能是 claude 或 codex，当前是：$AGENT" ;; esac

OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS" in
  Darwin) NODE_OS=darwin ;;
  Linux)  NODE_OS=linux ;;
  *) die "暂不支持 $OS。Windows 请在 PowerShell 用：npm i -g lark-channel-bridge && lark-channel-bridge start" ;;
esac
case "$ARCH" in
  arm64|aarch64) NODE_ARCH=arm64 ;;
  x86_64|amd64)  NODE_ARCH=x64 ;;
  *) die "暂不支持的 CPU 架构：$ARCH" ;;
esac

printf '%slark-channel-bridge 一键安装%s  %s(%s/%s, agent=%s)%s\n' "$BOLD" "$RESET" "$DIM" "$OS" "$ARCH" "$AGENT" "$RESET"

# 本脚本自己的目录优先：保证后面用到的 node / npm / bridge 都是我们装的这份，
# bridge 注册后台服务时会把当前 PATH 写进 launchd/systemd，daemon 也能找到它们。
export PATH="$NPM_PREFIX/bin:$NODE_DIR/bin:$PATH"
export NPM_CONFIG_PREFIX="$NPM_PREFIX"   # bridge 内部自动装 lark-cli 时也落到这里
mkdir -p "$RUNTIME_DIR" "$NPM_PREFIX"

reachable() { curl -fsS -o /dev/null --max-time 6 "$1" 2>/dev/null; }

version_ge() {  # version_ge 20.15.1 20.12.0
  local IFS=.; local a=($1) b=($2) i
  for i in 0 1 2; do
    [ "${a[i]:-0}" -gt "${b[i]:-0}" ] && return 0
    [ "${a[i]:-0}" -lt "${b[i]:-0}" ] && return 1
  done
  return 0
}

# ── 1. Node ────────────────────────────────────────────────────────────────
step "1/5 检查 Node.js"
node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local v; v="$(node -v 2>/dev/null | sed 's/^v//')"
  [ -n "$v" ] && version_ge "$v" "$MIN_NODE"
}

if node_ok; then
  ok "Node $(node -v)（$(command -v node)）"
else
  if command -v node >/dev/null 2>&1; then
    warn "现有 Node $(node -v) 太旧（需要 >= $MIN_NODE），另装一份到 $NODE_DIR，不影响原来的"
  else
    warn "没找到 Node，下载一份到 $NODE_DIR"
  fi
  if [ -n "${NODE_MIRROR:-}" ]; then mirror="$NODE_MIRROR"
  elif reachable "https://nodejs.org/dist/index.json"; then mirror="https://nodejs.org/dist"
  else mirror="https://npmmirror.com/mirrors/node"
  fi
  base="$mirror/latest-v$NODE_MAJOR.x"
  sums="$(curl -fsSL --max-time 30 "$base/SHASUMS256.txt")" || die "下载 Node 版本列表失败：$base"
  line="$(printf '%s\n' "$sums" | grep -E " node-v[0-9.]+-$NODE_OS-$NODE_ARCH\.tar\.gz$" | head -1)"
  [ -n "$line" ] || die "找不到 $NODE_OS-$NODE_ARCH 的 Node 安装包"
  sha="${line%% *}"; file="${line##* }"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  printf '  下载 %s …\n' "$file"
  curl -fL --progress-bar "$base/$file" -o "$tmp/$file" || die "下载 Node 失败"
  if command -v shasum >/dev/null 2>&1; then got="$(shasum -a 256 "$tmp/$file" | cut -d' ' -f1)"
  else got="$(sha256sum "$tmp/$file" | cut -d' ' -f1)"
  fi
  [ "$got" = "$sha" ] || die "Node 安装包校验失败（sha256 不匹配），请重试"
  rm -rf "$NODE_DIR"; mkdir -p "$NODE_DIR"
  tar -xzf "$tmp/$file" -C "$NODE_DIR" --strip-components=1
  hash -r
  node_ok || die "Node 安装后仍不可用"
  ok "Node $(node -v)（$NODE_DIR）"
fi

# ── 2. bridge + lark-cli ───────────────────────────────────────────────────
step "2/5 安装 lark-channel-bridge"
if [ -n "${NPM_REGISTRY:-}" ]; then registry="$NPM_REGISTRY"
elif reachable "https://registry.npmjs.org/lark-channel-bridge"; then registry="https://registry.npmjs.org/"
else registry="https://registry.npmmirror.com/"; warn "npmjs 不通，改用 npmmirror"
fi
export NPM_CONFIG_REGISTRY="$registry"

npm_install() {
  local log; log="$(mktemp)"
  if ! npm install -g --no-fund --no-audit --loglevel=error "$@" >"$log" 2>&1; then
    cat "$log" >&2; rm -f "$log"; die "npm install $* 失败"
  fi
  rm -f "$log"
}
npm_install lark-channel-bridge@latest @larksuite/cli@latest
BRIDGE="$NPM_PREFIX/bin/lark-channel-bridge"
[ -x "$BRIDGE" ] || die "安装完成但找不到 $BRIDGE"
ok "lark-channel-bridge $("$BRIDGE" --version 2>/dev/null || echo '?')"
ok "lark-cli（飞书能力）已就绪"

# 写 PATH 到 shell 配置，以后开新终端直接能用 lark-channel-bridge
if [ "${SKIP_RC:-0}" != "1" ]; then
  marker="# lark-channel-bridge (added by install.sh)"
  line="export PATH=\"$NPM_PREFIX/bin:$NODE_DIR/bin:\$PATH\""
  case "${SHELL:-}" in
    */zsh)  rcs=("$HOME/.zshrc") ;;
    */bash) rcs=("$HOME/.bashrc" "$HOME/.bash_profile") ;;
    *)      rcs=("$HOME/.profile") ;;
  esac
  for rc in "${rcs[@]}"; do
    [ -f "$rc" ] || [ "$rc" = "${rcs[0]}" ] || continue
    if ! grep -qF "$marker" "$rc" 2>/dev/null; then
      printf '\n%s\n%s\n' "$marker" "$line" >>"$rc"
      ok "已把命令路径写进 ${rc/#$HOME/~}"
    fi
  done
fi

# ── 3. agent 安装 + 登录 ───────────────────────────────────────────────────
step "3/5 检查 $AGENT 是否安装并登录"
# 在 Claude Code 会话里运行本脚本时，去掉嵌套检测变量，否则 claude 子进程拒绝启动
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

if [ "$AGENT" = claude ]; then
  if ! command -v claude >/dev/null 2>&1; then
    warn "没找到 claude，正在安装 Claude Code"
    npm_install @anthropic-ai/claude-code@latest
  fi
  ok "claude $(claude --version 2>/dev/null | head -1)"

  claude_logged_in() {
    local out
    out="$(claude auth status --json 2>/dev/null)" || true
    printf '%s' "$out" | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true'
  }
  if claude_logged_in; then
    ok "Claude 已登录"
  else
    warn "Claude 还没登录。飞书机器人要靠它回复，现在先登录一次（会打开浏览器授权）"
    claude auth login <"$TTY" || true
    if ! claude_logged_in; then
      warn "自动登录没完成，改用交互方式：在打开的界面里输入 /login，登录成功后输入 /exit"
      claude <"$TTY" || true
    fi
    claude_logged_in || die "Claude 仍未登录。请运行 claude → 输入 /login，完成后重新执行本安装命令"
    ok "Claude 已登录"
  fi
else
  if ! command -v codex >/dev/null 2>&1; then
    warn "没找到 codex，正在安装 Codex CLI"
    npm_install @openai/codex@latest
  fi
  ok "codex $(codex --version 2>/dev/null | head -1)"
  if codex login status >/dev/null 2>&1; then
    ok "Codex 已登录"
  else
    warn "Codex 还没登录，现在登录一次"
    codex login <"$TTY" || true
    codex login status >/dev/null 2>&1 || die "Codex 仍未登录。请运行 codex login，完成后重新执行本安装命令"
    ok "Codex 已登录"
  fi
fi

# ── 4. 扫码绑定 + 后台服务 ────────────────────────────────────────────────
step "4/5 绑定飞书机器人并转为后台常驻"
# 重复安装时先停掉旧的后台服务，避免「已有 bridge 进程占用 [y/N]」卡住
"$BRIDGE" stop --profile "$PROFILE" >/dev/null 2>&1 || true

if [ -f "$HOME/.lark-channel/config.json" ] && grep -q "\"$PROFILE\"" "$HOME/.lark-channel/config.json" 2>/dev/null; then
  ok "检测到已绑定的机器人（profile: $PROFILE），直接启动"
else
  printf '  接下来终端会出现二维码：%s用飞书 App 扫码%s → 选择或新建一个 PersonalAgent 应用。\n' "$BOLD" "$RESET"
fi
printf '  %s（如果提示「已有 bridge 进程占用，是否停止」，输入 y 回车即可）%s\n' "$DIM" "$RESET"
"$BRIDGE" start --profile "$PROFILE" --agent "$AGENT" <"$TTY" \
  || die "后台服务启动失败。日志：~/.lark-channel/profiles/$PROFILE/logs/daemon/"

# ── 5. 自检 ────────────────────────────────────────────────────────────────
step "5/5 自检"
status="$("$BRIDGE" status --profile "$PROFILE" 2>&1 || true)"
if printf '%s' "$status" | grep -q "正在后台运行\|running"; then
  ok "$(printf '%s' "$status" | head -1 | sed 's/^✓ //')"
else
  printf '%s\n' "$status"
  die "后台服务没有跑起来。日志：~/.lark-channel/profiles/$PROFILE/logs/daemon/"
fi

cat <<EOF

${GREEN}${BOLD}✓ 安装完成${RESET}

  现在打开飞书，给刚创建的机器人发一句「你好」，收到回复就说明接通了。

  常用：
    飞书里发  /cd <项目路径>   让它在你的项目目录里干活（默认不是你的项目）
    飞书里发  /help            查看全部指令
    终端里    lark-channel-bridge status | restart | stop

  电脑开着、不休眠，机器人就一直在线；开机会自动启动。
  它能在你电脑上读写文件、执行命令——建议只私聊使用，别拉进有外人的群。
EOF
