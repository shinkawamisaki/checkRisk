#!/bin/bash
# checkRisk.sh — リスク要約レポート
# SPDX-License-Identifier: LicenseRef-Shinkawa-NC-1.1
# Shinkawa Non-Commercial License v1.1 (with Commercial Service Provider Exception)
# 最終更新: 2026-09-19
# 著作権表示: © 2025 Shinkawa. All rights reserved.
#
# 【適用範囲 / Scope】
# 本ライセンスは、このリポジトリの checkRisk.sh（および付随ドキュメント）に適用されます。
#
# 日本語条文
# 1. 定義
#   「非商用」とは、対価（直接・間接を問わず）を得ることを目的としない利用。
# 2. 許諾（非商用）
#   非商用に限り、使用・複製・改変・再配布（本ライセンス全文と帰属表示を保持、同一条件）を無償で許可。
# 3. 禁止（商用）
#   有償のコンサル・監査・導入/設定/保守・受託/納品での利用、有償製品への組込み、リブランディング転売、サブライセンスを禁止。
# 4. 例外（商用サービス提供者例外）
#   上記にかかわらず、**著作権者 Shinkawa（および著作権者が明示的に許諾した者）**は、
#   本ソフトウェアを用いた**有償の導入・設定・カスタマイズ・保守・マネージド運用**を第三者へ提供できます。
#   この例外は第三者への**サブライセンス権・商用再配布権**を与えるものではありません。
# 5. 商用ライセンス
#   商用利用が必要な場合は別途、著作権者と商用ライセンス契約を締結してください。
# 6. 帰属・通知
#   「© 2025 Shinkawa. All rights reserved. Licensed under Shinkawa Non-Commercial License v1.1.」を保持。
# 7. 免責
#   本ソフトウェアは「現状のまま」。いかなる保証も責任も負いません。
# 8. 終了
#   条項違反で自動終了。終了後は使用を停止。

# English (for convenience)
# 1. Grant (Non-commercial): Use/copy/modify/redistribute for non-commercial purposes only, keeping this license and attribution under the same terms.
# 2. Prohibited Uses: Any commercial use incl. paid consulting/audits/deployment/customization/support/managed services, inclusion in paid products, rebranding/reselling, sublicensing.
# 3. Commercial Service Provider Exception: **Licensor (Shinkawa) and parties explicitly authorized by the Licensor** may provide paid services using the Software. No sublicense or commercial redistribution rights to third parties.
# 4. Commercial License: Contact the Licensor for a separate commercial license.
# 5. Attribution/Notice: Keep “© 2025 Shinkawa. All rights reserved. Licensed under Shinkawa Non-Commercial License v1.1.”
# 6. Disclaimer & Termination: AS IS; breach terminates the license.

# ---------------------------------------------------------------------
# 使い方:  ./checkRisk.sh [region]
#   POLISH_WITH_OPENAI=1  … OpenAI API でレポートを整形（API キーは Secrets Manager から取得）
#   OPENAI_SECRET_NAME    … 上記キーのシークレット名（既定: openai/prod/key）
#   OPENAI_MODEL / OPENAI_MODEL_FALLBACK / OPENAI_API_BASE … 任意
#   CHECKRISK_NOW_EPOCH   … 「現在時刻」を固定する（テスト用）
# 依存: aws（CLI v2）, jq。bash 3.2（macOS 標準）でも動くように書く（連想配列・mapfile・$'\U…' は使わない）。
# ---------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'
umask 077

# 失敗時に行番号と直前コマンドを出す（BASH_LINENO[0] = ERR が起きた行）
on_err() {
  local ec=$?
  echo "❌ Error (exit=$ec) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  exit "$ec"
}
trap on_err ERR

export AWS_PAGER=""
export LANG=C
# AWSの再試行（標準）を強めに
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"

REGION="${1:-${AWS_REGION:-ap-northeast-1}}"; export AWS_REGION="$REGION"
NOW_EPOCH="${CHECKRISK_NOW_EPOCH:-$(date +%s)}"
DATE_JST="$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')"
DATE_TAG="$(TZ=Asia/Tokyo date '+%Y%m%d_%H%M%S')"
OUTDIR="output"; mkdir -p "$OUTDIR"; chmod 700 "$OUTDIR"
OUT="${OUTDIR}/checkRiskReport_${DATE_TAG}.md"
TMP="$(mktemp)"
# finish を仕掛けるまでの間に落ちても一時ファイルを残さない
trap 'rm -f "$TMP"' EXIT

echo "🐈 処理開始（region=${REGION}）"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ $1 が見つからない"; exit 1; }; }
need aws; need jq

# base64 デコード（GNU/BSD 両対応）
b64d(){ if base64 --help 2>&1 | grep -q -- '--decode'; then base64 --decode; else base64 -D; fi; }

# ---- 事前健全性チェック（認証・リージョン妥当性） -------------------
# アカウント ID はここで 1 回だけ取得し、以降で使い回す
if ! ACC="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  echo "❌ AWS 認証に失敗（プロファイル/環境変数を確認してください）" >&2
  exit 1
fi
# 指定リージョンが利用可能か軽く確認
aws ec2 describe-availability-zones --region "$REGION" --all-availability-zones >/dev/null 2>&1 || {
  echo "❌ 無効なリージョン指定: $REGION" >&2; exit 1; }

# ------------------ 任意: OpenAI API 連携（POLISH_WITH_OPENAI=1） ----
# API キーは「整形を有効にしたとき」だけ Secrets Manager から取得する。
# export はしない（aws/jq/curl 等の子プロセス環境に漏らさない）。curl へはヘッダファイル経由で渡し、
# コマンドライン引数（ps で見える）に載せない。
: "${OPENAI_SECRET_NAME:=openai/prod/key}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
export -n OPENAI_API_KEY 2>/dev/null || true

load_openai_key() {
  [ -n "$OPENAI_API_KEY" ] && return 0
  OPENAI_API_KEY="$(aws secretsmanager get-secret-value \
    --secret-id "$OPENAI_SECRET_NAME" \
    --query 'SecretString' --output text 2>/dev/null || true)"
}

