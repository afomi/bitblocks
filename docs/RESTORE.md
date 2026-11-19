# Archive and restore

The runbook for archiving bitblocks to S3 and bringing it back, and for rehearsing that restore before anything is stopped.
Written 2026-11-17 for https://github.com/afomi/bitblocks/issues/55; the infra session runs it, with Ryan's go for each infra step.
An archive that has never been restored isn't a backup yet, so the rehearsal comes first, while the database is small.
Related: [STORAGE_PLAN.md](STORAGE_PLAN.md) (the measured sizes), [TX_STORAGE.md](TX_STORAGE.md) (the block objects), [SYNCING.md](SYNCING.md) (`complete_through`).

Every step marked **Infra** touches production or AWS, and is run by the infra session only.
The rest runs against the throwaway copy, or nowhere.

## The rules

- **Never the live instance.**
  Every restore goes to a new RDS instance named `bitblocks-restore-<yyyymmdd>`.
  No command in this runbook modifies, reboots, restores over or deletes `bitblocks-db`.
- **The restored instance has the source's master user and password.**
  So the endpoint is the only thing that tells the two apart: read the host `restore_check` prints before trusting any number below it.
- **Nothing that syncs points at a copy.**
  A writer node pointed at a restore would fetch blocks from our node and write block objects to the live bucket.
  The rehearsal uses `bin/bitblocks eval` (the repo only: no web server, no Oban, no sync) and `NODE_ROLE=reader`, never a writer.
- **Success is read, never assumed.**
  An AWS command that returns 0 has only been accepted.
  Each step below names the end state to read back, and the rehearsal is done only when `restore_check` prints the same fingerprint on the source and the restore.

## 1. What an archive holds

