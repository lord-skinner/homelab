# GenAI Toolbox for n8n Integration

This directory contains Kubernetes manifests to deploy the Google GenAI Toolbox in your homelab environment, allowing integration with your n8n workflows.

## Prerequisites

- A running Kubernetes cluster
- kubectl installed and configured
- A Google API key for accessing Google AI APIs

## Setup Instructions

1. Configure your Google API key:

```bash
# Edit the .env file
nano .env

# Update the GOOGLE_API_KEY value with your actual API key
# GOOGLE_API_KEY=your_api_key_here
```

2. Apply the Kubernetes manifests using the setup script:

```bash
# Navigate to the genai-toolbox directory
cd /home/skinner/homelab/genai-toolbox

# Run the setup script
./setup.sh
```

3. Verify the deployment:

```bash
kubectl get pods -n genai-toolbox
```

## Using with n8n

To use the GenAI Toolbox with n8n, you can create a workflow that makes HTTP requests to the GenAI Toolbox service. The service will be available inside the cluster at:

```
http://genai-toolbox.genai-toolbox.svc.cluster.local:8080
```

### Example Endpoints

- `/healthz` - Health check endpoint
- `/api/vertex/text` - For text generation
- `/api/vertex/chat` - For chat completion
- `/api/vertex/embedding` - For embedding generation

Refer to the [GenAI Toolbox documentation](https://googleapis.github.io/genai-toolbox/) for more details on available endpoints and parameters.

## Troubleshooting

If you encounter issues with the deployment, check the following:

1. Verify that the GenAI Toolbox pod is running:

```bash
kubectl get pods -n genai-toolbox
```

2. Check the logs of the GenAI Toolbox pod:

```bash
kubectl logs -n genai-toolbox $(kubectl get pods -n genai-toolbox -o jsonpath='{.items[0].metadata.name}')
```

3. Ensure your Google API key has access to the required Google AI APIs and has the necessary permissions.
