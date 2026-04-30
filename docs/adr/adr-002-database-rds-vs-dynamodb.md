# ADR-002: Database Selection — RDS MySQL for Products, DynamoDB for Orders

## Status
Accepted

## Context

The application has two distinct data domains with meaningfully different access patterns:

**Products:** Catalog data. Schema is well-defined (id, name, price, description, stock). Reads are high-volume and often involve filtering — "get products under $50" or "get products in category X." Write volume is low (catalog updates). Data relationships are predictable and unlikely to change dramatically.

**Orders:** Transactional data. Written once (order placed), then read either by `order_id` (order detail lookup) or by `user_id` (order history). No joins needed — an order record is self-contained. Write volume spikes with traffic; read volume is unpredictable.

The question: does it make sense to run both on the same database engine, or does the access pattern difference justify using two different stores?

## Decision

Use RDS MySQL (Multi-AZ) for the products table. Use DynamoDB (PAY_PER_REQUEST) for orders.

This is a polyglot persistence model — each store is chosen for the access pattern it handles best, rather than forcing everything into a single database.

## Alternatives Considered

**RDS MySQL for everything**

The straightforward path. One database to manage, one connection pool, simpler operational model. 

The downside for orders: the access pattern doesn't need SQL. There are no joins, no aggregations, no filtering beyond "give me orders for user X." Running a relational database to do key-value lookups is technically fine but wastes the capabilities you're paying for, and introduces a tighter dependency on RDS for availability. If RDS goes down, both products and orders are unavailable.

Also: RDS t3.micro is always running regardless of traffic. DynamoDB PAY_PER_REQUEST charges per read/write operation. For a demo or low-traffic application, DynamoDB effectively costs zero when idle. This made the decision easier.

**DynamoDB for everything**

Would simplify infrastructure (no RDS to manage) but creates real problems for the products domain. DynamoDB doesn't support arbitrary filtering without full table scans unless you pre-model all your query patterns in advance. "Get all products under $50" would require a GSI on price — fine, but as query patterns evolve, you end up maintaining multiple GSIs and the schema becomes brittle.

More importantly: product catalog data benefits from transactions (stock management, atomic updates across related records). DynamoDB does support transactions (TransactWriteItems), but they're expensive and limited. SQL is genuinely better for this use case.

**Aurora Serverless**

Came up as an option. The appeal: serverless scaling, pay-per-use. The problem for this project: Aurora Serverless v1 had significant cold start latency (up to 30 seconds after a period of inactivity). v2 is much better, but overkill for a demo with known, stable traffic. RDS MySQL t3.micro is simpler, cheaper for constant-on workloads, and easier to reason about.

Worth revisiting if the application saw truly spiky traffic patterns where the database sat idle for long stretches between bursts.

## Consequences

**Positive:**
- Each store is optimized for its access pattern
- DynamoDB PAY_PER_REQUEST = zero cost when no traffic (significant for demo environments)
- Failure isolation — RDS outage doesn't affect order reads from DynamoDB
- DynamoDB scales automatically; no capacity planning needed for the orders domain
- Orders GSI on `user_id` handles the "order history" query efficiently without full scans

**Negative / Trade-offs:**
- Two different database SDKs in the application (PyMySQL for RDS, boto3 for DynamoDB)
- Two different mental models for schema design and query patterns
- No cross-store transactions — you can't atomically decrement product stock in RDS and create an order in DynamoDB in one operation. In a production system, this would need a compensating transaction pattern (saga) or a distributed transaction coordinator. For this demo, it's out of scope.
- More infrastructure to manage in Terraform

**On the cross-store transaction gap:**

This is worth acknowledging explicitly. In a real e-commerce system, "place order" and "deduct inventory" need to be atomic. The current design doesn't handle this — if the DynamoDB write succeeds but the RDS stock update fails, inventory is inconsistent.

Production mitigation options:
1. Saga pattern with compensating transactions (complex, but correct)
2. Move inventory tracking to DynamoDB as well, where DynamoDB transactions can handle the atomicity
3. Implement an order processing queue (SQS) that decouples placement from fulfillment and handles retry/rollback explicitly

This is a deliberate simplification for the demo scope, not something that would survive a production design review unchanged.
