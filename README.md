# Tailscale/Celery Distributed Worker Node

This repository configures a lightweight, secure distributed worker node. Within a Tailscale network, each node consists of a Celery worker, mTLS client, and a Prometheus monitoring agent. Security is enforced through certificates and public keys (via Smallstep Certificates), ensuring the node only executes tasks it is authorized for.

---

## Node Architecture

Each node in the network runs the following components:

| Component     | Function                                |
| ------------- | --------------------------------------- |
| Tailscale     | Private network connection              |
| Worker        | Executes assigned Celery tasks          |
| Cert Client   | Retrieves node certificates from the CA |
| Node Exporter | Exports host metrics to Prometheus      |
| Watcher       | Reports node status (optional)          |

---

## Getting Started

Each node defines its identity via environment variables. Start by copying the example configuration:

```bash
cp .env.example .env
```

Edit `.env` to define the node identity:
```env
NODE_ID=node-eu-1
NODE_QUEUE=queue_cpu
```

### Starting the Node

Make sure Tailscale is running on the host. Then start the stack:

```bash
docker-compose up -d
```

---

## Security Model

The infrastructure relies on multiple layers of security to emulate a distributed orchestration system.

### 1. Redis Accessible Only via Tailscale
Redis should be bound exclusively to your Tailscale interface (`100.x.x.x`), preventing any internet exposure.

### 2. Tailscale ACLs
Restrict access so workers can only communicate with the Redis server:

```json
{
 "acls": [
  {
   "action": "accept",
   "src": ["tag:worker"],
   "dst": ["tag:rpi:6379"]
  }
 ]
}
```

### 3. Cryptographic Node Identity (mTLS)
Each node securely provisions a certificate (`node.crt`, `node.key`) via a central CA (Smallstep). This allows for strong identity verification and enables prompt revocation of compromised nodes. Workers can validate the `CN` of the certificates.

### 4. Task-level Restriction
Nodes explicitly verify task authorization prior to execution. If a task requires execution on specific nodes, the worker verifies `task.headers["allowed_nodes"]` against its local `NODE_ID`. Unrecognized nodes will gracefully reject the task.

### 5. Monitoring
Each node exports metrics (via Prometheus `node-exporter`) that can be centralized into a Grafana dashboard.

---

## End-to-End Workflow

1. An authorized node/service creates a task.
2. The task is queued securely in Redis.
3. The assigned worker checks its relevant queue.
4. The worker verifies its authorization for the task.
5. The task is executed.
6. Result/status is reported back.

---

## Resource Footprint

The node stack is highly optimized and suited for low-resource VPS or Raspberry Pi environments:

| Service       | Approx. RAM |
| ------------- | ----------- |
| Worker        | ~80 MB      |
| Node Exporter | ~20 MB      |
| Step Client   | ~10 MB      |

**Total ≈ 110 MB**
