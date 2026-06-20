# ============================================================
# クロスリージョンレプリケーション（CRR）
# ============================================================

# --- レプリケーション用IAMロール ---
data "aws_iam_policy_document" "replication_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  name               = "${var.name_prefix}-s3-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "replication" {
  statement {
    sid    = "SourceRead"
    effect = "Allow"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.source.arn]
  }
  statement {
    sid    = "SourceObjects"
    effect = "Allow"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = ["${aws_s3_bucket.source.arn}/*"]
  }
  statement {
    sid    = "DestWrite"
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]
    resources = ["${aws_s3_bucket.dest.arn}/*"]
  }
}

resource "aws_iam_role_policy" "replication" {
  name   = "${var.name_prefix}-s3-replication"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication.json
}

# --- レプリケーションルール ---
# 仮説C: メトリクス/RTCを有効化（無効だと ReplicationLatency 等が出ずアラーム不発）
# 仮説D: フィルタは prefix(completed) AND tag(status=final)、宛先はGIR、削除マーカーは非伝播
resource "aws_s3_bucket_replication_configuration" "source" {
  depends_on = [
    aws_s3_bucket_versioning.source,
    aws_s3_bucket_versioning.dest,
  ]

  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.source.id

  rule {
    id       = "myreplicationrule"
    status   = "Enabled"
    priority = 0

    filter {
      and {
        prefix = "completed"
        tags = {
          status = "final"
        }
      }
    }

    # 仮説D: 削除マーカーは伝播させない（タグフィルタ併用時は Disabled が必須でもある）
    delete_marker_replication {
      status = "Disabled"
    }

    destination {
      bucket        = aws_s3_bucket.dest.arn
      storage_class = "GLACIER_IR" # Glacier Instant Retrieval

      # メトリクス/RTC は無効時にブロックごと省く（status=Disabled で残すとAPIに弾かれるため）
      dynamic "metrics" {
        for_each = var.enable_replication_metrics ? [1] : []
        content {
          status = "Enabled"
          event_threshold {
            minutes = 15
          }
        }
      }

      dynamic "replication_time" {
        for_each = (var.enable_rtc && var.enable_replication_metrics) ? [1] : []
        content {
          status = "Enabled"
          time {
            minutes = 15
          }
        }
      }
    }
  }
}
