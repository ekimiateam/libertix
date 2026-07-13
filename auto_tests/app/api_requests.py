from __future__ import annotations

from app.models import AutomationRequest, SourceMode, ValidationRequest


def validation_selectors(
    body: ValidationRequest | None, query_vms: list[str] | None
) -> list[str] | None:
    selectors: list[str] = []
    if body:
        selectors.extend(body.selectors() or [])
    if query_vms:
        selectors.extend(query_vms)
    return selectors or None


def validation_request(
    body: ValidationRequest | None,
    query_vms: list[str] | None,
    query_source: SourceMode | None,
) -> tuple[list[str] | None, ValidationRequest]:
    request = body or ValidationRequest()
    selectors = validation_selectors(request, query_vms)
    if query_source is not None:
        request.source = query_source
    return selectors, request


def automation_request(
    body: AutomationRequest | None,
    query_vms: list[str] | None,
    query_apply: bool | None,
    query_source: SourceMode | None,
) -> tuple[list[str] | None, AutomationRequest]:
    request = body or AutomationRequest()
    selectors = validation_selectors(request, query_vms)
    if query_apply is not None:
        request.apply = query_apply
    if query_source is not None:
        request.source = query_source
    return selectors, request
