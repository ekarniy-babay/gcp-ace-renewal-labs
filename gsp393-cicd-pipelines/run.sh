#!/usr/bin/env bash
# GSP393 - Implement CI/CD Pipelines on Google Cloud: Challenge Lab (lab text of 18.11.2026)
# One command in the lab's Cloud Shell, no manual steps:
#   curl -fsSL https://raw.githubusercontent.com/ekarniy-babay/gcp-ace-renewal-labs/main/gsp393-cicd-pipelines/run.sh | bash
# REGION and ZONE are read from the lab project; pass them only if the script cannot find them:
#   curl -fsSL .../run.sh | REGION=us-central1 ZONE=us-central1-a bash
# Re-running is safe: existing bucket, repository, clusters, targets and releases are reused.
set -euo pipefail
# run via curl | bash reads the script from stdin: no gcloud prompt may read it
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

meta() {  # project metadata key set by the lab
  gcloud compute project-info describe \
    --format="value(commonInstanceMetadata.items[$1])" 2>/dev/null || true
}
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION=${REGION:-$(meta google-compute-default-region)}
REGION=${REGION:-$(gcloud config get-value compute/region 2>/dev/null)}
ZONE=${ZONE:-$(meta google-compute-default-zone)}
ZONE=${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}
[ -n "$REGION" ] || { echo "REGION not found - rerun with REGION=<lab region> ZONE=<lab zone>"; exit 1; }
ZONE=${ZONE:-$(gcloud compute zones list --filter="region:$REGION" --format="value(name)" --sort-by=name --limit=1 2>/dev/null || true)}
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
export PROJECT_ID PROJECT_NUMBER REGION ZONE
PIPELINE=web-app
REPO=cicd-challenge
CLUSTERS=(cd-staging cd-production)
gcloud config set compute/region "$REGION" >/dev/null 2>&1
gcloud config set deploy/region "$REGION" >/dev/null 2>&1
echo "project=$PROJECT_ID region=$REGION zone=$ZONE"

rollout_state() {  # $1 release, $2 target
  gcloud deploy rollouts list --delivery-pipeline "$PIPELINE" --release "$1" \
    --filter="targetId=$2" --sort-by=~createTime --format="value(state)" 2>/dev/null | head -1
}
wait_rollout() {  # $1 release, $2 target, $3 wanted state
  local state
  for _ in $(seq 1 90); do
    state=$(rollout_state "$1" "$2")
    echo "  $1 -> $2: ${state:-not yet}"
    [ "$state" = "$3" ] && return 0
    [ "$state" = "FAILED" ] && { echo "rollout failed"; return 1; }
    sleep 20
  done
  echo "timeout waiting for $1 -> $2 ($3)"; return 1
}
build() {
  (cd web && skaffold build --interactive=false \
    --default-repo "$REGION-docker.pkg.dev/$PROJECT_ID/$REPO" --file-output artifacts.json)
}

echo "== Task 1: APIs, permissions, bucket, repository, clusters"
gcloud services enable container.googleapis.com clouddeploy.googleapis.com \
  artifactregistry.googleapis.com cloudbuild.googleapis.com
# the lab pre-configures these roles; adding them again is harmless and covers a lab that did not
for role in roles/clouddeploy.jobRunner roles/container.developer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="$role" --condition=None >/dev/null 2>&1 || true
done
gcloud storage buckets describe "gs://${PROJECT_ID}_cloudbuild" >/dev/null 2>&1 ||
  gcloud storage buckets create --project="$PROJECT_ID" "gs://${PROJECT_ID}_cloudbuild"
gcloud artifacts repositories describe "$REPO" --location "$REGION" >/dev/null 2>&1 ||
  gcloud artifacts repositories create "$REPO" --description="Image registry for tutorial web app" \
    --repository-format=docker --location="$REGION"
for c in "${CLUSTERS[@]}"; do
  gcloud container clusters describe "$c" --region "$REGION" >/dev/null 2>&1 ||
    gcloud container clusters create "$c" --region "$REGION" --node-locations="$ZONE" \
      --num-nodes=1 --async
done

echo "== Task 2: build the images and push them"
cd ~
[ -d cloud-deploy-tutorials ] || git clone https://github.com/GoogleCloudPlatform/cloud-deploy-tutorials.git
cd cloud-deploy-tutorials
git checkout -- . 2>/dev/null || true
git checkout c3cae80 --quiet
cd tutorials/base
envsubst < clouddeploy-config/skaffold.yaml.template > web/skaffold.yaml
build

