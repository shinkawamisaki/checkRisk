#!/bin/bash
# checkRisk.sh — リスク要約レポート
# LICENSE: Non-Commercial Use Only / 商用利用禁止ライセンス
# 本スクリプト（checkRisk.sh）は、以下の条件で利用可能です：
#
# OK: 学習・研究・社内利用・個人プロジェクトでの使用、改変、再配布は自由です
# NG: 本ツールを用いた有償サービス提供、診断代行、成果物納品などの **商用利用は禁止** します
# OK: 改変後の再配布も可能ですが、同じライセンスを継承してください（CC BY-NC-SA 準拠）
# OK: クレジット表示（著作：Shinkawa）を削除しないでください
# 
# This software is provided under a **Non-Commercial Use License**:
# OK: You are free to use, modify, and distribute this tool for educational, personal, or internal use
# NG: You may **not** use this tool, modified or unmodified, for any commercial purposes, including:
# - Selling it as a product or service
# - Using it to perform paid audits, consulting, or deliverables
# - Rebranding and reselling to customers
#
# Attribution is required: © 2025 Shinkawa. All rights reserved.
#

set -euo pipefail
IFS=$'\n\t'
umask 077

# 失敗時に行番号と直前コマンドを出す
on_err() {
  local ec=$?
  echo "❌ Error (exit=$ec) at line $LINENO: ${BASH_COMMAND}" >&2
  exit $ec
}
trap on_err ERR

export AWS_PAGER=""
export LANG=C
# AWSの再試行（標準）を強めに
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"

REGION="${1:-${AWS_REGION:-ap-northeast-1}}"; export AWS_REGION="$REGION"
DATE_JST="$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')"
DATE_TAG="$(TZ=Asia/Tokyo date '+%Y%m%d_%H%M%S')"
OUTDIR="output"; mkdir -p "$OUTDIR"; chmod 700 "$OUTDIR"
OUT="${OUTDIR}/checkRiskReport_${DATE_TAG}.md"
TMP="$(mktemp)"

echo "🐈 処理開始（region=${REGION}）"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ $1 が見つからない"; exit 1; }; }
need aws; need jq

# base64 デコード（GNU/BSD 両対応）
b64d(){ if base64 --help 2>&1 | grep -q -- '--decode'; then base64 --decode; else base64 -D; fi; }

# ---- 事前健全性チェック（認証・リージョン妥当性） -------------------
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "❌ AWS 認証に失敗（プロファイル/環境変数を確認してください）" >&2
  exit 1
fi
# 指定リージョンが利用可能か軽く確認
aws ec2 describe-availability-zones --region "$REGION" --all-availability-zones >/dev/null 2>&1 || {
  echo "❌ 無効なリージョン指定: $REGION" >&2; exit 1; }

# ------------------ 任意: OpenAI API 連携（POLISH_WITH_OPENAI=1） ----
# （※ Secrets Manager からの取得ロジックは依頼通り「変更なし」）
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

: "${OPENAI_SECRET_NAME:=openai/prod/key}"
if [ -z "${OPENAI_API_KEY:-}" ]; then
  if command -v aws >/dev/null 2>&1; then
    OPENAI_API_KEY="$(aws secretsmanager get-secret-value \
      --secret-id "$OPENAI_SECRET_NAME" \
      --query 'SecretString' --output text 2>/dev/null || true)"
    export OPENAI_API_KEY
  fi
fi

