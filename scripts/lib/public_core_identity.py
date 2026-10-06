"""Derive publication identity from already validated private Core evidence.

Private receipts remain path-sensitive. Only the staging root in the version
authority is replaced, before rebinding its digest in the copied input document.
"""
import json
from pathlib import Path

from core_stage import bound_directory, canonical, digest, read_regular
from dependency_lock import reject_duplicate_pairs


def public_core_fingerprint(evidence, provenance):
    """Check private bindings, then hash inputs with a normalized authority."""
    evidence = Path(evidence).absolute()
    stage = str(evidence / "source")
    if provenance.get("staged_root") != stage:
        raise ValueError("public Core identity staged root differs")
    with bound_directory(evidence / "source"):
        raw_authority = read_regular(evidence / "version-authority.json")[0]
        raw_inputs = read_regular(evidence / "core-inputs.json")[0]
        authority = json.loads(raw_authority, object_pairs_hook=reject_duplicate_pairs)
        inputs = json.loads(raw_inputs, object_pairs_hook=reject_duplicate_pairs)
        if (not isinstance(authority, dict) or not isinstance(inputs, dict)
                or authority.get("schema") != 1 or inputs.get("schema") != 1
                or raw_authority != canonical(authority) or raw_inputs != canonical(inputs)):
            raise ValueError("public Core identity private documents differ")
        authority_digest, input_digest = digest(raw_authority), digest(raw_inputs)
        if (authority.get("staged_root") != stage
                or authority_digest != provenance.get("version_authority_sha256")
                or inputs.get("version_authority_sha256") != authority_digest):
            raise ValueError("public Core identity private authority binding differs")
        if (input_digest != provenance.get("core_input_fingerprint")
                or read_regular(evidence / "core-input-fingerprint.txt")[0] != (input_digest + "\n").encode()):
            raise ValueError("public Core identity private input fingerprint differs")
        public_authority = dict(authority, staged_root="$CORE_SOURCE")
        public_inputs = dict(inputs, version_authority_sha256=digest(canonical(public_authority)))
        return digest(canonical(public_inputs))
