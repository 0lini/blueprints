#!/usr/bin/env bash
# Copyright 2026 The Kanister Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# End-to-end test of cnpg-blueprint.yaml on a local kind cluster:
# installs cert-manager, CloudNativePG, the Barman Cloud plugin, MinIO and
# Kanister, then runs backup, restore and delete ActionSets and checks the
# results. Exits non-zero on the first failed check.
#
# Requires: docker, kind, kubectl, helm, kanctl
#
# Settings (environment variables):
#   KIND_CLUSTER            kind cluster name (default: cnpg-e2e)
#   KIND_NODE_IMAGE         kind node image (default: kindest/node:v1.34.0)
#   KIND_LOAD_IMAGES        space-separated local images to load into kind
#                           before installing (for air-gapped runs)
#   KEEP_CLUSTER            1 keeps the kind cluster after the run (default: 0)
#   RUN_FAILURE_TESTS       0 skips the failure-path checks (default: 1)
#   CERT_MANAGER_MANIFEST   cert-manager manifest URL or path
#   CNPG_MANIFEST           CloudNativePG operator manifest URL or path
#   BARMAN_MANIFEST         Barman Cloud plugin manifest URL or path
#   KANISTER_CHART          Kanister operator chart (repo/chart name or path)
#   KANISTER_VERSION        Kanister chart version (ignored for a chart path)
#   MINIO_IMAGE             MinIO image (must include the mc client)

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

KIND_CLUSTER=${KIND_CLUSTER:-cnpg-e2e}
KIND_NODE_IMAGE=${KIND_NODE_IMAGE:-kindest/node:v1.34.0}
KIND_LOAD_IMAGES=${KIND_LOAD_IMAGES:-}
KEEP_CLUSTER=${KEEP_CLUSTER:-0}
RUN_FAILURE_TESTS=${RUN_FAILURE_TESTS:-1}
CERT_MANAGER_MANIFEST=${CERT_MANAGER_MANIFEST:-https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml}
CNPG_MANIFEST=${CNPG_MANIFEST:-https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml}
BARMAN_MANIFEST=${BARMAN_MANIFEST:-https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.1/manifest.yaml}
KANISTER_CHART=${KANISTER_CHART:-kanister/kanister-operator}
KANISTER_VERSION=${KANISTER_VERSION:-0.119.0}
MINIO_IMAGE=${MINIO_IMAGE:-bitnamilegacy/minio:2025.7.23}

KANISTER_NS=kanister
MINIO_NS=minio
TEST_NS=cnpg-test
SOURCE_CLUSTER=pg-source
RESTORED_CLUSTER=pg-restored
BUCKET=cnpg-backups
ROWS=1000

log() { printf '\n=== %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        printf '\nTest failed, collecting diagnostics\n' >&2
        kubectl get actionsets.cr.kanister.io -n $KANISTER_NS -o wide 2>/dev/null || true
        kubectl get clusters.postgresql.cnpg.io,backups.postgresql.cnpg.io,pods -n $TEST_NS 2>/dev/null || true
        kubectl logs -n $KANISTER_NS -l app=kanister-operator --tail=50 2>/dev/null || true
    fi
    if [ "$KEEP_CLUSTER" != "1" ]; then
        kind delete cluster --name "$KIND_CLUSTER" || true
    fi
    exit $rc
}

psql_source() {
    kubectl exec -n $TEST_NS "$1-1" -c postgres -- psql -d app -Atc "$2"
}

# Wait until an ActionSet reaches "complete" or "failed" and print that state
wait_actionset() {
    local name=$1 timeout=${2:-900} state=""
    for _ in $(seq 1 $((timeout / 5))); do
        state=$(kubectl get actionsets.cr.kanister.io "$name" -n $KANISTER_NS -o jsonpath='{.status.state}')
        if [ "$state" = "complete" ] || [ "$state" = "failed" ]; then
            echo "$state"
            return
        fi
        sleep 5
    done
    echo "timeout"
}

actionset_error() {
    kubectl get actionsets.cr.kanister.io "$1" -n $KANISTER_NS -o jsonpath='{.status.error.message}'
}

# Run kanctl and print the name of the ActionSet it created
create_actionset() {
    kanctl create actionset --namespace $KANISTER_NS "$@" | sed -n 's/^actionset \(.*\) created$/\1/p'
}

minio_mc() {
    kubectl exec -n $MINIO_NS deploy/minio -- bash -c \
        "mc alias set e2e http://localhost:9000 minioadmin minioadmin > /dev/null && $1"
}

setup_cluster() {
    log "Creating kind cluster $KIND_CLUSTER"
    if ! kind get clusters | grep -qx "$KIND_CLUSTER"; then
        kind create cluster --name "$KIND_CLUSTER" --image "$KIND_NODE_IMAGE" --wait 120s
    fi
    kubectl config use-context "kind-$KIND_CLUSTER"
    for image in $KIND_LOAD_IMAGES; do
        kind load docker-image --name "$KIND_CLUSTER" "$image"
    done
}

