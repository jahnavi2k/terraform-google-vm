/**
 * Copyright 2019 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#########
# Locals
#########

locals {
  source_image         = var.source_image != "" ? var.source_image : "rocky-linux-9-optimized-gcp-v20240111"
  source_image_family  = var.source_image_family != "" ? var.source_image_family : "rocky-linux-9-optimized-gcp"
  source_image_project = var.source_image_project != "" ? var.source_image_project : "rocky-linux-cloud"

  boot_disk = [
    {
      source_image      = var.source_image != "" ? format("${local.source_image_project}/${local.source_image}") : format("${local.source_image_project}/${local.source_image_family}")
      disk_size_gb      = var.disk_size_gb
      disk_type         = var.disk_type
      disk_labels       = var.disk_labels
      auto_delete       = var.auto_delete
      boot              = "true"
      resource_policies = var.disk_resource_policies
    },
  ]

  all_disks = concat(local.boot_disk, var.additional_disks)

  # NOTE: Even if all the shielded_instance_config or confidential_instance_config
  # values are false, if the config block exists and an unsupported image is chosen,
  # the apply will fail so we use a single-value array with the default value to
  # initialize the block only if it is enabled.
  shielded_vm_configs = var.enable_shielded_vm ? [true] : []

  gpu_enabled                      = var.gpu != null
  alias_ip_range_enabled           = var.alias_ip_range != null
  confidential_terminate_condition = var.enable_confidential_vm && (var.confidential_instance_type != "SEV" || var.min_cpu_platform != "AMD Milan")
  on_host_maintenance = (
    var.preemptible || local.gpu_enabled || var.spot || local.confidential_terminate_condition
    ? "TERMINATE"
    : var.on_host_maintenance
  )

  # must be set to "AMD Milan" if confidential_instance_type is set to "SEV_SNP", or this will fail to create the VM.
  min_cpu_platform = var.confidential_instance_type == "SEV_SNP" ? "AMD Milan" : var.min_cpu_platform

  automatic_restart = (
    # must be false when preemptible or spot is true
    var.preemptible || var.spot ? false : var.automatic_restart
  )
  preemptible = (
    # must be true when preemtible or spot is true
    var.preemptible || var.spot ? true : false
  )

  service_account = (
    var.service_account != null
    ? var.service_account
    : (
      var.create_service_account
      ? { email : google_service_account.sa[0].email, scopes : ["cloud-platform"] }
      : null
    )
  )
  create_service_account = var.create_service_account ? var.service_account == null : false

  service_account_prefix = substr("${var.name_prefix}-${var.region}", 0, 27)
  service_account_output = local.create_service_account ? {
    id     = google_service_account.sa[0].account_id,
    email  = google_service_account.sa[0].email,
    member = google_service_account.sa[0].member
  } : {}
}

# Service account
resource "google_service_account" "sa" {
  provider = google-beta
  count    = local.create_service_account ? 1 : 0

  project      = var.project_id
  account_id   = "${local.service_account_prefix}-sa"
  display_name = "Service account for ${var.name_prefix} in ${var.region}"
}

resource "google_project_iam_member" "roles" {
  provider = google-beta
  for_each = toset(distinct(var.service_account_project_roles))

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.service_account.email}"
}

####################
# Instance Template
####################
resource "google_compute_instance_template" "tpl" {
  provider                = google-beta
  name_prefix             = "${var.name_prefix}-"
  description             = var.description
  instance_description    = var.instance_description
  project                 = var.project_id
  machine_type            = var.machine_type
  labels                  = var.labels
  metadata                = var.metadata
  tags                    = var.tags
  can_ip_forward          = var.can_ip_forward
  metadata_startup_script = var.startup_script
  region                  = var.region
  min_cpu_platform        = local.min_cpu_platform
  resource_policies       = var.resource_policies
  resource_manager_tags   = var.resource_manager_tags

  dynamic "disk" {
    for_each = local.all_disks
    content {
      auto_delete       = lookup(disk.value, "auto_delete", null)
      boot              = lookup(disk.value, "boot", null)
      device_name       = lookup(disk.value, "device_name", null)
      disk_name         = lookup(disk.value, "disk_name", null)
      disk_size_gb      = lookup(disk.value, "disk_size_gb", lookup(disk.value, "disk_type", null) == "local-ssd" ? "375" : null)
      disk_type         = lookup(disk.value, "disk_type", null)
      interface         = lookup(disk.value, "interface", lookup(disk.value, "disk_type", null) == "local-ssd" ? "NVME" : null)
      mode              = lookup(disk.value, "mode", null)
      source            = lookup(disk.value, "source", null)
      source_image      = lookup(disk.value, "source_image", null)
      source_snapshot   = lookup(disk.value, "source_snapshot", null)
      type              = lookup(disk.value, "disk_type", null) == "local-ssd" ? "SCRATCH" : "PERSISTENT"
      labels            = lookup(disk.value, "disk_labels", null)
      resource_policies = lookup(disk.value, "resource_policies", [])

      dynamic "disk_encryption_key" {
        for_each = compact([var.disk_encryption_key == null ? null : 1])
        content {
          kms_key_self_link = var.disk_encryption_key
        }
      }
    }
  }

  dynamic "service_account" {
    for_each = local.service_account == null ? [] : [local.service_account]
    content {
      email  = lookup(service_account.value, "email", null)
      scopes = lookup(service_account.value, "scopes", null)
    }
  }

  network_interface {
    network            = var.network
    subnetwork         = var.subnetwork
    subnetwork_project = var.subnetwork_project
    network_ip         = length(var.network_ip) > 0 ? var.network_ip : null
    nic_type           = var.nic_type
    stack_type         = var.stack_type
    dynamic "access_config" {
      for_each = var.access_config
      content {
        nat_ip       = access_config.value.nat_ip
        network_tier = access_config.value.network_tier
      }
    }
    dynamic "ipv6_access_config" {
      for_each = var.ipv6_access_config
      content {
        network_tier = ipv6_access_config.value.network_tier
      }
    }
    dynamic "alias_ip_range" {
      for_each = local.alias_ip_range_enabled ? [var.alias_ip_range] : []
      content {
        ip_cidr_range         = alias_ip_range.value.ip_cidr_range
        subnetwork_range_name = alias_ip_range.value.subnetwork_range_name
      }
    }
  }

  dynamic "network_interface" {
    for_each = var.additional_networks
    content {
      network            = network_interface.value.network
      subnetwork         = network_interface.value.subnetwork
      subnetwork_project = network_interface.value.subnetwork_project
      network_ip         = length(network_interface.value.network_ip) > 0 ? network_interface.value.network_ip : null
      nic_type           = network_interface.value.nic_type
      stack_type         = network_interface.value.stack_type
      queue_count        = network_interface.value.queue_count
      dynamic "access_config" {
        for_each = network_interface.value.access_config
        content {
          nat_ip       = access_config.value.nat_ip
          network_tier = access_config.value.network_tier
        }
      }
      dynamic "ipv6_access_config" {
        for_each = network_interface.value.ipv6_access_config
        content {
          network_tier = ipv6_access_config.value.network_tier
        }
      }
      dynamic "alias_ip_range" {
        for_each = network_interface.value.alias_ip_range
        content {
          ip_cidr_range         = alias_ip_range.value.ip_cidr_range
          subnetwork_range_name = alias_ip_range.value.subnetwork_range_name
        }
      }
    }
  }

  lifecycle {
    create_before_destroy = "true"
  }

  scheduling {
    automatic_restart           = local.automatic_restart
    instance_termination_action = var.spot ? var.spot_instance_termination_action : null
    maintenance_interval        = var.maintenance_interval
    on_host_maintenance         = local.on_host_maintenance
    preemptible                 = local.preemptible
    provisioning_model          = var.spot ? "SPOT" : null
  }

  advanced_machine_features {
    enable_nested_virtualization = var.enable_nested_virtualization
    threads_per_core             = var.threads_per_core
  }

  dynamic "shielded_instance_config" {
    for_each = local.shielded_vm_configs
    content {
      enable_secure_boot          = lookup(var.shielded_instance_config, "enable_secure_boot", shielded_instance_config.value)
      enable_vtpm                 = lookup(var.shielded_instance_config, "enable_vtpm", shielded_instance_config.value)
      enable_integrity_monitoring = lookup(var.shielded_instance_config, "enable_integrity_monitoring", shielded_instance_config.value)
    }
  }

  confidential_instance_config {
    enable_confidential_compute = var.enable_confidential_vm
    confidential_instance_type  = var.confidential_instance_type
  }

  network_performance_config {
    total_egress_bandwidth_tier = var.total_egress_bandwidth_tier
  }

  dynamic "guest_accelerator" {
    for_each = local.gpu_enabled ? [var.gpu] : []
    content {
      type  = guest_accelerator.value.type
      count = guest_accelerator.value.count
    }
  }
}
