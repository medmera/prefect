"""
Internal WebSocket proxy utilities for Prefect client connections.

This module provides shared WebSocket proxy connection logic and SSL configuration
to avoid duplication between events and logs clients.
"""

import ssl
import warnings
from functools import wraps
from typing import Any, Optional
from urllib.parse import urlparse

import certifi
from websockets.asyncio.client import connect

try:
    from prefect.client.iap_auth import IAPTokenManager
except ImportError:
    IAPTokenManager = None
from prefect.settings import PREFECT_API_IAP_ENABLED, get_current_settings


def create_ssl_context_for_websocket(uri: str) -> Optional[ssl.SSLContext]:
    """Create SSL context for WebSocket connections based on URI scheme."""
    u = urlparse(uri)

    if u.scheme != "wss":
        return None

    if get_current_settings().api.tls_insecure_skip_verify:
        # Create an unverified context for insecure connections
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    else:
        # Create a verified context with the certificate file
        cert_file = get_current_settings().api.ssl_cert_file
        if not cert_file:
            cert_file = certifi.where()
        return ssl.create_default_context(cafile=cert_file)


@wraps(connect)
def websocket_connect(uri: str, **kwargs: Any) -> connect:
    """
    Create a WebSocket connection with proxy and SSL support.

    Proxy support is automatic via HTTP_PROXY/HTTPS_PROXY environment variables.
    The websockets library handles proxy detection and connection automatically.
    """
    # Configure SSL context for HTTPS connections
    ssl_context = create_ssl_context_for_websocket(uri)
    if ssl_context:
        kwargs.setdefault("ssl", ssl_context)

    # Add custom headers from settings
    custom_headers = get_current_settings().client.custom_headers
    if custom_headers:
        # Get existing additional_headers or create new dict
        additional_headers = kwargs.get("additional_headers", {})
        if not isinstance(additional_headers, dict):
            additional_headers = {}

        for header_name, header_value in custom_headers.items():
            # Check for protected headers that shouldn't be overridden
            if header_name.lower() in {
                "user-agent",
                "sec-websocket-key",
                "sec-websocket-version",
                "sec-websocket-extensions",
                "sec-websocket-protocol",
                "connection",
                "upgrade",
                "host",
            }:
                warnings.warn(
                    f"Custom header '{header_name}' is ignored because it conflicts with "
                    f"a protected WebSocket header. Protected headers include: "
                    f"User-Agent, Sec-WebSocket-Key, Sec-WebSocket-Version, "
                    f"Sec-WebSocket-Extensions, Sec-WebSocket-Protocol, Connection, "
                    f"Upgrade, Host",
                    UserWarning,
                    stacklevel=2,
                )
            else:
                additional_headers[header_name] = header_value

        kwargs["additional_headers"] = additional_headers

<<<<<<< HEAD
        if not host:
            raise ValueError(f"Invalid URI {uri}, no hostname found")

        if u.scheme == "ws":
            port = u.port or 80
            proxy_url = os.environ.get("HTTP_PROXY")
        elif u.scheme == "wss":
            port = u.port or 443
            proxy_url = os.environ.get("HTTPS_PROXY")
            kwargs["server_hostname"] = host
        else:
            raise ValueError(
                "Unsupported scheme %s. Expected 'ws' or 'wss'. " % u.scheme
            )

        # Store proxy URL for deferred creation. Creating the proxy object here
        # can bind asyncio futures to the wrong event loop when multiple WebSocket
        # connections are initialized at different times (e.g., events + logs clients).
        self._proxy_url = proxy_url if proxy_url and not proxy_bypass(host) else None
        self._host = host
        self._port = port

        # Configure SSL context for HTTPS connections
        ssl_context = create_ssl_context_for_websocket(uri)
        if ssl_context:
            self._kwargs.setdefault("ssl", ssl_context)

        # Add custom headers from settings
        custom_headers = get_current_settings().client.custom_headers
        if custom_headers:
            # Get existing additional_headers or create new dict
            additional_headers = self._kwargs.get("additional_headers", {})
            if not isinstance(additional_headers, dict):
                additional_headers = {}

            for header_name, header_value in custom_headers.items():
                # Check for protected headers that shouldn't be overridden
                if header_name.lower() in {
                    "user-agent",
                    "sec-websocket-key",
                    "sec-websocket-version",
                    "sec-websocket-extensions",
                    "sec-websocket-protocol",
                    "connection",
                    "upgrade",
                    "host",
                }:
                    warnings.warn(
                        f"Custom header '{header_name}' is ignored because it conflicts with "
                        f"a protected WebSocket header. Protected headers include: "
                        f"User-Agent, Sec-WebSocket-Key, Sec-WebSocket-Version, "
                        f"Sec-WebSocket-Extensions, Sec-WebSocket-Protocol, Connection, "
                        f"Upgrade, Host",
                        UserWarning,
                        stacklevel=2,
                    )
                else:
                    additional_headers[header_name] = header_value

            self._kwargs["additional_headers"] = additional_headers

    async def _proxy_connect(self: Self) -> ClientConnection:
        if self._proxy_url:
            # Create proxy in the current event loop context
            proxy = Proxy.from_url(self._proxy_url)
            sock = await proxy.connect(
                dest_host=self._host,
                dest_port=self._port,
            )
            self._kwargs["sock"] = sock

        super().__init__(self.uri, **self._kwargs)
        proto = await self.__await_impl__()
        return proto

    def __await__(self: Self) -> Generator[Any, None, ClientConnection]:
        return self._proxy_connect().__await__()


def websocket_connect(uri: str, **kwargs: Any) -> WebsocketProxyConnect:
    """Create a WebSocket connection with proxy and SSL support."""

    if PREFECT_API_IAP_ENABLED.value():
        if IAPTokenManager is None:
            raise ImportError(
                "IAP authentication is not available. Please install the prefect (or prefect-client) package with the 'gcp-iap' extra."
            )

        kwargs["additional_headers"] = {
            **(kwargs.get("additional_headers", {}) or {}),
            **IAPTokenManager().get_id_token_header(),
        }

    return WebsocketProxyConnect(uri, **kwargs)
=======
    return connect(uri, **kwargs)
>>>>>>> 3.6.25
