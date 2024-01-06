
provider "aws" {
  region                  = var.region
  shared_credentials_files = [var.credentials]
  profile                 = var.profile
}

provider "kubectl" {
  host                   = aws_eks_cluster.eks_cluster.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.eks_cluster.certificate_authority[0].data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks_cluster.id]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.eks_cluster.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.eks_cluster.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks_cluster.id]
      command     = "aws"
    }
  }
}

provider "kubernetes" {
  host                   = aws_eks_cluster.eks_cluster.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.eks_cluster.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks_cluster.id]
    command     = "aws"
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_vpc" "vpc" {
  cidr_block = var.cidr_vpc
  enable_dns_support = true
  enable_dns_hostnames  = true

  tags = {
    Name = "${var.cluster_name}-vpc",
  }

}

resource "aws_subnet" "private" {
  count = length(var.azs) 

  availability_zone = var.azs[count.index]
  cidr_block        = var.cidr_private[count.index]
  vpc_id            = aws_vpc.vpc.id

  tags = {
    Name = "${var.cluster_name}-subnet-${count.index}",
    "kubernetes.io/cluster/${var.cluster_name}" = "shared",
    "kubernetes.io/role/internal-elb": "1",
    "karpenter.sh/discovery" = "${var.cluster_name}"
  }

}

resource "aws_subnet" "public" {
  count = length(var.azs) 

  availability_zone = var.azs[count.index]
  cidr_block        = var.cidr_public[count.index]
  vpc_id            = aws_vpc.vpc.id

  tags = {
    Name = "${var.cluster_name}-subnet-${count.index}",
    "kubernetes.io/cluster/${var.cluster_name}" = "shared",
    "kubernetes.io/role/elb" = "1"
  }

}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

resource "aws_eip" "ip" {
}

resource "aws_nat_gateway" "ngw" {
  allocation_id = aws_eip.ip.id 
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.cluster_name}-ngw"
  }

}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.ngw.id
  }

  tags = {
    Name = "${var.cluster_name}-private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.cluster_name}-public"
  }
}

resource "aws_route_table_association" "private" {
  count = length(var.azs) 

  subnet_id      = aws_subnet.private.*.id[count.index]
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "public" {
  count = length(var.azs) 

  subnet_id      = aws_subnet.public.*.id[count.index]
  route_table_id = aws_route_table.public.id
}


resource "aws_iam_role" "cluster_role" {
  name = "${var.cluster_name}-control-role"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster_role.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.cluster_role.name
}

resource "aws_efs_file_system" "fs" {

 performance_mode = var.efs_performance_mode
 throughput_mode = var.efs_throughput_mode
 encrypted = true


  tags = {
    Name = var.cluster_name
  }
}


resource "aws_security_group" "efs_sg" {
  name = "${var.cluster_name}-efs-sg"
  description = "Security group for efs clients in vpc"
  vpc_id      = aws_vpc.vpc.id

  egress {
    from_port   = 2049
    to_port     = 2049 
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 2049 
    to_port     = 2049 
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block] 
  }

  tags = {
    Name = "${var.cluster_name}-efs-sg"
  }
}

resource "aws_efs_mount_target" "target" {
  count = length(var.azs) 
  file_system_id = aws_efs_file_system.fs.id

  subnet_id      = aws_subnet.private.*.id[count.index] 
  security_groups = [aws_security_group.efs_sg.id] 
}

resource "aws_security_group" "fsx_lustre_sg" {
  name = "${var.cluster_name}-fsx-lustre-sg"
  description = "Security group for fsx lustre clients in vpc"
  vpc_id      = aws_vpc.vpc.id

  egress {
    from_port   = 988 
    to_port     = 988 
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 988 
    to_port     = 988 
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block] 
  }

  tags = {
    Name = "${var.cluster_name}-fsx-lustre-sg"
  }
}

resource "aws_fsx_lustre_file_system" "fs" {
  import_path      = var.import_path != "" ? var.import_path: null 
  storage_capacity = 1200
  subnet_ids       = [aws_subnet.private[0].id]
  deployment_type = "SCRATCH_2"
  security_group_ids = [aws_security_group.fsx_lustre_sg.id] 

  tags = {
    Name = var.cluster_name
  }
}

locals {
  use_k8s_version = substr(var.k8s_version, 0, 3) == "1.1" ? "1.28": var.k8s_version
}

