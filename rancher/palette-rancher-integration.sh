#!/bin/bash

# ------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------

# - Import Host cluster into Rancher (if not created and already available in Rancher)
# - Import Host Cluster into Tenant Admin Prject - So we can create Virtual Cluster on that host
# - Create a Project in Palette
# - Create a Cluster Group in Tenant Admin (if you're cluster was also imported into Tenant Admin)
# - Rancher CLI
# - Kubectl 

# Required files (these file names are configurable in the section below): 
# - create-vc.json (must contain create-vc.json contents)
# - create-import-cluster.json (must contain create-import-cluster.json contents)
# - palette-virtual-cluster-host.yaml (must contain kube-config for host cluster, name can be changed in PALETTE_HOST_KUBE_CONFIG)

# ------------------------------------------------------------
# Variables
# ------------------------------------------------------------

# Run-time parameters, can be used to customise the script when run. All variables have a default value. 
VIRTUAL_CLUSTER_NAME=${1:-test} # Default = test
IMPORTED_VC_CLUSTER_NAME_IN_RANCHER=${2:-imported-$VIRTUAL_CLUSTER_NAME} # Default = imported-test
CLUSTER_GROUP_UID=${3:-651f188154ff39db2} # CHANGE default to match one of your existing cluster group ID's

# Virtual Cluster size, default: 4 CPU, 6GB RAM, 2GB DISK
VC_CPU=${4:-4}
VC_MEMORY_MB=${5:-6144}
VC_STORAGE_GB=${6:-2}

# Palette variables
PALETTE_API_KEY='ADD-API-KEY' # CHANGE
PALETTE_PROJECT_UID='64d6c8d744ed4' # CHANGE
PALETTE_HOST_KUBE_CONFIG=palette-virtual-cluster-host.yaml
PALETTE_API_ENDPOINT='https://api.spectrocloud.com/v1'

# Virtual Cluster Namespace labels. Test label for a fake user.
USER=bob

# Host cluster
HOST_CLUSTER_NAME_IN_RANCHER='virtual-cluster-host-org' # CHANGE


# Rancher variables
RANCHER_PROJECT_NAME_PREFIX='test-project'
RANCHER_URL='https://rancher.example.com'
RANCHER_API_URL="$RANCHER_URL/v3"
RANCHER_BEARER_TOKEN="ADD-BEARER-TOKEN"

# Generated files. 
GEN_CREATE_VC_JSON=gen-create-vc.json
GEN_VC_ADMIN_CONF=gen-vc-admin-kubeconfig.yaml
GEN_VC_UID=gen-vc-uid.txt

# ------------------------------------------------------------
# Create Virtual Cluster
# ------------------------------------------------------------

echo -e "- Creating Virtual Cluster: $VIRTUAL_CLUSTER_NAME \n"

# Read the create-vc.json file. This will contain the template for the VC payload. 
CREATE_VC_JSON=$(cat create-vc.json)

# Ensure the payload is not empty
if [ -z "$CREATE_VC_JSON" ]; then
    echo -e "Payload is empty. Exiting. \n"
    exit 1
fi

# Values used in the script
echo "- Captured parameters:"
echo "-- Virtual Cluster Name: $VIRTUAL_CLUSTER_NAME"
echo "-- New Imported Cluster Name: $IMPORTED_VC_CLUSTER_NAME_IN_RANCHER"
echo "-- Cluster Group UID: $CLUSTER_GROUP_UID"
echo "-- Virtual Cluster resources:"
echo "--- CPU: $VC_CPU"
echo "--- Memory in MB: $VC_MEMORY_MB"
echo -e "--- Disk size: $VC_STORAGE_GB \n"

# Replace the placeholders with the new values and store the result in a new file
sed -e "s/replace-virtual-cluster-name/${VIRTUAL_CLUSTER_NAME}/g" \
        -e "s/replace-cluster-group-uid/${CLUSTER_GROUP_UID}/g" \
        -e "s/replace-cpu/${VC_CPU}/g" \
        -e "s/replace-memory/${VC_MEMORY_MB}/g" \
        -e "s/replace-storage/${VC_STORAGE_GB}/g" \
        create-vc.json > $GEN_CREATE_VC_JSON

