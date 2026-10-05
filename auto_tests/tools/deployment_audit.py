"""Static audit of the folders where Libertix deploys its Windows scripts.

Libertix copies the same PowerShell files into folders of different shapes: the
application folder, the UEFI recovery payload (a copy of the source tree), the
flat BIOS recovery folder and the Windows sharing folder. A script that builds a
path from its own folder can therefore work in one shape and break, or look into
a missing location, in another. Some of these folders are run by SYSTEM
scheduled tasks, so they must not accept files written by standard users.

This program reads repository files only. It starts no VM, auto-test, build or
network access. It rebuilds every layout from the project and installer sources,
follows each script started in a layout through the modules it loads there,
resolves every deployment reference on that path, and reports anything it cannot
interpret instead of skipping it.

Run from the auto_tests directory: python -m tools.deployment_audit
Exit status: 0 without errors, 1 with errors, 2 when a source no longer has a
shape this audit understands.
"""

from __future__ import annotations

import posixpath
import re
import sys
import xml.etree.ElementTree as ElementTree
from dataclasses import dataclass, field
from pathlib import Path, PureWindowsPath

REPO = Path(__file__).resolve().parents[2]
MSBUILD = "{http://schemas.microsoft.com/developer/msbuild/2003}"

# A name joined to a layout root is a shipped file when it carries one of these
# suffixes or the product prefix; plans, markers, states and logs are runtime data.
DEPLOYED_SUFFIXES = (".ps1", ".psm1", ".cs", ".exe", ".dll", ".ico")
PRODUCT_PREFIX = "Libertix."

# Dynamic references that cannot name a file statically. Each entry must explain
# where the value comes from; any other dynamic reference is reported as an error.
DOCUMENTED_DYNAMIC_REFERENCES = {
    ("Scripts/libertix-uefi-recovery-agent.ps1", "([string]$item.RelativePath)"): (
        "verifies the payload manifest written by the installer, entry by entry"
    ),
}

# Where each script is started, with the source text that starts it there. The
# audit fails when that text disappears or when a top-level script is missing.
ENTRY_POINTS = {
    "application": [
        (
            "scripts/libertix-compatibility-preflight.ps1",
            "Helpers/CompatibilityPreflightRunner.cs",
            '"libertix-compatibility-preflight.ps1"',
        ),
        (
            "scripts/libertix-storage-preflight.ps1",
            "Installation/InstallationEngine.System.cs",
            '"libertix-storage-preflight.ps1"',
        ),
        (
            "scripts/libertix-bios-storage.ps1",
            "Installation/InstallationEngine.Windows.cs",
            '"libertix-bios-storage.ps1"',
        ),
        (
            "scripts/libertix-disk-image.ps1",
            "Installation/InstallationEngine.Bios.cs",
            '"libertix-disk-image.ps1"',
        ),
        (
            "scripts/libertix-register-bios-recovery-task.ps1",
            "Installation/InstallationEngine.Windows.cs",
            '"libertix-register-bios-recovery-task.ps1"',
        ),
        (
            "scripts/libertix-save-storage-baseline.ps1",
            "Installation/InstallationEngine.Plan.cs",
            '"libertix-save-storage-baseline.ps1"',
        ),
        (
            "scripts/libertix-uefi-install.ps1",
            "Installation/InstallationEngine.Uefi.cs",
            '"libertix-uefi-install.ps1"',
        ),
        (
            "scripts/libertix-windows-sharing-inventory.ps1",
            "Installation/InstallationEngine.Windows.cs",
            '"libertix-windows-sharing-inventory.ps1"',
        ),
    ],
    "uefi-recovery": [
        (
            "payload/scripts/libertix-uefi-recovery-agent.ps1",
            "Installation/InstallationEngine.Uefi.cs",
            'Path.Combine(recovery.PayloadRoot, "Scripts", "libertix-uefi-recovery-agent.ps1")',
        ),
        (
            "payload/scripts/libertix-register-uefi-recovery-tasks.ps1",
            "Installation/InstallationEngine.Uefi.cs",
            '"libertix-register-uefi-recovery-tasks.ps1"',
        ),
        (
            "payload/scripts/libertix-uefi-install.ps1",
            "Scripts/libertix-uefi-recovery-agent.ps1",
            'Join-Path $State.PayloadRoot "Scripts\\libertix-uefi-install.ps1"',
        ),
        (
            "payload/scripts/libertix-post-install-result.ps1",
            "Scripts/libertix-uefi-recovery-agent.ps1",
            'Join-Path $State.PayloadRoot "Scripts\\libertix-post-install-result.ps1"',
        ),
    ],
    "bios-recovery": [
        (
            "recover.ps1",
            "Installation/InstallationEngine.Windows.cs",
            'Path.Combine(RecoveryRoot, "recover.ps1")',
        ),
        (
            "libertix-post-install-result.ps1",
            "Installation/InstallationEngine.Windows.cs",
            'Path.Combine(RecoveryRoot, "libertix-post-install-result.ps1")',
        ),
    ],
    "windows-share": [
        (
            "mount-linux-readonly.ps1",
            "Scripts/libertix-uefi-recovery-agent.ps1",
            'Join-Path $WindowsShareRoot "mount-linux-readonly.ps1"',
        ),
    ],
}

