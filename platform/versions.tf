terraform {
  required_version = ">= 1.7.0"

  required_providers {
    proxmox = {
      source = "Telmate/proxmox"
      # 3.0.2-rc04+ removes VM.Monitor from the required-permissions pre-flight
      # check (PR #1382). Earlier versions reject Proxmox 9.x because PVE 9
      # removed that privilege entirely.
      version = "= 3.0.2-rc07"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }

    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }
}