resource "aws_eks_cluster" "eks_cluster" {
  name            = var.cluster_name
  role_arn        = aws_iam_role.cluster_role.arn
  version	        = local.use_k8s_version
  enabled_cluster_log_types = [ "api", "audit" ]

  vpc_config {
    subnet_ids         = flatten([aws_subnet.private.*.id])
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl config unset current-context"
  }

  provisioner "local-exec" {
    command = "aws --region ${var.region} eks update-kubeconfig --name ${aws_eks_cluster.eks_cluster.name}"
  }

}


resource "kubectl_manifest" "nvidia-device-plugin" {

  yaml_body = <<YAML
  apiVersion: apps/v1
  kind: DaemonSet
  metadata:
    name: nvidia-device-plugin-daemonset
    namespace: kube-system
  spec:
    selector:
      matchLabels:
        name: nvidia-device-plugin-ds
    updateStrategy:
      type: RollingUpdate
    template:
      metadata:
        labels:
          name: nvidia-device-plugin-ds
      spec:
        tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
        priorityClassName: "system-node-critical"
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                  - key: "node.kubernetes.io/instance-type"
                    operator: In
                    values:
                    - g4dn.xlarge
                    - g4dn.2xlarge
                    - g4dn.4xlarge
                    - g4dn.8xlarge
                    - g4dn.12xlarge
                    - g4dn.16xlarge
                    - g5.xlarge
                    - g5.2xlarge
                    - g5.4xlarge
                    - g5.8xlarge
                    - g5.12xlarge
                    - g5.16xlarge
                    - g5.24xlarge
                    - g5.48xlarge
                    - p3.2xlarge
                    - p3.8xlarge
                    - p3.16xlarge
                    - p3dn.24xlarge
                    - p4d.24xlarge
                    - p4de.24xlarge
                    - p5.48xlarge
        containers:
        - image: nvcr.io/nvidia/k8s-device-plugin:${var.nvidia_plugin_version}
          name: nvidia-device-plugin-ctr
          env:
            - name: FAIL_ON_INIT_ERROR
              value: "false"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
          - name: device-plugin
            mountPath: /var/lib/kubelet/device-plugins
        volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins

  YAML
}

module "eks_blueprints_addons" {

  source = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.12" #ensure to update this to the latest/desired version

  cluster_name      = aws_eks_cluster.eks_cluster.id
  cluster_endpoint  = aws_eks_cluster.eks_cluster.endpoint
  cluster_version   = aws_eks_cluster.eks_cluster.version
  oidc_provider_arn = aws_iam_openid_connect_provider.eks_oidc_provider.arn

  enable_aws_load_balancer_controller    = true
  enable_metrics_server                  = true
  enable_aws_efs_csi_driver              = true
  enable_aws_fsx_csi_driver              = true

  aws_load_balancer_controller = {
    namespace     = "kube-system"
    chart_version = "v1.6.2"
  }

  aws_efs_csi_driver = {
    namespace     = "kube-system"
    chart_version = "2.5.2"
  }

  aws_fsx_csi_driver = {
    namespace     = "kube-system"
    chart_version = "1.8.0"
  }

}

resource "helm_release" "cluster-autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.34.1"
  namespace  = "kube-system"

  set {
    name  = "cloudProvider"
    value = "aws"
  }

  set {
    name  = "awsRegion"
    value = var.region
  }

  set {
    name  = "autoDiscovery.clusterName"
    value = aws_eks_cluster.eks_cluster.id
  }

  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }

  set {
    name  = "extraArgs.skip-nodes-with-local-storage"
    value = "false"
  }

  set {
    name  = "extraArgs.expander"
    value = "least-waste"
  }

  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  set {
    name  = "podAnnotations.cluster-autoscaler\\.kubernetes\\.io/safe-to-evict"
    value = "\"false\""
  }

}

resource "helm_release" "aws-efa-k8s-device-plugin" {
  name       = "aws-efa-k8s-device-plugin"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-efa-k8s-device-plugin"
  version    = "v0.4.2"
  namespace  = "kube-system"

  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }

  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  set {
    name  = "tolerations[1].key"
    value = "aws.amazon.com/neuron"
  }

  set {
    name  = "tolerations[1].operator"
    value = "Exists"
  }

  set {
    name  = "tolerations[1].effect"
    value = "NoSchedule"
  }

  set {
    name  = "tolerations[2].key"
    value = "aws.amazon.com/efa"
  }

  set {
    name  = "tolerations[2].operator"
    value = "Exists"
  }

  set {
    name  = "tolerations[2].effect"
    value = "NoSchedule"
  }

}

