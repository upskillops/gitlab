variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  description = "Full https:// API server endpoint. The scheme is stripped to give Cilium k8sServiceHost -- with kube-proxy gone there is nothing to translate the kubernetes.default ClusterIP, so the agent needs the real address."
  type        = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider" {
  description = "OIDC issuer host, without the https:// scheme. Used to build the IRSA trust conditions."
  type        = string
}

variable "vpc_cidr" {
  description = "Becomes ipv4NativeRoutingCIDR. Traffic inside it is routed natively rather than encapsulated."
  type        = string
}

variable "chart_version" {
  type = string
}

variable "install_method" {
  description = "\"terraform\" renders the helm_release here. \"helm\" creates only the IRSA role and leaves the release to helm-charts/bin/install-cilium.sh."
  type        = string

  validation {
    condition     = contains(["helm", "terraform"], var.install_method)
    error_message = "install_method must be \"helm\" or \"terraform\"."
  }
}

variable "enable_prefix_delegation" {
  type    = bool
  default = true
}

variable "enable_hubble_relay" {
  type    = bool
  default = true
}

variable "operator_replicas" {
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
