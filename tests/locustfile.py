"""
tests/locustfile.py — Locust load test

Simulates realistic e-commerce traffic against the ALB endpoint.

Task weights reflect typical read-heavy traffic patterns:
  - GET /products     (weight 3) — most common: browsing the catalogue
  - GET /products/:id (weight 2) — viewing a product detail page
  - POST /orders      (weight 2) — placing an order
  - GET /health       (weight 1) — baseline check

Usage:
    locust -f tests/locustfile.py --host=http://<ALB_DNS>
    Then open http://localhost:8089 and set users / spawn rate.
"""

from locust import HttpUser, task, between
import random


class EcommerceUser(HttpUser):
    # Simulate think-time between requests (1–3 seconds per user)
    wait_time = between(1, 3)

    def on_start(self):
        """Seed one product per virtual user so GET /products/:id has valid IDs."""
        self.client.post(
            "/products",
            json={
                "name": f"Product {random.randint(1, 1000)}",
                "description": "Load test product",
                "price": round(random.uniform(10, 500), 2),
                "stock": 100,
            },
        )

    @task(3)
    def list_products(self):
        """Browse the full product catalogue (highest frequency)."""
        self.client.get("/products")

    @task(2)
    def get_product(self):
        """View a single product detail page."""
        product_id = random.randint(1, 10)
        self.client.get(f"/products/{product_id}")

    @task(2)
    def create_order(self):
        """Place an order — hits DynamoDB write path."""
        self.client.post(
            "/orders",
            json={
                "user_id": f"user-{random.randint(1, 100)}",
                "items": [
                    {
                        "product_id": random.randint(1, 10),
                        "quantity": random.randint(1, 5),
                        "price": round(random.uniform(10, 500), 2),
                    }
                ],
                "total_amount": round(random.uniform(10, 2000), 2),
            },
        )

    @task(1)
    def health_check(self):
        """Baseline health probe (lowest frequency)."""
        self.client.get("/health")
