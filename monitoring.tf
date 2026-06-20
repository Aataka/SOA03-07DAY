# ============================================================
# 監視（SNS + CloudWatchアラーム）
# ============================================================
resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-replication-alerts"
  tags = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# 仮説C(却下した素朴な設計): ReplicationLatency は metrics 無効だと存在せず、
# 有効でも健全・高速複製では datapoint が立たず INSUFFICIENT_DATA のまま
# → 一次ヘルス信号には使えない（記事の対比用に残す）
resource "aws_cloudwatch_metric_alarm" "replication_latency" {
  alarm_name          = "${var.name_prefix}-ReplicationLatency"
  namespace           = "AWS/S3"
  metric_name         = "ReplicationLatency"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_description   = "CRRレプリ遅延が15分SLAを超過。メトリクス未有効だとそもそも発火しない"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    SourceBucket      = aws_s3_bucket.source.id
    DestinationBucket = aws_s3_bucket.dest.id
    RuleId            = "myreplicationrule"
  }
}

# 仮説C(採用した一次ヘルス信号): OperationsFailedReplication は metrics 有効時に
# 失敗0でも安定して datapoint を出す数少ない複製メトリクス。失敗>=1 を即通知する。
resource "aws_cloudwatch_metric_alarm" "replication_failed" {
  alarm_name          = "${var.name_prefix}-OperationsFailedReplication"
  namespace           = "AWS/S3"
  metric_name         = "OperationsFailedReplication"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "CRR の複製失敗を検知（failed >= 1）。これが実運用の一次アラーム"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    SourceBucket      = aws_s3_bucket.source.id
    DestinationBucket = aws_s3_bucket.dest.id
    RuleId            = "myreplicationrule"
  }
}

# 仮説C: レプリ未処理オペレーションが解消しない＝バックログ滞留を検知
resource "aws_cloudwatch_metric_alarm" "replication_backlog" {
  alarm_name          = "${var.name_prefix}-OperationsPendingReplication"
  namespace           = "AWS/S3"
  metric_name         = "OperationsPendingReplication"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "5分間レプリ待ちが解消しない＝バックログ滞留"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    SourceBucket      = aws_s3_bucket.source.id
    DestinationBucket = aws_s3_bucket.dest.id
    RuleId            = "myreplicationrule"
  }
}
