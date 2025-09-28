# GPTコメントつきAWSリスク検査ツール

## ✨ これは何？

- AWSアカウントに対して IAM/S3/CloudTrail 構成のリスクをチェックして
    
    Markdownレポートとして出力する**簡易監査ツール**です
    
- オプションで OpenAI API（ChatGPT）を使い、**読みやすいコメント付きレポート**に自動整形も可能です

## ✅ 特徴

| 特徴 | 内容 |
| --- | --- |
| 🪶 軽量 | bashスクリプト1本、依存も `aws` / `jq` 程度 |
| 📄 Markdown出力 | レポートはそのままSlack投稿やPDF変換にも使える |
| 🤖 ChatGPT連携 | Markdownに短評・Top5・用語整形などを自動追加可能（任意） |
| 🔐 安全配布 | APIキーは Secrets Manager から取得し、履歴やログに残さない |
| 🛡️ 機密値を取得しない | 上記APIキー以外のSecrets/SSMの値参照はゼロ、S3オブジェクト本文は未取得、KMSはSign/Verifyのみ。|

## 🔍 チェックする項目
- IAM、IAM Password Policy、IAM 未使用ユーザー（Credential Report）
- Access Analyzer
- S3（アカウントPAB）、S3（各バケット）
- EC2 / EBS
- RDS
- KMS
- CloudTrail
- CloudWatch Logs
- AWS Config
- GuardDuty
- Security Hub
- CI/CD（CodeBuild / CodePipeline / ECR）
- ネットワーク（VPC Flow Logs）
- Security Group（0.0.0.0/0: 22/3389 + IPv6）、Security Group（ワイドオープン/IPv6含む）

## サンプル（一部）

こんな感じ↓でリスクについてのコメントがつきます

GPTに読ませないモードも可能です

なお事前にマスキングしているためGPT（OpenAI API）に機密情報は渡しません

<img width="809" height="522" alt="スクリーンショット 2025-09-16 0 06 13" src="https://github.com/user-attachments/assets/aeebd42b-ec67-4a29-8886-e8294be472c7" />
<img width="788" height="719" alt="スクリーンショット 2025-09-16 0 06 52" src="https://github.com/user-attachments/assets/33e6dae3-b8a3-4bcf-953d-3073719032e9" />

💡 なお、上記のスクリーンショットはテスト用AWSアカウントの状態をそのまま出力したものであり、本番環境ではありません。
むしろ意図的に未設定のリスクを残した状態にしておくことで、各種監査ツールや自作スクリプトの検証・チューニングを行う用途に使っています。


## 🔧 手順

### GPTコメントありの場合Secrets Manager に chatGPTのAPIキーを保存

```bash
aws secretsmanager create-secret \
  --name openai/prod/key \
  --secret-string "sk-xxxxxxxxxxxxxxxxxxxx" \
  --region ap-northeast-1

```

> ✅ openai/prod/key という名前で保存します（変更可）
> 

### 実行（GPTコメントなし）

```bash
./checkRisk.sh
```

---

### 実行（GPTコメントあり）

```bash
export POLISH_WITH_OPENAI=1
export OPENAI_SECRET_NAME=openai/prod/key
./checkRisk.sh
```

 GPTのモデルを変えたい場合 下記を追加（デフォルトは4.1miniです。下記は4.1モデルに変える場合）

```jsx
export OPENAI_MODEL=gpt-4.1
```

## 🔐 なぜ Secrets Manager 経由にするのか？

| 方法 | 安全性 | 備考 |
| --- | --- | --- |
| `export OPENAI_API_KEY=...` | ⚠️ 低 | 履歴や`ps`コマンドから漏れる危険あり |
| `.env`ファイル | ⚠️ 中 | `.gitignore`が必要、漏洩リスクあり |
| **Secrets Manager** | ✅ 高 | IAMポリシー制御＋ログに残らない |

## License：非商用利用限定 / 商用利用禁止ライセンス
SPDX-License-Identifier: LicenseRef-Shinkawa-NC-1.1
Shinkawa Non-Commercial License v1.1 (with Commercial Service Provider Exception)
最終更新: 2025-09-28
著作権表示: © 2025 Shinkawa. All rights reserved.

【適用範囲 / Scope】
本ライセンスは、このリポジトリの checkR.sh（および付随ドキュメント）に適用されます。

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
