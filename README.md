# GPTコメントつきAWSリスク検査ツール

## ✨ これは何？

- AWSアカウントに対して IAM / S3 / CloudTrail などの構成リスクをチェックして
  Markdownレポートとして出力する**簡易監査ツール**です
- オプションで OpenAI API（ChatGPT）を使い、**読みやすいコメント付きレポート**に自動整形も可能です

## ✅ 特徴

| 特徴 | 内容 |
| --- | --- |
| 🪶 軽量 | bashスクリプト1本、依存は `aws`（CLI v2）と `jq` |
| 🍎 macOS 標準の bash で動く | bash 3.2 でも動くように書いてある（連想配列・`mapfile` 不使用） |
| 📄 Markdown出力 | レポートはそのままSlack投稿やPDF変換にも使える。指摘が無い表には「該当なし」行を入れる |
| 🤖 ChatGPT連携 | Markdownに短評・Top5・用語整形などを自動追加可能（任意） |
| 🔐 APIキーを引数・環境に出さない | キーは整形を有効にしたときだけ Secrets Manager から取得。子プロセスに export せず、curl へはヘッダファイル経由で渡す（`ps` に出ない） |
| 🛡️ 読み取り専用 | 呼ぶのは list / describe / get 系のみ。Secrets Manager の値を読むのは上記 API キー 1 件だけ（GPT なしなら 0 件）。S3 オブジェクト本文は取得しない |
| 🧪 オフラインテスト付き | 偽の `aws` コマンドとフィクスチャで、AWS に接続せずに全経路を検証できる（`tests/run.sh`） |

## 🔍 チェックする項目

- IAM（root の MFA / アクセスキー、ユーザーの MFA / 管理者権限 / キー作成・最終使用 >90日）
- IAM Password Policy
- IAM 未使用ユーザー（Credential Report、最終活動 >90日）
- Access Analyzer
- S3（アカウント PAB）、S3（各バケット：暗号化 / バージョニング / PAB / ポリシー公開 / ACL 公開 / TLS 必須）
- EC2 / EBS（PublicIP / IMDSv2 / EBS 暗号化）、EBS 既定暗号化
- RDS（暗号化 / Public / MultiAZ / バックアップ保持 / 自動マイナー UPG / スナップショット公開）
- KMS（カスタマー管理キーのローテーション）
- CloudTrail（マルチリージョン / 証跡検証 / ログ稼働 / CW Logs 連携と保持 / データイベント / Insights / 送信先 S3 の保護）
- CloudWatch Logs（保持日数 / KMS）
- AWS Config
- GuardDuty（有効化 / アーカイブされていない Findings 件数 / 無効な機能）
- Security Hub（FSBP / CIS）
- CI/CD（CodeBuild の privileged、CodePipeline のアーティファクト KMS、ECR の scanOnPush / タグ不変 / 暗号化）
- ネットワーク（VPC Flow Logs）
- Security Group（0.0.0.0/0・::/0 への 22/3389 開放、全ポート開放）

## サンプル（一部）

こんな感じ↓でリスクについてのコメントがつきます

GPTに読ませないモードも可能です

<img width="809" height="522" alt="スクリーンショット 2025-09-16 0 06 13" src="https://github.com/user-attachments/assets/aeebd42b-ec67-4a29-8886-e8294be472c7" />
<img width="788" height="719" alt="スクリーンショット 2025-09-16 0 06 52" src="https://github.com/user-attachments/assets/33e6dae3-b8a3-4bcf-953d-3073719032e9" />

💡 上記のスクリーンショットはテスト用AWSアカウントの状態をそのまま出力したものであり、本番環境ではありません。
むしろ意図的に未設定のリスクを残した状態にしておくことで、各種監査ツールや自作スクリプトの検証・チューニングを行う用途に使っています。

## 🔧 手順

### 前提

- AWS CLI v2、`jq`、bash 3.2 以上（macOS 標準で可）
- 対象アカウントの読み取り権限（`SecurityAudit` 管理ポリシー相当）。GPT 整形を使う場合は加えて、API キーを置いたシークレット 1 件への `secretsmanager:GetSecretValue`