resource "kubectl_manifest" "neuron_device_rbac_cr" {

  yaml_body = <<YAML
  kind: ClusterRole
  apiVersion: rbac.authorization.k8s.io/v1
  metadata:
    name: neuron-device-plugin
  rules:
  - apiGroups:
    - ""
    resources:
    - nodes
    verbs:
    - get
    - list
    - watch
  - apiGroups:
    - ""
    resources:
    - events
    verbs:
    - create
    - patch
  - apiGroups:
    - ""
    resources:
    - pods
    verbs:
    - update
    - patch
    - get
    - list
    - watch
  - apiGroups:
    - ""
    resources:
    - nodes/status
    verbs:
    - patch
    - update
  YAML

}

resource "kubectl_manifest" "neuron_device_rbac_sa" {

  yaml_body = <<YAML
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: neuron-device-plugin
    namespace: kube-system
  YAML

}

resource "kubectl_manifest" "neuron_device_rbac_crb" {

  yaml_body = <<YAML
  kind: ClusterRoleBinding
  apiVersion: rbac.authorization.k8s.io/v1
  metadata:
    name: neuron-device-plugin
    namespace: kube-system
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: neuron-device-plugin
  subjects:
  - kind: ServiceAccount
    name: neuron-device-plugin
    namespace: kube-system
  YAML

}

resource "kubectl_manifest" "neuron_device_plugin" {

  yaml_body = <<YAML
  apiVersion: apps/v1
  kind: DaemonSet
  metadata:
    name: neuron-device-plugin-daemonset
    namespace: kube-system
  spec:
    selector:
      matchLabels:
        name:  neuron-device-plugin-ds
    updateStrategy:
      type: RollingUpdate
    template:
      metadata:
        labels:
          name: neuron-device-plugin-ds
      spec:
        serviceAccount: neuron-device-plugin
        tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
        - key: aws.amazon.com/neuron
          operator: Exists
          effect: NoSchedule
        priorityClassName: "system-node-critical"
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                    - key: "node.kubernetes.io/instance-type"
                      operator: In
                      values:
                        - inf2.xlarge
                        - inf2.4xlarge
                        - inf2.8xlarge
                        - inf2.24xlarge
                        - inf2.48xlarge
                        - trn1.2xlarge
                        - trn1.32xlarge
                        - trn1n.32xlarge
        containers:
          #Device Plugin containers are available both in us-east and us-west ecr
          #repos
        - image: public.ecr.aws/neuron/neuron-device-plugin:2.18.3.0
          imagePullPolicy: Always
          name: neuron-device-plugin
          env:
          - name: KUBECONFIG
            value: /etc/kubernetes/kubelet.conf
          - name: NODE_NAME
            valueFrom:
              fieldRef:
                fieldPath: spec.nodeName
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
            - name: infa-map
              mountPath: /run
        volumes:
          - name: device-plugin
            hostPath:
              path: /var/lib/kubelet/device-plugins
          - name: infa-map
            hostPath:
              path: /run
  YAML
}

resource "kubernetes_namespace" "kubeflow" {
  metadata {
    name = "${var.kubeflow_namespace}"
  }
}

module "kubeflow-components" {
  source = "./kubeflow"

  namespace = var.kubeflow_namespace
  local_helm_repo = var.local_helm_repo

  depends_on = [ kubernetes_namespace.kubeflow ]
}



data "tls_certificate" "this" {
  url = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks_oidc_provider" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.this.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer
  
}

resource "kubectl_manifest" "fsx_sc" {

  yaml_body = <<YAML
  kind: StorageClass
  apiVersion: storage.k8s.io/v1
  metadata:
    name: fsx-sc
  provisioner: fsx.csi.aws.com
  YAML
}

resource "kubectl_manifest" "pv_fsx" {

  depends_on = [
    kubectl_manifest.fsx_sc
  ]

  yaml_body = <<YAML
  apiVersion: v1
  kind: PersistentVolume
  metadata:
    name: pv-fsx
  spec:
    capacity:
      storage: 1200Gi 
    volumeMode: Filesystem
    accessModes:
      - ReadWriteMany
    mountOptions:
      - noatime
      - flock
    persistentVolumeReclaimPolicy: Retain
    csi:
      driver: fsx.csi.aws.com
      volumeHandle: "${aws_fsx_lustre_file_system.fs.id}"
      volumeAttributes:
        dnsname: "${aws_fsx_lustre_file_system.fs.id}.fsx.${var.region}.amazonaws.com"
        mountname: "${aws_fsx_lustre_file_system.fs.mount_name}"
  YAML
}