| Part | Where | Restores to | Notes |
|---|---|---|---|
| RDS snapshot of `bitblocks-db` | RDS (manual snapshot) | a new RDS instance, in 20 to 60 minutes | the fastest way back; billed while kept, and outlives the instance only as a manual snapshot (automated ones go with the instance) |
| `pg_dump` of the database, directory format | S3, `s3://<archive bucket>/bitblocks/<yyyymmdd>/` | an empty RDS instance of any size, through `pg_restore --jobs` | the cheap long-term copy, and the only way to a smaller instance: RDS storage never shrinks |
| Block objects | the tx store bucket (`AWS_S3_BUCKET_TXS`), `blocks/<height>-<hash>.bin`, plus `raw/<txid>` | read in place by `TxStore.raw/1` | a second copy of the raw bytes, which the `transactions.raw` column still holds through 400,000; only blocks with `raw_object_stored_at` have one (https://github.com/afomi/bitblocks/issues/94) |
| Config | the Secrets Manager secret `bitblocks/prod` | `/opt/bitblocks.env`, written by `.github/scripts/deploy.sh` | kept as it is; never copied to S3 in the clear |
| The release | ECR `bitblocks:<sha>`, and git | `docker run` of that image | record the SHA that wrote the archive (`RELEASE_SHA` on the container) |

The database holds everything the site serves: headers, txs, derived data, the protocol indexes, users and API keys.
So the database is the archive, and the block objects and config are what make it run again.

## 2. The rehearsal

Best run once `complete_through` has reached the stop height (400,000): the sync is then quiet, and every count matches exactly.
It also works mid-sync, with one condition.
Rows at heights up to `complete_through` change only through backfills and repairs: the backfill chains (`timelocks`, `bap`, `token_recipients`, …) and `CatchUpBlockWorker` insert rows at old heights, `reopen_short_blocks` adds `transactions` rows, and a reorg reconcile removes some.
So pause those for the whole window, from the restore point until the source has been checked (2.3).
Hold deploys to `develop` while it runs.

### 2.0 Quiet the source (Infra)

See what's running, and pause each running backfill chain by its id:

```bash
bin/bitblocks rpc 'Bitblocks.Release.backfill_status()'
bin/bitblocks rpc 'Bitblocks.Release.pause_backfill(<id>)'
```

A paused chain stops once the range in flight finishes, so wait until the `derived` and `backfills` queues are idle.
This must print `[]`:

```bash
bin/bitblocks rpc 'import Ecto.Query; Bitblocks.Repo.all(from j in Oban.Job, where: j.queue in ["derived", "backfills"] and j.state in ["available", "scheduled", "executing", "retryable"], group_by: [j.queue, j.state], select: {j.queue, j.state, count()}) |> IO.inspect()'
```

Run no `reopen_short_blocks`, reorg reconcile or other repair until 2.3 is done; then `resume_backfill(<id>)` each chain paused here.

### 2.1 Take the copy (Infra)

Read the source's settings, so the restore lands in the same network on the same storage:

```bash
aws rds describe-db-instances --db-instance-identifier bitblocks-db \
  --query 'DBInstances[0].{class:DBInstanceClass,storage:AllocatedStorage,type:StorageType,iops:Iops,throughput:StorageThroughput,retention:BackupRetentionPeriod,engine:EngineVersion,subnets:DBSubnetGroup.DBSubnetGroupName,sgs:VpcSecurityGroups[].VpcSecurityGroupId,params:DBParameterGroups[].DBParameterGroupName,endpoint:Endpoint.Address,latest:LatestRestorableTime}'
```

Restore to a point in time from the automated backups, which costs the live instance nothing (a manual snapshot of a Single-AZ instance pauses its I/O briefly).
Pin the storage to the source's: the flags' defaults have changed over time, and a gp2 volume would make every cold read slower.

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier bitblocks-db \
  --target-db-instance-identifier bitblocks-restore-20261118 \
  --use-latest-restorable-time \
  --db-instance-class db.m7g.large \
  --storage-type gp3 --iops <iops from above> --storage-throughput <throughput from above> \
  --db-subnet-group-name <subnets from above> \
  --vpc-security-group-ids <sgs from above> \
  --db-parameter-group-name <params from above> \
  --no-publicly-accessible --no-multi-az --no-deletion-protection \
  --tags Key=purpose,Value=restore-rehearsal Key=issue,Value=55
aws rds wait db-instance-available --db-instance-identifier bitblocks-restore-20261118
```

The restore inherits the source's backup retention, so RDS would start a full backup while the check reads the cold volume.
Turn it off on the restore, by its own identifier:

```bash
aws rds modify-db-instance --db-instance-identifier bitblocks-restore-20261118 \
  --backup-retention-period 0 --apply-immediately
aws rds wait db-instance-available --db-instance-identifier bitblocks-restore-20261118
```

Then read back that it exists, is available, has its own endpoint, its storage, and no backups:

```bash
aws rds describe-db-instances --db-instance-identifier bitblocks-restore-20261118 \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address,AllocatedStorage,StorageType,Iops,StorageThroughput,BackupRetentionPeriod]'
```

It must say `available`, the source's storage type, IOPS and throughput, and retention `0`, and its endpoint must differ from `bitblocks-db`'s.
With the source's subnet group and security groups, the app instances reach it the way they reach `bitblocks-db`, and nothing outside the VPC does.
Write down both endpoints and the restore time; the rehearsal record (section 2.5) needs them.

### 2.2 Check the copy (Infra, against the restore only)

On an app instance (inside the VPC, with the image already pulled), run the check as a one-off release against the restore.
`bin/bitblocks eval` starts only the repo, so nothing else runs:

```bash
RESTORE_URL='ecto://<user>:<password>@<restore endpoint>/<database>'
docker run --rm --network host --env-file /opt/bitblocks.env \
  -e DATABASE_URL="$RESTORE_URL" -e NODE_ROLE=reader -e CLUSTER_EC2_TAG=off -e STORE_BLOCK_OBJECTS=false \
  <the running image> /app/bin/bitblocks eval 'Bitblocks.Release.restore_check()'
```

`Release.restore_check/1` (`Bitblocks.RestoreCheck`) is read-only: it runs in one `READ ONLY` transaction, so Postgres refuses any write.
It prints:

- the database name and host: **confirm the host is the restore's endpoint before reading on**;
- `tip` and `complete_through`, and the height it compares through (`complete_through` unless `through:` is given);
- `chain digest`: sha256 over `<height>:<hash>` for every block from 0 through that height;
- `fingerprint`: sha256 over that height, the chain digest and the row counts at heights up to it, including the `transactions` rows holding `raw` and the bytes of it, so a copy that lost bytes doesn't match;
- `full fingerprint`: the fingerprint's text plus the exact count of every table without a height (`spend_index`, `users`, `api_keys`, …), for comparing two copies of a quiet database (section 3);
- rows at heights 0 through that height, for `blocks` and every table with a `block_height` (`transactions`, `timelocks`, `protocol_instances`, …), and `transactions` per 50,000 blocks as rows, rows with `raw` and `raw` bytes, so a mismatch says where it is;
- rows in the tables without a height;
- every header from 0 through that height rebuilt from its row and checked: hash, proof of work, and each block naming the one below it (`Chain.Headers`);
- one tx from each of 100 random blocks, its row's own `raw` hashed: each must hash to its txid, and a row without `raw` fails as `:no_raw_in_row` rather than borrowing the bytes from the live store (only a row marked `raw_in_db` false, its bytes moved on purpose, is read from the store, and counted apart);
- `OK`, or `FAIL:` and each reason.

On a fresh restore the first reads are slow, because RDS loads each block of the volume from S3 the first time it is read.
The check reads the `transactions` heap (for the `raw` counts) and all of `spend_index`, most of the database: at the tens of MB/s typical of first-touch reads, expect 2 to 6 hours.
Its run time is a measurement worth recording; a second run on the warm volume takes minutes.

Then the block objects, read-only, in pieces of 50,000 blocks up to the restore's `complete_through` (the same one-off release, so it reads the live bucket and writes nothing):

```bash
docker run --rm --network host --env-file /opt/bitblocks.env \
  -e DATABASE_URL="$RESTORE_URL" -e NODE_ROLE=reader -e CLUSTER_EC2_TAG=off -e STORE_BLOCK_OBJECTS=false \
  <the running image> /app/bin/bitblocks eval 'Bitblocks.Release.tx_store_reconcile(0, 49_999, sample: 50)'