# Only this script uses $Root for its own deployment folder; elsewhere the name
# is an ordinary parameter and says nothing about the layout.
SCRIPTS_WITH_LAYOUT_ROOT_VARIABLE = {"Scripts/libertix-recovery-guard.ps1"}

# References that are deliberately absent from a layout because the code that
# uses them cannot run there. The guard text must appear in the same function
# before the reference; the audit checks it instead of trusting this table.
DOCUMENTED_LAYOUT_EXCEPTIONS = {
    (
        "Scripts/modules/Libertix.PostInstallVerification.psm1",
        "libertix.firmware.psm1",
        "bios-recovery",
    ): (
        'if ([string]$Plan.firmware -ne "uefi")',
        "the boot guardian check returns before this import on BIOS plans",
    ),
    (
        "Scripts/modules/Libertix.PostInstallVerification.psm1",
        "libertix.firmwarevariables.psm1",
        "bios-recovery",
    ): (
        'if ([string]$Plan.firmware -ne "uefi")',
        "the boot guardian check returns before this import on BIOS plans",
    ),
}


class AuditStructureError(Exception):
    """A source no longer has a shape that this audit can interpret."""


@dataclass(frozen=True)
class Finding:
    rule: str
    where: str
    message: str


@dataclass
class Layout:
    name: str
    description: str
    # Case-folded POSIX path inside the layout -> repository source path.
    files: dict[str, str]
    # Variables that name the layout root inside scripts deployed in it.
    root_variables: dict[str, str] = field(default_factory=dict)
    # None means no scheduled task runs files from this layout.
    protected: bool | None = None
    protection_evidence: str = ""


@dataclass(frozen=True)
class Reference:
    script: str
    line: int
    base: str
    child: str


def read(relative: str) -> str:
    path = REPO / relative
    if not path.is_file():
        raise AuditStructureError(f"{relative} is missing")
    return path.read_text(encoding="utf-8-sig")


def layout_key(path: str) -> str:
    return posixpath.normpath(path.replace("\\", "/")).lower()


def is_deployment_reference(relative: str) -> bool:
    name = PureWindowsPath(relative).name
    return name.lower().endswith(DEPLOYED_SUFFIXES) or name.startswith(PRODUCT_PREFIX)


# --- C# source helpers -------------------------------------------------------


STRING_PREFIXES = ('$@"', '@$"', '@"', '$"', '"')


def _char_literal_end(source: str, index: int) -> int:
    end = index + 1
    while end < len(source) and source[end] != "'":
        end += 2 if source[end] == "\\" else 1
    return end + 1


def _string_end(source: str, index: int) -> int:
    """Return the index after a C# string literal, including interpolation holes."""

    prefix = next(prefix for prefix in STRING_PREFIXES if source.startswith(prefix, index))
    verbatim = "@" in prefix
    interpolated = "$" in prefix
    position = index + len(prefix)
    while position < len(source):
        # Two-character sequences that never end the literal: a doubled quote in a
        # verbatim string, an escape in a regular one, or a literal brace.
        if (
            (verbatim and source.startswith('""', position))
            or (not verbatim and source[position] == "\\")
            or (interpolated and source.startswith("{{", position))
        ):
            position += 2
        elif interpolated and source[position] == "{":
            position = _interpolation_end(source, position + 1)
        elif source[position] == '"':
            return position + 1
        else:
            position += 1
    return len(source)


def _interpolation_end(source: str, position: int) -> int:
    # An interpolation hole is code: it may contain nested strings and braces.
    depth = 1
    while position < len(source):
        if source.startswith(STRING_PREFIXES, position):
            position = _string_end(source, position)
            continue
        char = source[position]
        if char == "'":
            position = _char_literal_end(source, position)
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return position + 1
        position += 1
    return len(source)


def csharp_code_mask(source: str) -> str:
    """Blank strings, chars and comments so their brackets and commas are not code."""

    masked = list(source)
    index = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
        elif source.startswith("/*", index):
            end = source.find("*/", index + 2)
            end = len(source) if end < 0 else end + 2
        elif source.startswith(STRING_PREFIXES, index):
            end = _string_end(source, index)
        elif source[index] == "'":
            end = _char_literal_end(source, index)
        else:
            index += 1
            continue
        masked[index:end] = [char if char == "\n" else " " for char in source[index:end]]
        index = end
    return "".join(masked)


def csharp_methods(source: str) -> dict[str, tuple[list[str], str]]:
    """Map method names to their parameter names and body text."""

    masked = csharp_code_mask(source)
    signature = re.compile(
        r"(?:private|internal|public|protected)[\w\s<>\[\],.?]*?\s(\w+)\s*\(([^()]*)\)\s*\{"
    )
    methods: dict[str, tuple[list[str], str]] = {}
    for match in signature.finditer(masked):
        depth = 0
        for index in range(match.end() - 1, len(masked)):
            if masked[index] == "{":
                depth += 1
            elif masked[index] == "}":
                depth -= 1
                if depth == 0:
                    break
        parameters = [
            part.strip().split()[-1] for part in match.group(2).split(",") if part.strip()
        ]
        methods[match.group(1)] = (parameters, source[match.end() : index])
    return methods


