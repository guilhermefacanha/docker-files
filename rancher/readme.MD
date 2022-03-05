# Install Rancher
https://rancher.com/docs/rancher/v2.x/en/installation/other-installation-methods/single-node-docker/advanced/

``` shell

sysctl -w net/netfilter/nf_conntrack_max=131072
docker run -d --name rancher --restart=unless-stopped -p 80:80 -p 443:443 -e NO_PROXY="localhost,127.0.0.1,0.0.0.0,10.43.0.1,.mydomain.net,{localip range}/16,10.43.0.1/16"  --privileged -v /opt/rancher:/var/lib/rancher -v /host/rancher:/var/lib/rancher rancher/rancher:latest

```

## Adicionar Cluster/Nodes

Global -> Add Cluster -> Existing Nodes
 - Cluster Name: `<qualquer>`
 - Kubernetes Options:
   - Network Provider: Weave

## Adicionar Credencial DockerHub

Open Cluster -> 


#After Install

Setting a Private Registry with Credentials when Deploying a Cluster

You can follow these steps to configure a private registry when you provision a cluster with Rancher:

    When you create a cluster through the Rancher UI, go to the Cluster Options section and click Show Advanced Options.
    In the Enable Private Registries section, click Enabled.
    Enter the registry URL and credentials.
    Click Save.


kubectl edit deployment cattle-cluster-agent -n cattle-system
...
dnsPolicy: Default