# Large-Scale PostgreSQL Database Guide

This document covers considerations for running Bitblocks with a 20TB+ PostgreSQL database.

## Cloud Provider Options

### AWS

#### Amazon RDS for PostgreSQL

- Max storage: 64TB (20TB fits comfortably)
- Recommended instance types: `db.r6g.4xlarge` or larger
- Provisioned IOPS (io1/io2) essential for performance
- Automated backups, Multi-AZ for high availability
- Downside: Less control, higher cost at scale

#### Amazon Aurora PostgreSQL

- Better for read-heavy workloads (up to 15 read replicas)
- Storage auto-scales to 128TB
- 3x throughput vs standard PostgreSQL (per AWS claims)
- Higher cost per GB but includes replication
- Downside: Some PostgreSQL compatibility gaps

#### EC2 + Self-Managed PostgreSQL

- Full control over configuration
- Use `i3en` or `i4i` instances (NVMe SSD storage)
- Or EBS io2 Block Express (up to 64TB, 256K IOPS)
- Lower cost but you manage everything
- Good for: blockchain workloads with specific tuning needs

### Google Cloud

#### Cloud SQL for PostgreSQL

- Max storage: 64TB, similar to RDS
- Managed service with automated backups

#### AlloyDB

- PostgreSQL-compatible with better performance
- Higher cost than Cloud SQL
- Good for analytical workloads

### Azure

#### Azure Database for PostgreSQL

- Flexible Server: up to 16TB per instance (would need sharding for 20TB)
- Hyperscale (Citus): built-in sharding for databases exceeding 16TB

### Other Managed Options

- **Neon**: Serverless PostgreSQL, pay-per-use (may be expensive at 20TB)
- **Supabase**: Managed PostgreSQL with additional features
- **Crunchy Data**: Enterprise PostgreSQL management

## Key Recommendations for 20TB+

### Storage

Storage type matters most at this scale:

- **Provisioned IOPS (io2)** or **local NVMe** are required
- GP3 will struggle with sustained workloads at this scale
- Local NVMe (i3en/i4i instances) offers best price-performance

### Memory Sizing

Aim for enough RAM to cache hot data.
For blockchain data where recent blocks are accessed most frequently, 128-256GB RAM helps significantly.

Rule of thumb: size memory to cache the last N blocks that receive 80% of queries.

### Table Partitioning

Partition the blocks table by height ranges.
This is critical for:

- Query performance on recent data
- Maintenance operations (vacuum, reindex)
- Potential future sharding
- Dropping old partitions if needed

Example partitioning strategy:

```sql
-- Partition by height ranges of 100,000 blocks
CREATE TABLE blocks (
    id BIGSERIAL,
    height INTEGER NOT NULL,
    hash VARCHAR(64) NOT NULL,
    -- other columns...
    PRIMARY KEY (id, height)
) PARTITION BY RANGE (height);

CREATE TABLE blocks_0_100k PARTITION OF blocks
    FOR VALUES FROM (0) TO (100000);

CREATE TABLE blocks_100k_200k PARTITION OF blocks
    FOR VALUES FROM (100000) TO (200000);

-- Continue for additional ranges...
```

### Connection Pooling

Use PgBouncer in front of PostgreSQL:

- Reduces connection overhead
- Handles connection spikes from web traffic
- Transaction pooling mode recommended for Phoenix

### Backup Strategy

At 20TB, full backups are slow and expensive.
Consider:

- **Incremental backups** using pgBackRest
- **WAL archiving** to S3/GCS for point-in-time recovery
- **Replicas as backup source** to avoid impacting primary

### PostgreSQL Configuration

Key settings to tune for large databases:

```ini
# Memory
shared_buffers = 32GB              # 25% of RAM, max ~32GB useful
effective_cache_size = 96GB        # 75% of RAM
work_mem = 256MB                   # Per-operation memory
maintenance_work_mem = 2GB         # For vacuum, index creation

# WAL
wal_buffers = 64MB
max_wal_size = 8GB
min_wal_size = 2GB

# Checkpoints
checkpoint_completion_target = 0.9
checkpoint_timeout = 15min

# Parallelism
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
max_parallel_maintenance_workers = 4

# Vacuum
autovacuum_vacuum_cost_limit = 2000
autovacuum_naptime = 10s
```

## Cost Estimates (AWS)

| Option | Monthly (approx) |
|--------|------------------|
| RDS r6g.4xlarge + 20TB io2 | $4,000-6,000 |
| Aurora (20TB storage) | $5,000-8,000 |
| EC2 i3en.6xlarge (self-managed) | $2,500-3,500 |

Costs vary based on:

- IOPS provisioned
- Data transfer
- Backup storage
- Multi-AZ / replicas

## Recommendation for Bitblocks

For a blockchain application like Bitblocks, **EC2 + self-managed PostgreSQL** is recommended if you have the expertise.

Blockchain data has predictable access patterns (recent blocks hot, old blocks cold) that benefit from custom tuning.

Recommended setup:

- `i3en.6xlarge` or `i4i.4xlarge` with local NVMe for data
- EBS for WAL and backups
- Table partitioning by block height (ranges of 100k blocks)
- PgBouncer for connection pooling
- Consider TimescaleDB extension for time-series queries on transaction data

**Use Aurora** if you prefer a managed service and need read replicas for the web interface.

## Monitoring

Essential metrics to track:

- **Disk I/O**: Read/write latency, IOPS utilization
- **Cache hit ratio**: Should be >99% for hot data
- **Vacuum progress**: Ensure autovacuum keeps up
- **Replication lag**: If using replicas
- **Connection count**: vs. max_connections
- **Query performance**: pg_stat_statements for slow query analysis

Tools:

- pg_stat_statements (built-in)
- pgBadger for log analysis
- Prometheus + Grafana with postgres_exporter
- AWS CloudWatch (for RDS/Aurora)