# LLM に渡す前のマスク（アカウントID / アクセスキーID / ARN / IPv4 / メール）
# ※ バケット名・ユーザー名・リソースIDはマスクしない（README 参照）
mask_for_llm() {
  if command -v perl >/dev/null 2>&1; then
    perl -0777 -pe '
      s/\b(\d{2})\d{10}\b/${1}**********/g;
      s/\b(AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[A-Z0-9]{16}\b/[ACCESS-KEY-ID]/g;
      s#arn:(aws[\w-]*):([\w-]+):([\w-]*):\d{12}:[^\s]+#arn:$1:$2:$3:12**********:[RESOURCE]#g;
      s/\b(?:\d{1,3}\.){3}\d{1,3}\b/[IP]/g;
      s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[EMAIL]/g;
    '
  else
    sed -E \
      -e 's/\b([0-9]{2})[0-9]{10}\b/\1**********/g' \
      -e 's/\b(AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[A-Z0-9]{16}\b/[ACCESS-KEY-ID]/g' \
      -e 's#arn:(aws[[:alnum:]-]*):([[:alnum:]-]+):([[:alnum:]-]*):[0-9]{12}:[^ ]+#arn:\1:\2:\3:12**********:[RESOURCE]#g' \
      -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/[IP]/g' \
      -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[EMAIL]/g'
  fi
}

polish_with_openai() {
  [ "${POLISH_WITH_OPENAI:-0}" = "1" ] || return 0
  command -v curl >/dev/null 2>&1 || { echo "ℹ️ curl 未インストールのため整形スキップ"; return 0; }
  load_openai_key
  if [ -z "$OPENAI_API_KEY" ]; then
    echo "⚠️ OPENAI_API_KEY を取得できないため整形スキップ（Secrets Manager: $OPENAI_SECRET_NAME）" >&2
    return 0
  fi

  local BASE="${OPENAI_API_BASE:-https://api.openai.com}"
  local MODEL="${OPENAI_MODEL:-gpt-4.1-mini}"
  local FB="${OPENAI_MODEL_FALLBACK:-gpt-4.1}"
  local SYS MASKED OUT2 LASTJSON
  OUT2="${OUT%.md}_polished.md"
  LASTJSON="${OUT2%.md}_last.json"

  SYS=$'あなたはセキュリティ監査レポートの編集者です。\n'
  SYS+=$'必ず以下を守る:\n'
  SYS+=$'- 元のMarkdownの表/見出し/順序を壊さない（数値は改変しない）\n'
  SYS+=$'- 各セクション直後に3行以内の「### 📝 …（短評）」を追加\n'
  SYS+=$'- 冒頭に「### 🔴 今すぐ対応（Top5）」を作る（本文の所見のみで構成）\n'
  SYS+=$'- 用語を統一（例：未設定/有効/無効）\n'

  MASKED="$(mask_for_llm < "$OUT")"

  call_chat() {
    local mdl="$1" data resp code body content err
    data="$(jq -n --arg model "$mdl" --arg sys "$SYS" --arg msg "$MASKED" '{
      model: $model, temperature: 0.2,
      messages: [ {role:"system",content:$sys}, {role:"user",content:$msg} ]
    }')"
    # Authorization ヘッダはプロセス置換のファイルから読ませ、引数に載せない
    resp="$(curl -sS -w '\n%{http_code}' "$BASE/v1/chat/completions" \
      -H @<(printf 'Authorization: Bearer %s\n' "$OPENAI_API_KEY") \
      -H "Content-Type: application/json" --data-binary @<(printf '%s' "$data"))" || return 2
    code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    printf '%s' "$body" > "$LASTJSON"

    content="$(echo "$body" | jq -r '.choices[0].message.content // empty')"
    err="$(echo "$body" | jq -r '.error.message // empty')"

    if [ -n "$content" ]; then
      printf '%s' "$content" > "$OUT2"
      echo "📝 整形レポート: $OUT2 (model=$mdl)"
      return 0
    else
      echo "⚠️ OpenAI API (HTTP $code, model=$mdl): ${err:-no content}" >&2
      return 1
    fi
  }

  if call_chat "$MODEL"; then :; elif call_chat "$FB"; then :; else
    echo "⚠️ 整形失敗（両モデルNG）。詳細: $LASTJSON" >&2
    rm -f "$OUT2" 2>/dev/null || true
  fi
}

# 表紙
{
  echo "# AWSセキュリティ監査レポート（要約）"
  echo "- 生成(JST): ${DATE_JST}"
  echo "- リージョン: ${REGION}"
  echo "- アカウント: ${ACC}"
  echo
  echo "> このレポートは読み取り専用API（list/describe/get）のみ使用。Secrets Manager の値を取得するのは、OpenAI 整形を有効にしたときの API キー1件のみ。"
  echo
} > "$OUT"

# ---- レポート組み立てヘルパー ----------------------------------------
CRIT=0; HIGH=0; MED=0; LOW=0
SECTION_ROWS=0; SECTION_COLS=0

section_end(){ # 直前のセクションに行が無ければ「該当なし」を入れる
  { [ "$SECTION_COLS" -gt 0 ] && [ "$SECTION_ROWS" -eq 0 ]; } || return 0
  local row="| 該当なし |" i
  for ((i=1; i<SECTION_COLS; i++)); do row+=" - |"; done
  echo "$row" >>"$TMP"
}

section(){ # section <見出し> <ヘッダ行 "| a | b | … |">  … 区切り行は列数から生成する
  section_end
  local title="$1" header="$2" cols sep i
  cols=$(( $(printf '%s' "$header" | tr -cd '|' | wc -c) - 1 ))
  sep="|"; for ((i=0; i<cols; i++)); do sep+="------|"; done
  local blank=""; [ -s "$TMP" ] && blank=$'\n'   # 2 つ目以降のセクションは空行で区切る
  {
    printf '%s' "$blank"
    echo "## $title"
    echo
    echo "$header"
    echo "$sep"
  } >>"$TMP"
  SECTION_ROWS=0; SECTION_COLS=$cols
}

add(){ # add <Severity> <MarkdownRow>
  local s="$1"; shift
  echo "$*" >>"$TMP"
  SECTION_ROWS=$((SECTION_ROWS+1))
  case "$s" in
    Critical) CRIT=$((CRIT+1));;
    High)     HIGH=$((HIGH+1));;
    Medium)   MED=$((MED+1));;
    Low)      LOW=$((LOW+1));;
  esac
}

