# oracle-rac-213
Oracle RAC in Kubernetes Cluster Deployment

This article covers the necessary and sufficient steps to run and configure RAC 21.3 on a kubernetes 1.26 cluster. There were no precedents for April 2023 work outside of Oracle Cloud, so thousands of experiments had to be carried out, many hypotheses were discarded and accepted.
Today, the world's first rollout of RAC in kubernetes and without docker.
```
uname -a
Linux r02 5.4.17-2136.300.7.el8uek.x86_64 #2 SMP Fri Oct 8 16:23:01 PDT 2021 x86_64 x86_64 x86_64 GNU/Linux
containerd --version
containerd github.com/containerd/containerd v1.6.4 212e8b6fa2f44b9c21b2798135fc6fb7c53efc16
runc --version
runc version 1.0.2
spec: 1.0.2-dev
go: go1.16.7
libseccomp: 2.5.1
```
OEL 8.5 is already certified for Oracle RAC, 7.9 does not need to be installed.
The main tasks of setting up a RAC rollout:

 1. Creating and configuring subnets in a kubernetes cluster
 2. Settings:
    - kubernetes worker node kernel
    - RAC container kernel, namespaced and read only.
 3. Selecting and configuring the RAM used by RAC
 4. Setting up shared RAC storage in kubernetes.

This rollout is not the only possible configuration, it is the simplest example of a working solution. Deployment of development and test environments can be achieved in a relatively simple way. For production setup, you should use other approaches in configuring and reserving shared partitions.

Due to the deprecation of podSecurityPolicy from version 1.23, some of the settings are done in the namespace.

