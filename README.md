## Setting up Tanzu Application Platform on a local machine

These are scripts I've used to set up Beta 1 of
Tanzup Application Platform (TAP) on a local VM using
[Kind](https://kind.sigs.k8s.io/) for the Kubernetes cluster.

Any machine needs to have at least 4 CPUs, 16 GB of memory and around
30 GB of disk.

For more information see
[the official documentation](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/0.1/tap-0-1/GUID-overview.html)
or the excellent
[series of blog posts](https://tanzu.vmware.com/developer/blog/getting-started-with-vmware-tanzu-application-platform-beta-1-on-kind-part-1/).

There are two scripts here:

* `kind-with-registry.sh`
* `setup-tap.sh`

The first sets up a Kind cluster (named `tap`) which has port forwarding
to ports 80, 443 and 53.
The DNS (port 53) forwarding is probably not necessary but could be used
to hook into the cluster DNS.
The HTTP/S ports will expose applications deployed on TAP vi `*.vcap.me`
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

You will also need a login to the Tanzu Network and access to a Docker registry (e.g.
DockerHub) to which you can push container images.

After the setup script completes you should have a fully functioning TAP
installation, ready to build and run applications.

### Using TAP

Port forwarding will have been set up so that the Application Accelerator should
be accessible on http://localhost:8877 and App Live View on http://localhost:5112.

The TAP components are configured to work primarily in the `tap-install`
namespace.

You can create a Git-triggered image build using `kp` like this (assuming you
have the source for the Spring Petclinic app at https://github.com/somebody/spring-petclinic
and access to a container registry at repo.example.com/somebody):

```bash
kp image create petclinic \
  --tag repo.example.com/somebody/petclinic \
  --git https://github.com/example/spring-petclinic \
  -n tap-install
```

You can then run the application, once it has built, as follows:

```bash
kn service create petclinic \
  -n tap-install
  --image repo.example.com/somebody/petclinic \
  --scale-min=1 \
  --label tanzu.app.live.view=true \
  --label tanzu.app.live.view.application.name=petclinic
```

This will result in the app being run and exposed at
http://petclinic.tap-install.vcap.me. 
