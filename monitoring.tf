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

# 仮説C: レプリ遅延が15分SLAを超えたら通知
# treat_missing_data="missing" → メトリクス未出力時はINSUFFICIENT_DATA（トラップの可視化）
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