def method_body(source: str, name: str, relative: str) -> str:
    methods = csharp_methods(source)
    if name not in methods:
        raise AuditStructureError(f"{relative} no longer defines {name}")
    return methods[name][1]


def split_arguments(text: str) -> list[str]:
    """Split on top-level commas; commas and brackets inside strings do not count."""

    masked = csharp_code_mask(text)
    arguments, depth, start = [], 0, 0
    for index, char in enumerate(masked):
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            arguments.append(text[start:index].strip())
            start = index + 1
    if text[start:].strip():
        arguments.append(text[start:].strip())
    return arguments


def call_arguments(body: str, function: str) -> list[list[str]]:
    """Return the argument lists of every call to `function` in `body`."""

    masked = csharp_code_mask(body)
    calls = []
    for match in re.finditer(rf"(?<![\w.]){re.escape(function)}\s*\(", masked):
        depth = 1
        index = match.end()
        while depth and index < len(masked):
            depth += {"(": 1, ")": -1}.get(masked[index], 0)
            index += 1
        calls.append(split_arguments(body[match.end() : index - 1]))
    return calls


def string_array(source: str, field_name: str, relative: str) -> list[str]:
    match = re.search(
        rf"\b{re.escape(field_name)}\s*=\s*(?:new\s*\w*\[\]\s*)?\{{([^}}]*)\}}", source
    )
    if not match:
        raise AuditStructureError(f"{relative} no longer defines the array {field_name}")
    return re.findall(r'"([^"]+)"', match.group(1))


def literal_path(expression: str, loop_values: dict[str, list[str]]) -> list[str] | None:
    """Evaluate a string literal or Path.Combine of literals and loop variables."""

    expression = expression.strip()
    if re.fullmatch(r'"[^"]*"', expression):
        return [expression[1:-1]]
    if expression in loop_values:
        return loop_values[expression]
    match = re.fullmatch(r"Path\.Combine\((.*)\)", expression, re.DOTALL)
    if not match:
        return None
    results = [""]
    for part in split_arguments(match.group(1)):
        if re.fullmatch(r'"[^"]*"', part):
            values = [part[1:-1]]
        elif part in loop_values:
            values = loop_values[part]
        else:
            return None
        results = [str(PureWindowsPath(base, value)) for base in results for value in values]
    return results


# --- Layouts -------------------------------------------------------------------


def release_output(project_path: Path) -> Path:
    project = ElementTree.parse(project_path).getroot()
    for group in project.iter(f"{MSBUILD}PropertyGroup"):
        output = group.find(f"{MSBUILD}OutputPath")
        if output is not None and "Release|AnyCPU" in (group.get("Condition") or ""):
            relative = output.text.replace("\\", "/")
            return (project_path.parent / relative).resolve()
    raise AuditStructureError(f"{project_path.name} has no Release|AnyCPU output folder")


def assembly_file(project_path: Path) -> str:
    project = ElementTree.parse(project_path).getroot()
    name = project.find(f"{MSBUILD}PropertyGroup/{MSBUILD}AssemblyName")
    kind = project.find(f"{MSBUILD}PropertyGroup/{MSBUILD}OutputType")
    if name is None or kind is None:
        raise AuditStructureError(f"{project_path.name} has no AssemblyName or OutputType")
    suffix = ".dll" if kind.text == "Library" else ".exe"
    return name.text + suffix


def application_layout(findings: list[Finding]) -> Layout:
    project_path = REPO / "Libertix.csproj"
    project = ElementTree.parse(project_path).getroot()
    files: dict[str, str] = {}

    def add(target: str, source: str) -> None:
        if "*" in target or "*" in source:
            raise AuditStructureError(f"Libertix.csproj uses a wildcard item: {source}")
        if not (REPO / source.replace("\\", "/")).is_file():
            findings.append(
                Finding(
                    "build-source",
                    "Libertix.csproj",
                    f"the build copies {source}, which does not exist",
                )
            )
        files[layout_key(target)] = source.replace("\\", "/")

    for item in project.iter():
        if item.tag not in (f"{MSBUILD}Content", f"{MSBUILD}None"):
            continue
        copy = item.find(f"{MSBUILD}CopyToOutputDirectory")
        if copy is None or copy.text.strip() == "Never":
            continue
        link = item.find(f"{MSBUILD}Link")
        add(link.text if link is not None else item.get("Include"), item.get("Include"))
    for copy in project.iter(f"{MSBUILD}Copy"):
        folder = copy.get("DestinationFolder", "")
        if not folder.startswith("$(TargetDir)"):
            raise AuditStructureError(f"Libertix.csproj copies outside the output: {folder}")
        for source in copy.get("SourceFiles", "").split(";"):
            target = str(
                PureWindowsPath(folder.removeprefix("$(TargetDir)"), PureWindowsPath(source).name)
            )
            add(target, source)

    files[layout_key(assembly_file(project_path))] = "Libertix.csproj"
    main_output = release_output(project_path)
    for reference in project.iter(f"{MSBUILD}ProjectReference"):
        referenced = (REPO / reference.get("Include").replace("\\", "/")).resolve()
        if release_output(referenced) != main_output:
            raise AuditStructureError(
                f"{referenced.name} no longer builds into the Libertix output"
            )
        files[layout_key(assembly_file(referenced))] = str(referenced.relative_to(REPO))
    return Layout("application", "Libertix output folder, used while Libertix.exe runs", files)