```

Each piece must show `sample  N of N match`; `block_objects_missing` is expected until https://github.com/afomi/bitblocks/issues/94 has run, and is recorded, not failed.

### 2.3 Compare with the source (Infra, read-only on prod)

Run the same check on prod at the restore's height, with the planner's estimates for the tables without a height, and a cap on each statement:

```bash
bin/bitblocks rpc 'Bitblocks.Release.restore_check(through: <restore complete_through>, unbounded: :estimate, statement_timeout_ms: 1_800_000)'
```

It holds one of the app's pool connections for its run and reads the `transactions` heap through the buffer cache, so run it with the sync stopped or quiet.
It counts one 50,000-block bucket per statement, so the 30-minute cap applies to each range; Ctrl-C on `rpc` does not cancel a running query, and the cap does.
A statement past the cap stops the run with `query_canceled`: raise the cap and run it again off-peak.

The rehearsal passes when all of these hold:

| Check | Source | Restore |
|---|---|---|
| `complete_through` | at or above the restore's | the height compared |
| `chain digest` | equal | equal |
| `fingerprint` | equal | equal |
| `transactions` per 50,000 blocks (rows, with `raw`, bytes) | equal, every line | equal, every line |
| `full fingerprint` | none (estimates) | printed and recorded |
| headers | | all verified and canonical, 0 missing |
| sample | | every row's own `raw` hashes to its txid |
| last line | | `OK` |
| block objects | | every sampled ranged read matches |

A different fingerprint with an equal chain digest means rows differ: the per-table and per-bucket lines say which table and which 50,000 blocks.
A different chain digest means the restore holds another chain, which should never happen: stop and look.
Then resume the backfills paused in 2.0.

### 2.4 Boot the app against it (Infra)

The check above is the proof; this shows the app runs on the copy.
Start a reader on an app instance, on a spare port, outside the load balancer and the cluster:

```bash
docker run -d --name bitblocks-restore -p 127.0.0.1:8081:8080 --env-file /opt/bitblocks.env \
  -e DATABASE_URL="$RESTORE_URL" -e NODE_ROLE=reader -e CLUSTER_EC2_TAG=off \
  -e STORE_BLOCK_OBJECTS=false -e PORT=8080 -e PHX_SERVER=true \
  -e RELEASE_COOKIE="$(openssl rand -hex 16)" \
  <the running image>
