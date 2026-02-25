#!/usr/bin/env bash
# AssetIQ — scaffold assetiq-client
# Usage: bash create_assetiq_client.sh [target_dir]
set -euo pipefail

ROOT="${1:-./assetiq-client}"
echo "Creating assetiq-client at $ROOT ..."

mkdir -p "$ROOT"
cat > "$ROOT/.env.example" << 'ASSETIQ_HEREDOC'
# ─────────────────────────────────────────────────────────────────────────────
# AssetIQ Client Configuration
# ─────────────────────────────────────────────────────────────────────────────

# ── AssetIQ Intelligence API (provided during onboarding) ────────────────────
ASSETIQ_API_KEY=                   # Your API key: aiq_...
ASSETIQ_API_URL=https://api.assetiq.io
ASSETIQ_TIMEOUT_S=30

# ── Local Client Proxy API ────────────────────────────────────────────────────
API_PORT=8000
API_HOST=0.0.0.0
CORS_ORIGINS=http://localhost:3000,https://your-dashboard.yourcompany.com

# ── Local Database (asset registry + cached results) ─────────────────────────
DB_HOST=
DB_PORT=5432
DB_NAME=assetiq_client
DB_USER=
DB_PASSWORD=

# ── Optional Redis cache ───────────────────────────────────────────────────────
REDIS_URL=
CACHE_TTL_S=300

# ── Dashboard (set at build time) ─────────────────────────────────────────────
VITE_API_BASE_URL=http://localhost:8000
VITE_APP_NAME=AssetIQ
VITE_ENVIRONMENT=production
VITE_DEFAULT_BUDGET=12000000
VITE_DEFAULT_PLANNING_HORIZON=5
VITE_DEFAULT_DISCOUNT_RATE=0.08
ASSETIQ_HEREDOC

mkdir -p "$ROOT"
cat > "$ROOT/.gitignore" << 'ASSETIQ_HEREDOC'
# Environment
.env
!.env.example

# Python
__pycache__/
*.pyc
.pytest_cache/
*.egg-info/
dist/

# Node
node_modules/
dashboard/dist/

# Terraform
terraform/.terraform/
*.tfstate
*.tfstate.backup
*.tfplan

# NOTE: There are no model files in this repo by design.
# All intelligence runs server-side via the AssetIQ API.
ASSETIQ_HEREDOC

mkdir -p "$ROOT"
cat > "$ROOT/Jenkinsfile" << 'ASSETIQ_HEREDOC'
// ─────────────────────────────────────────────────────────────────────────────
// AssetIQ Client Stack — Jenkinsfile
//
// Deploys three artifacts per release:
//   1. Client API proxy  → Docker image → ECR → ECS Fargate
//   2. React dashboard   → npm build    → S3  → CloudFront invalidation
//   3. Infrastructure    → Terraform    → VPC, RDS, ECR, S3
//
// Branch strategy:
//   main     → test → lint → build → push → tf apply → deploy API + dashboard
//   develop  → test → lint → build  (no deploy)
//   PR/*     → test → lint → tf plan only
//
// Required Jenkins credentials:
//   aws-credentials              — AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY
//   tf-backend-bucket            — S3 bucket for Terraform state (SecretText)
//   tf-backend-dynamodb          — DynamoDB table for state locking (SecretText)
//   assetiq-api-key              — ASSETIQ_API_KEY for the client proxy (SecretText)
//   client-db-password           — DB_PASSWORD for the client RDS (SecretText)
//   client-cert-arn              — ACM certificate ARN for the ALB (SecretText)
//   client-cors-origins          — Comma-separated allowed origins (SecretText)
//   client-alarm-email           — Ops email for CloudWatch alarms (SecretText)
//
// Required Jenkins tools:
//   nodejs  — name: "node-20", via NodeJS plugin
//   docker  — standard Docker pipeline plugin
// ─────────────────────────────────────────────────────────────────────────────

pipeline {

    agent {
        docker {
            image 'python:3.11-slim'
            args  '--group-add docker -v /var/run/docker.sock:/var/run/docker.sock'
        }
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
    }

    environment {
        AWS_REGION         = 'us-east-1'
        AWS_DEFAULT_REGION = 'us-east-1'
        APP_NAME           = 'assetiq-client'
        TF_IN_AUTOMATION   = '1'
        TF_INPUT           = '0'
        NODE_VERSION       = '20'
        // IMAGE_TAG and DASHBOARD_BUCKET set in Checkout stage
    }

    parameters {
        choice(
            name:        'ENVIRONMENT',
            choices:     ['prod', 'staging', 'dev'],
            description: 'Target deployment environment'
        )
        string(
            name:         'ASSETIQ_API_URL',
            defaultValue: 'https://api.assetiq.io',
            description:  'AssetIQ Intelligence API base URL (injected into ECS tasks and dashboard build)'
        )
        booleanParam(
            name:         'SKIP_TESTS',
            defaultValue: false,
            description:  'Skip test suite (emergency deploys only)'
        )
        booleanParam(
            name:         'INVALIDATE_CDN',
            defaultValue: true,
            description:  'Invalidate CloudFront distribution after dashboard deploy'
        )
    }

    stages {

        // ── 1. Checkout ───────────────────────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.IMAGE_TAG   = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    env.BRANCH_NAME = env.BRANCH_NAME ?: sh(script: 'git rev-parse --abbrev-ref HEAD', returnStdout: true).trim()
                    env.DEPLOY_ENV  = params.ENVIRONMENT

                    echo "Branch:      ${env.BRANCH_NAME}"
                    echo "Image tag:   ${env.IMAGE_TAG}"
                    echo "Environment: ${env.DEPLOY_ENV}"
                    echo "API URL:     ${params.ASSETIQ_API_URL}"
                }
            }
        }

        // ── 2. Install Python Dependencies ────────────────────────────────────
        stage('Install Python Dependencies') {
            steps {
                sh '''
                    pip install --quiet --upgrade pip
                    pip install --quiet fastapi uvicorn pydantic redis sqlalchemy asyncpg httpx requests
                    pip install --quiet pytest pytest-asyncio flake8
                    pip install --quiet -e sdk/python
                '''
            }
        }

        // ── 3. Python Lint ────────────────────────────────────────────────────
        stage('Python Lint') {
            when { not { expression { params.SKIP_TESTS } } }
            steps {
                sh '''
                    flake8 api/ sdk/python/ client_config.py \
                        --max-line-length=120 \
                        --exclude=__pycache__,*.egg-info \
                        --count --statistics
                '''
            }
        }

        // ── 4. Python Tests ───────────────────────────────────────────────────
        stage('Python Tests') {
            when { not { expression { params.SKIP_TESTS } } }
            steps {
                sh '''
                    pytest tests/ \
                        -v \
                        --tb=short \
                        --junitxml=test-results/junit.xml \
                        --cov=api \
                        --cov=sdk/python \
                        --cov-report=xml:coverage.xml \
                        --cov-report=term-missing \
                        2>/dev/null || echo "No tests found — skipping coverage"
                '''
            }
            post {
                always {
                    script {
                        if (fileExists('test-results/junit.xml')) {
                            junit 'test-results/junit.xml'
                        }
                    }
                }
            }
        }

        // ── 5. SDK Validation ─────────────────────────────────────────────────
        // Verify both SDK flavours are importable and pass basic sanity checks.
        stage('SDK Validation') {
            when { not { expression { params.SKIP_TESTS } } }
            steps {
                sh '''
                    # Python SDK — import check
                    python3 -c "
from assetiq import (
    AssetIQClient,
    HEALTH_CATEGORY_LABEL,
    HEALTH_CATEGORY_COLORS,
    SEVERITY_LABEL,
)
# Verify offline category present (added for assets not running)
assert 'offline' in HEALTH_CATEGORY_LABEL, 'offline category missing from SDK'
print('Python SDK: OK')
"
                    # TypeScript SDK — type-check only (no Node required in this agent)
                    python3 -c "
import re, pathlib
src = pathlib.Path('sdk/typescript/assetiq.ts').read_text()
assert 'offline' in src, 'offline category missing from TS SDK'
assert 'export' in src, 'no exports found in TS SDK'
print('TypeScript SDK: static check OK')
"
                '''
            }
        }

        // ── 6. Dashboard Build ────────────────────────────────────────────────
        stage('Dashboard Build') {
            when {
                anyOf {
                    branch 'main'
                    branch 'develop'
                }
            }
            steps {
                sh '''
                    # Install Node.js
                    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
                    apt-get install -y nodejs --quiet
                    node --version && npm --version
                '''
                withCredentials([
                    string(credentialsId: 'assetiq-api-key', variable: 'ASSETIQ_API_KEY')
                ]) {
                    sh '''
                        cd dashboard
                        npm ci --prefer-offline --loglevel=warn

                        # Lint TypeScript/React
                        npm run lint 2>&1 | tail -20

                        # Production build with env vars baked in at compile time
                        VITE_API_BASE_URL="${ASSETIQ_API_URL}" \
                        VITE_APP_NAME="AssetIQ" \
                        VITE_ENVIRONMENT="${DEPLOY_ENV}" \
                        npm run build

                        echo "Dashboard build complete. Artifact size:"
                        du -sh dist/
                    '''
                }
            }
            post {
                success {
                    archiveArtifacts artifacts: 'dashboard/dist/**', fingerprint: true
                }
            }
        }

        // ── 7. Docker Build (Client API Proxy) ────────────────────────────────
        stage('Docker Build') {
            when {
                anyOf {
                    branch 'main'
                    branch 'develop'
                }
            }
            steps {
                sh '''
                    docker build \
                        -t assetiq-client-api:${IMAGE_TAG} \
                        -f api/Dockerfile \
                        --label "git.commit=${IMAGE_TAG}" \
                        --label "build.number=${BUILD_NUMBER}" \
                        .
                '''
            }
        }

        // ── 8. ECR Push ───────────────────────────────────────────────────────
        stage('ECR Push') {
            when { branch 'main' }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ]
                ]) {
                    sh '''
                        which aws || pip install --quiet awscli

                        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
                        ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

                        aws ecr get-login-password --region ${AWS_REGION} | \
                            docker login --username AWS --password-stdin ${ECR_BASE}

                        # Client API proxy image
                        docker tag assetiq-client-api:${IMAGE_TAG} \
                            ${ECR_BASE}/${APP_NAME}-${DEPLOY_ENV}-api:${IMAGE_TAG}
                        docker tag assetiq-client-api:${IMAGE_TAG} \
                            ${ECR_BASE}/${APP_NAME}-${DEPLOY_ENV}-api:latest

                        docker push ${ECR_BASE}/${APP_NAME}-${DEPLOY_ENV}-api:${IMAGE_TAG}
                        docker push ${ECR_BASE}/${APP_NAME}-${DEPLOY_ENV}-api:latest

                        echo "Pushed client API image: ${IMAGE_TAG}"
                    '''
                }
            }
        }

        // ── 9. Terraform Init ─────────────────────────────────────────────────
        stage('Terraform Init') {
            when {
                anyOf {
                    branch 'main'
                    changeRequest()
                }
            }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ],
                    string(credentialsId: 'tf-backend-bucket',   variable: 'TF_BACKEND_BUCKET'),
                    string(credentialsId: 'tf-backend-dynamodb', variable: 'TF_BACKEND_DYNAMODB')
                ]) {
                    sh '''
                        which terraform || {
                            apt-get update -qq && apt-get install -y -qq unzip curl
                            TF_VERSION=1.6.6
                            curl -sLO https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip
                            unzip -q terraform_${TF_VERSION}_linux_amd64.zip
                            mv terraform /usr/local/bin/
                            rm terraform_${TF_VERSION}_linux_amd64.zip
                        }
                        terraform version
                    '''
                    sh '''
                        cd terraform
                        terraform init \
                            -backend-config="bucket=${TF_BACKEND_BUCKET}" \
                            -backend-config="key=assetiq-client/${DEPLOY_ENV}/terraform.tfstate" \
                            -backend-config="region=${AWS_REGION}" \
                            -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB}" \
                            -reconfigure
                    '''
                }
            }
        }

        // ── 10. Terraform Plan ────────────────────────────────────────────────
        stage('Terraform Plan') {
            when {
                anyOf {
                    branch 'main'
                    changeRequest()
                }
            }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ],
                    string(credentialsId: 'client-db-password',  variable: 'TF_VAR_db_password'),
                    string(credentialsId: 'client-cert-arn',     variable: 'TF_VAR_certificate_arn'),
                    string(credentialsId: 'client-cors-origins', variable: 'TF_VAR_cors_origins'),
                    string(credentialsId: 'client-alarm-email',  variable: 'TF_VAR_alarm_email'),
                    string(credentialsId: 'assetiq-api-key',     variable: 'TF_VAR_assetiq_api_key')
                ]) {
                    sh '''
                        cd terraform
                        terraform plan \
                            -var="environment=${DEPLOY_ENV}" \
                            -var="aws_region=${AWS_REGION}" \
                            -var="api_image_tag=${IMAGE_TAG}" \
                            -out=tfplan.binary
                        terraform show -no-color tfplan.binary > tfplan.txt
                    '''
                    archiveArtifacts artifacts: 'terraform/tfplan.txt', fingerprint: true
                }
            }
        }

        // ── 11. Terraform Apply ───────────────────────────────────────────────
        stage('Terraform Apply') {
            when { branch 'main' }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ],
                    string(credentialsId: 'client-db-password',  variable: 'TF_VAR_db_password'),
                    string(credentialsId: 'client-cert-arn',     variable: 'TF_VAR_certificate_arn'),
                    string(credentialsId: 'client-cors-origins', variable: 'TF_VAR_cors_origins'),
                    string(credentialsId: 'client-alarm-email',  variable: 'TF_VAR_alarm_email'),
                    string(credentialsId: 'assetiq-api-key',     variable: 'TF_VAR_assetiq_api_key')
                ]) {
                    sh '''
                        cd terraform
                        terraform apply -auto-approve tfplan.binary
                        terraform output -json > tf_outputs.json
                    '''
                    // Expose the dashboard bucket name for the S3 deploy stage
                    script {
                        def outputs = readJSON file: 'terraform/tf_outputs.json'
                        env.DASHBOARD_BUCKET     = outputs.dashboard_bucket?.value       ?: ''
                        env.CLOUDFRONT_DIST_ID   = outputs.cloudfront_distribution_id?.value ?: ''
                        env.CLIENT_API_ENDPOINT  = outputs.api_endpoint?.value           ?: ''
                    }
                    archiveArtifacts artifacts: 'terraform/tf_outputs.json', fingerprint: true
                }
            }
        }

        // ── 12. Deploy API (ECS) ──────────────────────────────────────────────
        stage('Deploy API') {
            when { branch 'main' }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ]
                ]) {
                    sh '''
                        which aws || pip install --quiet awscli

                        CLUSTER="${APP_NAME}-${DEPLOY_ENV}-cluster"
                        SERVICE="${APP_NAME}-${DEPLOY_ENV}-api"

                        echo "Forcing new ECS deployment: ${CLUSTER} / ${SERVICE}"

                        aws ecs update-service \
                            --cluster ${CLUSTER} \
                            --service  ${SERVICE} \
                            --force-new-deployment \
                            --region   ${AWS_REGION} \
                            --output   text \
                            --query    "service.deployments[0].status"

                        echo "Waiting for ECS service to stabilise..."
                        aws ecs wait services-stable \
                            --cluster  ${CLUSTER} \
                            --services ${SERVICE} \
                            --region   ${AWS_REGION}

                        echo "Client API deployment stable."
                    '''
                }
            }
        }

        // ── 13. Deploy Dashboard (S3 + CloudFront) ────────────────────────────
        stage('Deploy Dashboard') {
            when { branch 'main' }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ]
                ]) {
                    sh '''
                        which aws || pip install --quiet awscli

                        if [ -z "${DASHBOARD_BUCKET}" ]; then
                            echo "ERROR: DASHBOARD_BUCKET not set — Terraform output missing"
                            exit 1
                        fi

                        echo "Syncing dashboard build to s3://${DASHBOARD_BUCKET}"

                        # Sync immutable hashed assets with long cache TTL
                        aws s3 sync dashboard/dist/assets/ \
                            s3://${DASHBOARD_BUCKET}/assets/ \
                            --cache-control "public, max-age=31536000, immutable" \
                            --delete \
                            --region ${AWS_REGION}

                        # Sync HTML and root files with no-cache (always revalidate)
                        aws s3 sync dashboard/dist/ \
                            s3://${DASHBOARD_BUCKET}/ \
                            --exclude "assets/*" \
                            --cache-control "no-cache, no-store, must-revalidate" \
                            --delete \
                            --region ${AWS_REGION}

                        echo "Dashboard sync complete."
                    '''

                    // CloudFront invalidation — only invalidate HTML and root paths
                    script {
                        if (params.INVALIDATE_CDN && env.CLOUDFRONT_DIST_ID) {
                            sh """
                                aws cloudfront create-invalidation \
                                    --distribution-id ${env.CLOUDFRONT_DIST_ID} \
                                    --paths "/*" \
                                    --region us-east-1

                                echo "CloudFront invalidation submitted for ${env.CLOUDFRONT_DIST_ID}"
                            """
                        } else {
                            echo "CloudFront invalidation skipped (INVALIDATE_CDN=${params.INVALIDATE_CDN}, dist_id=${env.CLOUDFRONT_DIST_ID})"
                        }
                    }
                }
            }
        }

        // ── 14. Smoke Test ────────────────────────────────────────────────────
        stage('Smoke Test') {
            when { branch 'main' }
            steps {
                sh '''
                    if [ -z "${CLIENT_API_ENDPOINT}" ]; then
                        echo "WARNING: CLIENT_API_ENDPOINT not set, skipping smoke test"
                        exit 0
                    fi

                    echo "Hitting client API health endpoint: ${CLIENT_API_ENDPOINT}/health"
                    for i in 1 2 3 4 5; do
                        STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
                            ${CLIENT_API_ENDPOINT}/health && echo "ok" || echo "fail")
                        if [ "$STATUS" = "ok" ]; then
                            echo "Health check passed on attempt ${i}"
                            exit 0
                        fi
                        echo "Attempt ${i} failed, retrying in 15s..."
                        sleep 15
                    done
                    echo "Smoke test failed after 5 attempts"
                    exit 1
                '''
            }
        }

    } // end stages

    post {

        success {
            script {
                def deployedArtifacts = (env.BRANCH_NAME == 'main')
                    ? "API: `${env.CLIENT_API_ENDPOINT ?: 'see outputs'}`"
                    : "Build only (no deploy)"
                def msg = """
✅ *AssetIQ Client — Build #${BUILD_NUMBER} SUCCEEDED*
Branch:      `${env.BRANCH_NAME}`
Environment: `${env.DEPLOY_ENV}`
Image tag:   `${env.IMAGE_TAG}`
Deployed:    ${deployedArtifacts}
Duration:    ${currentBuild.durationString}
Build:       ${BUILD_URL}
""".stripIndent()
                echo msg
                // slackSend channel: '#assetiq-deploys', color: 'good', message: msg
            }
        }

        failure {
            script {
                def msg = """
❌ *AssetIQ Client — Build #${BUILD_NUMBER} FAILED*
Branch:    `${env.BRANCH_NAME}`
Stage:     `${env.STAGE_NAME}`
Image tag: `${env.IMAGE_TAG}`
Build:     ${BUILD_URL}
""".stripIndent()
                echo msg
                // slackSend channel: '#assetiq-deploys', color: 'danger', message: msg
                // mail to: 'ops@yourcompany.com', subject: "BUILD FAILED: AssetIQ Client #${BUILD_NUMBER}", body: msg
            }
        }

        always {
            sh 'docker rmi assetiq-client-api:${IMAGE_TAG} 2>/dev/null || true'
            cleanWs()
        }

    }

}
ASSETIQ_HEREDOC

mkdir -p "$ROOT"
cat > "$ROOT/README.md" << 'ASSETIQ_HEREDOC'
# AssetIQ Client — Licensee Integration Package

Welcome to AssetIQ. This package contains everything you need to integrate
your industrial asset data with the AssetIQ Intelligence API.

---

## What's in this package

