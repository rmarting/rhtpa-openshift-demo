# Demo of Red Hat Trusted Profile Analyzer on OpenShift

This repository installs **Red Hat Trusted Profile Analyzer (RHTPA)** on **OpenShift** with Kustomize.
It also installs Keycloak, which RHTPA uses for sign-in.

Manifests that are the same on every OpenShift cluster live in `base`. Two overlays extend that base:

| Overlay | Cluster | What it changes |
|---|---|---|
| `crc` | OpenShift Local | Hostnames under `apps-crc.testing`, documents on a filesystem volume |
| `ocp` | A standard OpenShift cluster | The same hostnames, using that cluster's ingress domain, documents in an object bucket |

The components installed are:

- the **Red Hat build of Keycloak (RHBK)** operator
- one Keycloak server, custom resource name `keycloak-sso`
- a realm named `trustify`, the public client `frontend`, the confidential client `cli`, and two users
- the **Red Hat Trusted Profile Analyzer** operator
- one **TrustedProfileAnalyzer** custom resource
- PostgreSQL databases for Keycloak and RHTPA

Keycloak is its own application. The custom resource is `keycloak-sso`, and its labels use `app.kubernetes.io/part-of: keycloak`. RHTPA consumes the `trustify` realm.

An optional later stage adds the [Red Hat Dependency Analytics](https://marketplace.visualstudio.com/items?itemName=redhat.fabric8-analytics) backend in the same namespace. Each install guide has the steps.

## What you can open when it finishes

This is a diagram of the final deployment:

![Red Hat Trusted Profile Analyzer Topology](./media/topology.png)

On OpenShift Local the hosts are:

| | |
|---|---|
| RHTPA console | `https://server-trusted-profile-analyzer.apps-crc.testing` |
| Keycloak account login | `https://sso-trusted-profile-analyzer.apps-crc.testing` |
| Keycloak master admin | `https://sso-trusted-profile-analyzer.apps-crc.testing/admin` |
| Keycloak TPA realm | `https://sso-trusted-profile-analyzer.apps-crc.testing/realms/trustify` |

On a standard OpenShift cluster the same four hosts use that cluster's apps domain in place of `apps-crc.testing`. The deploy script prints the URLs when the install finishes.

## Lab accounts

These values are written in `base/10-database/secrets.yaml` and in the realm import.
Change them before the routes are reachable by anyone else.

| Who | Username | Password | What they can do |
|---|---|---|---|
| RHTPA administrator | `admin` | `admin123456` | Read, upload, update, and delete documents. Realm roles `trustify-admin` and `trustify-manager`. |
| RHTPA reader | `analyst` | `analyst123456` | Read. Realm role `trustify-user`. |
| Keycloak master administrator | `admin` | `admin123456` | The `/admin` console. This is a different account from the RHTPA `admin` user: same password, different realm (`master`). |
| CLI client | client id `cli` | secret `5460cc91-4e20-4edd-881c-b15b169f8a79` | Service account for API calls. Same lab secret as the RHTPA 3.1 deployment guide. |

Database passwords, if you need them while debugging:

| Database | User | Password | Service |
|---|---|---|---|
| `trustify` | `trustify` | `trustify-lab-pass` | `rhtpa-postgresql:5432` |
| maintenance | `postgres` | `postgres-lab-pass` | `rhtpa-postgresql:5432` |
| `keycloak` | `keycloak` | `keycloak-lab-pass` | `keycloak-postgresql:5432` |

### Why the two users are different

- `trustify-user` (analyst) maps to read permissions.
- `trustify-manager` and `trustify-admin` (admin) map to read and write permissions.

## Choose a cluster

Both environments use the same `base` manifests, the `oc` client, and `python3`. The deploy script uses
`python3` to read the operator catalog. The account you use must be **cluster-admin**,
and the cluster pull secret must be allowed to pull images from `registry.redhat.io`.

### OpenShift Local

OpenShift Local is the laptop demo. `crc` runs OpenShift in a virtual machine. The apps domain is
`apps-crc.testing`, the overlay is `crc`, and the install command is `./deploy/deploy.sh crc`.
Documents stay on a filesystem volume.

Follow [Install on OpenShift Local](./README-crc.md) from the virtual machine setup through removal.

### OpenShift

A standard OpenShift cluster is a cluster you already administer. This repository does not install that cluster.
The overlay is `ocp`, and the install command is `./deploy/deploy.sh ocp`. The script reads the cluster ingress
domain and writes it into the hostnames before it applies the overlay. PostgreSQL uses the default StorageClass.
RHTPA stores documents in an object bucket from OpenShift Data Foundation.

You can request the cluster from the Red Hat Demo Platform. The catalog item is **OpenShift Container Platform Cluster (Multi-Cloud)**.

Follow [Install on OpenShift](./README-ocp.md) from ordering the cluster through removal.

## Troubleshooting

These notes apply after either install.

### Unable to authenticate to Lightwell Network repositories

Issue: [https://redhat.atlassian.net/browse/TC-7588](https://redhat.atlassian.net/browse/TC-7588)

The current TPA 3.1.1 does not manage correctly the injection of the Lightwell credentials
from a file system mounted in a secret.

Sample log message:

```text
2026-11-16T14:00:08.407177Z ERROR ThreadId(01) run:run_once:run_once_http: trustify_module_importer::runner::http: error=file credential source is disabled; set IMPORTER_CREDENTIAL_PATHS to allow one or more paths http=HttpImporter {
common: CommonImporter {
disabled: false,
period: 86400s,
description: None,
labels: Labels(
{},
),
},
source: "https://packages.redhat.com/lightwell/osv/python/remediated/",
discovery: Pulp,
auth: Some(
AuthConfig {
method: Basic {
username: File(
"/run/secrets/rhtpa-rhlw-creds/RH_LW_USERNAME",
),
password: File(
"/run/secrets/rhtpa-rhlw-creds/RH_LW_PASSWORD",
),
},
},
),
only_patterns: [],
fetch_retries: None,
} _continuation=Null
```

Workaround:

* Add the environment variable `IMPORTER_CREDENTIAL_PATHS` with value `/run/secrets/rhtpa-rhlw-creds`
for the `importer` deployment.

### OSV Import fails for ecosytem "Red Hat Lightwell:Maven"

Issue: [https://redhat.atlassian.net/browse/TC-7303](https://redhat.atlassian.net/browse/TC-7303)

The current TPA 3.1.1 does not identify the new Lightwell ecosystem `Red Hat Lightwell:Maven` and
rejects all the entries with that value. This issue will be fixed in TPA 3.1.2 and beyond.

Sample log message:

```text
2026-11-16T14:46:37.210286Z INFO ThreadId(01) run:run_once:run_once_http:transaction:transaction_with_config:ingest:detect_as: trustify_module_ingestor::service::detect: error=invalid format: Failed to parse: unknown variant `Red Hat Lightwell:Maven`, expected `Ecosystem` http=HttpImporter {
common: CommonImporter {
disabled: false,
period: 86400s,
description: None,
labels: Labels(
{},
),
},
source: "https://packages.redhat.com/lightwell/osv/java/remediated/",
discovery: Pulp,
auth: Some(
AuthConfig {
method: Basic {
username: File(
"/run/secrets/rhtpa-rhlw-creds/RH_LW_USERNAME",
),
password: File(
"/run/secrets/rhtpa-rhlw-creds/RH_LW_PASSWORD",
),
},
},
),
only_patterns: [],
fetch_retries: None,
} _continuation=Null
```