GENERATED_CREATE_VC_JSON=$(cat $GEN_CREATE_VC_JSON)

# Make the API call
VC_UID=$(curl -L -X POST "${PALETTE_API_ENDPOINT}/spectroclusters/virtual" \
-H "Content-Type: application/json" \
-H "Accept: application/json" \
-H "apiKey: ${PALETTE_API_KEY}" \
-H "ProjectUid: ${PALETTE_PROJECT_UID}" \
--data-raw "${GENERATED_CREATE_VC_JSON}"  | jq -r '.uid')

# sed -i -e 's/.*"uid":"\([^"]*\)".*/\1/' $GEN_VC_UID - working
# sed -i -e 's/.*"uid":"\([^"]*\)".*/cluster-\1/' $GEN_VC_UID

# VC_UID=$(cat $GEN_VC_UID) - working

# ------------------------------------------------------------
# Get VC kube-config
# ------------------------------------------------------------

# A variable to control the loop
SUCCESS=false

while [ "$SUCCESS" != true ]; do
  # Execute the curl command and save the HTTP status code to a variable
  HTTP_STATUS=$(curl -s -o $GEN_VC_ADMIN_CONF -w "%{http_code}" -L -X GET "$PALETTE_API_ENDPOINT/spectroclusters/${VC_UID}/assets/adminKubeconfig" \
    -H "Content-Type: application/json" \
    -H "Accept: application/octet-stream" \
    -H "apiKey: $PALETTE_API_KEY" \
    -H "ProjectUid: $PALETTE_PROJECT_UID")

  # Check if the HTTP status code is 200
  if [ "$HTTP_STATUS" -eq 200 ]; then
    SUCCESS=true
    echo -e "- Virtual Cluster kube-config successfully received, file saved to $GEN_VC_ADMIN_CONF \n"
  else
    echo "* Waiting for VC. Status $HTTP_STATUS, retrying..."
    sleep 15  # Pause for 10 seconds before retrying
  fi
done

# ------------------------------------------------------------
# Label Virtual Cluster Namespace - test user - this is just an example
# ------------------------------------------------------------

echo -e "- Label Virtual Cluster base namespace via Palette on host cluster with test user Bob - $HOST_CLUSTER_NAME_IN_RANCHER \n"

kubectl --kubeconfig $PALETTE_HOST_KUBE_CONFIG label namespace cluster-$VC_UID vc-cluster-name=$VIRTUAL_CLUSTER_NAME user=$USER

# ------------------------------------------------------------
# Create Rancher Project
# ------------------------------------------------------------

# Get Cluster ID of host cluster in Rancher
CLUSTER_ID=$(curl -s -X GET "$RANCHER_API_URL/clusters?name=$HOST_CLUSTER_NAME_IN_RANCHER" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $RANCHER_BEARER_TOKEN" | jq -r '.data[] | select(.name=="'$HOST_CLUSTER_NAME_IN_RANCHER'") | .id')

# Check if cluster ID was found
if [ -z "$CLUSTER_ID" ]; then
    echo "* Cluster not found! \n"
    exit 1
fi

# JSON Payload
PAYLOAD='{
    "type": "project",
    "name": "'$RANCHER_PROJECT_NAME_PREFIX-$VIRTUAL_CLUSTER_NAME'",
    "clusterId": "'$CLUSTER_ID'"
}'

