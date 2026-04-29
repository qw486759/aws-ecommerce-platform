# ─────────────────────────────────────────────────────────────────────────────
# dynamodb.tf — DynamoDB table for order storage
#
# Design decisions:
#   - PAY_PER_REQUEST (on-demand) billing: no idle cost, scales automatically.
#   - order_id as the partition key ensures each order has a unique, fast lookup.
#   - A Global Secondary Index on user_id enables efficient per-user order queries
#     without scanning the full table.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "orders" {
  name         = "${var.project_name}-orders"
  billing_mode = "PAY_PER_REQUEST" # on-demand — no cost when idle
  hash_key     = "order_id"

  # Primary key attribute
  attribute {
    name = "order_id"
    type = "S" # String
  }

  # Attribute required by the GSI below
  attribute {
    name = "user_id"
    type = "S"
  }

  # GSI allows queries like "give me all orders for user X"
  global_secondary_index {
    name            = "user-index"
    hash_key        = "user_id"
    projection_type = "ALL" # project every attribute into the index
  }

  tags = {
    Name        = "${var.project_name}-orders"
    Environment = "demo"
    Project     = var.project_name
  }
}
