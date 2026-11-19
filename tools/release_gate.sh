#!/usr/bin/env bash
# 发布护栏（V3-3，2026-11-19）：打 tag / 发 release 前必须三道门全绿。
# 门序快→慢：格式 → lint → 测试全量。任一门红即 exit 1 并指明哪道门。
# 用法：bash tools/release_gate.sh（在仓库任意目录均可，自动 cd 到仓库根）
set -u
cd "$(dirname "$0")/.." || exit 1

GDFORMAT="/c/Users/wgt/AppData/Roaming/Python/Python314/Scripts/gdformat.exe"
GDLINT="/c/Users/wgt/AppData/Roaming/Python/Python314/Scripts/gdlint.exe"
GODOT="/d/godot/Godot_v4.6.3-stable_win64_console.exe"
# Linux/CI 环境回退 PATH 查找
command -v gdformat >/dev/null 2>&1 && GDFORMAT="gdformat"
command -v gdlint >/dev/null 2>&1 && GDLINT="gdlint"

fail=0

echo "== 门① gdformat --check（格式基线）=="
if "$GDFORMAT" --check addons/; then
  echo "门① 绿"
else
  echo "门① 红：格式基线漂移——跑 gdformat addons/ 修复后重试"
  fail=1
fi

echo ""
echo "== 门② gdlint（规则见 .gdlintrc）=="
if "$GDLINT" addons/; then
  echo "门② 绿"
else
  echo "门② 红：lint 问题见上方输出"
  fail=1
fi

echo ""
echo "== 门③ 测试全量（SceneTree runner）=="
TEST_LOG="$(mktemp)"
if "$GODOT" --headless --path . --script res://tests/test_runner.gd >"$TEST_LOG" 2>&1; then
  tail -1 "$TEST_LOG"
  echo "门③ 绿"
else
  tail -5 "$TEST_LOG"
  echo "门③ 红：测试失败见上方输出"
  fail=1
fi
rm -f "$TEST_LOG"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "=== release_gate 全绿，允许打 tag ==="
else
  echo "=== release_gate 有红门，禁止打 tag ==="
fi
exit "$fail"
