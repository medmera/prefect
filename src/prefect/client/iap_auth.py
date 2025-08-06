import asyncio
import json
import threading
import time
from typing import Generator, Optional

import google.auth
import google.auth.transport.requests
import google.cloud.secretmanager as secretmanager
import httpx
from google.auth.credentials import Credentials as GoogleCredentials

from prefect.settings import (
    PREFECT_API_IAP_AUTH_HEADER_NAME,
    PREFECT_API_IAP_CLIENT_ID_GCP_SECRET_VERSION,
    PREFECT_API_IAP_IMPERSONATE_SERVICE_ACCOUNT,
)


class IAPTokenManager:
    """
    Singleton that manages ID tokens for Google Cloud Identity-Aware Proxy (IAP).

    This class handles:
    - Getting access tokens using Application Default Credentials
    - Calling the Service Account Credentials API to generate ID tokens
    - Caching tokens and managing expiration
    - Thread-safe operations for both sync and async usage
    """

    _instance = None
    _lock = threading.Lock()

    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
        return cls._instance

    def __init__(self):
        if hasattr(self, "_initialized"):
            return

        self._initialized = True
        self._sync_lock = threading.RLock()
        self._async_lock = asyncio.Lock()
        self._cached_token = None
        self._token_expiry = 0
        self._credentials = None
        self._client_id = None

    def _get_application_credentials(self) -> GoogleCredentials:
        """Get Application Default Credentials"""
        if self._credentials is None:
            self._credentials, _ = google.auth.default(
                scopes=["https://www.googleapis.com/auth/cloud-platform"]
            )

        # Refresh if needed
        if not self._credentials.valid:
            self._credentials.refresh(google.auth.transport.requests.Request())

        return self._credentials

    @property
    def client_id(self) -> str:
        """Get the client ID from the secret manager"""
        if self._client_id:
            return self._client_id

        self._client_id = self._get_client_id_from_secret()
        return self._client_id

    def _get_client_id_from_secret(self) -> str:
        """Fetch client ID from Google Secret Manager"""
        if self._client_id:
            return self._client_id

        secret_version = PREFECT_API_IAP_CLIENT_ID_GCP_SECRET_VERSION.value()
        if not secret_version:
            raise ValueError(
                "PREFECT_API_IAP_CLIENT_ID_GCP_SECRET_VERSION must be set to the "
                "full secret version path (e.g., 'projects/PROJECT/secrets/SECRET/versions/VERSION')"
            )

        client = secretmanager.SecretManagerServiceClient()
        response = client.access_secret_version(name=secret_version)

        # The secret should contain just the client ID or a JSON with client_id field
        secret_data = response.payload.data.decode("UTF-8").strip()

        try:
            # Try parsing as JSON first
            secret_json = json.loads(secret_data)
            if isinstance(secret_json, dict) and "client_id" in secret_json:
                return secret_json["client_id"]
            elif isinstance(secret_json, dict) and "web" in secret_json:
                return secret_json["web"]["client_id"]
            elif isinstance(secret_json, dict) and "installed" in secret_json:
                return secret_json["installed"]["client_id"]
        except json.JSONDecodeError:
            pass

        # Assume it's just the client ID string
        return secret_data

    def _generate_id_token(self, audience: str) -> tuple[str, float]:
        """
        Generate an ID token using the Service Account Credentials API.

        Returns:
            tuple: (id_token, expiry_timestamp)
        """
        service_account = PREFECT_API_IAP_IMPERSONATE_SERVICE_ACCOUNT.value()
        if not service_account:
            raise ValueError(
                "PREFECT_API_IAP_IMPERSONATE_SERVICE_ACCOUNT must be set to the "
                "email address of the service account to impersonate"
            )

        # Get access token for authentication
        credentials = self._get_application_credentials()
        access_token = credentials.token

        # Call the generateIdToken API
        url = f"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{service_account}:generateIdToken"

        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json; charset=utf-8",
        }

        payload = {"audience": audience, "includeEmail": "true"}

        response = httpx.post(url, headers=headers, json=payload)
        response.raise_for_status()

        token_data = response.json()
        id_token = token_data["token"]

        # Calculate expiry (ID tokens are valid for 1 hour)
        expiry_timestamp = time.time() + 3600  # 1 hour from now

        return id_token, expiry_timestamp

    def _is_token_expired(self) -> bool:
        """Check if the cached token is expired (with 5 minute buffer)"""
        return time.time() >= (self._token_expiry - 300)  # 5 minute buffer

    def get_id_token(self, audience: Optional[str] = None) -> str:
        """
        Get a valid ID token for IAP authentication.

        Args:
            audience: The audience for the token. If not provided, will use the
                     client ID from the secret manager.

        Returns:
            Valid ID token string
        """
        with self._sync_lock:
            if audience is None:
                audience = self.client_id

            # Return cached token if still valid
            if self._cached_token and not self._is_token_expired():
                return self._cached_token

            # Generate new token
            self._cached_token, self._token_expiry = self._generate_id_token(audience)
            return self._cached_token

    async def get_id_token_async(self, audience: Optional[str] = None) -> str:
        """
        Async version of get_id_token.

        Note: The underlying operations are still synchronous (Google API calls),
        but this method ensures thread safety in async contexts.
        """
        async with self._async_lock:
            # Run the synchronous token operations in a thread pool
            loop = asyncio.get_event_loop()
            return await loop.run_in_executor(None, self.get_id_token, audience)

    def clear_cached_token(self) -> None:
        """Clear the cached token to force refresh on next request"""
        with self._sync_lock:
            self._cached_token = None
            self._token_expiry = 0

    def get_id_token_header(self) -> dict[str, str]:
        """Get the ID token header for IAP authentication"""
        return {
            f"{PREFECT_API_IAP_AUTH_HEADER_NAME}": f"Bearer {self.get_id_token()}",
        }