echo "== Task 3: delivery pipeline and targets"
sed -e "s/targetId: staging/targetId: cd-staging/" \
    -e "s/targetId: prod/targetId: cd-production/" \
    -e "/targetId: test/d" \
    clouddeploy-config/delivery-pipeline.yaml.template > clouddeploy-config/delivery-pipeline.yaml
gcloud beta deploy apply --file=clouddeploy-config/delivery-pipeline.yaml

for c in "${CLUSTERS[@]}"; do
  until [ "$(gcloud container clusters describe "$c" --region "$REGION" --format='value(status)')" = RUNNING ]; do
    echo "  waiting for cluster $c"; sleep 30
  done
  gcloud container clusters get-credentials "$c" --region "$REGION"
  kubectl config delete-context "$c" >/dev/null 2>&1 || true
  kubectl config rename-context "gke_${PROJECT_ID}_${REGION}_${c}" "$c"
  kubectl --context "$c" apply -f kubernetes-config/web-app-namespace.yaml
done

# exactly as the lab text: the check for Task 3 failed on targets that kept the old "staging cluster" description
envsubst < clouddeploy-config/target-staging.yaml.template > clouddeploy-config/target-cd-staging.yaml
envsubst < clouddeploy-config/target-prod.yaml.template > clouddeploy-config/target-cd-production.yaml
sed -i "s/staging/cd-staging/" clouddeploy-config/target-cd-staging.yaml
sed -i "s/prod/cd-production/" clouddeploy-config/target-cd-production.yaml
for c in "${CLUSTERS[@]}"; do
  gcloud beta deploy apply --file "clouddeploy-config/target-$c.yaml"
done

echo "== Task 4: release web-app-001 to staging"
gcloud deploy releases describe web-app-001 --delivery-pipeline "$PIPELINE" >/dev/null 2>&1 ||
  gcloud beta deploy releases create web-app-001 --delivery-pipeline "$PIPELINE" \
    --build-artifacts web/artifacts.json --source web/
wait_rollout web-app-001 cd-staging SUCCEEDED

echo "== Task 5: promote to production and approve"
[ -n "$(rollout_state web-app-001 cd-production)" ] ||
  gcloud beta deploy releases promote --delivery-pipeline "$PIPELINE" --release web-app-001 \
    --to-target cd-production --quiet
if [ "$(rollout_state web-app-001 cd-production)" != SUCCEEDED ]; then
  wait_rollout web-app-001 cd-production PENDING_APPROVAL
  ROLLOUT=$(gcloud deploy rollouts list --delivery-pipeline "$PIPELINE" --release web-app-001 \
    --filter=targetId=cd-production --format="value(name.basename())" | head -1)
  gcloud beta deploy rollouts approve "$ROLLOUT" --delivery-pipeline "$PIPELINE" \
    --release web-app-001 --quiet
  wait_rollout web-app-001 cd-production SUCCEEDED
fi

echo "== Task 6: change app.go line 24 and release web-app-002"
sed -i 's/leeroooooy app!!/leeroooooy app v2!!/' web/leeroy-app/app.go
sed -n 24p web/leeroy-app/app.go
build
gcloud deploy releases describe web-app-002 --delivery-pipeline "$PIPELINE" >/dev/null 2>&1 ||
  gcloud beta deploy releases create web-app-002 --delivery-pipeline "$PIPELINE" \
    --build-artifacts web/artifacts.json --source web/
wait_rollout web-app-002 cd-staging SUCCEEDED

echo "== Task 7: roll staging back to web-app-001"
gcloud deploy targets rollback cd-staging --delivery-pipeline="$PIPELINE" \
  --release=web-app-001 --quiet
for _ in $(seq 1 45); do
  s=$(gcloud deploy rollouts list --delivery-pipeline "$PIPELINE" --release web-app-001 \
    --filter="targetId=cd-staging" --sort-by=~createTime --format="value(state)" | head -1)
  echo "  rollback web-app-001 -> cd-staging: ${s:-not yet}"
  [ "$s" = SUCCEEDED ] && break
  sleep 20
done
echo "Done. Press 'Check my progress' for every task in the lab."
