#!/usr/bin/env bash
# GSP393 - Implement CI/CD Pipelines on Google Cloud: Challenge Lab
# Run in the lab's Cloud Shell:
#   REGION=<region from the lab> ZONE=<zone from the lab> bash run.sh
# Re-running is safe: existing repository, clusters, targets and releases are reused.
set -euo pipefail

: "${REGION:?set REGION to the region given in the lab instructions}"
: "${ZONE:?set ZONE to the zone given in the lab instructions}"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
export PROJECT_ID REGION ZONE
PIPELINE=web-app
REPO=cicd-challenge
CLUSTERS=(cd-staging cd-production)

gcloud config set compute/region "$REGION" >/dev/null
gcloud config set deploy/region "$REGION" >/dev/null
echo "project=$PROJECT_ID region=$REGION zone=$ZONE"

wait_rollout() {  # $1 release, $2 target, $3 wanted state
  local state
  for _ in $(seq 1 90); do
    state=$(gcloud deploy rollouts list --delivery-pipeline "$PIPELINE" --release "$1" \
      --filter="targetId=$2" --format="value(state)" 2>/dev/null | head -1)
    echo "  $1 -> $2: ${state:-not yet}"
    [ "$state" = "$3" ] && return 0
    [ "$state" = "FAILED" ] && { echo "rollout failed"; return 1; }
    sleep 20
  done
  echo "timeout waiting for $1 -> $2 ($3)"; return 1
}

echo "== Task 1: APIs, permissions, Artifact Registry, clusters"
gcloud services enable container.googleapis.com clouddeploy.googleapis.com \
  artifactregistry.googleapis.com cloudbuild.googleapis.com
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
for role in roles/clouddeploy.jobRunner roles/container.developer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="$role" --condition=None >/dev/null
done
gcloud artifacts repositories describe "$REPO" --location "$REGION" >/dev/null 2>&1 ||
  gcloud artifacts repositories create "$REPO" --repository-format=docker \
    --location="$REGION" --description="Image registry for tutorial web app"
for c in "${CLUSTERS[@]}"; do
  gcloud container clusters describe "$c" --region "$REGION" >/dev/null 2>&1 ||
    gcloud container clusters create "$c" --region "$REGION" --node-locations="$ZONE" \
      --num-nodes=1 --async
done

echo "== Task 2: build the image"
cd ~
[ -d cloud-deploy-tutorials ] || git clone https://github.com/GoogleCloudPlatform/cloud-deploy-tutorials.git
cd cloud-deploy-tutorials
git checkout c3cae80 --quiet
cd tutorials/base
envsubst < clouddeploy-config/skaffold.yaml.template > web/skaffold.yaml
(cd web && skaffold build --interactive=false \
  --default-repo "$REGION-docker.pkg.dev/$PROJECT_ID/$REPO" --file-output artifacts.json)

echo "== Task 3: delivery pipeline and targets"
sed -e "s/targetId: staging/targetId: cd-staging/" \
    -e "s/targetId: prod/targetId: cd-production/" \
    -e "/targetId: test/d" \
    clouddeploy-config/delivery-pipeline.yaml.template > clouddeploy-config/delivery-pipeline.yaml
gcloud deploy apply --file=clouddeploy-config/delivery-pipeline.yaml

for c in "${CLUSTERS[@]}"; do
  until [ "$(gcloud container clusters describe "$c" --region "$REGION" --format='value(status)')" = RUNNING ]; do
    echo "  waiting for cluster $c"; sleep 30
  done
  gcloud container clusters get-credentials "$c" --region "$REGION"
  kubectl config delete-context "$c" >/dev/null 2>&1 || true
  kubectl config rename-context "gke_${PROJECT_ID}_${REGION}_${c}" "$c"
  kubectl --context "$c" apply -f kubernetes-config/web-app-namespace.yaml
done

# The tutorial ships target-staging / target-prod templates named staging / prod; the lab wants cd-staging / cd-production.
envsubst < clouddeploy-config/target-staging.yaml.template |
  sed -e "s/name: staging/name: cd-staging/" -e "s#clusters/staging#clusters/cd-staging#" \
  > clouddeploy-config/target-cd-staging.yaml
envsubst < clouddeploy-config/target-prod.yaml.template |
  sed -e "s/name: prod/name: cd-production/" -e "s#clusters/prod#clusters/cd-production#" \
  > clouddeploy-config/target-cd-production.yaml
for c in "${CLUSTERS[@]}"; do
  gcloud deploy apply --file "clouddeploy-config/target-$c.yaml"
done

echo "== Task 4: release web-app-001 to staging"
gcloud deploy releases describe web-app-001 --delivery-pipeline "$PIPELINE" >/dev/null 2>&1 ||
  gcloud deploy releases create web-app-001 --delivery-pipeline "$PIPELINE" \
    --build-artifacts web/artifacts.json --source web/
wait_rollout web-app-001 cd-staging SUCCEEDED

echo "== Task 5: promote to production and approve"
if [ -z "$(gcloud deploy rollouts list --delivery-pipeline "$PIPELINE" --release web-app-001 \
      --filter=targetId=cd-production --format='value(name)')" ]; then
  gcloud deploy releases promote --delivery-pipeline "$PIPELINE" --release web-app-001 \
    --to-target cd-production --quiet
fi
wait_rollout web-app-001 cd-production PENDING_APPROVAL || true
ROLLOUT=$(gcloud deploy rollouts list --delivery-pipeline "$PIPELINE" --release web-app-001 \
  --filter=targetId=cd-production --format="value(name.basename())" | head -1)
gcloud deploy rollouts approve "$ROLLOUT" --delivery-pipeline "$PIPELINE" --release web-app-001 --quiet || true
wait_rollout web-app-001 cd-production SUCCEEDED

echo "== Task 6: change the application and release web-app-002"
echo "Make the code change that Task 6 of the lab asks for, in $(pwd)/web."
read -r -p "Press Enter when the change is saved... " _
(cd web && skaffold build --interactive=false \
  --default-repo "$REGION-docker.pkg.dev/$PROJECT_ID/$REPO" --file-output artifacts.json)
gcloud deploy releases describe web-app-002 --delivery-pipeline "$PIPELINE" >/dev/null 2>&1 ||
  gcloud deploy releases create web-app-002 --delivery-pipeline "$PIPELINE" \
    --build-artifacts web/artifacts.json --source web/
wait_rollout web-app-002 cd-staging SUCCEEDED

echo "== Task 7: roll staging back"
gcloud deploy targets rollback cd-staging --delivery-pipeline="$PIPELINE" --quiet
echo "Done. Check each task with 'Check my progress' in the lab."
