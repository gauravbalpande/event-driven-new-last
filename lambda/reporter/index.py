"""
Lambda Function: Daily Report Generator
Generates daily summary reports from processed data
"""

import json
import boto3
import os
from datetime import datetime, timedelta
from decimal import Decimal
from boto3.dynamodb.conditions import Key, Attr

# Initialize AWS clients
s3_client = boto3.client('s3')
sns_client = boto3.client('sns')
dynamodb = boto3.resource('dynamodb')

# Environment variables
REPORTS_BUCKET = os.environ['REPORTS_BUCKET']
METADATA_TABLE = os.environ['METADATA_TABLE']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
ENVIRONMENT = os.environ['ENVIRONMENT']

table = dynamodb.Table(METADATA_TABLE)

def handler(event, context):
    """
    Main handler for daily report generation
    """
    print("Starting daily report generation...")
    
    try:
        # Calculate time range (last 24 hours)
        end_time = datetime.utcnow()
        start_time = end_time - timedelta(days=1)
        
        # Fetch data from DynamoDB
        report_data = fetch_report_data(start_time, end_time)
        
        # Generate report
        report = generate_report(report_data, start_time, end_time)
        
        # Save report to S3
        report_key = save_report_to_s3(report, end_time)
        
        # Send notification
        send_notification(report, report_key)
        
        print("Report generation completed successfully")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Report generated successfully',
                'report_key': report_key
            })
        }
        
    except Exception as e:
        print(f"Error generating report: {str(e)}")
        import traceback
        print(traceback.format_exc())
        
        # Send error notification
        send_error_notification(str(e))
        
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e)
            })
        }

def fetch_report_data(start_time, end_time):
    """
    Fetch data from DynamoDB for the specified time range
    """
    start_timestamp = int(start_time.timestamp())
    end_timestamp = int(end_time.timestamp())
    
    # Scan table for records in time range
    response = table.scan(
        FilterExpression=Attr('uploadTimestamp').between(start_timestamp, end_timestamp)
    )
    
    items = response.get('Items', [])
    
    # Handle pagination
    while 'LastEvaluatedKey' in response:
        response = table.scan(
            FilterExpression=Attr('uploadTimestamp').between(start_timestamp, end_timestamp),
            ExclusiveStartKey=response['LastEvaluatedKey']
        )
        items.extend(response.get('Items', []))
    
    print(f"Fetched {len(items)} records from DynamoDB")
    return items

def generate_report(data, start_time, end_time):
    """
    Generate comprehensive report from data
    """
    # Initialize counters
    total_files = len(data)
    completed_files = sum(1 for item in data if item.get('processingStatus') == 'COMPLETED')
    failed_files = sum(1 for item in data if item.get('processingStatus') == 'FAILED')
    processing_files = sum(1 for item in data if item.get('processingStatus') == 'PROCESSING')
    
    total_records = sum(int(item.get('recordCount', 0)) for item in data if item.get('recordCount'))
    total_size_bytes = sum(int(item.get('fileSize', 0)) for item in data)
    total_size_mb = total_size_bytes / (1024 * 1024)
    
    # Calculate success rate
    success_rate = (completed_files / total_files * 100) if total_files > 0 else 0
    
    # Group by hour
    hourly_stats = {}
    for item in data:
        timestamp = int(item.get('uploadTimestamp', 0))
        hour = datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:00')
        
        if hour not in hourly_stats:
            hourly_stats[hour] = {'count': 0, 'completed': 0, 'failed': 0}
        
        hourly_stats[hour]['count'] += 1
        if item.get('processingStatus') == 'COMPLETED':
            hourly_stats[hour]['completed'] += 1
        elif item.get('processingStatus') == 'FAILED':
            hourly_stats[hour]['failed'] += 1
    
    # Collect error messages
    errors = []
    for item in data:
        if item.get('processingStatus') == 'FAILED' and item.get('errorMessage'):
            errors.append({
                'fileName': item.get('fileName', 'Unknown'),
                'error': item.get('errorMessage', 'No error message'),
                'timestamp': datetime.fromtimestamp(int(item.get('uploadTimestamp', 0))).isoformat()
            })
    
    # Build report structure
    report = {
        'report_metadata': {
            'generated_at': datetime.utcnow().isoformat(),
            'report_period_start': start_time.isoformat(),
            'report_period_end': end_time.isoformat(),
            'environment': ENVIRONMENT
        },
        'summary': {
            'total_files_processed': total_files,
            'successful_files': completed_files,
            'failed_files': failed_files,
            'in_progress_files': processing_files,
            'success_rate_percent': round(success_rate, 2),
            'total_records_processed': total_records,
            'total_data_size_mb': round(total_size_mb, 2)
        },
        'hourly_breakdown': hourly_stats,
        'errors': errors[:10],  # Limit to top 10 errors
        'top_files': sorted(
            [{'fileName': item.get('fileName'), 'recordCount': int(item.get('recordCount', 0))} 
             for item in data if item.get('recordCount')],
            key=lambda x: x['recordCount'],
            reverse=True
        )[:10]
    }
    
    return report

