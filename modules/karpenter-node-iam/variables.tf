variable "node_iam_role_name" { type = string }

variable "tags" {
  type    = map(string)
  default = {}
}
