# Running our BSV node

An operator's runbook for the SV node that bitblocks reads from.
It is written for someone new to running a node, on a shared server, in Docker.
For what "synced", "pruned" and "archival" mean, see `NODE_MODES.md`.
For how bitblocks uses the node and falls back to public sources, see `SYNCING.md`.

## The short version

1. Confirm the node keeps every block and has `txindex=1`, before anything else.
2. Give Docker a long stop timeout, so the node always shuts down cleanly.
3. Keep RPC off the public internet.
4. Cap the logs and watch the disk; disk is the thing that runs out.
5. Once it reaches the tip, let bitblocks catch up, then put a daily health check on a timer.

## Set these once

Every script below starts from these three variables.
Set them in your shell, or put them in `~/.bsvnode.env` and `source` it.

```bash
# ~/.bsvnode.env
export BSV_CONTAINER=bsv          # docker ps --format '{{.Names}}' shows the real name
export BSV_DATADIR=/srv/bsv/data  # the host path mounted as the node's data dir
export BSV_CLI="docker exec $BSV_CONTAINER bitcoin-cli"
```

Test it with `$BSV_CLI getblockcount`.
If it fails with a cookie or config error, the CLI can't find the data dir inside the container.
Add it explicitly, for example `BSV_CLI="docker exec $BSV_CONTAINER bitcoin-cli -datadir=/data"`, using the container-side path from `docker inspect $BSV_CONTAINER`.

## 1. What bitblocks needs from the node

Bitblocks backfills history, so it asks for old blocks and old transactions by id.
That works only if the node is **archival** (not pruned) and has **`txindex=1`**.
Without `txindex`, `getrawtransaction` fails for historical transactions even though the block is on disk.

Check both now, while the node is still syncing.
Turning `txindex` on later means rebuilding the index, which can take days.

```bash
source ~/.bsvnode.env

# Should print "pruned": false
$BSV_CLI getblockchaininfo | grep -E '"(pruned|blocks|headers)"'

# The first bitcoin payment (block 170), shared history on BSV.
# Explicit success: this prints a long hex string.
# Explicit failure: "No such mempool or blockchain transaction" means txindex is off.
$BSV_CLI getrawtransaction f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16 | head -c 80; echo
```

The txindex check can fail during initial sync if the index is still building.
Run it again once the node is at the tip before you decide.

## 2. The config file

SV node reads `bitcoin.conf` from the data dir.
Here is a reasonable starting point for an indexer node.
Compare it against yours, and change one thing at a time.

```ini
# bitcoin.conf — bitblocks' indexer node

# --- what bitblocks needs ---
txindex=1
prune=0

# --- BSV consensus settings; recent node versions refuse to start without them ---
# Use the values in the release notes for your node version.
excessiveblocksize=10000000000
maxstackmemoryusageconsensus=100000000
minminingtxfee=0.00000001

# --- no wallet: bitblocks doesn't use one, and it removes an attack surface ---
disablewallet=1

# --- RPC: reachable from bitblocks, nobody else ---
server=1
rpcbind=0.0.0.0
rpcallowip=172.16.0.0/12    # the Docker bridge range; narrow it to what you use
rpcauth=bitblocks:<salt$hash>  # from share/rpcauth/rpcauth.py; better than a plain rpcpassword
rpcthreads=8
rpcworkqueue=64             # bitblocks batches calls; the default queue is small

# --- memory: be a good neighbour on a shared box ---
dbcache=4096                # MB; raise it during initial sync, lower it after
maxmempool=2000             # MB

# --- logs ---
printtoconsole=1            # let Docker own the log, and rotate it (section 4)
shrinkdebugfile=1
```

After any edit, restart cleanly (section 3) and confirm the setting took.
For example, after changing `rpcworkqueue`, run `$BSV_CLI getnetworkinfo` and confirm the node answers at all, then watch bitblocks' sync logs for `Work queue depth exceeded` errors.

## 3. Docker: stop it gently

This one matters most.
The node keeps a lot in memory and writes it out at shutdown.
Docker's default is to wait 10 seconds and then kill the process.
A killed node can come back needing a `-reindex`, which re-reads the whole chain and takes days.

If you use Compose, give it a long grace period, a restart policy and a memory limit:

```yaml
services:
  bsv:
    image: bitcoinsv/bitcoin-sv:<pinned-version>   # pin it; never :latest
    restart: unless-stopped
    stop_grace_period: 15m
    mem_limit: 12g        # above dbcache + maxmempool + ~2 GB headroom
    ulimits:
      nofile: 65536
    ports:
      - "8333:8333"                 # P2P: fine to publish, helps the network
      - "127.0.0.1:8332:8332"       # RPC: localhost only, never 0.0.0.0
    volumes:
      - /srv/bsv/data:/data
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "5"
```