def save_report_to_s3(report, timestamp):
    """
    Save report to S3 bucket
    """
    # Generate report key with date partitioning
    report_key = f"daily-reports/{timestamp.year}/{timestamp.month:02d}/{timestamp.day:02d}/report_{timestamp.strftime('%Y%m%d_%H%M%S')}.json"
    
    # Convert Decimal to float for JSON serialization
    report_json = json.dumps(report, indent=2, default=decimal_default)
    
    # Upload to S3
    s3_client.put_object(
        Bucket=REPORTS_BUCKET,
        Key=report_key,
        Body=report_json,
        ContentType='application/json'
    )
    
    print(f"Report saved to s3://{REPORTS_BUCKET}/{report_key}")
    
    # Also save as HTML
    html_report = generate_html_report(report)
    html_key = report_key.replace('.json', '.html')
    
    s3_client.put_object(
        Bucket=REPORTS_BUCKET,
        Key=html_key,
        Body=html_report,
        ContentType='text/html'
    )
    
    return report_key

def generate_html_report(report):
    """
    Generate HTML version of the report
    """
    summary = report['summary']
    
    html = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <title>Daily Data Processing Report</title>
        <style>
            body {{ font-family: Arial, sans-serif; margin: 20px; }}
            h1 {{ color: #333; }}
            table {{ border-collapse: collapse; width: 100%; margin: 20px 0; }}
            th, td {{ border: 1px solid #ddd; padding: 12px; text-align: left; }}
            th {{ background-color: #4CAF50; color: white; }}
            .success {{ color: green; font-weight: bold; }}
            .error {{ color: red; font-weight: bold; }}
            .metric {{ font-size: 24px; font-weight: bold; margin: 10px 0; }}
        </style>
    </head>
    <body>
        <h1>Daily Data Processing Report</h1>
        <p><strong>Environment:</strong> {report['report_metadata']['environment']}</p>
        <p><strong>Report Period:</strong> {report['report_metadata']['report_period_start']} to {report['report_metadata']['report_period_end']}</p>
        
        <h2>Summary</h2>
        <div class="metric">Total Files: {summary['total_files_processed']}</div>
        <div class="metric success">✓ Successful: {summary['successful_files']}</div>
        <div class="metric error">✗ Failed: {summary['failed_files']}</div>
        <div class="metric">Success Rate: {summary['success_rate_percent']}%</div>
        <div class="metric">Total Records: {summary['total_records_processed']}</div>
        <div class="metric">Total Data: {summary['total_data_size_mb']} MB</div>
        
        <h2>Top Files by Record Count</h2>
        <table>
            <tr>
                <th>File Name</th>
                <th>Record Count</th>
            </tr>
    """
    
    for file_info in report['top_files']:
        html += f"""
            <tr>
                <td>{file_info['fileName']}</td>
                <td>{file_info['recordCount']}</td>
            </tr>
        """
    
    html += """
        </table>
        
        <h2>Recent Errors</h2>
        <table>
            <tr>
                <th>File Name</th>
                <th>Error Message</th>
                <th>Timestamp</th>
            </tr>
    """
    
    for error in report['errors']:
        html += f"""
            <tr>
                <td>{error['fileName']}</td>
                <td>{error['error']}</td>
                <td>{error['timestamp']}</td>
            </tr>
        """
    
    html += """
        </table>
    </body>
    </html>
    """
    
    return html

def send_notification(report, report_key):
    """
    Send SNS notification with report summary
    """
    summary = report['summary']
    
    subject = f"Daily Data Processing Report - {ENVIRONMENT.upper()} - {datetime.utcnow().strftime('%Y-%m-%d')}"
    
    message = f"""
Daily Data Processing Report

Environment: {ENVIRONMENT}
Generated At: {report['report_metadata']['generated_at']}

SUMMARY
=======
Total Files Processed: {summary['total_files_processed']}
Successful: {summary['successful_files']}
Failed: {summary['failed_files']}
Success Rate: {summary['success_rate_percent']}%
Total Records: {summary['total_records_processed']}
Total Data Size: {summary['total_data_size_mb']} MB

Full report available at:
s3://{REPORTS_BUCKET}/{report_key}

HTML Report:
s3://{REPORTS_BUCKET}/{report_key.replace('.json', '.html')}
"""
    
    if summary['failed_files'] > 0:
        message += f"\n\n⚠️ WARNING: {summary['failed_files']} files failed processing. Check the full report for details."
    
    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject,
        Message=message
    )
    
    print("Notification sent successfully")

def send_error_notification(error_message):
    """
    Send error notification when report generation fails
    """
    subject = f"ERROR: Daily Report Generation Failed - {ENVIRONMENT.upper()}"
    
    message = f"""
Report generation failed!

Environment: {ENVIRONMENT}
Time: {datetime.utcnow().isoformat()}

Error Message:
{error_message}

Please investigate immediately.
"""
    
    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject,
        Message=message
    )

def decimal_default(obj):
    """Helper function to convert Decimal to float for JSON serialization"""
    if isinstance(obj, Decimal):
        return float(obj)
    raise TypeError