# Cloud SQL for PostgreSQL: users, conversations, messages, settings.
#
# It has a public IP address, but no "authorized networks": nothing on the
# internet may connect to it. The api reaches it through Cloud Run's built-in
# Cloud SQL connection (an encrypted tunnel authorized by IAM), which shows up
# in the container as a unix socket under /cloudsql/. No VPC needed.

resource "google_sql_database_instance" "main" {
  name             = "${local.name}-db-${random_id.suffix.hex}"
  database_version = "POSTGRES_17"
  region           = var.region

  # Terraform refuses to delete it while this is true.
  deletion_protection = local.is_prod

  settings {
    tier = var.db_tier
    # The shared-core tiers (db-f1-micro, db-g1-small) only exist in the
    # Enterprise edition; new PostgreSQL 16+ instances default to Enterprise Plus.
    edition           = "ENTERPRISE"
    availability_type = local.is_prod ? "REGIONAL" : "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = var.db_disk_gb
    disk_autoresize   = true
    user_labels       = local.labels

    # Google's own protection, on top of Terraform's.
    deletion_protection_enabled = local.is_prod

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00" # UTC
      point_in_time_recovery_enabled = local.is_prod
      backup_retention_settings {
        retained_backups = 7
      }
    }

    maintenance_window {
      day  = 7 # Sunday
      hour = 4 # UTC
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_sql_database" "app" {
  name     = "llmchat"
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "app" {
  name     = "llmchat"
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
}