polish_with_openai() {
  [ "${POLISH_WITH_OPENAI:-0}" = "1" ] || return 0
  command -v curl >/dev/null 2>&1 || { echo "ℹ️ curl 未インストールのため整形スキップ"; return 0; }
  : "${OPENAI_API_KEY:?OPENAI_API_KEY が未設定です}"

  local BASE="${OPENAI_API_BASE:-https://api.openai.com}"
  local MODEL="${OPENAI_MODEL:-gpt-4.1-mini}"
  local FB="${OPENAI_MODEL_FALLBACK:-gpt-4.1}"
  local SYS MASKED OUT2 LASTJSON
  OUT2="${OUT%.md}_polished.md"
  LASTJSON="${OUT2%.md}_last.json"

  SYS=$'あなたはセキュリティ監査レポートの編集者です。\n'
  SYS+=$'必ず以下を守る:\n'
  SYS+=$'- 元のMarkdownの表/見出し/順序を壊さない（数値は改変しない）\n'
  SYS+=$'- 各セクション直後に3行以内の「### \U0001F4DD …（短評）」を追加\n'
  SYS+=$'- 冒頭に「### \U0001F534 今すぐ対応（Top5）」を作る（本文の所見のみで構成）\n'
  SYS+=$'- 表が空なら1行「該当なし — – — –」を追加\n'
  SYS+=$'- 用語を統一（例：未設定/有効/無効）\n'

  MASKED="$(cat "$OUT" | mask_for_llm)"

  call_chat() {
    local mdl="$1" data resp code body content err
    data="$(jq -n --arg model "$mdl" --arg sys "$SYS" --arg msg "$MASKED" '{
      model: $model, temperature: 0.2,
      messages: [ {role:"system",content:$sys}, {role:"user",content:$msg} ]
    }')"
    resp="$(curl -sS -w '\n%{http_code}' "$BASE/v1/chat/completions" \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" -d "$data")" || return 2
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
  echo "- アカウント: $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo UNKNOWN)"
  echo
  echo "> このレポートは読み取り専用APIのみ使用（list/describe/get-status）。Secrets Manager/SSMの復号呼び出しなし。"
  echo
} > "$OUT"

finish(){
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
  echo "✅ 完了: $OUT"
  polish_with_openai || true
}
trap finish EXIT

CRIT=0; HIGH=0; MED=0; LOW=0
add(){ # add <Severity> <MarkdownRow>
  local s="$1"; shift
  echo "$*" >>"$TMP"
  case "$s" in
    Critical) CRIT=$((CRIT+1));;
    High)     HIGH=$((HIGH+1));;
    Medium)   MED=$((MED+1));;
    Low)      LOW=$((LOW+1));;
  esac
}

days_since(){ # ISO8601 → 経過日数（GNU/BSD両対応）
  local ts="$1" s=""
  if date --version >/dev/null 2>&1; then s=$(date -d "$ts" +%s 2>/dev/null || true)
  else s=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || true); fi
  [ -z "$s" ] && { echo ""; return; }
  echo $(( ( $(date +%s) - s ) / 86400 ))
}

# ==== IAM ============================================================
{
  echo "## IAM"
  echo
  echo "| 対象 | 設定 | リスク | 優先度 |"
  echo "|------|------|--------|--------|"
} >>"$TMP"

# root: MFA / AccessKey 存在
ROOT_MFA="$(aws iam get-account-summary --query 'SummaryMap.AccountMFAEnabled' --output text 2>/dev/null || echo 0)"
[ "$ROOT_MFA" = "0" ] && add Critical "| root | MFA=未設定 | ⚠️ root MFA未設定 | Critical |"
ROOT_AK="$(aws iam get-account-summary --query 'SummaryMap.AccountAccessKeysPresent' --output text 2>/dev/null || echo 0)"
[ "$ROOT_AK" != "0" ] && add High "| root | AccessKey=存在 | ⚠️ rootにアクセスキー | High |"

