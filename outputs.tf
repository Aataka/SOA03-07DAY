output "source_bucket" {
  description = "レプリケーション元バケット名"
  value       = aws_s3_bucket.source.id
}

output "dest_bucket" {
  description = "レプリケーション先バケット名（大阪）"
  value       = aws_s3_bucket.dest.id
}

output "dest_region" {
  value = var.dest_region
}

output "ec2_instance_id" {
  description = "マルチパート計測用インスタンスID（SSM接続先）"
  value       = aws_instance.host.id
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "replication_alarm" {
  value = aws_cloudwatch_metric_alarm.replication_latency.alarm_name
}
