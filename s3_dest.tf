# ============================================================
# レプリケーション先バケット（ap-northeast-3 / 大阪）
# ============================================================
resource "aws_s3_bucket" "dest" {
  provider      = aws.dest
  bucket        = local.dest_bucket
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "dest" {
  provider = aws.dest
  bucket   = aws_s3_bucket.dest.id
  versioning_configuration {
    status = "Enabled" # レプリ先もバージョニング必須
  }
}