def uefi_payload_layout(application: Layout) -> Layout:
    relative = "Installation/InstallationEngine.Uefi.cs"
    source = read(relative)
    body = method_body(source, "EnumerateUefiRecoveryPayloadFiles", relative)
    directories = re.search(r"foreach \(string \w+ in new\[\] \{([^}]*)\}", body)
    names = re.findall(r'GetFileName\(path\)\.Equals\("([^"]+)"', body)
    extensions = re.findall(r'GetExtension\(path\)\.Equals\("([^"]+)"', body)
    if not directories or not names or not extensions:
        raise AuditStructureError(f"{relative} changed how the UEFI payload is enumerated")
    copied_directories = {name.lower() for name in re.findall(r'"([^"]+)"', directories.group(1))}
    session = method_body(source, "CreateUefiRecoverySession", relative)
    if 'Path.Combine(root, "payload")' not in session:
        raise AuditStructureError(f"{relative} no longer places the payload under the run root")

    files = {}
    for key, origin in application.files.items():
        first, _, rest = key.partition("/")
        top_level = not rest and (
            key in {name.lower() for name in names}
            or posixpath.splitext(key)[1] in {ext.lower() for ext in extensions}
        )
        if top_level or (rest and first in copied_directories):
            files["payload/" + key] = origin
    return Layout(
        "uefi-recovery",
        "per-run UEFI recovery folder; the payload mirrors the application tree",
        files,
        root_variables={"$state.payloadroot": "payload"},
    )


def bios_recovery_layout(application: Layout, findings: list[Finding]) -> Layout:
    relative = "Installation/InstallationEngine.Windows.cs"
    source = read(relative)
    files = {}
    calls = call_arguments(source, "CopyRequiredRecoveryFile")
    # The method declaration matches the call pattern too; its arguments are typed.
    calls = [arguments for arguments in calls if not arguments[0].startswith("string ")]
    if not calls:
        raise AuditStructureError(f"{relative} no longer copies BIOS recovery files")
    loops = {
        variable: string_array(source, collection, relative)
        for variable, collection in re.findall(
            r"foreach \(string (\w+) in (\w+)\)\s*CopyRequiredRecoveryFile", source
        )
    }
    if "BiosRecoveryModules" not in source or not loops:
        raise AuditStructureError(f"{relative} no longer copies the BIOS module list in a loop")
    for arguments in calls:
        if len(arguments) != 2:
            raise AuditStructureError(f"{relative}: unexpected CopyRequiredRecoveryFile call")
        sources = literal_path(arguments[0], loops)
        targets = literal_path(arguments[1], loops)
        if sources is None or targets is None or len(sources) != len(targets):
            raise AuditStructureError(
                f"{relative}: cannot evaluate CopyRequiredRecoveryFile({', '.join(arguments)})"
            )
        for origin, target in zip(sources, targets, strict=True):
            if layout_key(origin) not in application.files:
                findings.append(
                    Finding(
                        "copy-source",
                        relative,
                        f"BIOS recovery copies {origin}, absent from the build output",
                    )
                )
                continue
            files[layout_key(target)] = application.files[layout_key(origin)]
    return Layout(
        "bios-recovery",
        "flat BIOS recovery folder at the root of the Windows drive",
        files,
        root_variables={"$root": ""},
    )


def windows_share_layout(application: Layout, findings: list[Finding]) -> Layout:
    relative = "Installation/InstallationEngine.Windows.cs"
    body = method_body(read(relative), "PrepareWindowsSharePayloadAsync", relative)
    sources = {
        name: [str(PureWindowsPath(*re.findall(r'"([^"]+)"', arguments)))]
        for name, arguments in re.findall(
            r"string (\w+) = ApplicationFiles\.Resolve\(([^;]*)\);", body, re.DOTALL
        )
    }
    targets = {
        name: [value]
        for name, value in re.findall(
            r'string (\w+) = Path\.Combine\(\s*WindowsShareRoot\s*,\s*"([^"]+)"\s*\);', body
        )
    }
    files = {}
    for arguments in call_arguments(body, "File.Copy"):
        origin, target = arguments[0], arguments[1]
        if origin.startswith("LocalArtifactPath("):
            continue  # a verified catalog download, not a file of the source tree
        origin_values = sources.get(origin)
        target_values = targets.get(target)
        inline = re.fullmatch(r'Path\.Combine\(\s*WindowsShareRoot\s*,\s*"([^"]+)"\s*\)', target)
        if inline:
            target_values = [inline.group(1)]
        if origin_values is None or target_values is None:
            raise AuditStructureError(f"{relative}: cannot evaluate File.Copy({origin}, {target})")
        key = layout_key(origin_values[0])
        if key not in application.files:
            findings.append(
                Finding(
                    "copy-source",
                    relative,
                    f"the sharing folder copies {origin_values[0]}, absent from the build output",
                )
            )
            continue
        files[layout_key(target_values[0])] = application.files[key]
    if not files:
        raise AuditStructureError(f"{relative} no longer copies files to the sharing folder")
    return Layout("windows-share", "Windows sharing folder under ProgramData", files)


