# PostgreSQL Exporter Operations Guide

This guide explains how to monitor multiple PostgreSQL databases with the Kubernetes monitoring stack.

## Architecture

Each database uses three Kubernetes resources:

```text
PostgreSQL database
        ^
        |
postgres-exporter-dbN Deployment
        |
postgres-exporter-dbN Service :9187
        |
Prometheus scrape target
```

Each database has its own Secret:

```text
postgres-exporter-db1-secret
postgres-exporter-db2-secret
...
postgres-exporter-db6-secret
```

Every Secret contains one key:

```text
DATA_SOURCE_NAME
```

The exporter Deployment passes that value to the PostgreSQL exporter container.

## Files

- `12-postgres-exporter.yaml`: exporter Deployments and Services. Secrets are
  created separately through the kubectl CLI.
- `01-prometheus.yaml`: Prometheus scrape targets and database labels.
- The old single-database exporter has been replaced by the multi-database `12-postgres-exporter.yaml`.

## DSN format

```text
postgresql://USER:PASSWORD@HOST:PORT/DATABASE?sslmode=disable
```

Example:

```text
postgresql://monitor_user:password@postgres.example.internal:5432/orders?sslmode=disable
```

URL-encode special characters in the username or password. For example:

```text
@  becomes  %40
#  becomes  %23
:  becomes  %3A
/  becomes  %2F
?  becomes  %3F
```

Use a read-only monitoring account, not the application account.

## Create or update a database Secret

Create one Secret per database. Example for database 1:

```powershell
kubectl create secret generic postgres-exporter-db1-secret `
  --namespace monitoring `
  --from-literal=DATA_SOURCE_NAME='postgresql://USER:PASSWORD@HOST:5432/DATABASE1?sslmode=disable' `
  --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run=client -o yaml | kubectl apply -f -` pattern makes the command safe to run again when rotating a password.

Verify only the Secret metadata. Do not print its value:

```powershell
kubectl get secret postgres-exporter-db1-secret -n monitoring
```

Restart the matching exporter after changing its Secret:

```powershell
kubectl rollout restart deployment/postgres-exporter-db1 -n monitoring
kubectl rollout status deployment/postgres-exporter-db1 -n monitoring
```

## Add a seventh database

Use `db7` consistently in all three places: Secret, Deployment/Service, and Prometheus target.

### 1. Create the seventh Secret

```powershell
kubectl create secret generic postgres-exporter-db7-secret `
  --namespace monitoring `
  --from-literal=DATA_SOURCE_NAME='postgresql://USER:PASSWORD@HOST:5432/DATABASE7?sslmode=disable' `
  --dry-run=client -o yaml | kubectl apply -f -
```

### 2. Add the exporter Deployment and Service

Copy an existing `db6` Deployment and Service block in `12-postgres-exporter.yaml` and change every `db6` reference to `db7`:

```yaml
name: postgres-exporter-db7
namespace: monitoring
labels:
  app.kubernetes.io/name: postgres-exporter
  database: db7
```

The Deployment must reference the seventh Secret:

```yaml
env:
  - name: DATA_SOURCE_NAME
    valueFrom:
      secretKeyRef:
        name: postgres-exporter-db7-secret
        key: DATA_SOURCE_NAME
```

The Service selector must use the same label:

```yaml
selector:
  app.kubernetes.io/name: postgres-exporter
  database: db7
```

### 3. Add the Prometheus target

In `01-prometheus.yaml`, add this block under `postgres-exporters-multi`:

```yaml
- targets:
    - 'postgres-exporter-db7:9187'
  labels:
    database: db7
```

### 4. Apply the changes

```powershell
kubectl apply -f 12-postgres-exporter.yaml
kubectl apply -f 01-prometheus.yaml
```

### 5. Verify database 7

```powershell
kubectl get deployment,service,pod -n monitoring | Select-String postgres-exporter-db7
kubectl rollout status deployment/postgres-exporter-db7 -n monitoring
```

In Prometheus, query:

```promql
pg_up{database="db7"}
```

A value of `1` means the exporter connected successfully. A value of `0` means the exporter is running but cannot connect to the database.

## Delete a database

Deleting the exporter does not delete the PostgreSQL database or any PostgreSQL data. It only stops monitoring that database.

### 1. Remove the Prometheus target

Remove the matching target block from `01-prometheus.yaml`:

```yaml
- targets:
    - 'postgres-exporter-db7:9187'
  labels:
    database: db7
```

Apply the Prometheus configuration:

```powershell
kubectl apply -f 01-prometheus.yaml
```

### 2. Delete the exporter resources

```powershell
kubectl delete deployment postgres-exporter-db7 -n monitoring
kubectl delete service postgres-exporter-db7 -n monitoring
kubectl delete secret postgres-exporter-db7-secret -n monitoring
```

Delete only the database number being retired. For example, replace `db7` with `db3` when removing database 3.

### 3. Confirm removal

```powershell
kubectl get deployment,service,secret -n monitoring | Select-String postgres-exporter-db7
```

No result should be returned.

## Rotate a database password

Update the Secret using the same create-and-apply command:

```powershell
kubectl create secret generic postgres-exporter-db1-secret `
  --namespace monitoring `
  --from-literal=DATA_SOURCE_NAME='postgresql://USER:NEW_PASSWORD@HOST:5432/DATABASE1?sslmode=disable' `
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/postgres-exporter-db1 -n monitoring
kubectl rollout status deployment/postgres-exporter-db1 -n monitoring
```

## Troubleshooting

Check exporter logs:

```powershell
kubectl logs deployment/postgres-exporter-db1 -n monitoring
```

Check the Pod events:

```powershell
kubectl describe pod -l database=db1 -n monitoring
```

Check the exporter metric directly through port-forwarding:

```powershell
kubectl port-forward service/postgres-exporter-db1 9187:9187 -n monitoring
```

Then open:

```text
http://localhost:9187/metrics
```

Useful Prometheus queries:

```promql
pg_up
pg_stat_database_tup_fetched_total{database="db1"}
pg_stat_database_xact_commit_total{database="db1"}
pg_locks_count{database="db1"}
```

## Security rules

- Never commit real DSNs or passwords to Git.
- Do not put database passwords in `01-prometheus.yaml`.
- Do not print Secret values in logs or support tickets.
- Use a separate read-only monitoring user for each database where possible.
- Restrict the monitoring user to the required PostgreSQL permissions.
- Use TLS, for example `sslmode=require` or stricter, when supported by the database.
- The Kubernetes Secret is base64-encoded, not automatically encrypted in Git. Protect cluster access and configure encryption at rest when required.

## MySQL note

These resources are only for PostgreSQL. For MySQL databases, use `17-mysql-exporter.yaml`, the `prom/mysqld-exporter` image, and the MySQL DSN format:

```text
USER:PASSWORD@tcp(HOST:3306)/
```
