# Setting up your own Tanzu Application Platform cluster

These are scripts that can be used to set up a version of
Tanzu Application Platform (TAP) on your own cluster.

The process of installing TAP is described in the
[official documentation](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/index.html).
It is not particularly difficult, but you may find that these scripts
save you some time if you just want to get something up and running
quickly.
In particular, they will take care of installing the necessary
pre-requisites and will generate configuration files that you
may later refine if you wish.

The scripts work on Linux and macOS (and even under WSL on Windows).
They are known to work with:

* [Minikube](https://minikube.sigs.k8s.io/) on macOS
* [Kind](https://kind.sigs.k8s.io/) on a Linux VM (and at some points,
  Docker Desktop on macOS)
* [Amazon EKS](https://aws.amazon.com/eks/)
* [Google GKE](https://cloud.google.com/kubernetes-engine)

Specific instructions for EKS are in
[README_AWS_EKS.md](README_AWS_EKS.md).

It may also work (but is less tested) on TCE and TKG.
There are some specific addtional steps for
[TCE](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.0/tap/GUID-install-tce.html)
and
[TKG](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.0/tap/GUID-install-tkg.html)
steps that the setup script does not handle.
It attempts to detect whether it is running against a TCEor TKG cluster
and to notify you of the additional work that needs to be done.

The script is known to work with DockerHub, Harbor and GCR for the container
registry.
It is also possible to use a completely local registry with
Kind, and that should also be possible (but has not been tested)
with Minikube.

As far as resources are concerned, from the pre-requisites in the
[the official documentation](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.0/tap/GUID-install-general.html):

> To deploy all Tanzu Application Platform packages your cluster must
> have at least 8 GB of RAM across all nodes available to Tanzu
> Application Platform. At least 8 CPUs for i9 or equivalent or 12 CPUs
> for i7 or equivalent must be available to Tanzu Application Platform
> components. VMware recommends that at least 16 GB of RAM is available
> to build and deploy applications, including for Kind and Minikube.

## What do the scripts do?

There are three main scripts here:

* `install-prereqs.sh` (or `install-prereqs-macos.sh` for macOS)
* `kind-with-registry.sh`
* `setup-tap.sh` (with `functions.sh`)

### `install-prereqs.sh`

The first script , `install-prereqs.sh`, installs the necessary CLI tools on
64-bit AMD/Intel Ubuntu-like Linux systems (including WSL under Windows).
These tools are:

* `docker`, `kubectl` and `kind`.
* The tools from [carvel.dev](https://carvel.dev) (`ytt`, `kbld`, `kapp`,
  `imgpkg` and `vendir`.
* The `kp` [kpack CLI](https://github.com/vmware-tanzu/kpack-cli).
* The `kn` [Knative CLI](https://github.com/knative/client).
* The `tanzu` CLI from the [Tanzu Network](https://network.tanzu.vmware.com/products/tanzu-application-platform/).

There is an equivalent script for (Intel-based) macOS which uses
the [Brew](https://brew.sh) package manager to install the tools.

### `kind-with-registry.sh`

If you wish to create and use Kind for your Kubernetes environment then
the second script sets up a Kind cluster (named `tap`) which has port
forwarding to ports 80, 443 and 53.
The DNS (port 53) forwarding is probably not necessary but could be used
to hook into the cluster DNS.
The HTTP/S ports will enable applications deployed on TAP via `*.vcap.me`
URLs (all lookups of `vcap.me` addresses resolve to 127.0.0.1).

The script also creates a local container registry and configures
the cluster to trust it.

### `setup-tap.sh`

The main script is `setup-tap.sh` (which also uses shell functions
defined in `functions.sh`).

The core part of the TAP installation is actually only a single
command: `tanzu package update --install ...`.
However, most of the work of the setup script is in preparing
the environment for this and in creating the necessary configuration
file(s).

The script will prompt you for key information (if you have not
set environment variables to supply it automatically) and it
will generate a "sensible" configuration based on the options
that you choose.

#### Credentials

You will need a login to the Tanzu Network and access to a Docker
registry (e.g. DockerHub) to which you can push container images.

The script will prompt you for Tanzu Network and registry credentials, but
you can also set these as environment variables and it will pick them
up automatically.
If set, values will be taken from `TN_USERNAME` and `TN_PASSWORD` for
the Tanzu Network and `REGISTRY`, `REG_USERNAME` and `REG_PASSWORD` for
the registry.

#### Profiles and packages

The TAP package supports the concept of installation
profiles, and the script reflects this too.
You can specify that you want to use the 'full' or 'dev' profiles
supported by TAP, when prompted, or set the `INSTALL_PROFILE`
environment variable.

In addition, you can use the script to do an "unbundled" install
and just pick the packages that you want, for example, just
installing Cloud-Native Runtimes and Tanzu Build Service along
with a basic supply chain.
The script should take care of installing pre-requisite packages in
this case, but this is not thoroughly tested.

Note that you cannot mix the TAP profiles with the selection of
individual packages that form part of those profiles.

#### Other information

The script will also prompt for the location of a catalog file to
use with the TAP GUI as well as the choice of supply chain.

By default, the script assumes an installation on a local cluster,
such as Kind or Minikube, where services will be accessed via the
`localhost` address.
However, it can also be used for an installation on to a full,
externally-accessible cluster.
In order to enable this you should set the `DOMAIN` environment
variable (or supply a value when prompted) to something other than
the default of `vcap.me`.

There are further descriptions of the environment variables that
you can use to control the script both in the messages written out
by the script and within the `envrc-template` file.

After the setup script completes you should have a fully functioning TAP
installation, ready to build and run applications.

### Re-running the script

If the installation fails at any point it should be safe to re-run the setup
script.
If the installation of the main `tap` package fails, but steps prior
to that succeeded, you can re-run the script with the `--skip-init`
option to omit earlier actions that do not have to be re-run.

### Use with DockerHub

Unlike other container registries, DockerHub does not support
hierarchical registry paths.
This means that the initial registry path that you specify, for
example `some-user/tap` will only be the path for the Tanzu Build
Service images.
Any new application created with the build service will appear
as a new registry beneath your user account, for example,
`some-user/my-new-app`.

### Use with Google Container Registry (GCR)

If you intend to use the setup script with a `gcr.io` registry then
you will need an JSON-formatted access key and must use `_json_key`
as the username.
The easiest way to provide the information to the setup script
is to export environment variables, for example, as follows:

```bash
export REGISTRY=gcr.io/my-project-name/tap
export REG_USERNAME=_json_key
export REG_PASSWORD="$(cat gcr-access-key.json)"
```

### Using Amazon EKS

There are some additional "helper" scripts that you can use to
set up a cluster and configure DNS.
There are described in the [README_AWS_EKS.md](README_AWS_EKS.md) file.

## Using TAP

For a local installation, port forwarding will have been set up so that
the GUI should be accessible on http://gui.vcap.me:7000.

If you used the setup script for Kind that should have caused Docker to
forward traffic so that apps will be accessible on the URL shown
by `tanzu apps workload get ...`, for example:
http://some-app-name.default.apps.vcap.me.

However, port forwarding will also be set up to port 8080 so that
http://some-app-name.default.apps.vcap.me:8080 should also work if
it wasn't possible to bind to port 80.

If you deploy to a publicly accessible cluster (not using `vcap.me` as
the domain name) you will need to do the work to map DNS names to the
various load balancers created.
The script will print out these mappings when it completes.

The TAP components are configured to work with applications deployed primarily in
the `default` namespace.

You should be able to follow the
[Getting Started guide](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.0/tap/GUID-getting-started.html)
to deploy your first application to the platform.