class IAPAuth(httpx.Auth):
    """
    Custom httpx authentication for Google Cloud Identity-Aware Proxy (IAP).

    This auth class uses the IAPTokenManager singleton to get ID tokens
    and handles the authentication flow for httpx requests.
    """

    def __init__(self, auth_header_name: Optional[str] = None):
        """
        Initialize IAP authentication.

        Args:
            audience: The audience for the token. If not provided, will use the
                     client ID from the secret manager.
            auth_header_name: Name of the authorization header. If not provided, will use
                             the value from PREFECT_API_IAP_AUTH_HEADER_NAME setting.
        """
        self.auth_header_name = (
            auth_header_name or PREFECT_API_IAP_AUTH_HEADER_NAME.value()
        )
        self.token_manager = IAPTokenManager()

    def sync_auth_flow(
        self, request: httpx.Request
    ) -> Generator[httpx.Request, httpx.Response, None]:
        """
        Synchronous authentication flow for httpx.Client.

        This method handles:
        1. Getting a valid ID token from the token manager
        2. Adding authentication headers to the request
        3. Handling 401 responses by clearing cache and retrying
        """
        # Get ID token and add to headers
        id_token = self.token_manager.get_id_token()
        request.headers[self.auth_header_name] = f"Bearer {id_token}"

        # Send the request
        response = yield request

        # Handle 401 by clearing cached token and retrying
        if response.status_code == 401:
            self.token_manager.clear_cached_token()

            # Get fresh token and retry
            fresh_token = self.token_manager.get_id_token()
            request.headers[self.auth_header_name] = f"Bearer {fresh_token}"

            # Retry the request
            yield request

    async def async_auth_flow(self, request: httpx.Request):
        """
        Asynchronous authentication flow for httpx.AsyncClient.

        Note: The token generation operations are wrapped in thread pool
        execution to avoid blocking the async event loop.
        """
        # Get ID token and add to headers
        id_token = await self.token_manager.get_id_token_async()
        request.headers[self.auth_header_name] = f"Bearer {id_token}"

        # Send the request
        response = yield request

        # Handle 401 by clearing cached token and retrying
        if response.status_code == 401:
            self.token_manager.clear_cached_token()

            # Get fresh token and retry
            fresh_token = await self.token_manager.get_id_token_async()
            request.headers[self.auth_header_name] = f"Bearer {fresh_token}"

            # Retry the request
            yield request