resource "kubectl_manifest" "pvc_fsx" {

  depends_on = [
    kubectl_manifest.pv_fsx
  ]

  yaml_body = <<YAML
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: pv-fsx
    namespace: "${var.kubeflow_namespace}"
  spec:
    accessModes:
      - ReadWriteMany
    storageClassName: "" 
    resources:
      requests:
        storage: 1200Gi
    volumeName: pv-fsx
  YAML
}


resource "kubectl_manifest" "efs_sc" {

  yaml_body = <<YAML
  kind: StorageClass
  apiVersion: storage.k8s.io/v1
  metadata:
    name: efs-sc
  provisioner: efs.csi.aws.com
  YAML
}

resource "kubectl_manifest" "pv_efs" {

  depends_on = [
    kubectl_manifest.efs_sc
  ]

  yaml_body = <<YAML
  apiVersion: v1
  kind: PersistentVolume
  metadata:
    name: pv-efs
  spec:
    capacity:
      storage: 1000Gi
    volumeMode: Filesystem
    accessModes:
      - ReadWriteMany
    persistentVolumeReclaimPolicy: Retain
    storageClassName: efs-sc
    csi:
      driver: efs.csi.aws.com
      volumeHandle: "${aws_efs_file_system.fs.id}"
  YAML
}

resource "kubectl_manifest" "pvc_efs" {

  depends_on = [
    kubectl_manifest.pv_efs
  ]

  yaml_body = <<YAML
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: pv-efs
    namespace: "${var.kubeflow_namespace}"
  spec:
    accessModes:
      - ReadWriteMany
    storageClassName: efs-sc 
    resources:
      requests:
        storage: 100Gi
    YAML
}

resource "aws_iam_role" "node_role" {
  name = "${aws_eks_cluster.eks_cluster.id}-node-role"

  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "node_autoscaler_policy" {
   name = "node-autoscaler-policy"
   role = aws_iam_role.node_role.id

    policy = jsonencode({
      "Version": "2012-10-17",
      "Statement": [
        {
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:DescribeTags",
                "autoscaling:SetDesiredCapacity",
                "autoscaling:TerminateInstanceInAutoScalingGroup",
                "ec2:DescribeLaunchTemplateVersions",
                "eks:DescribeNodegroup"
            ],
            "Resource": "*",
            "Effect": "Allow"
        }
      ]
    })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonS3ReadOnlyPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  role       = aws_iam_role.node_role.name
}

resource "aws_eks_node_group" "system_ng" {
  cluster_name    = aws_eks_cluster.eks_cluster.id
  node_group_name = "system" 
  node_role_arn   = aws_iam_role.node_role.arn 
  subnet_ids      = aws_subnet.private.*.id 
  instance_types  = var.system_instances
  disk_size       = var.system_volume_size
  ami_type        = "AL2_x86_64"

  scaling_config {
    desired_size = 2 
    max_size     = 8
    min_size     = 2 
  }

  dynamic "remote_access" {
    for_each = var.key_pair != "" ? [1] : []
    content {
      ec2_ssh_key = var.key_pair
    }
  }

}

resource "aws_launch_template" "this" {

  count = var.karpenter_enabled ? 0 : length(var.node_instances)

  instance_type = var.node_instances[count.index]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.node_volume_size
      volume_type = "gp3"
      iops =  3000
      encrypted = true
      delete_on_termination = true
      throughput = 125
    }
  }

  dynamic "network_interfaces" {
    for_each = range(0, lookup(var.efa_enabled, var.node_instances[count.index], 0), 1)
    iterator = nic
    content {
      device_index          = nic.value != 0 ? 1 : nic.value
      delete_on_termination = true
      associate_public_ip_address = false
      interface_type = "efa"
      network_card_index = nic.value
    }
  }

  key_name = var.key_pair != "" ? var.key_pair : null
  
  user_data = filebase64("../../user-data.txt")
}

resource "aws_eks_node_group" "this" {
  count = var.karpenter_enabled ? 0 : length(var.node_instances)

  cluster_name    = var.cluster_name
  node_group_name = "nodegroup-${count.index}"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = aws_subnet.private.*.id
  ami_type        = "AL2_x86_64_GPU"
  capacity_type = var.capacity_type

 launch_template {
    id = aws_launch_template.this[count.index].id
    version = aws_launch_template.this[count.index].latest_version
  }

  scaling_config {
    desired_size = var.node_group_desired 
    max_size     = var.node_group_max 
    min_size     = var.node_group_min 
  }

  taint {
    key = "fsx.csi.aws.com/agent-not-ready"
    effect = "NO_EXECUTE"
  }

  taint {
    key = contains(var.neuron_instances, var.node_instances[count.index]) ? "aws.amazon.com/neuron" : "nvidia.com/gpu"
    value = "true"
    effect = "NO_SCHEDULE"
  }

  dynamic "taint" {
    for_each = var.custom_taints

    content {
      key = taint.value.key
      value = taint.value.value
      effect = taint.value.effect
    }
  }

}


