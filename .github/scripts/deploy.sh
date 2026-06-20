#!/bin/bash
set -e

IMAGE="$1"

# Refresh env from Secrets Manager
SECRETS=$(aws secretsmanager get-secret-value --secret-id bitblocks/prod --region us-east-1 --query SecretString --output text)
echo "$SECRETS" | jq -r 'to_entries[] | "\(.key)=\(.value)"' > /opt/bitblocks.env
echo PHX_SERVER=true >> /opt/bitblocks.env
echo PORT=8080 >> /opt/bitblocks.env
echo POOL_SIZE=10 >> /opt/bitblocks.env

# Pull latest image
ECR_REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$ECR_REGISTRY"
docker pull "$IMAGE"

# Restart container
docker stop bitblocks 2>/dev/null || true
docker rm bitblocks 2>/dev/null || true
INSTANCE_ID=$(ec2-metadata -i | cut -d' ' -f2)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
docker run -d --name bitblocks --restart unless-stopped --env-file /opt/bitblocks.env --network host \
  --log-driver=awslogs --log-opt awslogs-region=us-east-1 --log-opt awslogs-group=/app/bitblocks --log-opt awslogs-stream="$INSTANCE_ID" \
  -e RELEASE_DISTRIBUTION=sname \
  -e RELEASE_NODE="bitblocks@${PRIVATE_IP}" \
  -e DNS_CLUSTER_QUERY="bitblocks.internal.local" \
  "$IMAGE"

# `docker run -d` returns 0 even if the app crashes on boot, so don't trust it:
# poll until the app actually answers on its port, then confirm the container is
# still running. Fail loudly otherwise — the rollout's drain keeps this instance
# out of the ALB while we wait, so a slow/failed boot here never serves traffic.
echo "Waiting for app to become ready on :8080 ..."
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null http://127.0.0.1:8080/; then
    echo "App is responding."
    break
  fi
  if [ "$i" = "30" ]; then
    echo "ERROR: app did not respond within 60s. Container logs:" >&2
    docker logs --tail 50 bitblocks >&2 || true
    exit 1
  fi
  sleep 2
done

if [ "$(docker inspect -f '{{.State.Running}}' bitblocks 2>/dev/null)" != "true" ]; then
  echo "ERROR: bitblocks container is not running after deploy." >&2
  docker logs --tail 50 bitblocks >&2 || true
  exit 1
fi
echo "Deploy verified: container running and responding."
