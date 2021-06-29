
./cluster-up small.yaml

kubectl apply -f https://github.com/ForgeRock/secret-agent/releases/latest/download/secret-agent.yaml

ingress-controller-deploy.sh --eks

host DOMAIN

certmanager-deploy.sh
kubectl get pods --namespace cert-manager

prometheus-deploy.sh
kubectl get pods --namespace monitoring

aws ecr get-login-password | docker login --username AWS --password-stdin 286867230872.dkr.ecr.ca-central-1.amazonaws.com

skaffold config set default-repo 286867230872.dkr.ecr.ca-central-1.amazonaws.com/forgeops -k jsingheks@small.ca-central-1.eksctl.io

// 7.0 should match the kustomize directory
./config.sh init --profile cdk --version 7.0

// change NS to PROD
kubectl config set-context --current --namespace=prod

cd /path/to/forgeops/kustomize/base/secrets
kubectl apply --filename secret_agent_config.yaml
kubectl get sac

cd /path/to/forgeops
skaffold run --profile small
kubectl get pods // should default to PROD ns

// access secrets
./print-secrets -n prod amadmin

https://prod.iam.example.com/platform