If you started it with `docker run`, the same flags are `--restart unless-stopped --stop-timeout 900 --memory 12g --log-opt max-size=100m --log-opt max-file=5`.
Changing them means recreating the container (the data dir is a volume, so the chain survives).
Check what you have now:

```bash
source ~/.bsvnode.env
docker inspect $BSV_CONTAINER --format \
  'restart={{.HostConfig.RestartPolicy.Name}} stop_timeout={{.Config.StopTimeout}} mem={{.HostConfig.Memory}} log={{.HostConfig.LogConfig}}'
```

`stop_timeout=<nil>` means the 10-second default, which is the one to fix.
`mem=0` means no limit.

### Safe stop and restart

Paste this whenever you need to restart the node.
It asks the node to stop, waits until the container has really exited, and then starts it and waits for RPC.

```bash
source ~/.bsvnode.env
$BSV_CLI stop
echo "waiting for a clean shutdown (can take several minutes)..."
docker wait $BSV_CONTAINER >/dev/null
docker logs --tail 5 $BSV_CONTAINER   # look for "Shutdown: done"
docker start $BSV_CONTAINER
until $BSV_CLI getblockcount >/dev/null 2>&1; do sleep 10; done
echo "node is answering RPC at height $($BSV_CLI getblockcount)"
```

If the last log lines don't say `Shutdown: done`, the stop wasn't clean.
Watch the next startup closely for `Rewinding blocks` or a request to reindex.

### Server reboots

The host's shutdown also stops containers, with the same timeout.
Before a planned reboot of the shared server, stop the node with the script above first.
Ask whoever else uses the server to tell you before they reboot it.

## 4. Logs and disk

Disk is the thing that runs out, and when it does, the node stops writing mid-block.
BSV blocks can be gigabytes each, so plan in terabytes, measured from your own growth rate rather than a guess.

### Where the space goes

```bash
source ~/.bsvnode.env
df -h "$BSV_DATADIR"
sudo du -sh "$BSV_DATADIR"/blocks "$BSV_DATADIR"/blocks/index "$BSV_DATADIR"/chainstate \
            "$BSV_DATADIR"/indexes 2>/dev/null
ls -lh "$BSV_DATADIR"/debug.log 2>/dev/null
docker inspect --format '{{.LogPath}}' $BSV_CONTAINER | xargs sudo ls -lh
```

With `printtoconsole=1` and the Docker log options above, Docker rotates the log for you.
If the node writes `debug.log` instead, rotate it on the host:

```bash
sudo tee /etc/logrotate.d/bsv-node >/dev/null <<'EOF'
/srv/bsv/data/debug.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
  copytruncate
}
EOF
sudo logrotate -d /etc/logrotate.d/bsv-node   # dry run: confirm it finds the file
```

### Measure growth, then forecast

Log one line a day, and after a week you know how many days of disk you have left.

```bash
source ~/.bsvnode.env
( crontab -l 2>/dev/null; echo "15 3 * * * echo \"\$(date -u +\%F) \$(df -B1 --output=used,avail $BSV_DATADIR | tail -1)\" >> \$HOME/bsv-disk.log" ) | crontab -
crontab -l | grep bsv-disk   # confirm the entry is there
```

```bash
# Days of disk left, from the first and last lines of the log
awk 'NR==1{d0=$1;u0=$2} {d=$1;u=$2;a=$3} END{
  cmd="echo $(( ($(date -d " d " +%s) - $(date -d " d0 " +%s)) / 86400 ))"; cmd | getline days
  if (days<1) {print "need at least two days of data"; exit}
  rate=(u-u0)/days; printf "growing %.1f GB/day; %.0f days left\n", rate/1e9, (rate>0? a/rate : -1)
}' ~/bsv-disk.log
```

Alert yourself well before it's full: at 80 percent, plan the next volume.

## 5. Watching it reach the tip

```bash
source ~/.bsvnode.env
while true; do
  $BSV_CLI getblockchaininfo | grep -E '"(blocks|headers|verificationprogress|initialblockdownload)"' | tr -d ' ,\n'
  echo "  peers=$($BSV_CLI getconnectioncount)  $(date -u +%T)"
  sleep 60
done
```

It's at the tip when `blocks` equals `headers`, `initialblockdownload` is `false`, and `headers` matches a public explorer's height.
The last stretch is slow: recent BSV blocks are much larger than early ones, so the final few thousand blocks can take longer than the first several hundred thousand.

If `headers` stops moving or peers drop to zero, check the node's clock (`timedatectl`; it should say `System clock synchronized: yes`) and that port 8333 is reachable.

