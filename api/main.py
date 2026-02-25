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