module "karpenter" {
  count = var.karpenter_enabled ? 1 : 0

  source = "terraform-aws-modules/eks/aws//modules/karpenter"

  cluster_name = aws_eks_cluster.eks_cluster.id

  irsa_oidc_provider_arn          = aws_iam_openid_connect_provider.eks_oidc_provider.arn
  irsa_namespace_service_accounts = ["${var.karpenter_namespace}:karpenter"]

  create_iam_role = true
  iam_role_attach_cni_policy = true
  iam_role_additional_policies = {
    s3_policy = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  }
  irsa_tag_key = "karpenter.sh/managed-by"

}

resource "aws_iam_policy" "karpenter" {
  count = var.karpenter_enabled ? 1 : 0

  name        = "karpenter-iam-policy"
  
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "iam:GetInstanceProfile",
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": "iam:CreateInstanceProfile",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/kubernetes.io/cluster/${aws_eks_cluster.eks_cluster.id}": "owned",
          "aws:RequestTag/topology.kubernetes.io/region": "${var.region}"
        },
        "StringLike": {
          "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      },
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:DeleteInstanceProfile"
      ],
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${aws_eks_cluster.eks_cluster.id}": "owned",
          "aws:ResourceTag/topology.kubernetes.io/region": "${var.region}"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      },
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": "iam:TagInstanceProfile",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${aws_eks_cluster.eks_cluster.id}": "owned",
          "aws:ResourceTag/topology.kubernetes.io/region": "${var.region}",
          "aws:RequestTag/kubernetes.io/cluster/${aws_eks_cluster.eks_cluster.id}": "owned",
          "aws:RequestTag/topology.kubernetes.io/region": "${var.region}"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*",
          "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      },
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "karpenter_policy_attach" {
  count = var.karpenter_enabled ? 1 : 0

  role       = "${module.karpenter[0].irsa_name}"
  policy_arn = "${aws_iam_policy.karpenter[0].arn}"
  
}


resource "kubectl_manifest" "aws_auth" {

  count = var.karpenter_enabled ? 1 : 0

  yaml_body = <<YAML
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: aws-auth
    namespace: kube-system
  data:
    mapRoles: |
      - rolearn: "${aws_iam_role.node_role.arn}"
        username: system:node:{{EC2PrivateDNSName}}
        groups:
          - system:bootstrappers
          - system:nodes
      - rolearn: "${module.karpenter[0].role_arn}"
        username: system:node:{{EC2PrivateDNSName}}
        groups:
          - system:bootstrappers
          - system:nodes
  
  YAML
}

resource "helm_release" "karpenter" {
  count = var.karpenter_enabled ? 1 : 0
  
  name       = "karpenter"
  chart      = "karpenter"
  cleanup_on_fail = true
  create_namespace = true
  repository  = "oci://public.ecr.aws/karpenter/"
  version    = var.karpenter_version
  namespace  = var.karpenter_namespace
  timeout = 300
  wait = true

  set {
    name  = "settings.clusterName"
    value = aws_eks_cluster.eks_cluster.id
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = "1"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "2Gi"
  }

  set {
    name  = "controller.resources.limits.cpu"
    value = "1"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "2Gi"
  }


  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter[0].irsa_arn
  }

  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter[0].queue_name
  }

}

resource "helm_release" "karpenter_components" {
  count = var.karpenter_enabled ? 1 : 0

  chart = "${var.local_helm_repo}/karpenter-components"
  name = "karpenter-components"
  version = "1.0.0"
  namespace = var.karpenter_namespace
  
  set {
    name  = "namespace"
    value = var.karpenter_namespace
  }

  set {
    name  = "role_name"
    value = module.karpenter[0].role_name
  }

  set {
    name  = "cluster_id"
    value = aws_eks_cluster.eks_cluster.id
  }

  set {
    name  = "consolidate_after"
    value = var.karpenter_consolidate_after
  }

  set {
    name  = "capacity_type"
    value = var.karpenter_capacity_type
  }

}