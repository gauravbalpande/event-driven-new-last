"""
Lambda Function: Data Processor
Processes files from S3, transforms data, and stores results
"""

import json
import boto3
import os
from datetime import datetime
import csv
import io
import uuid
import traceback

# Initialize AWS clients
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')

# Environment variables
PROCESSED_BUCKET = os.environ['PROCESSED_BUCKET']
METADATA_TABLE = os.environ['METADATA_TABLE']
table = dynamodb.Table(METADATA_TABLE)

def handler(event, context):
    """
    Main Lambda handler function
    Processes SQS messages containing S3 event notifications
    """
    print(f"Received event with {len(event['Records'])} records")
    
    successful = 0
    failed = 0
    
    for record in event['Records']:
        try:
            # Parse SQS message
            message_body = json.loads(record['body'])
            
            # Handle S3 event notification
            if 'Records' in message_body:
                for s3_record in message_body['Records']:
                    result = process_s3_event(s3_record)
                    if result:
                        successful += 1
                    else:
                        failed += 1
        except Exception as e:
            print(f"Error processing record: {str(e)}")
            print(traceback.format_exc())
            failed += 1
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'successful': successful,
            'failed': failed
        })
    }

def process_s3_event(s3_record):
    """
    Process a single S3 event record
    """
    try:
        # Extract S3 details
        bucket_name = s3_record['s3']['bucket']['name']
        object_key = s3_record['s3']['object']['key']
        file_size = s3_record['s3']['object']['size']
        
        print(f"Processing file: s3://{bucket_name}/{object_key}")
        
        # Generate unique file ID
        file_id = str(uuid.uuid4())
        
        # Update DynamoDB with initial status
        update_metadata(
            file_id=file_id,
            file_name=object_key,
            status='PROCESSING',
            file_size=file_size
        )
        
        # Download and process file
        response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
        file_content = response['Body'].read().decode('utf-8')
        
        # Process the data (example: CSV processing)
        processed_data = process_csv_data(file_content)
        
        # Generate output filename
        output_key = generate_output_key(object_key)
        
        # Upload processed data to S3
        s3_client.put_object(
            Bucket=PROCESSED_BUCKET,
            Key=output_key,
            Body=json.dumps(processed_data, indent=2),
            ContentType='application/json'
        )
        
        # Update DynamoDB with success status
        update_metadata(
            file_id=file_id,
            file_name=object_key,
            status='COMPLETED',
            file_size=file_size,
            processed_key=output_key,
            record_count=len(processed_data.get('records', []))
        )
        
        print(f"Successfully processed file: {object_key}")
        return True
        
    except Exception as e:
        print(f"Error processing S3 event: {str(e)}")
        print(traceback.format_exc())
        
        # Update DynamoDB with error status
        try:
            update_metadata(
                file_id=file_id,
                file_name=object_key,
                status='FAILED',
                file_size=file_size,
                error_message=str(e)
            )
        except:
            pass
        
        return False

def process_csv_data(csv_content):
    """
    Process CSV data and perform transformations
    This is a simple example - customize based on your needs
    """
    csv_reader = csv.DictReader(io.StringIO(csv_content))
    
    records = []
    summary = {
        'total_records': 0,
        'valid_records': 0,
        'invalid_records': 0
    }
    
    for row in csv_reader:
        summary['total_records'] += 1
        
        # Data validation and transformation
        try:
            # Example transformation: clean and validate data
            cleaned_row = {
                k.strip(): v.strip() if isinstance(v, str) else v 
                for k, v in row.items()
            }
            
            # Add metadata
            cleaned_row['processed_at'] = datetime.utcnow().isoformat()
            cleaned_row['row_id'] = str(uuid.uuid4())
            
            records.append(cleaned_row)
            summary['valid_records'] += 1
            
        except Exception as e:
            print(f"Error processing row: {str(e)}")
            summary['invalid_records'] += 1
    
    return {
        'summary': summary,
        'records': records,
        'processed_timestamp': datetime.utcnow().isoformat()
    }

def update_metadata(file_id, file_name, status, file_size, 
                    processed_key=None, record_count=None, error_message=None):
    """
    Update file metadata in DynamoDB
    """
    timestamp = int(datetime.utcnow().timestamp())
    
    item = {
        'fileId': file_id,
        'fileName': file_name,
        'processingStatus': status,
        'uploadTimestamp': timestamp,
        'fileSize': file_size,
        'lastUpdated': datetime.utcnow().isoformat()
    }
    
    if processed_key:
        item['processedKey'] = processed_key
    
    if record_count is not None:
        item['recordCount'] = record_count
    
    if error_message:
        item['errorMessage'] = error_message
    
    table.put_item(Item=item)
    print(f"Updated metadata for file: {file_name} with status: {status}")

def generate_output_key(input_key):
    """
    Generate output S3 key based on input key
    """
    # Extract filename without extension
    filename = input_key.split('/')[-1].rsplit('.', 1)[0]
    
    # Generate output path with date partitioning
    now = datetime.utcnow()
    output_key = f"processed/{now.year}/{now.month:02d}/{now.day:02d}/{filename}_{now.strftime('%H%M%S')}.json"
    
    return output_key