terraform {
    backend "s3" {
        bucket = "horangflow"
        key    = "amazon-eks-machine-learning-with-terraform-and-kubeflow/terraform/state"
        region = "ap-northeast-2"
    }
}
