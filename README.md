# SOA03-07DAY — S3 マルチパートアップロード / クロスリージョンレプリケーション 実測検証

AWS Skill Builder ラボ *「Multi-part Uploads, Batch Operations, and Cross-Region Replication with S3」* を題材に、
ラボが省略している **運用監視の観点** を Terraform で再現し、実機で測る。

実測値・考察は別途まとめる（本リポジトリには含めない）。本READMEは **再現手順（Runbook）** を扱う。

## 検証する想定（仮説）

| | 想定 |
|---|---|
| **A** | 不完全マルチパートアップロードの滞留パートは通常のオブジェクト一覧に出ないが**ストレージ課金され続ける**。CloudWatch `BucketSizeBytes` では切り分けられず、可視化は Storage Lens が要る。 |
| **B** | CLI の `max_concurrent_requests` / multipart 設定でアップロードの**スループットが変わる**。S3側の可視化は Request metrics（有料・1分粒度）。 |
| **C** | CRR のレプリケーション遅延は**既定では監視できない**。`ReplicationLatency` 等は Replication metrics を有効化しないと**存在せず**、アラームは永久に `INSUFFICIENT_DATA`。RTC で15分SLA。 |
| **D** | レプリフィルタは prefix **AND** tag。片方だけのオブジェクトはレプリされない。**削除マーカーは既定で伝播しない**。 |

## 構成

```
[ ap-northeast-1 (東京) ]                         [ ap-northeast-3 (大阪) ]
                                                          
  EC2 t3.micro ──(SSM)                                    
   （インバウンド無し）                                   
        │ aws s3 cp（マルチパート）                       
        ▼                                                 
  ┌──────────────────────────┐    CRR rule          ┌──────────────────────┐
  │ source バケット          │  prefix=completed     │ dest バケット        │
  │  versioning ON           │  AND tag status=final │  versioning ON       │
  │  lifecycle: abort MPU 7d │ ───────────────────▶ │  storage class = GIR │
  │  request metrics         │  RTC 15min + metrics  │                      │
  └──────────────────────────┘  削除マーカー非伝播     └──────────────────────┘
        │ ReplicationLatency / OperationsPendingReplication
        ▼
   CloudWatch アラーム ──▶ SNS
```

- **source**（東京）: versioning / lifecycle（不完全MPU 7日清掃）/ request metrics
- **dest**（大阪）: versioning / 宛先ストレージクラス = Glacier Instant Retrieval
- **CRR**: フィルタ `prefix=completed AND tag status=final`、RTC(15分)+メトリクス、削除マーカー非伝播
- **監視**: `ReplicationLatency`・`OperationsPendingReplication` アラーム + SNS
- **EC2**: マルチパート計測用。SG は egress のみ、SSM 経由、IMDSv2 必須、`shutdown -h +1440`

## 前提

- Terraform >= 1.5（検証時 v1.14 / AWS provider v6）
- AWS 認証はファイルベース（`~/.aws/`、region `ap-northeast-1`）
- EC2 / SSM / S3 / CloudWatch / SNS が使えるアカウント
- 大阪リージョン（ap-northeast-3）が有効化済みであること

## 変数

| 変数 | 既定 | 説明 |
|---|---|---|
| `region` | `ap-northeast-1` | レプリ元 |
| `dest_region` | `ap-northeast-3` | レプリ先 |
| `name_prefix` | `soa03-07` | リソース名プレフィックス |
| `notification_email` | `""` | 設定すると SNS メール購読を作成（確認は手動） |
| `enable_replication_metrics` | `true` | `false` でメトリクス無効＝**仮説Cのトラップ**（アラーム不発）を実証 |
| `enable_rtc` | `true` | Replication Time Control（15分SLA）。metrics 有効が前提 |

## 使い方

```bash
cd ~/projects/SOA03-07DAY
terraform init
terraform plan
terraform apply            # 既定: metrics + RTC 有効

# 主要な出力
SRC=$(terraform output -raw source_bucket)
DST=$(terraform output -raw dest_bucket)
IID=$(terraform output -raw ec2_instance_id)
```

