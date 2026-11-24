# Google Cloud ACE renewal - challenge lab scripts

Scripts for two skill badge challenge labs on the Associate Cloud Engineer renewal path
(Google Skills for Partners, path 4177):

| Folder | Lab | Skill badge |
|---|---|---|
| `gsp393-cicd-pipelines` | GSP393 Implement CI/CD Pipelines on Google Cloud: Challenge Lab | Implement CI/CD Pipelines on Google Cloud |
| `gsp363-gemini-streamlit` | GSP363 Develop GenAI Apps with Gemini and Streamlit: Challenge Lab | Develop Gen AI Apps with Gemini and Streamlit |

Start the badge from the renewal path page, so it counts toward the renewal. Take the region and zone from the
lab instructions: they differ between lab runs. Each lab ends with its own "Check my progress" buttons; press them.

In the lab's Cloud Shell:

```bash
git clone https://github.com/ekarniy-babay/gcp-ace-renewal-labs.git
cd gcp-ace-renewal-labs
```

## GSP393 - CI/CD pipelines

```bash
REGION=<lab region> ZONE=<lab zone> bash gsp393-cicd-pipelines/run.sh
```

Tasks 1-7 in order: APIs, IAM roles, Artifact Registry `cicd-challenge`, clusters `cd-staging` and `cd-production`,
skaffold build, Cloud Deploy pipeline `web-app` with targets, release `web-app-001` to staging, promote and approve to
production, release `web-app-002`, rollback of staging. The script waits for the clusters and each rollout.

At Task 6 it stops and asks you to make the code change the lab describes in `web/`, then press Enter.

Fixed compared to the common online write-ups: no hard-coded project, `ZONE` is required, the `cloud deploy-config` typo
in the `sed` for the production target, and the target files (the tutorial ships `target-staging` and `target-prod`
templates; the lab wants `cd-staging` and `cd-production`).

## GSP363 - Gemini and Streamlit

### Task 1 - notebook (Vertex AI Workbench)

Open the notebook the lab gives you and fill in the cells:

```python
# Task 1.3
PROJECT_ID = !gcloud config get project
PROJECT_ID = PROJECT_ID[0]
LOCATION = "<lab region>"

import os
os.environ["PROJECT_ID"] = PROJECT_ID
os.environ["LOCATION"] = LOCATION
os.environ["API_ENDPOINT"] = f"{LOCATION}-aiplatform.googleapis.com"
```

```bash
%%bash
# Task 1.4 - put the prompt from the lab guide into "text"
MODEL_ID="gemini-2.0-flash-001"
curl -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  "https://${API_ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${MODEL_ID}:streamGenerateContent" \
  -d '{"contents": {"role": "USER", "parts": {"text": "<prompt from the lab guide>"}}}'
```

### Tasks 2 and 3 - Cloud Shell

```bash
REGION=<lab region> bash gsp363-gemini-streamlit/run.sh
```

The script takes the lab's own `chef.py` from `gs://spls/gsp517/chef.py`, adds the wine radio button (Task 2.5) and the
chef prompt (Task 2.6) with `patch_chef.py`, uploads it to the lab bucket, starts the app on port 8080 (Web Preview),
then builds the image and deploys it to Cloud Run.

Default names: bucket `<project>-generative-ai`, repository `chef-repo`, service `chef-streamlit-app`. If the lab text
names them differently, pass them in: `BUCKET=... AR_REPO=... SERVICE_NAME=... REGION=... bash gsp363-gemini-streamlit/run.sh`.

## Status

Shell syntax checked; `patch_chef.py` tested on the current lab `chef.py`; `requirements.txt` imports checked on
Python 3.12 and 3.13. The scripts have not yet been run end to end in a live lab.
