#!/bin/bash
# checkRisk.sh のオフラインテスト（AWS にも OpenAI にも接続しない）
#
#   bash tests/run.sh                 … 全テスト
#   UPDATE_GOLDEN=1 bash tests/run.sh … 期待出力（tests/golden/*.md）を現在の出力で更新
#
# 仕組み:
#   - PATH の先頭に tests/fake-aws を置き、aws コマンドをフィクスチャ応答に差し替える
#   - OpenAI API は tests/fake_openai.py（ローカル HTTP サーバー）に差し替える
#   - CHECKRISK_NOW_EPOCH で「現在時刻」を固定し、経過日数の判定を決定的にする
# 必要なもの: bash, jq, python3（fake_aws.py には jmespath が必要。無ければ AWS CLI 同梱の python を自動で探す）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/checkRisk.sh"
GOLDEN="$HERE/golden"
NOW_EPOCH=1789776000   # 2026-09-19T00:00:00Z。フィクスチャの日付はこれを基準に作ってある
DUMMY_KEY="test-dummy-not-a-real-key"   # fixtures/sample/secretsmanager の値と一致させる

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $*"; }
ng(){ FAIL=$((FAIL+1)); echo "  ❌ $*"; }
check(){ # check <説明> <コマンド…>  … コマンドが成功すれば OK
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$msg"; else ng "$msg"; fi
}

# ---- jmespath が使える python を探す ------------------------------------
find_python(){
  local py cand
  for cand in "${FAKE_AWS_PYTHON:-}" python3 "$(brew --prefix awscli 2>/dev/null || true)/libexec/bin/python3"; do
    [ -n "$cand" ] || continue
    py="$(command -v "$cand" 2>/dev/null || true)"; [ -n "$py" ] || continue
    "$py" -c 'import jmespath' >/dev/null 2>&1 && { echo "$py"; return 0; }
  done
  return 1
}
if ! FAKE_AWS_PYTHON="$(find_python)"; then
  echo "❌ jmespath を import できる python が見つかりません。pip install jmespath するか、FAKE_AWS_PYTHON を指定してください" >&2
  exit 1