## 6. When it reaches the tip

Our node was down from 2026-07 to 2026-11, and bitblocks has been leaning on public sources (`SYNCING.md`).
Once the node is at the tip:

1. Run the txindex check from section 1 again, and confirm it prints hex.
2. Lower `dbcache` if you raised it for the initial sync, and restart cleanly (section 3).
3. Let bitblocks catch up.
   Tip sync runs every minute, and blocks that failed while the node was down need their retry counters cleared:

   ```bash
   bin/bitblocks rpc 'Bitblocks.Release.sync_status()'
   bin/bitblocks rpc 'Bitblocks.Release.retry_failed_blocks()'
   bin/bitblocks rpc 'Bitblocks.Release.gaps()'
   ```

4. Confirm the end-state, not just the commands: `sync_status()` shows bitblocks' tip at the node's height, and `gaps()` shows nothing new.
5. Put the daily health check (section 7) on a timer.

## 7. Daily health check

One screen that answers "is the node OK?".
Save it as `~/bin/bsv-health`, `chmod +x` it, and run it by hand or from cron.
It exits non-zero on any problem, so cron mail or a monitor can catch it.

```bash
#!/usr/bin/env bash
# bsv-health — one-screen check of the BSV node. Exits 1 on any problem.
set -uo pipefail
source ~/.bsvnode.env
fail=0
bad() { echo "PROBLEM: $*"; fail=1; }

docker inspect -f '{{.State.Running}}' "$BSV_CONTAINER" 2>/dev/null | grep -q true \
  || { echo "PROBLEM: container $BSV_CONTAINER is not running"; exit 1; }

info=$($BSV_CLI getblockchaininfo 2>&1) || { echo "PROBLEM: RPC not answering: $info"; exit 1; }
field() { echo "$info" | grep "\"$1\"" | head -1 | sed -E 's/.*: *"?([^",]*)"?,?/\1/'; }

blocks=$(field blocks); headers=$(field headers); ibd=$(field initialblockdownload); pruned=$(field pruned)
peers=$($BSV_CLI getconnectioncount)
public=$(curl -fsS --max-time 10 https://api.whatsonchain.com/v1/bsv/main/chain/info \
  | sed -E 's/.*"blocks":([0-9]+).*/\1/' || echo "?")

echo "height  : $blocks (headers $headers, public $public)"
echo "ibd     : $ibd   pruned: $pruned   peers: $peers"
[ "$blocks" = "$headers" ] || bad "validating behind its own headers by $((headers - blocks))"
[ "$public" = "?" ] || [ $((public - blocks)) -le 3 ] || bad "$((public - blocks)) blocks behind the public chain"
[ "$pruned" = "false" ] || bad "node is pruned; bitblocks backfill needs archival"
[ "$peers" -ge 4 ] || bad "only $peers peers"

$BSV_CLI getrawtransaction f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16 >/dev/null 2>&1 \
  || bad "historical getrawtransaction failed (txindex off or still building)"

use=$(df --output=pcent "$BSV_DATADIR" | tail -1 | tr -dc 0-9)
echo "disk    : ${use}% used"
[ "$use" -lt 85 ] || bad "disk ${use}% full"

restarts=$(docker inspect -f '{{.RestartCount}}' "$BSV_CONTAINER")
[ "$restarts" -eq 0 ] || bad "container has restarted $restarts times (check for OOM: docker inspect -f '{{.State.OOMKilled}}' $BSV_CONTAINER)"

[ $fail -eq 0 ] && echo "OK"
exit $fail
```

To run it every morning and keep the result:

```bash
( crontab -l 2>/dev/null; echo '0 7 * * * $HOME/bin/bsv-health >> $HOME/bsv-health.log 2>&1' ) | crontab -
crontab -l | grep bsv-health
```

## 8. Upgrades

SV node has had mandatory upgrades, where nodes that don't upgrade by a block height fall off the network.
Watch the releases at <https://github.com/bitcoin-sv/bitcoin-sv/releases> and the BSV node announcements.

To upgrade:

1. Read the release notes for config changes (new required settings, renamed ones).
2. Stop cleanly (section 3), and wait for `Shutdown: done`.
3. Change the pinned image tag, recreate the container, and start it.
4. Confirm the version and that it's still at the tip:
   `$BSV_CLI getnetworkinfo | grep -E '"(version|subversion)"'`, then run `bsv-health`.

Keep the old tag written down, so you can roll back the same way.

## 9. Living on a shared server

