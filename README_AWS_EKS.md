## Setting up Tanzu Application Platform on AWS EKS

These are scripts I've used to set up
Tanzu Application Platform (TAP) on AWS Elastic Kubernetes Service (EKS).

It is known to work with:
* [TAP beta 4](https://network.tanzu.vmware.com/products/tanzu-application-platform/#/releases/1013926)
* DockerHub for the container registry

This document assumes you are using a Mac, although it should be adaptable to a Linux-style environment.

This document and scripts are adapted from the original installation instructions:
<https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/0.4/tap/GUID-install-intro.html>

### Required environment

You'll need to have the following:

* A static domain name (not `nip.io` or similar tools which emulate one)
* An AWS account with an IAM user with the ability to create an EKS cluster with 3 EC2 instances of type `t2.xlarge`
* An external image repository account (e.g. DockerHub)

You'll need to install a subset of the command line tools as described in the `README.md` file:
* `kubectl`
* `kapp`
* `tanzu`

You do not need `kind`.

You'll also need to install:
* the [AWS CLI](https://aws.amazon.com/cli/)
* the [eksctl CLI](https://eksctl.io/)

### (Recommended) Set your environment variables

It is helpful to set the required environment variables in your shell prior to executing the `setup-tap.sh` script,
in order to avoid entering them at the prompts.

If you use [direnv](https://direnv.net/):
* Copy `envrc-template` to a new file called `.envrc`
* Edit the new file, and `direnv allow` it

```bash
cp envrc-template .envrc
# Edit .envrc to contain the correct values. Make sure to use enclose values with shell special characters, like `!`, with single quotes
direnv allow
```
Of course, `direnv` is not a requirement - you can use the template file as documentation to set your environment 
variables by whatever mechanism you choose.

AWS-specific notes on environment variables:
* `DOMAIN` should be the FQDN of an AWS Hosted Zone that your user has permission to add records to.
* `APPS_DOMAIN`, `GUI_DOMAIN`, and `EDUCATES_DOMAIN` (if needed based on which packages you select for installation)
  should be subdomain of DOMAIN.

### Configure (log into) `aws`

```bash
aws configure
```
Follow the prompts, filling in your AWS IAM's credentials.

### Obtain an EKS cluster

TAP will be installed into an EKS cluster. You can either create a new cluster, or use an existing one.

#### Option 1: Create an EKS cluster on AWS

To create a brand-new cluster:

```bash
./aws-create-eks-cluster.sh
```
If you have not set all the required environment variables, then you will be prompted for the values.

If successful, the cluster creation should take approximately 20 minutes.

Note that this step modifies your `~/.kube/config` file to contain a Kubernetes Context that points to the new cluster,
and also sets the current context to it.  You can verify that by typing:

```
kubectl config get-contexts
```

#### Option 2: Use an existing EKS cluster

To connect to an existing cluster:

_NOTE_: For instructions on how to grant permissions to a cluster for a new user, 
see this: <https://docs.aws.amazon.com/eks/latest/userguide/add-user-role.html>_

Navigate the AWS Console Elastic Kubernetes Service page, click on *Clusters*, and find the name of the cluster
you want to install TAP into. Then:
```
aws eks update-kubeconfig <CLUSTER_NAME>
```

### Install TAP in the EKS cluster

```
./setup-tap.sh
```
If you have not set all the required environment variables, then you will be prompted for the values.

Remember to re-execute the script if it errors out because of timeouts on the first couple tries.
On subsequent runs, to save time, you can (but do not have to) add the `--skip-init` flag, 
if the steps prior to installing TAP packages have run.

The script will output a bunch of useful information upon a successful install.
Keep this in a terminal as it will be useful.

Sit back and relax ... If successful, the entire installation process should take approximately 20 minutes.

### Configure AWS Route 53 DNS records

This will configure DNS records in an AWS Hosted Zone.
```
./aws-configure-dns.sh
```
A caveat about DNS lookup: The DNS entries might take a long time to propagate.
I've had best luck with quick propagation by setting my DNS server to 8.8.8.8 (Google's DNS server).
Also, make sure you are not on a VPN as in this case your locally configured DNS server may not be used.

### Use TAP

NOW you can follow the Getting Started guide from the installation documentation.

### (Optional) Re-install TAP

Delete tap:
```
tanzu package installed delete tap -n tap-install
```
Then go back to the `./setup-tap.sh` step.

### (Optional) Destroy the cluster

To limit AWS cost, then after deleting your TAP installation, you can destroy the entire AWS EKS cluster.
```
./aws-delete-eks-cluster.sh
```
You should also delete the DNS entries, as they are no longer valid:
```
./aws-delete-dns.sh
```

#### Known Issues

##### _The AWS cluster fails to delete completely_

For example, some AWS objects 
(i.e. CloudFormation) might not delete. In this case you will need to use the AWS Console to find 
the orphaned objects and delete them manually. This can be a tedious task.

**More details:**

If the `aws-delete-eks-cluster.sh` script reports success, but you cannot re-create the cluster again
with the same name, and the error message indicates there is an existing stack (or service) of the name the script is 
trying to create:
1. Give it a couple minutes. It might be still in-process of deletion.
2. If the error persists, the probable cause is that some resources associated with the deleted cluster
   have been orphaned. In order to re-create the cluster with the same name, they need to be deleted.

The following steps use the AWS console (console.aws.com).

First, find the VPC associated with the cluster you previously deleted:
Go to AWS console / VPCs / Your VPCs. You can identify the target VPC by name. 
Make a note of its ID, as it will be useful in identifying other objects to delete.

The following additional steps are in order of the dependencies, so they should work most of the time.
Your Mileage May Vary! 
If you have trouble, the general strategy is: delete resources from the bottom up in the dependency hierarchy.
The AWS Console will _sometimes_ give you hints.

1. Try to delete LoadBalancers:  Go to AWS console / EC2, and select Load Balancers on the left.
   Identify the Load Balancers with the VPC ID you noted above, and try to delete them.

2. Try to delete VPCs:  Go to AWS console / VPCs / Your VPCs. Identify the VPC to delete. Delete it.

3. Try to delete CloudFormation instances: Go to AWS console / Cloud Formation.
   Find the stacks that were associated with your cluster.  You should be able to identify them by name.
   They will also have a tag with key =  `eksctl.cluster.k8s.io/v1alpha1/cluster-name`, value = `cluster name`

   Try to delete them.  If there are two stacks and one of them is the worker-nodes stack, delete that one first.

