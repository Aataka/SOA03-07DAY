variable "region" {
  description = "プライマリリージョン（レプリケーション元）"
  type        = string
  default     = "ap-northeast-1"
}

variable "dest_region" {
  description = "レプリケーション先リージョン"
  type        = string
  default     = "ap-northeast-3"
}

variable "name_prefix" {
  description = "リソース名プレフィックス"
  type        = string
  default     = "soa03-07"
}

variable "notification_email" {
  description = "SNS通知先メール（空ならサブスクリプションを作成しない）"
  type        = string
  default     = ""
}

variable "enable_replication_metrics" {
  description = "S3レプリケーションメトリクス(ReplicationLatency等)を有効化。falseだとメトリクスが出力されず、アラームは永久にINSUFFICIENT_DATA(仮説Cのトラップ実証用)"
  type        = bool
  default     = true
}

variable "enable_rtc" {
  description = "Replication Time Control(15分SLA)。enable_replication_metrics=true が前提"
  type        = bool
  default     = true
}