curl -fsS http://127.0.0.1:8081/api/v1/status | jq '{index: .index, this_node: .this_node}'
curl -fsS http://127.0.0.1:8081/api/v1/headers/0 | jq '.data | {hash, verified, canonical}'
```

It passes when `/api/v1/status` answers with the restore's `complete_through` and `this_node.role` is `reader`, and header 0 is `verified` and `canonical`.
The status can take a minute after boot to fill in.
Why each setting:

- Its own network (`-p`, not `--network host`): `rel/env.sh.eex` names every node `bitblocks@<private ip>`, so on the host's network it would collide with the live container's name and fail to boot.
- `CLUSTER_EC2_TAG=off` and its own `RELEASE_COOKIE`: it never joins the prod cluster, so its PubSub never reaches the live nodes.
- `NODE_ROLE=reader`: no Oban queues, no leadership and no coordinator.
  Its caches may still write a few rows, so it runs after the check, never before.
- A name other than `bitblocks`: deploys restart and migrate only the container called `bitblocks`.

### 2.5 Record it (Infra)

Comment on https://github.com/afomi/bitblocks/issues/55 with: the restore time, the source and restore endpoints, the release SHA, both `restore_check` outputs (or their fingerprints, `complete_through` and last line), the reconcile lines, the reader's status answer, and the time each step took.
Those times replace the estimates in section 5.

### 2.6 Tear down (Infra)

Stop the reader, then delete the instance, with no final snapshot and no retained backups:

```bash
docker rm -f bitblocks-restore
aws rds delete-db-instance --db-instance-identifier bitblocks-restore-20261118 \
  --skip-final-snapshot --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier bitblocks-restore-20261118
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
```

The last command must list `bitblocks-db` and no `bitblocks-restore-*`; `docker ps -a` on the app instance must show no `bitblocks-restore`.
Delete any manual snapshot taken only for the rehearsal, and list the snapshots after to confirm.

## 3. The final archive (Infra)

When Ryan calls it, with the sync stopped (`index.stopped` or `paused` on `/api/v1/status`):

1. Quiet the source as in 2.0, and leave it quiet to the end of step 3.
2. Take a manual snapshot, `bitblocks-db-final-<yyyymmdd>`, wait for `available`, and read its status back.
3. Restore the snapshot to `bitblocks-restore-<yyyymmdd>` as in 2.1 (`restore-db-instance-from-db-snapshot`, with the same storage flags and retention 0), and run the check on it with exact counts, as in 2.2:

   ```bash
   ... /app/bin/bitblocks eval 'Bitblocks.Release.restore_check(unbounded: :exact)'
   ```

   Its `fingerprint` and `full fingerprint` are the archive's reference, taken from the snapshot itself at no cost to prod.
   It must end `OK`, and its `fingerprint` must equal prod's at the same height (2.3), which ties the snapshot to the source.
4. Dump from that restore, not from prod, on a scratch EC2 instance with room for the dump.
   An app instance's root volume can't hold it, and a custom-format dump streamed to S3 can't be restored in parallel.
   The scratch instance: the app instances' subnet and security group, an instance role allowed `s3:PutObject` and `s3:GetObject` on the archive bucket, a 400 GB gp3 data volume at `/dump`, and a `Name` tag that doesn't start with `bitblocks` (deploys target `bitblocks` and `bitblocks-*`).
   Use the `pg_dump` matching the server's major version (`restore_check` prints it) and a libpq URL over TLS, not the `ecto://` one:

   ```bash
   PG_URL='postgresql://<user>:<password>@<restore endpoint>/<database>?sslmode=require'
   docker run --rm --network host -v /dump:/dump postgres:<major> \
     pg_dump --format=directory --jobs=4 --compress=6 --no-owner --no-privileges \
     --file=/dump/bitblocks-<yyyymmdd> "$PG_URL"
   docker run --rm -v /dump:/dump postgres:<major> pg_restore --list /dump/bitblocks-<yyyymmdd> | wc -l
   aws s3 sync /dump/bitblocks-<yyyymmdd> s3://<archive bucket>/bitblocks/<yyyymmdd>/
   du -sb /dump/bitblocks-<yyyymmdd>
   aws s3 ls --recursive --summarize s3://<archive bucket>/bitblocks/<yyyymmdd>/ | tail -2
   ```

   `pg_restore --list` must print the table of contents (hundreds of lines), and the bucket's object count and total size must equal the directory's file count and `du` bytes.
5. Rehearse from the dump, not the snapshot.
   Create an empty instance, `bitblocks-restore-dump-<yyyymmdd>`, gp3, retention 0, with storage for the data and its indexes (800 GB at 400,000), in the same network.
   Then, from the scratch instance, read the dump back from S3 into an empty directory and restore it in parallel:

   ```bash
   aws s3 sync s3://<archive bucket>/bitblocks/<yyyymmdd>/ /dump/from-s3/
   NEW_URL='postgresql://<user>:<password>@<dump-restore endpoint>/<database>?sslmode=require'
   docker run --rm --network host -v /dump:/dump postgres:<major> \
     pg_restore --jobs=4 --no-owner --no-privileges --exit-on-error --dbname="$NEW_URL" /dump/from-s3
   docker run --rm --network host postgres:<major> psql "$NEW_URL" -c 'ANALYZE'
   ```

   Then `restore_check(unbounded: :exact)` against it (2.2) must end `OK` and print the same `fingerprint` **and** `full fingerprint` as step 3.
   The full fingerprint is what shows `spend_index` and every other table came back whole.
   Only this proves the archive restores, which is what https://github.com/afomi/bitblocks/issues/55 closes on.
