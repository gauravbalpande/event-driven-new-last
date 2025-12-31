############################
# Terraform Configuration
############################
terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

############################
# Provider
############################
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "EventDrivenPipeline"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner
    }
  }
}

############################
# Locals & Random Suffix
############################
locals {
  project_name = "event-pipeline"
}

resource "random_id" "suffix" {
  byte_length = 2
}

############################
# S3 Buckets
############################
resource "aws_s3_bucket" "raw_data" {
  bucket = "${local.project_name}-raw-data-${var.environment}-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "processed_data" {
  bucket = "${local.project_name}-processed-data-${var.environment}-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "reports" {
  bucket = "${local.project_name}-reports-${var.environment}-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "raw_data" {
  bucket = aws_s3_bucket.raw_data.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "processed_data" {
  bucket = aws_s3_bucket.processed_data.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports_lifecycle" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "archive-old"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

############################
# SQS Queues
############################
resource "aws_sqs_queue" "dlq" {
  name = "${local.project_name}-dlq-${var.environment}"
}

resource "aws_sqs_queue" "file_processing_queue" {
  name                      = "${local.project_name}-file-processing-${var.environment}"
  visibility_timeout_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "file_processing_queue_policy" {
  queue_url = aws_sqs_queue.file_processing_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.file_processing_queue.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_s3_bucket.raw_data.arn
        }
      }
    }]
  })
}

############################
# S3 → SQS Notification
############################
resource "aws_s3_bucket_notification" "raw_data_notification" {
  bucket = aws_s3_bucket.raw_data.id

  queue {
    queue_arn     = aws_sqs_queue.file_processing_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".csv"
  }

  depends_on = [aws_sqs_queue_policy.file_processing_queue_policy]
}

############################
# DynamoDB
############################
resource "aws_dynamodb_table" "file_metadata" {
  name         = "${local.project_name}-metadata-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "fileId"

  attribute {
    name = "fileId"
    type = "S"
  }

  tags = {
    Project = "EventDrivenPipeline"
  }
}

############################
# IAM Role - Processor
############################
resource "aws_iam_role" "lambda_processor_role" {
  name = "${local.project_name}-processor-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_processor_policy" {
  role = aws_iam_role.lambda_processor_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:*"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          "${aws_s3_bucket.raw_data.arn}/*",
          "${aws_s3_bucket.processed_data.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:*"]
        Resource = aws_sqs_queue.file_processing_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:*"]
        Resource = aws_dynamodb_table.file_metadata.arn
      }
    ]
  })
}

############################
# Lambda Processor
############################
data "archive_file" "processor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/processor"
  output_path = "${path.module}/builds/processor.zip"
}

resource "aws_lambda_function" "data_processor" {
  function_name = "${local.project_name}-processor-${var.environment}"
  filename      = data.archive_file.processor_zip.output_path
  role          = aws_iam_role.lambda_processor_role.arn
  handler       = "index.handler"
  runtime       = "python3.11"
  timeout       = 300
  memory_size   = 512
}

############################
# SQS → Lambda Mapping
############################
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.file_processing_queue.arn
  function_name    = aws_lambda_function.data_processor.arn
  batch_size       = 10
}

resource "aws_lambda_permission" "allow_sqs" {
  statement_id  = "AllowExecutionFromSQS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.data_processor.function_name
  principal     = "sqs.amazonaws.com"
  source_arn    = aws_sqs_queue.file_processing_queue.arn
}

############################
# SNS Notifications
############################
resource "aws_sns_topic" "report_notifications" {
  name = "${local.project_name}-reports-${var.environment}"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.report_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