# IAMユーザー
while read -r U; do
  [ -z "$U" ] && continue
  MFA="$(aws iam list-mfa-devices --user-name "$U" --query 'length(MFADevices)' --output text 2>/dev/null || echo 0)"
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
{
  echo
  echo "## IAM Password Policy"
  echo
  echo "| 長さ | 記号 | 数字 | 大小英 | 最大有効日 | リスク | 優先度 |"
  echo "|------|------|------|--------|------------|--------|--------|"
} >>"$TMP"
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
  {
    echo
    echo "## IAM（未使用>90日 ユーザー）"
    echo
    echo "| User | 最終活動（日） | リスク | 優先度 |"
    echo "|------|----------------|--------|--------|"
  } >>"$TMP"

  parse_days() {
    local v="${1%$'\r'}"
    case "$v" in
      ""|"N/A"|"not_supported"|"no_information") echo 9999 ;;
      *T*Z) days_since "$v" || echo 9999 ;;
      *) echo 9999 ;;
    esac
  }

  printf '%s\n' "$CR" \
  | tail -n +2 \
  | while IFS=, read -r user arn uid create pwd_enabled pwd_last_used _ a1_active _ a1_last_used _ a2_active _ a2_last_used _ rest; do
      D1="$(parse_days "${pwd_last_used//\"/}")"
      D2="$(parse_days "${a1_last_used//\"/}")"
      D3="$(parse_days "${a2_last_used//\"/}")"
      : "${D1:=9999}"; : "${D2:=9999}"; : "${D3:=9999}"
      MIN=$(( D1 < D2 ? (D1 < D3 ? D1 : D3) : (D2 < D3 ? D2 : D3) ))
      [ "${MIN:-9999}" -gt 90 ] && add High "| ${user//\"/} | $MIN | ⚠️ 最終活動>90日 | High |"
    done || true
fi

# ==== Access Analyzer ===============================================
{
  echo
  echo "## Access Analyzer"
  echo
  echo "| Analyzer | ステータス | リスク | 優先度 |"
  echo "|----------|------------|--------|--------|"
} >>"$TMP"

while read -r AN; do
  [ -z "$AN" ] && continue
  ST="$(aws accessanalyzer get-analyzer --analyzer-name "$AN" --query 'analyzer.status' --output text 2>/dev/null || echo UNKNOWN)"
  R=""; S=Low; [ "$ST" != "ACTIVE" ] && { R="⚠️ 非ACTIVE"; S=High; }
  add "$S" "| $AN | $ST | ${R:-} | $S |"
done < <(aws accessanalyzer list-analyzers --query 'analyzers[].name' --output text 2>/dev/null | tr '\t' '\n' || true)
if ! aws accessanalyzer list-analyzers --query 'length(analyzers)' --output text 2>/dev/null | grep -q '^[1-9]'; then
  add High "| N/A | 無効 | ⚠️ Analyzer未作成 | High |"
fi

# ==== S3（アカウントPAB） ==========================================
{
  echo
  echo "## S3 Public Access Block（Account）"
  echo
  echo "| Account | 全項目ON | リスク | 優先度 |"
  echo "|---------|----------|--------|--------|"
} >>"$TMP"
ACC="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo UNKNOWN)"
APAB="$(aws s3control get-public-access-block --account-id "$ACC" 2>/dev/null \
      | jq -r '[.PublicAccessBlockConfiguration.BlockPublicAcls,
                 .PublicAccessBlockConfiguration.IgnorePublicAcls,
                 .PublicAccessBlockConfiguration.BlockPublicPolicy,
                 .PublicAccessBlockConfiguration.RestrictPublicBuckets] | all' \
      2>/dev/null || echo false)"
R=""; S=Low; [ "$APAB" != "true" ] && { R="⚠️ いずれかOFF"; S=High; }
add "$S" "| $ACC | $APAB | ${R:-} | $S |"

# ==== S3（各バケット） =============================================
{
  echo
  echo "## S3"
  echo
  echo "| バケット | 暗号化 | バージョニング | PAB | ポリシー公開 | ACL公開 | TLS必須 | リスク | 優先度 |"
  echo "|----------|--------|----------------|-----|------------|--------|--------|--------|--------|"
} >>"$TMP"

while read -r B; do
  [ -z "$B" ] && continue
  PUB="$(aws s3api get-bucket-policy-status --bucket "$B" 2>/dev/null | jq -r '.PolicyStatus.IsPublic // false' || echo false)"
  ENC_ALG="$(aws s3api get-bucket-encryption --bucket "$B" 2>/dev/null \
        | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' 2>/dev/null || echo "なし")"
  [ -z "$ENC_ALG" ] && ENC_ALG="なし"
  ENC_KEYID="$(aws s3api get-bucket-encryption --bucket "$B" 2>/dev/null \
        | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID // empty' 2>/dev/null || true)"
  VER="$(aws s3api get-bucket-versioning --bucket "$B" 2>/dev/null | jq -r '.Status // "無効"' || echo "無効")"
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
  # KMS推奨（SSE-S3のみはLow提言）
  if [ "$ENC_ALG" = "AES256" ]; then R+=" ⚠️ KMS未使用（推奨）"; [ "$S" = Low ] && S=Low; fi
  [ "$VER" = "無効" ] && { R+=" ⚠️ バージョニング無効"; [ "$S" = Low ] && S=Medium; }
  [ "$BPAB" != "true" ] && { R+=" ⚠️ PAB不足"; [ "$S" = Low ] && S=Medium; }
  [ "$TLSREQ" != "true" ] && { R+=" ⚠️ TLS必須未設定"; [ "$S" = Low ] && S=Medium; }

  add "$S" "| $B | $ENC_ALG${ENC_KEYID:+(KMS)} | $VER | $BPAB | $PUB | $ACLPUB | $TLSREQ |${R:- } | $S |"
done < <(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' || true)

# ==== EC2 / EBS ======================================================
{
  echo
  echo "## EC2 / EBS"
  echo
  echo "| インスタンス | PublicIP | EBS暗号化 | IMDSv2 | リスク | 優先度 |"
  echo "|--------------|----------|-----------|--------|--------|--------|"
} >>"$TMP"

while read -r I; do
  [ -z "$I" ] && continue
  DESC="$(aws ec2 describe-instances --instance-ids "$I" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  PUBIP="$(echo "$DESC" | jq -r '.Reservations[0].Instances[0].PublicIpAddress // "None"')"
  TOKENS="$(echo "$DESC" | jq -r '.Reservations[0].Instances[0].MetadataOptions.HttpTokens // "unknown"')"
  VOLS="$(echo "$DESC" | jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[].Ebs.VolumeId // empty' | tr '\n' ' ')"
  R=""; S=Low; ENC_FLAG="N/A"
  [ "$PUBIP" != "None" ] && { R+=" ⚠️ PublicIP"; S=Medium; }
  [ "$TOKENS" != "required" ] && { R+=" ⚠️ IMDSv2未強制"; [ "$S" = Low ] && S=Medium; }
  if [ -n "${VOLS:-}" ]; then
    ENC_FLAG="OK"
    for V in $VOLS; do
      EN="$(aws ec2 describe-volumes --volume-ids "$V" --region "$REGION" --query 'Volumes[0].Encrypted' --output text 2>/dev/null || echo False)"
      [ "$EN" = "False" ] && { R+=" ⚠️ EBS暗号化なし($V)"; S=High; ENC_FLAG="NG"; }
    done
  fi
  add "$S" "| $I | $PUBIP | $ENC_FLAG | $TOKENS |${R:- } | $S |"
done < <(aws ec2 describe-instances --region "$REGION" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' || true)

# EBS 既定暗号化（アカウント設定）
{
  echo
  echo "## EBS Default Encryption（Account）"
  echo
  echo "| Account | 既定暗号化 | デフォルトKMS | リスク | 優先度 |"
  echo "|---------|------------|-------------|--------|--------|"
} >>"$TMP"
DEFENC="$(aws ec2 get-ebs-encryption-by-default --region "$REGION" --query 'EbsEncryptionByDefault' --output text 2>/dev/null || echo False)"
DEFKMS="$(aws ec2 get-ebs-default-kms-key-id --region "$REGION" --query 'KmsKeyId' --output text 2>/dev/null || echo None)"
R=""; S=Low; [ "$DEFENC" != "True" ] && { R="⚠️ 無効"; S=High; }
add "$S" "| $ACC | $DEFENC | $DEFKMS | ${R:-} | $S |"

# ==== RDS ============================================================
{
  echo
  echo "## RDS"
  echo
  echo "| DB | 暗号化 | Public | MultiAZ | Backup保持 | AutoMinorUpg | スナップ公開 | リスク | 優先度 |"
  echo "|----|--------|--------|---------|------------|--------------|--------------|--------|--------|"
} >>"$TMP"

while read -r DB; do
  [ -z "$DB" ] && continue
  INFO="$(aws rds describe-db-instances --db-instance-identifier "$DB" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  ENC="$(echo "$INFO" | jq -r '.DBInstances[0].StorageEncrypted // false')"
  PUB="$(echo "$INFO" | jq -r '.DBInstances[0].PubliclyAccessible // false')"
  MAZ="$(echo "$INFO" | jq -r '.DBInstances[0].MultiAZ // false')"
  BRET="$(echo "$INFO" | jq -r '.DBInstances[0].BackupRetentionPeriod // 0')"
  AMU="$(echo "$INFO" | jq -r '.DBInstances[0].AutoMinorVersionUpgrade // false')"
  R=""; S=Low; SNAP="Checked"
  [ "$ENC" = "false" ] && { R+=" ⚠️ 暗号化なし"; S=High; }
  [ "$PUB" = "true" ] && { R+=" ⚠️ Public"; S=High; }
  [ "$MAZ" = "false" ] && { R+=" ⚠️ 単一AZ"; [ "$S" = Low ] && S=Medium; }
  [ "${BRET:-0}" -lt 7 ] && { R+=" ⚠️ Backup保持<7日"; [ "$S" = Low ] && S=Medium; }
  [ "$AMU" = "false" ] && { R+=" ⚠️ 自動マイナーUPG無効"; [ "$S" = Low ] && S=Low; }
  while read -r SNAME; do
    [ -z "$SNAME" ] && continue
    ATTR="$(aws rds describe-db-snapshot-attributes --db-snapshot-identifier "$SNAME" --region "$REGION" \
            --query "DBSnapshotAttributesResult.DBSnapshotAttributes[?AttributeName=='restore'].AttributeValues[]" --output text 2>/dev/null || echo "")"
    echo "$ATTR" | grep -q '\ball\b' && { R+=" ⚠️ スナップ公開($SNAME)"; S=High; }
  done < <(aws rds describe-db-snapshots --db-instance-identifier "$DB" --region "$REGION" \
           --query 'DBSnapshots[].DBSnapshotIdentifier' --output text 2>/dev/null | tr '\t' '\n' || true)
  add "$S" "| $DB | $ENC | $PUB | $MAZ | ${BRET:-0} | $AMU | $SNAP |${R:- } | $S |"
done < <(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null | tr '\t' '\n' || true)

# ==== KMS ============================================================
{
  echo
  echo "## KMS"
  echo
  echo "| KeyId | Spec | Manager | Rotation | リスク | 優先度 |"
  echo "|-------|------|---------|----------|--------|--------|"
} >>"$TMP"

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
{
  echo
  echo "## CloudTrail"
  echo
  echo "| Trail | MultiRegion | Verify | Logging | CW Logs | DataEvents | Insights | リスク | 優先度 |"
  echo "|-------|-------------|--------|---------|---------|------------|----------|--------|--------|"
} >>"$TMP"

ANY_MULTI_LOGGING=false
while read -r T; do
  [ -z "$T" ] && continue
  INFO="$(aws cloudtrail get-trail --name "$T" --region "$REGION" 2>/dev/null || true)"
  MULTI="$(echo "$INFO" | jq -r '.Trail.IsMultiRegionTrail // false')"
  VERIFY="$(echo "$INFO" | jq -r '.Trail.LogFileValidationEnabled // false')"
  S3B="$(echo "$INFO" | jq -r '.Trail.S3BucketName // "None"')"
  CWLG="$(echo "$INFO" | jq -r '.Trail.CloudWatchLogsLogGroupArn // "None"')"
  LOGGING="$(aws cloudtrail get-trail-status --name "$T" --region "$REGION" --query 'IsLogging' --output text 2>/dev/null || echo False)"
  # Data events（AdvancedEventSelectorsにも対応）
  DEVT="$(aws cloudtrail get-event-selectors --trail-name "$T" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  HAS_DATA_STD="$(echo "$DEVT" | jq -r '[.EventSelectors[]?.DataResources[]? // empty] | length>0' 2>/dev/null || echo false)"
  HAS_DATA_ADV="$(echo "$DEVT" | jq -r '(.AdvancedEventSelectors // []) | length>0' 2>/dev/null || echo false)"
  if [ "$HAS_DATA_STD" = "true" ] || [ "$HAS_DATA_ADV" = "true" ]; then HAS_DATA="true"; else HAS_DATA="false"; fi
  INS="$(aws cloudtrail get-insight-selectors --trail-name "$T" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  HAS_INS="$(echo "$INS" | jq -r '.InsightSelectors | length>0' 2>/dev/null || echo false)"

  R=""; S=Low
  [ "$MULTI" = "false" ] && { R+=" ⚠️ マルチリージョン無効"; S=High; }
  [ "$VERIFY" = "false" ] && { R+=" ⚠️ 証跡検証無効"; S=High; }
  [ "$LOGGING" = "False" ] && { R+=" ⚠️ ログ停止中"; S=High; }
  [ "$HAS_DATA" != "true" ] && { R+=" ⚠️ データイベント未設定"; [ "$S" = Low ] && S=Medium; }
  [ "$HAS_INS" != "true" ] && { R+=" ⚠️ Insights無効"; [ "$S" = Low ] && S=Medium; }

  # CW Logs 連携 & 保持日数
  CWRET="None"
  if [ "$CWLG" != "None" ] && [ "$CWLG" != "null" ]; then
    LG="${CWLG##*:log-group:}"
    CWRET="$(aws logs describe-log-groups --log-group-name-prefix "$LG" --region "$REGION" \
            --query "logGroups[?logGroupName=='$LG'].retentionInDays | [0]" --output text 2>/dev/null || echo None)"
    [ "$CWRET" = "None" ] && { R+=" ⚠️ CloudWatchLogs保持未設定"; [ "$S" = Low ] && S=Medium; }
  else
    R+=" ⚠️ CloudWatchLogs連携なし"; [ "$S" = Low ] && S=Medium
  fi
  # 送信先S3の保護
  if [ "$S3B" != "None" ] && [ "$S3B" != "null" ]; then
    PUB2="$(aws s3api get-bucket-policy-status --bucket "$S3B" 2>/dev/null | jq -r '.PolicyStatus.IsPublic // false' || echo false)"
    ENC2="$(aws s3api get-bucket-encryption --bucket "$S3B" 2>/dev/null \
           | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' 2>/dev/null || echo "なし")"
    VER2="$(aws s3api get-bucket-versioning --bucket "$S3B" 2>/dev/null | jq -r '.Status // "無効"' || echo "無効")"
    OLOCK="$(aws s3api get-object-lock-configuration --bucket "$S3B" 2>/dev/null | jq -r '.ObjectLockConfiguration.ObjectLockEnabled // "None"' || echo "None")"
    [ "$PUB2" = "true" ] && { R+=" ⚠️ 送信先S3がPublic"; S=High; }
    [ "$ENC2" = "なし" ] && { R+=" ⚠️ 送信先S3暗号化なし"; S=High; }
    [ "$VER2" = "無効" ] && { R+=" ⚠️ 送信先S3バージョニング無効"; [ "$S" = Low ] && S=Medium; }
    [ "$OLOCK" != "Enabled" ] && { R+=" ⚠️ 送信先S3 ObjectLock無効"; [ "$S" = Low ] && S=Low; }
  fi
  [ "$MULTI" = "true" ] && [ "$LOGGING" = "True" ] && ANY_MULTI_LOGGING=true
  add "$S" "| $T | $MULTI | $VERIFY | $LOGGING | ${CWRET} | $HAS_DATA | $HAS_INS |${R:- } | $S |"
done < <(aws cloudtrail describe-trails --region "$REGION" --query 'trailList[].Name' --output text 2>/dev/null | tr '\t' '\n' || true)
if [ "${ANY_MULTI_LOGGING}" != "true" ]; then
  add High "| summary | - | - | - | - | - | - | ⚠️ マルチリージョン有効なTrailが稼働していません | High |"
fi

# ==== CloudWatch Logs ===============================================
{
  echo
  echo "## CloudWatch Logs"
  echo
  echo "| LogGroup | 保持日数 | KMS | リスク | 優先度 |"
  echo "|----------|----------|-----|--------|--------|"
} >>"$TMP"

# 1回で出ない数のため nextToken でページング
_next=""
while :; do
  if [ -n "$_next" ] && [ "$_next" != "None" ]; then
    PAGE="$(aws logs describe-log-groups --region "$REGION" --next-token "$_next" --output json 2>/dev/null || echo '{}')"
  else
    PAGE="$(aws logs describe-log-groups --region "$REGION" --output json 2>/dev/null || echo '{}')"
  fi
  echo "$PAGE" | jq -c '.logGroups[]?' | while read -r row; do
    LG="$(echo "$row" | jq -r '.logGroupName')"
    RET="$(echo "$row" | jq -r '.retentionInDays // "None"')"
    KMSK="$(echo "$row" | jq -r '.kmsKeyId // "None"')"
    R=""; S=Low
    [ "$RET" = "None" ] && { R+=" ⚠️ 保持未設定"; S=Medium; }
    [ "$KMSK" = "None" ] && { R+=" ⚠️ KMS暗号なし"; [ "$S" = Low ] && S=Low; }
    add "$S" "| $LG | $RET | $KMSK | ${R:-} | $S |"
  done
  _next="$(echo "$PAGE" | jq -r '.nextToken // "None"')"
  [ "$_next" = "None" ] && break
done

# ==== AWS Config =====================================================
{
  echo
  echo "## AWS Config"
  echo
  echo "| Recorder | recording | Delivery | リスク | 優先度 |"
  echo "|----------|-----------|----------|--------|--------|"
} >>"$TMP"

RC_JSON="$(aws configservice describe-configuration-recorder-status --region "$REGION" --output json 2>/dev/null || echo '{"ConfigurationRecordersStatus":[]}')"
DC_JSON="$(aws configservice describe-delivery-channel-status --region "$REGION" --output json 2>/dev/null || echo '{"DeliveryChannelsStatus":[]}')"
if [ "$(echo "$RC_JSON" | jq -r '.ConfigurationRecordersStatus | length')" = "0" ]; then
  add High "| N/A | False | None | ⚠️ Recorder未作成 | High |"
else
  echo "$RC_JSON" | jq -c '.ConfigurationRecordersStatus[]?' | while read -r r; do
    NAME="$(echo "$r" | jq -r '.name // "default"')"
    REC="$(echo "$r" | jq -r '.recording // false')"
    DEL="$(echo "$DC_JSON" | jq -r --arg n "$NAME" '.DeliveryChannelsStatus[]? | .configHistoryDeliveryInfo.lastStatus // "None"')"
    R=""; S=Low
    [ "$REC" != "true" ] && { R+=" ⚠️ Recorder無効"; S=High; }
    { [ "$DEL" = "Failure" ] || [ "$DEL" = "None" ]; } && { R+=" ⚠️ Delivery停止/未設定"; S=High; }
    add "$S" "| $NAME | $REC | $DEL | ${R:-} | $S |"
  done
fi

# ==== GuardDuty ======================================================
{
  echo
  echo "## GuardDuty"
  echo
  echo "| Detector | Findings | Features(Disabled数) | リスク | 優先度 |"
  echo "|----------|----------|----------------------|--------|--------|"
} >>"$TMP"

DET="$(aws guardduty list-detectors --region "$REGION" --query 'DetectorIds[0]' --output text 2>/dev/null || echo "")"
if [ -z "$DET" ] || [ "$DET" = "None" ]; then
  add High "| N/A | - | - | ⚠️ 無効 | High |"
else
  F="$(aws guardduty list-findings --detector-id "$DET" --region "$REGION" --query 'length(findingIds)' --output text 2>/dev/null || echo 0)"
  FEAT_JSON="$(aws guardduty describe-detector --detector-id "$DET" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  FEAT_DISABLED_CNT="$(echo "$FEAT_JSON" | jq -r '[.Features[]? | select((.Status!="ENABLED") and (.Name!=null))] | length' 2>/dev/null || echo 0)"
  R=""; S=Low
  [ "${F:-0}" -gt 0 ] && { R+=" ⚠️ Findingsあり(${F})"; S=High; }
  [ "${FEAT_DISABLED_CNT:-0}" -gt 0 ] && { R+=" ⚠️ 一部機能無効(${FEAT_DISABLED_CNT})"; [ "$S" = Low ] && S=Medium; }
  add "$S" "| $DET | ${F:-0} | ${FEAT_DISABLED_CNT:-0} | ${R:-} | $S |"
fi

# ==== Security Hub ===================================================
{
  echo
  echo "## Security Hub"
  echo
  echo "| 有効 | FSBP | CIS | リスク | 優先度 |"
  echo "|------|------|-----|--------|--------|"
} >>"$TMP"

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
{
  echo
  echo "## CI/CD"
  echo
  echo "| 対象 | 設定 | リスク | 優先度 |"
  echo "|------|------|--------|--------|"
} >>"$TMP"

# CodeBuild: privilegedMode = true は High
while read -r P; do
  [ -z "$P" ] && continue
  PRV="$(aws codebuild batch-get-projects --names "$P" --region "$REGION" \
        --query 'projects[0].environment.privilegedMode' --output text 2>/dev/null || echo False)"
  [ "$PRV" = "True" ] && add High "| codebuild:$P | privileged=true | Docker権限昇格の恐れ | High |"
done < <(aws codebuild list-projects --region "$REGION" --output text 2>/dev/null | tr '\t' '\n' || true)

# CodePipeline: ArtifactStore に KMS 無しは Medium（提言）
while read -r N; do
  [ -z "$N" ] && continue
  ART="$(aws codepipeline get-pipeline --name "$N" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  KMS="$(echo "$ART" | jq -r '.pipeline.artifactStore.encryptionKey.id // empty')"
  [ -z "$KMS" ] && add Medium "| codepipeline:$N | KMS=なし | アーティファクト無KMS（推奨） | Medium |"
done < <(aws codepipeline list-pipelines --region "$REGION" --query 'pipelines[].name' --output text 2>/dev/null | tr '\t' '\n' || true)

# ECR: ScanOnPush 無効は Medium、タグ不変/暗号化も
while read -r RPO; do
  [ -z "$RPO" ] && continue
  J="$(aws ecr describe-repositories --repository-names "$RPO" --region "$REGION" --output json 2>/dev/null || echo '{}')"
  S="$(echo "$J" | jq -r '.repositories[0].imageScanningConfiguration.scanOnPush // false')"
  MUT="$(echo "$J" | jq -r '.repositories[0].imageTagMutability // "MUTABLE"')"
  ENC_T="$(echo "$J" | jq -r '.repositories[0].encryptionConfiguration.encryptionType // "AES256"')"
  { [ "$S" = "false" ] || [ "$S" = "False" ]; } && add Medium "| ecr:$RPO | scanOnPush=false | 脆弱画像の混入恐れ | Medium |"
  [ "$MUT" = "MUTABLE" ] && add Medium "| ecr:$RPO | tagMutability=MUTABLE | タグ上書きリスク | Medium |"
  [ "$ENC_T" != "KMS" ] && add Low "| ecr:$RPO | encryption=$ENC_T | KMSでの暗号化推奨 | Low |"
done < <(aws ecr describe-repositories --region "$REGION" --query 'repositories[].repositoryName' --output text 2>/dev/null | tr '\t' '\n' || true)

# ==== ネットワーク（VPC Flow Logs） =================================
{
  echo
  echo "## VPC Flow Logs"
  echo
  echo "| VPC | FlowLogs数 | リスク | 優先度 |"
  echo "|-----|-----------|--------|--------|"
} >>"$TMP"

FLOGS_JSON="$(aws ec2 describe-flow-logs --region "$REGION" --output json 2>/dev/null || echo '{"FlowLogs":[]}')"
while read -r VPCID; do
  [ -z "$VPCID" ] && continue
  CNT="$(echo "$FLOGS_JSON" | jq -r --arg V "$VPCID" '[.FlowLogs[]? | select(.ResourceId==$V)] | length')"
  [ "${CNT:-0}" -eq 0 ] && add Medium "| $VPCID | 0 | FlowLogs無効（トラフィック追跡不可） | Medium |"
done < <(aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' '\n' || true)

# ==== Security Group（0.0.0.0/0: 22/3389 + IPv6） ===================
{
  echo
  echo "## Security Group（世界開放 SSH/RDP）"
  echo
  echo "| SG | Port | IPバージョン | リスク | 優先度 |"
  echo "|----|------|-------------|--------|--------|"
} >>"$TMP"

aws ec2 describe-security-groups --region "$REGION" --output json 2>/dev/null \
| jq -r '
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
' \
| sort -u \
| while IFS=$'\t' read -r SG PORT IPVER; do
    add High "| $SG | $PORT | $IPVER | 世界開放SSH/RDP | High |"
  done || true

# ==== Security Group（ワイドオープン/IPv6含む） =====================
{
  echo
  echo "## Security Group（ワイドオープン/IPv6）"
  echo
  echo "| SG | 内容 | リスク | 優先度 |"
  echo "|----|------|--------|--------|"
} >>"$TMP"

aws ec2 describe-security-groups --region "$REGION" --output json 2>/dev/null \
| jq -r '
  .SecurityGroups[] as $g
  | ($g.IpPermissions // [])[]? as $p
  | ( ($p.IpProtocol == "-1") or ($p.FromPort == null and $p.ToPort == null) ) as $all
  | ([ $p.IpRanges[]?.CidrIp     | select(. == "0.0.0.0/0") ] | length > 0) as $v4
  | ([ $p.Ipv6Ranges[]?.CidrIpv6 | select(. == "::/0") ]      | length > 0) as $v6
  | select( $all and ($v4 or $v6) )
  | [$g.GroupId, "ALL TCP/UDP/ICMP (IPv4/IPv6 :/0)"]
  | @tsv
' \
| sort -u \
| while IFS=$'\t' read -r SG DETAIL; do
    add High "| $SG | $DETAIL | ワイドオープン | High |"
  done || true

echo "🐈‍⬛ 処理終了"