# Create Rancher Project in host cluster
PROJECT_ID=$(curl -s -X POST "$RANCHER_API_URL/projects" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $RANCHER_BEARER_TOKEN" \
    -d "$PAYLOAD" | jq -r '.id')

# Check if Project was created
if [ "$PROJECT_ID" != "null" ]; then
    echo -e "- Project created with ID: $PROJECT_ID \n"
else
    echo -e "* Failed to create project \n"
fi

# ------------------------------------------------------------
# Import Virtual Cluster Namespace into created Project
# by annotating the VC namespace
# ------------------------------------------------------------

echo -e "- Import Virtual Cluster namespace cluster-$VC_UID into new $RANCHER_PROJECT_NAME_PREFIX-$VIRTUAL_CLUSTER_NAME Rancher Project \n"

# Combine UID with default namespace prefix
VC_NAMESPACE_NAME="cluster-$VC_UID"

# Get Virtual Cluster namespace UID
NAMESPACE_ID=$(curl -s -X GET "$RANCHER_API_URL/clusters/$CLUSTER_ID/namespaces?name=$VC_NAMESPACE_NAME" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $RANCHER_BEARER_TOKEN" | jq -r '.data[] | select(.name=="'$VC_NAMESPACE_NAME'") | .id')

# Check if namespace ID was found
if [ -z "$NAMESPACE_ID" ]; then
    echo -e "* Namespace not found! \n"
    exit 1
fi

echo -e "- Virtual Cluster namespace: $NAMESPACE_ID \n"

# Import Virtual Cluster namespace into the Rancher Project by annotating the namespace
kubectl --kubeconfig $PALETTE_HOST_KUBE_CONFIG annotate namespace $NAMESPACE_ID field.cattle.io/projectId=$PROJECT_ID --overwrite

UPDATED_PROJECT_ID=$(curl -s -X GET "$RANCHER_API_URL/clusters/$CLUSTER_ID/namespaces?name=$VC_NAMESPACE_NAME" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $RANCHER_BEARER_TOKEN" | jq -r '.data[] | select(.name=="'$VC_NAMESPACE_NAME'") | .projectId')

# Check if import was successful
if [ "$UPDATED_PROJECT_ID" == "$PROJECT_ID" ]; then
    echo -e "- Namespace imported into project $RANCHER_PROJECT_NAME_PREFIX-$VIRTUAL_CLUSTER_NAME successfully \n"
else
    echo -e "* Failed to import namespace into project \n"
fi

echo -e "- Rancher Project $RANCHER_PROJECT_NAME_PREFIX-$VIRTUAL_CLUSTER_NAME succesfully annotated with - $UPDATED_PROJECT_ID \n"

# ------------------------------------------------------------
# Import Virtual Cluster into Rancher
# ------------------------------------------------------------

echo -e "- Import Virtual Cluster $VIRTUAL_CLUSTER_NAME into Rancher \n"

# Login and select a project. You need to select a project when loging in, so this forces the login to choose the first choice. 
echo 1 | rancher login $RANCHER_URL --token $RANCHER_BEARER_TOKEN

# Create Generic Imported cluster
rancher cluster create $IMPORTED_VC_CLUSTER_NAME_IN_RANCHER --import

# Wait a short while for the cluster to be available
sleep 15 

# Get kubectl apply command for the new imported cluster
rancher cluster import $IMPORTED_VC_CLUSTER_NAME_IN_RANCHER -q | head -1 > "${IMPORTED_VC_CLUSTER_NAME_IN_RANCHER}-import-command".sh

# Read contents of the apply commands 
IMPORT_COMMAND=$(cat "${IMPORTED_VC_CLUSTER_NAME_IN_RANCHER}-import-command.sh")

echo -e "- Import Command: $IMPORT_COMMAND \n"

# Run kubectl apply command against the Virtual Cluster kubeconfig file
cat ${IMPORTED_VC_CLUSTER_NAME_IN_RANCHER}-import-command.sh | xargs -I {} bash -c "{} --kubeconfig=$GEN_VC_ADMIN_CONF"

echo -e "- Waiting for cluster - $IMPORTED_VC_CLUSTER_NAME_IN_RANCHER to provision \n"

# Wait for imported cluster to come up 
rancher wait $IMPORTED_VC_CLUSTER_NAME_IN_RANCHER

echo "Succesfully completed script"
