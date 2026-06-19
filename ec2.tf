# ============================================================
# マルチパートアップロード計測用 EC2（インバウンド無し・SSM経由）
# ============================================================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.name_prefix}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# マルチパート計測でソースバケットへ読み書き＋中断アップロードの確認/清掃
data "aws_iam_policy_document" "ec2_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload",
      "s3:PutObjectTagging",
    ]
    resources = [
      aws_s3_bucket.source.arn,
      "${aws_s3_bucket.source.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "ec2_s3" {
  name   = "${var.name_prefix}-ec2-s3"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_s3.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name_prefix}-ec2"
  role = aws_iam_role.ec2.name
}

resource "aws_security_group" "ec2" {
  name_prefix = "${var.name_prefix}-ec2-"
  description = "egress only (SSM endpoints, S3)"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "host" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [aws_security_group.ec2.id]
  subnet_id              = data.aws_subnets.default.ids[0]

  metadata_options {
    http_tokens   = "required" # IMDSv2必須
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true
  }

  # destroy忘れの課金頭打ち（24h後に自動stop。terminateではない）
  user_data = <<-EOF
    #!/bin/bash
    shutdown -h +1440
  EOF

  tags = merge(local.tags, { Name = "${var.name_prefix}-host" })
}
