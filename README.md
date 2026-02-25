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
