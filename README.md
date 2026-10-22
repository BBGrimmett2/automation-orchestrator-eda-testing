# Automation Orchestrator EDA Testing Environment

Test environment for the `run_ao_workflow` action plugin, which enables Ansible Event-Driven Automation (EDA) to trigger Red Hat Automation Orchestrator (AO) workflows via webhook.

## Overview

This repository provides configuration-as-code to deploy an AAP environment for testing EDA-to-AO integration. The `run_ao_workflow` action plugin is packaged in a custom decision environment and allows EDA rulebooks to invoke AO workflows in response to events.

## Prerequisites

- AAP 2.7 instance with admin access
- Red Hat Automation Orchestrator with admin access
- Access credentials:
  - AAP hostname and personal access token
  - AO host URL, Service Account client ID and secret
  - Event stream authentication token (generated)

## Repository Structure

```
├── aap_config/              # AAP configuration as code
│   ├── eda/                 # EDA Controller objects
│   └── gateway/             # Gateway organizations
├── ao/                      # AO workflow example
│   └── ao-eda-testing.json  # Sample webhook workflow definition
├── rulebooks/               # EDA rulebook examples
│   ├── ao_minimal_example.yml
│   ├── eda_ao_production.yml
│   └── tests/               # Test rulebooks for validation
├── playbooks/
│   └── configure_aap.yml    # Main configuration playbook
├── collections/
│   └── requirements.yml     # Required Ansible collections
└── vault.yml.template       # Secrets template
```

## Setup

### 1. Install Collection Dependencies

```bash
ansible-galaxy collection install -r collections/requirements.yml
```

### 2. Configure Secrets

Copy the vault template and populate with your credentials:

```bash
cp vault.yml.template vault.yml
```

Edit `vault.yml` with the following secrets:

- `vault_aap_hostname` — AAP instance hostname
- `vault_aap_token` — AAP personal access token or service account token
- `vault_ao_host` — Base URL of Automation Orchestrator (e.g., `https://ao.example.com`)
- `vault_ao_client_id` — AO Service Account client ID
- `vault_ao_client_secret` — AO Service Account client secret
- `vault_ao_event_stream_token` — Event stream authentication token

Encrypt the vault file:

```bash
ansible-vault encrypt vault.yml
```

### 3. Deploy AAP Configuration

Run the configuration playbook to create all AAP resources:

```bash
ansible-playbook playbooks/configure_aap.yml -e @vault.yml --ask-vault-pass
```

This creates:
- EDA credential type for AO authentication
- AO credential with OAuth2 configuration
- Decision environment using `quay.io/bgrimmet/ansible-rulebook/ao-de`
- EDA project referencing this repository
- Event stream for webhook ingestion
- Rulebook activation linked to the event stream

### 4. Configure Automation Orchestrator

Import the example workflow into AO:

1. In the AO UI, import `ao/ao-eda-testing.json`
2. Note the webhook path UUID from the imported workflow (or use the example: `755d5f81-a574-4ea3-8461-1934cb4a5c51`)
3. Configure the workflow actions as needed

### 5. Update Rulebook Configuration

Edit the activation configuration in `aap_config/eda/activations.yml` or your chosen rulebook to reference your AO workflow webhook path:

```yaml
action:
  run_ao_workflow:
    webhook_path: "YOUR_WEBHOOK_UUID_HERE"
```

Rerun the configuration playbook if you modified files in `aap_config/`.

### 6. Verify Activation

1. Navigate to **Automation Decisions → Rulebook Activations** in the AAP UI
2. Verify that "AO EDA - Minimal Integration Activation" is running
3. Review activation logs for successful startup

## Testing the Integration

Send a test event to the event stream to trigger the rulebook:

```bash
curl -X POST https://<AAP_HOSTNAME>/eda-event-streams/api/eda/v1/external_event_stream/<EVENT_STREAM_UUID>/post/ \
  -H "Authorization: Bearer <EVENT_STREAM_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "disk_alert",
    "host": "test-server-01",
    "disk_usage": "95"
  }'
```

Replace:
- `<AAP_HOSTNAME>` — Your AAP instance hostname
- `<EVENT_STREAM_UUID>` — Event stream UUID from `aap_config/eda/event_streams.yml`
- `<EVENT_STREAM_TOKEN>` — Event stream authentication token from `vault.yml`

Expected behavior:
1. Event appears in EDA activation logs
2. Rulebook condition matches (`event.payload.event_type == "disk_alert"`)
3. `run_ao_workflow` action triggers AO workflow via webhook
4. AO workflow executes and logs appear in AO UI

## Decision Environment

The testing environment uses a pre-built decision environment:

```
quay.io/bgrimmet/ansible-rulebook/ao-de
```

This image contains a fork of `ansible-rulebook` with the `run_ao_workflow` action plugin integrated.

## Plugin Parameters

The `run_ao_workflow` action supports the following parameters:

| Parameter | Required | Description |
|-----------|----------|-------------|
| `ao_host` | Yes | Base URL of Automation Orchestrator |
| `ao_client_id` | Yes | OAuth2 client ID |
| `ao_client_secret` | Yes | OAuth2 client secret |
| `webhook_path` | Yes* | Webhook UUID for the AO workflow |
| `workflow_name` | Yes* | Alternative to webhook_path, workflow name lookup |
| `payload` | No | JSON payload sent to the workflow |
| `timeout` | No | Maximum time to wait for workflow completion (seconds) |
| `poll_interval` | No | Interval between status checks (seconds) |
| `post_facts` | No | Post workflow results as facts (boolean) |
| `treat_errors_as_failure` | No | Fail rulebook on workflow errors (boolean) |
| `ao_verify_ssl` | No | Verify SSL certificates (default: yes) |

*Either `webhook_path` or `workflow_name` must be provided.