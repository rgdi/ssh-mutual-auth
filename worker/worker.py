from celery import Celery
import os
import logging

# Configure basic logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
node_id = os.getenv("NODE_ID", "default-node")

app = Celery(
    "tasks",
    broker=redis_url,
    backend=redis_url
)

@app.task(bind=True)
def process_task(self, task_data):
    # Retrieve allowed_nodes from task headers if they exist
    headers = self.request.headers or {}
    allowed_nodes = headers.get("allowed_nodes")

    if allowed_nodes is not None and node_id not in allowed_nodes:
        logger.warning(f"Task rejected. Node {node_id} is not in allowed_nodes: {allowed_nodes}")
        # Reject task processing due to node identity constraint
        return {"status": "rejected", "reason": "node_not_authorized"}

    logger.info(f"Executing task on {node_id}: {task_data}")
    return {"status": "success", "result": f"Executed on {node_id}"}