# Create networks and adapters
Public and private RAC networks, historically required from 2 adapters, virtual ones are also suitable, will not work with fewer adapters.
In my opinion, any CNI can be configured to add additional adapters to a container at startup.
To reduce implementation time, I use cncf approved multus solution. When deploying multus CNI in a kubernetes cluster, I advise you to pay attention to the possibility of deploying only on nodes where RAC containers will run. Even in the absence of annotations in manifests, no containers may start due to incorrect settings after rolling out multus CNI. Immediately pay attention to the file /etc/cni/net.d/00-multus.conf

 { "cniVersion": "0.3.1", "name": "multus-cni-network", "type": "multus", "capabilities": {"portMappings": true}, "kubeconfig": "/etc/cni/net.d/multus.d/multus.kubeconfig", "delegates": [ { "cniVersion": "0.3.1", "name" ……
This may work in future versions of containerd, but today every time a kubernetes node is started, this file is updated and cniVersion must be 0.3.1 to work correctly.

# Add network definitions:

I specifically wrote the mtu 1500 for a private network knowing jumbo packets are required with the mtu 9000 and we would get a warning when deploying the grid in the logs. There is nothing wrong with this, it's just that this setup will require a lot of work that is not included in the current plans. It may well turn out that 20% speedup when using jumbo packets will not affect the overall performance.
spec. securityContext:sysctls: this is where you can declare some of the kernel parameters for use in the container, the rest can be set at the level of the kubernetes worker node.
To do this, use featureGates on the worker node, add the line to the /var/lib/kubelet/config.yaml file:
allowedUnsafeSysctls: [kernel.shm*, kernel.sem, net.*]
Add to file /etc/kubernetes/manifests/kube-apiserver.yaml
--feature-gates=ProcMountType=true
The kubernetes server API will restart within a few minutes, the cluster API resources will be unavailable. At this point, it is important to understand what and why you are doing, otherwise you may lose your kubernetes cluster.
Restart kubelet, swap should still be disabled up to this point.
You can not perform this step, just add all sysctl at the host level to /etc/sysctl.conf and sysctl -p, a matter of perfectionism. Everything required by the official Oracle documentation should also be added there.
To speed up image loading (20Gi), it is better to configure any local image registry.
Then:
podman pull container-registry.oracle.com/database/rac:21.3.0.0
podman push --tls-verify=false  docker-service.docker-registry:5000/container-registry.oracle.com/database/rac:21.3.0.0
To set up a mirror registry in config.toml add the name and port of your registry:

      [plugins."io.containerd.grpc.v1.cri".registry.configs]
        [plugins."io.containerd.grpc.v1.cri".registry.configs."cr.local:32424"]
          [plugins."io.containerd.grpc.v1.cri".registry.configs."cr.local:32424".tls]
            insecure_skip_verify = true

      [plugins."io.containerd.grpc.v1.cri".registry.headers]

      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."cr.local:32424"]
          endpoint = ["https://cr.local:32424"]
          
In this example, podman is running in its own container and the storage port is used on the kubernetes cluster network, while containerd is running on the host network, so we see the port from the podman deployment service in kubernetes.
securityContext:
privileged: true
There is no mistake here, it is at the container level that the second securityContext block is declared. When compared with the official Oracle docker configuration, a significant difference in the operation of docker and kubernetes.

# Configuring RAM settings

The total amount of RAM on the described stand is not very large - 20Gb, the recommended minimum amount of 16Gb for a pod seems normal. Also, kube-proxy, flannel, multus are required to work on the node, container registry is not required to work on the node, saves time only.
It is very important to decide on what equipment you can and should use huge pages. In my personal opinion, based on Oracle recommendations, the officially defined value vm.nr_hugepages=16384 should not be used on servers with less than 64Gb of physical RAM. You can try, most likely the Oracle database will not start. Just don't use it:
sysctl vm.nr_hugepages=0
The Oracle database server will automatically switch to regular pages, which should be sufficient. Then you should correlate the size of the SGA and the allocated area /dev/shm. Here they are 3.8Gb and 4Gb, respectively.
Don't forget to disable transparent huge pages in all cases:
sudo echo never > /sys/kernel/mm/transparent_hugepage/enabled
It is better to do this at the GRUB level in advance.

# Preparing to run install grid infrastructure

In common_scripts create sh file.
Rename ntp.conf file to avoid cvu error. It is not clear why he appeared in this image.
Encrypting the initial password and placing the private key is described in the Oracle documentation, just put those files here.
Next comes a trick. It is not yet possible to display all the necessary kernel parameters, so that cvu check is clean, copy the plot to a regular file system
sudo cp -r /proc/sys/net /home/<…>
In this batch file, mount --bind will successfully mount this piece in /proc of the container and we won't see any cvu errors or container logs.
kernel.sched_rt_runtime_us=-1 on this "-1" here, to be honest, everything is established :) This parameter allows container root processes to run processes with RT priority. ASM from version 19.3 will not work differently. 18.3 still works.
The system must be booted with DefaultCPUAccounting=no in /etc/systemd/system.conf Otherwise realtime won't work in the container.
/etc/security/limits.conf contains an unrealistic memlock value of 128Gb, the database will not start, so for a 20Gb system for everything, we will allocate 8Gb for ASM and 8Gb for Oracle.
Chronyd replaced ntp and it starts here.

This file should be executed in the first 60 seconds of the container's operation, for which time is allocated there.

kubectl -n oracle-rac-213 exec -it oracle-rac-213-0 -- bash /oradata/scripts/ini.sh

# Shared Storage

Deploy 1 or more nfs servers to share a catalog with storage files. If you have specialized NAS equipment, you can miss a lot here.
Prepare 2 or more files on nfs servers according to Oracle documentation.
I use a slightly different but very fast solution:
cd /home/oracle-rac-213/
sudo fallocate -z -o 0 -l 23G asm_disk01.img
sudo fallocate -z -o 0 -l 23G asm_disk02.img
sudo fallocate -z -o 0 -l 23G asm_disk03.img
sudo fallocate -z -o 0 -l 23G asm_disk04.img
sudo fallocate -z -o 0 -l 23G asm_disk05.img
The presence of zero blocks is stored in the file system metadata.
On the kubernetes worker node, mount the shared directory:
mkdir -p /mnt/ora
mount -t nfs 192.168.1.4:/home/oracle-rac-213 /mnt/ora
Mount each file as a device:
losetup -f /mnt/ora/asm_disk01.img
… Etc.

Now we can declare all persistent volumes.

Everything must be applied.
Persistent volume claims are declared in the statefulset manifest.

# Settings

I do not explicitly specify the DNS server, Oracle's normal mode of operation, it will focus on resolv.conf, then cluster dns. The main thing in this chain is to indicate the correspondence of host names from this list and their addresses, for SCAN, specify all 3 addresses 172.16.1.70 - 172.16.1.72. I used a dns server from a network domain external to the kubernetes cluster, so I had to specify everything 2 times with and without a domain. The domain name in the container is formed according to the rules of kubernetes: oracle-rac-213.svc.cluster.local

# Enabling swap
```
sudo fallocate -l 32G /swap.img
sudo chmod 600 /swap.img
sudo mkswap /swap.img
sudo swapon /swap.img
```
# Launch and monitoring
Apply all manifests from namespace creation to statefulset.

Your system will require additional configuration for accessing the database from outside the cluster. CMAN is an option and can and should be configured additionally.

Let's execute inside the container:
[grid@oracle-rac-213-0 ~] $ crsctl check crs
```
CRS-4638: Oracle High Availability Services is online
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
```
[grid@oracle-rac-213-0 ~] $ crsctl status resource -w "TYPE co ’ora’" -t
```
--------------------------------------------------------------------------------
Name           Target  State        Server                   State details
--------------------------------------------------------------------------------
Local Resources
--------------------------------------------------------------------------------
ora.LISTENER.lsnr
               ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.chad
               ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.net1.network
               ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.ons
               ONLINE  ONLINE       oracle-rac-213-0         STABLE
--------------------------------------------------------------------------------
Cluster Resources
--------------------------------------------------------------------------------
ora.ASMNET1LSNR_ASM.lsnr(ora.asmgroup)
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.DATA.dg(ora.asmgroup)
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.LISTENER_SCAN1.lsnr
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.LISTENER_SCAN2.lsnr
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.LISTENER_SCAN3.lsnr
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.asm(ora.asmgroup)
      1        ONLINE  ONLINE       oracle-rac-213-0         Started,STABLE
ora.asmnet1.asmnetwork(ora.asmgroup)
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.cdp1.cdp
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.cdp2.cdp
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.cdp3.cdp
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.cvu
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.oracle-rac-213-0.vip
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.orclcdb.db
      1        ONLINE  ONLINE       oracle-rac-213-0         Open,HOME=/u01/app/o
                                                             racle/product/21.3.0
                                                             /dbhome_1,STABLE
ora.orclcdb.orclpdb.pdb
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.qosmserver
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.scan1.vip
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.scan2.vip
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
ora.scan3.vip
      1        ONLINE  ONLINE       oracle-rac-213-0         STABLE
--------------------------------------------------------------------------------
```