fi
export FAKE_AWS_PYTHON
echo "fake-aws python: $FAKE_AWS_PYTHON"

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup(){
  if [ -n "$SERVER_PID" ]; then
    { kill "$SERVER_PID" && wait "$SERVER_PID"; } 2>/dev/null || true   # wait で「Terminated」通知を出さない
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 0. 静的チェック ------------------------------------------------------
echo "== 静的チェック =="
check "bash -n（構文）" bash -n "$SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck" shellcheck -s bash "$SCRIPT"
else
  echo "  ⏭  shellcheck 未インストール（brew install shellcheck）"
fi

# ---- シナリオ実行 ----------------------------------------------------------
# run_scenario <名前> <フィクスチャdir> [追加の環境変数 KEY=VALUE …]
# 結果: $WORK/<名前>/{report.md,calls.log,stdout.txt,stderr.txt,exit}
run_scenario(){
  local name="$1" fixtures="$2"; shift 2
  local dir="$WORK/$name"; mkdir -p "$dir/cwd"
  ( cd "$dir/cwd" && \
    env PATH="$HERE/fake-aws:$PATH" FAKE_AWS_FIXTURES="$fixtures" FAKE_AWS_LOG="$dir/calls.log" \
        CHECKRISK_NOW_EPOCH="$NOW_EPOCH" AWS_REGION=ap-northeast-1 "$@" \
        bash "$SCRIPT" >"$dir/stdout.txt" 2>"$dir/stderr.txt"; echo $? >"$dir/exit" )
  cp "$dir"/cwd/output/checkRiskReport_*[0-9].md "$dir/report.md" 2>/dev/null || : >"$dir/report.md"
}
normalize(){ sed -E '/^- 生成\(JST\)/d' "$1"; }   # 生成時刻だけ揺れるので除く
golden_check(){ # golden_check <名前>
  local name="$1" got="$WORK/$1/report.md" want="$GOLDEN/$1.md"
  if [ "${UPDATE_GOLDEN:-0}" = "1" ]; then
    mkdir -p "$GOLDEN"; normalize "$got" >"$want"; ok "golden 更新: tests/golden/$name.md"; return
  fi
  if [ ! -f "$want" ]; then ng "golden がありません: tests/golden/$name.md（UPDATE_GOLDEN=1 で作成）"; return; fi
  if diff -u "$want" <(normalize "$got") >"$WORK/$name.diff"; then ok "レポートが golden と一致（$name）"
  else ng "レポートが golden と異なる（$name）"; sed 's/^/     /' "$WORK/$name.diff" | head -40; fi
}
readonly_check(){ # 呼び出した API がすべて読み取り系か
  local bad; bad="$(awk '{print $1" "$2}' "$1" | grep -vE '^[a-z0-9]+ (list|describe|get|batch-get|generate-credential-report)' || true)"
  [ -z "$bad" ]
}

# ---- 1. 指摘の多いサンプルアカウント ------------------------------------
echo "== シナリオ: sample（GPT なし） =="
run_scenario sample "$HERE/fixtures/sample"
check "exit 0" test "$(cat "$WORK/sample/exit")" = 0
check "stderr が空" test ! -s "$WORK/sample/stderr.txt"
check "読み取り系 API しか呼んでいない" readonly_check "$WORK/sample/calls.log"
check "GPT なしでは Secrets Manager を呼ばない" test "$(grep -c '^secretsmanager' "$WORK/sample/calls.log")" = 0
check "Credential Report: 実際に未使用の svc-batch だけを検出" grep -q '^| svc-batch | 250 |' "$WORK/sample/report.md"
check "Credential Report: 直近に使った alice は検出しない" bash -c "! grep -q '^| alice | .* 最終活動>90日' '$WORK/sample/report.md'"
check "アクセスキー: +00:00 形式の日付を解釈して >90日 を検出" grep -q '^| svc-batch | MFA=0, Admin=no | .*キー作成>90日.*最終使用>90日' "$WORK/sample/report.md"
check "EBS: 暗号化済みだけのインスタンスは OK" grep -q '^| i-0bbb222 | None | OK | required' "$WORK/sample/report.md"
check "EBS: 未暗号化ボリュームを個別に検出" grep -q 'EBS暗号化なし(vol-0a2)' "$WORK/sample/report.md"
check "CloudTrail: ログ群の保持日数を読める（ARN 末尾 :* の除去）" grep -q '^| trail-main | true | true | True | 90 |' "$WORK/sample/report.md"
check "CloudTrail: 他リージョンがホームの Trail を ARN で解決" grep -q '^| org-trail-shadow | true | true | True |' "$WORK/sample/report.md"
check "GuardDuty: Findings 件数を読める（FindingIds）" grep -q '^| det-1 | 2 | 1 |' "$WORK/sample/report.md"
check "集計: サブシェルで失われていた件数を含む（High=17）" grep -q '^- High:     17$' "$WORK/sample/report.md"
check "CodeBuild: 'PROJECTS' を名前として問い合わせない" bash -c "! grep -q 'batch-get-projects --names PROJECTS' '$WORK/sample/calls.log'"
golden_check sample

# ---- 2. 指摘がゼロのアカウント --------------------------------------------
echo "== シナリオ: empty（指摘なし） =="
run_scenario empty "$HERE/fixtures/empty"
check "exit 0" test "$(cat "$WORK/empty/exit")" = 0
check "空のセクションに「該当なし」行が入る" grep -q '^| 該当なし | - | - | - | - | - | - | - | - |$' "$WORK/empty/report.md"
check "Critical/High が 0" bash -c "grep -q '^- Critical: 0$' '$WORK/empty/report.md' && grep -q '^- High:     0$' '$WORK/empty/report.md'"
golden_check empty

# ---- 3. GPT 整形あり（偽 OpenAI サーバー） -------------------------------
echo "== シナリオ: gpt（POLISH_WITH_OPENAI=1） =="
FAKE_OPENAI_LOG="$WORK/openai.log" python3 "$HERE/fake_openai.py" 0 >"$WORK/openai.port" 2>"$WORK/openai.err" &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$WORK/openai.port" ] && break; python3 -c 'import time; time.sleep(0.25)'
done
PORT="$(cat "$WORK/openai.port" 2>/dev/null || true)"
if [ -z "$PORT" ]; then ng "偽 OpenAI サーバーが起動しない"; else
  run_scenario gpt "$HERE/fixtures/sample" POLISH_WITH_OPENAI=1 OPENAI_API_BASE="http://127.0.0.1:$PORT"
  check "exit 0" test "$(cat "$WORK/gpt/exit")" = 0
  check "整形レポートが生成される" bash -c "ls '$WORK'/gpt/cwd/output/*_polished.md >/dev/null"
  check "Secrets Manager の取得は API キー 1 件だけ" test "$(grep -c '^secretsmanager get-secret-value' "$WORK/gpt/calls.log")" = 1
  check "API キーが Authorization ヘッダで届く" python3 - "$WORK/openai.log" "$DUMMY_KEY" <<'PY'
import json, sys
req = json.loads(open(sys.argv[1], encoding="utf-8").readline())
sys.exit(0 if req["authorization"] == "Bearer " + sys.argv[2] else 1)
PY
  check "LLM へ送る本文がマスク済み（アカウントID/IPv4/アクセスキーID/ARN）" python3 - "$WORK/openai.log" <<'PY'
import json, re, sys
req = json.loads(open(sys.argv[1], encoding="utf-8").readline())
msg = json.loads(req["body"])["messages"][1]["content"]
leaks = [p for p in ["111122223333", "203.0.113.10", r"AKIA[A-Z0-9]{16}", r"arn:aws:iam::\d{12}"] if re.search(p, msg)]
sys.exit(1 if leaks else 0)
PY
fi

echo
echo "== 結果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