6. Record it on the issue as in section 2.5, then tear down both scratch instances (section 2.6) and the scratch EC2 instance and its volume.
7. Keep: the dump (S3, then Glacier Deep Archive after step 5 passes), the tx store bucket, the secret `bitblocks/prod`, and the image in ECR.
   Keep the final snapshot until step 5 passes, then delete it or keep it a month, by Ryan's call: it is the costly part (section 5).
8. Only then stop the paid resources: the app instances and load balancer, and `bitblocks-db` with `--final-db-snapshot-identifier` (a snapshot is billed only while kept).

## 4. Bringing it back

1. **Infra.** Restore the newest archive to a new instance: from a kept snapshot (section 2.1), or from the dump (section 3, step 5), which allows a smaller volume.
   A dump in Glacier Deep Archive takes up to 12 hours to restore to S3 first (up to 48 for bulk).
2. **Infra.** Run `restore_check(unbounded: :exact)` against it with `bin/bitblocks eval`; it must print the archive's reference fingerprints and `OK`.
3. **Infra.** Point the secret's `DATABASE_URL` at the new instance and deploy (`.github/workflows/restart.yml`), which runs `bin/migrate` for any migrations newer than the archive.
4. The sync carries on from `complete_through + 1` by itself (docs/SYNCING.md); clear or raise `SYNC_STOP_AT_HEIGHT`, and unpause on `/syncing` if it was paused.
   `/syncing` and `/api/v1/status` show it moving.

### Rolling the code back past a checkpoint inside a block

Code from https://github.com/afomi/bitblocks/pull/119 on can save a backfill chain's checkpoint inside a dense block: `checkpoint_tx_id` set beside `checkpoint_height`.
Older code ignores `checkpoint_tx_id` and would start after `checkpoint_height`, skipping the rest of that block.
So before deploying code older than that pull request to a database that newer code has run on, **Infra** runs:

```sql
UPDATE derivation_chains
SET checkpoint_height = checkpoint_height - 1, checkpoint_tx_id = NULL
WHERE checkpoint_tx_id IS NOT NULL;
```

The chain then takes that block again from its start.
Redoing it writes nothing new: the backfills select by version or by missing rows, so the txs already done drop out.
A restore from an archive taken before that pull request has no such rows; the update finds none.

## 5. Cost and time

From the measured sizes in [STORAGE_PLAN.md](STORAGE_PLAN.md): 370 GB used at `complete_through` 348,921 (2026-11-13), 433 GB allocated, 5.3 KB per stored tx; about 560 to 620 GB used at 400,000 (est.).
Prices are us-east-1 list prices on 2026-11-17 (est.); check them before the run.

| Step | Time (est.) | Cost (est.) |
|---|---|---|
| Point-in-time restore to db.m7g.large | 20 to 60 minutes to `available` | $0.17 an hour for the instance, plus gp3 at $0.115 per GB-month on the source's allocated storage (650 GB is about $0.10 an hour): about $0.27 an hour |
| `restore_check` on the restore, cold volume | 2 to 6 hours (first-touch reads at tens of MB/s over most of 560 GB) | in the hours above |
| `restore_check` on prod, `unbounded: :estimate` | 30 to 90 minutes, mostly the `transactions` heap | nothing extra |
| `tx_store_reconcile` in pieces of 50,000 | about 1 minute a piece | S3 GETs, under $0.01 |
| Reader boot and checks | 10 minutes | nothing extra |
| **The whole rehearsal** | **most of a working day** | **about $1.60 to $6.50** (6 to 24 hours at $0.27) |
| `pg_dump --jobs=4` from the snapshot's restore | 2 to 4 hours (`transactions` is one table, so one stream at 40 to 80 MB/s over about 370 GB of heap and TOAST) | the restore's hours, about $1, plus the scratch EC2 and its 400 GB volume, about $0.12 an hour |
| `pg_restore --jobs=4` of that dump, with index builds | 4 to 8 hours | an 800 GB instance at about $0.30 an hour, about $2.50 |
| Keeping the dump, 150 to 190 GB compressed | | S3 Standard about $4 a month; Glacier Deep Archive about $0.20 a month (180-day minimum) |
| Keeping the final snapshot, 560 to 620 GB | | about $55 a month at $0.095 per GB-month, once no instance's free backup allowance covers it |
| Keeping the block objects, about 66 GB through 400,000 | | S3 Standard about $1.50 a month |
| Keeping the secret and the image | | about $0.40 and $0.02 a month |

So the long-term archive costs about $2 a month in the dump and the block objects, against about $55 for a kept snapshot.
The rehearsal costs a few dollars; the time that matters is the day of infra's attention, most of it waiting on the cold volume.
