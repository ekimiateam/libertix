from __future__ import annotations

import asyncio
from types import TracebackType

import httpx
import uvloop
from fastapi import FastAPI


class AsgiTestClient:
    """Run ASGI requests on one local event loop without a blocking portal."""

    __test__ = False

    def __init__(
        self,
        app: FastAPI,
        *,
        client: tuple[str, int] = ("127.0.0.1", 50000),
    ) -> None:
        self._app = app
        self._client_address = client
        self._runner: asyncio.Runner | None = None
        self._http_client: httpx.AsyncClient | None = None
        self._lifespan = None

    def __enter__(self) -> AsgiTestClient:
        self._runner = asyncio.Runner(loop_factory=uvloop.new_event_loop)
        self._lifespan = self._app.router.lifespan_context(self._app)
        self._runner.run(self._lifespan.__aenter__())
        self._http_client = httpx.AsyncClient(
            transport=httpx.ASGITransport(
                app=self._app,
                client=self._client_address,
            ),
            base_url="http://testserver",
        )
        self._runner.run(self._http_client.__aenter__())
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        assert self._runner is not None
        assert self._http_client is not None
        assert self._lifespan is not None
        try:
            self._runner.run(self._http_client.__aexit__(exc_type, exc_value, traceback))
            self._runner.run(self._lifespan.__aexit__(exc_type, exc_value, traceback))
        finally:
            self._runner.close()

    def request(self, method: str, url: str, **kwargs) -> httpx.Response:
        assert self._runner is not None
        assert self._http_client is not None
        return self._runner.run(self._http_client.request(method, url, **kwargs))

    def get(self, url: str, **kwargs) -> httpx.Response:
        return self.request("GET", url, **kwargs)

    def head(self, url: str, **kwargs) -> httpx.Response:
        return self.request("HEAD", url, **kwargs)

    def post(self, url: str, **kwargs) -> httpx.Response:
        return self.request("POST", url, **kwargs)
