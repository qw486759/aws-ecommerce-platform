"""
tests/test_api.py — Functional API test suite

Runs a sequential smoke test against the live ALB endpoint:
  1. Health check
  2. Create a product  (RDS MySQL)
  3. List products     (RDS MySQL)
  4. Create an order   (DynamoDB)
  5. Query orders by user (DynamoDB GSI)

Usage:
    python tests/test_api.py
"""

import os

import pytest
import requests

BASE_URL = os.environ["BASE_URL"]


def test_health():
    print("\n=== Health Check ===")
    r = requests.get(f"{BASE_URL}/health")
    assert r.status_code == 200
    print(f"✅ Health: {r.json()}")


def test_create_product():
    print("\n=== Create Product ===")
    payload = {
        "name": "iPhone 15",
        "description": "Apple smartphone",
        "price": 999.99,
        "stock": 100,
    }
    r = requests.post(f"{BASE_URL}/products", json=payload)
    print(f"   Status code: {r.status_code}")
    print(f"   Response: {r.text}")
    assert r.status_code == 201
    print(f"✅ Created: {r.json()}")
    return r.json()["id"]


@pytest.fixture
def product_id():
    return test_create_product()


def test_list_products():
    print("\n=== List Products ===")
    r = requests.get(f"{BASE_URL}/products")
    assert r.status_code == 200
    print(f"✅ Products count: {len(r.json())}")
    print(f"   {r.json()}")


def test_create_order(product_id: int):
    print("\n=== Create Order ===")
    payload = {
        "user_id": "user-001",
        "items": [{"product_id": product_id, "quantity": 2, "price": 999.99}],
        "total_amount": 1999.98,
    }
    r = requests.post(f"{BASE_URL}/orders", json=payload)
    print(f"   Status code: {r.status_code}")
    print(f"   Response: {r.text}")
    assert r.status_code == 201
    print(f"✅ Order created: {r.json()['order_id']}")


def test_get_orders():
    print("\n=== Get Orders by User ===")
    r = requests.get(f"{BASE_URL}/orders/user-001")
    assert r.status_code == 200
    print(f"✅ Orders count: {len(r.json())}")


if __name__ == "__main__":
    print("🚀 Starting API tests...")
    print(f"   Target: {BASE_URL}")
    try:
        test_health()
        product_id = test_create_product()
        test_list_products()
        test_create_order(product_id)
        test_get_orders()
        print("\n✅ All tests passed!")
    except AssertionError as e:
        print(f"\n❌ Test failed: {e}")
    except Exception as e:
        print(f"\n❌ Error: {e}")
