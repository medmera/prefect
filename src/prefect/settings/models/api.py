import os
from typing import ClassVar, Optional

from pydantic import Field, SecretStr
from pydantic_settings import SettingsConfigDict

from prefect.settings.base import (
    PrefectBaseSettings,
    build_settings_config,
)


class IAPSettings(PrefectBaseSettings):
    """
    Settings for interacting with the Prefect API using IAP
    """

    model_config: ClassVar[SettingsConfigDict] = build_settings_config(("api", "iap"))

    enabled: bool = Field(
        default=False,
        description="Whether to enable IAP authentication. If enabled, the client will use IAP to authenticate with the Prefect API.",
    )
    client_id_gcp_secret_version: Optional[str] = Field(
        default=None,
        description="The name of the GCP secret to use for the client ID.",
    )
    impersonate_service_account: Optional[str] = Field(
        default=None,
        description="The email of the service account to impersonate for the API when using the service-account mode.",
    )
    auth_header_name: str = Field(
        default="Authorization",
        description="The name of the HTTP header to use for IAP authentication.",
    )


class APISettings(PrefectBaseSettings):
    """
    Settings for interacting with the Prefect API
    """

    model_config: ClassVar[SettingsConfigDict] = build_settings_config(("api",))
    url: Optional[str] = Field(
        default=None,
        description="The URL of the Prefect API. If not set, the client will attempt to infer it.",
    )
    auth_string: Optional[SecretStr] = Field(
        default=None,
        description="The auth string used for basic authentication with a self-hosted Prefect API. Should be kept secret.",
    )
    key: Optional[SecretStr] = Field(
        default=None,
        description="The API key used for authentication with the Prefect API. Should be kept secret.",
    )
    tls_insecure_skip_verify: bool = Field(
        default=False,
        description="If `True`, disables SSL checking to allow insecure requests. Setting to False is recommended only during development. For example, when using self-signed certificates.",
    )
    ssl_cert_file: Optional[str] = Field(
        default=os.environ.get("SSL_CERT_FILE"),
        description="This configuration settings option specifies the path to an SSL certificate file.",
    )
    enable_http2: bool = Field(
        default=False,
        description="If true, enable support for HTTP/2 for communicating with an API. If the API does not support HTTP/2, this will have no effect and connections will be made via HTTP/1.1.",
    )
    request_timeout: float = Field(
        default=60.0,
        description="The default timeout for requests to the API",
    )
    iap: IAPSettings = Field(
        default_factory=IAPSettings,
        description="Settings for interacting with the Prefect API using IAP.",
    )
