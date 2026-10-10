# 3. Deploy a model on a Cloud Run GPU

**Goal:** a real open-source LLM on a GPU in **your** Google Cloud project, private to
you, and the app on your laptop chatting with it.

What you get:

- One **Cloud Run service** running [vLLM](https://docs.vllm.ai) on an **NVIDIA L4
  GPU** (24 GB), with the model you pick. The default, Qwen3-VL 8B, does chat, vision
  and OCR in one model.
- **Private.** Cloud Run refuses every request that doesn't carry a Google ID token
  from an account allowed to call it. There is no API key to leak.
- **Scale to zero.** While nobody chats there is no instance and no GPU bill. The
  first message after a quiet period wakes it in about 1–3 minutes.
- The local app (`make up-cloud`) shows it in the model picker, next to the others.

> **This costs money, but only while the GPU is awake.** Approximate prices
> (us-central1, October 2026; check [cloud.google.com/run/pricing](https://cloud.google.com/run/pricing)):
>
> | What | About |
> |---|---|
> | Model awake, L4 with 8 vCPU + 32 GiB (`qwen3-vl-8b`, `qwen3-8b`, `llama-3.1-8b`) | $1.42 per hour |
> | Model awake, L4 with 4 vCPU + 16 GiB (`qwen3-vl-4b`, `gemma-3-4b`) | $1.05 per hour |
> | Model asleep | $0 |
> | Each wake-up (start-up, plus up to ~15 idle minutes before Cloud Run stops it) | $0.35–0.50 |
> | The model's weights in Cloud Storage (~10 GB) | $0.20 per month |
> | The vLLM image, cached in Artifact Registry (~10 GB) | $1 per month |
> | Copying the model into your project, once (Cloud Build) | $0.10–0.30 |
>
> An evening of testing with the GPU awake for 2 hours is about $3. Set a budget alert
> before you start (below), and clean up at the end with `make model-delete`.

## How a model runs on Cloud Run

```
Cloud Run service "llmchat-qwen3-vl-8b"   the address you call: https://...run.app (private)
  └── revision                            WHAT runs: the vLLM image, its command, GPU, CPU, memory
        └── instances: 0 or 1             the running container on a GPU; billed while it exists
              └── /models (read-only)     the weights, mounted from your Cloud Storage bucket
```

- **Cloud Run** runs containers. It starts an instance when a request arrives and
  stops it after a while without requests. Each instance with a GPU gets exactly one
  GPU. GPU services use *instance-based billing*: you pay for every second an instance
  exists, including the idle minutes before Cloud Run stops it.
- **vLLM** comes as its official image, `vllm/vllm-openai:v0.30.0` from Docker Hub. It
  speaks the OpenAI chat API. **Nothing to build.**
- **The weights** are copied once from Hugging Face into a bucket in your project.
  Every new instance reads them from there.

[`ml/cloudrun/deploy.py`](../ml/cloudrun/deploy.py) does all of this with plain
`gcloud` commands, and prints each one before it runs it. Read it: it's short and
commented. (Guide 4 builds the same thing, plus the rest of the app, with Terraform.)

## Before you start

You need **Docker** running, and that's all: `gcloud` runs from Google's official Docker
image through [`scripts/gcloud.sh`](../scripts/gcloud.sh). Nothing else gets installed
on your computer.

### 1. A Google Cloud project with billing

1. Open [console.cloud.google.com](https://console.cloud.google.com/) and sign in with
   a Google account.
2. Click the **project picker** in the top bar → **New project**. Give it a name. Under
   the name, note the **project ID** (for example `my-llm-chat-123`): lowercase,
   unique across Google Cloud. The tools need the ID, not the name or the number.
3. Link a **billing account** to the project (**Billing → Link a billing account**).
   New accounts get free credit, but GPUs may need a paid account: if the deploy
   says GPUs aren't available on the free trial, upgrade under **Billing → Overview**.
   Your remaining credit stays.

### 2. A budget alert

A GPU you forgot about is the classic surprise bill. **Billing → Budgets & alerts →
Create budget**: this project, a monthly amount (say $50), alerts at 50%, 90% and 100%.
Google emails the billing admins when a threshold is crossed.

A budget **only warns**. It doesn't stop anything, and billing data arrives a few hours
late. Scale to zero is what keeps the bill small; the budget tells you when something
didn't sleep.

### 3. `.env`

```bash
cp .env.example .env      # if you don't have one yet
```

Set these three:

```bash
GCP_PROJECT=my-llm-chat-123   # the project ID
GCP_REGION=us-central1        # a region with Cloud Run L4 GPUs
HF_TOKEN=                     # only for gated models (Llama, Gemma)
```

L4 GPUs are in `us-central1`, `us-east4`, `europe-west1`, `europe-west4` and
`asia-southeast1`. Pick one close to you and stay with it: the weights bucket is
created in the region of your first deploy.

**Gated models** (Llama, Gemma): accept the licence on the model's page on
huggingface.co, create a **read** token at
[huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) and put it in
`HF_TOKEN`. The deploy stores it in Secret Manager (`llmchat-hf-token`), where only the
copy job can read it.

### 4. Log in: `make gcp-login`

```bash
make gcp-login
```

This runs `gcloud auth login --update-adc --no-launch-browser` inside the official
image (`gcr.io/google.com/cloudsdktool/google-cloud-cli:586.0.0-slim`). There is no
browser inside a container, so it's a copy-and-paste login:

1. It prints a long `accounts.google.com` link.
2. Open the link in your browser, sign in with the account that owns the project,
   and allow access.
3. Google shows a code. Copy it, paste it into the terminal, press Enter.

```
Go to the following link in your browser, and complete the sign-in prompts:

    https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=...

Once finished, enter the verification code provided in your browser: 4/0Ab...

Logged in as you@gmail.com, project my-llm-chat-123.
```

What it saved, in `~/.config/gcloud` on your computer:

- **gcloud's own login**, for `gcloud` commands.
- **Application default credentials** ("ADC"), the login that *programs* use:
  Terraform in guide 4, and the local app's api container in this guide.
- Your **default project**, and the ADC **quota project** (some Google APIs need to
  know which project a user's requests count against).

It's the same folder an installed `gcloud` uses, so the two share the login if you
happen to have one. You log in once; it lasts until you revoke it. Any other gcloud
command works the same way: `make gcloud ARGS="run services list"`.

## Pick a model

```bash
make model-presets
```

```
PRESET         GPU                              $/HOUR   MODEL
qwen3-vl-8b    1x NVIDIA L4, 24 GB              1.42     Qwen/Qwen3-VL-8B-Instruct-FP8 (vision)
qwen3-vl-4b    1x NVIDIA L4, 24 GB              1.05     Qwen/Qwen3-VL-4B-Instruct (vision)
qwen3-8b       1x NVIDIA L4, 24 GB              1.42     Qwen/Qwen3-8B-FP8
llama-3.1-8b   1x NVIDIA L4, 24 GB              1.42     meta-llama/Llama-3.1-8B-Instruct (gated: needs HF_TOKEN)
gemma-3-4b     1x NVIDIA L4, 24 GB              1.05     google/gemma-3-4b-it (vision) (gated: needs HF_TOKEN)
qwen3-32b      1x NVIDIA RTX PRO 6000, 96 GB    preview  Qwen/Qwen3-32B-FP8

$/hour = while awake; $0 while asleep. Deploy: make model-deploy PRESET=<preset>
```

Start with **`qwen3-vl-8b`**: chat, vision and OCR in one model. `qwen3-32b` needs the
96 GB RTX PRO 6000, a preview on Cloud Run (see [5. Advanced](05-advanced.md)). The
presets live in [`ml/models/catalog.json`](../ml/models/catalog.json); the details are
in [models.md](models.md).

## Deploy

```bash
make model-deploy PRESET=qwen3-vl-8b
```

The first time takes **about 20–30 minutes**, mostly copying ~10 GB of weights. Later
deploys take about 5 minutes, because the copy is skipped. It starts with:

```
Deploying Qwen3-VL 8B (FP8) (Qwen/Qwen3-VL-8B-Instruct-FP8) to Cloud Run in my-llm-chat-123 / us-central1
GPU: 1x NVIDIA L4, 24 GB, 8 vCPU, 32Gi. About $1.42/hour while awake, $0 while asleep.
```

and then works through six numbered steps. Each prints the `gcloud` commands it runs
(lines starting with `$`). Anything that already exists is skipped ("already there"),
so running it again is safe.

### Look before you leap: `--dry-run`

```bash
./scripts/gcloud.sh --run python3 ml/cloudrun/deploy.py deploy qwen3-vl-8b --dry-run

# or, if you have Python 3 on your computer (no Docker, no login needed):
python3 ml/cloudrun/deploy.py deploy qwen3-vl-8b --dry-run --project my-project
```

This prints every command, and the Cloud Build configuration, without changing
anything. In a dry run nothing is "already there", so you see them all, and your
account shows as `YOU@example.com`. The output below comes from the second command.

### The six steps, and why each one exists

#### 1. Turn on the APIs

```
  $ gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com storage.googleapis.com iam.googleapis.com iamcredentials.googleapis.com secretmanager.googleapis.com --project=my-project --quiet
```

A new project has most Google services switched off. Turning them on is free. Cloud
Run runs the model, Cloud Build copies it, Artifact Registry caches the image, Cloud
Storage holds the weights, IAM and IAM Credentials handle the service accounts and
their tokens, and Secret Manager keeps the Hugging Face token.

#### 2. A cache of Docker Hub in Artifact Registry

```
  $ gcloud artifacts repositories create dockerhub --repository-format=docker --mode=remote-repository --remote-docker-repo=DOCKER-HUB '--remote-repo-config-desc=Docker Hub' '--description=Docker Hub images (vLLM), cached for Cloud Run (private-llm-chat)' --location=us-central1 --project=my-project --quiet
```

A **remote** repository fetches an image from Docker Hub the first time someone asks
for it, then keeps a copy. Cloud Run pulls the ~10 GB vLLM image as
`us-central1-docker.pkg.dev/<project>/dockerhub/vllm/vllm-openai:v0.30.0`, so the image
comes over Google's own network, Docker Hub's download limits only matter once, and the
image keeps working even if Docker Hub removes the tag. The cached copy costs about
$1 a month.

#### 3. A bucket for the weights

```
  $ gcloud storage buckets create gs://my-project-llmchat-models --location=us-central1 --uniform-bucket-level-access --public-access-prevention --project=my-project --quiet
```

In the same region as the GPU: fast, and no transfer fees. Private: no per-object
permissions, and public access is blocked. Bucket names are global, so the name starts
with your project ID.

#### 4. Three service accounts

```
  $ gcloud iam service-accounts create llmchat-model '--display-name=LLM chat: the GPU model service runs as this' --project=my-project --quiet
  $ gcloud iam service-accounts create llmchat-invoker '--display-name=LLM chat: the app calls the model as this' --project=my-project --quiet
  $ gcloud iam service-accounts create llmchat-builder '--display-name=LLM chat: Cloud Build copies model weights as this' --project=my-project --quiet
  $ gcloud storage buckets add-iam-policy-binding gs://my-project-llmchat-models --member=serviceAccount:llmchat-model@my-project.iam.gserviceaccount.com --role=roles/storage.objectViewer ...
  $ gcloud storage buckets add-iam-policy-binding gs://my-project-llmchat-models --member=serviceAccount:llmchat-builder@my-project.iam.gserviceaccount.com --role=roles/storage.objectAdmin ...
  $ gcloud projects add-iam-policy-binding my-project --member=serviceAccount:llmchat-builder@my-project.iam.gserviceaccount.com --role=roles/logging.logWriter --condition=None --quiet
```

| Account | What it's for | What it may do |
|---|---|---|
| `llmchat-model` | The GPU service runs as this | Read the weights bucket |
| `llmchat-invoker` | The identity that calls the model. The local app borrows it | Call this model service (granted after step 6) |
| `llmchat-builder` | Cloud Build runs the copy job as this | Write the weights bucket, write build logs |

Why three: **least privilege**. The model can read the weights but not change them.
The builder can write weights but can't call the model. The invoker can call the model
and do nothing else. No keys are ever created: Google hands each account short-lived
credentials when it needs them. If an IAM change fails because a brand-new account
isn't visible yet, the script waits 10 seconds and retries.

#### 5. Copy the model into the bucket, with Cloud Build

```
5. Copying Qwen/Qwen3-VL-8B-Instruct-FP8 from Hugging Face to gs://my-project-llmchat-models/Qwen/Qwen3-VL-8B-Instruct-FP8 ...
   Cloud Build runs this (as llmchat-builder@my-project.iam.gserviceaccount.com); follow along in the console under Cloud Build -> History.
  $ gcloud builds submit --no-source --config=/tmp/tmpxpf92wqd.json --region=us-central1 --service-account=projects/my-project/serviceAccounts/llmchat-builder@my-project.iam.gserviceaccount.com --project=my-project --quiet
```

A two-step build on a Google machine (`E2_HIGHCPU_8`, 200 GB disk):

1. `python:3.12-slim` installs `huggingface_hub` and downloads the model
   (`snapshot_download`), skipping files vLLM doesn't use (`original/*`, `*.pth`,
   `*.gguf`, `*.onnx`).
2. The gcloud image uploads it with `gcloud storage rsync` to
   `gs://<bucket>/<Hugging Face id>/`, then writes a marker file, `.llmchat-staged`.

Why bother? Cloud Run starts every instance with an empty disk. If vLLM downloaded the
model from Hugging Face at start-up, **every wake-up** would pull ~10 GB from outside
Google. Reading from a bucket in the same region is faster, and it works even when
Hugging Face is down. The copy also runs inside Google's network: your home internet
only uploads a small JSON file. The marker file is written last, so a copy that broke
halfway isn't mistaken for a finished one; with it in place, the next deploy says
"already copied".

For gated models, `HF_TOKEN` goes into Secret Manager first, the builder may read it,
and the build gets it as a secret environment variable. The token never appears in the
build configuration or its logs.

#### 6. The GPU service

The script prints this as one long line. Here it is wrapped for reading:

```bash
gcloud run deploy llmchat-qwen3-vl-8b \
  --image=us-central1-docker.pkg.dev/my-project/dockerhub/vllm/vllm-openai:v0.30.0 \
  --region=us-central1 \
  --command=vllm \
  --args=serve,/models/Qwen/Qwen3-VL-8B-Instruct-FP8,--served-model-name=Qwen/Qwen3-VL-8B-Instruct-FP8,--host=0.0.0.0,--port=8000,--max-model-len=32768 \
  --port=8000 \
  --gpu=1 --gpu-type=nvidia-l4 --no-gpu-zonal-redundancy \
  --cpu=8 --memory=32Gi --no-cpu-throttling \
  --min-instances=0 --max-instances=1 \
  --concurrency=32 --timeout=3600 \
  --no-allow-unauthenticated \
  --service-account=llmchat-model@my-project.iam.gserviceaccount.com \
  --add-volume=name=models,type=cloud-storage,bucket=my-project-llmchat-models,readonly=true \
  --add-volume-mount=volume=models,mount-path=/models \
  --startup-probe=httpGet.path=/health,httpGet.port=8000,initialDelaySeconds=0,periodSeconds=10,timeoutSeconds=5,failureThreshold=90 \
  --set-env-vars=HF_HUB_OFFLINE=1 \
  --labels=app=llmchat,llmchat-preset=qwen3-vl-8b \
  --project=my-project --quiet
```

| Flag | Why |
|---|---|
| `--command=vllm --args=serve,/models/...` | Serve the model from the mounted bucket. `--served-model-name` keeps its Hugging Face name, which is what the app sends as `model` |
| `--max-model-len=32768` | The context window. It decides how much GPU memory vLLM sets aside for the conversation |
| `--gpu=1 --gpu-type=nvidia-l4` | One L4 (24 GB). One GPU per instance is all Cloud Run offers |
| `--no-gpu-zonal-redundancy` | Cheaper, and it's what the automatic GPU quota covers. If the zone has a problem, a new instance may take longer to find a GPU |
| `--cpu=8 --memory=32Gi` | From the preset. An L4 needs at least 4 vCPU and 16 GiB |
| `--no-cpu-throttling` | GPU services must keep their CPU on. That makes it instance-based billing: you pay while the instance exists |
| `--min-instances=0 --max-instances=1` | **Scale to zero**, and never more than one GPU for this model |
| `--concurrency=32` | Up to 32 requests at once on the one instance; vLLM batches them on the GPU |
| `--timeout=3600` | A request may wait for the GPU to wake, then stream for minutes |
| `--no-allow-unauthenticated` | Private: Cloud Run checks the ID token before vLLM sees anything |
| `--service-account=llmchat-model` | The identity that reads the weights |
| `--add-volume`, `--add-volume-mount` | The bucket appears as the folder `/models`, read-only (Cloud Storage FUSE) |
| `--startup-probe=httpGet.path=/health,...` | The instance counts as ready only when vLLM's `/health` answers. Loading takes a while, so Cloud Run waits up to 15 minutes (90 checks, 10 s apart) |
| `--set-env-vars=HF_HUB_OFFLINE=1` | Everything is in the bucket: vLLM must not try to reach Hugging Face |
| `--labels=app=llmchat,...` | So `make model-status` can find it |

To check that a new revision works, Cloud Run starts it once. So the first deploy
wakes the GPU for a few minutes (and bills them), then lets it fall asleep.

#### Then: who may call it

```
   Who may call it: the invoker account (and you may borrow that account) ...
  $ gcloud run services add-iam-policy-binding llmchat-qwen3-vl-8b --region=us-central1 --member=serviceAccount:llmchat-invoker@my-project.iam.gserviceaccount.com --role=roles/run.invoker --project=my-project --quiet
  $ gcloud iam service-accounts add-iam-policy-binding llmchat-invoker@my-project.iam.gserviceaccount.com --member=user:YOU@example.com --role=roles/iam.serviceAccountTokenCreator --project=my-project --quiet
```

1. `llmchat-invoker` may call this service (`roles/run.invoker`).
2. **You** may borrow `llmchat-invoker` (`roles/iam.serviceAccountTokenCreator`): ask
   Google for short-lived tokens in its name. That's how the local app gets in (below).

Finally the script writes **`config/models.cloudrun.json`** (gitignored; the format is in
[`config/models.cloudrun.example.json`](../config/models.cloudrun.example.json)): this
model with `"provider": "cloudrun"` and its URL, plus the mock model.

```
Done: https://llmchat-qwen3-vl-8b-123456789012.us-central1.run.app

It is asleep now (no instance, no GPU bill) and wakes on the first message.
  make model-chat PRESET=qwen3-vl-8b     a test message from here
  make up-cloud                     the local app, with this model (config/models.cloudrun.json)

Cloud Run keeps a woken instance for up to ~15 minutes after the last message
(you pay for that time), then it scales to zero. Remove it: make model-delete PRESET=qwen3-vl-8b
```

## Talk to it from the terminal

```bash
make model-chat PRESET=qwen3-vl-8b
```

This sends "Say hello in three languages." from the gcloud container, with an ID token
of **your own** login (`gcloud auth print-identity-token`; as the project's owner you
may call any service in it), and streams the answer:

```
> Say hello in three languages.
(If the GPU is asleep, the answer starts in 1-3 minutes.)

[first word after 104 s]

Hello! ...

[107 s in total]
```

(The numbers are an example; yours will differ.) The time to the first word is the
**wake-up time**: Cloud Run starts an instance in seconds, then vLLM loads the weights
from the bucket onto the GPU and warms up, which is most of the wait. Run it again
straight away and the first word arrives in about a second: the instance is still awake.

Your own question:

```bash
./scripts/gcloud.sh --run python3 ml/cloudrun/deploy.py chat qwen3-vl-8b "What is the capital of Peru?"
```

The request is a plain OpenAI chat completion (`POST /v1/chat/completions` with
`"stream": true`), exactly what the app sends.

## Use it from the app: `make up-cloud`

```bash
make up-cloud
# = docker compose -f docker-compose.yml -f docker-compose.cloudrun.yml up -d --build
```

The same local app as `make up`, but the api loads `config/models.cloudrun.json`. Open
http://localhost:3000: the picker shows **Qwen3-VL 8B (FP8) (Cloud Run)** and the mock
model. `GCP_PROJECT` must be set in `.env`.

**How the local api gets past "private".** Every request to the model needs a Google ID
token made for the model's URL. Your own login can't create tokens for any address you
like; a service account can. So
[`docker-compose.cloudrun.yml`](../docker-compose.cloudrun.yml):

- mounts your `~/.config/gcloud` into the api container, read-only, and
- sets `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=llmchat-invoker@<GCP_PROJECT>.iam.gserviceaccount.com`.

With your login, the api asks Google's IAM Credentials API for an ID token **as
`llmchat-invoker`**, with the model's URL as the audience
([`backend/apps/llm/providers/google_auth.py`](../backend/apps/llm/providers/google_auth.py)).
Google allows it because the deploy gave you Token Creator on that account. Cloud Run
accepts the token because `llmchat-invoker` has `run.invoker` on the service. A token
lasts an hour; the api caches it until 5 minutes before it expires.

```
browser -> localhost:3000 (web) -> api container --ID token of llmchat-invoker--> https://llmchat-qwen3-vl-8b-....run.app -> vLLM on the L4
```

Back to the models on your laptop: `make up`.

## Scale to zero, as you see it in the app

- The **model picker** shows each model's state: Ready, Asleep, Starting or Unavailable.
- A sleeping model gets a banner: **"This model's GPU is asleep."** with
  "Asleep to save money. Your first message wakes it up (about 2 minutes)." and a
  **Start it** button (`POST /api/models/<id>/wake/`).
- **Send a message while it sleeps**, and the api starts a wake-up in the background:
  one `GET /health` request with a long timeout. That request is what makes Cloud Run
  start an instance. The api answers `503 model_starting`, so nothing is saved and
  your message stays in the box. The banner switches to **"This model's GPU is
  starting."** and the page checks again every 15 seconds.
- When the model answers, you get **"... is ready — press Send again."** The app never
  re-sends on its own.
- After your last message, Cloud Run keeps the instance for up to ~15 minutes (you pay
  for them), then stops it. The app assumes a model is awake for 10 minutes after it
  last heard from it, then shows it as Asleep. If the instance is in fact still up, the
  next message simply goes straight through.
- In the admin (http://localhost:3000/admin/ → **LLM models**) every Cloud Run model
  shows when it was last used, when a wake was requested, when it last answered, and
  the last error. Two actions: **Check now** and **Wake up now**.
- In the console: **Cloud Run → llmchat-qwen3-vl-8b → Metrics → Instance count** goes
  0 → 1 → 0.

The "about 2 minutes" comes from `MODEL_WAKE_SECONDS` (default 120) in the backend
settings.

## What's deployed: `make model-status`

```bash
make model-status
```

```
SERVICE                      GPU                    READY  URL
llmchat-qwen3-vl-8b          nvidia-l4              True   https://llmchat-qwen3-vl-8b-123456789012.us-central1.run.app

An instance only runs (and costs money) after a message, for up to ~15 idle minutes.
See instances and cost: console.cloud.google.com/run (Metrics: 'Instance count').
```

`READY` means the service is deployed and healthy, **not** that a GPU is running right
now. It lists the services labelled `app=llmchat` in `GCP_REGION`. The full stack from
guide 4 uses the same label, so its services show up too if both live in one project.

## Stop paying: `make model-delete`

A sleeping model already costs nothing for the GPU. Deleting is about tidiness and the
small storage costs:

```bash
make model-delete PRESET=qwen3-vl-8b             # delete the service, keep the copied weights
make model-delete PRESET=qwen3-vl-8b WEIGHTS=1   # ... and delete the weights from the bucket
```

Kept weights cost about $0.02 per GB per month (about $0.20 for this model), and a later
`make model-deploy` skips the copy. Either way the model is also removed from
`config/models.cloudrun.json`.

Still there afterwards, for pennies up to about $1 a month: the `dockerhub` cache, the
bucket, the three service accounts and, if you used a gated model, the
`llmchat-hf-token` secret. To leave nothing behind:

```bash
make gcloud ARGS="artifacts repositories delete dockerhub --location=us-central1"
make gcloud ARGS="storage rm --recursive gs://my-llm-chat-123-llmchat-models"
```

Or delete the whole project: **IAM & Admin → Settings → Shut down**. That stops all
billing for it.

## Switching and adding models

- **Another preset:** `make model-deploy PRESET=qwen3-8b`. It becomes a second service,
  `llmchat-qwen3-8b`, using the same bucket and accounts. Each model sleeps on its own,
  and you pay only for the ones that are awake. Your first model stays the default.
- **Reload the app's list.** The api reads `config/models.cloudrun.json` when it starts.
  If `make up-cloud` is already running: `docker compose exec api python manage.py sync_models`.
- **Gated models** need `HF_TOKEN` in `.env` (see "Before you start").
- **How many at once:** a project gets 3 GPUs of quota per region with its first GPU
  deploy, so up to 3 models can be awake at the same time. More needs a quota request.
- **A model that isn't a preset:** copy an entry in
  [`ml/models/catalog.json`](../ml/models/catalog.json) and change `hf_model_id`,
  `gpu_type`, `cpu`, `memory`, `max_model_len` and the rest. The full stack and the
  website's model table read the same file. In guide 4 you can also describe a model
  directly in `terraform.tfvars`. Will it fit? See [models.md](models.md).
- **Changed a preset** (say, a smaller `max_model_len`)? Run `make model-deploy` again:
  Cloud Run rolls out a new revision.

## When it goes wrong

| Symptom | Cause and fix |
|---|---|
| `Docker is not running` | Start Docker Desktop |
| `set GCP_PROJECT in .env first` | Put the project **ID** in `.env`, then `make gcp-login` |
| `requires a quota project`, or other login errors | Run `make gcp-login` again: it sets the ADC quota project |
| Step 1 fails: billing not enabled | Link a billing account to the project (Before you start, step 1) |
| Step 6 fails with a quota or "GPU not available" error | The region has no L4 for Cloud Run, or no GPU quota is left. Check `GCP_REGION` against the list above; see **IAM & Admin → Quotas** (search for L4) and request more. On the free trial, upgrade the billing account |
| Step 5 fails with `401`, `403` or "gated repo" | Accept the licence on the model's Hugging Face page, put a **read** token in `HF_TOKEN`, deploy again |
| Step 6: "failed the configured startup probe checks" | vLLM didn't come up within 15 minutes. Read why: **Cloud Run → the service → Logs**. `CUDA out of memory` means the model or `max_model_len` is too big for the GPU. A "no such file" error under `/models` means the weights are missing: copy them again with `./scripts/gcloud.sh --run python3 ml/cloudrun/deploy.py stage qwen3-vl-8b --force` |
| `make model-chat` gets HTTP 403 | Your account may not call the service. Project owners and editors can; otherwise grant yourself `roles/run.invoker` on it |
| The app: `Permission denied ... iam.serviceAccounts.getAccessToken` | The Token Creator grant takes a few minutes to apply after the first deploy. Or you're logged in with another account than the one that deployed |
| The app: "Could not get a Google ID token to call the model service" | You started it with `make up` instead of `make up-cloud`, or `GCP_PROJECT` is missing from `.env` |
| Linux: the api can't read `application_default_credentials.json` | The api container runs as user 10001 and the file is readable only by you (mode 600). `chmod 644 ~/.config/gcloud/application_default_credentials.json` (other users of your computer could then read it), or run the api with your own user id |
| The model shows "Unavailable" | The last wake-up failed; the banner shows the error. Check the service's logs, as above |

More in [troubleshooting.md](troubleshooting.md).

## Next

[4. Deploy the whole app on Google Cloud →](04-deploy-the-full-stack-on-google-cloud.md)