メール通知も使うなら `terraform apply -var notification_email=you@example.com`（届く確認メールは手動承認。SNS確認リンクの直クリックは自動解除されることがあるので、Token を抽出して `aws sns confirm-subscription` 推奨）。

---

## 検証 Runbook

EC2 へはインバウンドを開けず **SSM 経由**で実行する。先にヘルパを定義（SSM Run Command は **root** で走る点に注意）。

```bash
run() {  # EC2 上でコマンドを実行し、完了を待って標準出力を返す
  cid=$(aws ssm send-command --instance-ids "$IID" \
    --document-name AWS-RunShellScript \
    --parameters commands="$1" \
    --query Command.CommandId --output text)
  aws ssm wait command-executed --command-id "$cid" --instance-id "$IID" 2>/dev/null
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$IID" \
    --query StandardOutputContent --output text
}
```

### 仮説B — マルチパート並列度のスループット

```bash
# 1GB のテストファイル生成（dd の sparse トリック）＋ multipart 設定
run "dd if=/dev/zero of=/tmp/1GB.file bs=1 count=0 seek=1G; aws configure set default.s3.multipart_threshold 64MB; aws configure set default.s3.multipart_chunksize 16MB; ls -al /tmp/1GB.file"

# 並列度 1 / 3 / 8 で転送時間を比較
run "aws configure set default.s3.max_concurrent_requests 1; { time aws s3 cp /tmp/1GB.file s3://$SRC/upload-c1.test; } 2>&1"
run "aws configure set default.s3.max_concurrent_requests 3; { time aws s3 cp /tmp/1GB.file s3://$SRC/upload-c3.test; } 2>&1"
run "aws configure set default.s3.max_concurrent_requests 8; { time aws s3 cp /tmp/1GB.file s3://$SRC/upload-c8.test; } 2>&1"
```

Request metrics（`PutObject`/`UploadPart` 数）はコンソール or `aws cloudwatch get-metric-statistics --namespace AWS/S3 --metric-name PutRequests` で観測。

### 仮説A — 不完全マルチパートアップロードの不可視性

```bash
# threshold を下げ multipart を確実化 → SIGKILL で中断（SIGTERM だと CLI が自動 abort するため）
run "aws configure set default.s3.multipart_threshold 16MB; timeout -s KILL 5 aws s3 cp /tmp/1GB.file s3://$SRC/upload-abort.test; echo '--- killed ---'; aws s3api list-multipart-uploads --bucket $SRC --query 'Uploads[].{Key:Key,Id:UploadId}' --output table"

# 滞留パートの合計サイズ（UploadId は上の出力から）
UID=$(run "aws s3api list-multipart-uploads --bucket $SRC --query 'Uploads[0].UploadId' --output text")
run "aws s3api list-parts --bucket $SRC --key upload-abort.test --upload-id $UID --query 'sum(Parts[].Size)'"
```

- `BucketSizeBytes`（日次・翌日反映）に中断分が計上されるかを観測 → **仮説Aのトラップ確認**
- Storage Lens 既定ダッシュボード（アカウント単位・無料）で「不完全MPUバイト」を確認
- 清掃: `run "aws s3api abort-multipart-upload --bucket $SRC --key upload-abort.test --upload-id $UID"`（lifecycle は翌日非同期なので手動でも実演）

### 仮説C — レプリケーション監視のトラップ → 有効化

