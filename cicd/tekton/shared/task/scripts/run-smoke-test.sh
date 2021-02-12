#!/usr/bin/env bash
# Invokes the smoke test service on cloud run
# Pass in NAMESPACE, PROFILE and SLACK_FAILED_WEBHOOK_URL as env vars

NAMESPACE="${NAMESPACE:-smoke}"
FQDN="${FQDN:-$NAMESPACE.iam.forgeops.com}"

TEST_SVC="https://smoketest.forgeops.com/test"

AMADMIN_PASS=$(kubectl get secret -n "$NAMESPACE" am-env-secrets -o jsonpath="{.data.AM_PASSWORDS_AMADMIN_CLEAR}"  | base64 --decode)
echo "Running smoke test against $FQDN"
curl -X POST "$TEST_SVC" --data "fqdn=$FQDN&amadminPassword=$AMADMIN_PASS" || { #If something fails
    curl -X POST -H 'Content-type: application/json' --data \
        '{"text":"Smoke test failed in the '"${FQDN}"' environment. See pipeline logs"}' "$SLACK_FAILED_WEBHOOK_URL"
    exit 1
  }
