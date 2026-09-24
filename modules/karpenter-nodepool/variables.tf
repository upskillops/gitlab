variable "name" {
  description = "NodePool / EC2NodeClass name, e.g. 'infra-pool'."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, used for the karpenter.sh/discovery tag on subnets and security groups."
  type        = string
}

variable "node_iam_role_name" {
  description = "IAM role name (not ARN) Karpenter should use when launching nodes for this pool."
  type        = string
}

variable "ami_alias" {
  description = "EC2NodeClass amiSelectorTerms alias, family@version. Karpenter resolves the correct architecture automatically from the NodePool's kubernetes.io/arch requirement, so one alias covers both arm64 and amd64."
  type        = string
  default     = "al2023@latest"
}

variable "architecture" {
  description = "kubernetes.io/arch value. arm64 = Graviton."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "amd64"], var.architecture)
    error_message = "architecture must be either arm64 or amd64."
  }
}

variable "subnet_selector_terms" {
  description = "Override subnet selection, e.g. [{ id = \"subnet-xxxx\" }]. Defaults to karpenter.sh/discovery tag lookup. Typed 'any' because each term can mix a flat 'id' string with a nested 'tags' map."
  type        = list(any)
  default     = []
}

variable "security_group_selector_terms" {
  description = "Override security group selection, same shape as subnet_selector_terms. Defaults to karpenter.sh/discovery tag lookup."
  type        = list(any)
  default     = []
}

variable "volume_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 50
}

variable "taint_key" {
  type    = string
  default = "workload"
}

variable "taint_value" {
  description = "Value for the workload isolation taint applied to every node in this pool. Must match the tier's managed node group taint."
  type        = string
}

variable "extra_labels" {
  description = "Additional node labels beyond {taint_key = taint_value}."
  type        = map(string)
  default     = {}
}

variable "instance_categories" {
  description = "Allowed karpenter.k8s.aws/instance-category values, e.g. [\"c\",\"m\"]."
  type        = list(string)
}

variable "instance_sizes" {
  description = "Allowed karpenter.k8s.aws/instance-size values. This is what enforces the minimum instance size -- omit 'nano'..'medium' to set a floor."
  type        = list(string)
}

variable "min_instance_generation" {
  description = "Minimum instance generation, exclusive Gt comparison. \"6\" restricts arm64 to the 7g/8g families."
  type        = string
  default     = "6"
}

variable "capacity_types" {
  description = "Allowed karpenter.sh/capacity-type values, e.g. [\"spot\",\"on-demand\"]."
  type        = list(string)
  default     = ["on-demand"]
}

variable "expire_after" {
  description = "Force node replacement after this duration, e.g. \"720h\"."
  type        = string
  default     = "720h"
}

variable "limits" {
  description = "Total resource ceiling for this NodePool, a safety cap roughly derived from max node count x instance size."
  type = object({
    cpu    = string
    memory = string
  })
}

variable "consolidation_policy" {
  type    = string
  default = "WhenEmptyOrUnderutilized"
}

variable "consolidate_after" {
  type    = string
  default = "5m"
}

variable "disruption_budgets" {
  description = "Karpenter disruption budgets, e.g. [{ nodes = \"20%\" }] or [{ nodes = \"1\" }]."
  type        = list(map(string))
  default     = [{ nodes = "20%" }]
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "namespace" {
  description = "Namespace for the carrier Helm release. The Karpenter objects themselves are cluster-scoped; this only decides where the release secret lives."
  type        = string
  default     = "kube-system"
}