- **Memory:** the node's `dbcache` plus mempool is real, steady memory. Set a container memory limit (section 3) so the node can't starve its neighbours, and keep the limit comfortably above what the node uses, because an OOM kill mid-write is an unclean shutdown.
- **Disk I/O:** initial sync and reindexes saturate disk. Tell the other people on the box when you're about to do either.
- **CPU:** after initial sync the node is mostly idle, with short bursts when big blocks arrive.
- **Secrets:** the RPC credentials live in `bitcoin.conf` and bitblocks' `BITCOIN_NODE_RPC_*` environment variables. Keep `bitcoin.conf` readable only by the node's user (`chmod 600`).
- **Ports:** publishing 8333 lets other nodes connect and is good citizenship. RPC (8332) stays on localhost or a private network, always.

## 10. Locking down RPC

RPC is plain HTTP with a password, and anyone who has the password can control the node.
The password travels unencrypted, so over the public internet anyone on the path can read it.
Docker writes its own firewall rules for published ports, which skip `ufw`, so a host firewall alone doesn't protect a published RPC port.

Pick the strongest option that still lets the right callers in:

1. **Nobody remote needs it:** publish RPC on localhost only (`127.0.0.1:8332:8332`), and reach it from a laptop through an SSH tunnel: `ssh -N -L 8332:127.0.0.1:8332 user@node-host`, then use `http://127.0.0.1:8332` locally.
2. **Specific servers need it:** put the node and those servers on a private network (WireGuard or Tailscale), and publish RPC only on that interface, for example `100.x.y.z:8332:8332`. This also encrypts the password in transit.
3. **Interim, while you set up 1 or 2:** allow only known IPs at the cloud firewall or security group, and in Docker's own chain:

   ```bash
   EXT=$(ip route show default | awk '{print $5; exit}')   # the public interface
   sudo iptables -I DOCKER-USER -i "$EXT" -p tcp --dport 8332 -j DROP
   sudo iptables -I DOCKER-USER -i "$EXT" -p tcp --dport 8332 -s <allowed-ip> -j ACCEPT   # one per caller
   sudo iptables -L DOCKER-USER -n --line-numbers   # confirm ACCEPT sits above DROP
   ```

   These rules cover IPv4 only and are lost on reboot unless saved, for example with `iptables-persistent`.
   The `[::]:8332` mapping is still open over IPv6, so close it with the matching `ip6tables` rules or by not publishing on IPv6.

Whichever option you choose:

- Use `rpcauth` (a salted hash in `bitcoin.conf`) with a long random password, and rotate any password that has crossed the internet.
  Generate the line and the password with Python's standard library:

  ```bash
  python3 - <<'EOF'
  import secrets, hmac, hashlib
  user = "bitblocks"
  pw = secrets.token_urlsafe(32)
  salt = secrets.token_hex(16)
  h = hmac.new(salt.encode(), pw.encode(), hashlib.sha256).hexdigest()
  print(f"rpcauth={user}:{salt}${h}")
  print(f"PASSWORD: {pw}")
  EOF
  ```

  The `rpcauth=` line goes in `bitcoin.conf`.
  The username and password go in Secrets Manager (`bitblocks/prod`, keys `BITCOIN_NODE_RPC_USERNAME` and `BITCOIN_NODE_RPC_PASSWORD`) with `infra/scripts/app-secret-set.sh`, followed by `app-restart.sh bitblocks`.
- Production bitblocks reaches the internet through the AWS NAT gateway's fixed Elastic IP (shared with the other apps in that VPC; infra has the address), so that is the address to allow.
  People with changing IPs use the SSH tunnel instead of an allowlist entry.
- Set `disablewallet=1` unless something really needs the node's wallet.
- Narrow `rpcallowip`. Inside Docker the node may see every caller as the bridge gateway (for example `172.17.0.1`), so `rpcallowip` there is a backstop, not the main control.
- Check who has been knocking: `docker logs $BSV_CONTAINER 2>&1 | grep -i 'incorrect password' | tail`.

## Quick reference

| Question | Command |
| --- | --- |
| Height | `$BSV_CLI getblockcount` |
| Synced? | `$BSV_CLI getblockchaininfo` (blocks = headers, `initialblockdownload` false) |
| Peers | `$BSV_CLI getconnectioncount`, details in `getpeerinfo` |
| Version | `$BSV_CLI getnetworkinfo` |
| Mempool | `$BSV_CLI getmempoolinfo` |
| Forks seen | `$BSV_CLI getchaintips` |
| Uptime | `$BSV_CLI uptime` |
| Recent log | `docker logs --tail 100 $BSV_CONTAINER` |
| Clean stop | `$BSV_CLI stop`, then `docker wait $BSV_CONTAINER` |
| Health | `~/bin/bsv-health` |
