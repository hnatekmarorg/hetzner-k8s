#!/usr/bin/env python3
import json
import os
import time

import requests
from prometheus_client import Gauge, start_http_server

API_URL = "https://api.runpod.io/graphql"
API_KEY = os.environ["RUNPOD_API_KEY"]

POD_STATUS = Gauge(
    "runpod_pod_status",
    "1 if the RunPod pod exists this scrape, 0 otherwise",
    ["id", "name", "desired_status", "runtime_status"],
)
POD_COST = Gauge("runpod_pod_cost_per_hour_usd", "RunPod pod cost per hour in USD", ["id", "name"])
ACCOUNT_BALANCE = Gauge("runpod_account_balance_usd", "RunPod account balance in USD", ["kind"])
GPU_LOWEST_PRICE = Gauge(
    "runpod_gpu_lowest_price_usd_hour", "RunPod lowest secure/community bid price per hour", ["id", "name", "cloud"]
)
GPU_MAX_COUNT = Gauge("runpod_gpu_max_count", "RunPod max GPUs per pod for a GPU type", ["id", "name"])


def query(body):
    resp = requests.post(
        API_URL,
        json=body,
        headers={"api-key": API_KEY, "content-type": "application/json"},
        timeout=15,
    )
    resp.raise_for_status()
    data = resp.json()
    if "errors" in data:
        raise RuntimeError(data["errors"])
    return data.get("data", {})


def scrape_pods():
    data = query({"query": "{ pods { id name desiredStatus costPerHr runtimeStatus runtime { uptimeSeconds } } }"})
    seen = set()
    for pod in data.get("pods", []) or []:
        pod_id = pod["id"]
        seen.add(pod_id)
        labels = (
            pod_id,
            pod.get("name") or "",
            pod.get("desiredStatus") or "",
            pod.get("runtimeStatus") or "",
        )
        POD_STATUS.labels(*labels).set(1)
        POD_COST.labels(pod_id, pod.get("name") or "").set(pod.get("costPerHr") or 0)
    for sample in POD_STATUS.collect():
        for s in sample.samples:
            labels = dict(s.labels)
            if labels["id"] not in seen:
                POD_STATUS.labels(labels["id"], labels["name"], labels["desired_status"], labels["runtime_status"]).set(0)


def scrape_account():
    data = query(
        {"query": "{ myself { id email balanceInfo { committedAmount uncommittedAmount lifetimeAmount } } }"}
    )
    balance = (data.get("myself") or {}).get("balanceInfo") or {}
    ACCOUNT_BALANCE.labels("committed").set(balance.get("committedAmount") or 0)
    ACCOUNT_BALANCE.labels("uncommitted").set(balance.get("uncommittedAmount") or 0)
    ACCOUNT_BALANCE.labels("lifetime").set(balance.get("lifetimeAmount") or 0)


def scrape_gpus():
    data = query(
        {
            "query": (
                "{ gpuTypes { id displayName maxGpuCount secureCloud communityCloud "
                'lowestPrice(gpuCount: 1) { minimumBidPrice } } }'
            )
        }
    )
    for gpu in data.get("gpuTypes", []) or []:
        gid = gpu["id"]
        name = gpu.get("displayName") or ""
        GPU_MAX_COUNT.labels(gid, name).set(gpu.get("maxGpuCount") or 0)
        price = (gpu.get("lowestPrice") or {}).get("minimumBidPrice")
        GPU_LOWEST_PRICE.labels(gid, name, "secure").set((price or 0) if gpu.get("secureCloud") else float("-inf"))
        GPU_LOWEST_PRICE.labels(gid, name, "community").set((price or 0) if gpu.get("communityCloud") else float("-inf"))


def main():
    start_http_server(9405)
    while True:
        try:
            scrape_pods()
            scrape_account()
            scrape_gpus()
        except Exception as exc:
            print(f"scrape error: {exc}", flush=True)
        time.sleep(60)


if __name__ == "__main__":
    main()
