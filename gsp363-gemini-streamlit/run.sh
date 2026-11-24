#!/usr/bin/env bash
# GSP363 - Develop GenAI Apps with Gemini and Streamlit: Challenge Lab, Tasks 2 and 3 (Task 1 is the notebook, see README).
# Run in the lab's Cloud Shell from a clone of this repository:
#   REGION=<region from the lab> bash run.sh
# Names default to the usual lab values; override if the lab text says otherwise:
#   BUCKET=<bucket> AR_REPO=<repository> SERVICE_NAME=<service> REGION=... bash run.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
: "${REGION:?set REGION to the region given in the lab instructions}"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
BUCKET=${BUCKET:-$PROJECT_ID-generative-ai}
AR_REPO=${AR_REPO:-chef-repo}
SERVICE_NAME=${SERVICE_NAME:-chef-streamlit-app}
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/$AR_REPO/$SERVICE_NAME"
echo "project=$PROJECT_ID region=$REGION bucket=$BUCKET repo=$AR_REPO service=$SERVICE_NAME"

gcloud services enable run.googleapis.com aiplatform.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com

echo "== Task 2: complete chef.py and upload it"
WORK=~/chef-app
mkdir -p "$WORK" && cd "$WORK"
gcloud storage cp gs://spls/gsp517/chef.py chef.py
python3 "$HERE/patch_chef.py" chef.py
cp "$HERE/Dockerfile" "$HERE/requirements.txt" .
gcloud storage cp chef.py "gs://$BUCKET/"

echo "== Task 2: run the app in Cloud Shell (Web Preview, port 8080)"
python3 -m venv ~/gemini-streamlit
# shellcheck disable=SC1090
source ~/gemini-streamlit/bin/activate
python3 -m pip install -q -r requirements.txt
GCP_PROJECT=$PROJECT_ID GCP_REGION=$REGION nohup streamlit run chef.py \
  --browser.serverAddress=localhost --server.enableCORS=false \
  --server.enableXsrfProtection=false --server.port 8080 > ~/streamlit.log 2>&1 &
echo "  streamlit started, log: ~/streamlit.log"

echo "== Task 3: build and deploy to Cloud Run"
gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" >/dev/null 2>&1 ||
  gcloud artifacts repositories create "$AR_REPO" --location="$REGION" --repository-format=docker
gcloud builds submit --tag "$IMAGE"
gcloud run deploy "$SERVICE_NAME" --port=8080 --image="$IMAGE" --allow-unauthenticated \
  --region="$REGION" --platform=managed --project="$PROJECT_ID" \
  --set-env-vars="GCP_PROJECT=$PROJECT_ID,GCP_REGION=$REGION"
echo "Cloud Run URL: $(gcloud run services describe "$SERVICE_NAME" --region="$REGION" --format='value(status.url)')"
