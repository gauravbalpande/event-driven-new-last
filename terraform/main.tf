# main.tf - Main Terraform Configuration

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
  }

  # Backend configuration for state management
  backend "s3" {
    bucket         = "terraform-state-megaminds-project"
    key            = "event-pipeline/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

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

# Local variables
locals {
  project_name = "event-pipeline"
  common_tags = {
    Project     = "EventDrivenPipeline"
    Environment = var.environment
  }
}

# S3 Bucket for Raw Data
resource "aws_s3_bucket" "raw_data" {
  bucket = "${local.project_name}-raw-data-${var.environment}"
}

resource "aws_s3_bucket_versioning" "raw_data" {
  bucket = aws_s3_bucket.raw_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_notification" "raw_data_notification" {
  bucket = aws_s3_bucket.raw_data.id

  queue {
    queue_arn     = aws_sqs_queue.file_processing_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
    filter_suffix = ".csv"
  }

  depends_on = [aws_sqs_queue_policy.file_processing_queue_policy]
}

# S3 Bucket for Processed Data
resource "aws_s3_bucket" "processed_data" {
  bucket = "${local.project_name}-processed-data-${var.environment}"
}

resource "aws_s3_bucket_versioning" "processed_data" {
  bucket = aws_s3_bucket.processed_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket for Reports
resource "aws_s3_bucket" "reports" {
  bucket = "${local.project_name}-reports-${var.environment}"
}

resource "aws_s3_bucket_lifecycle_configuration" "reports_lifecycle" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "archive-old-reports"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

# SQS Queue for file processing
resource "aws_sqs_queue" "file_processing_queue" {
  name                      = "${local.project_name}-file-processing-${var.environment}"
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 1209600 # 14 days
  receive_wait_time_seconds = 10
  visibility_timeout_seconds = 300 # 5 minutes

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

# Dead Letter Queue
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.project_name}-dlq-${var.environment}"
  message_retention_seconds = 1209600 # 14 days
}

# SQS Queue Policy to allow S3 to send messages
resource "aws_sqs_queue_policy" "file_processing_queue_policy" {
  queue_url = aws_sqs_queue.file_processing_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.file_processing_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.raw_data.arn
          }
        }
      }
    ]
  })
}

