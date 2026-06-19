# ============================================================
# レプリケーション元バケット（ap-northeast-1）
# ============================================================
resource "aws_s3_bucket" "source" {
  bucket        = local.src_bucket
  force_destroy = true # 検証後のdestroyを簡単にする（バージョン込みで削除）
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "source" {
  bucket = aws_s3_bucket.source.id
  versioning_configuration {
    status = "Enabled" # CRRはバージョニング必須
  }
}

# 仮説A: 不完全マルチパートアップロードを7日で自動清掃する
# （中断パートは通常のオブジェクト一覧に出ないがストレージ課金され続ける）
resource "aws_s3_bucket_lifecycle_configuration" "source" {
  bucket     = aws_s3_bucket.source.id
  depends_on = [aws_s3_bucket_versioning.source]

  rule {
    id     = "DeleteIncompleteUploads"
    status = "Enabled"

    filter {} # バケット内のすべてのオブジェクトに適用

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# 仮説B: リクエストメトリクス(1分粒度・有料)を有効化し、
# アップロード中の PutObject / UploadPart 数・レイテンシを観測する
resource "aws_s3_bucket_metric" "source_requests" {
  bucket = aws_s3_bucket.source.id
  name   = "EntireBucket"
}