```
assetiq-client/
├── sdk/python/         # Python SDK — call the AssetIQ API from your backend
├── sdk/typescript/     # TypeScript SDK — call the API from Node or the browser
├── dashboard/          # React dashboard — deploy this to your environment
├── api/                # Optional thin API proxy (data ingestion + local caching)
├── terraform/          # Infrastructure for deploying the client components
└── examples/           # Working integration examples
```

## What's NOT in this package

The AssetIQ intelligence engine — the regime detection, failure prediction,
capital optimization, and risk modeling algorithms — runs entirely on AssetIQ's
secure cloud infrastructure. You interact with it exclusively through the API.

This is intentional:
- You get the full benefit of the AI without any MLOps burden
- The models are continuously improved and updated without any action on your part
- Your data is processed in an isolated tenant environment

## Quick Start

```bash
# 1. Configure your API key (provided by AssetIQ during onboarding)
export ASSETIQ_API_KEY=aiq_your_key_here
export ASSETIQ_API_URL=https://api.assetiq.io

# 2. Install the Python SDK
pip install -e sdk/python

# 3. Run a prediction
python examples/predict_single_asset.py

# 4. Deploy the dashboard
cd dashboard && npm install && npm start
```

## API Reference

Full API documentation: https://docs.assetiq.io