# --- Folder protection and privileged execution ----------------------------------


def protected_root_expressions() -> set[str]:
    """Follow ProtectDirectoryForInstallerAndSystem through one level of parameters."""

    expressions: set[str] = set()
    sources = {
        path: read(path)
        for path in (
            "Installation/InstallationEngine.Uefi.cs",
            "Installation/InstallationEngine.Plan.cs",
            "Installation/InstallationEngine.Windows.cs",
            "Installation/InstallationEngine.cs",
        )
    }
    methods = {}
    for source in sources.values():
        methods.update(csharp_methods(source))
    protection = methods.get("ProtectDirectoryForInstallerAndSystem")
    if protection is None:
        raise AuditStructureError("the directory protection helper is missing")
    _, protection_body = protection
    delegated = call_arguments(protection_body, "Security.ProtectedFiles.CreateDirectory")
    protection_methods = csharp_methods(read("Helpers/ProtectedFiles.cs"))
    _, create_body = protection_methods["CreateDirectory"]
    _, acl_body = protection_methods["DirectorySecurity"]
    applied_acl = call_arguments(create_body, "Directory.SetAccessControl")
    inheritance = call_arguments(acl_body, "security.SetAccessRuleProtection")
    if (
        delegated != [["directory", "readableByUsers"]]
        or applied_acl != [["path", "DirectorySecurity(readableByUsers)"]]
        or inheritance != [["true", "false"]]
        or call_arguments(create_body, "RequireTree") != [["path", "administrator"]]
        or not call_arguments(acl_body, "security.SetOwner")
    ):
        raise AuditStructureError(
            "the directory protection helper must apply its ACL and remove inherited rules"
        )
    for name, (parameters, body) in methods.items():
        for arguments in call_arguments(body, "ProtectDirectoryForInstallerAndSystem"):
            argument = arguments[0]
            if argument in parameters:
                position = parameters.index(argument)
                for _, (_, caller) in methods.items():
                    for call in call_arguments(caller, name):
                        if len(call) > position:
                            expressions.add(call[position])
            else:
                expressions.add(f"{name}:{argument}")
    return expressions


# Text that registers a SYSTEM task running the hidden host from each folder. A
# pattern that disappears stops the audit instead of silently skipping the folder.
PRIVILEGED_TASK_EVIDENCE = {
    "uefi-recovery": (
        "CreateUefiRecoverySession:root",
        [
            ("Scripts/libertix-register-uefi-recovery-tasks.ps1", r'-UserId "SYSTEM"'),
            (
                "Installation/InstallationEngine.Uefi.cs",
                r"bootGuardianExecutable = Path\.Combine\(\s*recovery\.PayloadRoot,"
                r'\s*"Libertix\.BootGuardian\.exe"\)',
            ),
            (
                "Installation/InstallationEngine.Uefi.cs",
                r"-HiddenHostPath \{QuoteArgument\(bootGuardianExecutable\)\}",
            ),
        ],
    ),
    "bios-recovery": (
        "RecoveryRoot",
        [
            ("Scripts/libertix-register-bios-recovery-task.ps1", r'-UserId "SYSTEM"'),
            (
                "Installation/InstallationEngine.Windows.cs",
                r"-HiddenHostPath \{QuoteArgument\(Path\.Combine\(RecoveryRoot, "
                r'"Libertix\.BootGuardian\.exe"\)\)\}',
            ),
        ],
    ),
    "windows-share": (
        "PrepareWindowsSharePayloadAsync:WindowsShareRoot",
        [
            (
                "Scripts/libertix-configure-windows-share.ps1",
                r'\$hiddenHost = Join-Path \$root "Libertix\.BootGuardian\.exe"',
            ),
            ("Scripts/libertix-configure-windows-share.ps1", r'-UserId "SYSTEM"'),
        ],
    ),
}


def apply_protection(layouts: dict[str, Layout], findings: list[Finding]) -> None:
    protected = protected_root_expressions()
    for name, (root_expression, evidence) in PRIVILEGED_TASK_EVIDENCE.items():
        for relative, pattern in evidence:
            if not re.search(pattern, read(relative)):
                raise AuditStructureError(
                    f"{relative} no longer shows the SYSTEM task evidence for {name}: {pattern}"
                )
        layout = layouts[name]
        layout.protected = root_expression in protected
        layout.protection_evidence = (
            f"{root_expression} reaches ProtectDirectoryForInstallerAndSystem"
            if layout.protected
            else f"no ProtectDirectoryForInstallerAndSystem call reaches {root_expression}"
        )
        if not layout.protected:
            findings.append(
                Finding(
                    "privileged-folder",
                    name,
                    f"a SYSTEM task runs Libertix.BootGuardian.exe from this folder, but "
                    f"{layout.protection_evidence}; standard users keep the rights inherited "
                    "from the parent folder",
                )
            )