# DynamoDB Table for metadata and tracking
resource "aws_dynamodb_table" "file_metadata" {
  name           = "${local.project_name}-metadata-${var.environment}"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "fileId"
  
  attribute {
    name = "fileId"
    type = "S"
  }
  
  attribute {
    name = "processingStatus"
    type = "S"
  }

  attribute {
    name = "uploadTimestamp"
    type = "N"
  }

  global_secondary_index {
    name            = "StatusIndex"
    hash_key        = "processingStatus"
    range_key       = "uploadTimestamp"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.common_tags
}

# IAM Role for Lambda Data Processor
resource "aws_iam_role" "lambda_processor_role" {
  name = "${local.project_name}-processor-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for Lambda Data Processor
resource "aws_iam_role_policy" "lambda_processor_policy" {
  name = "${local.project_name}-processor-policy"
  role = aws_iam_role.lambda_processor_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.raw_data.arn}/*",
          "${aws_s3_bucket.processed_data.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.file_processing_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.file_metadata.arn,
          "${aws_dynamodb_table.file_metadata.arn}/index/*"
        ]
      }
    ]
  })
}

# Package Lambda function code
data "archive_file" "lambda_processor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/processor"
  output_path = "${path.module}/builds/processor.zip"
}

# Lambda Function - Data Processor
resource "aws_lambda_function" "data_processor" {
  filename         = data.archive_file.lambda_processor_zip.output_path
  function_name    = "${local.project_name}-processor-${var.environment}"
  role            = aws_iam_role.lambda_processor_role.arn
  handler         = "index.handler"
  source_code_hash = data.archive_file.lambda_processor_zip.output_base64sha256
  runtime         = "python3.11"
  timeout         = 300
  memory_size     = 512

  environment {
    variables = {
      PROCESSED_BUCKET = aws_s3_bucket.processed_data.bucket
      METADATA_TABLE   = aws_dynamodb_table.file_metadata.name
      ENVIRONMENT      = var.environment
    }
  }

  reserved_concurrent_executions = 10

  tracing_config {
    mode = "Active"
  }
}

# Lambda Event Source Mapping - SQS to Lambda
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.file_processing_queue.arn
  function_name    = aws_lambda_function.data_processor.arn
  batch_size       = 10
  enabled          = true

  scaling_config {
    maximum_concurrency = 10
  }
}

# CloudWatch Log Group for Processor Lambda
resource "aws_cloudwatch_log_group" "processor_logs" {
  name              = "/aws/lambda/${aws_lambda_function.data_processor.function_name}"
  retention_in_days = 30
}

# IAM Role for Lambda Report Generator
resource "aws_iam_role" "lambda_reporter_role" {
  name = "${local.project_name}-reporter-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for Lambda Report Generator
resource "aws_iam_role_policy" "lambda_reporter_policy" {
  name = "${local.project_name}-reporter-policy"
  role = aws_iam_role.lambda_reporter_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.reports.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.file_metadata.arn,
          "${aws_dynamodb_table.file_metadata.arn}/index/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.report_notifications.arn
      }
    ]
  })
}

# Package Lambda report generator code
data "archive_file" "lambda_reporter_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/reporter"
  output_path = "${path.module}/builds/reporter.zip"
}

# Lambda Function - Report Generator
resource "aws_lambda_function" "report_generator" {
  filename         = data.archive_file.lambda_reporter_zip.output_path
  function_name    = "${local.project_name}-reporter-${var.environment}"
  role            = aws_iam_role.lambda_reporter_role.arn
  handler         = "index.handler"
  source_code_hash = data.archive_file.lambda_reporter_zip.output_base64sha256
  runtime         = "python3.11"
  timeout         = 300
  memory_size     = 256

  environment {
    variables = {
      REPORTS_BUCKET = aws_s3_bucket.reports.bucket
      METADATA_TABLE = aws_dynamodb_table.file_metadata.name
      SNS_TOPIC_ARN  = aws_sns_topic.report_notifications.arn
      ENVIRONMENT    = var.environment
    }
  }

  tracing_config {
    mode = "Active"
  }
}

# CloudWatch Log Group for Reporter Lambda
resource "aws_cloudwatch_log_group" "reporter_logs" {
  name              = "/aws/lambda/${aws_lambda_function.report_generator.function_name}"
  retention_in_days = 30
}

# EventBridge Rule for Daily Report Generation
resource "aws_cloudwatch_event_rule" "daily_report" {
  name                = "${local.project_name}-daily-report-${var.environment}"
  description         = "Trigger daily report generation at 6 AM UTC"
  schedule_expression = "cron(0 6 * * ? *)"
}

resource "aws_cloudwatch_event_target" "daily_report_target" {
  rule      = aws_cloudwatch_event_rule.daily_report.name
  target_id = "ReportGeneratorLambda"
  arn       = aws_lambda_function.report_generator.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report_generator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_report.arn
}

# SNS Topic for Report Notifications
resource "aws_sns_topic" "report_notifications" {
  name = "${local.project_name}-reports-${var.environment}"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.report_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.project_name}-processor-errors-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "Alert when Lambda processor has too many errors"
  alarm_actions       = [aws_sns_topic.report_notifications.arn]

  dimensions = {
    FunctionName = aws_lambda_function.data_processor.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.project_name}-dlq-messages-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "300"
  statistic           = "Average"
  threshold           = "1"
  alarm_description   = "Alert when messages appear in DLQ"
  alarm_actions       = [aws_sns_topic.report_notifications.arn]

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.project_name}-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Lambda", "Invocations", { stat = "Sum", label = "Lambda Invocations" }],
            [".", "Errors", { stat = "Sum", label = "Lambda Errors" }],
            [".", "Duration", { stat = "Average", label = "Avg Duration" }]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "Lambda Metrics"
        }
      },
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", { stat = "Sum" }],
            [".", "NumberOfMessagesReceived", { stat = "Sum" }]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "SQS Queue Activity"
        }
      }
    ]
  })
}