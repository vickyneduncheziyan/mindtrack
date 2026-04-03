
# Mindtrack — AWS EKS Deployment Guide

A complete step-by-step guide to containerize and deploy a static web application to AWS EKS using Docker, CodeBuild, CodePipeline, and CloudWatch.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Project Structure](#project-structure)
4. [Step 1 — Dockerize the Application](#step-1--dockerize-the-application)
5. [Step 2 — Push Code to GitHub](#step-2--push-code-to-github)
6. [Step 3 — Store Credentials in AWS Parameter Store](#step-3--store-credentials-in-aws-parameter-store)
7. [Step 4 — Create EKS Cluster](#step-4--create-eks-cluster)
8. [Step 5 — Create Kubernetes Manifests](#step-5--create-kubernetes-manifests)
9. [Step 6 — Create CodeBuild Project](#step-6--create-codebuild-project)
10. [Step 7 — Create CodePipeline](#step-7--create-codepipeline)
11. [Step 9 — Verify Deployment](#step-9--verify-deployment)

---

## Architecture Overview

```
Developer pushes code to GitHub
            ↓
    CodePipeline triggered
            ↓
    CodeBuild runs buildspec.yml
    ├── Docker login to Docker Hub
    ├── docker build
    ├── docker push → vickyneduncheziyan/mindtrack:latest
    └── kubectl set image → EKS
            ↓
    New pod rolls out in mindtrack-cluster
            ↓
    CloudWatch captures all logs
```

---

## Prerequisites

| Tool | Purpose |
|---|---|
| AWS Account (Free Tier) | Cloud infrastructure |
| GitHub Account | Source code repository |
| Docker Hub Account | Docker image registry |
| AWS CLI | Interact with AWS from terminal |
| kubectl | Manage Kubernetes cluster |
| eksctl | Create and manage EKS clusters |

### Install required tools

```bash
# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
aws --version

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
kubectl version --client

# Install eksctl
curl --silent --location \
  "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" \
  | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
eksctl version

# Configure AWS CLI
aws configure
# Enter: Access Key ID, Secret Access Key, Region (ap-south-1), Output (json)
```

---

## Project Structure

```
mindtrack/
├── dist/
│   └── index.html          ← your application
├── Dockerfile              ← container definition
├── buildspec.yml           ← CodeBuild instructions
└── k8s/
    ├── deployment.yaml     ← EKS deployment config
    └── service.yaml        ← EKS service config
```

---

## Step 1 — Dockerize the Application

### 1.1 Create the Dockerfile

Create a file named `Dockerfile` in your project root:

```dockerfile
FROM nginx:latest
COPY dist/ /usr/share/nginx/html/
```

### 1.2 Create buildspec.yml

Create `buildspec.yml` in your project root:

```yaml
version: 0.2

phases:
  install:
    commands:
      - echo Installing kubectl...
      - curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
      - chmod +x kubectl && mv kubectl /usr/local/bin/kubectl

  pre_build:
    commands:
      - echo Logging in to Docker Hub...
      - echo $DOCKERHUB_PASSWORD | docker login -u $DOCKERHUB_USERNAME --password-stdin
      - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c1-7)
      - IMAGE_URI=$DOCKERHUB_USERNAME/mindtrack:$IMAGE_TAG
      - echo "IMAGE_URI is $IMAGE_URI"
      - echo Updating kubeconfig...
      - aws eks update-kubeconfig --name mindtrack-cluster --region $AWS_DEFAULT_REGION

  build:
    commands:
      - echo Building Docker image...
      - docker build -t $IMAGE_URI .
      - docker tag $IMAGE_URI $DOCKERHUB_USERNAME/mindtrack:latest

  post_build:
    commands:
      - echo Pushing image to Docker Hub...
      - docker push $IMAGE_URI
      - docker push $DOCKERHUB_USERNAME/mindtrack:latest
      - echo Deploying to EKS...
      - kubectl set image deployment/mindtrack-deployment mindtrack=$IMAGE_URI
      - kubectl rollout status deployment/mindtrack-deployment
      - echo Deployment complete!

logs:
  cloudwatch:
    group-name: /aws/codebuild/mindtrack-build
    stream-name: build-log
```

### 1.3 Test Docker build locally (optional)

```bash
docker build -t mindtrack:test .
docker run -d -p 8080:80 mindtrack:test
# Open http://localhost:8080 to verify
```

---

## Step 2 — Push Code to GitHub

### 2.1 Create a new GitHub repository

```
Go to github.com
→ Click "+" → New repository
→ Repository name: mindtrack
→ Visibility: Public
→ Click "Create repository"
```

### 2.2 Push code via CLI

```bash
cd mindtrack

git init
git add .
git commit -m "Initial commit - Dockerfile, buildspec.yml, k8s manifests"
git remote add origin https://github.com/YOUR_USERNAME/mindtrack.git
git branch -M main
git push -u origin main
```

---

## Step 3 — Store Credentials in AWS Parameter Store

### 3.1 Create Docker Hub Access Token

```
hub.docker.com
→ Click your profile → Account Settings
→ Security
→ New Access Token
→ Description: mindtrack-codebuild
→ Click Generate
→ Copy the token (shown only once)
```


### 3.2 Store credentials in Parameter Store

```
AWS Console
→ Search "Systems Manager"
→ Parameter Store (left sidebar)
→ Create parameter

--- Parameter 1 ---
Name  → /mindtrack/DOCKERHUB_USERNAME
Tier  → Standard
Type  → SecureString
Value → vickyneduncheziyan
→ Create parameter

--- Parameter 2 ---
Name  → /mindtrack/DOCKERHUB_PASSWORD
Tier  → Standard
Type  → SecureString
Value → (paste your Docker Hub access token)
→ Create parameter
```


---

## Step 4 — Create EKS Cluster

```bash
eksctl create cluster \
  --name mindtrack-cluster \
  --region ap-south-1 \
  --nodegroup-name mindtrack-nodes \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 3 \
  --managed
```

> This takes approximately 15 minutes.

```bash
# Verify cluster is running
kubectl get nodes
# Both nodes should show STATUS = Ready
```


### Fix EKS access for your IAM user (if needed)

```bash
# Add your user to EKS auth
eksctl create iamidentitymapping \
  --cluster mindtrack-cluster \
  --region ap-south-1 \
  --arn arn:aws:iam::YOUR_ACCOUNT_ID:root \
  --group system:masters \
  --username root
```

---

## Step 5 — Create Kubernetes Manifests

### 5.1 k8s/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mindtrack-deployment
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mindtrack
  template:
    metadata:
      labels:
        app: mindtrack
    spec:
      containers:
      - name: mindtrack
        image: vickyneduncheziyan/mindtrack:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 80
```

### 5.2 k8s/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mindtrack-service
spec:
  type: LoadBalancer
  selector:
    app: mindtrack
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

### 5.3 Apply manifests (first time only)

```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Get the public URL
kubectl get svc mindtrack-service
# Copy EXTERNAL-IP — this is your app URL
```

---

## Step 6 — Create CodeBuild Project

### 6.1 Open CodeBuild

```
AWS Console → Search "CodeBuild"
→ Build projects (left sidebar)
→ Create build project
```

### 6.2 Project configuration

```
Project name → mindtrack-build
```

### 6.3 Source

```
Source provider → GitHub
→ Connect to GitHub → Authorize
Repository      → YOUR_USERNAME/mindtrack
Branch          → main
☑ Rebuild every time a code change is pushed
```

### 6.4 Environment

```
Environment image  → Managed image
Operating system   → Ubuntu
Runtime            → Standard
Image              → aws/codebuild/standard:7.0
Service role       → New service role (auto-named)
☑ Enable privileged mode   ← REQUIRED for Docker builds
```

### 6.5 Environment variables

Click **Additional configuration** → Add environment variable:

| Name | Value | Type |
|---|---|---|
| `DOCKERHUB_USERNAME` | `/mindtrack/DOCKERHUB_USERNAME` | Parameter |
| `DOCKERHUB_PASSWORD` | `/mindtrack/DOCKERHUB_PASSWORD` | Parameter |
| `AWS_DEFAULT_REGION` | `ap-south-1` | Plaintext |


### 6.6 Buildspec

```
Build specifications → Use a buildspec file
Buildspec name       → buildspec.yml
```

### 6.7 Logs

```
☑ CloudWatch logs
Group name  → /aws/codebuild/mindtrack-build
Stream name → build-log
```

→ Click **Create build project**

### 6.8 Attach IAM policies to CodeBuild role

```
AWS Console → IAM → Roles
→ Search: codebuild-mindtrack-build-service-role
→ Add permissions → Attach policies

Attach each of these:
☑ AmazonEKSClusterPolicy
☑ AmazonEKSWorkerNodePolicy
☑ AmazonEKS_CNI_Policy
☑ CloudWatchLogsFullAccess
☑ AmazonSSMReadOnlyAccess
```

### 6.9 Give CodeBuild access to EKS cluster

```bash
eksctl create iamidentitymapping \
  --cluster mindtrack-cluster \
  --region ap-south-1 \
  --arn arn:aws:iam::YOUR_ACCOUNT_ID:role/codebuild-mindtrack-build-service-role \
  --group system:masters \
  --username CodeBuildRole
```

---

## Step 7 — Create CodePipeline

### 7.1 Open CodePipeline

```
AWS Console → Search "CodePipeline"
→ Create pipeline
```

### 7.2 Pipeline settings

```
Pipeline name  → mindtrack-pipeline
Execution mode → Superseded
Service role   → New service role
→ Click Next
```

### 7.3 Source stage

```
Source provider → GitHub (Version 2)
→ Connect to GitHub
  Connection name → mindtrack-github
  → Authorize → Install AWS Connector
  → Select mindtrack repo → Save → Connect

Repository name → YOUR_USERNAME/mindtrack
Branch          → main
Detection mode  → Webhooks
→ Click Next
```


### 7.4 Build stage

```
Build provider → AWS CodeBuild
Region         → ap-south-1 (Mumbai)
Project name   → mindtrack-build
Build type     → Single build
→ Click Next
```

### 7.5 Deploy stage

```
Deploy provider  → AWS CodeDeploy
Region           → ap-south-1
Application name → mindtrack-app
Deployment group → mindtrack-deploy-group
→ Click Next
```

> Note: The actual EKS deployment is handled by `kubectl set image`
> inside `buildspec.yml`. The CodeDeploy stage satisfies the AWS
> pipeline requirement of having at least two stages.

→ Click **Create pipeline**

---

## Step 8 — CloudWatch Monitoring

### 8.1 View build logs in real time

```
AWS Console
→ CloudWatch
→ Log groups (left sidebar)
→ /aws/codebuild/mindtrack-build
→ Click the latest log stream
→ Watch live build output
```


### 8.2 Enable EKS control plane logging

```
AWS Console
→ EKS → mindtrack-cluster
→ Observability tab
→ Manage logging
→ Turn ON:
  ☑ API server
  ☑ Audit
  ☑ Authenticator
  ☑ Controller manager
  ☑ Scheduler
→ Save changes
```

### 8.3 Create a build failure alarm

```
CloudWatch → Alarms → Create alarm
→ Select metric → CodeBuild → Build Metrics
→ FailedBuilds → mindtrack-build → Select metric

Statistic  → Sum
Period     → 5 minutes
Condition  → Greater than → 0

→ Create new SNS topic
Topic name → mindtrack-build-alerts
Email      → your-email@gmail.com
→ Create topic → Next

Alarm name → mindtrack-build-failure
→ Create alarm
```

> Check your email and click **Confirm Subscription**.

---

## Step 9 — Verify Deployment

### 9.1 Check pods are running

```bash
kubectl get pods -o wide
# STATUS should be Running
```

### 9.2 Confirm image version

```bash
kubectl describe deployment mindtrack-deployment | grep Image
# Image: vickyneduncheziyan/mindtrack:latest
```

### 9.3 Access the application

```bash
# Get the LoadBalancer URL
kubectl get svc mindtrack-service

# Open in browser:
# http://
```


### 9.4 Test the full CI/CD flow end to end

```bash
# Make a change to your app
echo "Updated!" >> dist/index.html

# Push to GitHub
git add .
git commit -m "Test auto deploy"
git push origin main

# Watch CodePipeline auto trigger in AWS Console
# → CodePipeline → mindtrack-pipeline
```