# --- PowerShell references -------------------------------------------------------


def join_continuations(text: str) -> tuple[str, list[int]]:
    """Join backtick line continuations and keep the original line of each character."""

    joined, lines, line = [], [], 1
    index = 0
    while index < len(text):
        continuation = re.match(r"`[ \t]*\r?\n[ \t]*", text[index:])
        if continuation:
            line += 1
            joined.append(" ")
            lines.append(line)
            index += continuation.end()
            continue
        joined.append(text[index])
        lines.append(line)
        if text[index] == "\n":
            line += 1
        index += 1
    return "".join(joined), lines


REFERENCE_PATTERN = re.compile(
    r"Join-Path\s+(?:-Path\s+)?"
    r"(?P<base>\$PSScriptRoot|\(\s*Split-Path\s+-Parent\s+\$PSScriptRoot\s*\)"
    r"|\$[Ss]tate\.PayloadRoot|\$Root)"
    r"\s+(?:-ChildPath\s+)?"
    r"(?P<child>\"[^\"]*\"|'[^']*'|\(\[string\]\$\w+\.\w+\)|\$\w+)"
)


def loop_values(text: str, variable: str) -> list[str] | None:
    direct = re.search(rf"foreach\s*\(\${variable}\s+in\s+@\((.*?)\)\s*\)", text, re.DOTALL)
    if direct:
        return re.findall(r"[\"']([^\"']+)[\"']", direct.group(1))
    indirect = re.search(rf"foreach\s*\(\${variable}\s+in\s+\$(\w+)\s*\)", text)
    if indirect:
        listing = re.search(rf"\${indirect.group(1)}\s*=\s*@\((.*?)\n\)", text, re.DOTALL)
        if listing:
            lines = [line.split("#", 1)[0] for line in listing.group(1).splitlines()]
            return re.findall(r"[\"']([^\"']+)[\"']", "\n".join(lines))
    return None


def firmware_branch_source(source: str, relative: str, layout_name: str) -> str:
    """Exclude the other firmware branch without changing reference line numbers."""

    # This entry point receives the layout's firmware. In other scripts a variable
    # with the same name may describe inspected data, not the deployment folder.
    if relative != "Scripts/libertix-post-install-result.ps1":
        return source
    firmware = {"bios-recovery": "bios", "uefi-recovery": "uefi"}.get(layout_name)
    if firmware is None:
        return source
    pattern = re.compile(
        r'if\s*\(\$Firmware\s+-(?P<operator>eq|ne)\s+"(?P<firmware>bios|uefi)"\)'
        r"\s*\{(?P<yes>[^{}]*)\}\s*else\s*\{(?P<no>[^{}]*)\}",
        re.IGNORECASE,
    )
    masked = list(source)
    consumed = set()
    for match in pattern.finditer(source):
        consumed.add(match.start())
        matches = firmware == match.group("firmware").lower()
        selected = matches if match.group("operator").lower() == "eq" else not matches
        start, end = match.span("no" if selected else "yes")
        masked[start:end] = ["\n" if char == "\n" else " " for char in source[start:end]]
    for match in re.finditer(r"if\s*\(\$Firmware\b", source, re.IGNORECASE):
        if match.start() not in consumed:
            raise AuditStructureError("cannot resolve a firmware branch in a recovery script")
    return "".join(masked)


def script_references(
    relative: str, findings: list[Finding], layout_name: str = "application"
) -> list[Reference]:
    original = read(relative)
    text, lines = join_continuations(firmware_branch_source(original, relative, layout_name))
    references = []
    consumed: set[int] = set()
    for match in REFERENCE_PATTERN.finditer(text):
        consumed.update(range(match.start(), match.end()))
        base = match.group("base")
        if base == "$Root" and relative not in SCRIPTS_WITH_LAYOUT_ROOT_VARIABLE:
            continue
        child = match.group("child")
        line = lines[match.start()]
        if child[0] in "\"'" and "$" not in child:
            values = [child[1:-1]]
        else:
            documented = (relative, child) in DOCUMENTED_DYNAMIC_REFERENCES
            variable = re.search(r"\$(\w+)", child.strip("\"'"))
            values = None
            if variable and not documented:
                expansion = loop_values(text, variable.group(1))
                if expansion is not None:
                    values = [re.sub(r"\$\w+", item, child.strip("\"'")) for item in expansion]
            if values is None:
                if not documented:
                    findings.append(
                        Finding(
                            "dynamic-reference",
                            f"{relative}:{line}",
                            f"cannot name the file of Join-Path {base} {child}",
                        )
                    )
                continue
        references.extend(
            Reference(relative, line, base, value)
            for value in values
            if is_deployment_reference(value)
        )
    for match in re.finditer(r"\$PSScriptRoot", text):
        if match.start() not in consumed:
            findings.append(
                Finding(
                    "unrecognized-reference",
                    f"{relative}:{lines[match.start()]}",
                    "$PSScriptRoot is used in a form this audit cannot resolve",
                )
            )
    return references


