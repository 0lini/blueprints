# CloudNativePG (CNPG)

[CloudNativePG](https://cloudnative-pg.io) is a Kubernetes operator that manages the full lifecycle of highly available PostgreSQL clusters. Backups to object storage (S3, GCS, Azure Blob and S3-compatible stores such as MinIO) are handled by the [Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/).

## Introduction

This blueprint uses CNPG's own backup and recovery mechanism. Kanister doesn't copy any data itself:

- **Backup**: the blueprint creates an on-demand CNPG `Backup` with `method: plugin`, which takes a base backup with the Barman Cloud plugin. It waits for the `Backup` to complete and records its name and backup ID, the `ObjectStore` and server name it was written to, and the cluster's spec as Kanister output artifacts.
- **Restore**: CNPG can't restore an existing cluster in place, so the blueprint creates a **new** `Cluster`, named by the `newClusterName` option. The new cluster gets the spec the source cluster had at backup time and is bootstrapped from the object store with `bootstrap.recovery` and an `externalClusters` entry for the plugin. Recovery stops at the end of the backup (`recoveryTarget.backupID` with `targetImmediate`), so the new cluster holds exactly the data of that backup. The blueprint waits for the new cluster to become `Ready`.
- **Delete**: the blueprint deletes the CNPG `Backup` resource. The backup files in object storage are **not** removed. Their lifecycle is governed by the `retentionPolicy` of the `ObjectStore`.

Backup data is stored in the object store configured on the `Cluster`, not in a Kanister Profile location, so the ActionSets don't need a Profile.

## Prerequisites

- Kubernetes 1.30+
- PV provisioner support in the underlying infrastructure
- [cert-manager](https://cert-manager.io), required by the Barman Cloud plugin
- CloudNativePG 1.26+ (tested with 1.30.1)
- Barman Cloud plugin 0.5+ (tested with 0.15.1)
- An object storage bucket. CNPG doesn't create it.
- Kanister controller version 0.119.0 installed in your cluster, let's assume in Namespace `kanister`
- Kanctl CLI installed (https://docs.kanister.io/tooling.html#install-the-tools)

## Installing CloudNativePG and the Barman Cloud plugin

```bash
# cert-manager
$ kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml

# CloudNativePG operator
$ kubectl apply --server-side -f \
    https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml

# Barman Cloud plugin, installed in the same namespace as the operator
$ kubectl apply -f \
    https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.1/manifest.yaml

# Verify both are running
$ kubectl get deployments -n cnpg-system
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
barman-cloud              1/1     1            1           1m
cnpg-controller-manager   1/1     1            1           2m
```

See the [CNPG installation guide](https://cloudnative-pg.io/documentation/current/installation_upgrade/) and the [plugin installation guide](https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/) for Helm and other installation methods.

## Creating a Cluster

**NOTE:**

The blueprint requires the **Barman Cloud plugin** to be configured on the `Cluster`, with an entry named `barman-cloud.cloudnative-pg.io` in `spec.plugins` that sets `barmanObjectName`. The backup action fails if this entry is missing. Clusters that use the deprecated in-tree `spec.backup.barmanObjectStore` aren't supported.

Create an `ObjectStore` that points to your bucket, and a `Cluster` named `pg` in the `cnpg-test` namespace that archives to it. The example below uses an S3-compatible MinIO endpoint. Replace the bucket, endpoint and credentials with your own:

```bash
$ kubectl create namespace cnpg-test

$ kubectl create secret generic s3-creds -n cnpg-test \
    --from-literal=ACCESS_KEY_ID=<access key> \
    --from-literal=ACCESS_SECRET_KEY=<secret key>

$ cat <<EOF | kubectl apply -n cnpg-test -f -
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: s3-store
spec:
  configuration:
    destinationPath: s3://cnpg-backups/
    endpointURL: http://minio.minio.svc:9000
    s3Credentials:
      accessKeyId:
        name: s3-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: s3-creds
        key: ACCESS_SECRET_KEY
  retentionPolicy: "30d"
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg
spec:
  instances: 2
  storage:
    size: 1Gi
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: s3-store
EOF
```

For AWS S3, GCS and Azure Blob Storage, configure the `ObjectStore` as described in the [plugin's object store documentation](https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/).

Wait until the cluster is ready:

```bash
$ kubectl get clusters.postgresql.cnpg.io -n cnpg-test
NAME   AGE   INSTANCES   READY   STATUS                     PRIMARY
pg     2m    2           2       Cluster in healthy state   pg-1
```

## Integrating with Kanister

If you created the `Cluster` with a name other than `pg` or in a namespace other than `cnpg-test`, update the commands below to use the correct name and namespace.

### Grant Kanister access to CNPG resources

The blueprint's `KubeTask` and `WaitV2` phases read and create `clusters`, and create, read and delete `backups`. Grant the Kanister controller's service account these permissions:

```bash
$ cat <<EOF | kubectl apply -f -
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
  namespace: kanister
EOF
```

You may have to update the service account name and namespace in the binding if you deployed Kanister with a different release name or namespace.

### Create Blueprint

Create Blueprint in the same namespace as the Kanister controller

```bash
$ kubectl create -f ./cnpg-blueprint.yaml -n kanister
blueprint.cr.kanister.io/cnpg-blueprint created
```

Once the cluster is running, you can populate it with some data. Let's add a table called "company" to the `app` database:

```bash
$ kubectl exec -ti -n cnpg-test pg-1 -c postgres -- psql -d app

app=# CREATE TABLE COMPANY(
     ID INT PRIMARY KEY     NOT NULL,
     NAME           TEXT    NOT NULL,
     AGE            INT     NOT NULL,
     ADDRESS        CHAR(50),
     SALARY         REAL,
     CREATED_AT    TIMESTAMP
);
CREATE TABLE

app=# INSERT INTO COMPANY (ID,NAME,AGE,ADDRESS,SALARY,CREATED_AT) VALUES (10, 'Paul', 32, 'California', 20000.00, now());
INSERT 0 1
app=# INSERT INTO COMPANY (ID,NAME,AGE,ADDRESS,SALARY,CREATED_AT) VALUES (20, 'Omkar', 32, 'California', 20000.00, now());
INSERT 0 1
app=# INSERT INTO COMPANY (ID,NAME,AGE,ADDRESS,SALARY,CREATED_AT) VALUES (30, 'Saima', 32, 'California', 20000.00, now());
INSERT 0 1

app=# SELECT id, name FROM company;
 id | name
----+-------
 10 | Paul
 20 | Omkar
 30 | Saima
(3 rows)
```

`pg-1` is the primary in a fresh cluster. Check the `PRIMARY` column of `kubectl get clusters.postgresql.cnpg.io` if it has failed over since.

## Protect the Application

You can now take a backup of the PostgreSQL data using an ActionSet defining backup for this application. Create an ActionSet in the same namespace as the controller.

```bash
$ kanctl create actionset --action backup --namespace kanister --blueprint cnpg-blueprint \
    --objects postgresql.cnpg.io/v1/clusters/cnpg-test/pg
actionset backup-8xk2q created

# View the status of the actionset
$ kubectl --namespace kanister get actionsets.cr.kanister.io backup-8xk2q
NAME           PROGRESS   LAST TRANSITION TIME   STATE
backup-8xk2q   100.00     2026-10-17T09:20:41Z   complete
```

The backup action waits up to 45 minutes for the `Backup` to finish. For larger databases, raise the `timeout` of the `waitForBackup` phase in the blueprint.

Once the backup completes, you can see the CNPG `Backup` it created:

```bash
$ kubectl get backups.postgresql.cnpg.io -n cnpg-test
NAME                         AGE   CLUSTER   METHOD   PHASE       ERROR
pg-kanister-20261017092012   1m    pg        plugin   completed
```

The ActionSet's `backupInfo` artifact holds the `Backup` name, its backup ID, the `ObjectStore` and server name, and the cluster spec (base64-encoded JSON) that the restore action uses:

```bash
$ kubectl --namespace kanister get actionsets.cr.kanister.io backup-8xk2q \
    -o jsonpath='{.status.actions[0].artifacts.backupInfo.keyValue}'
```

### Disaster strikes!

Let's say someone accidentally deleted the `company` table:

```bash
$ kubectl exec -ti -n cnpg-test pg-1 -c postgres -- psql -d app -c 'DROP TABLE company;'
DROP TABLE
```

### Restore the Application

CNPG restores a backup into a **new** cluster. Pass its name with the `newClusterName` option. The new cluster is created in the same namespace as the backed up cluster, because it reads the backup through the same `ObjectStore`:

```bash
# Make sure to use correct backup actionset name here
$ kanctl --namespace kanister create actionset --action restore --from "backup-8xk2q" \
    --options newClusterName=pg-restored
actionset restore-backup-8xk2q-6vbbr created

# View the status of the ActionSet
$ kubectl --namespace kanister get actionsets.cr.kanister.io restore-backup-8xk2q-6vbbr
NAME                         PROGRESS   LAST TRANSITION TIME   STATE
restore-backup-8xk2q-6vbbr   100.00     2026-10-17T09:31:17Z   complete
```

The restore action waits up to 45 minutes for the new cluster to become ready. For larger databases, raise the `timeout` of the `waitForClusterReady` phase in the blueprint.

Once the ActionSet status is set to "complete", the new cluster holds the data as of the backup:

```bash
$ kubectl get clusters.postgresql.cnpg.io -n cnpg-test
NAME          AGE   INSTANCES   READY   STATUS                     PRIMARY
pg            40m   2           2       Cluster in healthy state   pg-1
pg-restored   4m    2           2       Cluster in healthy state   pg-restored-1

$ kubectl exec -ti -n cnpg-test pg-restored-1 -c postgres -- psql -d app -c 'SELECT id, name FROM company;'
 id | name
----+-------
 10 | Paul
 20 | Omkar
 30 | Saima
(3 rows)
```

Point your applications at the new cluster's services (`pg-restored-rw`, `pg-restored-ro`). Its credentials are in new secrets (`pg-restored-app`, `pg-restored-superuser` if enabled).

**NOTE:**

- The restore action fails if `newClusterName` is missing, if a `Cluster` with that name already exists, or if it is the name of the backed up cluster.
- The new cluster archives its WAL to the same `ObjectStore`, under its own name. If an earlier cluster with the same name archived there, CNPG refuses to start the new one because its WAL archive isn't empty. Pick a new name or clean up that path in the bucket.
- The restore only needs the `backupInfo` artifact and the `ObjectStore`. It still works if the source cluster has been deleted, as long as the `ObjectStore` (and its credentials secret) still exists in the namespace. Because Kanister needs the ActionSet's object to exist, point the restore ActionSet at the namespace instead: `kanctl create actionset --action restore --from backup-8xk2q --namespacetargets cnpg-test --options newClusterName=pg-restored`.

### Delete the Artifacts

The artifacts created by the backup action can be cleaned up using the following command:

```bash
$ kanctl --namespace kanister create actionset --action delete --from "backup-8xk2q"
actionset delete-backup-8xk2q-k9ncm created

# View the status of the ActionSet
$ kubectl --namespace kanister get actionsets.cr.kanister.io delete-backup-8xk2q-k9ncm
NAME                        PROGRESS   LAST TRANSITION TIME   STATE
delete-backup-8xk2q-k9ncm   100.00     2026-10-17T09:40:02Z   complete
```

This deletes the CNPG `Backup` resource only. The backup files and WAL in object storage are kept until the `ObjectStore`'s `retentionPolicy` removes them. See the [plugin retention documentation](https://cloudnative-pg.io/plugin-barman-cloud/docs/retention/) for details.

## Limitations

- Only clusters that back up with the Barman Cloud plugin are supported. The in-tree `barmanObjectStore` method (deprecated) and volume snapshot backups aren't.
- Restore always creates a new cluster in the source cluster's namespace. Restoring in place, or into another namespace, isn't supported.
- The new cluster's `spec.externalClusters` and `spec.replica` are replaced by the recovery source, and any Barman Cloud plugin entry in `spec.plugins` gets `serverName` set to the new cluster's name. The rest of the spec is copied from the source cluster as it was at backup time.
- The restore recovers to the end of the backup. Point-in-time recovery to a later time isn't exposed by the blueprint.

## Testing

`e2e.sh` runs the backup, restore and delete actions end to end on a local [kind](https://kind.sigs.k8s.io) cluster. It installs cert-manager, CNPG, the Barman Cloud plugin, MinIO and Kanister, writes 1,000 rows to a 2-instance cluster, and checks that:

- the backup creates a completed `Backup`, a `backupInfo` artifact and backup files in MinIO,
- the restored cluster becomes ready with exactly the 1,000 rows (rows written after the backup are not restored),
- the delete action removes the `Backup` resource but leaves the files in MinIO,
- the actions fail with a clear error when `newClusterName` is missing or already taken, when the cluster doesn't exist, and when the object store credentials are wrong.

```bash
$ ./e2e.sh
```

It requires `docker`, `kind`, `kubectl`, `helm` and `kanctl`, and deletes the kind cluster at the end (set `KEEP_CLUSTER=1` to keep it). See the top of the script for the other settings.

## Troubleshooting

If you run into any issues with the above commands, you can check the logs of the controller using:

```bash
$ kubectl --namespace kanister logs -l app=kanister-operator
```

you can also check events of the actionset

```bash
$ kubectl describe actionset restore-backup-8xk2q-6vbbr -n kanister
```

Backup and recovery are carried out by CNPG and the Barman Cloud plugin, so their status and logs are also useful:

```bash
# Backup status and error reported by CNPG
$ kubectl get backups.postgresql.cnpg.io -n cnpg-test -o wide

# Status of the restored cluster, including the recovery job
$ kubectl describe clusters.postgresql.cnpg.io pg-restored -n cnpg-test
$ kubectl get pods -n cnpg-test

# Barman Cloud sidecar logs on the source cluster's instances
$ kubectl logs -n cnpg-test pg-1 -c plugin-barman-cloud

# Operator and plugin logs
$ kubectl logs -n cnpg-system deployment/cnpg-controller-manager
$ kubectl logs -n cnpg-system deployment/barman-cloud
```

## Cleanup

### Delete the Clusters

```bash
$ kubectl delete clusters.postgresql.cnpg.io pg pg-restored -n cnpg-test
$ kubectl delete objectstores.barmancloud.cnpg.io s3-store -n cnpg-test
```

### Uninstalling CloudNativePG

```bash
$ kubectl delete -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.1/manifest.yaml
$ kubectl delete -f https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml
```

### Delete CRs
Remove Blueprint, ActionSets and the RBAC created for Kanister

```bash
$ kubectl delete blueprints.cr.kanister.io cnpg-blueprint -n kanister

$ kubectl --namespace kanister delete actionsets.cr.kanister.io backup-8xk2q restore-backup-8xk2q-6vbbr delete-backup-8xk2q-k9ncm

$ kubectl delete clusterrolebinding kanister-operator-role-cnpg
$ kubectl delete clusterrole kanister-operator-cluster-role-cnpg
```
