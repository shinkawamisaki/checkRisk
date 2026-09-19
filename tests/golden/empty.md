# AWSセキュリティ監査レポート（要約）
- リージョン: ap-northeast-1
- アカウント: 111122223333

> このレポートは読み取り専用API（list/describe/get）のみ使用。Secrets Manager の値を取得するのは、OpenAI 整形を有効にしたときの API キー1件のみ。


## サマリー

- Critical: 0
- High:     0
- Medium:   1
- Low:      7

## IAM

| 対象 | 設定 | リスク | 優先度 |
|------|------|------|------|
| 該当なし | - | - | - |

## IAM Password Policy

| 長さ | 記号 | 数字 | 大小英 | 最大有効日 | リスク | 優先度 |
|------|------|------|------|------|------|------|
| 14 | true | true | true/true | 90 |  | Low |

## IAM（未使用>90日 ユーザー）

| User | 最終活動（日） | リスク | 優先度 |
|------|------|------|------|
| 該当なし | - | - | - |

## Access Analyzer

| Analyzer | ステータス | リスク | 優先度 |
|------|------|------|------|
| acct-analyzer | ACTIVE |  | Low |

## S3 Public Access Block（Account）

| Account | 全項目ON | リスク | 優先度 |
|------|------|------|------|
| 111122223333 | true |  | Low |

## S3

| バケット | 暗号化 | バージョニング | PAB | ポリシー公開 | ACL公開 | TLS必須 | リスク | 優先度 |
|------|------|------|------|------|------|------|------|------|
| 該当なし | - | - | - | - | - | - | - | - |

## EC2 / EBS

| インスタンス | PublicIP | EBS暗号化 | IMDSv2 | リスク | 優先度 |
|------|------|------|------|------|------|
| 該当なし | - | - | - | - | - |

## EBS Default Encryption（Account）

| Account | 既定暗号化 | デフォルトKMS | リスク | 優先度 |
|------|------|------|------|------|
| 111122223333 | True | alias/aws/ebs |  | Low |

## RDS

| DB | 暗号化 | Public | MultiAZ | Backup保持 | AutoMinorUpg | スナップ公開 | リスク | 優先度 |
|------|------|------|------|------|------|------|------|------|
| 該当なし | - | - | - | - | - | - | - | - |

## KMS

| KeyId | Spec | Manager | Rotation | リスク | 優先度 |
|------|------|------|------|------|------|
| 該当なし | - | - | - | - | - |

## CloudTrail

| Trail | MultiRegion | Verify | Logging | CW Logs | DataEvents | Insights | リスク | 優先度 |
|------|------|------|------|------|------|------|------|------|
| org-trail | true | true | True | None | true | true | ⚠️ CloudWatchLogs連携なし | Medium |

## CloudWatch Logs

| LogGroup | 保持日数 | KMS | リスク | 優先度 |
|------|------|------|------|------|
| 該当なし | - | - | - | - |

## AWS Config

| Recorder | recording | Delivery | リスク | 優先度 |
|------|------|------|------|------|
| default | true | SUCCESS |  | Low |

## GuardDuty

| Detector | Findings | Features(Disabled数) | リスク | 優先度 |
|------|------|------|------|------|
| det-1 | 0 | 0 |  | Low |

## Security Hub

| 有効 | FSBP | CIS | リスク | 優先度 |
|------|------|------|------|------|
| 有効 | 有効 | 有効 |  | Low |

## CI/CD

| 対象 | 設定 | リスク | 優先度 |
|------|------|------|------|
| 該当なし | - | - | - |

## VPC Flow Logs

| VPC | FlowLogs数 | リスク | 優先度 |
|------|------|------|------|
| 該当なし | - | - | - |

## Security Group（世界開放 SSH/RDP）

| SG | Port | IPバージョン | リスク | 優先度 |
|------|------|------|------|------|
| 該当なし | - | - | - | - |

## Security Group（ワイドオープン/IPv6）

| SG | 内容 | リスク | 優先度 |
|------|------|------|------|
| 該当なし | - | - | - |
