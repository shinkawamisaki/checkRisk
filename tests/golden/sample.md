# AWSセキュリティ監査レポート（要約）
- リージョン: ap-northeast-1
- アカウント: 111122223333

> このレポートは読み取り専用API（list/describe/get）のみ使用。Secrets Manager の値を取得するのは、OpenAI 整形を有効にしたときの API キー1件のみ。


## サマリー

- Critical: 1
- High:     17
- Medium:   9
- Low:      8

## IAM

| 対象 | 設定 | リスク | 優先度 |
|------|------|------|------|
| root | MFA=未設定 | ⚠️ root MFA未設定 | Critical |
| root | AccessKey=存在 | ⚠️ rootにアクセスキー | High |
| alice | MFA=1, Admin=yes | ⚠️ 管理者権限 ⚠️ キー作成>90日 | High |
| bob | MFA=0, Admin=no | ⚠️ MFA未設定 | High |
| svc-batch | MFA=0, Admin=no | ⚠️ MFA未設定 ⚠️ キー作成>90日 ⚠️ 最終使用>90日 | High |

## IAM Password Policy

| 長さ | 記号 | 数字 | 大小英 | 最大有効日 | リスク | 優先度 |
|------|------|------|------|------|------|------|
| 8 | false | true | true/true | 0 |  ⚠️ 長さ<12 ⚠️ 記号なし ⚠️ 期限なし | High |

## IAM（未使用>90日 ユーザー）

| User | 最終活動（日） | リスク | 優先度 |
|------|------|------|------|
| svc-batch | 250 | ⚠️ 最終活動>90日 | High |

## Access Analyzer

| Analyzer | ステータス | リスク | 優先度 |
|------|------|------|------|
| acct-analyzer | ACTIVE |  | Low |

## S3 Public Access Block（Account）

| Account | 全項目ON | リスク | 優先度 |
|------|------|------|------|
| 111122223333 | false | ⚠️ いずれかOFF | High |

## S3

| バケット | 暗号化 | バージョニング | PAB | ポリシー公開 | ACL公開 | TLS必須 | リスク | 優先度 |
|------|------|------|------|------|------|------|------|------|
| public-bucket | AES256 | 無効 | false | true | true | false | ⚠️ ポリシーで公開 ⚠️ ACLで公開 ⚠️ KMS未使用（推奨） ⚠️ バージョニング無効 ⚠️ PAB不足 ⚠️ TLS必須未設定 | High |
| logs-bucket | aws:kms(KMS) | Enabled | true | false | false | true |  | Low |
| plain-bucket | AES256 | 無効 | true | false | false | false | ⚠️ KMS未使用（推奨） ⚠️ バージョニング無効 ⚠️ TLS必須未設定 | Medium |

## EC2 / EBS

| インスタンス | PublicIP | EBS暗号化 | IMDSv2 | リスク | 優先度 |
|------|------|------|------|------|------|
| i-0aaa111 | 203.0.113.10 | NG | optional | ⚠️ PublicIP ⚠️ IMDSv2未強制 ⚠️ EBS暗号化なし(vol-0a2) | High |
| i-0bbb222 | None | OK | required |  | Low |

## EBS Default Encryption（Account）

| Account | 既定暗号化 | デフォルトKMS | リスク | 優先度 |
|------|------|------|------|------|
| 111122223333 | False | alias/aws/ebs | ⚠️ 無効 | High |

## RDS

| DB | 暗号化 | Public | MultiAZ | Backup保持 | AutoMinorUpg | スナップ公開 | リスク | 優先度 |
|------|------|------|------|------|------|------|------|------|
| app-db | false | true | false | 1 | false | Checked | ⚠️ 暗号化なし ⚠️ Public ⚠️ 単一AZ ⚠️ Backup保持<7日 ⚠️ 自動マイナーUPG無効 ⚠️ スナップ公開(app-db-snap-1) | High |

## KMS

| KeyId | Spec | Manager | Rotation | リスク | 優先度 |
|------|------|------|------|------|------|
| 11111111-1111-1111-1111-111111111111 | SYMMETRIC_DEFAULT | CUSTOMER | False | ⚠️ ローテーション無効 | High |
| 22222222-2222-2222-2222-222222222222 | SYMMETRIC_DEFAULT | AWS | N/A |  | Low |

## CloudTrail

| Trail | MultiRegion | Verify | Logging | CW Logs | DataEvents | Insights | リスク | 優先度 |
|------|------|------|------|------|------|------|------|------|
| trail-main | true | true | True | 90 | true | false | ⚠️ Insights無効 ⚠️ 送信先S3 ObjectLock無効 | Medium |
| org-trail-shadow | true | true | True | None | false | false | ⚠️ データイベント未設定 ⚠️ Insights無効 ⚠️ CloudWatchLogs連携なし ℹ️ 送信先S3は参照不可（別アカウント等） | Medium |

## CloudWatch Logs

| LogGroup | 保持日数 | KMS | リスク | 優先度 |
|------|------|------|------|------|
| /aws/lambda/notify | 365 | arn:aws:kms:ap-northeast-1:111122223333:key/11111111-1111-1111-1111-111111111111 |  | Low |
| /aws/cloudtrail/main | 90 | None |  ⚠️ KMS暗号なし | Low |
| /app/api | None | None |  ⚠️ 保持未設定 ⚠️ KMS暗号なし | Medium |

## AWS Config

| Recorder | recording | Delivery | リスク | 優先度 |
|------|------|------|------|------|
| default | true | SUCCESS |  | Low |

## GuardDuty

| Detector | Findings | Features(Disabled数) | リスク | 優先度 |
|------|------|------|------|------|
| det-1 | 2 | 1 |  ⚠️ Findingsあり(2) ⚠️ 一部機能無効(1) | High |

## Security Hub

| 有効 | FSBP | CIS | リスク | 優先度 |
|------|------|------|------|------|
| 有効 | 有効 | 無効 |  ⚠️ CIS未有効 | Medium |

## CI/CD

| 対象 | 設定 | リスク | 優先度 |
|------|------|------|------|
| codebuild:build-privileged | privileged=true | Docker権限昇格の恐れ | High |
| codepipeline:deploy | KMS=なし | アーティファクト無KMS（推奨） | Medium |
| ecr:app | scanOnPush=false | 脆弱画像の混入恐れ | Medium |
| ecr:app | tagMutability=MUTABLE | タグ上書きリスク | Medium |
| ecr:app | encryption=AES256 | KMSでの暗号化推奨 | Low |

## VPC Flow Logs

| VPC | FlowLogs数 | リスク | 優先度 |
|------|------|------|------|
| vpc-0bbb | 0 | FlowLogs無効（トラフィック追跡不可） | Medium |

## Security Group（世界開放 SSH/RDP）

| SG | Port | IPバージョン | リスク | 優先度 |
|------|------|------|------|------|
| sg-all6 | 22 | IPv6 | 世界開放SSH/RDP | High |
| sg-ssh | 22 | IPv4 | 世界開放SSH/RDP | High |

## Security Group（ワイドオープン/IPv6）

| SG | 内容 | リスク | 優先度 |
|------|------|------|------|
| sg-all6 | ALL TCP/UDP/ICMP (IPv4/IPv6 :/0) | ワイドオープン | High |
