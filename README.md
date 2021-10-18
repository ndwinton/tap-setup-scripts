## Setting up Tanzu Application Platform on a local machine

These are scripts I've used to set up beta versions of
Tanzu Application Platform (TAP) on a local VM using
[Kind](https://kind.sigs.k8s.io/) for the Kubernetes cluster.

From the pre-requisites of Beta 2 for Kind on Linux:

> Minimum requirements: 8 CPUs for i9 or equivalent, 12 CPUs for i7 or
> equivalent, 8 GB RAM (12+ GB recommended), and 120 GB disk space.

For more information see
[the official documentation](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/0.2/tap-0-2/GUID-overview.html).

There are three scripts here:

* `kind-with-registry.sh`
* `setup-tap.sh`
* `install-prereqs.sh`

The first sets up a Kind cluster (named `tap`) which has port forwarding
to ports 80, 443 and 53.
The DNS (port 53) forwarding is probably not necessary but could be used
to hook into the cluster DNS.
The HTTP/S ports will expose applications deployed on TAP via `*.vcap.me`
URLs (all lookups of `vcap.me` addresses resolve to 127.0.0.1).

The second script sets up the entire TAP installation, including
the Tanzu Build Service.
It assumes that all of the necessary CLI tools have been installed prior
to running the script.
These tools are:

* `docker`, `kubectl` and `kind`.
* The tools from [carvel.dev](https://carvel.dev) (`ytt`, `kbld`, `kapp`,
  `imgpkg` and `vendir`.
* The `kp` [kpack CLI](https://github.com/vmware-tanzu/kpack-cli).
* The `kn` [Knative CLI](https://github.com/knative/client).
* The `tanzu` CLI from the [Tanzu Network](https://network.tanzu.vmware.com/products/tanzu-application-platform/).

If you do not have these tools installed you can use the third script,
`install-prereqs.sh` to install them.

You will also need a login to the Tanzu Network and access to a Docker registry (e.g.
DockerHub) to which you can push container images.

The script will prompt you for Tanzu Network and registry credentials, but
you can also set these as environment variables and it will pick them
up automatically.
If set, values will be taken from `TN_USERNAME` and `TN_PASSWORD` for
the Tanzu Network and `REGISTRY`, `REG_USERNAME` and `REG_PASSWORD` for
the registry.

After the setup script completes you should have a fully functioning TAP
installation, ready to build and run applications.

If the installation fails at any point it should be safe to re-run the setup
script.
In particular, the initial installation of the Tanzu Build Service component
may time out, although it is likely to complete successfully in the background.

#### Use with DockerHub

Unlike other container registries, DockerHub does not support
hierarchical registry paths.
This means that the initial registry path that you specify, for
example `some-user/tap` will only be the path for the Tanzu Build
Service images.
Any new application created with the build service will appear
as a new registry beneath your user account, for example,
`some-user/my-new-app`.

#### Use with Google Container Registry (GCR)

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

### Using TAP

Port forwarding will have been set up so that the Application Accelerator should
be accessible on http://localhost:8877 and App Live View on http://localhost:5112.

The TAP components are configured to work with applications deployed primarily in
the `default` namespace.

You should be able to follow the
[Getting Started guide](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/0.2/tap-0-2/GUID-getting-started.html)
to deploy your first application to the platform.