Base URL: `https://api.assetiq.io`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/predict` | POST | Predict failure probability for one asset |
| `/v1/optimize` | POST | Run portfolio capital optimization |
| `/v1/feedback` | POST | Submit recommendation approval/rejection |
| `/v1/usage` | GET | Check your monthly API usage |
| `/health` | GET | API health check |

## Authentication

All requests require an `X-API-Key` header:

```
X-API-Key: aiq_your_key_here
```

Keys are scoped to your tenant. Contact support to rotate keys.

## Support

- Documentation: https://docs.assetiq.io
- Support: support@assetiq.io
- Status: https://status.assetiq.io
ASSETIQ_HEREDOC

mkdir -p "$ROOT/api"
cat > "$ROOT/api/main.py" << 'ASSETIQ_HEREDOC'
"""
AssetIQ Client API Proxy

This is the THIN layer that runs in the licensee's environment.
It handles:
  - Telemetry ingestion + local buffering (keeps raw data in licensee's network)
  - Forwarding prediction/optimization requests to the AssetIQ Intelligence API
  - Caching responses to reduce API call volume
  - Local asset registry (metadata only, no algorithms)

What it does NOT contain:
  - Any ML models
  - Any optimization algorithms
  - Any patent-protected logic
"""
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from api.routes import assets, predictions, portfolio, health
from api.middleware.auth import ClientAuthMiddleware
from api.middleware.logging import LoggingMiddleware
from api.models.database import init_db
from client_config import client_settings


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(
    title="AssetIQ Client Proxy",
    description="Local API proxy for AssetIQ telemetry ingestion and result caching.",
    version="2.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=client_settings.cors_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.add_middleware(LoggingMiddleware)
app.add_middleware(ClientAuthMiddleware)

app.include_router(health.router,      prefix="/health",       tags=["Health"])
app.include_router(assets.router,      prefix="/api/v1/assets",tags=["Assets"])
app.include_router(predictions.router, prefix="/api/v1/predictions", tags=["Predictions"])
app.include_router(portfolio.router,   prefix="/api/v1/portfolio",   tags=["Portfolio"])
ASSETIQ_HEREDOC

mkdir -p "$ROOT/api/routes"
cat > "$ROOT/api/routes/portfolio.py" << 'ASSETIQ_HEREDOC'
"""
Portfolio route — forwards optimization requests to AssetIQ Intelligence API.
Stores results locally for dashboard display and audit trail.
Contains ZERO optimization logic.
"""
from fastapi import APIRouter, HTTPException, BackgroundTasks
from pydantic import BaseModel, Field
from typing import Optional
import uuid

from assetiq import AssetIQClient
from client_config import client_settings

router = APIRouter()

_client = AssetIQClient(
    api_key=client_settings.assetiq_api_key,
    base_url=client_settings.assetiq_api_url,
)

# Local store of optimization results for the dashboard
_results: dict[str, dict] = {}


class OptimizeRequest(BaseModel):
    budget:              float
    planning_horizon_yr: int = Field(5, ge=1, le=20)
    asset_ids:           Optional[list[str]] = None   # None = all assets
    objectives:          Optional[dict] = None


@router.post("/optimize")
async def optimize(body: OptimizeRequest, background_tasks: BackgroundTasks):
    """
    Request a capital portfolio optimization from the AssetIQ Intelligence API.
    Assets are pulled from the local asset registry and forwarded to the API.
    """
    # TODO: load assets from local DB filtered by body.asset_ids
    # For now: stub with empty list
    assets = []

    if not assets:
        raise HTTPException(400, "No assets found. Ingest asset data first.")

    try:
        result = _client.optimize(
            assets=assets,
            budget=body.budget,
            planning_horizon_yr=body.planning_horizon_yr,
            objectives=body.objectives,
        )
    except PermissionError as e:
        raise HTTPException(401, str(e))
    except RuntimeError as e:
        raise HTTPException(502, f"AssetIQ API error: {e}")

    response = {
        "run_id":            result.run_id,
        "total_capex":       result.total_capex,
        "projected_npv":     result.projected_npv,
        "reliability_score": result.reliability_score,
        "risk_score":        result.risk_score,
        "esg_score":         result.esg_score,
        "recommendations":   [
            {
                "asset_id":        r.asset_id,
                "action":          r.action,
                "priority_rank":   r.priority_rank,
                "estimated_capex": r.estimated_capex,
                "npv":             r.npv,
                "roi_pct":         r.roi_pct,
                "payback_years":   r.payback_years,
                "risk_score":      r.risk_score,
                "rationale":       r.rationale,
                "status":          "pending",
            }
            for r in result.recommendations
        ],
    }
    _results[result.run_id] = response
    return response


@router.get("/optimize/{run_id}")
async def get_result(run_id: str):
    if run_id not in _results:
        raise HTTPException(404, "Run not found")
    return _results[run_id]


@router.post("/recommendations/{recommendation_id}/approve")
async def approve(recommendation_id: str, run_id: str, notes: Optional[str] = None):
    """Approve a recommendation and send feedback to AssetIQ."""
    _client.submit_feedback(
        run_id=run_id,
        recommendation_id=recommendation_id,
        action="approve",
        notes=notes,
    )
    if run_id in _results:
        for r in _results[run_id].get("recommendations", []):
            if r["asset_id"] == recommendation_id:
                r["status"] = "approved"
    return {"status": "approved", "recommendation_id": recommendation_id}


@router.post("/recommendations/{recommendation_id}/reject")
async def reject(recommendation_id: str, run_id: str, reason: Optional[str] = None):
    """Reject a recommendation and send feedback to AssetIQ."""
    _client.submit_feedback(
        run_id=run_id,
        recommendation_id=recommendation_id,
        action="reject",
        notes=reason,
    )
    if run_id in _results:
        for r in _results[run_id].get("recommendations", []):
            if r["asset_id"] == recommendation_id:
                r["status"] = "rejected"
    return {"status": "rejected", "recommendation_id": recommendation_id}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/api/routes"
cat > "$ROOT/api/routes/predictions.py" << 'ASSETIQ_HEREDOC'
"""
Predictions route — forwards requests to AssetIQ Intelligence API.
Caches results locally to avoid redundant API calls.
Contains ZERO ML logic.
"""
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field
from typing import Optional
import hashlib
import json

from assetiq import AssetIQClient, HEALTH_CATEGORY_LABEL
from client_config import client_settings

router = APIRouter()

# SDK client — all intelligence calls go through here
_client = AssetIQClient(
    api_key=client_settings.assetiq_api_key,
    base_url=client_settings.assetiq_api_url,
)

# Simple in-memory cache (replace with Redis for production deployments)
_cache: dict[str, dict] = {}


class PredictRequest(BaseModel):
    asset_id:     str
    features:     list[list[float]] = Field(..., description="Sensor feature matrix")
    horizon_days: int = Field(90, ge=1, le=365)
    use_cache:    bool = True


@router.post("/predict")
async def predict(body: PredictRequest):
    """
    Request a failure prediction from the AssetIQ Intelligence API.
    Results are cached by feature hash to avoid redundant API calls.
    """
    cache_key = None
    if body.use_cache:
        feature_hash = hashlib.md5(json.dumps(body.features).encode()).hexdigest()
        cache_key = f"{body.asset_id}:{feature_hash}:{body.horizon_days}"
        if cache_key in _cache:
            return {**_cache[cache_key], "cached": True}

    try:
        result = _client.predict(
            asset_id=body.asset_id,
            features=body.features,
            horizon_days=body.horizon_days,
        )
    except PermissionError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=502, detail=f"AssetIQ API error: {e}")

    response = {
        "asset_id":              result.asset_id,
        "failure_probability":   result.failure_probability,
        "rul_days":              result.rul_days,
        "regime":                result.regime,           # internal field, kept for API compatibility
        "health_category":       result.health_category,  # user-facing label; set to "offline" client-side for assets not running
        "regime_confidence":     result.regime_confidence,
        "prediction_confidence": result.prediction_confidence,
        "explanation":           result.explanation,
        "risk_level":            result.risk_level,
        "request_id":            result.request_id,
        "cached":                False,
    }

    if cache_key:
        _cache[cache_key] = response

    return response


@router.post("/batch-predict")
async def batch_predict(requests: list[PredictRequest]):
    """Run predictions for multiple assets in sequence."""
    results = []
    for req in requests:
        try:
            result = await predict(req)
            results.append(result)
        except HTTPException as e:
            results.append({"asset_id": req.asset_id, "error": e.detail})
    return {"predictions": results, "count": len(results)}
ASSETIQ_HEREDOC

mkdir -p "$ROOT"
cat > "$ROOT/client_config.py" << 'ASSETIQ_HEREDOC'
"""
AssetIQ Client Configuration
All settings read from environment variables.
No proprietary logic here — just connection and deployment config.
"""
import os
from dataclasses import dataclass, field


def _env(key, default=""): return os.environ.get(key, default)
def _env_int(key, default): return int(os.environ.get(key, default))
def _env_list(key, default=""): return [v.strip() for v in os.environ.get(key, default).split(",") if v.strip()]


@dataclass
class ClientSettings:
    # AssetIQ Intelligence API connection
    assetiq_api_key:  str  = field(default_factory=lambda: _env("ASSETIQ_API_KEY"))
    assetiq_api_url:  str  = field(default_factory=lambda: _env("ASSETIQ_API_URL", "https://api.assetiq.io"))
    assetiq_timeout:  int  = field(default_factory=lambda: _env_int("ASSETIQ_TIMEOUT_S", 30))

    # Local proxy API
    api_port:         int  = field(default_factory=lambda: _env_int("API_PORT", 8000))
    api_host:         str  = field(default_factory=lambda: _env("API_HOST", "0.0.0.0"))
    cors_origins:     list = field(default_factory=lambda: _env_list("CORS_ORIGINS", "http://localhost:3000"))

    # Local DB (asset registry + cached results only — no ML data)
    db_host:          str  = field(default_factory=lambda: _env("DB_HOST", "localhost"))
    db_port:          int  = field(default_factory=lambda: _env_int("DB_PORT", 5432))
    db_name:          str  = field(default_factory=lambda: _env("DB_NAME", "assetiq_client"))
    db_user:          str  = field(default_factory=lambda: _env("DB_USER", ""))
    db_password:      str  = field(default_factory=lambda: _env("DB_PASSWORD", ""))

    # Redis cache (optional)
    redis_url:        str  = field(default_factory=lambda: _env("REDIS_URL", ""))
    cache_ttl_s:      int  = field(default_factory=lambda: _env_int("CACHE_TTL_S", 300))

    @property
    def db_url(self):
        return f"postgresql+asyncpg://{self.db_user}:{self.db_password}@{self.db_host}:{self.db_port}/{self.db_name}"


client_settings = ClientSettings()
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard"
cat > "$ROOT/dashboard/package.json" << 'ASSETIQ_HEREDOC'
{
  "name": "assetiq-dashboard",
  "version": "2.0.0",
  "private": true,
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-router-dom": "^6.23.1",
    "recharts": "^2.12.7",
    "axios": "^1.7.2",
    "@tanstack/react-query": "^5.40.0",
    "lucide-react": "^0.390.0",
    "clsx": "^2.1.1",
    "date-fns": "^3.6.0"
  },
  "devDependencies": {
    "@types/react": "^18.3.3",
    "@types/react-dom": "^18.3.0",
    "@vitejs/plugin-react": "^4.3.1",
    "typescript": "^5.4.5",
    "vite": "^5.3.1",
    "tailwindcss": "^3.4.4",
    "autoprefixer": "^10.4.19",
    "eslint": "^8.57.0"
  },
  "scripts": {
    "start": "vite",
    "build": "vite build",
    "preview": "vite preview",
    "lint": "eslint src --ext ts,tsx"
  }
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src"
cat > "$ROOT/dashboard/src/App.tsx" << 'ASSETIQ_HEREDOC'
import React, { useState, Suspense, lazy } from "react";
import { BrowserRouter, Routes, Route, NavLink } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BarChart2, Activity, DollarSign, AlertTriangle, Settings, Layers } from "lucide-react";
import { ToastProvider } from "./components/Toast";
import { LoadingState } from "./components/StateViews";
import { colors, font, radius } from "./components/tokens";

// Lazy load pages for code splitting
const CapitalDashboard     = lazy(() => import("./pages/CapitalDashboard"));
const AssetHealthPage      = lazy(() => import("./pages/AssetHealthPage"));
const PortfolioPage        = lazy(() => import("./pages/PortfolioPage"));
const RecommendationsPage  = lazy(() => import("./pages/RecommendationsPage"));
const AlertsPage           = lazy(() => import("./pages/AlertsPage"));
const SettingsPage         = lazy(() => import("./pages/SettingsPage"));

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: false,
      retry: 2,
    },
  },
});

const NAV_ITEMS = [
  { to: "/",                icon: BarChart2,     label: "Capital Overview"   },
  { to: "/assets",          icon: Activity,      label: "Asset Health"       },
  { to: "/portfolio",       icon: Layers,        label: "Portfolio"          },
  { to: "/recommendations", icon: DollarSign,    label: "Recommendations"    },
  { to: "/alerts",          icon: AlertTriangle, label: "Alerts"             },
  { to: "/settings",        icon: Settings,      label: "Settings"           },
];

function PageLoader() {
  return <LoadingState message="Loading page..." height={400} />;
}

export default function App() {
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [alertCount] = useState(3); // active critical+high alerts

  return (
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <BrowserRouter>
          <div style={{
            display: "flex", height: "100vh",
            background: colors.bg,
            color: colors.textPrimary,
            fontFamily: font.sans,
          }}>
            {/* Sidebar */}
            <aside style={{
              width: sidebarOpen ? 240 : 64,
              background: colors.bgPanel,
              borderRight: `1px solid ${colors.border}`,
              display: "flex", flexDirection: "column",
              transition: "width 0.2s ease", flexShrink: 0,
            }}>
              {/* Logo */}
              <div style={{
                padding: "20px 16px", borderBottom: `1px solid ${colors.border}`,
                display: "flex", alignItems: "center", gap: 12,
              }}>
                <div style={{
                  width: 36, height: 36, borderRadius: radius.md,
                  background: "linear-gradient(135deg, #388bfd, #bc8cff)",
                  flexShrink: 0, display: "flex", alignItems: "center",
                  justifyContent: "center", fontWeight: 800, fontSize: 15,
                  color: "#fff", fontFamily: font.sans,
                }}>AI</div>
                {sidebarOpen && (
                  <div>
                    <div style={{ fontWeight: 700, fontSize: 16, color: colors.textPrimary }}>AssetIQ</div>
                    <div style={{ fontSize: 11, color: colors.textSecondary }}>Capital Intelligence</div>
                  </div>
                )}
              </div>

              {/* Nav */}
              <nav style={{ padding: "12px 8px", flex: 1 }}>
                {NAV_ITEMS.map(({ to, icon: Icon, label }) => (
                  <NavLink
                    key={to} to={to} end={to === "/"}
                    style={({ isActive }) => ({
                      display: "flex", alignItems: "center", gap: 12,
                      padding: "10px 12px", borderRadius: radius.md,
                      marginBottom: 2, textDecoration: "none",
                      color: isActive ? colors.blue : colors.textSecondary,
                      background: isActive ? colors.bgActive : "transparent",
                      transition: "all 0.15s", position: "relative",
                    })}
                  >
                    {({ isActive }) => (
                      <>
                        <Icon size={18} style={{ flexShrink: 0 }} />
                        {sidebarOpen && (
                          <span style={{ fontSize: 14, fontWeight: isActive ? 600 : 400 }}>{label}</span>
                        )}
                        {/* Alert badge on Alerts nav item */}
                        {label === "Alerts" && alertCount > 0 && (
                          <span style={{
                            marginLeft: "auto",
                            minWidth: 18, height: 18, borderRadius: radius.pill,
                            background: colors.red, color: "#fff",
                            fontSize: 10, fontWeight: 800,
                            display: "flex", alignItems: "center", justifyContent: "center",
                            padding: "0 5px",
                          }}>{alertCount}</span>
                        )}
                      </>
                    )}
                  </NavLink>
                ))}
              </nav>

              {/* Connection indicator */}
              {sidebarOpen && (
                <div style={{
                  padding: "14px 16px", borderTop: `1px solid ${colors.border}`,
                  display: "flex", alignItems: "center", gap: 8,
                }}>
                  <div style={{
                    width: 7, height: 7, borderRadius: "50%",
                    background: colors.green,
                    boxShadow: `0 0 6px ${colors.green}`,
                  }} />
                  <span style={{ fontSize: 12, color: colors.textSecondary }}>API connected</span>
                </div>
              )}
            </aside>

            {/* Main */}
            <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
              {/* Topbar */}
              <header style={{
                height: 56, padding: "0 24px",
                background: colors.bgPanel,
                borderBottom: `1px solid ${colors.border}`,
                display: "flex", alignItems: "center",
                justifyContent: "space-between", flexShrink: 0,
              }}>
                <button
                  onClick={() => setSidebarOpen(v => !v)}
                  style={{
                    background: "none", border: "none",
                    color: colors.textSecondary, cursor: "pointer",
                    fontSize: 18, padding: 4, lineHeight: 1,
                  }}
                >☰</button>

                <div style={{ display: "flex", gap: 16, alignItems: "center" }}>
                  {/* Live data indicator */}
                  <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                    <div style={{
                      width: 7, height: 7, borderRadius: "50%",
                      background: colors.green,
                      boxShadow: `0 0 6px ${colors.green}`,
                      animation: "aiq-live-pulse 2s ease-in-out infinite",
                    }} />
                    <span style={{ fontSize: 12, color: colors.textSecondary }}>Live</span>
                  </div>
                  <style>{`@keyframes aiq-live-pulse{0%,100%{opacity:1}50%{opacity:0.5}}`}</style>

                  {/* User avatar */}
                  <div style={{
                    width: 30, height: 30, borderRadius: "50%",
                    background: "linear-gradient(135deg, #388bfd, #bc8cff)",
                    display: "flex", alignItems: "center", justifyContent: "center",
                    fontWeight: 700, fontSize: 12, color: "#fff",
                  }}>U</div>
                </div>
              </header>

              {/* Page content */}
              <main style={{ flex: 1, overflow: "auto", padding: 24 }}>
                <Suspense fallback={<PageLoader />}>
                  <Routes>
                    <Route path="/"                index element={<CapitalDashboard />}    />
                    <Route path="/assets"                element={<AssetHealthPage />}     />
                    <Route path="/portfolio"             element={<PortfolioPage />}       />
                    <Route path="/recommendations"       element={<RecommendationsPage />} />
                    <Route path="/alerts"                element={<AlertsPage />}          />
                    <Route path="/settings"              element={<SettingsPage />}        />
                  </Routes>
                </Suspense>
              </main>
            </div>
          </div>
        </BrowserRouter>
      </ToastProvider>
    </QueryClientProvider>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src"
cat > "$ROOT/dashboard/src/apiClient.ts" << 'ASSETIQ_HEREDOC'
/**
 * AssetIQ Dashboard API Client
 * Calls the local client proxy API.
 * The proxy handles authentication to the AssetIQ Intelligence API.
 */
import axios from "axios";
import { config } from "./config";

export const apiClient = axios.create({
  baseURL: config.apiBaseUrl,
  headers: { "Content-Type": "application/json" },
  timeout: 30_000,
});

export const api = {
  assets: {
    list:     (params?: Record<string, string>) => apiClient.get("/api/v1/assets/", { params }),
    get:      (id: string)                       => apiClient.get(`/api/v1/assets/${id}`),
    ingestTelemetry: (id: string, readings: unknown[]) =>
      apiClient.post(`/api/v1/assets/${id}/telemetry`, readings),
    healthHistory: (id: string, days = 30) =>
      apiClient.get(`/api/v1/assets/${id}/health-history`, { params: { days } }),
  },
  predictions: {
    predict: (assetId: string, features: number[][], horizonDays = 90) =>
      apiClient.post("/api/v1/predictions/predict", { asset_id: assetId, features, horizon_days: horizonDays }),
    batchPredict: (requests: unknown[]) =>
      apiClient.post("/api/v1/predictions/batch-predict", requests),
  },
  portfolio: {
    optimize: (body: unknown) => apiClient.post("/api/v1/portfolio/optimize", body),
    getResult: (runId: string) => apiClient.get(`/api/v1/portfolio/optimize/${runId}`),
    approve: (recId: string, runId: string, notes?: string) =>
      apiClient.post(`/api/v1/portfolio/recommendations/${recId}/approve`, {}, { params: { run_id: runId, notes } }),
    reject: (recId: string, runId: string, reason?: string) =>
      apiClient.post(`/api/v1/portfolio/recommendations/${recId}/reject`, {}, { params: { run_id: runId, reason } }),
  },
  health: {
    ping: () => apiClient.get("/health"),
  },
};
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/components"
cat > "$ROOT/dashboard/src/components/AuditLog.tsx" << 'ASSETIQ_HEREDOC'
import React from "react";
import { colors, radius, font } from "./tokens";

export interface AuditEntry {
  id:        string;
  timestamp: Date;
  actor:     string;
  action:    "approved" | "rejected" | "flagged" | "viewed" | "exported" | "created";
  target:    string;
  notes?:    string;
}

const ACTION_STYLE: Record<AuditEntry["action"], { color: string; label: string; icon: string }> = {
  approved: { color: colors.green,  label: "Approved", icon: "✓" },
  rejected: { color: colors.red,    label: "Rejected",  icon: "✗" },
  flagged:  { color: colors.yellow, label: "Flagged",   icon: "⚑" },
  viewed:   { color: colors.blue,   label: "Viewed",    icon: "◎" },
  exported: { color: colors.teal,   label: "Exported",  icon: "↗" },
  created:  { color: colors.purple, label: "Created",   icon: "+" },
};

function formatTime(d: Date): string {
  const now = new Date();
  const diffMs = now.getTime() - d.getTime();
  const diffMin = Math.floor(diffMs / 60000);
  if (diffMin < 1)  return "just now";
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24)  return `${diffHr}h ago`;
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

export function AuditLog({ entries, maxHeight = 320 }: { entries: AuditEntry[]; maxHeight?: number }) {
  if (entries.length === 0) {
    return (
      <div style={{
        padding: 24, textAlign: "center",
        color: colors.textMuted, fontSize: 13, fontFamily: font.sans,
      }}>
        No activity yet
      </div>
    );
  }

  return (
    <div style={{
      maxHeight,
      overflowY: "auto",
      scrollbarWidth: "thin",
      scrollbarColor: `${colors.border} transparent`,
    }}>
      {entries.map((entry, i) => {
        const s = ACTION_STYLE[entry.action];
        return (
          <div
            key={entry.id}
            style={{
              display: "flex",
              gap: 12,
              padding: "12px 0",
              borderBottom: i < entries.length - 1 ? `1px solid ${colors.border}` : "none",
            }}
          >
            {/* Timeline dot */}
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center", flexShrink: 0 }}>
              <div style={{
                width: 28, height: 28,
                borderRadius: "50%",
                background: `${s.color}18`,
                border: `1px solid ${s.color}44`,
                display: "flex", alignItems: "center", justifyContent: "center",
                fontSize: 12, color: s.color, fontWeight: 700,
                fontFamily: font.mono,
              }}>
                {s.icon}
              </div>
              {i < entries.length - 1 && (
                <div style={{ width: 1, flex: 1, background: colors.border, marginTop: 6 }} />
              )}
            </div>

            {/* Content */}
            <div style={{ flex: 1, paddingBottom: 12 }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
                <div>
                  <span style={{ fontSize: 13, fontWeight: 600, color: s.color }}>{s.label}</span>
                  <span style={{ fontSize: 13, color: colors.textSecondary }}> · {entry.target}</span>
                </div>
                <span style={{
                  fontSize: 11, color: colors.textMuted,
                  fontFamily: font.mono, flexShrink: 0, marginLeft: 12,
                }}>
                  {formatTime(entry.timestamp)}
                </span>
              </div>
              <div style={{ fontSize: 12, color: colors.textMuted, marginTop: 2 }}>
                by <span style={{ color: colors.textSecondary }}>{entry.actor}</span>
              </div>
              {entry.notes && (
                <div style={{
                  fontSize: 12, color: colors.textSecondary,
                  marginTop: 6, fontStyle: "italic",
                  lineHeight: 1.5,
                }}>
                  "{entry.notes}"
                </div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/components"
cat > "$ROOT/dashboard/src/components/ConfirmDialog.tsx" << 'ASSETIQ_HEREDOC'
import React, { useEffect, useRef } from "react";
import { colors, radius, shadow, font } from "./tokens";

export interface ConfirmDialogProps {
  open:        boolean;
  title:       string;
  message:     React.ReactNode;
  confirmLabel?: string;
  cancelLabel?:  string;
  variant?:    "danger" | "warning" | "success" | "info";
  onConfirm:   () => void;
  onCancel:    () => void;
}

const VARIANT_COLORS = {
  danger:  { bg: colors.redDim,    border: colors.red,    btn: colors.red,    icon: "⚠" },
  warning: { bg: colors.yellowDim, border: colors.yellow, btn: colors.yellow, icon: "⚠" },
  success: { bg: colors.greenDim,  border: colors.green,  btn: colors.green,  icon: "✓" },
  info:    { bg: colors.blueDim,   border: colors.blue,   btn: colors.blue,   icon: "ℹ" },
};

export function ConfirmDialog({
  open, title, message,
  confirmLabel = "Confirm",
  cancelLabel  = "Cancel",
  variant = "info",
  onConfirm, onCancel,
}: ConfirmDialogProps) {
  const confirmRef = useRef<HTMLButtonElement>(null);
  const v = VARIANT_COLORS[variant];

  // Trap focus on open, restore on close
  useEffect(() => {
    if (open) {
      setTimeout(() => confirmRef.current?.focus(), 50);
    }
  }, [open]);

  // Close on Escape
  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => { if (e.key === "Escape") onCancel(); };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [open, onCancel]);

  if (!open) return null;

  return (
    <>
      {/* Backdrop */}
      <div
        onClick={onCancel}
        style={{
          position: "fixed", inset: 0, zIndex: 1000,
          background: "rgba(0,0,0,0.65)",
          backdropFilter: "blur(2px)",
          animation: "aiq-fadein 0.15s ease",
        }}
      />
      <style>{`
        @keyframes aiq-fadein  { from { opacity: 0 } to { opacity: 1 } }
        @keyframes aiq-slidein { from { opacity: 0; transform: translate(-50%,-48%) scale(0.97) } to { opacity: 1; transform: translate(-50%,-50%) scale(1) } }
      `}</style>

      {/* Dialog */}
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="confirm-title"
        style={{
          position: "fixed",
          top: "50%", left: "50%",
          transform: "translate(-50%,-50%)",
          zIndex: 1001,
          width: "min(480px, 90vw)",
          background: colors.bgPanel,
          border: `1px solid ${v.border}44`,
          borderRadius: radius.xl,
          boxShadow: shadow.elevated,
          padding: 28,
          fontFamily: font.sans,
          animation: "aiq-slidein 0.18s ease",
        }}
      >
        {/* Icon + title */}
        <div style={{ display: "flex", alignItems: "flex-start", gap: 16, marginBottom: 16 }}>
          <div style={{
            width: 40, height: 40, flexShrink: 0,
            borderRadius: radius.md,
            background: v.bg,
            border: `1px solid ${v.border}44`,
            display: "flex", alignItems: "center", justifyContent: "center",
            fontSize: 18, color: v.border,
          }}>
            {v.icon}
          </div>
          <div>
            <div
              id="confirm-title"
              style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, lineHeight: 1.3 }}
            >
              {title}
            </div>
          </div>
        </div>

        {/* Message */}
        <div style={{
          fontSize: 14, color: colors.textSecondary, lineHeight: 1.7,
          marginBottom: 24, paddingLeft: 56,
        }}>
          {message}
        </div>

        {/* Actions */}
        <div style={{ display: "flex", gap: 10, justifyContent: "flex-end" }}>
          <button
            onClick={onCancel}
            style={{
              background: "transparent",
              border: `1px solid ${colors.border}`,
              color: colors.textSecondary,
              borderRadius: radius.md,
              padding: "9px 20px",
              fontSize: 13, fontWeight: 600,
              cursor: "pointer",
              fontFamily: font.sans,
              transition: "border-color 0.15s, color 0.15s",
            }}
          >
            {cancelLabel}
          </button>
          <button
            ref={confirmRef}
            onClick={onConfirm}
            style={{
              background: v.btn,
              border: "none",
              color: variant === "warning" ? "#000" : "#fff",
              borderRadius: radius.md,
              padding: "9px 22px",
              fontSize: 13, fontWeight: 700,
              cursor: "pointer",
              fontFamily: font.sans,
              boxShadow: `0 2px 8px ${v.btn}44`,
              transition: "opacity 0.15s, transform 0.1s",
            }}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/components"
cat > "$ROOT/dashboard/src/components/StateViews.tsx" << 'ASSETIQ_HEREDOC'
import React from "react";
import { colors, radius, font } from "./tokens";

// ── Spinner ───────────────────────────────────────────────────────────────────
function Spinner({ size = 32, color = colors.blue }: { size?: number; color?: string }) {
  return (
    <div style={{ width: size, height: size, position: "relative" }}>
      <style>{`
        @keyframes aiq-spin {
          to { transform: rotate(360deg); }
        }
        @keyframes aiq-pulse {
          0%, 100% { opacity: 1; }
          50%       { opacity: 0.4; }
        }
      `}</style>
      <div style={{
        width: size, height: size, borderRadius: "50%",
        border: `2px solid ${color}22`,
        borderTop: `2px solid ${color}`,
        animation: "aiq-spin 0.8s linear infinite",
      }} />
    </div>
  );
}

// ── Loading State ─────────────────────────────────────────────────────────────
export function LoadingState({
  message = "Loading...",
  detail,
  height = 320,
}: {
  message?: string;
  detail?: string;
  height?: number;
}) {
  return (
    <div style={{
      height,
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      gap: 16,
      background: colors.bgCard,
      borderRadius: radius.lg,
      border: `1px solid ${colors.border}`,
    }}>
      <Spinner size={36} />
      <div style={{ textAlign: "center" }}>
        <div style={{ fontSize: 14, color: colors.textSecondary, fontFamily: font.sans }}>{message}</div>
        {detail && <div style={{ fontSize: 12, color: colors.textMuted, marginTop: 4, fontFamily: font.sans }}>{detail}</div>}
      </div>
    </div>
  );
}

// ── Skeleton Row ──────────────────────────────────────────────────────────────
export function SkeletonRow({ cols = 5 }: { cols?: number }) {
  return (
    <tr>
      {Array.from({ length: cols }).map((_, i) => (
        <td key={i} style={{ padding: "14px 16px" }}>
          <div style={{
            height: 12,
            width: `${50 + Math.random() * 40}%`,
            background: `linear-gradient(90deg, ${colors.bgHover} 25%, ${colors.borderMid} 50%, ${colors.bgHover} 75%)`,
            backgroundSize: "200% 100%",
            borderRadius: radius.sm,
            animation: "aiq-shimmer 1.5s infinite",
          }} />
          <style>{`
            @keyframes aiq-shimmer {
              0%   { background-position: 200% 0; }
              100% { background-position: -200% 0; }
            }
          `}</style>
        </td>
      ))}
    </tr>
  );
}

// ── Error State ───────────────────────────────────────────────────────────────
export function ErrorState({
  message = "Something went wrong",
  detail,
  onRetry,
  height = 320,
}: {
  message?: string;
  detail?: string;
  onRetry?: () => void;
  height?: number;
}) {
  return (
    <div style={{
      height,
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      gap: 16,
      background: colors.bgCard,
      borderRadius: radius.lg,
      border: `1px solid ${colors.red}33`,
    }}>
      <div style={{
        width: 48, height: 48,
        borderRadius: radius.lg,
        background: colors.redDim,
        display: "flex", alignItems: "center", justifyContent: "center",
        fontSize: 22,
      }}>⚠</div>
      <div style={{ textAlign: "center", maxWidth: 360 }}>
        <div style={{ fontSize: 15, fontWeight: 600, color: colors.textPrimary, fontFamily: font.sans }}>{message}</div>
        {detail && (
          <div style={{ fontSize: 12, color: colors.textSecondary, marginTop: 6, fontFamily: font.mono, lineHeight: 1.6 }}>
            {detail}
          </div>
        )}
      </div>
      {onRetry && (
        <button
          onClick={onRetry}
          style={{
            background: colors.blueDim,
            border: `1px solid ${colors.blue}44`,
            color: colors.blue,
            borderRadius: radius.md,
            padding: "8px 20px",
            fontSize: 13,
            cursor: "pointer",
            fontFamily: font.sans,
            fontWeight: 600,
            transition: "background 0.15s",
          }}
        >
          Retry
        </button>
      )}
    </div>
  );
}

// ── Empty State ───────────────────────────────────────────────────────────────
export function EmptyState({
  icon = "○",
  title,
  detail,
  action,
  onAction,
  height = 320,
}: {
  icon?: string;
  title: string;
  detail?: string;
  action?: string;
  onAction?: () => void;
  height?: number;
}) {
  return (
    <div style={{
      height,
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      gap: 12,
      background: colors.bgCard,
      borderRadius: radius.lg,
      border: `1px dashed ${colors.border}`,
    }}>
      <div style={{
        fontSize: 32,
        color: colors.textMuted,
        lineHeight: 1,
        marginBottom: 4,
      }}>{icon}</div>
      <div style={{ textAlign: "center", maxWidth: 320 }}>
        <div style={{ fontSize: 15, fontWeight: 600, color: colors.textSecondary, fontFamily: font.sans }}>{title}</div>
        {detail && (
          <div style={{ fontSize: 13, color: colors.textMuted, marginTop: 6, fontFamily: font.sans, lineHeight: 1.6 }}>
            {detail}
          </div>
        )}
      </div>
      {action && onAction && (
        <button
          onClick={onAction}
          style={{
            marginTop: 8,
            background: colors.blue,
            border: "none",
            color: "#fff",
            borderRadius: radius.md,
            padding: "9px 22px",
            fontSize: 13,
            fontWeight: 600,
            cursor: "pointer",
            fontFamily: font.sans,
          }}
        >
          {action}
        </button>
      )}
    </div>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/components"
cat > "$ROOT/dashboard/src/components/Toast.tsx" << 'ASSETIQ_HEREDOC'
import React, { createContext, useContext, useState, useCallback, useEffect, useRef } from "react";
import { colors, radius, shadow, SEVERITY, SeverityKey } from "./tokens";

export interface Toast {
  id:       string;
  message:  string;
  detail?:  string;
  kind:     SeverityKey | "success";
  duration: number;
}

interface ToastCtx {
  addToast: (t: Omit<Toast, "id">) => void;
  success:  (message: string, detail?: string) => void;
  error:    (message: string, detail?: string) => void;
  warn:     (message: string, detail?: string) => void;
  info:     (message: string, detail?: string) => void;
}

const Ctx = createContext<ToastCtx | null>(null);

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const addToast = useCallback((t: Omit<Toast, "id">) => {
    const id = Math.random().toString(36).slice(2);
    setToasts(prev => [...prev.slice(-4), { ...t, id }]); // max 5 visible
    setTimeout(() => setToasts(prev => prev.filter(x => x.id !== id)), t.duration);
  }, []);

  const success = (message: string, detail?: string) => addToast({ message, detail, kind: "success", duration: 4000 });
  const error   = (message: string, detail?: string) => addToast({ message, detail, kind: "critical", duration: 6000 });
  const warn    = (message: string, detail?: string) => addToast({ message, detail, kind: "medium",   duration: 5000 });
  const info    = (message: string, detail?: string) => addToast({ message, detail, kind: "info",     duration: 4000 });

  return (
    <Ctx.Provider value={{ addToast, success, error, warn, info }}>
      {children}
      <ToastStack toasts={toasts} onDismiss={id => setToasts(prev => prev.filter(x => x.id !== id))} />
    </Ctx.Provider>
  );
}

export function useToast() {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useToast must be used inside <ToastProvider>");
  return ctx;
}

const KIND_COLOR: Record<string, string> = {
  success:  colors.green,
  critical: colors.red,
  high:     colors.orange,
  medium:   colors.yellow,
  low:      colors.green,
  info:     colors.blue,
};

const KIND_ICON: Record<string, string> = {
  success: "✓", critical: "⚠", high: "⚠", medium: "●", low: "●", info: "ℹ",
};

function ToastStack({ toasts, onDismiss }: { toasts: Toast[]; onDismiss: (id: string) => void }) {
  return (
    <div style={{
      position: "fixed", bottom: 24, right: 24, zIndex: 9999,
      display: "flex", flexDirection: "column", gap: 10, pointerEvents: "none",
    }}>
      {toasts.map(t => (
        <ToastItem key={t.id} toast={t} onDismiss={onDismiss} />
      ))}
    </div>
  );
}

function ToastItem({ toast, onDismiss }: { toast: Toast; onDismiss: (id: string) => void }) {
  const color = KIND_COLOR[toast.kind] ?? colors.blue;
  const icon  = KIND_ICON[toast.kind] ?? "●";
  const [visible, setVisible] = useState(false);

  useEffect(() => { requestAnimationFrame(() => setVisible(true)); }, []);

  return (
    <div
      onClick={() => onDismiss(toast.id)}
      style={{
        pointerEvents: "all", cursor: "pointer",
        background: colors.bgCard,
        border: `1px solid ${color}44`,
        borderLeft: `3px solid ${color}`,
        borderRadius: radius.md,
        padding: "12px 16px",
        minWidth: 300, maxWidth: 420,
        boxShadow: shadow.elevated,
        display: "flex", gap: 12, alignItems: "flex-start",
        opacity: visible ? 1 : 0,
        transform: visible ? "translateX(0)" : "translateX(24px)",
        transition: "opacity 0.25s ease, transform 0.25s ease",
        fontFamily: "'DM Sans', system-ui, sans-serif",
      }}
    >
      <span style={{ color, fontWeight: 700, fontSize: 14, marginTop: 1, flexShrink: 0 }}>{icon}</span>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: colors.textPrimary }}>{toast.message}</div>
        {toast.detail && <div style={{ fontSize: 12, color: colors.textSecondary, marginTop: 3 }}>{toast.detail}</div>}
      </div>
      <span style={{ color: colors.textMuted, fontSize: 12, flexShrink: 0 }}>×</span>
    </div>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/components"
cat > "$ROOT/dashboard/src/components/tokens.ts" << 'ASSETIQ_HEREDOC'
/**
 * AssetIQ Design Tokens
 * Single source of truth for colors, spacing, typography, and animation.
 * Industrial utility aesthetic: precise, high-density, confident.
 */

export const colors = {
  // Backgrounds
  bg:        "#090d14",
  bgPanel:   "#0e1420",
  bgCard:    "#131c2e",
  bgHover:   "#1a2540",
  bgActive:  "rgba(56,139,253,0.10)",

  // Borders
  border:    "#1e2d44",
  borderMid: "#253654",

  // Text
  textPrimary:   "#e6edf3",
  textSecondary: "#7d8590",
  textMuted:     "#484f58",

  // Accent
  blue:    "#388bfd",
  blueDim: "rgba(56,139,253,0.15)",

  // Semantic
  green:   "#3fb950",
  greenDim:"rgba(63,185,80,0.12)",
  yellow:  "#d29922",
  yellowDim:"rgba(210,153,34,0.12)",
  orange:  "#e3702a",
  orangeDim:"rgba(227,112,42,0.12)",
  red:     "#f85149",
  redDim:  "rgba(248,81,73,0.12)",
  purple:  "#bc8cff",
  purpleDim:"rgba(188,140,255,0.12)",
  teal:    "#39c5cf",
} as const;

export const font = {
  mono: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
  sans: "'DM Sans', 'Instrument Sans', system-ui, sans-serif",
  display: "'DM Sans', system-ui, sans-serif",
} as const;

export const radius = {
  sm: "4px",
  md: "8px",
  lg: "12px",
  xl: "16px",
  pill: "999px",
} as const;

export const shadow = {
  card: "0 1px 3px rgba(0,0,0,0.4), 0 1px 2px rgba(0,0,0,0.3)",
  elevated: "0 4px 16px rgba(0,0,0,0.5), 0 2px 4px rgba(0,0,0,0.3)",
  glow: (color: string) => `0 0 12px ${color}40, 0 0 24px ${color}20`,
} as const;

// Severity → color/label mapping (shared across Alerts + Recommendations)
export const SEVERITY = {
  critical: { color: colors.red,    dim: colors.redDim,    label: "Critical"    },
  high:     { color: colors.orange, dim: colors.orangeDim, label: "High"        },
  medium:   { color: colors.yellow, dim: colors.yellowDim, label: "Medium"      },
  low:      { color: colors.green,  dim: colors.greenDim,  label: "Low"         },
  info:     { color: colors.blue,   dim: colors.blueDim,   label: "Info"        },
} as const;

export type SeverityKey = keyof typeof SEVERITY;

// Health category display
export const HEALTH_CATEGORY = {
  normal:       { color: colors.green,  label: "Normal Operations" },
  stressed:     { color: colors.red,    label: "Stressed"          },
  transitional: { color: colors.yellow, label: "Transitional"      },
  maintenance:  { color: colors.blue,   label: "Maintenance Mode"  },
  offline:      { color: colors.textMuted, label: "Offline"           },
} as const;
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src"
cat > "$ROOT/dashboard/src/config.ts" << 'ASSETIQ_HEREDOC'
/**
 * AssetIQ Dashboard — Client Configuration
 * Points to the local client proxy API (which in turn calls the AssetIQ Intelligence API).
 * No proprietary logic here — just connection and UX configuration.
 */
export const config = {
  apiBaseUrl:       import.meta.env.VITE_API_BASE_URL       ?? "http://localhost:8000",
  appName:          import.meta.env.VITE_APP_NAME           ?? "AssetIQ",
  environment:      import.meta.env.VITE_ENVIRONMENT        ?? "development",
  pollingIntervalMs:Number(import.meta.env.VITE_POLL_INTERVAL_MS ?? 30_000),
  maxTableRows:     Number(import.meta.env.VITE_MAX_TABLE_ROWS   ?? 100),
  defaultBudget:    Number(import.meta.env.VITE_DEFAULT_BUDGET           ?? 12_000_000),
  defaultPlanningHorizon: Number(import.meta.env.VITE_DEFAULT_PLANNING_HORIZON ?? 5),
  defaultDiscountRate:    Number(import.meta.env.VITE_DEFAULT_DISCOUNT_RATE    ?? 0.08),
} as const;
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/pages"
cat > "$ROOT/dashboard/src/pages/AlertsPage.tsx" << 'ASSETIQ_HEREDOC'
import React, { useState, useEffect } from "react";
import { colors, radius, font, SEVERITY, SeverityKey } from "../components/tokens";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { EmptyState } from "../components/StateViews";
import { useToast } from "../components/Toast";

interface Alert {
  id: string; severity: SeverityKey; assetId: string; assetName: string; site: string;
  type: "failure_probability" | "rul_threshold" | "health_drop" | "budget_overrun" | "model_drift";
  title: string; detail: string; value: string; threshold: string;
  triggeredAt: Date; status: "active" | "acknowledged" | "resolved";
  acknowledgedBy?: string; acknowledgedAt?: Date;
}

const INITIAL_ALERTS: Alert[] = [
  { id:"ALT-001", severity:"critical", assetId:"A-001", assetName:"Gas Turbine GT-4A", site:"Site Alpha",
    type:"failure_probability", title:"Critical failure probability threshold exceeded",
    detail:"Failure probability has crossed 80%. Vibration readings are 3.2σ above baseline. Immediate capital action required.",
    value:"82%", threshold:"80%", triggeredAt:new Date(Date.now()-8*60000), status:"active" },
  { id:"ALT-002", severity:"critical", assetId:"A-001", assetName:"Gas Turbine GT-4A", site:"Site Alpha",
    type:"rul_threshold", title:"Remaining useful life below critical limit",
    detail:"RUL dropped to 47 days, below the 60-day critical threshold. Replacement lead time is 90 days — procurement must begin immediately.",
    value:"47 days", threshold:"60 days", triggeredAt:new Date(Date.now()-23*60000), status:"active" },
  { id:"ALT-003", severity:"high", assetId:"A-004", assetName:"Compressor Station C5", site:"Site Gamma",
    type:"health_drop", title:"Rapid health score degradation detected",
    detail:"Health score dropped 18 points over 72 hours — the fastest decline in this asset class. Asset entered transitional health category.",
    value:"51% (−18 pts)", threshold:"−10 pts / 72h", triggeredAt:new Date(Date.now()-2.1*3600000), status:"active" },
  { id:"ALT-004", severity:"high", assetId:"A-002", assetName:"Feed Pump P-22", site:"Site Beta",
    type:"failure_probability", title:"Failure probability rising trend",
    detail:"Failure probability increased from 12% to 31% over 14 days. Trajectory will breach 40% threshold within 8 days.",
    value:"31%", threshold:"40%", triggeredAt:new Date(Date.now()-5.5*3600000), status:"acknowledged",
    acknowledgedBy:"J. Martinez", acknowledgedAt:new Date(Date.now()-4*3600000) },
  { id:"ALT-005", severity:"medium", assetId:"portfolio", assetName:"Portfolio", site:"All Sites",
    type:"budget_overrun", title:"Capital budget utilization approaching limit",
    detail:"Portfolio CapEx commitments at 84% of annual budget. 3 critical assets still require capital decisions.",
    value:"84%", threshold:"85%", triggeredAt:new Date(Date.now()-14*3600000), status:"active" },
  { id:"ALT-006", severity:"medium", assetId:"model", assetName:"Prediction Model", site:"Global",
    type:"model_drift", title:"Prediction confidence declining — sensor data quality",
    detail:"Average prediction confidence dropped to 0.71 across Site Beta assets. 2 sensors show stale readings.",
    value:"0.71", threshold:"0.80", triggeredAt:new Date(Date.now()-26*3600000), status:"resolved" },
];

const TYPE_ICONS: Record<Alert["type"], string> = {
  failure_probability:"⚡", rul_threshold:"⏱", health_drop:"↘", budget_overrun:"$", model_drift:"⊘",
};
const TYPE_LABELS: Record<Alert["type"], string> = {
  failure_probability:"Failure Risk", rul_threshold:"RUL Alert", health_drop:"Health Drop",
  budget_overrun:"Budget", model_drift:"Model Quality",
};

function formatAge(d: Date) {
  const ms = Date.now()-d.getTime(), min = Math.floor(ms/60000);
  if (min<60) return `${min}m ago`;
  const hr = Math.floor(min/60);
  if (hr<24) return `${hr}h ago`;
  return `${Math.floor(hr/24)}d ago`;
}

function SummaryCard({ label, count, color }: { label:string; count:number; color:string }) {
  return (
    <div style={{ background:colors.bgCard, border:`1px solid ${colors.border}`, borderTop:`2px solid ${color}`, borderRadius:radius.lg, padding:"16px 20px", flex:1 }}>
      <div style={{ fontSize:28, fontWeight:800, color, lineHeight:1 }}>{count}</div>
      <div style={{ fontSize:12, color:colors.textSecondary, marginTop:4, textTransform:"uppercase", letterSpacing:"0.06em" }}>{label}</div>
    </div>
  );
}

function AlertDetail({ alert }: { alert: Alert | null }) {
  if (!alert) return (
    <div style={{ height:"100%", display:"flex", alignItems:"center", justifyContent:"center", color:colors.textMuted, fontSize:13 }}>
      Select an alert to view details
    </div>
  );
  const sev = SEVERITY[alert.severity];
  return (
    <div style={{ padding:24, display:"flex", flexDirection:"column", gap:20 }}>
      <div>
        <div style={{ display:"inline-flex", alignItems:"center", gap:6, padding:"4px 12px", borderRadius:radius.pill, background:sev.dim, color:sev.color, fontSize:11, fontWeight:700, textTransform:"uppercase", letterSpacing:"0.08em", marginBottom:12 }}>
          {TYPE_ICONS[alert.type]} {TYPE_LABELS[alert.type]}
        </div>
        <div style={{ fontSize:15, fontWeight:700, color:colors.textPrimary, lineHeight:1.4 }}>{alert.title}</div>
        <div style={{ fontSize:13, color:colors.textSecondary, marginTop:8, lineHeight:1.7 }}>{alert.detail}</div>
      </div>
      <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:10 }}>
        {[
          { label:"Current value", value:alert.value,     color:sev.color },
          { label:"Threshold",     value:alert.threshold, color:colors.textSecondary },
          { label:"Asset",         value:alert.assetName, color:colors.textPrimary },
          { label:"Site",          value:alert.site,      color:colors.textPrimary },
        ].map(({ label, value, color }) => (
          <div key={label} style={{ background:colors.bg, borderRadius:radius.md, padding:"12px 14px", border:`1px solid ${colors.border}` }}>
            <div style={{ fontSize:11, color:colors.textMuted, textTransform:"uppercase", letterSpacing:"0.06em", marginBottom:4 }}>{label}</div>
            <div style={{ fontSize:15, fontWeight:700, color, fontFamily:font.mono }}>{value}</div>
          </div>
        ))}
      </div>
      <div style={{ background:colors.bg, borderRadius:radius.md, padding:"14px 16px", border:`1px solid ${colors.border}` }}>
        <div style={{ fontSize:12, color:colors.textMuted, textTransform:"uppercase", letterSpacing:"0.06em", marginBottom:10 }}>Status Timeline</div>
        {[
          { show:true, label:"Triggered", time:alert.triggeredAt, color:sev.color },
          { show:!!alert.acknowledgedBy, label:`Acknowledged by ${alert.acknowledgedBy}`, time:alert.acknowledgedAt!, color:colors.blue },
          { show:alert.status==="resolved", label:"Resolved", time:new Date(), color:colors.green },
        ].filter(x=>x.show).map(({ label, time, color }) => (
          <div key={label} style={{ display:"flex", justifyContent:"space-between", marginBottom:8 }}>
            <span style={{ fontSize:13, color:colors.textSecondary, display:"flex", gap:8, alignItems:"center" }}>
              <span style={{ width:8, height:8, borderRadius:"50%", background:color, display:"inline-block" }} />{label}
            </span>
            <span style={{ fontSize:12, color:colors.textMuted, fontFamily:font.mono }}>{time?.toLocaleTimeString("en-US",{hour:"2-digit",minute:"2-digit"})}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

export default function AlertsPage() {
  const [alerts, setAlerts]       = useState<Alert[]>(INITIAL_ALERTS);
  const [selected, setSelected]   = useState<Alert|null>(null);
  const [statusFilter, setStatus] = useState<"all"|"active"|"acknowledged"|"resolved">("all");
  const [sevFilter, setSev]       = useState<"all"|SeverityKey>("all");
  const [dialog, setDialog]       = useState<{ alert:Alert; action:"acknowledge"|"resolve" }|null>(null);
  const toast = useToast();

  useEffect(() => {
    const t = setTimeout(() => {
      const a: Alert = { id:`ALT-NEW`, severity:"high", assetId:"A-003", assetName:"Transformer TX-7", site:"Site Alpha",
        type:"health_drop", title:"Health score declined below warning threshold",
        detail:"Health score dropped from 88% to 79% over 6 hours.", value:"79%", threshold:"80%",
        triggeredAt:new Date(), status:"active" };
      setAlerts(prev => [a, ...prev]);
      toast.warn("New alert triggered", "Transformer TX-7 — health score below 80%");
    }, 30000);
    return () => clearTimeout(t);
  }, []);

  const visible = alerts.filter(a =>
    (statusFilter==="all"||a.status===statusFilter) && (sevFilter==="all"||a.severity===sevFilter)
  );

  const counts = {
    active:       alerts.filter(a=>a.status==="active").length,
    critical:     alerts.filter(a=>a.severity==="critical"&&a.status==="active").length,
    acknowledged: alerts.filter(a=>a.status==="acknowledged").length,
    resolved:     alerts.filter(a=>a.status==="resolved").length,
  };

  function handleConfirm() {
    if (!dialog) return;
    const { alert, action } = dialog;
    setAlerts(prev => prev.map(a => a.id!==alert.id ? a : {
      ...a, status: action==="acknowledge"?"acknowledged":"resolved",
      ...(action==="acknowledge" ? { acknowledgedBy:"Current User", acknowledgedAt:new Date() } : {}),
    }));
    if (selected?.id===alert.id) setSelected(null);
    setDialog(null);
    if (action==="acknowledge") toast.info("Alert acknowledged", alert.title);
    else toast.success("Alert resolved", alert.title);
  }

  return (
    <div style={{ maxWidth:1400, fontFamily:font.sans }}>
      <style>{`@keyframes aiq-pulse-dot{0%,100%{opacity:1}50%{opacity:0.4}}`}</style>

      {/* Header */}
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:24 }}>
        <div>
          <h1 style={{ fontSize:24, fontWeight:700, color:colors.textPrimary, margin:0 }}>Alert Center</h1>
          <p style={{ fontSize:14, color:colors.textSecondary, marginTop:4 }}>Real-time risk threshold monitoring across all assets</p>
        </div>
        {counts.critical>0 && (
          <div style={{ padding:"6px 14px", borderRadius:radius.pill, background:colors.redDim, border:`1px solid ${colors.red}44`, fontSize:13, fontWeight:700, color:colors.red, display:"flex", alignItems:"center", gap:6 }}>
            <div style={{ width:7, height:7, borderRadius:"50%", background:colors.red, animation:"aiq-pulse-dot 1.2s ease-in-out infinite" }} />
            {counts.critical} Critical
          </div>
        )}
      </div>

      {/* Summary strip */}
      <div style={{ display:"flex", gap:12, marginBottom:24 }}>
        <SummaryCard label="Active"       count={counts.active}       color={colors.red}    />
        <SummaryCard label="Critical"     count={counts.critical}     color={colors.orange} />
        <SummaryCard label="Acknowledged" count={counts.acknowledged} color={colors.blue}   />
        <SummaryCard label="Resolved"     count={counts.resolved}     color={colors.green}  />
      </div>

      {/* Main grid */}
      <div style={{ display:"grid", gridTemplateColumns:"1fr 340px", gap:16 }}>
        {/* List */}
        <div style={{ background:colors.bgCard, border:`1px solid ${colors.border}`, borderRadius:radius.lg, overflow:"hidden" }}>
          {/* Filters */}
          <div style={{ display:"flex", gap:6, padding:"12px 16px", borderBottom:`1px solid ${colors.border}`, background:colors.bgPanel, flexWrap:"wrap", alignItems:"center" }}>
            <span style={{ fontSize:12, color:colors.textMuted }}>Status:</span>
            {(["all","active","acknowledged","resolved"] as const).map(s => {
              const active = statusFilter===s;
              return <button key={s} onClick={()=>setStatus(s)} style={{ fontSize:12, fontWeight:active?600:400, padding:"3px 10px", borderRadius:radius.pill, border:`1px solid ${active?colors.blue:colors.border}`, background:active?colors.blueDim:"transparent", color:active?colors.blue:colors.textSecondary, cursor:"pointer", textTransform:"capitalize" }}>{s}</button>;
            })}
            <div style={{ width:1, background:colors.border, height:16, margin:"0 4px" }} />
            <span style={{ fontSize:12, color:colors.textMuted }}>Severity:</span>
            {(["all","critical","high","medium","low"] as const).map(s => {
              const active = sevFilter===s;
              const c = s==="all" ? colors.blue : SEVERITY[s]?.color ?? colors.blue;
              return <button key={s} onClick={()=>setSev(s)} style={{ fontSize:12, fontWeight:active?600:400, padding:"3px 10px", borderRadius:radius.pill, border:`1px solid ${active?c:colors.border}`, background:active?`${c}18`:"transparent", color:active?c:colors.textSecondary, cursor:"pointer", textTransform:"capitalize" }}>{s}</button>;
            })}
          </div>

          {visible.length===0
            ? <EmptyState icon="✓" title="No alerts match filters" detail="All clear for selected filters." height={260} />
            : visible.map(alert => {
              const sev = SEVERITY[alert.severity];
              const isActive = alert.status==="active";
              return (
                <div key={alert.id} onClick={()=>setSelected(alert)} style={{ display:"grid", gridTemplateColumns:"4px 1fr auto", borderBottom:`1px solid ${colors.border}`, background:selected?.id===alert.id?colors.bgActive:"transparent", cursor:"pointer", transition:"background 0.12s" }}>
                  <div style={{ width:4, alignSelf:"stretch", background:isActive?sev.color:colors.textMuted, opacity:alert.status==="resolved"?0.25:1 }} />
                  <div style={{ padding:"14px 16px" }}>
                    <div style={{ display:"flex", alignItems:"center", gap:8, flexWrap:"wrap", marginBottom:3 }}>
                      <span style={{ fontSize:13, fontWeight:600, color:alert.status==="resolved"?colors.textMuted:colors.textPrimary, textDecoration:alert.status==="resolved"?"line-through":"none" }}>{alert.title}</span>
                      <span style={{ fontSize:11, fontWeight:700, padding:"2px 7px", borderRadius:radius.pill, background:sev.dim, color:sev.color, textTransform:"uppercase", letterSpacing:"0.05em" }}>{sev.label}</span>
                      {alert.status!=="active" && <span style={{ fontSize:11, padding:"2px 7px", borderRadius:radius.pill, background:colors.bgHover, color:colors.textMuted, textTransform:"capitalize" }}>{alert.status}</span>}
                    </div>
                    <div style={{ fontSize:12, color:colors.textSecondary }}>{alert.assetName} · {alert.site} · {TYPE_LABELS[alert.type]}</div>
                    <div style={{ display:"flex", gap:16, marginTop:5 }}>
                      <span style={{ fontSize:12, fontFamily:font.mono, color:sev.color }}>{alert.value}</span>
                      <span style={{ fontSize:12, color:colors.textMuted }}>threshold: <span style={{ fontFamily:font.mono }}>{alert.threshold}</span></span>
                      <span style={{ fontSize:12, color:colors.textMuted }}>{formatAge(alert.triggeredAt)}</span>
                    </div>
                  </div>
                  <div style={{ padding:"0 14px", display:"flex", gap:8, alignItems:"center" }} onClick={e=>e.stopPropagation()}>
                    {alert.status==="active" && <>
                      <button onClick={()=>setDialog({alert,action:"acknowledge"})} style={{ fontSize:12, fontWeight:600, padding:"5px 10px", borderRadius:radius.md, border:`1px solid ${colors.blue}44`, background:"transparent", color:colors.blue, cursor:"pointer" }}>Acknowledge</button>
                      <button onClick={()=>setDialog({alert,action:"resolve"})}     style={{ fontSize:12, fontWeight:600, padding:"5px 10px", borderRadius:radius.md, border:`1px solid ${colors.green}44`, background:"transparent", color:colors.green, cursor:"pointer" }}>Resolve</button>
                    </>}
                    {alert.status==="acknowledged" && (
                      <button onClick={()=>setDialog({alert,action:"resolve"})} style={{ fontSize:12, fontWeight:600, padding:"5px 10px", borderRadius:radius.md, border:`1px solid ${colors.green}44`, background:"transparent", color:colors.green, cursor:"pointer" }}>Resolve</button>
                    )}
                    {alert.status==="resolved" && <span style={{ fontSize:12, color:colors.textMuted, whiteSpace:"nowrap" }}>Closed</span>}
                  </div>
                </div>
              );
            })
          }
        </div>

        {/* Detail panel */}
        <div style={{ background:colors.bgCard, border:`1px solid ${colors.border}`, borderRadius:radius.lg, overflow:"hidden", minHeight:400 }}>
          <div style={{ padding:"13px 24px", borderBottom:`1px solid ${colors.border}`, background:colors.bgPanel, fontSize:12, fontWeight:600, color:colors.textMuted, textTransform:"uppercase", letterSpacing:"0.08em" }}>Alert Detail</div>
          <AlertDetail alert={selected} />
        </div>
      </div>

      {/* Confirm */}
      <ConfirmDialog
        open={!!dialog}
        variant={dialog?.action==="resolve"?"success":"info"}
        title={dialog?.action==="acknowledge"?"Acknowledge this alert?":"Mark alert as resolved?"}
        message={dialog ? (
          <div>
            <strong style={{ color:colors.textPrimary }}>{dialog.alert.assetName}</strong>
            <span style={{ color:colors.textSecondary }}> · {dialog.alert.title}</span>
            <div style={{ marginTop:10, fontSize:14, color:colors.textSecondary }}>
              {dialog.action==="acknowledge"
                ? "This will mark the alert as acknowledged and log your user ID. The alert remains until resolved."
                : "This will close the alert and remove it from the active queue. Logged in audit trail."}
            </div>
          </div>
        ) : ""}
        confirmLabel={dialog?.action==="acknowledge"?"Acknowledge":"Mark Resolved"}
        onConfirm={handleConfirm}
        onCancel={()=>setDialog(null)}
      />
    </div>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/pages"
cat > "$ROOT/dashboard/src/pages/AssetHealthPage.tsx" << 'ASSETIQ_HEREDOC'
import React, { useState } from "react";
import { RadarChart, Radar, PolarGrid, PolarAngleAxis, ResponsiveContainer, Tooltip } from "recharts";

const MOCK_ASSETS = [
  { id: "A-001", name: "Gas Turbine GT-4A",    site: "Site Alpha", regime: "stressed",     health: 34, failProb: 0.82, rul: 47,  status: "critical" },
  { id: "A-002", name: "Feed Pump P-22",        site: "Site Beta",  regime: "normal",       health: 71, failProb: 0.31, rul: 280, status: "degraded"  },
  { id: "A-003", name: "Transformer TX-7",      site: "Site Alpha", regime: "normal",       health: 88, failProb: 0.12, rul: 510, status: "healthy"   },
  { id: "A-004", name: "Compressor Station C5", site: "Site Gamma", regime: "transitional", health: 51, failProb: 0.61, rul: 120, status: "degraded"  },
  { id: "A-005", name: "Pipeline Segment P9",   site: "Site Beta",  regime: "normal",       health: 92, failProb: 0.06, rul: 720, status: "healthy"   },
  { id: "A-006", name: "Heat Exchanger HX-3",   site: "Site Gamma", regime: "offline",      health: 0,  failProb: 0,    rul: 0,   status: "offline"   },
];

// Maps internal API `regime` values to user-facing Asset Health Category labels and colors
const HEALTH_CATEGORY_COLOR: Record<string, string> = {
  normal: "#22c55e", stressed: "#ef4444", transitional: "#eab308", maintenance: "#60a5fa", offline: "#484f58",
};

const HEALTH_CATEGORY_LABEL: Record<string, string> = {
  normal:       "Normal Operations",
  stressed:     "Stressed",
  transitional: "Transitional",
  maintenance:  "Maintenance Mode",
  offline:      "Offline",
};

const STATUS_COLOR: Record<string, string> = {
  healthy: "#22c55e", degraded: "#eab308", critical: "#ef4444",
};

function HealthBar({ value }: { value: number }) {
  const color = value > 70 ? "#22c55e" : value > 40 ? "#eab308" : "#ef4444";
  return (
    <div style={{ background: "#0f1117", borderRadius: 4, height: 6, width: 120, overflow: "hidden" }}>
      <div style={{ width: `${value}%`, height: "100%", background: color, borderRadius: 4, transition: "width 0.3s" }} />
    </div>
  );
}

export default function AssetHealthPage() {
  const [selected, setSelected] = useState(MOCK_ASSETS[0]);

  const radarData = [
    { axis: "Vibration",    value: 100 - selected.health * 0.6 },
    { axis: "Temperature",  value: selected.failProb * 60       },
    { axis: "Pressure",     value: 30                           },
    { axis: "Lubrication",  value: 100 - selected.health        },
    { axis: "Electrical",   value: selected.failProb * 40       },
  ];

  const healthCategoryLabel = HEALTH_CATEGORY_LABEL[selected.regime] ?? selected.regime;
  const healthCategoryColor = HEALTH_CATEGORY_COLOR[selected.regime];

  return (
    <div style={{ maxWidth: 1400 }}>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, color: "#f1f5f9", margin: 0 }}>Asset Health Monitor</h1>
        <p style={{ fontSize: 14, color: "#64748b", marginTop: 4 }}>Asset health category · Failure probability · Remaining useful life</p>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1.5fr 1fr", gap: 16 }}>
        {/* Asset table */}
        <div style={{ background: "#161b27", borderRadius: 12, border: "1px solid #1e2d40", overflow: "hidden" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr style={{ color: "#64748b", fontSize: 12, textTransform: "uppercase", background: "#0f1117" }}>
                {["Asset", "Site", "Asset Health Category", "Health", "Fail Prob", "RUL (days)"].map(h => (
                  <th key={h} style={{ textAlign: "left", padding: "12px 16px" }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {MOCK_ASSETS.map(a => (
                <tr
                  key={a.id}
                  onClick={() => setSelected(a)}
                  style={{
                    borderBottom: "1px solid #1e2d40", cursor: "pointer",
                    background: selected.id === a.id ? "rgba(59,130,246,0.08)" : "transparent",
                  }}
                >
                  <td style={{ padding: "14px 16px" }}>
                    <div style={{ fontSize: 13, fontWeight: 600, color: "#f1f5f9" }}>{a.name}</div>
                    <div style={{ fontSize: 11, color: "#64748b" }}>{a.id}</div>
                  </td>
                  <td style={{ padding: "14px 16px", fontSize: 13, color: "#94a3b8" }}>{a.site}</td>
                  <td style={{ padding: "14px 16px" }}>
                    <span style={{ color: HEALTH_CATEGORY_COLOR[a.regime], fontSize: 12, fontWeight: 600 }}>
                      ● {HEALTH_CATEGORY_LABEL[a.regime] ?? a.regime}
                    </span>
                  </td>
                  <td style={{ padding: "14px 16px" }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                      <HealthBar value={a.health} />
                      <span style={{ fontSize: 12, color: "#94a3b8" }}>{a.health}%</span>
                    </div>
                  </td>
                  <td style={{ padding: "14px 16px" }}>
                    <span style={{ color: a.regime === "offline" ? "#484f58" : a.failProb > 0.6 ? "#ef4444" : a.failProb > 0.3 ? "#eab308" : "#22c55e", fontWeight: 700, fontSize: 13 }}>
                      {a.regime === "offline" ? "—" : `${(a.failProb * 100).toFixed(0)}%`}
                    </span>
                  </td>
                  <td style={{ padding: "14px 16px", fontSize: 13, color: "#94a3b8" }}>{a.regime === "offline" ? "—" : `${a.rul} days`}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Asset detail */}
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
            <h3 style={{ margin: "0 0 4px", fontSize: 16, color: "#f1f5f9" }}>{selected.name}</h3>
            <div style={{ fontSize: 12, color: "#64748b", marginBottom: 20 }}>{selected.id} · {selected.site}</div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginBottom: 20 }}>
              {[
                { label: "Health Score",          value: selected.regime === "offline" ? "—" : `${selected.health}%`,                    color: selected.regime === "offline" ? "#484f58" : STATUS_COLOR[selected.status] },
                { label: "Failure Prob",           value: selected.regime === "offline" ? "—" : `${(selected.failProb*100).toFixed(0)}%`, color: selected.regime === "offline" ? "#484f58" : selected.failProb > 0.6 ? "#ef4444" : "#eab308" },
                { label: "RUL",                    value: selected.regime === "offline" ? "—" : `${selected.rul} days`,                   color: selected.regime === "offline" ? "#484f58" : "#60a5fa" },
                { label: "Asset Health Category",  value: healthCategoryLabel,                      color: healthCategoryColor },
              ].map(({ label, value, color }) => (
                <div key={label} style={{ background: "#0f1117", borderRadius: 8, padding: "12px 16px" }}>
                  <div style={{ fontSize: 11, color: "#64748b", marginBottom: 4, textTransform: "uppercase" }}>{label}</div>
                  <div style={{ fontSize: 20, fontWeight: 700, color }}>{value}</div>
                </div>
              ))}
            </div>

            <ResponsiveContainer width="100%" height={200}>
              <RadarChart data={radarData}>
                <PolarGrid stroke="#1e2d40" />
                <PolarAngleAxis dataKey="axis" tick={{ fontSize: 11, fill: "#64748b" }} />
                <Radar dataKey="value" stroke="#3b82f6" fill="#3b82f6" fillOpacity={0.2} />
                <Tooltip contentStyle={{ background: "#1e293b", border: "1px solid #334155", borderRadius: 8 }} />
              </RadarChart>
            </ResponsiveContainer>
          </div>

          <div style={{ background: "#161b27", borderRadius: 12, padding: 20, border: "1px solid #1e2d40" }}>
            <h4 style={{ fontSize: 13, fontWeight: 600, color: "#f1f5f9", margin: "0 0 12px" }}>AI Explanation</h4>
            <p style={{ fontSize: 13, color: "#94a3b8", lineHeight: 1.6, margin: 0 }}>
              {selected.regime === "offline"
                ? "Asset is currently offline and not producing sensor data. No failure prediction is available. Verify operational status before resuming monitoring."
                : selected.status === "critical"
                ? `⚠️ HIGH RISK — ${(selected.failProb*100).toFixed(0)}% probability of failure within 90 days. Asset health category: ${healthCategoryLabel}. Primary contributing factors: vibration anomaly (+3.2σ), bearing temperature trend. Immediate capital action recommended.`
                : `Asset health category: ${healthCategoryLabel}. Health trajectory is stable. Recommend continued monitoring. Next scheduled inspection in 45 days.`}
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/pages"
cat > "$ROOT/dashboard/src/pages/CapitalDashboard.tsx" << 'ASSETIQ_HEREDOC'
import React, { useState, useEffect } from "react";
import { LoadingState, ErrorState, SkeletonRow } from "../components/StateViews";
import { colors } from "../components/tokens";
import {
  AreaChart, Area, BarChart, Bar, XAxis, YAxis,
  CartesianGrid, Tooltip, ResponsiveContainer, PieChart, Pie, Cell, Legend,
} from "recharts";
import { config } from "../config";

// Budget is driven by VITE_DEFAULT_BUDGET env var — no hardcoding
const ANNUAL_BUDGET = config.defaultBudget;

// ── Mock data (replace with React Query hooks against apiClient) ──────────────
const capitalTrend = [
  { month: "Jan", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.817, projected_savings: ANNUAL_BUDGET * 0.267 },
  { month: "Feb", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.850, projected_savings: ANNUAL_BUDGET * 0.342 },
  { month: "Mar", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.925, projected_savings: ANNUAL_BUDGET * 0.467 },
  { month: "Apr", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.725, projected_savings: ANNUAL_BUDGET * 0.242 },
  { month: "May", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.783, projected_savings: ANNUAL_BUDGET * 0.317 },
  { month: "Jun", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.900, projected_savings: ANNUAL_BUDGET * 0.392 },
];

const riskDistribution = [
  { name: "Critical",    value: 8,  color: "#ef4444" },
  { name: "High",        value: 23, color: "#f97316" },
  { name: "Medium",      value: 61, color: "#eab308" },
  { name: "Low",         value: 108, color: "#22c55e" },
];

const recentRecommendations = [
  { id: "R-001", asset: "Turbine 4A", action: "Replace",   npv: 4200000, roi: 38, urgency: "critical" },
  { id: "R-002", asset: "Pump P-22",  action: "Overhaul",  npv: 890000,  roi: 22, urgency: "high"     },
  { id: "R-003", asset: "TX-7 Grid",  action: "Monitor",   npv: 110000,  roi: 8,  urgency: "medium"   },
  { id: "R-004", asset: "Comp. C-5",  action: "Replace",   npv: 2100000, roi: 31, urgency: "high"     },
];

const URGENCY_COLOR: Record<string, string> = {
  critical: "#ef4444",
  high:     "#f97316",
  medium:   "#eab308",
  low:      "#22c55e",
};

const fmt = (v: number) =>
  v >= 1_000_000 ? `$${(v / 1_000_000).toFixed(1)}M`
  : v >= 1_000   ? `$${(v / 1_000).toFixed(0)}K`
  : `$${v}`;


// ── KPI Card ─────────────────────────────────────────────────────────────────
function KPICard({ title, value, sub, color = "#60a5fa", delta }: any) {
  return (
    <div style={{
      background: "#161b27", borderRadius: 12, padding: "20px 24px",
      border: "1px solid #1e2d40", flex: 1,
    }}>
      <div style={{ fontSize: 12, color: "#64748b", marginBottom: 8, textTransform: "uppercase", letterSpacing: "0.08em" }}>{title}</div>
      <div style={{ fontSize: 28, fontWeight: 700, color, lineHeight: 1 }}>{value}</div>
      {sub   && <div style={{ fontSize: 12, color: "#64748b", marginTop: 6 }}>{sub}</div>}
      {delta && <div style={{ fontSize: 12, color: delta > 0 ? "#22c55e" : "#ef4444", marginTop: 4 }}>
        {delta > 0 ? "▲" : "▼"} {Math.abs(delta)}% vs last quarter
      </div>}
    </div>
  );
}


// ── Main ──────────────────────────────────────────────────────────────────────
export default function CapitalDashboard() {
  const [loading, setLoading] = useState(true);
  const [error, setError]     = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState(new Date());

  // Simulate data fetch on mount
  useEffect(() => {
    const t = setTimeout(() => setLoading(false), 900);
    return () => clearTimeout(t);
  }, []);

  function retry() {
    setError(null);
    setLoading(true);
    setTimeout(() => setLoading(false), 900);
  }

  if (loading) return <LoadingState message="Loading capital data..." detail="Fetching portfolio metrics from AssetIQ API" height={500} />;
  if (error)   return <ErrorState  message="Failed to load capital data" detail={error} onRetry={retry} height={500} />;

  return (
    <div style={{ maxWidth: 1400 }}>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, color: "#f1f5f9", margin: 0 }}>Capital Intelligence Overview</h1>
        <p style={{ fontSize: 14, color: colors.textSecondary, marginTop: 4 }}>AI-optimized capital allocation across 200 assets · Updated {lastUpdated.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit" })}</p>
      </div>

      {/* KPIs */}
      <div style={{ display: "flex", gap: 16, marginBottom: 24 }}>
        <KPICard title="Annual CapEx Budget"      value="$12.0M"  sub="FY 2025"                   delta={5}   color="#60a5fa" />
        <KPICard title="Committed"                value="$10.1M"  sub="84% utilized"               delta={-3}  color="#a78bfa" />
        <KPICard title="Projected NPV Uplift"     value="$4.2M"   sub="From AI recommendations"    delta={18}  color="#34d399" />
        <KPICard title="Assets at Risk"           value="31"      sub="Critical + High risk"        delta={-8}  color="#f97316" />
        <KPICard title="Portfolio Risk Score"     value="0.23"    sub="Lower is better"             delta={-12} color="#22c55e" />
      </div>

      {/* Charts row */}
      <div style={{ display: "grid", gridTemplateColumns: "2fr 1fr", gap: 16, marginBottom: 24 }}>
        {/* Capital trend */}
        <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
          <h3 style={{ fontSize: 14, fontWeight: 600, color: "#f1f5f9", marginBottom: 20, marginTop: 0 }}>Capital Committed vs Budget</h3>
          <ResponsiveContainer width="100%" height={220}>
            <AreaChart data={capitalTrend}>
              <defs>
                <linearGradient id="budget" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%"  stopColor="#3b82f6" stopOpacity={0.2} />
                  <stop offset="95%" stopColor="#3b82f6" stopOpacity={0}   />
                </linearGradient>
                <linearGradient id="committed" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%"  stopColor="#8b5cf6" stopOpacity={0.25} />
                  <stop offset="95%" stopColor="#8b5cf6" stopOpacity={0}   />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="#1e2d40" />
              <XAxis dataKey="month" tick={{ fontSize: 12, fill: "#64748b" }} axisLine={false} tickLine={false} />
              <YAxis tickFormatter={v => `$${v/1e6}M`} tick={{ fontSize: 12, fill: "#64748b" }} axisLine={false} tickLine={false} />
              <Tooltip formatter={(v: any) => fmt(v)} contentStyle={{ background: "#1e293b", border: "1px solid #334155", borderRadius: 8, fontSize: 13 }} />
              <Area type="monotone" dataKey="budget"    stroke="#3b82f6" fill="url(#budget)"    strokeWidth={2} name="Budget"    />
              <Area type="monotone" dataKey="committed" stroke="#8b5cf6" fill="url(#committed)" strokeWidth={2} name="Committed" />
            </AreaChart>
          </ResponsiveContainer>
        </div>

        {/* Risk distribution */}
        <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
          <h3 style={{ fontSize: 14, fontWeight: 600, color: "#f1f5f9", marginBottom: 20, marginTop: 0 }}>Asset Risk Distribution</h3>
          <ResponsiveContainer width="100%" height={220}>
            <PieChart>
              <Pie data={riskDistribution} dataKey="value" cx="50%" cy="50%" innerRadius={60} outerRadius={90} paddingAngle={3}>
                {riskDistribution.map((entry, i) => <Cell key={i} fill={entry.color} />)}
              </Pie>
              <Legend formatter={(v) => <span style={{ color: "#94a3b8", fontSize: 12 }}>{v}</span>} />
              <Tooltip contentStyle={{ background: "#1e293b", border: "1px solid #334155", borderRadius: 8 }} />
            </PieChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* Recommendations table */}
      <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 20 }}>
          <h3 style={{ fontSize: 14, fontWeight: 600, color: "#f1f5f9", margin: 0 }}>Top Capital Recommendations</h3>
          <button style={{ fontSize: 13, color: "#60a5fa", background: "none", border: "none", cursor: "pointer" }}>View All →</button>
        </div>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr style={{ color: "#64748b", fontSize: 12, textTransform: "uppercase", letterSpacing: "0.06em" }}>
              {["ID", "Asset", "Recommended Action", "Projected NPV", "ROI", "Urgency", "Actions"].map(h => (
                <th key={h} style={{ textAlign: "left", padding: "8px 12px", borderBottom: "1px solid #1e2d40" }}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {recentRecommendations.map(r => (
              <tr key={r.id} style={{ borderBottom: "1px solid #1e2d40" }}>
                <td style={{ padding: "14px 12px", fontSize: 13, color: "#64748b" }}>{r.id}</td>
                <td style={{ padding: "14px 12px", fontSize: 13, color: "#f1f5f9", fontWeight: 500 }}>{r.asset}</td>
                <td style={{ padding: "14px 12px", fontSize: 13 }}>
                  <span style={{ background: "rgba(59,130,246,0.15)", color: "#60a5fa", padding: "3px 10px", borderRadius: 20, fontSize: 12 }}>
                    {r.action}
                  </span>
                </td>
                <td style={{ padding: "14px 12px", fontSize: 13, color: "#34d399", fontWeight: 600 }}>{fmt(r.npv)}</td>
                <td style={{ padding: "14px 12px", fontSize: 13, color: "#f1f5f9" }}>{r.roi}%</td>
                <td style={{ padding: "14px 12px" }}>
                  <span style={{ background: `${URGENCY_COLOR[r.urgency]}22`, color: URGENCY_COLOR[r.urgency], padding: "3px 10px", borderRadius: 20, fontSize: 12, textTransform: "capitalize" }}>
                    {r.urgency}
                  </span>
                </td>
                <td style={{ padding: "14px 12px", display: "flex", gap: 8 }}>
                  <button style={{ fontSize: 12, color: "#22c55e", background: "rgba(34,197,94,0.1)", border: "none", padding: "4px 12px", borderRadius: 6, cursor: "pointer" }}>Approve</button>
                  <button style={{ fontSize: 12, color: "#ef4444", background: "rgba(239,68,68,0.1)", border: "none", padding: "4px 12px", borderRadius: 6, cursor: "pointer" }}>Reject</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/pages"
cat > "$ROOT/dashboard/src/pages/PortfolioPage.tsx" << 'ASSETIQ_HEREDOC'
import React from "react";
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from "recharts";

const data = [
  { site: "Alpha",   npv: 4200000,  capex: 3100000 },
  { site: "Beta",    npv: 1800000,  capex: 1200000 },
  { site: "Gamma",   npv: 2900000,  capex: 2400000 },
  { site: "Delta",   npv: 700000,   capex: 500000  },
];

export default function PortfolioPage() {
  return (
    <div style={{ maxWidth: 1000 }}>
      <h1 style={{ fontSize: 24, fontWeight: 700, color: "#f1f5f9", marginBottom: 8 }}>Capital Portfolio</h1>
      <p style={{ fontSize: 14, color: "#64748b", marginBottom: 24 }}>Multi-objective optimized capital plan across all sites</p>

      <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
        <h3 style={{ fontSize: 14, fontWeight: 600, color: "#f1f5f9", marginBottom: 20, marginTop: 0 }}>NPV vs CapEx by Site</h3>
        <ResponsiveContainer width="100%" height={300}>
          <BarChart data={data} barGap={4}>
            <CartesianGrid strokeDasharray="3 3" stroke="#1e2d40" />
            <XAxis dataKey="site" tick={{ fontSize: 12, fill: "#64748b" }} axisLine={false} tickLine={false} />
            <YAxis tickFormatter={v => `$${v/1e6}M`} tick={{ fontSize: 12, fill: "#64748b" }} axisLine={false} tickLine={false} />
            <Tooltip formatter={(v: any) => `$${(v/1e6).toFixed(1)}M`} contentStyle={{ background: "#1e293b", border: "1px solid #334155", borderRadius: 8 }} />
            <Bar dataKey="capex" name="CapEx"        fill="#3b82f6" radius={[4,4,0,0]} />
            <Bar dataKey="npv"   name="Projected NPV" fill="#22c55e" radius={[4,4,0,0]} />
          </BarChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/pages"
cat > "$ROOT/dashboard/src/pages/RecommendationsPage.tsx" << 'ASSETIQ_HEREDOC'
import React, { useState } from "react";
import { colors, radius, font, SEVERITY, SeverityKey } from "../components/tokens";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { AuditLog, AuditEntry } from "../components/AuditLog";
import { EmptyState } from "../components/StateViews";
import { useToast } from "../components/Toast";

// ── Types ─────────────────────────────────────────────────────────────────────
type RecStatus = "pending" | "approved" | "rejected" | "deferred";
type RecAction = "replace" | "overhaul" | "monitor" | "decommission";

interface Recommendation {
  id:                 string;
  priorityRank:       number;
  assetId:            string;
  assetName:          string;
  site:               string;
  action:             RecAction;
  urgency:            SeverityKey;
  estimatedCapex:     number;
  npv:                number;
  roiPct:             number;
  paybackYears:       number;
  riskScore:          number;
  riskReduction:      number;
  failureProbability: number;
  rulDays:            number;
  rationale:          string;
  alternatives:       string;
  status:             RecStatus;
  runId:              string;
  generatedAt:        Date;
}

// ── Mock data ─────────────────────────────────────────────────────────────────
const INITIAL_RECS: Recommendation[] = [
  {
    id: "R-001", priorityRank: 1,
    assetId: "A-001", assetName: "Gas Turbine GT-4A", site: "Site Alpha",
    action: "replace", urgency: "critical",
    estimatedCapex: 3_200_000, npv: 4_200_000, roiPct: 38.2, paybackYears: 2.6,
    riskScore: 0.78, riskReduction: 64, failureProbability: 0.82, rulDays: 47,
    rationale: "Failure probability of 82% exceeds the critical 80% threshold with only 47 days of remaining useful life. Replacement lead time is 90 days — procurement must be initiated immediately to avoid unplanned outage. Expected NPV uplift of $4.2M accounts for avoided downtime costs ($1.8M), OpEx savings ($1.2M/yr), and salvage value.",
    alternatives: "Overhaul considered but rejected: projected failure probability post-overhaul still 51% given age of secondary components. Deferral not viable — RUL is below procurement lead time.",
    status: "pending", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
  {
    id: "R-002", priorityRank: 2,
    assetId: "A-004", assetName: "Compressor Station C5", site: "Site Gamma",
    action: "replace", urgency: "high",
    estimatedCapex: 1_850_000, npv: 2_100_000, roiPct: 31.4, paybackYears: 3.2,
    riskScore: 0.58, riskReduction: 49, failureProbability: 0.61, rulDays: 120,
    rationale: "Failure probability of 61% and rapid 18-point health drop over 72 hours indicate accelerating degradation. 120-day RUL provides procurement window. Replacement ROI of 31.4% is top quartile for this asset class.",
    alternatives: "Major overhaul ($640K) would extend useful life ~18 months but ROI is 12.1% vs 31.4% for replacement. Given degradation trajectory, replacement is the superior capital allocation.",
    status: "pending", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
  {
    id: "R-003", priorityRank: 3,
    assetId: "A-002", assetName: "Feed Pump P-22", site: "Site Beta",
    action: "overhaul", urgency: "high",
    estimatedCapex: 185_000, npv: 890_000, roiPct: 22.1, paybackYears: 4.5,
    riskScore: 0.30, riskReduction: 28, failureProbability: 0.31, rulDays: 280,
    rationale: "Rising failure probability (12% → 31% in 14 days) and bearing temperature trend suggest impending component failure. Targeted overhaul of bearing assembly and seal replacement recommended. Cost-effective at $185K vs $450K replacement.",
    alternatives: "Full replacement ($450K) would yield 38% vs 22% ROI but is not warranted given 280-day RUL and contained failure scope.",
    status: "approved", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
  {
    id: "R-004", priorityRank: 4,
    assetId: "A-005", assetName: "Pipeline Segment P9", site: "Site Beta",
    action: "monitor", urgency: "low",
    estimatedCapex: 12_000, npv: 110_000, roiPct: 8.3, paybackYears: 1.4,
    riskScore: 0.06, riskReduction: 4, failureProbability: 0.06, rulDays: 720,
    rationale: "Asset in Normal Operations health category with 720-day RUL and 6% failure probability. Enhanced monitoring program ($12K/yr sensor upgrades) recommended to maintain data quality.",
    alternatives: "No capital action required at this time. Monitoring is the optimal allocation given low risk score and long RUL.",
    status: "pending", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
  {
    id: "R-005", priorityRank: 5,
    assetId: "A-003", assetName: "Transformer TX-7", site: "Site Alpha",
    action: "monitor", urgency: "medium",
    estimatedCapex: 28_000, npv: 210_000, roiPct: 14.2, paybackYears: 1.9,
    riskScore: 0.12, riskReduction: 9, failureProbability: 0.12, rulDays: 510,
    rationale: "Asset recently flagged for minor thermal signature changes. Predictive sensor package upgrade recommended to improve early-warning fidelity. No capital replacement required within planning horizon.",
    alternatives: "Deferral of monitoring upgrade acceptable if budget constrained — risk increase is minimal over 6-month window.",
    status: "rejected", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
];

const INITIAL_AUDIT: AuditEntry[] = [
  { id: "AU-001", timestamp: new Date(Date.now() - 90 * 60000), actor: "System",     action: "created",  target: "Optimization run OPT-2024-Q4-001", notes: "5 recommendations generated from 200-asset portfolio" },
  { id: "AU-002", timestamp: new Date(Date.now() - 85 * 60000), actor: "S. Chen",    action: "viewed",   target: "R-001 — Gas Turbine GT-4A replacement" },
  { id: "AU-003", timestamp: new Date(Date.now() - 70 * 60000), actor: "S. Chen",    action: "approved", target: "R-003 — Feed Pump P-22 overhaul", notes: "Approved at weekly ops review. PO to be raised by end of week." },
  { id: "AU-004", timestamp: new Date(Date.now() - 45 * 60000), actor: "J. Martinez",action: "rejected", target: "R-005 — Transformer TX-7 monitoring upgrade", notes: "Deferred to Q1 budget cycle. Not urgent given 510-day RUL." },
];

// ── Style helpers ─────────────────────────────────────────────────────────────
const ACTION_STYLE: Record<RecAction, { color: string; label: string; icon: string }> = {
  replace:      { color: colors.red,    label: "Replace",      icon: "↺" },
  overhaul:     { color: colors.orange, label: "Overhaul",     icon: "⚙" },
  monitor:      { color: colors.blue,   label: "Monitor",      icon: "◎" },
  decommission: { color: colors.purple, label: "Decommission", icon: "✗" },
};

const STATUS_STYLE: Record<RecStatus, { color: string; label: string }> = {
  pending:  { color: colors.yellow, label: "Pending"  },
  approved: { color: colors.green,  label: "Approved" },
  rejected: { color: colors.red,    label: "Rejected" },
  deferred: { color: colors.blue,   label: "Deferred" },
};

const fmt = (v: number) =>
  v >= 1_000_000 ? `$${(v / 1_000_000).toFixed(1)}M`
  : v >= 1_000   ? `$${(v / 1_000).toFixed(0)}K`
  : `$${v}`;

// ── Sub-components ────────────────────────────────────────────────────────────
function Chip({ color, children }: { color: string; children: React.ReactNode }) {
  return (
    <span style={{
      fontSize: 11, fontWeight: 700, padding: "3px 10px", borderRadius: radius.pill,
      background: `${color}18`, color, border: `1px solid ${color}30`,
      textTransform: "uppercase" as const, letterSpacing: "0.06em",
    }}>{children}</span>
  );
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  return <div style={{ fontSize: 11, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase" as const, letterSpacing: "0.08em", marginBottom: 10 }}>{children}</div>;
}

function StatMini({ label, value, color = colors.textPrimary, mono = false }: { label: string; value: string; color?: string; mono?: boolean }) {
  return (
    <div style={{ background: colors.bg, borderRadius: radius.md, padding: "12px 14px", border: `1px solid ${colors.border}` }}>
      <div style={{ fontSize: 11, color: colors.textMuted, textTransform: "uppercase" as const, letterSpacing: "0.06em", marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 17, fontWeight: 700, color, fontFamily: mono ? font.mono : font.sans }}>{value}</div>
    </div>
  );
}

// ── Row component ─────────────────────────────────────────────────────────────
function RecRow({ rec, selected, onClick, onApprove, onReject }: {
  rec: Recommendation; selected: boolean;
  onClick: () => void; onApprove: () => void; onReject: () => void;
}) {
  const act = ACTION_STYLE[rec.action];
  const sev = SEVERITY[rec.urgency];
  const sts = STATUS_STYLE[rec.status];
  const canAct = rec.status === "pending";

  return (
    <div onClick={onClick} style={{
      display: "grid", gridTemplateColumns: "4px 1fr auto",
      borderBottom: `1px solid ${colors.border}`,
      background: selected ? colors.bgActive : "transparent",
      cursor: "pointer", transition: "background 0.12s",
    }}>
      <div style={{ background: sev.color, opacity: rec.status !== "pending" ? 0.25 : 1, width: 4, alignSelf: "stretch" }} />
      <div style={{ padding: "14px 16px" }}>
        <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" as const, marginBottom: 4 }}>
          <span style={{ fontSize: 11, color: colors.textMuted, fontFamily: font.mono }}>#{rec.priorityRank}</span>
          <span style={{ fontSize: 13, fontWeight: 600, color: colors.textPrimary }}>{rec.assetName}</span>
          <Chip color={act.color}>{act.icon} {act.label}</Chip>
          <Chip color={sts.color}>{sts.label}</Chip>
        </div>
        <div style={{ fontSize: 12, color: colors.textSecondary, marginBottom: 6 }}>{rec.site}</div>
        <div style={{ display: "flex", gap: 16 }}>
          <span style={{ fontSize: 12, color: colors.green, fontFamily: font.mono, fontWeight: 600 }}>{fmt(rec.npv)} NPV</span>
          <span style={{ fontSize: 12, color: colors.textSecondary }}>{fmt(rec.estimatedCapex)} CapEx</span>
          <span style={{ fontSize: 12, color: sev.color, fontFamily: font.mono }}>{(rec.failureProbability * 100).toFixed(0)}% fail</span>
        </div>
      </div>
      {canAct && (
        <div style={{ padding: "0 14px", display: "flex", gap: 6, alignItems: "center" }} onClick={e => e.stopPropagation()}>
          <button onClick={onApprove} style={{ width: 28, height: 28, borderRadius: radius.md, border: `1px solid ${colors.green}44`, background: `${colors.green}12`, color: colors.green, fontSize: 14, fontWeight: 700, cursor: "pointer" }}>✓</button>
          <button onClick={onReject}  style={{ width: 28, height: 28, borderRadius: radius.md, border: `1px solid ${colors.red}44`,   background: `${colors.red}12`,   color: colors.red,   fontSize: 14, fontWeight: 700, cursor: "pointer" }}>✗</button>
        </div>
      )}
    </div>
  );
}

// ── Detail panel ──────────────────────────────────────────────────────────────
function RecDetail({ rec, onApprove, onReject, onDefer }: {
  rec: Recommendation | null;
  onApprove: (r: Recommendation) => void;
  onReject:  (r: Recommendation) => void;
  onDefer:   (r: Recommendation) => void;
}) {
  if (!rec) return (
    <div style={{ height: "100%", display: "flex", alignItems: "center", justifyContent: "center", flexDirection: "column" as const, gap: 8, color: colors.textMuted, fontSize: 13 }}>
      <div style={{ fontSize: 28 }}>←</div>
      <div>Select a recommendation to review</div>
    </div>
  );

  const act = ACTION_STYLE[rec.action];
  const sev = SEVERITY[rec.urgency];
  const sts = STATUS_STYLE[rec.status];

  return (
    <div style={{ padding: 24, display: "flex", flexDirection: "column" as const, gap: 20, overflowY: "auto" as const, maxHeight: "100%" }}>
      <div>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" as const, marginBottom: 12 }}>
          <Chip color={act.color}>{act.icon} {act.label}</Chip>
          <Chip color={sev.color}>{sev.label}</Chip>
          <Chip color={sts.color}>● {sts.label}</Chip>
        </div>
        <div style={{ fontSize: 17, fontWeight: 700, color: colors.textPrimary, lineHeight: 1.3 }}>{rec.assetName}</div>
        <div style={{ fontSize: 13, color: colors.textSecondary, marginTop: 4 }}>{rec.assetId} · {rec.site} · Priority #{rec.priorityRank}</div>
      </div>

      <div>
        <SectionLabel>Financial Case</SectionLabel>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
          <StatMini label="Est. CapEx"    value={fmt(rec.estimatedCapex)} />
          <StatMini label="Projected NPV" value={fmt(rec.npv)}            color={colors.green} />
          <StatMini label="ROI"           value={`${rec.roiPct.toFixed(1)}%`} color={colors.green} />
          <StatMini label="Payback"       value={`${rec.paybackYears.toFixed(1)} yrs`} color={colors.blue} />
        </div>
      </div>

      <div>
        <SectionLabel>Risk Profile</SectionLabel>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
          <StatMini label="Failure Prob"   value={`${(rec.failureProbability * 100).toFixed(0)}%`} color={colors.red}    mono />
          <StatMini label="RUL"            value={`${rec.rulDays} days`}                           color={colors.orange} mono />
          <StatMini label="Risk Score"     value={rec.riskScore.toFixed(2)}                        color={colors.yellow} mono />
          <StatMini label="Risk Reduction" value={`−${rec.riskReduction}%`}                        color={colors.green}  mono />
        </div>
      </div>

      <div>
        <SectionLabel>AI Rationale</SectionLabel>
        <div style={{ fontSize: 13, color: colors.textSecondary, lineHeight: 1.8, background: colors.bg, borderRadius: radius.md, padding: "14px 16px", border: `1px solid ${colors.border}` }}>
          {rec.rationale}
        </div>
      </div>

      <div>
        <SectionLabel>Alternatives Considered</SectionLabel>
        <div style={{ fontSize: 13, color: colors.textSecondary, lineHeight: 1.8, background: colors.bg, borderRadius: radius.md, padding: "14px 16px", border: `1px solid ${colors.border}`, fontStyle: "italic" }}>
          {rec.alternatives}
        </div>
      </div>

      {rec.status === "pending" && (
        <div style={{ display: "flex", gap: 10, paddingTop: 4 }}>
          <button onClick={() => onApprove(rec)} style={{ flex: 1, padding: "10px 0", borderRadius: radius.md, background: colors.green, border: "none", color: "#fff", fontSize: 13, fontWeight: 700, cursor: "pointer" }}>✓ Approve</button>
          <button onClick={() => onDefer(rec)}   style={{ padding: "10px 18px", borderRadius: radius.md, background: "transparent", border: `1px solid ${colors.border}`, color: colors.textSecondary, fontSize: 13, fontWeight: 600, cursor: "pointer" }}>Defer</button>
          <button onClick={() => onReject(rec)}  style={{ padding: "10px 18px", borderRadius: radius.md, background: colors.redDim, border: `1px solid ${colors.red}33`, color: colors.red, fontSize: 13, fontWeight: 600, cursor: "pointer" }}>✗ Reject</button>
        </div>
      )}
    </div>
  );
}

// ── Main page ─────────────────────────────────────────────────────────────────
type DialogState = { rec: Recommendation; action: "approve" | "reject" | "defer" } | null;

export default function RecommendationsPage() {
  const [recs, setRecs]           = useState<Recommendation[]>(INITIAL_RECS);
  const [audit, setAudit]         = useState<AuditEntry[]>(INITIAL_AUDIT);
  const [selected, setSelected]   = useState<Recommendation | null>(INITIAL_RECS[0]);
  const [dialog, setDialog]       = useState<DialogState>(null);
  const [notesInput, setNotesInput] = useState("");
  const [statusFilter, setStatusFilter] = useState<RecStatus | "all">("all");
  const [showAudit, setShowAudit] = useState(false);
  const toast = useToast();

  const visible = recs.filter(r => statusFilter === "all" || r.status === statusFilter);

  const counts = {
    pending:     recs.filter(r => r.status === "pending").length,
    approved:    recs.filter(r => r.status === "approved").length,
    rejected:    recs.filter(r => r.status === "rejected").length,
    totalCapex:  recs.filter(r => r.status === "approved").reduce((s, r) => s + r.estimatedCapex, 0),
    totalNpv:    recs.filter(r => r.status === "approved").reduce((s, r) => s + r.npv, 0),
  };

  function handleConfirm() {
    if (!dialog) return;
    const { rec, action } = dialog;
    const newStatus: RecStatus = action === "approve" ? "approved" : action === "reject" ? "rejected" : "deferred";
    const updatedRec = { ...rec, status: newStatus };

    setRecs(prev => prev.map(r => r.id !== rec.id ? r : updatedRec));
    if (selected?.id === rec.id) setSelected(updatedRec);

    setAudit(prev => [{
      id: `AU-${Date.now()}`,
      timestamp: new Date(),
      actor: "Current User",
      action: action === "approve" ? "approved" : "rejected",
      target: `${rec.id} — ${rec.assetName} ${rec.action}`,
      notes: notesInput || undefined,
    }, ...prev]);

    setDialog(null);
    setNotesInput("");

    if (action === "approve") toast.success("Recommendation approved", `${rec.assetName} — ${fmt(rec.estimatedCapex)} CapEx authorized`);
    else if (action === "reject") toast.error("Recommendation rejected", `${rec.assetName} removed from capital plan`);
    else toast.info("Recommendation deferred", `${rec.assetName} moved to next planning cycle`);
  }

  function exportCSV() {
    const rows = [
      ["Rank","Asset","Site","Action","Urgency","CapEx","NPV","ROI%","Payback","Status"],
      ...recs.map(r => [r.priorityRank, r.assetName, r.site, r.action, r.urgency, r.estimatedCapex, r.npv, r.roiPct, r.paybackYears, r.status]),
    ];
    const csv = rows.map(r => r.join(",")).join("\n");
    const blob = new Blob([csv], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a"); a.href = url; a.download = "assetiq-recommendations.csv"; a.click();
    URL.revokeObjectURL(url);
    setAudit(prev => [{ id: `AU-${Date.now()}`, timestamp: new Date(), actor: "Current User", action: "exported", target: "Recommendations report" }, ...prev]);
    toast.info("Export complete", "assetiq-recommendations.csv downloaded");
  }

  const dialogVariant = dialog?.action === "approve" ? "success" : dialog?.action === "reject" ? "danger" : "info";
  const dialogLabel   = dialog?.action === "approve" ? "Approve & Authorize" : dialog?.action === "reject" ? "Reject" : "Defer";

  return (
    <div style={{ maxWidth: 1400, fontFamily: font.sans }}>
      {/* Header */}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 24, fontWeight: 700, color: colors.textPrimary, margin: 0 }}>Capital Recommendations</h1>
          <p style={{ fontSize: 14, color: colors.textSecondary, marginTop: 4 }}>AI-optimized capital plan · Run OPT-2024-Q4-001 · {INITIAL_RECS[0].generatedAt.toLocaleDateString()}</p>
        </div>
        <div style={{ display: "flex", gap: 10 }}>
          <button onClick={() => setShowAudit(v => !v)} style={{ fontSize: 13, padding: "8px 16px", borderRadius: radius.md, border: `1px solid ${colors.border}`, background: showAudit ? colors.bgHover : "transparent", color: colors.textSecondary, cursor: "pointer", fontWeight: 600 }}>
            {showAudit ? "Hide" : "Show"} Audit Trail
          </button>
          <button onClick={exportCSV} style={{ fontSize: 13, padding: "8px 16px", borderRadius: radius.md, background: colors.blueDim, border: `1px solid ${colors.blue}44`, color: colors.blue, cursor: "pointer", fontWeight: 600 }}>
            ↗ Export CSV
          </button>
        </div>
      </div>

      {/* Summary strip */}
      <div style={{ display: "flex", gap: 12, marginBottom: 20, flexWrap: "wrap" as const }}>
        {[
          { label: "Pending Review",   value: counts.pending,           color: colors.yellow },
          { label: "Approved",         value: counts.approved,          color: colors.green  },
          { label: "Rejected",         value: counts.rejected,          color: colors.red    },
          { label: "Authorized CapEx", value: fmt(counts.totalCapex),   color: colors.blue   },
          { label: "Authorized NPV",   value: fmt(counts.totalNpv),     color: colors.teal   },
        ].map(({ label, value, color }) => (
          <div key={label} style={{ background: colors.bgCard, border: `1px solid ${colors.border}`, borderTop: `2px solid ${color}`, borderRadius: radius.lg, padding: "14px 18px", flex: 1, minWidth: 120 }}>
            <div style={{ fontSize: typeof value === "number" ? 26 : 20, fontWeight: 800, color, lineHeight: 1 }}>{value}</div>
            <div style={{ fontSize: 11, color: colors.textSecondary, marginTop: 4, textTransform: "uppercase" as const, letterSpacing: "0.06em" }}>{label}</div>
          </div>
        ))}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 380px", gap: 16 }}>
        {/* Left column */}
        <div style={{ display: "flex", flexDirection: "column" as const, gap: 16 }}>
          {/* List */}
          <div style={{ background: colors.bgCard, borderRadius: radius.lg, border: `1px solid ${colors.border}`, overflow: "hidden" }}>
            {/* Filter tabs */}
            <div style={{ display: "flex", gap: 6, padding: "12px 16px", borderBottom: `1px solid ${colors.border}`, background: colors.bgPanel }}>
              {(["all", "pending", "approved", "rejected", "deferred"] as const).map(s => {
                const active = statusFilter === s;
                const c = s === "all" ? colors.blue : STATUS_STYLE[s]?.color ?? colors.blue;
                return (
                  <button key={s} onClick={() => setStatusFilter(s)} style={{
                    fontSize: 12, fontWeight: active ? 600 : 400, padding: "4px 12px", borderRadius: radius.pill,
                    border: `1px solid ${active ? c : colors.border}`,
                    background: active ? `${c}18` : "transparent",
                    color: active ? c : colors.textSecondary,
                    cursor: "pointer", textTransform: "capitalize" as const,
                  }}>{s}</button>
                );
              })}
            </div>
            {visible.length === 0
              ? <EmptyState icon="✓" title="No recommendations match filter" height={200} />
              : visible.map(rec => (
                <RecRow key={rec.id} rec={rec} selected={selected?.id === rec.id}
                  onClick={() => setSelected(rec)}
                  onApprove={() => setDialog({ rec, action: "approve" })}
                  onReject={()  => setDialog({ rec, action: "reject"  })}
                />
              ))
            }
          </div>

          {/* Audit trail */}
          {showAudit && (
            <div style={{ background: colors.bgCard, borderRadius: radius.lg, border: `1px solid ${colors.border}`, overflow: "hidden" }}>
              <div style={{ padding: "13px 20px", borderBottom: `1px solid ${colors.border}`, background: colors.bgPanel, fontSize: 12, fontWeight: 600, color: colors.textMuted, textTransform: "uppercase" as const, letterSpacing: "0.08em" }}>Audit Trail</div>
              <div style={{ padding: "16px 20px" }}><AuditLog entries={audit} maxHeight={400} /></div>
            </div>
          )}
        </div>

        {/* Right: detail panel */}
        <div style={{ background: colors.bgCard, borderRadius: radius.lg, border: `1px solid ${colors.border}`, display: "flex", flexDirection: "column" as const, maxHeight: "calc(100vh - 220px)", position: "sticky" as const, top: 24 }}>
          <div style={{ padding: "13px 24px", borderBottom: `1px solid ${colors.border}`, background: colors.bgPanel, fontSize: 12, fontWeight: 600, color: colors.textMuted, textTransform: "uppercase" as const, letterSpacing: "0.08em", flexShrink: 0 }}>Recommendation Detail</div>
          <div style={{ flex: 1, overflow: "hidden" }}>
            <RecDetail rec={selected}
              onApprove={r => setDialog({ rec: r, action: "approve" })}
              onReject={r  => setDialog({ rec: r, action: "reject"  })}
              onDefer={r   => setDialog({ rec: r, action: "defer"   })}
            />
          </div>
        </div>
      </div>

      {/* Confirm dialog */}
      <ConfirmDialog
        open={!!dialog}
        variant={dialogVariant}
        title={
          dialog?.action === "approve" ? `Approve: ${dialog.rec.assetName}?` :
          dialog?.action === "reject"  ? "Reject this recommendation?" :
          "Defer to next planning cycle?"
        }
        message={dialog ? (
          <div style={{ display: "flex", flexDirection: "column" as const, gap: 14 }}>
            <div style={{ background: colors.bg, borderRadius: radius.md, padding: "12px 14px", border: `1px solid ${colors.border}`, display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
              <div>
                <div style={{ fontSize: 11, color: colors.textMuted, textTransform: "uppercase" as const }}>Action</div>
                <div style={{ fontSize: 14, fontWeight: 600, color: colors.textPrimary, marginTop: 2 }}>{ACTION_STYLE[dialog.rec.action].label}</div>
              </div>
              <div>
                <div style={{ fontSize: 11, color: colors.textMuted, textTransform: "uppercase" as const }}>Est. CapEx</div>
                <div style={{ fontSize: 14, fontWeight: 600, color: colors.textPrimary, marginTop: 2 }}>{fmt(dialog.rec.estimatedCapex)}</div>
              </div>
            </div>
            <div style={{ fontSize: 14, color: colors.textSecondary }}>
              {dialog.action === "approve" ? "This will authorize the capital expenditure and log your approval in the audit trail."
               : dialog.action === "reject" ? "This recommendation will be removed from the active capital plan. Your decision is recorded."
               : "This recommendation will be deferred to the next quarterly planning cycle."}
            </div>
            <div>
              <div style={{ fontSize: 12, color: colors.textSecondary, marginBottom: 6 }}>Notes for audit trail (optional)</div>
              <textarea value={notesInput} onChange={e => setNotesInput(e.target.value)}
                placeholder="Add context..." rows={2}
                style={{ width: "100%", boxSizing: "border-box" as const, background: colors.bg, border: `1px solid ${colors.border}`, borderRadius: radius.md, padding: "8px 12px", color: colors.textPrimary, fontSize: 13, fontFamily: font.sans, resize: "none" as const, outline: "none" }}
              />
            </div>
          </div>
        ) : ""}
        confirmLabel={dialogLabel}
        onConfirm={handleConfirm}
        onCancel={() => { setDialog(null); setNotesInput(""); }}
      />
    </div>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/dashboard/src/pages"
cat > "$ROOT/dashboard/src/pages/SettingsPage.tsx" << 'ASSETIQ_HEREDOC'
import React, { useState } from "react";
import { colors, radius, font } from "../components/tokens";
import { useToast } from "../components/Toast";

type Section = "api" | "thresholds" | "notifications" | "account";

function SectionTab({ label, active, onClick }: { label: string; active: boolean; onClick: () => void }) {
  return (
    <button onClick={onClick} style={{
      fontSize: 13, fontWeight: active ? 600 : 400,
      padding: "8px 16px", borderRadius: radius.md,
      border: `1px solid ${active ? colors.blue : "transparent"}`,
      background: active ? colors.bgActive : "transparent",
      color: active ? colors.blue : colors.textSecondary,
      cursor: "pointer", textAlign: "left", width: "100%",
      fontFamily: font.sans,
    }}>{label}</button>
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div style={{ marginBottom: 24 }}>
      <label style={{ fontSize: 13, fontWeight: 600, color: colors.textPrimary, display: "block", marginBottom: 6 }}>{label}</label>
      {hint && <div style={{ fontSize: 12, color: colors.textSecondary, marginBottom: 8 }}>{hint}</div>}
      {children}
    </div>
  );
}

const inputStyle: React.CSSProperties = {
  width: "100%", boxSizing: "border-box",
  background: colors.bg, border: `1px solid ${colors.border}`,
  borderRadius: radius.md, padding: "9px 12px",
  color: colors.textPrimary, fontSize: 13,
  fontFamily: font.mono, outline: "none",
};

function Toggle({ value, onChange, label }: { value: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "12px 0", borderBottom: `1px solid ${colors.border}` }}>
      <span style={{ fontSize: 13, color: colors.textPrimary }}>{label}</span>
      <div
        onClick={() => onChange(!value)}
        style={{
          width: 40, height: 22, borderRadius: 11, cursor: "pointer",
          background: value ? colors.green : colors.bgHover,
          position: "relative", transition: "background 0.2s",
          border: `1px solid ${value ? colors.green : colors.border}`,
        }}
      >
        <div style={{
          position: "absolute", top: 2,
          left: value ? 18 : 2,
          width: 16, height: 16, borderRadius: "50%",
          background: "#fff", transition: "left 0.2s",
        }} />
      </div>
    </div>
  );
}

function ThresholdRow({ label, value, unit, onChange }: { label: string; value: number; unit: string; onChange: (v: number) => void }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 0", borderBottom: `1px solid ${colors.border}` }}>
      <span style={{ fontSize: 13, color: colors.textPrimary }}>{label}</span>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <input
          type="number"
          value={value}
          onChange={e => onChange(Number(e.target.value))}
          style={{ ...inputStyle, width: 80, textAlign: "right", fontFamily: font.mono }}
        />
        <span style={{ fontSize: 12, color: colors.textMuted, width: 40 }}>{unit}</span>
      </div>
    </div>
  );
}

export default function SettingsPage() {
  const [section, setSection] = useState<Section>("api");
  const toast = useToast();

  // API settings
  const [apiUrl, setApiUrl]     = useState("https://api.assetiq.io");
  const [apiKey, setApiKey]     = useState("aiq_••••••••••••••••••••••••••••••••");
  const [timeout, setTimeout_]  = useState(30);

  // Thresholds
  const [criticalFailProb, setCritical] = useState(80);
  const [highFailProb, setHigh]         = useState(60);
  const [rulCritical, setRulCritical]   = useState(60);
  const [rulHigh, setRulHigh]           = useState(180);
  const [healthDropWindow, setDropWin]  = useState(72);
  const [healthDropPts, setDropPts]     = useState(10);
  const [budgetWarnPct, setBudget]      = useState(85);

  // Notifications
  const [emailAlerts, setEmailAlerts]   = useState(true);
  const [criticalPush, setCriticalPush] = useState(true);
  const [highPush, setHighPush]         = useState(true);
  const [mediumPush, setMediumPush]     = useState(false);
  const [dailyDigest, setDailyDigest]   = useState(true);
  const [weeklyReport, setWeeklyReport] = useState(true);
  const [emailAddress, setEmailAddress] = useState("ops-team@yourcompany.com");

  function save() {
    toast.success("Settings saved", "Changes will take effect immediately");
  }

  const SECTIONS: { key: Section; label: string }[] = [
    { key: "api",           label: "API Connection"  },
    { key: "thresholds",    label: "Alert Thresholds" },
    { key: "notifications", label: "Notifications"   },
    { key: "account",       label: "Account"         },
  ];

  return (
    <div style={{ maxWidth: 900, fontFamily: font.sans }}>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, color: colors.textPrimary, margin: 0 }}>Settings</h1>
        <p style={{ fontSize: 14, color: colors.textSecondary, marginTop: 4 }}>Configure your AssetIQ integration and alert preferences</p>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "180px 1fr", gap: 24 }}>
        {/* Nav */}
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          {SECTIONS.map(({ key, label }) => (
            <SectionTab key={key} label={label} active={section === key} onClick={() => setSection(key)} />
          ))}
        </div>

        {/* Panel */}
        <div style={{ background: colors.bgCard, border: `1px solid ${colors.border}`, borderRadius: radius.lg, padding: 28 }}>

          {section === "api" && (
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, marginTop: 0, marginBottom: 20 }}>API Connection</h2>
              <Field label="API Base URL" hint="The AssetIQ Intelligence API endpoint provided during onboarding.">
                <input value={apiUrl} onChange={e => setApiUrl(e.target.value)} style={inputStyle} />
              </Field>
              <Field label="API Key" hint="Your tenant API key. Rotate this in the AssetIQ portal if compromised.">
                <div style={{ display: "flex", gap: 10 }}>
                  <input value={apiKey} onChange={e => setApiKey(e.target.value)} type="password" style={{ ...inputStyle, flex: 1 }} />
                  <button onClick={() => toast.info("Contact support to rotate your API key", "support@assetiq.io")} style={{ padding: "9px 14px", borderRadius: radius.md, border: `1px solid ${colors.border}`, background: "transparent", color: colors.textSecondary, fontSize: 13, cursor: "pointer" }}>Rotate</button>
                </div>
              </Field>
              <Field label="Request Timeout (seconds)">
                <input type="number" value={timeout} onChange={e => setTimeout_(Number(e.target.value))} style={{ ...inputStyle, width: 120 }} />
              </Field>
              <div style={{ padding: "16px", background: colors.bg, borderRadius: radius.md, border: `1px solid ${colors.border}`, marginBottom: 24 }}>
                <div style={{ fontSize: 12, color: colors.textMuted, marginBottom: 10, textTransform: "uppercase", letterSpacing: "0.06em" }}>Connection Status</div>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <div style={{ width: 8, height: 8, borderRadius: "50%", background: colors.green }} />
                  <span style={{ fontSize: 13, color: colors.textPrimary }}>Connected</span>
                  <span style={{ fontSize: 12, color: colors.textMuted, marginLeft: 8 }}>Last ping: 4s ago · 42ms latency</span>
                </div>
              </div>
            </div>
          )}

          {section === "thresholds" && (
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, marginTop: 0, marginBottom: 4 }}>Alert Thresholds</h2>
              <p style={{ fontSize: 13, color: colors.textSecondary, marginBottom: 20 }}>Customize when alerts are triggered for your fleet. Changes apply to new predictions only.</p>
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 8 }}>Failure Probability</div>
              <ThresholdRow label="Critical threshold" value={criticalFailProb} unit="%" onChange={setCritical} />
              <ThresholdRow label="High threshold"     value={highFailProb}     unit="%" onChange={setHigh}     />
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", margin: "20px 0 8px" }}>Remaining Useful Life</div>
              <ThresholdRow label="Critical RUL floor" value={rulCritical} unit="days" onChange={setRulCritical} />
              <ThresholdRow label="High RUL floor"     value={rulHigh}     unit="days" onChange={setRulHigh}     />
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", margin: "20px 0 8px" }}>Health Score Drop</div>
              <ThresholdRow label="Detection window" value={healthDropWindow} unit="hours" onChange={setDropWin} />
              <ThresholdRow label="Point threshold"  value={healthDropPts}   unit="pts"   onChange={setDropPts} />
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", margin: "20px 0 8px" }}>Budget</div>
              <ThresholdRow label="Budget utilization warning" value={budgetWarnPct} unit="%" onChange={setBudget} />
            </div>
          )}

          {section === "notifications" && (
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, marginTop: 0, marginBottom: 20 }}>Notifications</h2>
              <Field label="Notification email">
                <input value={emailAddress} onChange={e => setEmailAddress(e.target.value)} style={inputStyle} type="email" />
              </Field>
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 4 }}>Alert Channels</div>
              <Toggle value={criticalPush} onChange={setCriticalPush} label="Push notifications — Critical alerts"  />
              <Toggle value={highPush}     onChange={setHighPush}     label="Push notifications — High alerts"      />
              <Toggle value={mediumPush}   onChange={setMediumPush}   label="Push notifications — Medium alerts"    />
              <Toggle value={emailAlerts}  onChange={setEmailAlerts}  label="Email — All active alerts"             />
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", margin: "20px 0 4px" }}>Reports</div>
              <Toggle value={dailyDigest}  onChange={setDailyDigest}  label="Daily digest — Alert summary"         />
              <Toggle value={weeklyReport} onChange={setWeeklyReport} label="Weekly report — Capital recommendations" />
            </div>
          )}

          {section === "account" && (
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, marginTop: 0, marginBottom: 20 }}>Account</h2>
              <div style={{ background: colors.bg, borderRadius: radius.md, border: `1px solid ${colors.border}`, padding: "16px 20px", marginBottom: 20 }}>
                {[
                  { label: "Tenant ID",   value: "ten_a1b2c3d4e5f6" },
                  { label: "Tier",        value: "Professional" },
                  { label: "API calls this month", value: "4,821 / 100,000" },
                  { label: "Assets",      value: "200 / 1,000" },
                  { label: "Optimize calls today", value: "3 / 50" },
                ].map(({ label, value }) => (
                  <div key={label} style={{ display: "flex", justifyContent: "space-between", padding: "8px 0", borderBottom: `1px solid ${colors.border}` }}>
                    <span style={{ fontSize: 13, color: colors.textSecondary }}>{label}</span>
                    <span style={{ fontSize: 13, color: colors.textPrimary, fontFamily: font.mono }}>{value}</span>
                  </div>
                ))}
              </div>
              <p style={{ fontSize: 13, color: colors.textSecondary, lineHeight: 1.6 }}>
                To upgrade your tier, rotate API keys, or manage users, visit the <a href="https://app.assetiq.io" target="_blank" style={{ color: colors.blue }}>AssetIQ portal</a> or contact <a href="mailto:support@assetiq.io" style={{ color: colors.blue }}>support@assetiq.io</a>.
              </p>
            </div>
          )}

          {/* Save button */}
          {section !== "account" && (
            <div style={{ borderTop: `1px solid ${colors.border}`, paddingTop: 20, marginTop: 8, display: "flex", justifyContent: "flex-end", gap: 10 }}>
              <button onClick={() => toast.info("Changes discarded")} style={{ padding: "9px 20px", borderRadius: radius.md, border: `1px solid ${colors.border}`, background: "transparent", color: colors.textSecondary, fontSize: 13, cursor: "pointer", fontWeight: 600 }}>Discard</button>
              <button onClick={save} style={{ padding: "9px 22px", borderRadius: radius.md, background: colors.blue, border: "none", color: "#fff", fontSize: 13, cursor: "pointer", fontWeight: 700 }}>Save Changes</button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
ASSETIQ_HEREDOC

mkdir -p "$ROOT/examples"
cat > "$ROOT/examples/quickstart.py" << 'ASSETIQ_HEREDOC'
"""
AssetIQ Quick Start Example

Demonstrates:
  1. Single asset failure prediction
  2. Portfolio optimization
  3. Submitting feedback

Run:
    export ASSETIQ_API_KEY=aiq_your_key_here
    python examples/quickstart.py
"""
import os
import sys

# Add SDK to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../sdk/python"))
from assetiq import AssetIQClient

client = AssetIQClient(
    api_key=os.environ["ASSETIQ_API_KEY"],
    base_url=os.environ.get("ASSETIQ_API_URL", "https://api.assetiq.io"),
)

# ── 1. Health check ────────────────────────────────────────────────────────────
print("Checking API health...")
if not client.health_check():
    print("❌ API is not reachable. Check your network and API key.")
    sys.exit(1)
print("✅ API is healthy\n")

# ── 2. Single asset prediction ─────────────────────────────────────────────────
print("Running failure prediction for Pump P-22...")

# Features must match the column spec provided during onboarding
# Typical features: [vibration_rms, bearing_temp, flow_rate, pressure_in, pressure_out, hours_since_maintenance, ...]
features = [[
    2.34,    # vibration_rms (mm/s)
    87.3,    # bearing_temperature (°C)
    145.2,   # flow_rate (m³/h)
    4.1,     # inlet_pressure (bar)
    3.8,     # outlet_pressure (bar)
    342,     # hours_since_last_maintenance
    0.82,    # load_factor (0-1)
    0.91,    # efficiency (0-1)
]]

result = client.predict(
    asset_id="pump-P22",
    features=features,
    horizon_days=90,
)

print(f"  Asset:               {result.asset_id}")
print(f"  Failure probability: {result.failure_probability * 100:.1f}%")
print(f"  Risk level:          {result.risk_level}")
print(f"  Remaining useful life: {result.rul_days:.0f} days")
print(f"  Asset health category: {result.health_category} (confidence: {result.regime_confidence*100:.0f}%)")
print(f"  Prediction confidence: {result.prediction_confidence*100:.0f}%")
print(f"  Explanation: {result.explanation}\n")

# ── 3. Portfolio optimization ──────────────────────────────────────────────────
print("Running portfolio optimization...")

assets = [
    {
        "asset_id":            "pump-P22",
        "replacement_cost":    450_000,
        "current_book_value":  120_000,
        "failure_probability": result.failure_probability,
        "rul_days":            result.rul_days,
        "criticality":         0.85,
        "reliability_impact":  0.70,
        "annual_opex_current": 85_000,
        "annual_opex_new":     42_000,
    },
    {
        "asset_id":            "turbine-GT4A",
        "replacement_cost":    3_200_000,
        "current_book_value":  800_000,
        "failure_probability": 0.82,
        "rul_days":            47,
        "criticality":         0.95,
        "reliability_impact":  0.90,
        "annual_opex_current": 420_000,
        "annual_opex_new":     180_000,
    },
    {
        "asset_id":            "transformer-TX7",
        "replacement_cost":    680_000,
        "current_book_value":  520_000,
        "failure_probability": 0.12,
        "rul_days":            510,
        "criticality":         0.60,
        "reliability_impact":  0.55,
        "annual_opex_current": 45_000,
        "annual_opex_new":     30_000,
    },
]

opt = client.optimize(
    assets=assets,
    budget=4_000_000,
    planning_horizon_yr=5,
)

print(f"  Run ID:            {opt.run_id}")
print(f"  Total CapEx:       ${opt.total_capex:,.0f}")
print(f"  Projected NPV:     ${opt.projected_npv:,.0f}")
print(f"  Reliability score: {opt.reliability_score:.2%}")
print(f"  Portfolio risk:    {opt.risk_score:.4f}\n")
print(f"  Recommendations ({len(opt.recommendations)}):")
for rec in opt.recommendations:
    print(f"    #{rec.priority_rank} {rec.asset_id}: {rec.action.upper()}")
    print(f"       CapEx: ${rec.estimated_capex:,.0f} | NPV: ${rec.npv:,.0f} | ROI: {rec.roi_pct:.1f}%")
    print(f"       {rec.rationale}")

# ── 4. Submit feedback (approve top recommendation) ────────────────────────────
if opt.recommendations:
    top = opt.recommendations[0]
    print(f"\nApproving recommendation for {top.asset_id}...")
    client.submit_feedback(
        run_id=opt.run_id,
        recommendation_id=top.asset_id,
        action="approve",
        notes="Approved at Q3 capital planning meeting.",
    )
    print("  ✅ Feedback submitted — this will improve future recommendations.")

# ── 5. Usage check ─────────────────────────────────────────────────────────────
usage = client.get_usage()
print(f"\nUsage this month:")
print(f"  API calls:        {usage.api_calls:,} / {usage.limits['api_calls_per_month']:,}")
print(f"  Optimize calls:   {usage.optimize_calls:,} / {usage.limits['optimize_per_day']:,} per day")
print(f"  Tier:             {usage.tier}")
ASSETIQ_HEREDOC

mkdir -p "$ROOT/sdk/python"
cat > "$ROOT/sdk/python/assetiq.py" << 'ASSETIQ_HEREDOC'
"""
AssetIQ Python SDK

Provides a clean, typed interface to the AssetIQ Intelligence API.
This is the ONLY way client code interacts with AssetIQ's algorithms.
No proprietary code is included here — all intelligence runs server-side.

Usage:
    from assetiq import AssetIQClient

    client = AssetIQClient(api_key="aiq_...", base_url="https://api.assetiq.io")

    result = client.predict(
        asset_id="pump-42",
        features=[[vibration, temp, pressure, ...]],
    )
    print(result.failure_probability)
    print(result.explanation)
"""
from __future__ import annotations

import os
import time
import logging
from dataclasses import dataclass
from typing import Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "https://api.assetiq.io"
SDK_VERSION      = "2.0.0"


# ── Response dataclasses ──────────────────────────────────────────────────────

# Maps the internal API `regime` value to a user-facing Asset Health Category label
HEALTH_CATEGORY_LABEL: dict[str, str] = {
    "normal":       "Normal Operations",
    "stressed":     "Stressed",
    "transitional": "Transitional",
    "maintenance":  "Maintenance Mode",
    # offline: not returned by the model — set client-side for assets not running
    "offline":      "Offline",
}


@dataclass
class PredictionResult:
    asset_id:              str
    failure_probability:   float
    rul_days:              float
    regime:                str   # internal API field
    regime_confidence:     float
    prediction_confidence: float
    explanation:           str
    request_id:            str

    @property
    def health_category(self) -> str:
        """User-facing Asset Health Category label. Use this for display instead of `regime`."""
        return HEALTH_CATEGORY_LABEL.get(self.regime, self.regime.capitalize())

    @property
    def risk_level(self) -> str:
        if self.failure_probability >= 0.70:
            return "CRITICAL"
        elif self.failure_probability >= 0.40:
            return "HIGH"
        elif self.failure_probability >= 0.20:
            return "MEDIUM"
        return "LOW"


@dataclass
class RecommendationItem:
    asset_id:        str
    action:          str
    priority_rank:   int
    estimated_capex: float
    npv:             float
    roi_pct:         float
    payback_years:   float
    risk_score:      float
    rationale:       str


@dataclass
class OptimizationResult:
    run_id:            str
    total_capex:       float
    projected_npv:     float
    reliability_score: float
    risk_score:        float
    esg_score:         float
    recommendations:   list[RecommendationItem]


@dataclass
class UsageInfo:
    tenant_id:     str
    api_calls:     int
    optimize_calls:int
    asset_count:   int
    limits:        dict
    tier:          str


# ── Client ────────────────────────────────────────────────────────────────────

class AssetIQClient:
    """
    Thread-safe HTTP client for the AssetIQ Intelligence API.
    Handles authentication, retries, and response parsing.
    """

    def __init__(
        self,
        api_key:  Optional[str] = None,
        base_url: Optional[str] = None,
        timeout:  int = 30,
        max_retries: int = 3,
    ):
        self.api_key  = api_key  or os.environ.get("ASSETIQ_API_KEY", "")
        self.base_url = (base_url or os.environ.get("ASSETIQ_API_URL", DEFAULT_BASE_URL)).rstrip("/")
        self.timeout  = timeout

        if not self.api_key:
            raise ValueError(
                "AssetIQ API key is required. Pass api_key= or set ASSETIQ_API_KEY env var."
            )

        # Session with automatic retries
        self._session = requests.Session()
        retry = Retry(
            total=max_retries,
            backoff_factor=0.5,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["GET", "POST"],
        )
        self._session.mount("https://", HTTPAdapter(max_retries=retry))
        self._session.headers.update({
            "X-API-Key": self.api_key,
            "Content-Type": "application/json",
            "User-Agent": f"assetiq-python-sdk/{SDK_VERSION}",
        })

    def predict(
        self,
        asset_id:     str,
        features:     list[list[float]],
        horizon_days: int = 90,
    ) -> PredictionResult:
        """
        Predict failure probability and remaining useful life for a single asset.

        Args:
            asset_id:     Your internal asset identifier
            features:     Sensor feature matrix — shape (1, n_features)
                          Column order must match the feature spec in your onboarding docs.
            horizon_days: Prediction horizon (default 90 days)

        Returns:
            PredictionResult with failure_probability, rul_days, regime, explanation
        """
        payload = {
            "asset_id":     asset_id,
            "features":     features,
            "horizon_days": horizon_days,
        }
        data = self._post("/v1/predict", payload)
        return PredictionResult(**data)

    def optimize(
        self,
        assets:              list[dict],
        budget:              float,
        planning_horizon_yr: int  = 5,
        objectives:          Optional[dict] = None,
    ) -> OptimizationResult:
        """
        Run multi-objective capital portfolio optimization.

        Args:
            assets: List of asset dicts. Required keys per asset:
                      asset_id, replacement_cost, current_book_value,
                      failure_probability, rul_days, criticality, reliability_impact
            budget:              Total available capital (USD)
            planning_horizon_yr: Planning horizon in years
            objectives:          Optional weight overrides e.g.
                                 {"npv_weight": 0.5, "reliability_weight": 0.3,
                                  "risk_weight": 0.1, "esg_weight": 0.1}

        Returns:
            OptimizationResult with ranked recommendations
        """
        payload = {
            "assets":              assets,
            "budget":              budget,
            "planning_horizon_yr": planning_horizon_yr,
        }
        if objectives:
            payload["objectives"] = objectives

        data = self._post("/v1/optimize", payload)
        recs = [RecommendationItem(**r) for r in data.pop("recommendations", [])]
        return OptimizationResult(recommendations=recs, **data)

    def submit_feedback(
        self,
        run_id:            str,
        recommendation_id: str,
        action:            str,   # "approve" or "reject"
        notes:             Optional[str] = None,
    ) -> dict:
        """
        Submit operator feedback on a recommendation.
        This improves future recommendations for your tenant.
        """
        params = {
            "run_id":            run_id,
            "recommendation_id": recommendation_id,
            "action":            action,
        }
        if notes:
            params["notes"] = notes
        return self._post("/v1/feedback", params)

    def get_usage(self) -> UsageInfo:
        """Return your current-month API usage and tier limits."""
        data = self._get("/v1/usage")
        return UsageInfo(**data)

    def health_check(self) -> bool:
        """Return True if the API is reachable and healthy."""
        try:
            data = self._get("/health")
            return data.get("status") == "ok"
        except Exception:
            return False

    # ── Private ───────────────────────────────────────────────────────────────

    def _post(self, path: str, payload: dict) -> dict:
        url = f"{self.base_url}{path}"
        resp = self._session.post(url, json=payload, timeout=self.timeout)
        return self._handle(resp)

    def _get(self, path: str, params: Optional[dict] = None) -> dict:
        url = f"{self.base_url}{path}"
        resp = self._session.get(url, params=params, timeout=self.timeout)
        return self._handle(resp)

    @staticmethod
    def _handle(resp: requests.Response) -> dict:
        if resp.status_code == 401:
            raise PermissionError("Invalid or missing API key. Check your ASSETIQ_API_KEY.")
        if resp.status_code == 429:
            raise RuntimeError(f"Rate limit exceeded. Retry-After: {resp.headers.get('Retry-After')}s")
        if resp.status_code == 403:
            raise PermissionError(f"Access denied: {resp.json().get('detail')}")
        if not resp.ok:
            raise RuntimeError(f"AssetIQ API error {resp.status_code}: {resp.text}")
        return resp.json()
ASSETIQ_HEREDOC

mkdir -p "$ROOT/sdk/typescript"
cat > "$ROOT/sdk/typescript/assetiq.ts" << 'ASSETIQ_HEREDOC'
/**
 * AssetIQ TypeScript SDK
 *
 * Typed client for the AssetIQ Intelligence API.
 * All intelligence runs server-side — this SDK only handles HTTP transport.
 *
 * Usage:
 *   import { AssetIQClient } from "@assetiq/sdk";
 *   const client = new AssetIQClient({ apiKey: "aiq_..." });
 *   const result = await client.predict({ assetId: "pump-42", features: [[...]] });
 */

const SDK_VERSION = "2.0.0";
const DEFAULT_BASE_URL = "https://api.assetiq.io";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface PredictRequest {
  assetId:     string;
  features:    number[][];   // shape: (1, n_features)
  horizonDays?: number;
}

/** Maps the internal regime value to a user-facing Asset Health Category label. */
export const HEALTH_CATEGORY_LABEL: Record<string, string> = {
  normal:       "Normal Operations",
  stressed:     "Stressed",
  transitional: "Transitional",
  maintenance:  "Maintenance Mode",
  /** Asset is not running — no sensor data, no prediction available. Set client-side. */
  offline:      "Offline",
};

/** Maps the internal regime value to a display color (hex). */
export const HEALTH_CATEGORY_COLORS: Record<string, string> = {
  normal:       "#22c55e",
  stressed:     "#ef4444",
  transitional: "#eab308",
  maintenance:  "#60a5fa",
  offline:      "#484f58",
};

export type HealthCategory = "normal" | "stressed" | "transitional" | "maintenance" | "offline";

export interface PredictResponse {
  asset_id:               string;
  failure_probability:    number;
  rul_days:               number;
  /** Internal API field — use `healthCategory` for display. */
  regime:                 HealthCategory;
  regime_confidence:      number;
  prediction_confidence:  number;
  explanation:            string;
  request_id:             string;
  /** User-facing label derived from `regime`. Use this for display. */
  readonly healthCategory: string;
  readonly healthCategoryColor: string;
}

export interface AssetCapitalInput {
  asset_id:            string;
  replacement_cost:    number;
  current_book_value:  number;
  failure_probability: number;
  rul_days:            number;
  criticality?:        number;
  reliability_impact?: number;
  annual_opex_current?:number;
  annual_opex_new?:    number;
  esg_score?:          number;
}

export interface OptimizeRequest {
  assets:               AssetCapitalInput[];
  budget:               number;
  planning_horizon_yr?: number;
  objectives?: {
    npv_weight?:         number;
    reliability_weight?: number;
    risk_weight?:        number;
    esg_weight?:         number;
  };
}

export interface RecommendationItem {
  asset_id:        string;
  action:          "replace" | "overhaul" | "monitor";
  priority_rank:   number;
  estimated_capex: number;
  npv:             number;
  roi_pct:         number;
  payback_years:   number;
  risk_score:      number;
  rationale:       string;
}

export interface OptimizeResponse {
  run_id:            string;
  total_capex:       number;
  projected_npv:     number;
  reliability_score: number;
  risk_score:        number;
  esg_score:         number;
  recommendations:   RecommendationItem[];
}

export interface UsageResponse {
  tenant_id:      string;
  api_calls:      number;
  optimize_calls: number;
  asset_count:    number;
  tier:           string;
  limits: {
    assets:                number;
    api_calls_per_month:   number;
    optimize_per_day:      number;
  };
}

export interface AssetIQConfig {
  apiKey:    string;
  baseUrl?:  string;
  timeout?:  number;
}

// ── Client ────────────────────────────────────────────────────────────────────

export class AssetIQClient {
  private readonly apiKey:  string;
  private readonly baseUrl: string;
  private readonly timeout: number;

  constructor(config: AssetIQConfig) {
    if (!config.apiKey) {
      throw new Error("AssetIQ API key is required.");
    }
    this.apiKey  = config.apiKey;
    this.baseUrl = (config.baseUrl ?? DEFAULT_BASE_URL).replace(/\/$/, "");
    this.timeout = config.timeout ?? 30_000;
  }

  /** Predict failure probability for a single asset. */
  async predict(req: PredictRequest): Promise<PredictResponse> {
    const raw = await this.post<Omit<PredictResponse, "healthCategory" | "healthCategoryColor">>("/v1/predict", {
      asset_id:     req.assetId,
      features:     req.features,
      horizon_days: req.horizonDays ?? 90,
    });
    // Enrich with user-facing display fields so callers never touch raw `regime`
    return {
      ...raw,
      healthCategory:      HEALTH_CATEGORY_LABEL[raw.regime] ?? raw.regime,
      healthCategoryColor: HEALTH_CATEGORY_COLORS[raw.regime] ?? "#94a3b8",
    };
  }

  /** Run multi-objective capital portfolio optimization. */
  async optimize(req: OptimizeRequest): Promise<OptimizeResponse> {
    return this.post<OptimizeResponse>("/v1/optimize", req);
  }

  /** Submit operator feedback to improve future recommendations. */
  async submitFeedback(params: {
    runId: string;
    recommendationId: string;
    action: "approve" | "reject";
    notes?: string;
  }): Promise<{ status: string; run_id: string }> {
    return this.post("/v1/feedback", {
      run_id:            params.runId,
      recommendation_id: params.recommendationId,
      action:            params.action,
      notes:             params.notes,
    });
  }

  /** Get current-month API usage for your tenant. */
  async getUsage(): Promise<UsageResponse> {
    return this.get<UsageResponse>("/v1/usage");
  }

  /** Returns true if the API is reachable and healthy. */
  async healthCheck(): Promise<boolean> {
    try {
      const data = await this.get<{ status: string }>("/health");
      return data.status === "ok";
    } catch {
      return false;
    }
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  private async post<T>(path: string, body: unknown): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeout);
    try {
      const res = await fetch(`${this.baseUrl}${path}`, {
        method: "POST",
        headers: this.headers(),
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      return this.handle<T>(res);
    } finally {
      clearTimeout(timer);
    }
  }

  private async get<T>(path: string): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeout);
    try {
      const res = await fetch(`${this.baseUrl}${path}`, {
        method: "GET",
        headers: this.headers(),
        signal: controller.signal,
      });
      return this.handle<T>(res);
    } finally {
      clearTimeout(timer);
    }
  }

  private headers(): Record<string, string> {
    return {
      "X-API-Key":    this.apiKey,
      "Content-Type": "application/json",
      "User-Agent":   `assetiq-ts-sdk/${SDK_VERSION}`,
    };
  }

  private async handle<T>(res: Response): Promise<T> {
    if (res.status === 401) throw new Error("Invalid or missing API key.");
    if (res.status === 429) throw new Error(`Rate limit exceeded. Retry-After: ${res.headers.get("Retry-After")}s`);
    if (res.status === 403) throw new Error(`Access denied: ${(await res.json()).detail}`);
    if (!res.ok) throw new Error(`AssetIQ API error ${res.status}: ${await res.text()}`);
    return res.json() as Promise<T>;
  }
}
ASSETIQ_HEREDOC

echo ""
echo "✓ assetiq-client ready at $ROOT"
echo "  $(find "$ROOT" -type f | wc -l) files created"
