consumer_rg=glb-lab
consumer_location=centralus
consumervnetcidr="10.30.0.0/16"
consumersubnet="10.30.1.0/24"
mypip=$(curl -4 ifconfig.io -s) # or replace with your home public ip, example mypip="1.1.1.1" (required for Cloud Shell deployments)
username=""
password=""

# Create the resource group
az group create --name $consumer_rg --location $consumer_location
# Create the consumer vnet
az network vnet create --resource-group $consumer_rg --name consumer-vnet --location $consumer_location --address-prefixes $consumervnetcidr --subnet-name vmsubnet --subnet-prefix $consumersubnet

# Create the NSG Rule to allow your IP ssh access
az network nsg create --resource-group $consumer_rg --name consumer-nsg --location $consumer_location
az network nsg rule create \
    --resource-group $consumer_rg \
    --nsg-name consumer-nsg \
    --name allow-http \
    --direction Inbound \
    --priority  101 \
    --source-address-prefixes '*' \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges 80 \
    --access Allow \
    --protocol Tcp \
    --description "Allow inbound HTTP" \
    --output none
az network vnet subnet update --name vmsubnet --resource-group $consumer_rg --vnet-name consumer-vnet --network-security-group consumer-nsg

# Get the subnet id
subnetid=$(az network vnet show -g $consumer_rg -n consumer-vnet -o tsv --query "subnets[?name=='vmsubnet'].id")

# Create an AKS cluster
az aks create \
-g $consumer_rg \
-n consumer-aks \
-l $consumer_location \
--vnet-subnet-id $subnetid

# Get cluster credentials
az aks get-credentials -g $consumer_rg -n consumer-aks

# Deploy a test app
kubectl apply -f nginx.yaml

# Provision the provider
provider_rg=glb-lab
provider_location=centralus
providervnetcidr="10.40.0.0/24"
providerexternalcidr="10.40.0.0/27"
providerinternalcidr="10.40.0.32/27"
providerbastionsubnet="10.40.0.64/27"
nva=provider-nva
mypip=$(curl -4 ifconfig.io -s) # or replace with your home public ip, example mypip="1.1.1.1" (required for Cloud Shell deployments)

# Create the provider resource group
az group create --name $provider_rg --location $provider_location --output none

# Create the provider vnet and subnets
az network vnet create --resource-group $provider_rg --name provider-vnet --location $provider_location --address-prefixes $providervnetcidr --subnet-name external --subnet-prefix $providerexternalcidr --output none
az network vnet subnet create --name internal --resource-group $provider_rg --vnet-name provider-vnet --address-prefix $providerinternalcidr --output none

# Deploy the OPNsense NVA
az deployment group create --name $nva-deploy-$RANDOM --resource-group $provider_rg \
--template-file ./bicep/glb-active-active.json \
--parameters virtualMachineSize=Standard_B2s virtualMachineName=$nva TempUsername=azureuser TempPassword=Msft123Msft123 existingVirtualNetworkName=provider-vnet existingUntrustedSubnet=external existingTrustedSubnet=internal PublicIPAddressSku=Standard

# Get the app ip from AKS
appip=$(kubectl get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Curl the app 
while true; do curl $appip && sleep 5; done;

# Get the Gateway Load Balancer Frontend IP ID
glbfeid=$(az network lb frontend-ip show -g $provider_rg --lb-name provider-nva-glb --name FW --query id --output tsv)

# Get the Kubernetes Service Public IP
managedcluster_rg=$(az aks show -g $consumer_rg -n consumer-aks -o tsv --query nodeResourceGroup)
appip_name=$(az network public-ip list -g $managedcluster_rg -o tsv --query "[?ipAddress=='$appip']".name)

# Get the cluster identity
cluster_principal=$(az aks show -g EphGWLBLAB -n consumer-aks -o tsv --query 'identity.principalId')
cluster_objid=$(az ad sp show --id $cluster_principal -o tsv --query objectId)

# Grant the cluster identity rights on the GWLB
az role assignment create --assignee-object-id $cluster_objid \
--role 'Contributor' \
--scope $glbfeid 

# Add the gateway load balancer to the application public IP
az network lb frontend-ip update \
-g $managedcluster_rg \
--name ${appip_name:11} \
--lb-name kubernetes \
--gateway-lb $glbfeid 


# Remove the gateway load balancer from the application public IP
# az network lb frontend-ip update \
# -g $managedcluster_rg \
# --name ${appip_name:11} \
# --lb-name kubernetes \
# --gateway-lb ""


# Install Agones (https://agones.dev/site/docs/installation/install-agones/yaml/)
kubectl create namespace agones-system
kubectl apply -f https://raw.githubusercontent.com/googleforgames/agones/release-1.23.0/install/yaml/install.yaml

# Deploy a Game Server (https://agones.dev/site/docs/getting-started/create-gameserver/)
kubectl create -f https://raw.githubusercontent.com/googleforgames/agones/release-1.23.0/examples/simple-game-server/gameserver.yaml

# Get the Game Name Server IP and port
gameservername=$(kubectl get gs -o jsonpath='{.items[0].metadata.name}')
gameservernodename=$(kubectl get gs -o jsonpath='{.items[0].status.nodeName}')
gameserverip=$(kubectl get gs -o jsonpath='{.items[0].status.address}')
gameserverport=$(kubectl get gs -o jsonpath='{.items[0].status.ports[0].port}')

# Test the Game Server
# After running this command you can type messages in the terminal and they 
# will be echoed by the game server via netcat
kubectl run netcat -it --rm --image=busybox -- nc -u $gameserverip $gameserverport

# Create the gameserver public IP
az network public-ip create \
--resource-group $consumer_rg  \
--name $gameservernodename \
--sku Standard

az network lb create \
--resource-group $consumer_rg \
--name gameserver-lb \
--sku Standard \
--public-ip-address $gameservernodename

az network lb address-pool address add \
-g $consumer_rg \
--lb-name gameserver-lb \
--pool-name gameserver-lbbepool \
-n $gameservernodename \
--vnet consumer-vnet \
--ip-address $gameserverip


# Create the NAT rule for the game server
az network lb inbound-nat-rule create \
-g $consumer_rg \
--lb-name gameserver-lb \
--name $gameservername \
--protocol udp \
--backend-pool-name gameserver-lbbepool \
--frontend-port-range-start $gameserverport \
--frontend-port-range-end $gameserverport \
--backend-port $gameserverport

# Get the public IP
gameserverpubip=$(az network public-ip show --resource-group $consumer_rg --name $gameservernodename -o tsv --query ipAddress)

# Netcat through the SLB NAT Rule
nc -u $gameserverpubip $gameserverport