finish(){
  local ec=$?
  section_end
  {
    echo
    echo "## サマリー"
    echo
    echo "- Critical: ${CRIT}"
    echo "- High:     ${HIGH}"
    echo "- Medium:   ${MED}"
    echo "- Low:      ${LOW}"
    echo
    cat "$TMP"
  } >>"$OUT"
  rm -f "$TMP"
  if [ "$ec" -ne 0 ]; then
    echo "⚠️ 途中で失敗しました（exit=$ec）。ここまでの部分レポート: $OUT" >&2
    return 0
  fi
  echo "✅ 完了: $OUT"
  polish_with_openai || true
}
trap finish EXIT

# ISO8601（…Z / …+00:00 / 小数秒つき）→ 経過日数。解釈できなければ空を返す。
# AWS CLI v2 は「2024-01-15T10:00:00+00:00」形式で出す（Z ではない）ので、UTC 前提で正規化する。
days_since(){
  local ts="${1%$'\r'}" s=""
  ts="${ts%%.*}"          # 小数秒以降（続くオフセット含む）を落とす
  ts="${ts%Z}"; ts="${ts%+00:00}"
  if date --version >/dev/null 2>&1; then
    s=$(date -u -d "$ts" +%s 2>/dev/null || true)
  else
    s=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null || true)
  fi
  [ -z "$s" ] && { echo ""; return; }
  echo $(( ( NOW_EPOCH - s ) / 86400 ))
}

# S3 バケットの個別属性（バケット一覧と CloudTrail 送信先の両方で使う）
# 参照できない場合（別アカウントの送信先など）は「不明」を返し、呼び出し側で扱いを分ける
s3_policy_public(){ aws s3api get-bucket-policy-status --bucket "$1" 2>/dev/null | jq -r '.PolicyStatus.IsPublic // false' 2>/dev/null || echo false; }
s3_versioning(){ aws s3api get-bucket-versioning --bucket "$1" 2>/dev/null | jq -r '.Status // "無効"' 2>/dev/null || echo "無効"; }
s3_encryption_json(){ aws s3api get-bucket-encryption --bucket "$1" 2>/dev/null || echo "不明"; }
s3_object_lock(){ aws s3api get-object-lock-configuration --bucket "$1" 2>/dev/null | jq -r '.ObjectLockConfiguration.ObjectLockEnabled // "None"' 2>/dev/null || echo "None"; }

# ==== IAM ============================================================
section "IAM" "| 対象 | 設定 | リスク | 優先度 |"

# root: MFA / AccessKey 存在（get-account-summary は 1 回で両方読む）
SUMMARY="$(aws iam get-account-summary --output json 2>/dev/null || echo '{}')"
ROOT_MFA="$(echo "$SUMMARY" | jq -r '.SummaryMap.AccountMFAEnabled // 0')"
ROOT_AK="$(echo "$SUMMARY" | jq -r '.SummaryMap.AccountAccessKeysPresent // 0')"
[ "$ROOT_MFA" = "0" ] && add Critical "| root | MFA=未設定 | ⚠️ root MFA未設定 | Critical |"
[ "$ROOT_AK" != "0" ] && add High "| root | AccessKey=存在 | ⚠️ rootにアクセスキー | High |"

# IAMユーザー
while read -r U; do
  [ -z "$U" ] && continue
  MFA="$(aws iam list-mfa-devices --user-name "$U" --query 'length(MFADevices)' --output text 2>/dev/null || echo 0)"
  # shellcheck disable=SC2016  # バッククォートは JMESPath のリテラル
  ADMIN="$(aws iam list-attached-user-policies --user-name "$U" \
    --query 'AttachedPolicies[?PolicyName==`AdministratorAccess`]' --output text 2>/dev/null || true)"
  R=""; S=Low
  [ "$MFA" -eq 0 ] && { R+=" ⚠️ MFA未設定"; S=High; }
  [ -n "$ADMIN" ] && { R+=" ⚠️ 管理者権限"; S=High; }
  while read -r AK CD; do
    [ -z "${AK:-}" ] && continue
    D="$(days_since "$CD")"; [ -n "$D" ] && [ "${D:-0}" -gt 90 ] && { R+=" ⚠️ キー作成>90日"; S=High; }
    LU="$(aws iam get-access-key-last-used --access-key-id "$AK" --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null || echo None)"
    if [ "$LU" != "None" ]; then D2="$(days_since "$LU")"; [ -n "$D2" ] && [ "${D2:-0}" -gt 90 ] && { R+=" ⚠️ 最終使用>90日"; S=High; }; fi
  done < <(aws iam list-access-keys --user-name "$U" --query 'AccessKeyMetadata[*].[AccessKeyId,CreateDate]' --output text 2>/dev/null)
  add "$S" "| $U | MFA=$MFA, Admin=$( [ -n "$ADMIN" ] && echo yes || echo no ) |${R:- } | $S |"
done < <(aws iam list-users --query 'Users[].UserName' --output text 2>/dev/null | tr '\t' '\n' || true)

# ==== IAM Password Policy ===========================================
section "IAM Password Policy" "| 長さ | 記号 | 数字 | 大小英 | 最大有効日 | リスク | 優先度 |"
PP="$(aws iam get-account-password-policy 2>/dev/null || true)"
if [ -z "$PP" ]; then
  add High "| - | - | - | - | - | ⚠️ ポリシー未設定 | High |"
else
  MIN="$(echo "$PP" | jq -r '.PasswordPolicy.MinimumPasswordLength // 0')"
  SYM="$(echo "$PP" | jq -r '.PasswordPolicy.RequireSymbols // false')"
  NUM="$(echo "$PP" | jq -r '.PasswordPolicy.RequireNumbers // false')"
  UPP="$(echo "$PP" | jq -r '.PasswordPolicy.RequireUppercaseCharacters // false')"
  LOWC="$(echo "$PP" | jq -r '.PasswordPolicy.RequireLowercaseCharacters // false')"
  MAX="$(echo "$PP" | jq -r '.PasswordPolicy.MaxPasswordAge // 0')"
  R=""; S=Low
  [ "${MIN:-0}" -lt 12 ] && { R+=" ⚠️ 長さ<12"; S=High; }
  [ "$SYM" != "true" ] && { R+=" ⚠️ 記号なし"; S=High; }
  [ "$NUM" != "true" ] && { R+=" ⚠️ 数字なし"; S=High; }
  { [ "$UPP" != "true" ] || [ "$LOWC" != "true" ]; } && { R+=" ⚠️ 大小英のいずれか不足"; S=High; }
  [ "${MAX:-0}" -eq 0 ] && { R+=" ⚠️ 期限なし"; [ "$S" = Low ] && S=Medium; }
  add "$S" "| $MIN | $SYM | $NUM | $UPP/$LOWC | $MAX | ${R:-} | $S |"