def resolve(layout: Layout, script_key: str, reference: Reference) -> str | None:
    """Return the layout key a reference designates, or None for another root."""

    base = reference.base.lower()
    folder = posixpath.dirname(script_key)
    if base == "$psscriptroot":
        start = folder
    elif base.startswith("(") and "split-path" in base:
        start = posixpath.dirname(folder)
    elif base in layout.root_variables:
        start = layout.root_variables[base]
    else:
        return None
    return layout_key(posixpath.join(start, reference.child.replace("\\", "/")) or ".")


def enclosing_function(relative: str, line: int) -> str:
    """Return the text from the nearest preceding function header to `line`."""

    source_lines = read(relative).splitlines()
    start = 0
    for index in range(line - 1, -1, -1):
        if re.match(r"\s*function\s+[\w-]+", source_lines[index]):
            start = index
            break
    return "\n".join(source_lines[start:line])


def entry_points(layouts: dict[str, Layout], findings: list[Finding]) -> dict[str, list[str]]:
    entries: dict[str, list[str]] = {}
    started_sources = set()
    for layout_name, declared in ENTRY_POINTS.items():
        layout = layouts[layout_name]
        for key, evidence_file, evidence in declared:
            if evidence not in read(evidence_file):
                raise AuditStructureError(
                    f"{evidence_file} no longer starts {key} in {layout_name} with {evidence}"
                )
            if key not in layout.files:
                findings.append(
                    Finding(
                        "entry-not-deployed",
                        layout_name,
                        f"{evidence_file} starts {key}, which is not deployed there",
                    )
                )
                continue
            entries.setdefault(layout_name, []).append(key)
            started_sources.add(layout.files[key])
    for script in sorted(
        path.relative_to(REPO).as_posix() for path in (REPO / "Scripts").glob("*.ps1")
    ):
        if script not in started_sources:
            findings.append(
                Finding(
                    "undeclared-entry",
                    script,
                    "this top-level script is not declared as started in any layout; declare "
                    "where it runs so its references are checked",
                )
            )
    return entries


def audit_references(layouts: dict[str, Layout], findings: list[Finding]) -> list[str]:
    """Follow each started script through the scripts and modules it loads."""

    notes = []
    references: dict[tuple[str, str], list[Reference]] = {}
    for layout_name, entries in entry_points(layouts, findings).items():
        layout = layouts[layout_name]
        pending = list(entries)
        visited = set()
        while pending:
            script_key = pending.pop()
            if script_key in visited:
                continue
            visited.add(script_key)
            source = layout.files[script_key]
            reference_key = (source, layout_name)
            if reference_key not in references:
                references[reference_key] = script_references(source, findings, layout_name)
            by_name: dict[str, list[tuple[Reference, str, bool]]] = {}
            for reference in references[reference_key]:
                target = resolve(layout, script_key, reference)
                if target is None:
                    continue
                present = not target.startswith("..") and target in layout.files
                name = PureWindowsPath(reference.child).name.lower()
                by_name.setdefault(name, []).append((reference, target, present))
                if present and target.endswith((".ps1", ".psm1")):
                    pending.append(target)
            for name, candidates in sorted(by_name.items()):
                if not any(present for _, _, present in candidates):
                    check_layout_exception(layout_name, source, name, candidates, findings, notes)
                    continue
                for reference, target, present in candidates:
                    if present:
                        continue
                    message = (
                        f"in {layout_name}, {reference.child} is looked up at {target}, which "
                        "is not deployed; another reference to the same file resolves"
                    )
                    if layout.protected is False:
                        findings.append(
                            Finding(
                                "probe-in-writable-folder",
                                f"{source}:{reference.line}",
                                message,
                            )
                        )
                    else:
                        notes.append(f"{source}:{reference.line}: {message}")
        started = {layout.files[key] for key in visited}
        idle = sorted(
            key
            for key, source in layout.files.items()
            if key.endswith((".ps1", ".psm1")) and source not in started
        )
        if idle:
            notes.append(f"{layout_name}: {len(idle)} deployed scripts are never started there")
    return notes


def check_layout_exception(
    layout_name: str,
    source: str,
    name: str,
    candidates: list[tuple[Reference, str, bool]],
    findings: list[Finding],
    notes: list[str],
) -> None:
    reference = candidates[0][0]
    exception = DOCUMENTED_LAYOUT_EXCEPTIONS.get((source, name, layout_name))
    if exception is None:
        findings.append(
            Finding(
                "missing-in-layout",
                f"{source}:{reference.line}",
                f"in {layout_name}, no reference to {name} resolves to a deployed file "
                f"(looked for {', '.join(target for _, target, _ in candidates)})",
            )
        )
        return
    guard, reason = exception
    early_return = re.escape(guard) + r'\s*\{\s*return\s+"not-required"\s*\}'
    if not re.search(early_return, enclosing_function(source, reference.line)):
        findings.append(
            Finding(
                "unguarded-exception",
                f"{source}:{reference.line}",
                f"documented as unreachable in {layout_name} ({reason}), but the guard "
                f"{guard} with its early return no longer precedes it in the same function",
            )
        )
        return
    notes.append(f"{source}:{reference.line}: absent in {layout_name}, guarded: {reason}")