install_operators() {
    log "Installing cert-manager"
    kubectl apply -f "$CERT_MANAGER_MANIFEST"
    kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

    log "Installing CloudNativePG"
    kubectl apply --server-side -f "$CNPG_MANIFEST"
    kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=300s

    log "Installing the Barman Cloud plugin"
    kubectl apply -f "$BARMAN_MANIFEST"
    kubectl rollout status deployment/barman-cloud -n cnpg-system --timeout=300s

    log "Installing Kanister"
    local chart_args=("$KANISTER_CHART")
    if [ ! -d "$KANISTER_CHART" ]; then
        helm repo add kanister https://charts.kanister.io/ > /dev/null
        helm repo update kanister > /dev/null
        chart_args+=(--version "$KANISTER_VERSION")
    fi
    helm upgrade --install kanister "${chart_args[@]}" --namespace $KANISTER_NS --create-namespace --wait
    # RBAC from the README
    kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kanister-operator-cluster-role-cnpg
  labels:
    app: kanister-operator
rules:
- apiGroups: ["postgresql.cnpg.io"]
  resources: ["clusters"]
  verbs: ["get", "list", "create"]
- apiGroups: ["postgresql.cnpg.io"]
  resources: ["backups"]
  verbs: ["get", "list", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kanister-operator-role-cnpg
  labels:
    app: kanister-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kanister-operator-cluster-role-cnpg
subjects:
- kind: ServiceAccount
  name: kanister-kanister-operator
  namespace: $KANISTER_NS
EOF
    kubectl apply -f "$SCRIPT_DIR/cnpg-blueprint.yaml" -n $KANISTER_NS
}

install_minio() {
    log "Installing MinIO"
    kubectl create namespace $MINIO_NS --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n $MINIO_NS -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: $MINIO_IMAGE
        env:
        - name: MINIO_ROOT_USER
          value: minioadmin
        - name: MINIO_ROOT_PASSWORD
          value: minioadmin
        ports:
        - containerPort: 9000
        readinessProbe:
          httpGet:
            path: /minio/health/ready
            port: 9000
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector:
    app: minio
  ports:
  - port: 9000
    targetPort: 9000
EOF
    kubectl rollout status deployment/minio -n $MINIO_NS --timeout=300s
    # CNPG doesn't create the bucket
    minio_mc "mc mb --ignore-existing e2e/$BUCKET"
}

create_source_cluster() {
    log "Creating source cluster $TEST_NS/$SOURCE_CLUSTER"
    kubectl create namespace $TEST_NS --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n $TEST_NS -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
stringData:
  ACCESS_KEY_ID: minioadmin
  ACCESS_SECRET_KEY: minioadmin
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: minio-store
spec:
  configuration:
    destinationPath: s3://$BUCKET/
    endpointURL: http://minio.$MINIO_NS.svc:9000
    s3Credentials:
      accessKeyId:
        name: minio-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: minio-creds
        key: ACCESS_SECRET_KEY
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $SOURCE_CLUSTER
spec:
  instances: 2
  storage:
    size: 1Gi
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: minio-store
EOF
    kubectl wait --for=condition=Ready clusters.postgresql.cnpg.io/$SOURCE_CLUSTER -n $TEST_NS --timeout=600s

    psql_source $SOURCE_CLUSTER "CREATE TABLE e2e (id int PRIMARY KEY, note text)"
    psql_source $SOURCE_CLUSTER "INSERT INTO e2e SELECT g, md5(g::text) FROM generate_series(1, $ROWS) g"
}

BACKUP_AS=""

test_backup() {
    log "Backup"
    BACKUP_AS=$(create_actionset --action backup --blueprint cnpg-blueprint \
        --objects postgresql.cnpg.io/v1/clusters/$TEST_NS/$SOURCE_CLUSTER)
    [ -n "$BACKUP_AS" ] || fail "kanctl did not create the backup ActionSet"
    local state
    state=$(wait_actionset "$BACKUP_AS")
    [ "$state" = "complete" ] || fail "backup ActionSet $BACKUP_AS ended as $state: $(actionset_error "$BACKUP_AS")"

    local artifact backup_name backup_id
    artifact=$(kubectl get actionsets.cr.kanister.io "$BACKUP_AS" -n $KANISTER_NS -o jsonpath='{.status.actions[0].artifacts.backupInfo.keyValue}')
    backup_name=$(kubectl get actionsets.cr.kanister.io "$BACKUP_AS" -n $KANISTER_NS -o jsonpath='{.status.actions[0].artifacts.backupInfo.keyValue.backupName}')
    backup_id=$(kubectl get actionsets.cr.kanister.io "$BACKUP_AS" -n $KANISTER_NS -o jsonpath='{.status.actions[0].artifacts.backupInfo.keyValue.backupID}')
    [ -n "$backup_name" ] && [ -n "$backup_id" ] || fail "backupInfo artifact is incomplete: $artifact"

    local phase
    phase=$(kubectl get backups.postgresql.cnpg.io "$backup_name" -n $TEST_NS -o jsonpath='{.status.phase}')
    [ "$phase" = "completed" ] || fail "Backup $backup_name is in phase $phase"

    minio_mc "mc ls --recursive e2e/$BUCKET/$SOURCE_CLUSTER/base/$backup_id/" | grep -q backup.info \
        || fail "backup $backup_id not found in MinIO"
    echo "Backup $backup_name ($backup_id) completed and is in MinIO"

    # Rows written after the backup must not show up in the restored cluster
    psql_source $SOURCE_CLUSTER "INSERT INTO e2e SELECT g, 'after backup' FROM generate_series($((ROWS + 1)), $((ROWS + 100))) g"
}

test_restore() {
    log "Restore into $RESTORED_CLUSTER"
    local restore_as state count
    restore_as=$(create_actionset --action restore --from "$BACKUP_AS" --options newClusterName=$RESTORED_CLUSTER)
    state=$(wait_actionset "$restore_as" 1500)
    [ "$state" = "complete" ] || fail "restore ActionSet $restore_as ended as $state: $(actionset_error "$restore_as")"

    kubectl wait --for=condition=Ready clusters.postgresql.cnpg.io/$RESTORED_CLUSTER -n $TEST_NS --timeout=60s
    count=$(psql_source $RESTORED_CLUSTER "SELECT count(*) FROM e2e")
    [ "$count" = "$ROWS" ] || fail "restored cluster has $count rows, expected $ROWS"
    echo "Restored cluster has $count rows"
}

test_delete() {
    log "Delete"
    local backup_name backup_id delete_as state
    backup_name=$(kubectl get actionsets.cr.kanister.io "$BACKUP_AS" -n $KANISTER_NS -o jsonpath='{.status.actions[0].artifacts.backupInfo.keyValue.backupName}')
    backup_id=$(kubectl get actionsets.cr.kanister.io "$BACKUP_AS" -n $KANISTER_NS -o jsonpath='{.status.actions[0].artifacts.backupInfo.keyValue.backupID}')
    delete_as=$(create_actionset --action delete --from "$BACKUP_AS")
    state=$(wait_actionset "$delete_as")
    [ "$state" = "complete" ] || fail "delete ActionSet $delete_as ended as $state: $(actionset_error "$delete_as")"

    if kubectl get backups.postgresql.cnpg.io "$backup_name" -n $TEST_NS > /dev/null 2>&1; then
        fail "Backup $backup_name still exists"
    fi
    minio_mc "mc ls --recursive e2e/$BUCKET/$SOURCE_CLUSTER/base/$backup_id/" | grep -q backup.info \
        || fail "backup files for $backup_id were removed from MinIO"
    echo "Backup resource deleted, files kept in MinIO"
}

# Expect an ActionSet to fail with an error that contains a given text
expect_failure() {
    local name=$1 expected=$2 timeout=${3:-900} state message
    state=$(wait_actionset "$name" "$timeout")
    [ "$state" = "failed" ] || fail "ActionSet $name ended as $state, expected failed"
    message=$(actionset_error "$name")
    [[ "$message" == *"$expected"* ]] || fail "ActionSet $name failed with \"$message\", expected it to mention \"$expected\""
    echo "ActionSet $name failed as expected: $expected"
}

test_failures() {
    log "Failure: restore without newClusterName"
    expect_failure "$(create_actionset --action restore --from "$BACKUP_AS")" 'The "newClusterName" option is required'

    log "Failure: restore into an existing cluster"
    expect_failure "$(create_actionset --action restore --from "$BACKUP_AS" --options newClusterName=$RESTORED_CLUSTER)" "already exists"

    log "Failure: backup of a cluster that doesn't exist"
    local missing_as
    missing_as=$(create_actionset --action backup --blueprint cnpg-blueprint \
        --objects postgresql.cnpg.io/v1/clusters/$TEST_NS/no-such-cluster 2>&1 || true)
    if [ -n "$missing_as" ]; then
        expect_failure "$missing_as" "no-such-cluster"
    else
        echo "kanctl refused to create the ActionSet for a missing cluster"
    fi

    log "Failure: backup with broken object store credentials"
    kubectl patch secret minio-creds -n $TEST_NS --type merge -p '{"stringData":{"ACCESS_SECRET_KEY":"wrong"}}'
    expect_failure "$(create_actionset --action backup --blueprint cnpg-blueprint \
        --objects postgresql.cnpg.io/v1/clusters/$TEST_NS/$SOURCE_CLUSTER)" "$SOURCE_CLUSTER" 3000
    kubectl patch secret minio-creds -n $TEST_NS --type merge -p '{"stringData":{"ACCESS_SECRET_KEY":"minioadmin"}}'
}

main() {
    for tool in docker kind kubectl helm kanctl; do
        command -v $tool > /dev/null || fail "$tool is not installed"
    done
    trap cleanup EXIT
    setup_cluster
    install_operators
    install_minio
    create_source_cluster
    test_backup
    test_restore
    test_delete
    if [ "$RUN_FAILURE_TESTS" = "1" ]; then
        test_failures
    fi
    log "PASS"
}

main "$@"
