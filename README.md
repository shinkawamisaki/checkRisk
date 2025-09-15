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

## サンプル（一部）です。

こんな感じ↓でリスクについてのコメントがつきます

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

本ソフトウェア（checkR.sh および関連スクリプトを含む）は、非商用利用限定ライセンスの下で提供されます。

✅ 許可される利用
	•	個人利用
	•	教育・研究目的での利用
	•	自組織内での内部利用　（自社AWSへの使用OKです）
	•	改変および再配布（※非商用に限る）

❌ 禁止される利用
	•	あらゆる形態の商用利用（有償のコンサルティング、監査、サービス、納品物での利用含む）
	•	有償製品や有償オファリングの一部としての再配布
	•	リブランディング（名称・著作権表記の差し替え等）しての転売

📜 条件
	•	次の帰属表示を削除せず保持してください：
© 2025 Shinkawa. All rights reserved.
	•	改変版を再配布する場合は、同一のライセンス条件で配布してください。
	•	本ライセンスは PolyForm Noncommercial License および CC BY-NC-SA を参考に設計されています。

商用ライセンスに関するお問い合わせは、著作者までご連絡ください。

This tool is provided under a **Non-Commercial Use License**.

- ✅ Free to use for personal, educational, research, or internal purposes
- ❌ **Commercial use is prohibited**, including paid audits, services, or deliverables
- ✅ Modifications and redistribution are allowed under the same license
- 📌 Attribution required: © 2025 Shinkawa. All rights reserved

For commercial inquiries, please contact the author directly.