```bash
# (1) トラップ: メトリクス無効で再apply → ReplicationLatency メトリクスが存在しないことを確認
terraform apply -var enable_replication_metrics=false
echo "hello $(date)" > /tmp/r.txt
aws s3 cp /tmp/r.txt s3://$SRC/completed/r1.txt --tagging "status=final"
aws cloudwatch list-metrics --namespace AWS/S3 --metric-name ReplicationLatency \
  --dimensions Name=SourceBucket,Value=$SRC          # → 空（=アラームは INSUFFICIENT_DATA）

# (2) 有効化して再apply → レプリ遅延を実測
terraform apply
aws s3 cp /tmp/r.txt s3://$SRC/completed/r2.txt --tagging "status=final"
aws s3api head-object --bucket $SRC --key completed/r2.txt --query ReplicationStatus   # PENDING→COMPLETED
aws s3api list-objects-v2 --bucket $DST --prefix completed/ --query 'Contents[].Key'   # 宛先に出現

# ReplicationLatency（数分後）
aws cloudwatch get-metric-statistics --namespace AWS/S3 --metric-name ReplicationLatency \
  --dimensions Name=SourceBucket,Value=$SRC Name=DestinationBucket,Value=$DST Name=RuleId,Value=myreplicationrule \
  --start-time $(date -u -d '-30 min' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 60 --statistics Maximum
```

### 仮説D — フィルタ AND ＋ 削除マーカー非伝播

```bash
# タグ無し（prefix のみ一致）→ レプリされない
aws s3 cp /tmp/r.txt s3://$SRC/completed/notag.txt
# prefix 違い（タグのみ一致）→ レプリされない
aws s3 cp /tmp/r.txt s3://$SRC/other/tagged.txt --tagging "status=final"
sleep 60
aws s3api list-objects-v2 --bucket $DST --query 'Contents[].Key'   # notag.txt / other/ は来ない

# 削除マーカー非伝播: ソース削除 → 宛先は残存
aws s3api delete-object --bucket $SRC --key completed/r2.txt        # 削除マーカー（versioned）
aws s3api head-object --bucket $DST --key completed/r2.txt          # 宛先はまだ存在
```

---

## クリーンアップ

```bash
terraform destroy
# 残骸確認（force_destroy でオブジェクトごと消える想定）
aws s3 ls | grep "$SRC\|$DST" || echo "no buckets"
```

> 中断アップロードを手動 abort せず destroy した場合、`force_destroy = true` で滞留パートも削除される。

---

## ハマりどころ

- **`ReplicationLatency` 等は Replication metrics 有効化が前提**。無効のままアラームを組むと永久に `INSUFFICIENT_DATA`（メトリクス自体が出ない）。`enable_replication_metrics=false` で再現できる。
- **不完全MPUの中断は `timeout -s KILL`（SIGKILL）で**。SIGTERM/SIGINT だと aws CLI がマルチパートアップロードを自動 abort してパートが残らない。
- **レプリ対象タグは `aws s3 cp --tagging "status=final"`** で付与。フィルタは prefix `completed/` AND tag の両方一致が必要。
- **削除マーカーはタグフィルタ併用時 `delete_marker_replication = Disabled` が必須**（かつ本検証の狙いどおり非伝播になる）。
- **RTC（`replication_time`）＋タグフィルタ**：apply で弾かれたら `terraform apply -var enable_rtc=false`（メトリクスのみ）にフォールバック。
- **宛先ストレージクラス `GLACIER_IR`**：大阪リージョンで利用可だが、未対応エラー時は `destination.storage_class` を見直す。
- **SSM Run Command は root 実行**：`aws configure set` は `/root/.aws/config` に書かれる。Session Manager 対話（ssm-user）とは別プロファイルになる点に注意。
- **CRR はバージョニング必須**：source/dest 両方で `versioning = Enabled`。`replication_configuration` は両 versioning に `depends_on`。
- （開発環境）WSL を Bash ツール経由で叩くと `$HOME` 化け・入れ子クォート崩れが起きるため、複雑なコマンドは `_*.sh` に書いて絶対パスで実行し、出力はログにリダイレクトして読む。

## コスト目安

S3 ストレージ・同一リージョン転送はほぼ無料、CRR 対象は数KB。RTC/メトリクス/リクエストメトリクスは数セント、EC2 t3.micro 約1〜1.5h。**合計 < $0.20**。検証後は必ず `terraform destroy`。
