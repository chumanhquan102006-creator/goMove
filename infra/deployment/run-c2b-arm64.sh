#!/usr/bin/env bash
# Native ARM64, private synthetic-data smoke for the C2B GitHub runner only.
set -euo pipefail

[[ "$(uname -m)" = aarch64 ]] || { echo 'Native aarch64 runner required' >&2; exit 1; }
case "$(docker info --format '{{.Architecture}}')" in
  aarch64|arm64) ;;
  *) echo 'Native ARM64 Docker Engine required' >&2; exit 1 ;;
esac
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$RUNNER_TEMP" = /* && "$RUNNER_TEMP" != / ]] || exit 1
test_root="$RUNNER_TEMP/gomove-c2b-$GITHUB_RUN_ID"
[[ "$test_root" = "$RUNNER_TEMP"/gomove-c2b-* ]] || exit 1
mkdir "$test_root"
network="gomove-c2b-$GITHUB_RUN_ID"
postgres="gomove-c2b-$GITHUB_RUN_ID-postgres"
osrm="gomove-c2b-$GITHUB_RUN_ID-osrm"
backend="gomove-c2b-$GITHUB_RUN_ID-backend"
pg_image="gomove-c2b-postgis:$GITHUB_RUN_ID"
backend_image="gomove-c2b-backend:$GITHUB_RUN_ID"
osrm_image="ghcr.io/project-osrm/osrm-backend@sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f"
network_id=''
postgres_id=''
osrm_id=''
backend_id=''

cleanup() {
  for container_id in "$backend_id" "$osrm_id" "$postgres_id"; do
    if [[ -n "$container_id" && "$(docker inspect --format '{{index .Config.Labels "gomove.c2b.run"}}' "$container_id" 2>/dev/null || true)" = "$GITHUB_RUN_ID" ]]; then
      docker stop "$container_id" >/dev/null 2>&1 || true
    fi
  done
  if [[ -n "$network_id" && "$(docker network inspect --format '{{index .Labels "gomove.c2b.run"}}' "$network_id" 2>/dev/null || true)" = "$GITHUB_RUN_ID" ]]; then
    docker network rm "$network_id" >/dev/null 2>&1 || true
  fi
  if [[ "$(realpath -m "$test_root")" = "$(realpath "$RUNNER_TEMP")/gomove-c2b-$GITHUB_RUN_ID" ]]; then
    sudo rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

docker build --progress=plain --platform linux/arm64 -f infra/postgis-arm64/Dockerfile -t "$pg_image" infra/postgis-arm64
docker build --progress=plain --platform linux/arm64 -f backend/Dockerfile -t "$backend_image" backend
docker pull --platform linux/arm64 "$osrm_image"
for image in "$pg_image" "$backend_image" "$osrm_image"; do
  [[ "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64 ]]
done
[[ "$(docker image inspect "$backend_image" --format '{{.Config.User}}')" = 10001:10001 ]]
echo 'PASS: Backend, PostGIS and OSRM images are linux/arm64; Backend image declares UID 10001.'

# Missing production secrets/config must fail before a network connection can help.
set +e
timeout 45s docker run --rm --network none --env SPRING_PROFILES_ACTIVE=prod "$backend_image" \
  > "$test_root/missing-config.log" 2>&1
missing_rc=$?
set -e
[[ "$missing_rc" -ne 0 && "$missing_rc" -ne 124 ]]
grep -Eq 'configtree|JWT_SECRET|Could not resolve placeholder|Config data resource' "$test_root/missing-config.log"
echo 'PASS: Production profile fails closed when mandatory configuration is absent.'

umask 077
secret_dir="$test_root/secrets"
mkdir -m 0700 "$secret_dir"
openssl rand -hex 32 > "$secret_dir/db-postgres"
cp "$secret_dir/db-postgres" "$secret_dir/db-backend"
openssl rand -hex 48 > "$secret_dir/JWT_SECRET"
postgres_uid="$(docker run --rm --network none --entrypoint id "$pg_image" -u postgres)"
postgres_gid="$(docker run --rm --network none --entrypoint id "$pg_image" -g postgres)"
[[ "$postgres_uid" =~ ^[1-9][0-9]*$ && "$postgres_gid" =~ ^[1-9][0-9]*$ ]]
sudo chown "$postgres_uid:$postgres_gid" "$secret_dir/db-postgres"
sudo chown 10001:10001 "$secret_dir/db-backend" "$secret_dir/JWT_SECRET"
sudo chmod 0400 "$secret_dir/db-postgres" "$secret_dir/db-backend" "$secret_dir/JWT_SECRET"
[[ "$(stat -c '%u:%g %a' "$secret_dir/db-postgres")" = "$postgres_uid:$postgres_gid 400" ]]
[[ "$(stat -c '%u:%g %a' "$secret_dir/db-backend")" = '10001:10001 400' ]]
[[ "$(stat -c '%u:%g %a' "$secret_dir/JWT_SECRET")" = '10001:10001 400' ]]
docker run --rm --network none --user "$postgres_uid:$postgres_gid" \
  --mount "type=bind,source=$secret_dir/db-postgres,target=/run/secrets/db-password,readonly" \
  --entrypoint sh "$pg_image" -c 'test -r /run/secrets/db-password && test ! -e /run/secrets/spring.datasource.password && test ! -e /run/secrets/JWT_SECRET'
docker run --rm --network none --user 10001:10001 \
  --mount "type=bind,source=$secret_dir/db-backend,target=/run/secrets/spring.datasource.password,readonly" \
  --mount "type=bind,source=$secret_dir/JWT_SECRET,target=/run/secrets/JWT_SECRET,readonly" \
  --entrypoint sh "$backend_image" -c 'test -r /run/secrets/spring.datasource.password && test -r /run/secrets/JWT_SECRET && test ! -e /run/secrets/db-password'
echo 'PASS: Synthetic secret ownership/mode and per-service non-root read access.'

route_dir="$test_root/route"
mkdir "$route_dir"
cp infra/deployment/c2b_synthetic_route.osm "$route_dir/route.osm"
for command in extract partition customize; do
  case "$command" in
    extract) docker run --rm --network none --mount "type=bind,source=$route_dir,target=/data" \
      "$osrm_image" osrm-extract -p /opt/car.lua /data/route.osm ;;
    partition) docker run --rm --network none --mount "type=bind,source=$route_dir,target=/data" \
      "$osrm_image" osrm-partition /data/route.osrm ;;
    customize) docker run --rm --network none --mount "type=bind,source=$route_dir,target=/data" \
      "$osrm_image" osrm-customize /data/route.osrm ;;
  esac