fi

# ==== IAM 未使用ユーザー（Credential Report） ====
aws iam generate-credential-report >/dev/null 2>&1 || true
CR="$(aws iam get-credential-report --query Content --output text 2>/dev/null | b64d || true)"
if [ -n "$CR" ]; then
  section "IAM（未使用>90日 ユーザー）" "| User | 最終活動（日） | リスク | 優先度 |"

  parse_days() {
    local v="${1%$'\r'}"
    case "$v" in
      ""|"N/A"|"not_supported"|"no_information") echo 9999 ;;
      *T*) days_since "$v" ;;
      *) echo 9999 ;;
    esac
  }

  # Credential Report の列順（AWS 仕様）:
  #  1 user, 2 arn, 3 user_creation_time, 4 password_enabled, 5 password_last_used,
  #  6 password_last_changed, 7 password_next_rotation, 8 mfa_active,
  #  9 access_key_1_active, 10 access_key_1_last_rotated, 11 access_key_1_last_used_date,
  # 12 access_key_1_last_used_region, 13 access_key_1_last_used_service,
  # 14 access_key_2_active, 15 access_key_2_last_rotated, 16 access_key_2_last_used_date, …
  while IFS=, read -r user _ _ _ pwd_last_used _ _ _ _ _ k1_last_used _ _ _ _ k2_last_used _; do
    [ -z "$user" ] && continue
    D1="$(parse_days "${pwd_last_used//\"/}")"
    D2="$(parse_days "${k1_last_used//\"/}")"
    D3="$(parse_days "${k2_last_used//\"/}")"
    : "${D1:=9999}"; : "${D2:=9999}"; : "${D3:=9999}"
    DAYS=$(( D1 < D2 ? (D1 < D3 ? D1 : D3) : (D2 < D3 ? D2 : D3) ))
    [ "$DAYS" -gt 90 ] && add High "| ${user//\"/} | $DAYS | ⚠️ 最終活動>90日 | High |"
  done < <(printf '%s\n' "$CR" | tail -n +2)
fi

# ==== Access Analyzer ===============================================
section "Access Analyzer" "| Analyzer | ステータス | リスク | 優先度 |"

AN_NAMES="$(aws accessanalyzer list-analyzers --query 'analyzers[].name' --output text 2>/dev/null | tr '\t' '\n' || true)"
if [ -z "$AN_NAMES" ]; then
  add High "| N/A | 無効 | ⚠️ Analyzer未作成 | High |"
else
  while read -r AN; do
    [ -z "$AN" ] && continue
    ST="$(aws accessanalyzer get-analyzer --analyzer-name "$AN" --query 'analyzer.status' --output text 2>/dev/null || echo UNKNOWN)"
    R=""; S=Low; [ "$ST" != "ACTIVE" ] && { R="⚠️ 非ACTIVE"; S=High; }
    add "$S" "| $AN | $ST | ${R:-} | $S |"
  done < <(printf '%s\n' "$AN_NAMES")
fi

# ==== S3（アカウントPAB） ==========================================
section "S3 Public Access Block（Account）" "| Account | 全項目ON | リスク | 優先度 |"
APAB="$(aws s3control get-public-access-block --account-id "$ACC" 2>/dev/null \
      | jq -r '[.PublicAccessBlockConfiguration.BlockPublicAcls,
                 .PublicAccessBlockConfiguration.IgnorePublicAcls,
                 .PublicAccessBlockConfiguration.BlockPublicPolicy,
                 .PublicAccessBlockConfiguration.RestrictPublicBuckets] | all' \
      2>/dev/null || echo false)"
R=""; S=Low; [ "$APAB" != "true" ] && { R="⚠️ いずれかOFF"; S=High; }
add "$S" "| $ACC | $APAB | ${R:-} | $S |"

# ==== S3（各バケット） =============================================
section "S3" "| バケット | 暗号化 | バージョニング | PAB | ポリシー公開 | ACL公開 | TLS必須 | リスク | 優先度 |"

while read -r B; do
  [ -z "$B" ] && continue
  PUB="$(s3_policy_public "$B")"
  # 暗号化は 1 回の呼び出しでアルゴリズムとキーIDの両方を読む
  ENC_JSON="$(s3_encryption_json "$B")"
  if [ "$ENC_JSON" = "不明" ]; then
    ENC_ALG="なし"; ENC_KEYID=""
  else
    ENC_ALG="$(echo "$ENC_JSON" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // "なし"')"
    ENC_KEYID="$(echo "$ENC_JSON" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID // empty')"
  fi
  VER="$(s3_versioning "$B")"
  BPAB="$(aws s3api get-bucket-public-access-block --bucket "$B" 2>/dev/null \
      | jq -r '[.PublicAccessBlockConfiguration.BlockPublicAcls,
                 .PublicAccessBlockConfiguration.IgnorePublicAcls,
                 .PublicAccessBlockConfiguration.BlockPublicPolicy,
                 .PublicAccessBlockConfiguration.RestrictPublicBuckets] | all' \
      2>/dev/null || echo false)"
  # ACL公開検出
  ACLPUB="false"
  ACL="$(aws s3api get-bucket-acl --bucket "$B" 2>/dev/null || echo '')"
  if [ -n "$ACL" ]; then
    echo "$ACL" | jq -r '.Grants[].Grantee.URI? // empty' 2>/dev/null | grep -Eq 'AllUsers|AuthenticatedUsers' && ACLPUB="true"
  fi
  # TLS必須（aws:SecureTransport のDeny）
  TLSREQ="false"
  POL_JSON_STR="$(aws s3api get-bucket-policy --bucket "$B" --query 'Policy' --output text 2>/dev/null || echo '')"
  if [ -n "$POL_JSON_STR" ] && printf '%s' "$POL_JSON_STR" \
      | jq -e '.Statement[]? | select((.Effect=="Deny") and (
            (.Condition.Bool."aws:SecureTransport"=="false") or
            (.Condition.Bool["aws:SecureTransport"]=="false") or
            (.Condition.BoolIfExists."aws:SecureTransport"=="false") or
            (.Condition.BoolIfExists["aws:SecureTransport"]=="false")
          ))' >/dev/null 2>&1; then
    TLSREQ="true"
  fi

  R=""; S=Low
  [ "$PUB" = "true" ] && { R+=" ⚠️ ポリシーで公開"; S=High; }
  [ "$ACLPUB" = "true" ] && { R+=" ⚠️ ACLで公開"; S=High; }
  [ "$ENC_ALG" = "なし" ] && { R+=" ⚠️ 暗号化なし"; S=High; }
  # KMS推奨（SSE-S3のみは提言。優先度は上げない）
  [ "$ENC_ALG" = "AES256" ] && R+=" ⚠️ KMS未使用（推奨）"
  [ "$VER" = "無効" ] && { R+=" ⚠️ バージョニング無効"; [ "$S" = Low ] && S=Medium; }
  [ "$BPAB" != "true" ] && { R+=" ⚠️ PAB不足"; [ "$S" = Low ] && S=Medium; }
  [ "$TLSREQ" != "true" ] && { R+=" ⚠️ TLS必須未設定"; [ "$S" = Low ] && S=Medium; }

  add "$S" "| $B | $ENC_ALG${ENC_KEYID:+(KMS)} | $VER | $BPAB | $PUB | $ACLPUB | $TLSREQ |${R:- } | $S |"
