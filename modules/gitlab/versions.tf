terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws        = { source = "hashicorp/aws", version = ">= 6.0" }
    helm       = { source = "hashicorp/helm", version = ">= 2.17" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.38" }
    random     = { source = "hashicorp/random", version = ">= 3.6" }
  }
}
