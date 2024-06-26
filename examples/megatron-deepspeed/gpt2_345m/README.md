# Pre-train GPT2 345M on Wikicorpus dataset using Megatron-DeepSpeed library

This example shows how to use [pytorch-distributed](../../../charts/machine-learning/training/pytorchjob-elastic/Chart.yaml) Helm chart to pre-train GPT2-345M model on Wikicorpus dataset with [Megatron-DeepSpeed](https://github.com/microsoft/Megatron-DeepSpeed) library, using distributed data-parallel, tensor-parallel, pipeline-parallel, and [DeepSpeed ZeRO-1](https://www.deepspeed.ai/tutorials/zero/). 

The example also shows use of [data-process](../../../charts/machine-learning/data-prep/data-process/Chart.yaml) Helm chart to pre-process the [Hugging Face Wikicorpus](https://huggingface.co/datasets/wikicorpus) dataset for use with Megatron-DeepSpeed GPT2-345M model.

Before proceeding, complete the [Prerequisites](../../../README.md#prerequisites) and [Getting started](../../../README.md#getting-started). See [What is in the YAML file](../../../README.md#what-is-in-the-yaml-file) to understand the common fields in the Helm values files. There are some fields that are specific to a machine learning chart.

## Pre-process Wikicorpus dataset

We define the runtime for pre-processing the dataset in [wikicorpus.yaml](./wikicorpus.yaml) values file. 

To launch the data processing job, execute:

    cd ~/amazon-eks-machine-learning-with-terraform-and-kubeflow
    helm install --debug mds-gpt2-345m \
        charts/machine-learning/data-prep/data-process \
        -f examples/megatron-deepspeed/gpt2_345m/wikicorpus.yaml -n kubeflow-user-example-com

To monitor the logs, execute:

    kubectl logs -f data-process-mds-gpt2-345m -n kubeflow-user-example-com

Uninstall the Helm chart at completion:

    helm uninstall mds-gpt2-345m -n kubeflow-user-example-com

## Launch DDP, ZeRO-1 pre-training 

We define the runtime for pre-training in [pretrain-ddp-zero1.yaml](./pretrain-ddp-zero1.yaml) values file. 

To launch distributed data parallel (DDP) training  with [DeepSpeed ZeRO-1](https://www.deepspeed.ai/tutorials/zero/):

    cd ~/amazon-eks-machine-learning-with-terraform-and-kubeflow
    helm install --debug mds-gpt2-345m \
        charts/machine-learning/training/pytorchjob-distributed \
        -f examples/megatron-deepspeed/gpt2_345m/pretrain-ddp-zero1.yaml -n kubeflow-user-example-com

To monitor the logs, execute:

    kubectl logs -f pytorchjob-mds-gpt2-345m-master-0  -n kubeflow-user-example-com

Uninstall the Helm chart at completion::

    helm uninstall mds-gpt2-345m -n kubeflow-user-example-com

## Launch DDP, TP, PP, ZeRO-1 pre-training 

We define the runtime for pre-training in [pretrain-ddp-tp-pp-zero1.yaml](./pretrain-ddp-tp-pp-zero1.yaml) values file. 

To launch distributed data parallel (DDP) training  with Megatron tensor-parallel (TP), pipeline-parallel (PP),  and [DeepSpeed ZeRO-1](https://www.deepspeed.ai/tutorials/zero/):

    cd ~/amazon-eks-machine-learning-with-terraform-and-kubeflow
    helm install --debug mds-gpt2-345m \
        charts/machine-learning/training/pytorchjob-distributed \
        -f examples/megatron-deepspeed/gpt2_345m/pretrain-ddp-tp-pp-zero1.yaml -n kubeflow-user-example-com

To monitor the logs, execute:

    kubectl logs -f pytorchjob-mds-gpt2-345m-master-0  -n kubeflow-user-example-com

Uninstall the Helm chart at completion::

    helm uninstall mds-gpt2-345m -n kubeflow-user-example-com

## Output

To access the output stored on EFS and FSx for Lustre file-systems, execute following commands:

    cd ~/amazon-eks-machine-learning-with-terraform-and-kubeflow
    kubectl apply -f eks-cluster/utils/attach-pvc.yaml  -n kubeflow
    kubectl exec -it -n kubeflow attach-pvc -- /bin/bash

This will put you in a pod attached to the  EFS and FSx for Lustre file-systems, mounted at `/efs`, and `/fsx`, respectively. Type `exit` to exit the pod.

### Data

Pre-processed data is available in `/fsx/home/mds-gpt2-345m/data/wikicorpus` folder.

### Logs

Pre-training `logs` are available in `/efs/home/mds-gpt2-345m/logs` folder. 

### Checkpoints

Pre-training `checkpoints`, if any, are available in `/fsx/home/mds-gpt2-345m/checkpoints` folder. 

### S3 Backup

Any content stored under `/fsx` is automatically backed up to your configured S3 bucket.