done < <(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' || true)

# ==== EC2 / EBS ======================================================
section "EC2 / EBS" "| インスタンス | PublicIP | EBS暗号化 | IMDSv2 | リスク | 優先度 |"

# describe-instances は 1 回だけ。ボリュームはインスタンス単位に 1 回（attachment.instance-id で絞る）
EC2_JSON="$(aws ec2 describe-instances --region "$REGION" --output json 2>/dev/null || echo '{"Reservations":[]}')"
while IFS=$'\t' read -r I PUBIP TOKENS; do
  [ -z "$I" ] && continue
  R=""; S=Low; ENC_FLAG="N/A"
  [ "$PUBIP" != "None" ] && { R+=" ⚠️ PublicIP"; S=Medium; }
  [ "$TOKENS" != "required" ] && { R+=" ⚠️ IMDSv2未強制"; [ "$S" = Low ] && S=Medium; }
  VOL_JSON="$(aws ec2 describe-volumes --region "$REGION" --filters "Name=attachment.instance-id,Values=$I" --output json 2>/dev/null || echo '{"Volumes":[]}')"
  if [ "$(echo "$VOL_JSON" | jq -r '.Volumes | length')" -gt 0 ]; then
    ENC_FLAG="OK"
    while read -r V; do
      [ -z "$V" ] && continue
      R+=" ⚠️ EBS暗号化なし($V)"; S=High; ENC_FLAG="NG"
    done < <(echo "$VOL_JSON" | jq -r '.Volumes[]? | select(.Encrypted != true) | .VolumeId')
  fi
  add "$S" "| $I | $PUBIP | $ENC_FLAG | $TOKENS |${R:- } | $S |"
done < <(echo "$EC2_JSON" | jq -r '.Reservations[]?.Instances[]? | [.InstanceId, (.PublicIpAddress // "None"), (.MetadataOptions.HttpTokens // "unknown")] | @tsv')

# EBS 既定暗号化（アカウント設定）
section "EBS Default Encryption（Account）" "| Account | 既定暗号化 | デフォルトKMS | リスク | 優先度 |"
DEFENC="$(aws ec2 get-ebs-encryption-by-default --region "$REGION" --query 'EbsEncryptionByDefault' --output text 2>/dev/null || echo False)"
DEFKMS="$(aws ec2 get-ebs-default-kms-key-id --region "$REGION" --query 'KmsKeyId' --output text 2>/dev/null || echo None)"
R=""; S=Low; [ "$DEFENC" != "True" ] && { R="⚠️ 無効"; S=High; }
add "$S" "| $ACC | $DEFENC | $DEFKMS | ${R:-} | $S |"

# ==== RDS ============================================================
section "RDS" "| DB | 暗号化 | Public | MultiAZ | Backup保持 | AutoMinorUpg | スナップ公開 | リスク | 優先度 |"

# describe-db-instances は 1 回だけ
RDS_JSON="$(aws rds describe-db-instances --region "$REGION" --output json 2>/dev/null || echo '{"DBInstances":[]}')"
while IFS=$'\t' read -r DB ENC PUB MAZ BRET AMU; do
  [ -z "$DB" ] && continue
  R=""; S=Low; SNAP="Checked"
  [ "$ENC" = "false" ] && { R+=" ⚠️ 暗号化なし"; S=High; }
  [ "$PUB" = "true" ] && { R+=" ⚠️ Public"; S=High; }
  [ "$MAZ" = "false" ] && { R+=" ⚠️ 単一AZ"; [ "$S" = Low ] && S=Medium; }
  [ "${BRET:-0}" -lt 7 ] && { R+=" ⚠️ Backup保持<7日"; [ "$S" = Low ] && S=Medium; }
  [ "$AMU" = "false" ] && R+=" ⚠️ 自動マイナーUPG無効"
  while read -r SNAME; do
    [ -z "$SNAME" ] && continue
    ATTR="$(aws rds describe-db-snapshot-attributes --db-snapshot-identifier "$SNAME" --region "$REGION" \
            --query "DBSnapshotAttributesResult.DBSnapshotAttributes[?AttributeName=='restore'].AttributeValues[]" --output text 2>/dev/null || echo "")"
    echo "$ATTR" | grep -q '\ball\b' && { R+=" ⚠️ スナップ公開($SNAME)"; S=High; }
  done < <(aws rds describe-db-snapshots --db-instance-identifier "$DB" --region "$REGION" \
           --query 'DBSnapshots[].DBSnapshotIdentifier' --output text 2>/dev/null | tr '\t' '\n' || true)
  add "$S" "| $DB | $ENC | $PUB | $MAZ | ${BRET:-0} | $AMU | $SNAP |${R:- } | $S |"
done < <(echo "$RDS_JSON" | jq -r '.DBInstances[]? | [.DBInstanceIdentifier, (.StorageEncrypted // false), (.PubliclyAccessible // false), (.MultiAZ // false), (.BackupRetentionPeriod // 0), (.AutoMinorVersionUpgrade // false)] | @tsv')

# ==== KMS ============================================================
section "KMS" "| KeyId | Spec | Manager | Rotation | リスク | 優先度 |"

while read -r K; do
  [ -z "$K" ] && continue
  META="$(aws kms describe-key --key-id "$K" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  SPEC="$(echo "$META" | jq -r '.KeyMetadata.KeySpec // "UNKNOWN"')"
  KMGR="$(echo "$META" | jq -r '.KeyMetadata.KeyManager // "UNKNOWN"')"
  KSTATE="$(echo "$META" | jq -r '.KeyMetadata.Enabled // false')"
  ROT="N/A"; R=""; S=Low
  if [ "$SPEC" = "SYMMETRIC_DEFAULT" ] && [ "$KMGR" = "CUSTOMER" ] && [ "$KSTATE" = "true" ]; then
    ROT="$(aws kms get-key-rotation-status --key-id "$K" --region "$REGION" --query 'KeyRotationEnabled' --output text 2>/dev/null || echo "N/A")"
    [ "$ROT" = "False" ] && { R="⚠️ ローテーション無効"; S=High; }
  fi
  add "$S" "| $K | $SPEC | $KMGR | $ROT | ${R:-} | $S |"
done < <(aws kms list-keys --region "$REGION" --query 'Keys[].KeyId' --output text 2>/dev/null | tr '\t' '\n' || true)

# ==== CloudTrail =====================================================
section "CloudTrail" "| Trail | MultiRegion | Verify | Logging | CW Logs | DataEvents | Insights | リスク | 優先度 |"

# describe-trails に主要属性が全部入っているので get-trail は呼ばない。
# 状態・セレクタは ARN で問い合わせる（他リージョンがホームの Trail は名前だと解決できない）。
TRAILS_JSON="$(aws cloudtrail describe-trails --region "$REGION" --output json 2>/dev/null || echo '{"trailList":[]}')"
ANY_MULTI_LOGGING=false
while IFS=$'\t' read -r T TARN MULTI VERIFY S3B CWLG; do
  [ -z "$T" ] && continue
  LOGGING="$(aws cloudtrail get-trail-status --name "$TARN" --region "$REGION" --query 'IsLogging' --output text 2>/dev/null || echo False)"
  # Data events（AdvancedEventSelectorsにも対応）
  DEVT="$(aws cloudtrail get-event-selectors --trail-name "$TARN" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  HAS_DATA_STD="$(echo "$DEVT" | jq -r '[.EventSelectors[]?.DataResources[]? // empty] | length>0' 2>/dev/null || echo false)"
  HAS_DATA_ADV="$(echo "$DEVT" | jq -r '(.AdvancedEventSelectors // []) | length>0' 2>/dev/null || echo false)"
  if [ "$HAS_DATA_STD" = "true" ] || [ "$HAS_DATA_ADV" = "true" ]; then HAS_DATA="true"; else HAS_DATA="false"; fi
  INS="$(aws cloudtrail get-insight-selectors --trail-name "$TARN" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  HAS_INS="$(echo "$INS" | jq -r '.InsightSelectors | length>0' 2>/dev/null || echo false)"

  R=""; S=Low
  [ "$MULTI" = "false" ] && { R+=" ⚠️ マルチリージョン無効"; S=High; }
  [ "$VERIFY" = "false" ] && { R+=" ⚠️ 証跡検証無効"; S=High; }
  [ "$LOGGING" = "False" ] && { R+=" ⚠️ ログ停止中"; S=High; }
  [ "$HAS_DATA" != "true" ] && { R+=" ⚠️ データイベント未設定"; [ "$S" = Low ] && S=Medium; }
  [ "$HAS_INS" != "true" ] && { R+=" ⚠️ Insights無効"; [ "$S" = Low ] && S=Medium; }

  # CW Logs 連携 & 保持日数（ARN 末尾の ":*" を除き、ロググループのリージョンで問い合わせる）
  CWRET="None"
  if [ "$CWLG" != "None" ] && [ "$CWLG" != "null" ]; then
    LG="${CWLG##*:log-group:}"; LG="${LG%:\*}"
    LGREG="$(echo "$CWLG" | cut -d: -f4)"; [ -z "$LGREG" ] && LGREG="$REGION"
    CWRET="$(aws logs describe-log-groups --log-group-name-prefix "$LG" --region "$LGREG" \
            --query "logGroups[?logGroupName=='$LG'].retentionInDays | [0]" --output text 2>/dev/null || echo None)"
    [ "$CWRET" = "None" ] && { R+=" ⚠️ CloudWatchLogs保持未設定"; [ "$S" = Low ] && S=Medium; }
  else
    R+=" ⚠️ CloudWatchLogs連携なし"; [ "$S" = Low ] && S=Medium
  fi
  # 送信先S3の保護（別アカウントのバケットは参照できないので「参照不可」として扱い、誤検知しない）
  if [ "$S3B" != "None" ] && [ "$S3B" != "null" ]; then
    ENC2_JSON="$(s3_encryption_json "$S3B")"
    if [ "$ENC2_JSON" = "不明" ]; then
      R+=" ℹ️ 送信先S3は参照不可（別アカウント等）"
    else
      PUB2="$(s3_policy_public "$S3B")"
      ENC2="$(echo "$ENC2_JSON" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // "なし"')"
      VER2="$(s3_versioning "$S3B")"
      OLOCK="$(s3_object_lock "$S3B")"
      [ "$PUB2" = "true" ] && { R+=" ⚠️ 送信先S3がPublic"; S=High; }
      [ "$ENC2" = "なし" ] && { R+=" ⚠️ 送信先S3暗号化なし"; S=High; }
      [ "$VER2" = "無効" ] && { R+=" ⚠️ 送信先S3バージョニング無効"; [ "$S" = Low ] && S=Medium; }
      [ "$OLOCK" != "Enabled" ] && R+=" ⚠️ 送信先S3 ObjectLock無効"
    fi
  fi
  [ "$MULTI" = "true" ] && [ "$LOGGING" = "True" ] && ANY_MULTI_LOGGING=true
  add "$S" "| $T | $MULTI | $VERIFY | $LOGGING | ${CWRET} | $HAS_DATA | $HAS_INS |${R:- } | $S |"
done < <(echo "$TRAILS_JSON" | jq -r '.trailList[]? | [.Name, .TrailARN, (.IsMultiRegionTrail // false), (.LogFileValidationEnabled // false), (.S3BucketName // "None"), (.CloudWatchLogsLogGroupArn // "None")] | @tsv')
if [ "${ANY_MULTI_LOGGING}" != "true" ]; then
  add High "| summary | - | - | - | - | - | - | ⚠️ マルチリージョン有効なTrailが稼働していません | High |"
fi

# ==== CloudWatch Logs ===============================================
section "CloudWatch Logs" "| LogGroup | 保持日数 | KMS | リスク | 優先度 |"

# AWS CLI v2 は describe-log-groups を自動でページングする（手動の nextToken ループは不要）
LG_JSON="$(aws logs describe-log-groups --region "$REGION" --output json 2>/dev/null || echo '{"logGroups":[]}')"
while IFS=$'\t' read -r LG RET KMSK; do
  [ -z "$LG" ] && continue
  R=""; S=Low
  [ "$RET" = "None" ] && { R+=" ⚠️ 保持未設定"; S=Medium; }
  [ "$KMSK" = "None" ] && R+=" ⚠️ KMS暗号なし"
  add "$S" "| $LG | $RET | $KMSK | ${R:-} | $S |"
done < <(echo "$LG_JSON" | jq -r '.logGroups[]? | [.logGroupName, (.retentionInDays // "None"), (.kmsKeyId // "None")] | @tsv')

# ==== AWS Config =====================================================
section "AWS Config" "| Recorder | recording | Delivery | リスク | 優先度 |"

RC_JSON="$(aws configservice describe-configuration-recorder-status --region "$REGION" --output json 2>/dev/null || echo '{"ConfigurationRecordersStatus":[]}')"
DC_JSON="$(aws configservice describe-delivery-channel-status --region "$REGION" --output json 2>/dev/null || echo '{"DeliveryChannelsStatus":[]}')"
if [ "$(echo "$RC_JSON" | jq -r '.ConfigurationRecordersStatus | length')" = "0" ]; then
  add High "| N/A | False | None | ⚠️ Recorder未作成 | High |"
else
  DEL="$(echo "$DC_JSON" | jq -r 'first(.DeliveryChannelsStatus[]? | .configHistoryDeliveryInfo.lastStatus // "None") // "None"')"
  while IFS=$'\t' read -r NAME REC; do
    [ -z "$NAME" ] && continue
    R=""; S=Low
    [ "$REC" != "true" ] && { R+=" ⚠️ Recorder無効"; S=High; }
    { [ "$DEL" = "Failure" ] || [ "$DEL" = "None" ]; } && { R+=" ⚠️ Delivery停止/未設定"; S=High; }
    add "$S" "| $NAME | $REC | $DEL | ${R:-} | $S |"
  done < <(echo "$RC_JSON" | jq -r '.ConfigurationRecordersStatus[]? | [(.name // "default"), (.recording // false)] | @tsv')
fi

# ==== GuardDuty ======================================================
section "GuardDuty" "| Detector | Findings | Features(Disabled数) | リスク | 優先度 |"

DET="$(aws guardduty list-detectors --region "$REGION" --query 'DetectorIds[0]' --output text 2>/dev/null || echo "")"
if [ -z "$DET" ] || [ "$DET" = "None" ]; then
  add High "| N/A | - | - | ⚠️ 無効 | High |"
else
  # アーカイブ済みは除外し、現在有効な Findings だけを数える（応答のキーは FindingIds）
  F="$(aws guardduty list-findings --detector-id "$DET" --region "$REGION" \
        --finding-criteria '{"Criterion":{"service.archived":{"Eq":["false"]}}}' \
        --query 'length(FindingIds)' --output text 2>/dev/null || echo 0)"
  FEAT_JSON="$(aws guardduty describe-detector --detector-id "$DET" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  FEAT_DISABLED_CNT="$(echo "$FEAT_JSON" | jq -r '[.Features[]? | select((.Status!="ENABLED") and (.Name!=null))] | length' 2>/dev/null || echo 0)"
  R=""; S=Low
  [ "${F:-0}" -gt 0 ] && { R+=" ⚠️ Findingsあり(${F})"; S=High; }
  [ "${FEAT_DISABLED_CNT:-0}" -gt 0 ] && { R+=" ⚠️ 一部機能無効(${FEAT_DISABLED_CNT})"; [ "$S" = Low ] && S=Medium; }
  add "$S" "| $DET | ${F:-0} | ${FEAT_DISABLED_CNT:-0} | ${R:-} | $S |"
fi

# ==== Security Hub ===================================================
section "Security Hub" "| 有効 | FSBP | CIS | リスク | 優先度 |"

SH_ACC="$(aws securityhub describe-hub --region "$REGION" --query 'HubArn' --output text 2>/dev/null || echo None)"
if [ "$SH_ACC" = "None" ] || [ -z "$SH_ACC" ]; then
  add High "| 無効 | - | - | ⚠️ Security Hub未有効化 | High |"
else
  STD_ARNS="$(aws securityhub get-enabled-standards --region "$REGION" --query 'StandardsSubscriptions[].StandardsArn' --output text 2>/dev/null || echo '')"
  FSBP=$(echo "$STD_ARNS" | tr '\t' '\n' | grep -c 'aws-foundational-security-best-practices' || true)
  CIS=$(echo "$STD_ARNS" | tr '\t' '\n' | grep -c 'cis-aws-foundations-benchmark' || true)
  R=""; S=Low
  [ "$FSBP" -eq 0 ] && { R+=" ⚠️ FSBP未有効"; S=High; }
  [ "$CIS" -eq 0 ] && { R+=" ⚠️ CIS未有効"; [ "$S" = Low ] && S=Medium; }
  add "$S" "| 有効 | $( [ "$FSBP" -gt 0 ] && echo 有効 || echo 無効 ) | $( [ "$CIS" -gt 0 ] && echo 有効 || echo 無効 ) | ${R:-} | $S |"
fi

# ==== CI/CD（CodeBuild / CodePipeline / ECR） =========================
section "CI/CD" "| 対象 | 設定 | リスク | 優先度 |"

# CodeBuild: privilegedMode = true は High
while read -r P; do
  [ -z "$P" ] && continue
  PRV="$(aws codebuild batch-get-projects --names "$P" --region "$REGION" \
        --query 'projects[0].environment.privilegedMode' --output text 2>/dev/null || echo False)"
  [ "$PRV" = "True" ] && add High "| codebuild:$P | privileged=true | Docker権限昇格の恐れ | High |"
done < <(aws codebuild list-projects --region "$REGION" --query 'projects[]' --output text 2>/dev/null | tr '\t' '\n' || true)

# CodePipeline: ArtifactStore に KMS 無しは Medium（提言）
while read -r N; do
  [ -z "$N" ] && continue
  ART="$(aws codepipeline get-pipeline --name "$N" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  KMS="$(echo "$ART" | jq -r '.pipeline.artifactStore.encryptionKey.id // empty')"
  [ -z "$KMS" ] && add Medium "| codepipeline:$N | KMS=なし | アーティファクト無KMS（推奨） | Medium |"
done < <(aws codepipeline list-pipelines --region "$REGION" --query 'pipelines[].name' --output text 2>/dev/null | tr '\t' '\n' || true)

# ECR: ScanOnPush 無効は Medium、タグ不変/暗号化も（describe-repositories は 1 回だけ）
ECR_JSON="$(aws ecr describe-repositories --region "$REGION" --output json 2>/dev/null || echo '{"repositories":[]}')"
while IFS=$'\t' read -r RPO SCAN MUT ENC_T; do
  [ -z "$RPO" ] && continue
  [ "$SCAN" != "true" ] && add Medium "| ecr:$RPO | scanOnPush=false | 脆弱画像の混入恐れ | Medium |"
  [ "$MUT" = "MUTABLE" ] && add Medium "| ecr:$RPO | tagMutability=MUTABLE | タグ上書きリスク | Medium |"
  [ "$ENC_T" != "KMS" ] && add Low "| ecr:$RPO | encryption=$ENC_T | KMSでの暗号化推奨 | Low |"
done < <(echo "$ECR_JSON" | jq -r '.repositories[]? | [.repositoryName, (.imageScanningConfiguration.scanOnPush // false), (.imageTagMutability // "MUTABLE"), (.encryptionConfiguration.encryptionType // "AES256")] | @tsv')

# ==== ネットワーク（VPC Flow Logs） =================================
section "VPC Flow Logs" "| VPC | FlowLogs数 | リスク | 優先度 |"

FLOGS_JSON="$(aws ec2 describe-flow-logs --region "$REGION" --output json 2>/dev/null || echo '{"FlowLogs":[]}')"
while read -r VPCID; do
  [ -z "$VPCID" ] && continue
  CNT="$(echo "$FLOGS_JSON" | jq -r --arg V "$VPCID" '[.FlowLogs[]? | select(.ResourceId==$V)] | length')"
  [ "${CNT:-0}" -eq 0 ] && add Medium "| $VPCID | 0 | FlowLogs無効（トラフィック追跡不可） | Medium |"
done < <(aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' '\n' || true)

# ==== Security Group ================================================
# describe-security-groups は 1 回だけ取得し、2 つの検査で使い回す
SG_JSON="$(aws ec2 describe-security-groups --region "$REGION" --output json 2>/dev/null || echo '{"SecurityGroups":[]}')"

# ---- 0.0.0.0/0 or ::/0 に対する 22/3389 ----
section "Security Group（世界開放 SSH/RDP）" "| SG | Port | IPバージョン | リスク | 優先度 |"

while IFS=$'\t' read -r SG PORT IPVER; do
  [ -z "$SG" ] && continue
  add High "| $SG | $PORT | $IPVER | 世界開放SSH/RDP | High |"
done < <(echo "$SG_JSON" | jq -r '
  .SecurityGroups[]? as $g
  | ($g.IpPermissions // [])[]? as $p
  # レンジに 22 or 3389 を含むか
  | ((($p.FromPort // -1) <= 22   and 22   <= ($p.ToPort // 65535))) as $is_ssh
  | ((($p.FromPort // -1) <= 3389 and 3389 <= ($p.ToPort // 65535))) as $is_rdp
  # /0 の開放があるか（IPv4/IPv6）
  | ([ $p.IpRanges[]?.CidrIp     | select(. == "0.0.0.0/0") ]     | length > 0) as $v4_open
  | ([ $p.Ipv6Ranges[]?.CidrIpv6 | select(. == "::/0") ]          | length > 0) as $v6_open
  | select( ($is_ssh or $is_rdp) and ($v4_open or $v6_open) )
  | [
      $g.GroupId,
      (if $is_ssh then 22 elif $is_rdp then 3389 else empty end),
      (if $v4_open then "IPv4" else "IPv6" end)
    ]
  | @tsv
' | sort -u)

# ---- ワイドオープン（全ポート/全プロトコルを /0 に開放） ----
section "Security Group（ワイドオープン/IPv6）" "| SG | 内容 | リスク | 優先度 |"

while IFS=$'\t' read -r SG DETAIL; do
  [ -z "$SG" ] && continue
  add High "| $SG | $DETAIL | ワイドオープン | High |"
done < <(echo "$SG_JSON" | jq -r '
  .SecurityGroups[]? as $g
  | ($g.IpPermissions // [])[]? as $p
  | ( ($p.IpProtocol == "-1") or ($p.FromPort == null and $p.ToPort == null) ) as $all
  | ([ $p.IpRanges[]?.CidrIp     | select(. == "0.0.0.0/0") ] | length > 0) as $v4
  | ([ $p.Ipv6Ranges[]?.CidrIpv6 | select(. == "::/0") ]      | length > 0) as $v6
  | select( $all and ($v4 or $v6) )
  | [$g.GroupId, "ALL TCP/UDP/ICMP (IPv4/IPv6 :/0)"]
  | @tsv
' | sort -u)

echo "🐈‍⬛ 処理終了"
