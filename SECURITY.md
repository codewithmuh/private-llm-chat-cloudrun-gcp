# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Use GitHub's private reporting instead: **Security → Report a vulnerability** on this
repository. Include what you found, how to reproduce it, and what an attacker could do
with it. You'll get an answer within a week.

## Scope

In scope: the application code in this repository (backend, frontend, model and
sidecar containers), the scripts, and the Terraform, when used as documented.

Out of scope: vulnerabilities in the models themselves (prompt injection, jailbreaks,
hallucinations), in upstream projects (vLLM, Django, Next.js, SearXNG, whisper.cpp;
report those upstream), in Google Cloud itself, and misconfigurations that the docs
warn against.

## Things this project does on purpose

- Sessions are `HttpOnly` cookies with CSRF protection; no tokens in `localStorage`.
  The browser talks to one origin only (the web service forwards `/api/` and
  `/admin/` to the api), so cookies never have to cross sites.
- Passwords are hashed by Django (PBKDF2); one-time codes and recovery codes are stored
  as keyed hashes; each emailed code allows 5 attempts and expires after 15 minutes.
- Two-factor authentication (authenticator app or email) also applies to the Django
  admin: `/admin/login/` sends you through the app's login.
- Only the web service is public. The api and the model services are **private**
  Cloud Run services: Cloud Run itself rejects any request without a valid Google ID
  token from an identity with `roles/run.invoker` on that service. Only the web
  service's account may call the api, and only the api's account may call the models.
  There is no API key to leak.
- **No service account keys**, anywhere. Each part runs as its own service account
  with only the permissions it needs, and gets short-lived credentials from Cloud Run.
  GitHub Actions deploys through Workload Identity Federation, trusted for one
  repository only. Locally, the app borrows a service account (impersonation) with
  your own Google login instead of a key file.
- Secrets (the Django secret key, the database password, the SearXNG secret, the SMTP
  password, a Hugging Face token for gated models) live in Secret Manager. Cloud Run
  injects them when a container starts; they never appear in a service's
  configuration or an image. Terraform generates the passwords, so they are also in
  the Terraform state, and the SMTP password is in your `terraform.tfvars`. Keep the
  state private (a local file, or the private bucket from `scripts/bootstrap-state.sh`),
  and never commit `terraform.tfvars` (it is gitignored).
- The Cloud SQL database has no authorized networks: the only way in is Cloud Run's
  built-in Cloud SQL connection, which IAM authorizes and encrypts. The instance
  accepts encrypted connections only.
- Uploaded files are private (Cloud Storage buckets with public access prevention
  enforced; downloads are signed links that expire after 5 minutes); only images and
  PDFs are ever shown inline.
- Web search fetches pages only from public IP addresses, checking every redirect,
  so a search result can't point the api at the metadata server or an internal
  service (SSRF).
- Prompts and answers are never written to logs.

## Before you put real data in it

- Set `environment = "prod"` in `terraform.tfvars`: database deletion protection, a
  regional (high-availability) database, point-in-time recovery, and an uploads
  bucket Terraform won't empty.
- Decide who can sign up (`signup_enabled`, `email_verification`, `admin_emails`).
- Set up real email (`email_provider = "smtp"`); the default writes emails to the logs.
- Consider a load balancer with Cloud Armor (a WAF) in front of the web service; it is
  not part of the Terraform. See [docs/05-advanced.md](docs/05-advanced.md).
- Set a billing budget with alerts.