def audit_stale_exceptions(layouts: dict[str, Layout], findings: list[Finding]) -> None:
    for (source, name, layout_name), (_, reason) in DOCUMENTED_LAYOUT_EXCEPTIONS.items():
        layout = layouts[layout_name]
        if any(PureWindowsPath(key).name == name for key in layout.files):
            findings.append(
                Finding(
                    "stale-exception",
                    source,
                    f"{name} is now deployed in {layout_name}; remove the exception ({reason})",
                )
            )


# --- Duplicated lists of required files -------------------------------------------


def required_file_lists() -> list[tuple[str, str, list[str]]]:
    lists = []
    relative = "Helpers/InstalledLinuxRecovery.cs"
    for arguments in call_arguments(read(relative), "ValidateRequiredFiles"):
        if len(arguments) != 2 or not arguments[1].startswith("new[]"):
            continue
        entries = []
        for item in split_arguments(arguments[1].split("{", 1)[1].rsplit("}", 1)[0]):
            value = literal_path(item, {})
            if value is None:
                raise AuditStructureError(f"{relative}: cannot evaluate required file {item}")
            entries.extend(value)
        if not any(is_deployment_reference(entry) for entry in entries):
            continue  # runtime evidence only, such as the storage baseline
        layout = (
            "uefi-recovery"
            if any(entry.lower().startswith("payload") for entry in entries)
            else "bios-recovery"
        )
        lists.append((relative, layout, entries))

    relative = "Scripts/modules/Libertix.PostInstallVerification.psm1"
    text = read(relative)
    archive = re.search(
        r'\$runtimeFiles = if \(\[string\]\$Plan\.firmware -eq "uefi"\) \{(.*?)\} else \{(.*?)\}',
        text,
        re.DOTALL,
    )
    if not archive:
        raise AuditStructureError(f"{relative} changed its permanent runtime file lists")
    lists.append((relative, "uefi-recovery", re.findall(r'"([^"]+)"', archive.group(1))))
    lists.append((relative, "bios-recovery", re.findall(r'"([^"]+)"', archive.group(2))))
    if sorted(layout for _, layout, _ in lists) != [
        "bios-recovery",
        "bios-recovery",
        "uefi-recovery",
        "uefi-recovery",
    ]:
        raise AuditStructureError(
            "expected one BIOS and one UEFI list in each required-file source"
        )
    return lists


def audit_required_lists(layouts: dict[str, Layout], findings: list[Finding]) -> None:
    for relative, layout_name, entries in required_file_lists():
        layout = layouts[layout_name]
        for entry in entries:
            if is_deployment_reference(entry) and layout_key(entry) not in layout.files:
                findings.append(
                    Finding(
                        "required-not-deployed",
                        relative,
                        f"{entry} is required in {layout_name} but the installer never "
                        "copies it there",
                    )
                )


# --- Report -----------------------------------------------------------------------


def run_audit() -> tuple[dict[str, Layout], list[Finding], list[str]]:
    findings: list[Finding] = []
    application = application_layout(findings)
    layouts = {
        "application": application,
        "uefi-recovery": uefi_payload_layout(application),
        "bios-recovery": bios_recovery_layout(application, findings),
        "windows-share": windows_share_layout(application, findings),
    }
    apply_protection(layouts, findings)
    notes = audit_references(layouts, findings)
    audit_stale_exceptions(layouts, findings)
    audit_required_lists(layouts, findings)
    return layouts, findings, notes


def main() -> int:
    try:
        layouts, findings, notes = run_audit()
    except AuditStructureError as error:
        print(f"STRUCTURE ERROR: {error}")
        print("The audit refuses to guess; update it to the new source shape.")
        return 2

    print("Layouts rebuilt from the sources:")
    for layout in layouts.values():
        scripts = sum(1 for key in layout.files if key.endswith((".ps1", ".psm1")))
        protection = (
            "not run by a scheduled task"
            if layout.protected is None
            else layout.protection_evidence
        )
        print(
            f"  {layout.name}: {len(layout.files)} files, {scripts} scripts; {layout.description}"
        )
        print(f"    protection: {protection}")
    print()
    print(f"Notes (not errors): {len(notes)}")
    for note in notes:
        print(f"  NOTE {note}")
    print()
    for finding in findings:
        print(f"ERROR [{finding.rule}] {finding.where}: {finding.message}")
    print()
    print("Not covered: runtime ACLs on a real disk, paths built from other variables,")
    print("C# and shell file accesses, and the live ISO layout.")
    print(f"RESULT {'ERROR' if findings else 'OK'}: {len(findings)} error(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
