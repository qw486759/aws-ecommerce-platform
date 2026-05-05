"""
E-Commerce FastAPI Application
Handles product management (MySQL/RDS) and order management (DynamoDB).
"""

from decimal import Decimal
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
from fastapi import FastAPI, HTTPException
from boto3.dynamodb.conditions import Key
import boto3
import pymysql
import os
import uuid

app = FastAPI(title="E-Commerce API", version="1.0.")

# ─── Configuration ─────────────────────────────────────
# Environment variables injected by EC2 user_data via systemd service
ENVIRONMENT  = os.getenv("ENVIRONMENT", "local").lower()
DB_HOST      = os.getenv("DB_HOST")
if not DB_HOST:
    if ENVIRONMENT in ("local", ""):
        DB_HOST = "localhost"
    else:
        raise RuntimeError("DB_HOST must be set for staging/production environments")
DB_USER      = os.getenv("DB_USER", "admin")
DB_PASSWORD  = os.getenv("DB_PASSWORD", "password")
DB_NAME      = os.getenv("DB_NAME", "ecommerce")
AWS_REGION   = os.getenv("AWS_REGION", "us-east-1")
DYNAMODB_TABLE = os.getenv("DYNAMODB_TABLE") or os.getenv("DYNAMO_TABLE", "ecommerce-orders")

# ─── Request / Response Models ─────────────────────────
class Product(BaseModel):
    name: str
    description: Optional[str] = ""
    price: float
    stock: int = 0

class ProductResponse(Product):
    id: int

class OrderItem(BaseModel):
    product_id: int
    quantity: int
    price: float

class Order(BaseModel):
    user_id: str
    items: List[OrderItem]
    total_amount: float

class OrderResponse(Order):
    order_id: str
    status: str
    created_at: str

# ─── Database Connections ──────────────────────────────
def get_db():
    """Return a PyMySQL connection to the RDS MySQL instance."""
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        cursorclass=pymysql.cursors.DictCursor
    )

def get_dynamo():
    """
    Return a boto3 DynamoDB resource.
    Uses explicit boto3.Session to ensure the correct AWS region is set
    when running on EC2 with an IAM instance profile.
    """
    session = boto3.Session(region_name="us-east-1")
    return session.resource("dynamodb")

# ─── Health Check ──────────────────────────────────────
@app.get("/health")
def health():
    """ALB health check endpoint. Returns service status and UTC timestamp."""
    return {"status": "healthy", "timestamp": datetime.utcnow().isoformat()}

# ─── Products — backed by RDS MySQL ────────────────────
@app.get("/products", response_model=List[ProductResponse])
def list_products():
    """Retrieve all products from the MySQL products table."""
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM products")
            return cur.fetchall()
    finally:
        conn.close()

@app.get("/products/{product_id}", response_model=ProductResponse)
def get_product(product_id: int):
    """Retrieve a single product by primary key. Returns 404 if not found."""
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM products WHERE id = %s", (product_id,))
            product = cur.fetchone()
            if not product:
                raise HTTPException(status_code=404, detail="Product not found")
            return product
    finally:
        conn.close()

@app.post("/products", response_model=ProductResponse, status_code=201)
def create_product(product: Product):
    """Insert a new product into MySQL and return the created record."""
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO products (name, description, price, stock) VALUES (%s, %s, %s, %s)",
                (product.name, product.description, product.price, product.stock)
            )
            conn.commit()
            cur.execute("SELECT * FROM products WHERE id = LAST_INSERT_ID()")
            return cur.fetchone()
    finally:
        conn.close()

# ─── Orders — backed by DynamoDB ───────────────────────
@app.get("/orders/{user_id}", response_model=List[OrderResponse])
def get_orders(user_id: str):
    """
    Query all orders for a given user using the DynamoDB Global Secondary Index
    (user-index) on the user_id attribute.
    """
    dynamo = get_dynamo()
    table = dynamo.Table(DYNAMODB_TABLE)
    response = table.query(
        IndexName="user-index",
        KeyConditionExpression=Key("user_id").eq(user_id)
    )
    return response.get("Items", [])

@app.post("/orders", response_model=OrderResponse, status_code=201)
def create_order(order: Order):
    """
    Write a new order to DynamoDB.
    Float values are converted to Decimal because DynamoDB does not support
    Python float types natively.
    """
    try:
        dynamo = get_dynamo()
        table = dynamo.Table(DYNAMODB_TABLE)
        order_id   = str(uuid.uuid4())
        created_at = datetime.utcnow().isoformat()
        item = {
            "order_id":     order_id,
            "user_id":      order.user_id,
            "items": [{
                "product_id": i.product_id,
                "quantity":   i.quantity,
                "price":      Decimal(str(i.price))   # float → Decimal for DynamoDB
            } for i in order.items],
            "total_amount": Decimal(str(order.total_amount)),
            "status":       "pending",
            "created_at":   created_at
        }
        table.put_item(Item=item)
        return {**item, "total_amount": order.total_amount}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
