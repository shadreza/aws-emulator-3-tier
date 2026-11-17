"""Notes API: GET and POST /api/notes, stored in DynamoDB.

The function holds no secret. Its IAM role lets it write and query one
table, and that is all it can do.
"""
import json
import os
import time
import uuid

import boto3

ddb = boto3.client("dynamodb")
TABLE = os.environ["TABLE_NAME"]


def reply(status, body):
    return {"statusCode": status,
            "headers": {"content-type": "application/json"},
            "body": json.dumps(body)}


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")

    if method == "POST":
        try:
            text = (json.loads(event.get("body") or "{}").get("body") or "").strip()
        except json.JSONDecodeError:
            return reply(400, {"error": "body must be JSON"})
        if not text or len(text) > 500:
            return reply(400, {"error": "a note is 1 to 500 characters"})
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        note_id = f"{now}#{uuid.uuid4().hex[:8]}"  # sorts by time
        ddb.put_item(TableName=TABLE, Item={
            "pk": {"S": "note"}, "id": {"S": note_id},
            "body": {"S": text}, "created_at": {"S": now}})
        return reply(201, {"id": note_id, "body": text, "created_at": now})

    out = ddb.query(TableName=TABLE,
                    KeyConditionExpression="pk = :pk",
                    ExpressionAttributeValues={":pk": {"S": "note"}},
                    ScanIndexForward=False, Limit=50)
    notes = [{"id": i["id"]["S"], "body": i["body"]["S"], "created_at": i["created_at"]["S"]}
             for i in out.get("Items", [])]
    return reply(200, {"notes": notes})
