terraform {
  required_providers {
    # helm, not kubernetes: these objects are Karpenter custom resources whose
    # CRDs are created in the same apply. kubernetes_manifest resolves the CRD
    # at plan time and so cannot plan against a cluster that does not have it
    # yet; helm_release resolves nothing until apply. See the header of main.tf.
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.17"
    }
  }
}
