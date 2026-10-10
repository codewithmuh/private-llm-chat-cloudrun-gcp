#!/usr/bin/env python3
"""Deploy an open-source LLM to your own Cloud Run GPU: one private service.

    make model-presets                     the ready-made models (ml/models/catalog.json)
    make model-deploy PRESET=qwen3-vl-8b   first time ~20-30 min (copies the model), later ~5 min
    make model-chat   PRESET=qwen3-vl-8b   one test message (wakes the GPU if it is asleep)
    make model-status                      what is deployed
    make model-delete PRESET=qwen3-vl-8b   remove the service (WEIGHTS=1: the copied model too)

The make targets run this file INSIDE Google's gcloud Docker image
(scripts/gcloud.sh), so there is nothing to install. Directly:

    ./scripts/gcloud.sh --run python3 ml/cloudrun/deploy.py deploy qwen3-vl-8b --dry-run

This script is the "learn how it works" path. It does by hand, with plain
gcloud commands, what the Terraform in infra/terraform does for the full
application. --dry-run prints every command without running it. In order:

    1. APIs               turn on Cloud Run, Cloud Build, Artifact Registry, ...
    2. Artifact Registry  "dockerhub": a cache of Docker Hub inside your project.
                          Cloud Run pulls the ~10 GB vLLM image through it, from
                          Google's own network (and only once from Docker Hub).
    3. Cloud Storage      a bucket for model weights.
    4. Service accounts   llmchat-model    what the GPU service runs as (reads the bucket)
                          llmchat-invoker  who may call it (your local app borrows it)
                          llmchat-builder  what Cloud Build runs as (writes the bucket)
    5. Cloud Build        copies the model from Hugging Face into that bucket,
                          once, inside Google's network (not over your internet).
    6. Cloud Run service  vLLM on one GPU, private (a Google ID token is required),
                          0 to 1 instances: it sleeps when nobody chats and costs
                          nothing then; the next message wakes it in 1-3 minutes.

Configuration: GCP_PROJECT and GCP_REGION (from .env), HF_TOKEN for gated
models (Llama, Gemma). Uses only the Python standard library and gcloud.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "ml" / "models" / "catalog.json"
APP_CONFIG = ROOT / "config" / "models.cloudrun.json"

# vLLM's own image (it serves an OpenAI-compatible API). Pinned: a new vLLM
# release can change flags. Pulled through the "dockerhub" cache repository.
VLLM_IMAGE = "vllm/vllm-openai:v0.30.0"
# For the Cloud Build step that uploads the weights (the same image scripts/gcloud.sh uses).
GCLOUD_IMAGE = "gcr.io/google.com/cloudsdktool/google-cloud-cli:586.0.0-slim"
HF_HUB_VERSION = "1.33.0"

PREFIX = "llmchat"
MODEL_SA = f"{PREFIX}-model"  # the GPU service runs as this
INVOKER_SA = f"{PREFIX}-invoker"  # the app calls the GPU service as this
BUILDER_SA = f"{PREFIX}-builder"  # Cloud Build copies the weights as this
HF_SECRET = f"{PREFIX}-hf-token"
REGISTRY = "dockerhub"
MOUNT = "/models"
STAGED_MARKER = ".llmchat-staged"  # written after a complete copy

APIS = [
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",  # minting ID tokens for the invoker account
    "secretmanager.googleapis.com",  # the Hugging Face token, for gated models
]

DRY_RUN = False


def say(message: str = "") -> None:
    print(message, flush=True)


def die(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------- gcloud ----


def gcloud(*args: str, check: bool = True, capture: bool = False, quiet_fail: bool = False) -> subprocess.CompletedProcess:
    """Run one gcloud command, and show it, so you can learn (or copy) it."""
    cmd = ["gcloud", *args, "--quiet"]
    if not capture or DRY_RUN:
        say("  $ " + shlex.join(cmd))
    if DRY_RUN:
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
    result = subprocess.run(cmd, text=True, capture_output=capture or quiet_fail)
    if check and result.returncode != 0:
        if capture or quiet_fail:
            sys.stderr.write(result.stderr)
        die(f"this command failed: {shlex.join(cmd)}")
    return result


def exists(*args: str) -> bool:
    """True if a gcloud describe/list command finds the thing (dry run: pretend it doesn't)."""
    if DRY_RUN:
        return False
    return subprocess.run(["gcloud", *args, "--quiet"], capture_output=True, text=True).returncode == 0


def value(*args: str) -> str:
    if DRY_RUN:
        return ""
    result = subprocess.run(["gcloud", *args, "--quiet"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def with_retries(*args: str, attempts: int = 6) -> None:
    """A brand-new service account takes a few seconds to be usable in IAM bindings."""
    for attempt in range(1, attempts + 1):
        result = gcloud(*args, check=False, quiet_fail=True)
        if result.returncode == 0:
            return
        if attempt == attempts:
            sys.stderr.write(result.stderr)
            die("an IAM binding kept failing (see above).")
        say("    (not ready yet, retrying in 10 s)")
        time.sleep(10)


class Target:
    """Where things go: project, region, and the names derived from them."""

    def __init__(self, project: str, region: str):
        self.project = project
        self.region = region

    @property
    def bucket(self) -> str:
        # Bucket names are global; a project id is unique, so this is too.
        return f"{self.project}-{PREFIX}-models"

    def sa(self, name: str) -> str:
        return f"{name}@{self.project}.iam.gserviceaccount.com"

    @property
    def image(self) -> str:
        return f"{self.region}-docker.pkg.dev/{self.project}/{REGISTRY}/{VLLM_IMAGE}"

    def flags(self) -> list[str]:
        return [f"--project={self.project}"]


def target_from(args) -> Target:
    project = args.project or os.environ.get("GCP_PROJECT") or value("config", "get-value", "project")
    if not project:
        die("no Google Cloud project. Set GCP_PROJECT in .env (the project ID, e.g. my-llm-chat-123).")
    return Target(project, args.region or os.environ.get("GCP_REGION") or "us-central1")


# ------------------------------------------------------------ the presets ----


def load_presets() -> dict:
    return json.loads(CATALOG.read_text())["presets"]


def preset_or_die(name: str) -> dict:
    presets = load_presets()
    if name not in presets:
        die(f"unknown preset {name!r}. Choose one of: {', '.join(presets)}")
    return presets[name]


def service_name(preset: str) -> str:
    # Cloud Run names: lowercase letters, digits and dashes (llama-3.1-8b -> llama-3-1-8b).
    return f"{PREFIX}-{preset}".replace(".", "-").replace("_", "-")


# ------------------------------------------------------- steps 1 to 4 -------


def enable_apis(t: Target) -> None:
    say("\n1. Turning on the Google Cloud APIs this needs (a minute the first time) ...")
    gcloud("services", "enable", *APIS, *t.flags())


def ensure_registry(t: Target) -> None:
    say(f"\n2. Artifact Registry: the {REGISTRY!r} cache of Docker Hub ...")
    if exists("artifacts", "repositories", "describe", REGISTRY, f"--location={t.region}", *t.flags()):
        say("   already there.")
        return
    gcloud(
        "artifacts", "repositories", "create", REGISTRY,
        "--repository-format=docker",
        "--mode=remote-repository",
        "--remote-docker-repo=DOCKER-HUB",
        "--remote-repo-config-desc=Docker Hub",
        "--description=Docker Hub images (vLLM), cached for Cloud Run (private-llm-chat)",
        f"--location={t.region}",
        *t.flags(),
    )  # fmt: skip


def ensure_bucket(t: Target) -> None:
    say(f"\n3. Cloud Storage: the bucket gs://{t.bucket} for model weights ...")
    if exists("storage", "buckets", "describe", f"gs://{t.bucket}", *t.flags()):
        say("   already there.")
        return
    gcloud(
        "storage", "buckets", "create", f"gs://{t.bucket}",
        f"--location={t.region}",  # same region as the GPU: fast, and no transfer fees
        "--uniform-bucket-level-access",
        "--public-access-prevention",
        *t.flags(),
    )  # fmt: skip


def ensure_service_account(t: Target, name: str, description: str) -> str:
    email = t.sa(name)
    if not exists("iam", "service-accounts", "describe", email, *t.flags()):
        gcloud("iam", "service-accounts", "create", name, f"--display-name={description}", *t.flags())
    return email


def ensure_identities(t: Target) -> tuple[str, str, str]:
    say("\n4. Service accounts: who runs, calls and builds the model ...")
    model = ensure_service_account(t, MODEL_SA, "LLM chat: the GPU model service runs as this")
    invoker = ensure_service_account(t, INVOKER_SA, "LLM chat: the app calls the model as this")
    builder = ensure_service_account(t, BUILDER_SA, "LLM chat: Cloud Build copies model weights as this")
    # The model service only READS the weights; Cloud Build WRITES them.
    with_retries("storage", "buckets", "add-iam-policy-binding", f"gs://{t.bucket}",
                 f"--member=serviceAccount:{model}", "--role=roles/storage.objectViewer", *t.flags())  # fmt: skip
    with_retries("storage", "buckets", "add-iam-policy-binding", f"gs://{t.bucket}",
                 f"--member=serviceAccount:{builder}", "--role=roles/storage.objectAdmin", *t.flags())  # fmt: skip
    with_retries("projects", "add-iam-policy-binding", t.project, f"--member=serviceAccount:{builder}",
                 "--role=roles/logging.logWriter", "--condition=None")  # fmt: skip
    return model, invoker, builder


# ------------------------------------------- step 5: copy the model weights ----


def weights_uri(t: Target, hf_model_id: str, bucket: str | None = None) -> str:
    return f"gs://{bucket or t.bucket}/{hf_model_id}"


def weights_staged(t: Target, hf_model_id: str, bucket: str | None = None) -> bool:
    return exists("storage", "objects", "describe", f"{weights_uri(t, hf_model_id, bucket)}/{STAGED_MARKER}", *t.flags())


def ensure_hf_secret(t: Target, builder: str) -> None:
    """Gated models (Llama, Gemma) need your Hugging Face token. It goes into
    Secret Manager, so it never appears in a build's configuration or logs."""
    token = os.environ.get("HF_TOKEN", "")
    stored = exists("secrets", "describe", HF_SECRET, *t.flags())
    if not token and not stored and not DRY_RUN:
        die(
            "this model is gated: accept its licence on huggingface.co, create a READ token "
            "(huggingface.co/settings/tokens) and put it in .env as HF_TOKEN=hf_..."
        )
    if not stored:
        gcloud("secrets", "create", HF_SECRET, "--replication-policy=automatic", *t.flags())
    if token or DRY_RUN:
        say(f"  $ gcloud secrets versions add {HF_SECRET} --data-file=- (your HF_TOKEN, from stdin)")
    if token and not DRY_RUN:
        subprocess.run(
            ["gcloud", "secrets", "versions", "add", HF_SECRET, "--data-file=-", *t.flags(), "--quiet"],
            input=token, text=True, check=True, capture_output=True,
        )  # fmt: skip
    elif not token:
        say(f"   No HF_TOKEN set: using the token already stored in {HF_SECRET}.")
    with_retries("secrets", "add-iam-policy-binding", HF_SECRET, f"--member=serviceAccount:{builder}",
                 "--role=roles/secretmanager.secretAccessor", *t.flags())  # fmt: skip


def stage_weights(t: Target, p: dict, builder: str, bucket: str | None = None, force: bool = False) -> None:
    """Copy the model from Hugging Face to Cloud Storage with Cloud Build.

    Why not let vLLM download from Hugging Face at startup? Cloud Run starts a
    fresh instance every time the GPU wakes up, with an empty disk: it would
    download ~10 GB again each time, from a site outside Google. Reading from
    a bucket in the same region is faster and doesn't depend on Hugging Face
    being up. (Google's GPU best practices recommend the same.)
    """
    hf_id = p["hf_model_id"]
    dest = weights_uri(t, hf_id, bucket)
    say(f"\n5. Copying {hf_id} from Hugging Face to {dest} ...")
    if not force and weights_staged(t, hf_id, bucket):
        say("   already copied.")
        return
    if p.get("gated"):
        ensure_hf_secret(t, builder)

    download = (
        "set -euo pipefail\n"
        f"pip install --quiet --root-user-action=ignore huggingface_hub=={HF_HUB_VERSION}\n"
        "python - <<'EOF'\n"
        "import os\n"
        "from huggingface_hub import snapshot_download\n"
        "token = os.environ.get('HF_TOKEN') or None\n"
        "path = snapshot_download(os.environ['MODEL'], local_dir='/workspace/model', token=token,\n"
        "                         ignore_patterns=['original/*', '*.pth', '*.gguf', '*.onnx'])\n"
        "print('Downloaded to', path)\n"
        "EOF\n"
    )
    build = {
        "steps": [
            {
                "id": "download-from-hugging-face",
                "name": "python:3.12-slim",
                "entrypoint": "bash",
                "args": ["-c", download.replace("$", "$$")],  # $$ = a literal $ for Cloud Build
                "env": [f"MODEL={hf_id}"],
                **({"secretEnv": ["HF_TOKEN"]} if p.get("gated") else {}),
            },
            {
                "id": "upload-to-cloud-storage",
                "name": GCLOUD_IMAGE,
                "entrypoint": "bash",
                "args": [
                    "-c",
                    f"gcloud storage rsync --recursive /workspace/model {dest} && "
                    f"date -u > /workspace/{STAGED_MARKER} && "
                    f"gcloud storage cp /workspace/{STAGED_MARKER} {dest}/{STAGED_MARKER}",
                ],
            },
        ],
        "timeout": "5400s",
        # More vCPUs = more network bandwidth for the download. Logs go to Cloud
        # Logging only, which a build running as its own service account needs.
        "options": {"machineType": "E2_HIGHCPU_8", "diskSizeGb": 200, "logging": "CLOUD_LOGGING_ONLY"},
    }
    if p.get("gated"):
        build["availableSecrets"] = {
            "secretManager": [{"versionName": f"projects/{t.project}/secrets/{HF_SECRET}/versions/latest", "env": "HF_TOKEN"}]
        }

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(build, f, indent=2)
    if DRY_RUN:
        say(f"   The build configuration ({f.name}):\n{json.dumps(build, indent=2)}")
    say(f"   Cloud Build runs this (as {builder}); follow along in the console under Cloud Build -> History.")
    gcloud(
        "builds", "submit", "--no-source", f"--config={f.name}",
        f"--region={t.region}",
        f"--service-account=projects/{t.project}/serviceAccounts/{builder}",
        *t.flags(),
    )  # fmt: skip


# --------------------------------------------- step 6: the GPU service ------


def vllm_args(p: dict) -> list[str]:
    """The `vllm serve` command line. The model is read from the mounted bucket,
    but the API calls it by its Hugging Face name (served-model-name)."""
    hf_id = p["hf_model_id"]
    return [
        "serve",
        f"{MOUNT}/{hf_id}",
        f"--served-model-name={hf_id}",
        "--host=0.0.0.0",
        "--port=8000",
        f"--max-model-len={p['max_model_len']}",
        *p.get("vllm_args", []),
    ]


def deploy_service(t: Target, name: str, p: dict, model_sa: str, preset: str) -> None:
    say(f"\n6. Cloud Run: the GPU service {name} ({p['gpu']}) ...")
    say("   Cloud Run starts it once to check it works (a few minutes: it loads the model), then lets it sleep.")
    gcloud(
        "run", "deploy", name,
        f"--image={t.image}",
        f"--region={t.region}",
        "--command=vllm",
        "--args=" + ",".join(vllm_args(p)),
        "--port=8000",
        # The GPU. Without zonal redundancy: cheaper, and the default quota.
        "--gpu=1",
        f"--gpu-type={p['gpu_type']}",
        "--no-gpu-zonal-redundancy",
        f"--cpu={p['cpu']}",
        f"--memory={p['memory']}",
        "--no-cpu-throttling",  # GPUs need the CPU always on (instance-based billing)
        # Scale to zero: no instance (and no bill) while nobody chats.
        "--min-instances=0",
        "--max-instances=1",
        "--concurrency=32",  # vLLM batches parallel requests on the one GPU
        "--timeout=3600",  # a request may wait for the GPU to wake, then stream for minutes
        # Private: Cloud Run checks a Google ID token before vLLM sees anything.
        "--no-allow-unauthenticated",
        f"--service-account={model_sa}",
        # The weights, read straight from the bucket (Cloud Storage FUSE).
        f"--add-volume=name=models,type=cloud-storage,bucket={t.bucket},readonly=true",
        f"--add-volume-mount=volume=models,mount-path={MOUNT}",
        # Ready only when vLLM's /health answers: loading the model takes a while.
        "--startup-probe=httpGet.path=/health,httpGet.port=8000,"
        "initialDelaySeconds=0,periodSeconds=10,timeoutSeconds=5,failureThreshold=90",
        "--set-env-vars=HF_HUB_OFFLINE=1",  # everything it needs is in the bucket
        f"--labels=app={PREFIX},{PREFIX}-preset={preset.replace('.', '-')}",
        *t.flags(),
    )  # fmt: skip


def grant_invoker(t: Target, name: str, invoker: str) -> None:
    say("\n   Who may call it: the invoker account (and you may borrow that account) ...")
    with_retries("run", "services", "add-iam-policy-binding", name, f"--region={t.region}",
                 f"--member=serviceAccount:{invoker}", "--role=roles/run.invoker", *t.flags())  # fmt: skip
    account = value("config", "get-value", "account") or "YOU@example.com"
    kind = "serviceAccount" if account.endswith(".gserviceaccount.com") else "user"
    with_retries("iam", "service-accounts", "add-iam-policy-binding", invoker, f"--member={kind}:{account}",
                 "--role=roles/iam.serviceAccountTokenCreator", *t.flags())  # fmt: skip


def service_url(t: Target, name: str) -> str:
    url = value("run", "services", "describe", name, f"--region={t.region}", "--format=value(status.url)", *t.flags())
    return url or f"https://{name}-PROJECT_NUMBER.{t.region}.run.app"


def write_app_config(t: Target, preset: str, p: dict, url: str) -> None:
    """Add the model to config/models.cloudrun.json, which `make up-cloud` loads."""
    entry = {
        "id": preset,
        "name": f"{p['name']} (Cloud Run)",
        "description": p["description"],
        "provider": "cloudrun",
        "base_url": f"{url}/v1",
        "model_id": p["hf_model_id"],
        "vision": p["vision"],
        "ocr": p["ocr"],
        "context_window": p["max_model_len"],
        "max_output_tokens": 4096,
        "temperature": p["temperature"],
        "params": p["params"],
        "hourly_cost_usd": p["hourly_usd"],
        "sort": 10,
    }
    entries = []
    if APP_CONFIG.exists():
        entries = [e for e in json.loads(APP_CONFIG.read_text()) if e.get("id") != preset]
    else:
        entries = [
            {
                "id": "mock",
                "name": "Mock model",
                "description": "Fake answers, for testing the app itself.",
                "provider": "openai",
                "base_url": "http://mock-llm:8080/v1",
                "model_id": "mock-chat",
                "vision": True,
                "context_window": 32768,
                "sort": 90,
            }
        ]
    if not any(e.get("default") for e in entries):
        entry["default"] = True
    entries.insert(0, entry)
    if DRY_RUN:
        say(f"\nWould add to {APP_CONFIG.relative_to(ROOT)}:\n{json.dumps(entry, indent=2)}")
        return
    APP_CONFIG.write_text(json.dumps(entries, indent=2) + "\n")
    say(f"\nAdded {preset!r} to {APP_CONFIG.relative_to(ROOT)}.")


# ------------------------------------------------------------- commands ----


def deploy(args) -> None:
    p = preset_or_die(args.preset)
    t = target_from(args)
    name = service_name(args.preset)
    say(f"Deploying {p['name']} ({p['hf_model_id']}) to Cloud Run in {t.project} / {t.region}")
    say(f"GPU: {p['gpu']}, {p['cpu']} vCPU, {p['memory']}. " + cost_line(p))
    enable_apis(t)
    ensure_registry(t)
    ensure_bucket(t)
    model_sa, invoker, builder = ensure_identities(t)
    stage_weights(t, p, builder)
    deploy_service(t, name, p, model_sa, args.preset)
    grant_invoker(t, name, invoker)
    url = service_url(t, name)
    write_app_config(t, args.preset, p, url)
    say(f"""
Done: {url}

It is asleep now (no instance, no GPU bill) and wakes on the first message.
  make model-chat PRESET={args.preset}     a test message from here
  make up-cloud                     the local app, with this model (config/models.cloudrun.json)

Cloud Run keeps a woken instance for up to ~15 minutes after the last message
(you pay for that time), then it scales to zero. Remove it: make model-delete PRESET={args.preset}""")


def stage(args) -> None:
    """Only copy the weights (scripts/deploy.sh uses this for the full stack).
    MODEL is a preset, or a Hugging Face id (org/name) for a model outside the catalog."""
    if "/" in args.model:
        p = {"hf_model_id": args.model, "gated": args.gated}
    else:
        p = preset_or_die(args.model)
    t = target_from(args)
    builder = args.service_account
    if not builder:
        enable_apis(t)
        ensure_bucket(t)
        _, _, builder = ensure_identities(t)
    stage_weights(t, p, builder, bucket=args.bucket, force=args.force)


def cost_line(p: dict) -> str:
    if p.get("hourly_usd") is None:
        return "Price: see cloud.google.com/run/pricing (preview GPU)."
    return f"About ${p['hourly_usd']:.2f}/hour while awake, $0 while asleep."


def chat(args) -> None:
    t = target_from(args)
    name = service_name(args.preset)
    url = service_url(t, name)
    if "PROJECT_NUMBER" in url:
        die(f"no service {name} in {t.project}/{t.region}. Deploy it first: make model-deploy PRESET={args.preset}")
    p = preset_or_die(args.preset)
    # Your own login, as an ID token. Project owners/editors may invoke any service.
    token = value("auth", "print-identity-token")
    if not token:
        die("could not get an ID token. Log in first: make gcp-login")
    body = {
        "model": p["hf_model_id"],
        "messages": [{"role": "user", "content": args.message}],
        "max_tokens": 300,
        "stream": True,
        "temperature": p["temperature"],
        **p["params"],
    }
    request = urllib.request.Request(
        f"{url}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    say(f"> {args.message}\n(If the GPU is asleep, the answer starts in 1-3 minutes.)\n")
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=900) as response:
            first = True
            for raw in response:
                line = raw.decode().strip()
                if not line.startswith("data: ") or line == "data: [DONE]":
                    continue
                delta = json.loads(line[6:])["choices"][0].get("delta", {})
                text = delta.get("content") or ""
                if first and text:
                    say(f"[first word after {time.monotonic() - started:.0f} s]\n")
                    first = False
                print(text, end="", flush=True)
    except urllib.error.HTTPError as e:
        die(f"HTTP {e.code}: {e.read().decode()[:500]}")
    say(f"\n\n[{time.monotonic() - started:.0f} s in total]")


def status(args) -> None:
    t = target_from(args)
    raw = value(
        "run", "services", "list", f"--region={t.region}", f"--filter=metadata.labels.app={PREFIX}",
        "--format=json", *t.flags(),
    )  # fmt: skip
    services = json.loads(raw or "[]")
    if not services:
        say(f"No model services in {t.project}/{t.region}. Deploy one: make model-deploy PRESET=qwen3-vl-8b")
        return
    say(f"{'SERVICE':<28} {'GPU':<22} {'READY':<6} URL")
    for s in services:
        tpl = s.get("spec", {}).get("template", {})
        gpu = tpl.get("spec", {}).get("nodeSelector", {}).get("run.googleapis.com/accelerator", "-")
        ready = next((c["status"] for c in s.get("status", {}).get("conditions", []) if c["type"] == "Ready"), "?")
        say(f"{s['metadata']['name']:<28} {gpu:<22} {ready:<6} {s.get('status', {}).get('url', '')}")
    say("\nAn instance only runs (and costs money) after a message, for up to ~15 idle minutes.")
    say("See instances and cost: console.cloud.google.com/run (Metrics: 'Instance count').")


def delete(args) -> None:
    t = target_from(args)
    name = service_name(args.preset)
    p = preset_or_die(args.preset)
    gcloud("run", "services", "delete", name, f"--region={t.region}", *t.flags(), check=False)
    if args.weights:
        gcloud("storage", "rm", "--recursive", weights_uri(t, p["hf_model_id"]), *t.flags(), check=False)
    else:
        say(
            f"\nThe copied model stays in {weights_uri(t, p['hf_model_id'])} (about $0.02 per GB per month),\n"
            f"so a new deploy skips the copy. Delete it too: make model-delete PRESET={args.preset} WEIGHTS=1"
        )
    if APP_CONFIG.exists() and not DRY_RUN:
        entries = [e for e in json.loads(APP_CONFIG.read_text()) if e.get("id") != args.preset]
        APP_CONFIG.write_text(json.dumps(entries, indent=2) + "\n")
        say(f"Removed {args.preset!r} from {APP_CONFIG.relative_to(ROOT)}.")


def presets(_args) -> None:
    say(f"{'PRESET':<14} {'GPU':<32} {'$/HOUR':<8} MODEL")
    for name, p in load_presets().items():
        price = f"{p['hourly_usd']:.2f}" if p.get("hourly_usd") is not None else "preview"
        flags = " (vision)" if p["vision"] else ""
        flags += " (gated: needs HF_TOKEN)" if p["gated"] else ""
        say(f"{name:<14} {p['gpu']:<32} {price:<8} {p['hf_model_id']}{flags}")
    say("\n$/hour = while awake; $0 while asleep. Deploy: make model-deploy PRESET=<preset>")


def main() -> None:
    global DRY_RUN
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project", help="Google Cloud project ID (default: GCP_PROJECT)")
    common.add_argument("--region", help="Region with GPUs (default: GCP_REGION, else us-central1)")
    common.add_argument("--dry-run", action="store_true", help="print the gcloud commands, change nothing")
    sub = parser.add_subparsers(required=True)

    sub.add_parser("presets", help="list ready-made models").set_defaults(fn=presets)
    p = sub.add_parser("deploy", parents=[common], help="copy the model and create the GPU service")
    p.add_argument("preset")
    p.set_defaults(fn=deploy)
    p = sub.add_parser("stage", parents=[common], help="only copy the model weights to Cloud Storage")
    p.add_argument("model", help="a preset, or a Hugging Face id such as Qwen/Qwen3-8B-FP8")
    p.add_argument("--gated", action="store_true", help="the Hugging Face model needs HF_TOKEN")
    p.add_argument("--bucket", help="weights bucket (default: <project>-llmchat-models)")
    p.add_argument("--service-account", help="run Cloud Build as this account (skips creating llmchat-builder)")
    p.add_argument("--force", action="store_true", help="copy again even if it was copied before")
    p.set_defaults(fn=stage)
    p = sub.add_parser("chat", parents=[common], help="send one message and stream the answer")
    p.add_argument("preset")
    p.add_argument("message", nargs="?", default="Say hello in three languages.")
    p.set_defaults(fn=chat)
    sub.add_parser("status", parents=[common], help="list the model services").set_defaults(fn=status)
    p = sub.add_parser("delete", parents=[common], help="delete the GPU service")
    p.add_argument("preset")
    p.add_argument("--weights", action="store_true", help="also delete the copied model from Cloud Storage")
    p.set_defaults(fn=delete)

    args = parser.parse_args()
    DRY_RUN = getattr(args, "dry_run", False)
    if DRY_RUN:
        say("DRY RUN: printing the commands, changing nothing.\n")
    args.fn(args)


if __name__ == "__main__":
    main()