### GPTコメントありの場合：Secrets Manager に OpenAI の API キーを保存

```bash
aws secretsmanager create-secret \
  --name openai/prod/key \
  --secret-string "sk-xxxxxxxxxxxxxxxxxxxx" \
  --region ap-northeast-1
```

> ✅ `openai/prod/key` という名前で保存します（`OPENAI_SECRET_NAME` で変更可）

### 実行（GPTコメントなし）

```bash
./checkRisk.sh              # リージョンは AWS_REGION、無ければ ap-northeast-1
./checkRisk.sh us-east-1    # 引数でリージョン指定
```

レポートは `output/checkRiskReport_<日時>.md` に出ます（`output/` は 700、ファイルは 600 で作成）。

### 実行（GPTコメントあり）

```bash
export POLISH_WITH_OPENAI=1
export OPENAI_SECRET_NAME=openai/prod/key
./checkRisk.sh
```

整形後のレポートは `output/checkRiskReport_<日時>_polished.md` に出ます。

GPTのモデルを変えたい場合（デフォルトは `gpt-4.1-mini`、失敗時のフォールバックは `gpt-4.1`）：

```bash
export OPENAI_MODEL=gpt-4.1
```

## 🔐 なぜ Secrets Manager 経由にするのか？

| 方法 | 安全性 | 備考 |
| --- | --- | --- |
| `export OPENAI_API_KEY=...` | ⚠️ 低 | シェル履歴や子プロセスの環境から漏れる危険あり |
| `.env`ファイル | ⚠️ 中 | `.gitignore`が必要、漏洩リスクあり |
| **Secrets Manager** | ✅ 高 | IAMポリシー制御＋取得が CloudTrail に記録される |

スクリプト側でも、取得したキーは export せず、curl のコマンドライン引数にも載せません（プロセス置換のヘッダファイルで渡す）。

## 🙈 GPT（OpenAI API）に渡す前のマスク

整形を有効にしたとき、レポート本文は次をマスクしてから送信します。

| マスクする | 例 |
| --- | --- |
| AWS アカウント ID（12桁） | `11**********` |
| アクセスキー ID（AKIA/ASIA/…） | `[ACCESS-KEY-ID]` |
| ARN 内のアカウント ID とリソース部 | `arn:aws:iam::12**********:[RESOURCE]` |
| IPv4 アドレス | `[IP]` |
| メールアドレス | `[EMAIL]` |

**マスクしないもの**：バケット名、IAM ユーザー名、インスタンス ID、KMS キー ID、Security Group ID、ロググループ名など。これらを外部に出したくない場合は GPT 整形を使わないでください。

## 🧪 テスト（AWS に接続しない）

```bash
bash tests/run.sh
```

- `tests/fake-aws/` … 偽の `aws` コマンド。`tests/fixtures/<シナリオ>/<service>/<operation>.json` を応答として返す（`--query` は jmespath で評価）
- `tests/fixtures/sample/` … 指摘が多いテスト用アカウント、`tests/fixtures/empty/` … 指摘ゼロのアカウント
- `tests/fake_openai.py` … 偽の OpenAI API（受け取ったヘッダと本文を記録）
- `tests/golden/*.md` … 期待するレポート。出力を意図的に変えたときは `UPDATE_GOLDEN=1 bash tests/run.sh` で更新

確認していること：構文と shellcheck、呼び出しが読み取り系 API だけであること、GPT なしでは Secrets Manager を呼ばないこと、日付判定・集計・各検出ロジック、GPT へ送る本文がマスク済みであること。

`fake_aws.py` には `jmespath` が必要です。`pip install jmespath` するか、Homebrew の AWS CLI に同梱の python（自動検出）を使います。

## 📝 変更履歴

### 2026-09-19

オフラインテストを作って検証したところ、次の不具合が見つかったので修正しました。

