import builtins
import logging
import sys
import types
from typing import AsyncGenerator, Generator

import httpx
import pytest
import respx

import prefect
from prefect._internal.version_checking import (
    _clear_api_version_check_cache,
    check_server_version,
)
from prefect.settings import (
    PREFECT_API_AUTH_STRING,
    PREFECT_API_IAP_AUTH_HEADER_NAME,
    PREFECT_API_IAP_ENABLED,
    PREFECT_CLIENT_SERVER_VERSION_CHECK_ENABLED,
    temporary_settings,
)

API_URL = "http://fake-server:4200/api"
VERSION_URL = f"{API_URL}/admin/version"
VALID_VERSION = "3.7.2"


class MockIAPAuth(httpx.Auth):
    """Minimal IAP auth mock that adds a bearer token header without GCP calls."""

    def __init__(self, auth_header_name: str | None = None) -> None:
        self.auth_header_name = auth_header_name or "Authorization"

    def sync_auth_flow(
        self, request: httpx.Request
    ) -> Generator[httpx.Request, httpx.Response, None]:
        request.headers[self.auth_header_name] = "Bearer mock-token"
        yield request

    async def async_auth_flow(
        self, request: httpx.Request
    ) -> AsyncGenerator[httpx.Request, httpx.Response]:
        request.headers[self.auth_header_name] = "Bearer mock-token"
        yield request


@pytest.fixture(autouse=True)
def clear_api_version_check_cache():
    _clear_api_version_check_cache()
    yield
    _clear_api_version_check_cache()


@pytest.fixture(autouse=True)
def pep440_client_version(monkeypatch):
    """Use a PEP 440-compliant version so packaging.version.parse succeeds."""
    monkeypatch.setattr(prefect, "__version__", VALID_VERSION)


@pytest.fixture
def mock_iap_auth(monkeypatch):
    fake_iap_auth = types.ModuleType("prefect.client.iap_auth")
    fake_iap_auth.IAPAuth = MockIAPAuth
    monkeypatch.setitem(sys.modules, "prefect.client.iap_auth", fake_iap_auth)


class TestCheckServerVersionIAP:
    async def test_iap_header_included_when_enabled(self, mock_iap_auth):
        with temporary_settings(
            {
                PREFECT_CLIENT_SERVER_VERSION_CHECK_ENABLED: True,
                PREFECT_API_IAP_ENABLED: True,
                PREFECT_API_IAP_AUTH_HEADER_NAME: "X-Serverless-Authorization",
            }
        ):
            with respx.mock:
                route = respx.get(VERSION_URL).mock(
                    return_value=httpx.Response(200, json=VALID_VERSION)
                )

                await check_server_version(API_URL, logging.getLogger("test"))

                assert route.called
                request = route.calls[0].request
                assert (
                    request.headers["X-Serverless-Authorization"] == "Bearer mock-token"
                )

    async def test_iap_and_basic_auth_both_included(self, mock_iap_auth):
        with temporary_settings(
            {
                PREFECT_CLIENT_SERVER_VERSION_CHECK_ENABLED: True,
                PREFECT_API_IAP_ENABLED: True,
                PREFECT_API_IAP_AUTH_HEADER_NAME: "X-Serverless-Authorization",
                PREFECT_API_AUTH_STRING: "admin:password",
            }
        ):
            with respx.mock:
                route = respx.get(VERSION_URL).mock(
                    return_value=httpx.Response(200, json=VALID_VERSION)
                )

                await check_server_version(API_URL, logging.getLogger("test"))

                assert route.called
                request = route.calls[0].request
                assert (
                    request.headers["X-Serverless-Authorization"] == "Bearer mock-token"
                )
                assert request.headers["Authorization"].startswith("Basic ")

    async def test_no_iap_header_when_disabled(self):
        with temporary_settings(
            {
                PREFECT_CLIENT_SERVER_VERSION_CHECK_ENABLED: True,
                PREFECT_API_IAP_ENABLED: False,
            }
        ):
            with respx.mock:
                route = respx.get(VERSION_URL).mock(
                    return_value=httpx.Response(200, json=VALID_VERSION)
                )

                await check_server_version(API_URL, logging.getLogger("test"))

                assert route.called
                request = route.calls[0].request
                assert "X-Serverless-Authorization" not in request.headers

    async def test_import_error_when_iap_enabled_but_unavailable(self, monkeypatch):
        monkeypatch.delitem(sys.modules, "prefect.client.iap_auth", raising=False)
        original_import = builtins.__import__

        def mock_import(name, *args, **kwargs):
            if name == "prefect.client.iap_auth":
                raise ImportError("No module named 'prefect.client.iap_auth'")
            return original_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", mock_import)

        with temporary_settings(
            {
                PREFECT_CLIENT_SERVER_VERSION_CHECK_ENABLED: True,
                PREFECT_API_IAP_ENABLED: True,
            }
        ):
            with pytest.raises(ImportError, match="gcp-iap"):
                await check_server_version(API_URL, logging.getLogger("test"))


class TestCheckServerVersionRaiseOnError:
    async def test_raise_on_error_false_with_401_returns_silently(self, caplog):
        with temporary_settings({PREFECT_CLIENT_SERVER_VERSION_CHECK_ENABLED: True}):
            with respx.mock:
                respx.get(VERSION_URL).mock(return_value=httpx.Response(401))

                with caplog.at_level(logging.DEBUG):
                    await check_server_version(
                        API_URL,
                        logging.getLogger("test"),
                        raise_on_error=False,
                    )

                assert any(
                    "Unable to check server version" in record.message
                    for record in caplog.records
                )

    async def test_raise_on_error_true_with_401_raises(self):
        with temporary_settings({PREFECT_CLIENT_SERVER_VERSION_CHECK_ENABLED: True}):
            with respx.mock:
                respx.get(VERSION_URL).mock(return_value=httpx.Response(401))

                with pytest.raises(httpx.HTTPStatusError):
                    await check_server_version(
                        API_URL,
                        logging.getLogger("test"),
                        raise_on_error=True,
                    )

    async def test_raise_on_error_false_with_403_returns_silently(self):
        with temporary_settings({PREFECT_CLIENT_SERVER_VERSION_CHECK_ENABLED: True}):
            with respx.mock:
                respx.get(VERSION_URL).mock(return_value=httpx.Response(403))

                await check_server_version(
                    API_URL,
                    logging.getLogger("test"),
                    raise_on_error=False,
                )


class TestCheckServerVersionCache:
    async def test_second_call_uses_cache(self):
        with temporary_settings({PREFECT_CLIENT_SERVER_VERSION_CHECK_ENABLED: True}):
            with respx.mock:
                route = respx.get(VERSION_URL).mock(
                    return_value=httpx.Response(200, json=VALID_VERSION)
                )

                logger = logging.getLogger("test")
                await check_server_version(API_URL, logger)
                await check_server_version(API_URL, logger)

                assert route.call_count == 1