done
chmod 0755 "$route_dir"
# Docker's root-owned preprocessing output needs an explicit readable mode for UID 10001.
sudo chmod -R a+rX "$route_dir"
for suffix in cells partition mldgr; do test -r "$route_dir/route.osrm.$suffix"; done
echo 'PASS: Synthetic fixture preprocesses to an ARM64 MLD dataset (not Hanoi).'

network_id="$(docker network create --label "gomove.c2b.run=$GITHUB_RUN_ID" "$network")"
postgres_id="$(docker run --detach --rm --name "$postgres" --label "gomove.c2b.run=$GITHUB_RUN_ID" --network "$network_id" --network-alias postgres \
  --tmpfs /var/lib/postgresql/data:rw,size=1024m \
  --env POSTGRES_DB=gomove_prod --env POSTGRES_USER=gomove_prod \
  --env POSTGRES_PASSWORD_FILE=/run/secrets/db-password \
  --mount "type=bind,source=$secret_dir/db-postgres,target=/run/secrets/db-password,readonly" \
  "$pg_image")"
for attempt in $(seq 1 90); do
  [[ "$(docker inspect "$postgres" --format '{{.State.Health.Status}}')" = healthy ]] && break
  sleep 2
done
[[ "$(docker inspect "$postgres" --format '{{.State.Health.Status}}')" = healthy ]]
echo 'PASS: Disposable native ARM64 PostgreSQL/PostGIS is healthy.'

osrm_id="$(docker run --detach --rm --name "$osrm" --label "gomove.c2b.run=$GITHUB_RUN_ID" --network "$network_id" --network-alias osrm \
  --user 10001:10001 --read-only --tmpfs /tmp:rw,size=16m --cap-drop ALL \
  --mount "type=bind,source=$route_dir,target=/data,readonly" \
  "$osrm_image" osrm-routed --algorithm mld /data/route.osrm)"
docker exec "$osrm" sh -c 'test -r /data/route.osrm.cells && test -r /data/route.osrm.partition && test -r /data/route.osrm.mldgr && kill -0 1'
echo 'PASS: OSRM non-root process and production-style shallow health probe.'

started="$SECONDS"
backend_id="$(docker run --detach --rm --name "$backend" --label "gomove.c2b.run=$GITHUB_RUN_ID" --network "$network_id" \
  --user 10001:10001 --read-only --tmpfs /tmp:rw,size=64m --cap-drop ALL \
  --env SPRING_PROFILES_ACTIVE=prod \
  --env SPRING_AUTOCONFIGURE_EXCLUDE=org.springframework.boot.autoconfigure.security.servlet.UserDetailsServiceAutoConfiguration \
  --env GOMOVE_PROD_PUBLIC_HOSTNAME=c2b.example.invalid \
  --env GOMOVE_PROD_GEOCODING_BASE_URL=https://geocoder.example.invalid \
  --mount "type=bind,source=$secret_dir/db-backend,target=/run/secrets/spring.datasource.password,readonly" \
  --mount "type=bind,source=$secret_dir/JWT_SECRET,target=/run/secrets/JWT_SECRET,readonly" \
  "$backend_image")"
ready=false
for attempt in $(seq 1 90); do
  if docker exec "$backend" java -cp /app/health HealthProbe \
    http://127.0.0.1:8081/actuator/health/readiness '"status":"UP"' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if ! "$ready"; then docker logs --tail 80 "$backend" >&2; exit 1; fi
echo "PASS: Backend prod readiness is UP after $((SECONDS - started)) seconds."
[[ "$(docker exec -u postgres "$postgres" psql -U gomove_prod -d gomove_prod -Atqc \
  'SELECT version FROM flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1')" = 18 ]]
docker exec -u postgres "$postgres" psql -U gomove_prod -d gomove_prod -Atqc 'SELECT PostGIS_Version()'
echo 'PASS: Fresh isolated DB migrated through Flyway V18 and loads PostGIS.'
docker exec "$backend" java -cp /app/health HealthProbe \
  'http://osrm:5000/route/v1/driving/0.000000,0.000000;0.002000,0.001000?overview=false' '"code":"Ok"'
echo 'PASS: Backend reaches the synthetic OSRM HTTP route privately.'
for container in "$backend" "$postgres" "$osrm"; do
  bindings="$(docker inspect "$container" --format '{{json .HostConfig.PortBindings}}')"
  [[ "$bindings" = '{}' || "$bindings" = null ]]
done
echo 'PASS: No test service publishes a host port.'
docker stats --no-stream --format 'MEASURED: {{.Name}} cpu={{.CPUPerc}} memory={{.MemUsage}}' \
  "$backend" "$postgres" "$osrm"
