import httpx

from app.clients.proxmox import ProxmoxClient


def test_vm_lookup_only_queries_nodes_and_target_vmid() -> None:
    paths: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        if request.url.path.endswith("/nodes"):
            return httpx.Response(200, json={"data": [{"node": "TPM-28"}]})
        if request.url.path.endswith("/nodes/TPM-28/qemu/500/status/current"):
            return httpx.Response(200, json={"data": {"status": "running"}})
        return httpx.Response(404, json={"data": None})

    proxmox = ProxmoxClient(
        "https://proxmox.test:8006",
        "token",
        "secret",
        verify_tls=True,
        timeout=1,
        task_timeout=1,
    )
    proxmox.client.close()
    proxmox.client = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        assert proxmox.locate_vm(500) == "TPM-28"
    finally:
        proxmox.client.close()

    assert paths == [
        "/api2/json/nodes",
        "/api2/json/nodes/TPM-28/qemu/500/status/current",
    ]
    assert all("cluster/resources" not in path for path in paths)