- **日付判定が macOS で効いていなかった**：AWS CLI v2 は日時を `2024-01-15T10:00:00+00:00` 形式で出すが、`Z` 形式しか解釈していなかった。結果、macOS では「キー作成 >90日」「最終使用 >90日」が一度も出ず、Credential Report の「未使用ユーザー」は全員 9999 日扱いだった
- **Credential Report の列ずれ**：`password_last_changed` や `access_key_1_last_rotated` を「最終使用日」として読んでいた
- **EBS 暗号化の誤検知**：`IFS` の設定により複数ボリュームが 1 つの ID として渡され、API エラーを「暗号化なし」と判定していた
- **CloudTrail の CloudWatch Logs 保持日数が読めない**：ロググループ ARN 末尾の `:*` を名前に含めていた
- **他リージョンがホームの Trail**：名前で問い合わせると解決できず「ログ停止中」等の誤検知。ARN で問い合わせるようにした
- **GuardDuty の Findings が常に 0**：応答キーは `FindingIds`（大文字始まり）。あわせてアーカイブ済みを除外
- **集計漏れ**：パイプで回していたループがサブシェルになり、未使用ユーザー・ロググループ・Config・Security Group の件数がサマリーに入っていなかった
- **GPT なしでも Secrets Manager を呼んでいた**：整形を有効にしたときだけ取得するようにし、キーを export しない・curl の引数に載せないよう変更
- bash 3.2 で `$'\U…'` が展開されず、GPT への指示文に `\U0001F4DD` がそのまま入っていた
- CodeBuild の一覧に `PROJECTS` という見出し語が混ざっていた（`--query` 未指定）

API 呼び出しも減らしました（サンプルアカウントで 103 → 83 回）。

## License：非商用利用限定 / 商用利用禁止ライセンス

SPDX-License-Identifier: LicenseRef-Shinkawa-NC-1.1
Shinkawa Non-Commercial License v1.1 (with Commercial Service Provider Exception)
最終更新: 2025-09-28
著作権表示: © 2025 Shinkawa. All rights reserved.

【適用範囲 / Scope】
本ライセンスは、このリポジトリの checkRisk.sh（および付随ドキュメント）に適用されます。

日本語条文
1. 定義
  「非商用」とは、対価（直接・間接を問わず）を得ることを目的としない利用。
2. 許諾（非商用）
  非商用に限り、使用・複製・改変・再配布（本ライセンス全文と帰属表示を保持、同一条件）を無償で許可。
3. 禁止（商用）
  有償のコンサル・監査・導入/設定/保守・受託/納品での利用、有償製品への組込み、リブランディング転売、サブライセンスを禁止。
4. 例外（商用サービス提供者例外）
  上記にかかわらず、**著作権者 Shinkawa（および著作権者が明示的に許諾した者）**は、
  本ソフトウェアを用いた**有償の導入・設定・カスタマイズ・保守・マネージド運用**を第三者へ提供できます。
  この例外は第三者への**サブライセンス権・商用再配布権**を与えるものではありません。
5. 商用ライセンス
  商用利用が必要な場合は別途、著作権者と商用ライセンス契約を締結してください。
6. 帰属・通知
  「© 2025 Shinkawa. All rights reserved. Licensed under Shinkawa Non-Commercial License v1.1.」を保持。
7. 免責
  本ソフトウェアは「現状のまま」。いかなる保証も責任も負いません。
8. 終了
  条項違反で自動終了。終了後は使用を停止。

English (for convenience)
1. Grant (Non-commercial): Use/copy/modify/redistribute for non-commercial purposes only, keeping this license and attribution under the same terms.
2. Prohibited Uses: Any commercial use incl. paid consulting/audits/deployment/customization/support/managed services, inclusion in paid products, rebranding/reselling, sublicensing.
3. Commercial Service Provider Exception: **Licensor (Shinkawa) and parties explicitly authorized by the Licensor** may provide paid services using the Software. No sublicense or commercial redistribution rights to third parties.
4. Commercial License: Contact the Licensor for a separate commercial license.
5. Attribution/Notice: Keep “© 2025 Shinkawa. All rights reserved. Licensed under Shinkawa Non-Commercial License v1.1.”
6. Disclaimer & Termination: AS IS; breach terminates the license.
