"""Billing kill switch: detach billing from the project once real spend passes the budget.

Triggered by the "beyond free tier" budget's Pub/Sub notifications (several a
day). Google's documented way to cap spending: with no billing account the
project's paid resources stop. Re-link it in Billing -> Account management.
"""
import base64
import json
import os

import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession

PROJECT_ID = os.environ["PROJECT_ID"]
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
API = "https://cloudbilling.googleapis.com/v1"


def over_budget(notification):
    return float(notification.get("costAmount", 0)) > float(notification.get("budgetAmount", 0))


@functions_framework.cloud_event
def stop_billing(cloud_event):
    notification = json.loads(base64.b64decode(cloud_event.data["message"]["data"]))
    if not over_budget(notification):
        print(f"under budget: {notification.get('costAmount')} of {notification.get('budgetAmount')}")
        return

    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-billing"])
    session = AuthorizedSession(creds)
    url = f"{API}/projects/{PROJECT_ID}/billingInfo"
    info = session.get(url, timeout=30)
    info.raise_for_status()
    if not info.json().get("billingEnabled"):
        print("billing already disabled")
        return
    if DRY_RUN:
        print(f"DRY_RUN: would disable billing on {PROJECT_ID} ({notification.get('costAmount')} spent)")
        return
    resp = session.put(url, json={"billingAccountName": ""}, timeout=30)
    resp.raise_for_status()
    print(f"billing disabled on {PROJECT_ID}: {notification.get('costAmount')} spent")
