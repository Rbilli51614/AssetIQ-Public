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
