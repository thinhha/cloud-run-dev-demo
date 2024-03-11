/**
 * Copyright 2023 Google LLC
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

locals {
  cloud_run_domain = "run.app."
}

###############################################################################
#                                  Projects                                   #
###############################################################################

# Main project
module "project_main" {
  source          = "github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/project?ref=v29.0.0"
  name            = var.prj_main_id
  services = [
    "run.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "accesscontextmanager.googleapis.com"
  ]
  skip_delete = true
  project_create = false
}

###############################################################################
#                                  Cloud Run                                  #
###############################################################################

# Cloud Run service in main project

# using Direct VPC Egress
module "cloud_run_hello" {
  source       = "github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/cloud-run-v2?ref=v29.0.0"
  project_id   = module.project_main.project_id
  name         = "hello-vpc-direct"
  region       = var.region
  launch_stage = "BETA"
  containers = {
    hello = {
      image = var.image
    }
  }
  revision = {
    gen2_execution_environment = true
    max_instance_count         = 20
    vpc_access = {
      egress = "ALL_TRAFFIC"
      subnet = module.my_vpc.subnet_ids["${var.region}/my-subnet-main"]
    }
  }
  ingress = var.ingress_settings
}



# VPC Access connector
resource "google_vpc_access_connector" "connector" {
  name    = "connector"
  project = module.project_main.project_id
  region  = var.region
  subnet {
    name       = module.my_vpc.subnets["${var.region}/subnet-vpc-access"].name
    project_id = module.project_main.project_id
  }
}

# using VPC Connector
module "cloud_run_hello_2" {
  source       = "github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/cloud-run-v2?ref=v29.0.0"
  project_id   = module.project_main.project_id
  name         = "hello-vpc-connector"
  region       = var.region
  launch_stage = "BETA"
  containers = {
    hello = {
      image = var.image
    }
  }
  revision = {
    gen2_execution_environment = true
    max_instance_count         = 20
    vpc_access = {
      connector = google_vpc_access_connector.connector.id
      egress    = "ALL_TRAFFIC"
    }
  }
  ingress = var.ingress_settings
}


###############################################################################
#                                    VPCs                                     #
###############################################################################

# VPC in main project
module "my_vpc" {
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/net-vpc?ref=v29.0.0"
  project_id = module.project_main.project_id
  name       = "my-vpc"
  subnets = [
    {
      ip_cidr_range = var.ip_ranges["main"].subnet
      name          = "my-subnet-main"
      region        = var.region
    },
    {
      ip_cidr_range = var.ip_ranges["main"].subnet_vpc_access
      name          = "subnet-vpc-access"
      region        = var.region
    }
  ]
}

# Main VPC Firewall with default config, IAP for SSH enabled
module "firewall_main" {
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/net-vpc-firewall?ref=v29.0.0"
  project_id = module.project_main.project_id
  network    = module.my_vpc.name
  default_rules_config = {
    http_ranges  = []
    https_ranges = []
  }
}

###############################################################################
#                                    PSC                                      #
###############################################################################

# PSC configured in the main project
module "psc_addr_main" {
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/net-address?ref=v29.0.0"
  project_id = module.project_main.project_id
  psc_addresses = {
    psc-addr = {
      address = var.ip_ranges["main"].psc_addr
      network = module.my_vpc.id
    }
  }
}

resource "google_compute_global_forwarding_rule" "psc_endpoint_main" {
  provider              = google-beta
  project               = module.project_main.project_id
  name                  = "pscaddr"
  network               = module.my_vpc.self_link
  ip_address            = module.psc_addr_main.psc_addresses["psc-addr"].self_link
  target                = "vpc-sc"
  load_balancing_scheme = ""
}

###############################################################################
#                                    DNS                                      #
###############################################################################

module "private_dns_main" {
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/dns?ref=v29.0.0"
  project_id = module.project_main.project_id
  name       = "dns-main"
  zone_config = {
    domain = local.cloud_run_domain
    private = {
      client_networks = [module.my_vpc.self_link]
    }
  }
  recordsets = {
    "A *" = { records = [module.psc_addr_main.psc_addresses["psc-addr"].address] }
  }
}

###############################################################################
#                                    VMs                                      #
###############################################################################

module "workstation-cluster" {
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/workstation-cluster?ref=v29.0.0"
  project_id = module.project_main.project_id
  id         = "my-workstation-cluster"
  location   = var.region
  network_config = {
    network    = module.my_vpc.id
    subnetwork = module.my_vpc.subnet_ids["${var.region}/my-subnet-main"]
  }
  private_cluster_config = {
    enable_private_endpoint = false
  }
  workstation_configs = {
    my-workstation-config = {
      workstations = {
        my-workstation = {
          gce_instance = {
            disable_public_ip_addresses  = true
          }
          labels = {
            team = "my-team"
          }
        }
      }
    }
  }
}
