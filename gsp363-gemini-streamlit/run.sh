#!/usr/bin/env bash
# GSP517 - Develop GenAI Apps with Gemini and Streamlit: Challenge Lab (lab text of 10.11.2026), Tasks 2-5.
# Task 1 is the Workbench notebook - see README.
# One command in the lab's Cloud Shell; values from the "Lab setup and access" panel:
#   curl -fsSL https://raw.githubusercontent.com/ekarniy-babay/gcp-ace-renewal-labs/main/gsp363-gemini-streamlit/run.sh \
#     | MODEL_ID=<model_id> CHEF_SRC=<chef.py path> bash
# REGION and the bucket are read from the lab project; pass REGION=... BUCKET=... only if the script cannot find them.
set -euo pipefail
# run via curl | bash reads the script from stdin: no gcloud prompt may read it
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

meta() {
  gcloud compute project-info describe \
    --format="value(commonInstanceMetadata.items[$1])" 2>/dev/null || true
}
PROJECT=$(gcloud config get-value project 2>/dev/null)
REGION=${REGION:-$(meta google-compute-default-region)}
REGION=${REGION:-$(gcloud config get-value compute/region 2>/dev/null)}
[ -n "$REGION" ] || { echo "REGION not found - rerun with REGION=<lab region>"; exit 1; }
CHEF_SRC=${CHEF_SRC:-gs://spls/gsp517/chef.py}
BUCKET=${BUCKET:-$(gcloud storage ls --project "$PROJECT" 2>/dev/null | grep -- '-generative-ai/$' | head -1 | sed 's#gs://##; s#/$##')}
BUCKET=${BUCKET:-$PROJECT-generative-ai}
BUCKET=${BUCKET#gs://}; BUCKET=${BUCKET%/}
AR_REPO=chef-repo
SERVICE_NAME=chef-streamlit-app
IMAGE="$REGION-docker.pkg.dev/$PROJECT/$AR_REPO/$SERVICE_NAME"
export PROJECT REGION
echo "project=$PROJECT region=$REGION bucket=$BUCKET chef=$CHEF_SRC model=${MODEL_ID:-<from chef.py>}"

# the lab pre-enables the APIs; the student may not be allowed to enable them (GSP517, 24.11.2026)
gcloud services enable run.googleapis.com aiplatform.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com >/dev/null 2>&1 ||
  echo "  (APIs not enabled by the script - the lab enables them itself)"

echo "== Task 2: complete chef.py and upload it"
cd ~
[ -d generative-ai ] || git clone https://github.com/GoogleCloudPlatform/generative-ai.git
cd generative-ai/gemini/sample-apps/gemini-streamlit-cloudrun
grep -qx 'google-cloud-logging' requirements.txt || echo 'google-cloud-logging' >> requirements.txt
gcloud storage cp "$CHEF_SRC" chef.py
if grep -q 'GEMINI_FLASH_MODEL_ID' chef.py && [ -z "${MODEL_ID:-}" ]; then
  echo "chef.py asks for the model: rerun with MODEL_ID=<model_id from the Lab setup panel>"; exit 1
fi
# an older chef.py imports the Vertex AI SDK, which the sample's requirements do not have
if grep -q '^import vertexai\|^from vertexai' chef.py && ! grep -q 'google-cloud-aiplatform' requirements.txt; then
  echo 'google-cloud-aiplatform==1.71.1' >> requirements.txt
fi
MODEL_ID=${MODEL_ID:-} python3 - chef.py <<'PY'
import os, re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = s.replace("GCP_PROJECT_ID", os.environ["PROJECT"])
if os.environ.get("MODEL_ID"):
    s = s.replace("GEMINI_FLASH_MODEL_ID", os.environ["MODEL_ID"])
if 'key="wine"' not in s:
    wine = ('wine = st.radio(\n'
            '    "What wine do you prefer?\\n\\n", ["Red", "White", "None"], key="wine", horizontal=True\n'
            ')\n')
    anchor = "# https://docs.streamlit.io/library/api-reference/widgets/st.radio\n"
    if s.count(anchor) == 1:
        s = s.replace(anchor, anchor + "\n" + wine)
    else:
        m = re.search(r"^prompt\s*=", s, re.M)
        if not m:
            sys.exit("STOP: no place for the wine radio button in chef.py")
        s = s[:m.start()] + wine + "\n" + s[m.start():]
prompt = '''prompt = f"""I am a Chef.  I need to create {cuisine} \\n
recipes for customers who want {dietary_preference} meals. \\n
However, don't include recipes that use ingredients with the customer's {allergy} allergy. \\n
I have {ingredient_1}, \\n
{ingredient_2}, \\n
and {ingredient_3} \\n
in my kitchen and other ingredients. \\n
The customer's wine preference is {wine} \\n
Please provide some for meal recommendations.
For each recommendation include preparation instructions,
time to prepare
and the recipe title at the beginning of the response.
Then include the wine paring for each recommendation.
At the end of the recommendation provide the calories associated with the meal
and the nutritional facts.
"""'''
m = re.search(r'^prompt\s*=\s*f?(""".*?"""|"[^"\n]*"|\'[^\'\n]*\')', s, re.M | re.S)
if not m:
    sys.exit("STOP: no prompt assignment found in chef.py")
s = s[:m.start()] + prompt + s[m.end():]
open(p, "w", encoding="utf-8").write(s)
left = [x for x in ("GCP_PROJECT_ID", "GEMINI_FLASH_MODEL_ID") if x in s]
print("chef.py: project, model, wine radio, prompt set" + (f" - STILL LEFT: {left}" if left else ""))
PY
python3 -c "import ast,sys; ast.parse(open('chef.py').read())"
gcloud storage cp chef.py "gs://$BUCKET/"

echo "== Task 3: run the app in Cloud Shell (Web Preview, port 8080)"
python3 -m venv ~/gemini-streamlit
# shellcheck disable=SC1090
source ~/gemini-streamlit/bin/activate
python3 -m pip install -q -r requirements.txt
pkill -f "streamlit run chef.py" 2>/dev/null || true
PROJECT=$PROJECT REGION=$REGION GCP_PROJECT=$PROJECT GCP_REGION=$REGION nohup streamlit run chef.py \
  --browser.serverAddress=localhost --server.enableCORS=false \
  --server.enableXsrfProtection=false --server.port 8080 > ~/streamlit.log 2>&1 &
sleep 8
grep -m1 -i 'url\|error' ~/streamlit.log || true

echo "== Task 4: Dockerfile with chef.py, image to Artifact Registry"
sed -i 's/"app\.py"/"chef.py"/' Dockerfile
grep ENTRYPOINT Dockerfile
gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" >/dev/null 2>&1 ||
  gcloud artifacts repositories create "$AR_REPO" --location="$REGION" --repository-format=Docker
gcloud builds submit --tag "$IMAGE"

echo "== Task 5: deploy to Cloud Run"
gcloud run deploy "$SERVICE_NAME" --port=8080 --image="$IMAGE" --allow-unauthenticated \
  --region="$REGION" --platform=managed --project="$PROJECT" \
  --set-env-vars="PROJECT=$PROJECT,REGION=$REGION,GCP_PROJECT=$PROJECT,GCP_REGION=$REGION"
URL=$(gcloud run services describe "$SERVICE_NAME" --region="$REGION" --format='value(status.url)')
echo
echo "Done."
echo "Task 3: Web Preview > Preview on port 8080 > 'Generate my recipes.'"
echo "Task 5: open $URL > 'Generate my recipes.'"
echo "Then press 'Check my progress' for Tasks 2-5."
